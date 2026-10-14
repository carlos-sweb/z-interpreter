//! The `Iterator` global (ES2025): the abstract constructor, `Iterator.from`,
//! and the helpers on `Iterator.prototype` (%IteratorPrototype%, which
//! every builtin iterator and generator object inherits from).
//!
//! The lazy helpers (map/filter/take/drop/flatMap) return an Iterator
//! helper object: an ordinary `.object` whose [[Prototype]] is
//! %IteratorHelperPrototype% and whose generator-like state lives in the
//! interpreter's `object_slots` (an IteratorHelper). Its `next` runs one
//! step of the spec's abstract closure; there is no fiber, since each
//! closure only ever yields at the top of its loop. The eager ones
//! (reduce/toArray/forEach/some/every/find) step the iterator directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const IteratorHelper = interpreter_mod.IteratorHelper;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const regex_builtins = @import("regex_builtins.zig");

const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const isObjectLike = builtin_helpers.isObjectLike;

const method_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };

// ===== Iterator records and the protocol's abstract operations =====

/// An Iterator Record: the iterator and its `next` method (both owned).
const Record = struct {
    iterator: JSValue,
    next: JSValue,

    fn deinit(r: Record) void {
        r.iterator.deinit();
        r.next.deinit();
    }
};

fn isCallable(v: JSValue) bool {
    return switch (v) {
        .function => true,
        .proxy => |box| isCallable(box.value.target),
        else => false,
    };
}

/// GetIteratorDirect(obj): reads `next` once; no callability check.
fn getIteratorDirect(self: *Interpreter, obj: JSValue) anyerror!Record {
    const next = try self.getProperty(obj, "next");
    return .{ .iterator = obj.retain(), .next = next };
}

/// IteratorStepValue: the next value, or null when done.
fn stepValue(self: *Interpreter, iterator: JSValue, next: JSValue) anyerror!?JSValue {
    if (!isCallable(next)) return self.throwError(.type_error, "{s} is not a function", .{"iterator.next"});
    const result = try self.callValue(next, iterator, &.{}, "next");
    defer result.deinit();
    if (!isObjectLike(result)) return self.throwError(.type_error, "Iterator result {s} is not an object", .{result.typeOf()});
    const done = try self.getProperty(result, "done");
    defer done.deinit();
    if (coercion.isTruthy(done)) return null;
    return try self.getProperty(result, "value");
}

/// IteratorClose(iterator, throw completion): calls `return` if there is
/// one; anything it throws is discarded and the original exception
/// (already pending) is what propagates. Returns `err` for `return err`.
fn closeOnThrow(self: *Interpreter, iterator: JSValue, err: anyerror) anyerror {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer {
        if (self.pending_exception) |v| v.deinit();
        self.pending_exception = saved;
    }
    const ret = self.getProperty(iterator, "return") catch return err;
    defer ret.deinit();
    if (ret == .undefined or ret == .null) return err;
    const r = self.callValue(ret, iterator, &.{}, "return") catch return err;
    r.deinit();
    return err;
}

/// IteratorClose(iterator, normal/return completion): `return`'s own
/// errors propagate, and a non-object result is a TypeError.
fn closeNormal(self: *Interpreter, iterator: JSValue) anyerror!void {
    const ret = try self.getProperty(iterator, "return");
    defer ret.deinit();
    if (ret == .undefined or ret == .null) return;
    const r = try self.callValue(ret, iterator, &.{}, "return");
    defer r.deinit();
    if (!isObjectLike(r)) return self.throwError(.type_error, "Iterator result {s} is not an object", .{r.typeOf()});
}

/// GetIteratorFlattenable(obj, primitiveHandling).
fn getIteratorFlattenable(self: *Interpreter, obj: JSValue, comptime allow_strings: bool) anyerror!Record {
    if (!isObjectLike(obj)) {
        if (!(allow_strings and obj == .string)) return self.throwError(.type_error, "{s} is not an object", .{obj.typeOf()});
    }
    const key = try self.encodeKey(self.symbol_iterator.?);
    defer self.gc_allocator.free(key);
    const method = try self.getProperty(obj, key);
    defer method.deinit();
    const iterator = if (method == .undefined or method == .null) blk: {
        // Strings (and String objects) iterate structurally here (no
        // String.prototype[@@iterator] yet): an array iterator over the
        // code points.
        const str: ?JSValue = if (obj == .string) obj else if (self.unboxPrimitiveWrapper(obj)) |u| (if (u == .string) u else null) else null;
        if (str) |sv| {
            const cps = try self.iterableItems(sv);
            defer self.gc_allocator.free(cps);
            var arr = try self.gcNewArray();
            defer arr.deinit();
            for (cps) |cp| _ = try arr.array.value.push(cp);
            break :blk try builtin_helpers.makeArrayIterator(self, self.gc_allocator, arr, .values);
        }
        break :blk obj.retain();
    } else
        try self.callValue(method, obj, &.{}, "[Symbol.iterator]");
    defer iterator.deinit();
    if (!isObjectLike(iterator)) return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
    return getIteratorDirect(self, iterator);
}

/// CreateIterResultObject(value, done); takes ownership of `value`.
fn iterResult(self: *Interpreter, value: JSValue, done: bool) anyerror!JSValue {
    var o = try self.ordinaryObject();
    try o.object.value.set("value", value);
    try o.object.value.set("done", JSValue.fromBool(done));
    return o;
}

/// `this` as an Object, else a TypeError.
fn requireObject(self: *Interpreter, this_value: JSValue, comptime what: []const u8) anyerror!void {
    if (!isObjectLike(this_value)) return self.throwError(.type_error, what ++ " called on non-object", .{});
}

// ===== Iterator / Iterator.from =====

/// The abstract constructor: TypeError unless called by `new` from a
/// subclass (NewTarget neither undefined nor Iterator itself).
fn iteratorConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    if (self.construct_target != ctx or this_value != .object)
        return self.throwError(.type_error, "Constructor Iterator requires 'new'", .{});
    const proto = this_value.object.value.getPrototype();
    if (proto == null or proto.? == &self.iterator_prototype.?.object.value)
        return self.throwError(.type_error, "Abstract class Iterator not directly constructable", .{});
    return this_value.retain();
}

/// OrdinaryHasInstance(%Iterator%, v): %IteratorPrototype% on v's chain.
fn inheritsFromIterator(self: *Interpreter, v: JSValue) bool {
    if (v != .object) return false;
    const target = &self.iterator_prototype.?.object.value;
    var p = v.object.value.getPrototype();
    while (p) |cur| : (p = cur.getPrototype()) {
        if (cur == target) return true;
    }
    return false;
}

fn iteratorFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const rec = try getIteratorFlattenable(self, arg(args, 0), true);
    if (inheritsFromIterator(self, rec.iterator)) {
        rec.next.deinit();
        return rec.iterator;
    }
    var wrapper = try self.gcNewObject();
    errdefer wrapper.deinit();
    try wrapper.object.value.setPrototype(&self.wrap_for_valid_iterator_proto.?.object.value);
    try self.object_slots.put(self.gc_allocator, @intFromPtr(wrapper.object), .{ .wrapped_iterator = .{ .iterator = rec.iterator, .next = rec.next } });
    return wrapper;
}

fn wrappedOf(self: *Interpreter, this_value: JSValue, comptime what: []const u8) anyerror!Record {
    if (this_value == .object) {
        if (self.object_slots.get(@intFromPtr(this_value.object))) |slots| {
            if (slots == .wrapped_iterator) return .{ .iterator = slots.wrapped_iterator.iterator, .next = slots.wrapped_iterator.next };
        }
    }
    return self.throwError(.type_error, "Method " ++ what ++ " called on incompatible receiver", .{});
}

fn wrapNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const rec = try wrappedOf(self, this_value, "%WrapForValidIteratorPrototype%.next");
    return self.callValue(rec.next, rec.iterator, &.{}, "next");
}

fn wrapReturn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const rec = try wrappedOf(self, this_value, "%WrapForValidIteratorPrototype%.return");
    const ret = try self.getProperty(rec.iterator, "return");
    defer ret.deinit();
    if (ret == .undefined or ret == .null) return iterResult(self, JSValue.UNDEFINED, true);
    return self.callValue(ret, rec.iterator, &.{}, "return");
}

// ===== Iterator.prototype accessors and @@iterator =====

fn ctorGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    return interp(ctx).iterator_ctor.?.retain();
}

fn tagGetter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    return interp(ctx).gcNewString("Iterator");
}

/// SetterThatIgnoresPrototypeProperties(this, %Iterator.prototype%, p, v).
fn ignoringSetter(comptime which: enum { constructor, tag }) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            if (!isObjectLike(this_value)) return self.throwError(.type_error, "Iterator.prototype setter called on non-object", .{});
            if (this_value == .object and this_value.object == self.iterator_prototype.?.object)
                return self.throwError(.type_error, "Cannot assign to read only property of Iterator.prototype", .{});
            const key = if (which == .constructor) try self.gc_allocator.dupe(u8, "constructor") else try regex_builtins.wellKnownKey(self, "toStringTag");
            defer self.gc_allocator.free(key);
            const v = arg(args, 0);
            if (this_value == .object and this_value.object.value.getOwnRecordMut(key) == null) {
                this_value.object.value.defineProperty(key, v.retain(), .{ .writable = true, .enumerable = true, .configurable = true }) catch |err| switch (err) {
                    error.ObjectNotExtensible => {
                        v.deinit();
                        return self.throwError(.type_error, "Cannot add property to a non-extensible object", .{});
                    },
                    else => return err,
                };
                return JSValue.UNDEFINED;
            }
            try self.setPropertyOnValue(this_value, key, v);
            return JSValue.UNDEFINED;
        }
    }.call;
}

// ===== Iterator helpers (lazy) =====

fn helperOf(self: *Interpreter, this_value: JSValue, comptime what: []const u8) anyerror!*IteratorHelper {
    if (this_value == .object) {
        if (self.object_slots.get(@intFromPtr(this_value.object))) |slots| {
            if (slots == .iterator_helper) return slots.iterator_helper;
        }
    }
    return self.throwError(.type_error, "Method " ++ what ++ " called on incompatible receiver", .{});
}

/// A new helper object over `rec` (ownership moves into the helper).
fn newHelper(self: *Interpreter, kind: @FieldType(IteratorHelper, "kind"), rec: Record, func: JSValue, remaining: f64) anyerror!JSValue {
    const h = try self.gc_allocator.create(IteratorHelper);
    h.* = .{ .kind = kind, .iterator = rec.iterator, .next = rec.next, .func = func.retain(), .remaining = remaining };
    var o = try self.gcNewObject();
    try o.object.value.setPrototype(&self.iterator_helper_proto.?.object.value);
    self.object_slots.put(self.gc_allocator, @intFromPtr(o.object), .{ .iterator_helper = h }) catch |err| {
        o.deinit();
        return err;
    };
    return o;
}

/// One run of the helper's closure up to its next Yield: the yielded
/// value, or null when the closure returns. Errors are the closure's own
/// (the underlying iterator already closed where the spec says so).
fn helperStep(self: *Interpreter, h: *IteratorHelper) anyerror!?JSValue {
    switch (h.kind) {
        .map => {
            const value = (try stepValue(self, h.iterator, h.next)) orelse return null;
            defer value.deinit();
            const mapped = self.callValue(h.func, JSValue.UNDEFINED, &.{ value, JSValue.fromNumber(h.counter) }, "mapper") catch |err|
                return closeOnThrow(self, h.iterator, err);
            h.counter += 1;
            return mapped;
        },
        .filter => while (true) {
            const value = (try stepValue(self, h.iterator, h.next)) orelse return null;
            const selected = self.callValue(h.func, JSValue.UNDEFINED, &.{ value, JSValue.fromNumber(h.counter) }, "predicate") catch |err| {
                value.deinit();
                return closeOnThrow(self, h.iterator, err);
            };
            defer selected.deinit();
            h.counter += 1;
            if (coercion.isTruthy(selected)) return value;
            value.deinit();
        },
        .take => {
            if (h.remaining == 0) {
                try closeNormal(self, h.iterator);
                return null;
            }
            if (h.remaining != std.math.inf(f64)) h.remaining -= 1;
            return stepValue(self, h.iterator, h.next);
        },
        .drop => {
            while (h.remaining > 0) {
                if (h.remaining != std.math.inf(f64)) h.remaining -= 1;
                const skipped = (try stepValue(self, h.iterator, h.next)) orelse return null;
                skipped.deinit();
            }
            return stepValue(self, h.iterator, h.next);
        },
        .flat_map => while (true) {
            if (h.inner_alive) {
                const inner = stepValue(self, h.inner_iterator, h.inner_next) catch |err|
                    return closeOnThrow(self, h.iterator, err);
                if (inner) |v| return v;
                h.inner_alive = false;
                h.counter += 1;
                continue;
            }
            const value = (try stepValue(self, h.iterator, h.next)) orelse return null;
            defer value.deinit();
            const mapped = self.callValue(h.func, JSValue.UNDEFINED, &.{ value, JSValue.fromNumber(h.counter) }, "mapper") catch |err|
                return closeOnThrow(self, h.iterator, err);
            defer mapped.deinit();
            const rec = getIteratorFlattenable(self, mapped, false) catch |err|
                return closeOnThrow(self, h.iterator, err);
            h.inner_iterator.deinit();
            h.inner_next.deinit();
            h.inner_iterator = rec.iterator;
            h.inner_next = rec.next;
            h.inner_alive = true;
        },
    }
}

fn helperNext(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const h = try helperOf(self, this_value, "Iterator Helper.prototype.next");
    switch (h.state) {
        .executing => return self.throwError(.type_error, "Generator is already running", .{}),
        .completed => return iterResult(self, JSValue.UNDEFINED, true),
        .suspended_start, .suspended_yield => {},
    }
    h.state = .executing;
    const v = helperStep(self, h) catch |err| {
        h.state = .completed;
        return err;
    };
    if (v) |value| {
        h.state = .suspended_yield;
        return iterResult(self, value, false);
    }
    h.state = .completed;
    return iterResult(self, JSValue.UNDEFINED, true);
}

fn helperReturn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const h = try helperOf(self, this_value, "Iterator Helper.prototype.return");
    switch (h.state) {
        .executing => return self.throwError(.type_error, "Generator is already running", .{}),
        .completed => return iterResult(self, JSValue.UNDEFINED, true),
        .suspended_start => {
            h.state = .completed;
            try closeNormal(self, h.iterator);
        },
        .suspended_yield => {
            // A return completion at the Yield: flatMap closes its inner
            // iterator first (its failure closes the outer one as a throw).
            h.state = .executing;
            defer h.state = .completed;
            if (h.kind == .flat_map and h.inner_alive) {
                h.inner_alive = false;
                closeNormal(self, h.inner_iterator) catch |err| return closeOnThrow(self, h.iterator, err);
            }
            try closeNormal(self, h.iterator);
        },
    }
    return iterResult(self, JSValue.UNDEFINED, true);
}

/// map / filter / flatMap: `this` must be an Object and the callback
/// callable (else the iterator is closed and a TypeError thrown).
fn callbackHelper(comptime kind: @FieldType(IteratorHelper, "kind"), comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            try requireObject(self, this_value, what);
            const f = arg(args, 0);
            if (!isCallable(f)) {
                const err = self.throwError(.type_error, "{s} is not a function", .{f.typeOf()});
                return closeOnThrow(self, this_value, err);
            }
            return newHelper(self, kind, try getIteratorDirect(self, this_value), f, 0);
        }
    }.call;
}

/// take / drop: ToNumber(limit), NaN or negative is a RangeError (each
/// failure closes the iterator).
fn limitHelper(comptime kind: @FieldType(IteratorHelper, "kind"), comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            try requireObject(self, this_value, what);
            const n = self.toNumberJS(arg(args, 0)) catch |err| return closeOnThrow(self, this_value, err);
            if (std.math.isNan(n)) return closeOnThrow(self, this_value, self.throwError(.range_error, "{s} must be a number", .{"limit"}));
            const limit = if (std.math.isInf(n)) n else @trunc(n);
            if (limit < 0) return closeOnThrow(self, this_value, self.throwError(.range_error, "{s} must be positive", .{"limit"}));
            if (limit != std.math.inf(f64) and limit > 9007199254740991.0)
                return closeOnThrow(self, this_value, self.throwError(.range_error, "{s} is too large", .{"limit"}));
            return newHelper(self, kind, try getIteratorDirect(self, this_value), JSValue.UNDEFINED, limit + 0.0);
        }
    }.call;
}

// ===== Iterator helpers (eager) =====

fn iteratorReduce(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const self = interp(ctx);
    try requireObject(self, this_value, "Iterator.prototype.reduce");
    const f = arg(args, 0);
    if (!isCallable(f)) return closeOnThrow(self, this_value, self.throwError(.type_error, "{s} is not a function", .{f.typeOf()}));
    const rec = try getIteratorDirect(self, this_value);
    defer rec.deinit();
    var counter: f64 = 0;
    var acc: JSValue = undefined;
    if (args.len < 2) {
        acc = (try stepValue(self, rec.iterator, rec.next)) orelse
            return self.throwError(.type_error, "Reduce of empty iterator with no initial value", .{});
        counter = 1;
    } else acc = args[1].retain();
    while (true) {
        const value = stepValue(self, rec.iterator, rec.next) catch |err| {
            acc.deinit();
            return err;
        } orelse return acc;
        defer value.deinit();
        const r = self.callValue(f, JSValue.UNDEFINED, &.{ acc, value, JSValue.fromNumber(counter) }, "reducer") catch |err| {
            acc.deinit();
            return closeOnThrow(self, rec.iterator, err);
        };
        acc.deinit();
        acc = r;
        counter += 1;
    }
}

fn iteratorToArray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    try requireObject(self, this_value, "Iterator.prototype.toArray");
    const rec = try getIteratorDirect(self, this_value);
    defer rec.deinit();
    var arr = try self.gcNewArray();
    errdefer arr.deinit();
    while (try stepValue(self, rec.iterator, rec.next)) |v| _ = try arr.array.value.push(v);
    return arr;
}

/// forEach / some / every / find: call the function per value, stopping
/// (and closing the iterator) on the first decisive result.
fn predicateConsumer(comptime mode: enum { for_each, some, every, find }, comptime what: []const u8) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            const self = interp(ctx);
            try requireObject(self, this_value, what);
            const f = arg(args, 0);
            if (!isCallable(f)) return closeOnThrow(self, this_value, self.throwError(.type_error, "{s} is not a function", .{f.typeOf()}));
            const rec = try getIteratorDirect(self, this_value);
            defer rec.deinit();
            var counter: f64 = 0;
            while (try stepValue(self, rec.iterator, rec.next)) |value| {
                defer value.deinit();
                const r = self.callValue(f, JSValue.UNDEFINED, &.{ value, JSValue.fromNumber(counter) }, "fn") catch |err|
                    return closeOnThrow(self, rec.iterator, err);
                defer r.deinit();
                counter += 1;
                const t = coercion.isTruthy(r);
                switch (mode) {
                    .for_each => {},
                    .some => if (t) {
                        try closeNormal(self, rec.iterator);
                        return JSValue.fromBool(true);
                    },
                    .every => if (!t) {
                        try closeNormal(self, rec.iterator);
                        return JSValue.fromBool(false);
                    },
                    .find => if (t) {
                        try closeNormal(self, rec.iterator);
                        return value.retain();
                    },
                }
            }
            return switch (mode) {
                .for_each, .find => JSValue.UNDEFINED,
                .some => JSValue.fromBool(false),
                .every => JSValue.fromBool(true),
            };
        }
    }.call;
}

// ===== install =====

fn defineMethod(self: *Interpreter, target: JSValue, comptime name: []const u8, arity: usize, f: NativeFn) !void {
    try target.object.value.defineProperty(name, try native(self, name, arity, f), method_attrs);
}

/// A new prototype object chained to %IteratorPrototype% with `next` and
/// `return`.
fn subProto(self: *Interpreter, next: NativeFn, ret: NativeFn) !JSValue {
    const proto = try self.gcNewObject();
    try proto.object.value.setPrototype(&self.iterator_prototype.?.object.value);
    try defineMethod(self, proto, "next", 0, next);
    try defineMethod(self, proto, "return", 0, ret);
    return proto;
}

/// Installs `Iterator`, makes %IteratorPrototype% its `.prototype` with
/// the helpers, and creates %IteratorHelperPrototype% and
/// %WrapForValidIteratorPrototype%. Runs at the end of materializeProtos
/// (after RegExp created %IteratorPrototype%).
pub fn install(self: *Interpreter) !void {
    const proto = self.iterator_prototype.?;
    const ctor = try builtin_helpers.installBuiltin(self, .{ .name = "Iterator", .ctor = .{ .arity = 0, .call = iteratorConstructor, .constructable = true }, .statics = &.{
        .{ .name = "from", .value = .{ .method = .{ .call = iteratorFrom, .arity = 1 } } },
    } });
    ctor.function.value.prototype = proto.retain();
    self.iterator_ctor = ctor.retain();

    // `constructor` and @@toStringTag are accessors (ES2025), so that
    // assigning them on a subclass instance doesn't hit Iterator.prototype.
    const tag_key = try regex_builtins.wellKnownKey(self, "toStringTag");
    defer self.gc_allocator.free(tag_key);
    inline for (.{ .{ "constructor", ctorGetter, ignoringSetter(.constructor) }, .{ "[Symbol.toStringTag]", tagGetter, ignoringSetter(.tag) } }) |e| {
        const g = try native(self, "get " ++ e[0], 0, e[1]);
        const s = try native(self, "set " ++ e[0], 1, e[2]);
        const key: []const u8 = if (comptime std.mem.eql(u8, e[0], "constructor")) "constructor" else tag_key;
        try proto.object.value.defineAccessor(key, g, s, JSValue.UNDEFINED);
        const rec = proto.object.value.getOwnRecordMut(key).?;
        rec.descriptor.enumerable = false;
        rec.descriptor.configurable = true;
    }

    // %IteratorPrototype%[@@iterator] (RegExp creates the object before
    // Symbol.iterator exists, so it is added here).
    const iter_key = try self.encodeKey(self.symbol_iterator.?);
    defer self.gc_allocator.free(iter_key);
    if (proto.object.value.getOwnRecordMut(iter_key) == null)
        try proto.object.value.defineProperty(iter_key, try native(self, "[Symbol.iterator]", 0, builtin_helpers.iteratorSelfBuiltin), method_attrs);

    try defineMethod(self, proto, "map", 1, callbackHelper(.map, "Iterator.prototype.map"));
    try defineMethod(self, proto, "filter", 1, callbackHelper(.filter, "Iterator.prototype.filter"));
    try defineMethod(self, proto, "take", 1, limitHelper(.take, "Iterator.prototype.take"));
    try defineMethod(self, proto, "drop", 1, limitHelper(.drop, "Iterator.prototype.drop"));
    try defineMethod(self, proto, "flatMap", 1, callbackHelper(.flat_map, "Iterator.prototype.flatMap"));
    try defineMethod(self, proto, "reduce", 1, iteratorReduce);
    try defineMethod(self, proto, "toArray", 0, iteratorToArray);
    try defineMethod(self, proto, "forEach", 1, predicateConsumer(.for_each, "Iterator.prototype.forEach"));
    try defineMethod(self, proto, "some", 1, predicateConsumer(.some, "Iterator.prototype.some"));
    try defineMethod(self, proto, "every", 1, predicateConsumer(.every, "Iterator.prototype.every"));
    try defineMethod(self, proto, "find", 1, predicateConsumer(.find, "Iterator.prototype.find"));

    const helper_proto = try subProto(self, helperNext, helperReturn);
    try helper_proto.object.value.defineProperty(tag_key, try self.gcNewString("Iterator Helper"), .{ .writable = false, .enumerable = false, .configurable = true });
    self.iterator_helper_proto = helper_proto;
    self.wrap_for_valid_iterator_proto = try subProto(self, wrapNext, wrapReturn);
}
