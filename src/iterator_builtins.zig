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
const ZipMode = interpreter_mod.ZipMode;
const ZipItem = interpreter_mod.ZipItem;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const property_desc = @import("property_desc.zig");
const regex_builtins = @import("regex_builtins.zig");
const promise_builtins = @import("promise_builtins.zig");
const object_builtins = @import("object_builtins.zig");

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
    return switch (v.unpack()) {
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
pub fn stepValue(self: *Interpreter, iterator: JSValue, next: JSValue) anyerror!?JSValue {
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
pub fn closeOnThrow(self: *Interpreter, iterator: JSValue, err: anyerror) anyerror {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer {
        if (self.pending_exception) |v| v.deinit();
        self.pending_exception = saved;
    }
    const ret = self.getProperty(iterator, "return") catch return err;
    defer ret.deinit();
    if (ret.tag() == .undefined or ret.tag() == .null) return err;
    const r = self.callValue(ret, iterator, &.{}, "return") catch return err;
    r.deinit();
    return err;
}

/// IteratorClose(iterator, normal/return completion): `return`'s own
/// errors propagate, and a non-object result is a TypeError.
fn closeNormal(self: *Interpreter, iterator: JSValue) anyerror!void {
    const ret = try self.getProperty(iterator, "return");
    defer ret.deinit();
    if (ret.tag() == .undefined or ret.tag() == .null) return;
    const r = try self.callValue(ret, iterator, &.{}, "return");
    defer r.deinit();
    if (!isObjectLike(r)) return self.throwError(.type_error, "Iterator result {s} is not an object", .{r.typeOf()});
}

/// GetIteratorFlattenable(obj, primitiveHandling).
fn getIteratorFlattenable(self: *Interpreter, obj: JSValue, comptime allow_strings: bool) anyerror!Record {
    if (!isObjectLike(obj)) {
        if (!(allow_strings and obj.tag() == .string)) return self.throwError(.type_error, "{s} is not an object", .{obj.typeOf()});
    }
    const key = try self.encodeKey(self.symbol_iterator.?);
    defer self.gc_allocator.free(key);
    const method = try self.getProperty(obj, key);
    defer method.deinit();
    const iterator = if (method.tag() == .undefined or method.tag() == .null) blk: {
        // Strings (and String objects) iterate structurally here (no
        // String.prototype[@@iterator] yet): an array iterator over the
        // code points.
        const str: ?JSValue = if (obj.tag() == .string) obj else if (self.unboxPrimitiveWrapper(obj)) |u| (if (u.tag() == .string) u else null) else null;
        if (str) |sv| {
            const cps = try self.iterableItems(sv);
            defer self.gc_allocator.free(cps);
            var arr = try self.gcNewArray();
            defer arr.deinit();
            for (cps) |cp| _ = try arr.asArray().value.push(cp);
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
    try o.asObject().value.set("value", value);
    try o.asObject().value.set("done", JSValue.fromBool(done));
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
    if (self.construct_target != ctx or this_value.tag() != .object)
        return self.throwError(.type_error, "Constructor Iterator requires 'new'", .{});
    const proto = this_value.asObject().value.getPrototype();
    if (proto == null or proto.? == &self.iterator_prototype.?.asObject().value)
        return self.throwError(.type_error, "Abstract class Iterator not directly constructable", .{});
    return this_value.retain();
}

/// OrdinaryHasInstance(%Iterator%, v): %IteratorPrototype% on v's chain.
fn inheritsFromIterator(self: *Interpreter, v: JSValue) bool {
    if (v.tag() != .object) return false;
    const target = &self.iterator_prototype.?.asObject().value;
    var p = v.asObject().value.getPrototype();
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
    try wrapper.asObject().value.setPrototype(&self.wrap_for_valid_iterator_proto.?.asObject().value);
    try self.object_slots.put(self.gc_allocator, @intFromPtr(wrapper.asObject()), .{ .wrapped_iterator = .{ .iterator = rec.iterator, .next = rec.next } });
    return wrapper;
}

fn wrappedOf(self: *Interpreter, this_value: JSValue, comptime what: []const u8) anyerror!Record {
    if (this_value.tag() == .object) {
        if (self.object_slots.get(@intFromPtr(this_value.asObject()))) |slots| {
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
    if (ret.tag() == .undefined or ret.tag() == .null) return iterResult(self, JSValue.UNDEFINED, true);
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
            if (this_value.isObject() and this_value.asObject() == self.iterator_prototype.?.asObject())
                return self.throwError(.type_error, "Cannot assign to read only property of Iterator.prototype", .{});
            const key = if (which == .constructor) try self.gc_allocator.dupe(u8, "constructor") else try regex_builtins.wellKnownKey(self, "toStringTag");
            defer self.gc_allocator.free(key);
            const v = arg(args, 0);
            if (this_value.tag() == .object and this_value.asObject().value.getOwnRecordMut(key) == null) {
                this_value.asObject().value.defineProperty(key, v.retain(), .{ .writable = true, .enumerable = true, .configurable = true }) catch |err| switch (err) {
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
    if (this_value.tag() == .object) {
        if (self.object_slots.get(@intFromPtr(this_value.asObject()))) |slots| {
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
    try o.asObject().value.setPrototype(&self.iterator_helper_proto.?.asObject().value);
    self.object_slots.put(self.gc_allocator, @intFromPtr(o.asObject()), .{ .iterator_helper = h }) catch |err| {
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
        .concat => while (true) {
            if (h.inner_alive) {
                const inner = stepValue(self, h.inner_iterator, h.inner_next) catch |err| {
                    h.inner_alive = false;
                    return err;
                };
                if (inner) |v| return v;
                h.inner_alive = false;
                h.inner_iterator.deinit();
                h.inner_next.deinit();
                h.inner_iterator = JSValue.UNDEFINED;
                h.inner_next = JSValue.UNDEFINED;
            }
            if (h.concat_idx >= h.concat_items.items.len) return null;
            const item = h.concat_items.items[h.concat_idx];
            h.concat_idx += 1;
            const iter = try self.callValue(item.open_method, item.iterable, &.{}, "Symbol.iterator");
            errdefer iter.deinit();
            if (!isObjectLike(iter)) return self.throwError(.type_error, "Iterator result is not an object", .{});
            const rec = try getIteratorDirect(self, iter);
            iter.deinit();
            h.inner_iterator.deinit();
            h.inner_next.deinit();
            h.inner_iterator = rec.iterator;
            h.inner_next = rec.next;
            h.inner_alive = true;
        },
        .zip, .zip_keyed => return zipStep(self, h),
    }
}

fn iteratorCloseAllThrow(self: *Interpreter, items: []ZipItem, err: anyerror) anyerror {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer {
        if (self.pending_exception) |v| v.deinit();
        self.pending_exception = saved;
    }
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (!items[i].open) continue;
        items[i].open = false;
        _ = closeOnThrow(self, items[i].iterator, err) catch {};
    }
    return err;
}

fn iteratorCloseAllNormal(self: *Interpreter, items: []ZipItem) anyerror!void {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (!items[i].open) continue;
        items[i].open = false;
        closeNormal(self, items[i].iterator) catch |err| {
            return iteratorCloseAllThrow(self, items[0..i], err);
        };
    }
}

fn zipStep(self: *Interpreter, h: *IteratorHelper) anyerror!?JSValue {
    const items = h.zip_items.items;
    if (items.len == 0) return null;

    const results = try self.gc_allocator.alloc(JSValue, items.len);
    var filled: usize = 0;
    defer {
        for (results[0..filled]) |v| v.deinit();
        self.gc_allocator.free(results);
    }

    var any_yielded = false;
    for (items, 0..) |*it, i| {
        if (!it.open) {
            results[i] = it.padding.retain();
            filled = i + 1;
            continue;
        }
        const val = stepValue(self, it.iterator, it.next) catch |err| {
            it.open = false;
            return iteratorCloseAllThrow(self, items, err);
        };
        if (val) |v| {
            results[i] = v;
            filled = i + 1;
            any_yielded = true;
        } else {
            it.open = false;
            switch (h.zip_mode) {
                .shortest => {
                    try iteratorCloseAllNormal(self, items);
                    return null;
                },
                .longest => {
                    results[i] = it.padding.retain();
                    filled = i + 1;
                },
                .strict => {
                    if (i == 0) {
                        for (items[1..]) |*other| {
                            if (!other.open) continue;
                            const ov = stepValue(self, other.iterator, other.next) catch |err| {
                                other.open = false;
                                return iteratorCloseAllThrow(self, items, err);
                            };
                            if (ov) |v| {
                                v.deinit();
                                const te = self.throwError(.type_error, "Iterator.zip strict mode length mismatch", .{});
                                return iteratorCloseAllThrow(self, items, te);
                            }
                            other.open = false;
                        }
                        return null;
                    }
                    const te = self.throwError(.type_error, "Iterator.zip strict mode length mismatch", .{});
                    return iteratorCloseAllThrow(self, items, te);
                },
            }
        }
    }

    if (!any_yielded) return null;

    if (h.kind == .zip) {
        var arr = try self.gcNewArray();
        errdefer arr.deinit();
        for (results[0..filled]) |v| _ = try arr.asArray().value.push(v.retain());
        return arr;
    }

    var obj = try self.gcNewObject();
    errdefer obj.deinit();
    const attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = true, .configurable = true };
    for (items, 0..) |it, i| {
        try obj.asObject().value.defineProperty(it.key, results[i].retain(), attrs);
    }
    return obj;
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
            if (h.kind == .zip or h.kind == .zip_keyed) {
                try iteratorCloseAllNormal(self, h.zip_items.items);
            } else if (h.kind != .concat) {
                try closeNormal(self, h.iterator);
            }
        },
        .suspended_yield => {
            // A return completion at the Yield: flatMap closes its inner
            // iterator first (its failure closes the outer one as a throw).
            h.state = .executing;
            defer h.state = .completed;
            if (h.kind == .zip or h.kind == .zip_keyed) {
                try iteratorCloseAllNormal(self, h.zip_items.items);
            } else if (h.kind == .concat) {
                if (h.inner_alive) {
                    h.inner_alive = false;
                    try closeNormal(self, h.inner_iterator);
                }
            } else {
                if (h.kind == .flat_map and h.inner_alive) {
                    h.inner_alive = false;
                    closeNormal(self, h.inner_iterator) catch |err| return closeOnThrow(self, h.iterator, err);
                }
                try closeNormal(self, h.iterator);
            }
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
    while (try stepValue(self, rec.iterator, rec.next)) |v| _ = try arr.asArray().value.push(v);
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
    try target.asObject().value.defineProperty(name, try native(self, name, arity, f), method_attrs);
}

/// A new prototype object chained to %IteratorPrototype% with `next` and
/// `return`.
fn subProto(self: *Interpreter, next: NativeFn, ret: NativeFn) !JSValue {
    const proto = try self.gcNewObject();
    try proto.asObject().value.setPrototype(&self.iterator_prototype.?.asObject().value);
    try defineMethod(self, proto, "next", 0, next);
    try defineMethod(self, proto, "return", 0, ret);
    return proto;
}

fn iteratorSymbolDispose(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const ret = try self.getProperty(this_value, "return");
    defer ret.deinit();
    if (!ret.isUndefined() and !ret.isNull()) {
        if (!isCallable(ret)) return self.throwError(.type_error, "iterator.return is not a function", .{});
        const res = try self.callValue(ret, this_value, &.{}, "iterator.return");
        res.deinit();
    }
    return JSValue.UNDEFINED;
}

fn asyncIterDisposeFulfill(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const c: *promise_builtins.FinallyCtx = @ptrCast(@alignCast(ctx));
    try c.interp.resolvePromise(c.handler, JSValue.UNDEFINED);
    return JSValue.UNDEFINED;
}

fn asyncIterDisposeReject(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const c: *promise_builtins.FinallyCtx = @ptrCast(@alignCast(ctx));
    try c.interp.rejectPromiseValue(c.handler, arg(args, 0));
    return JSValue.UNDEFINED;
}

fn asyncIteratorSymbolDispose(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    const self = interp(ctx);
    const p = try self.gcNewPromise();
    errdefer p.deinit();

    const ret = self.getProperty(this_value, "return") catch |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception orelse JSValue.UNDEFINED;
        self.pending_exception = null;
        defer ex.deinit();
        try self.rejectPromiseValue(p, ex);
        return p;
    };
    defer ret.deinit();

    if (ret.isUndefined() or ret.isNull()) {
        try self.resolvePromise(p, JSValue.UNDEFINED);
        return p;
    }
    if (!isCallable(ret)) {
        const te = try self.gcNewError(.type_error, "iterator.return is not a function");
        defer te.deinit();
        try self.rejectPromiseValue(p, te);
        return p;
    }
    const call_res = self.callValue(ret, this_value, &.{}, "iterator.return") catch |err0| {
        const err = self.throwIfGap(err0);
        if (err != error.JsThrow) return err;
        const ex = self.pending_exception orelse JSValue.UNDEFINED;
        self.pending_exception = null;
        defer ex.deinit();
        try self.rejectPromiseValue(p, ex);
        return p;
    };
    defer call_res.deinit();

    const val_p = try self.gcNewPromise();
    defer val_p.deinit();
    try self.resolvePromise(val_p, call_res);

    const c = try self.gc_allocator.create(promise_builtins.FinallyCtx);
    c.* = .{ .interp = self, .handler = p.retain() };
    try self.gcTrackFinallyCtx(c);
    const on_f = try self.gcNewFunction(.{ .ctx = c, .name = "", .arity = 1, .call = asyncIterDisposeFulfill });
    defer on_f.deinit();
    const on_r = try self.gcNewFunction(.{ .ctx = c, .name = "", .arity = 1, .call = asyncIterDisposeReject });
    defer on_r.deinit();
    try self.subscribePromise(val_p, on_f, on_r, null);
    return p;
}

/// Installs `Iterator`, makes %IteratorPrototype% its `.prototype` with
/// the helpers, and creates %IteratorHelperPrototype% and
/// %WrapForValidIteratorPrototype%. Runs at the end of materializeProtos
/// (after RegExp created %IteratorPrototype%).
fn iteratorConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const sym = self.symbol_iterator orelse return self.throwError(.type_error, "Symbol.iterator is not defined", .{});
    const key = try self.encodeKey(sym);
    defer allocator.free(key);

    var items: std.ArrayListUnmanaged(interpreter_mod.ConcatItem) = .empty;
    errdefer {
        for (items.items) |it| {
            it.iterable.deinit();
            it.open_method.deinit();
        }
        items.deinit(self.gc_allocator);
    }

    for (args) |item| {
        if (!isObjectLike(item)) {
            return self.throwError(.type_error, "Iterator.concat requires object arguments", .{});
        }
        const method = try self.getProperty(item, key);
        errdefer method.deinit();
        if (method.isUndefined() or method.isNull() or !isCallable(method)) {
            return self.throwError(.type_error, "Argument is not iterable", .{});
        }
        try items.append(self.gc_allocator, .{
            .iterable = item.retain(),
            .open_method = method,
        });
    }

    const h = try self.gc_allocator.create(IteratorHelper);
    h.* = .{
        .kind = .concat,
        .iterator = JSValue.UNDEFINED,
        .next = JSValue.UNDEFINED,
        .concat_items = items,
    };
    var o = try self.gcNewObject();
    try o.asObject().value.setPrototype(&self.iterator_helper_proto.?.asObject().value);
    self.object_slots.put(self.gc_allocator, @intFromPtr(o.asObject()), .{ .iterator_helper = h }) catch |err| {
        o.deinit();
        return err;
    };
    return o;
}

pub fn getIteratorSync(self: *Interpreter, obj: JSValue) anyerror!Record {
    const sym = self.symbol_iterator orelse return self.throwError(.type_error, "Symbol.iterator is not defined", .{});
    const key = try self.encodeKey(sym);
    defer self.gc_allocator.free(key);
    const method = try self.getProperty(obj, key);
    defer method.deinit();
    if (method.isUndefined() and obj.tag() == .string) {
        const cps = try self.iterableItems(obj);
        defer self.gc_allocator.free(cps);
        var arr = try self.gcNewArray();
        defer arr.deinit();
        for (cps) |cp| _ = try arr.asArray().value.push(cp);
        const str_iter = try builtin_helpers.makeArrayIterator(self, self.gc_allocator, arr, .values);
        defer str_iter.deinit();
        return getIteratorDirect(self, str_iter);
    }
    if (method.isUndefined() or method.isNull() or !isCallable(method)) {
        return self.throwError(.type_error, "{s} is not iterable", .{obj.typeOf()});
    }
    const iter = try self.callValue(method, obj, &.{}, "[Symbol.iterator]");
    defer iter.deinit();
    if (!isObjectLike(iter)) return self.throwError(.type_error, "Iterator result is not an object", .{});
    return getIteratorDirect(self, iter);
}

/// Shared by Map, Set, WeakMap, WeakSet constructors: checks `adder`
/// before opening `iterable`, then steps lazily and closes the iterator
/// on any entry/adder error.
pub fn addEntriesFromIterable(self: *Interpreter, target: JSValue, iterable: JSValue, comptime is_map: bool, comptime name: []const u8) anyerror!void {
    if (iterable.tag() == .undefined or iterable.tag() == .null) return;
    const adder_name = if (is_map) "set" else "add";
    const adder = try self.getProperty(target, adder_name);
    defer adder.deinit();
    if (!property_desc.isCallable(adder)) {
        return self.throwError(.type_error, "'" ++ adder_name ++ "' returned for " ++ name ++ " is not a function", .{});
    }
    // Fast path for plain unmodified arrays with default Array.prototype.values:
    // avoids allocating a GC-tracked ArrayIterCtx snapshot so refcount_test
    // sees exact immediate refcounts.
    if (iterable.tag() == .array and self.array_props.get(@intFromPtr(iterable.asArray())) == null and self.proto_refs.get(@intFromPtr(iterable.asArray())) == null and !iterable.asArray().value.isSparse() and !iterable.asArray().value.isHoley()) {
        if (self.symbol_iterator) |sym| {
            const key = try self.encodeKey(sym);
            defer self.gc_allocator.free(key);
            const method = try self.getProperty(iterable, key);
            defer method.deinit();
            const default_values = self.protos.array.asObject().value.getOwn("values");
            if (default_values != null and zvalue.equality.strictEquals(method, default_values.?)) {
                for (iterable.asArray().value.toSlice()) |item| {
                    if (is_map) {
                        if (!isObjectLike(item)) return self.throwError(.type_error, "Iterator value {s} is not an entry object", .{item.typeOf()});
                        const k = try self.getProperty(item, "0");
                        defer k.deinit();
                        const v = try self.getProperty(item, "1");
                        defer v.deinit();
                        const r = try self.callValue(adder, target, &.{ k, v }, adder_name);
                        r.deinit();
                    } else {
                        const r = try self.callValue(adder, target, &.{item}, adder_name);
                        r.deinit();
                    }
                }
                return;
            }
        }
    }
    const rec = try getIteratorSync(self, iterable);
    defer rec.deinit();
    while (true) {
        const item = (try stepValue(self, rec.iterator, rec.next)) orelse break;
        defer item.deinit();
        if (is_map) {
            if (!isObjectLike(item)) {
                const te = self.throwError(.type_error, "Iterator value {s} is not an entry object", .{item.typeOf()});
                return closeOnThrow(self, rec.iterator, te);
            }
            const k = self.getProperty(item, "0") catch |err| return closeOnThrow(self, rec.iterator, err);
            defer k.deinit();
            const v = self.getProperty(item, "1") catch |err| return closeOnThrow(self, rec.iterator, err);
            defer v.deinit();
            const r = self.callValue(adder, target, &.{ k, v }, adder_name) catch |err| return closeOnThrow(self, rec.iterator, err);
            r.deinit();
        } else {
            const r = self.callValue(adder, target, &.{item}, adder_name) catch |err| return closeOnThrow(self, rec.iterator, err);
            r.deinit();
        }
    }
}

fn parseZipOptions(self: *Interpreter, options_val: JSValue) anyerror!struct { mode: ZipMode, padding: JSValue } {
    if (options_val.isUndefined()) return .{ .mode = .shortest, .padding = JSValue.UNDEFINED };
    if (!isObjectLike(options_val)) return self.throwError(.type_error, "Options must be an object", .{});
    const mode_val = try self.getProperty(options_val, "mode");
    defer mode_val.deinit();
    const mode: ZipMode = if (mode_val.isUndefined())
        .shortest
    else if (mode_val.isString()) blk: {
        const s = mode_val.asString().value.data;
        if (std.mem.eql(u8, s, "shortest")) break :blk .shortest;
        if (std.mem.eql(u8, s, "longest")) break :blk .longest;
        if (std.mem.eql(u8, s, "strict")) break :blk .strict;
        return self.throwError(.type_error, "Invalid zip mode", .{});
    } else return self.throwError(.type_error, "Invalid zip mode", .{});

    var padding = JSValue.UNDEFINED;
    if (mode == .longest) {
        const pad_val = try self.getProperty(options_val, "padding");
        errdefer pad_val.deinit();
        if (!pad_val.isUndefined() and !isObjectLike(pad_val)) {
            return self.throwError(.type_error, "padding must be an object", .{});
        }
        padding = pad_val;
    }
    return .{ .mode = mode, .padding = padding };
}

fn deinitZipItems(allocator: Allocator, items: *std.ArrayListUnmanaged(ZipItem)) void {
    for (items.items) |it| {
        it.iterator.deinit();
        it.next.deinit();
        it.padding.deinit();
        if (it.key.len > 0) allocator.free(it.key);
    }
    items.deinit(allocator);
}

fn buildZipHelper(self: *Interpreter, kind: @FieldType(IteratorHelper, "kind"), mode: ZipMode, items: std.ArrayListUnmanaged(ZipItem)) anyerror!JSValue {
    const h = try self.gc_allocator.create(IteratorHelper);
    h.* = .{
        .kind = kind,
        .iterator = JSValue.UNDEFINED,
        .next = JSValue.UNDEFINED,
        .zip_mode = mode,
        .zip_items = items,
    };
    var o = try self.gcNewObject();
    try o.asObject().value.setPrototype(&self.iterator_helper_proto.?.asObject().value);
    self.object_slots.put(self.gc_allocator, @intFromPtr(o.asObject()), .{ .iterator_helper = h }) catch |err| {
        o.deinit();
        return err;
    };
    return o;
}

fn iteratorZip(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const iterables = arg(args, 0);
    if (!isObjectLike(iterables)) return self.throwError(.type_error, "Iterator.zip requires an object", .{});
    const opts = try parseZipOptions(self, arg(args, 1));
    defer opts.padding.deinit();

    const input_rec = try getIteratorSync(self, iterables);
    defer input_rec.deinit();

    var items: std.ArrayListUnmanaged(ZipItem) = .empty;
    errdefer deinitZipItems(self.gc_allocator, &items);

    while (true) {
        const elem = stepValue(self, input_rec.iterator, input_rec.next) catch |err| {
            return iteratorCloseAllThrow(self, items.items, err);
        } orelse break;
        defer elem.deinit();
        const rec = getIteratorFlattenable(self, elem, false) catch |err| {
            _ = iteratorCloseAllThrow(self, items.items, err) catch {};
            return closeOnThrow(self, input_rec.iterator, err);
        };
        items.append(self.gc_allocator, .{ .iterator = rec.iterator, .next = rec.next }) catch |err| {
            rec.deinit();
            _ = iteratorCloseAllThrow(self, items.items, err) catch {};
            return closeOnThrow(self, input_rec.iterator, err);
        };
    }

    if (opts.mode == .longest and !opts.padding.isUndefined()) {
        const pad_rec = getIteratorSync(self, opts.padding) catch |err| {
            return iteratorCloseAllThrow(self, items.items, err);
        };
        defer pad_rec.deinit();
        var pad_exhausted = false;
        for (items.items) |*it| {
            const pv = stepValue(self, pad_rec.iterator, pad_rec.next) catch |err| {
                return iteratorCloseAllThrow(self, items.items, err);
            };
            if (pv) |v| {
                it.padding = v;
            } else {
                pad_exhausted = true;
                break;
            }
        }
        if (!pad_exhausted) {
            closeNormal(self, pad_rec.iterator) catch |err| {
                return iteratorCloseAllThrow(self, items.items, err);
            };
        }
    }

    return buildZipHelper(self, .zip, opts.mode, items);
}

fn iteratorZipKeyed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const iterables = arg(args, 0);
    if (!isObjectLike(iterables)) return self.throwError(.type_error, "Iterator.zipKeyed requires an object", .{});
    const opts = try parseZipOptions(self, arg(args, 1));
    defer opts.padding.deinit();

    const keys = try object_builtins.ownPropertyKeyList(self, allocator, iterables);
    defer object_builtins.freeOwnedKeys(allocator, keys);

    var items: std.ArrayListUnmanaged(ZipItem) = .empty;
    errdefer deinitZipItems(self.gc_allocator, &items);

    for (keys) |k| {
        const is_enum = (object_builtins.ownPropertyEnumerable(self, iterables, k) catch |err| {
            return iteratorCloseAllThrow(self, items.items, err);
        }) orelse continue;
        if (!is_enum) continue;

        const val = self.getProperty(iterables, k) catch |err| {
            return iteratorCloseAllThrow(self, items.items, err);
        };
        defer val.deinit();
        if (val.isUndefined()) continue;

        const rec = getIteratorFlattenable(self, val, false) catch |err| {
            return iteratorCloseAllThrow(self, items.items, err);
        };
        const duped_key = self.gc_allocator.dupe(u8, k) catch |err| {
            rec.deinit();
            return iteratorCloseAllThrow(self, items.items, err);
        };
        items.append(self.gc_allocator, .{ .iterator = rec.iterator, .next = rec.next, .key = duped_key }) catch |err| {
            rec.deinit();
            self.gc_allocator.free(duped_key);
            return iteratorCloseAllThrow(self, items.items, err);
        };
    }

    if (opts.mode == .longest and !opts.padding.isUndefined()) {
        for (items.items) |*it| {
            const pv = self.getProperty(opts.padding, it.key) catch |err| {
                return iteratorCloseAllThrow(self, items.items, err);
            };
            it.padding = pv;
        }
    }

    return buildZipHelper(self, .zip_keyed, opts.mode, items);
}

pub fn install(self: *Interpreter) !void {
    const proto = self.iterator_prototype.?;
    const ctor = try builtin_helpers.installBuiltin(self, .{ .name = "Iterator", .ctor = .{ .arity = 0, .call = iteratorConstructor, .constructable = true }, .statics = &.{
        .{ .name = "from", .value = .{ .method = .{ .call = iteratorFrom, .arity = 1 } } },
        .{ .name = "concat", .value = .{ .method = .{ .call = iteratorConcat, .arity = 0 } } },
        .{ .name = "zip", .value = .{ .method = .{ .call = iteratorZip, .arity = 1 } } },
        .{ .name = "zipKeyed", .value = .{ .method = .{ .call = iteratorZipKeyed, .arity = 1 } } },
    } });
    ctor.asFunction().value.prototype = proto.retain();
    self.iterator_ctor = ctor.retain();

    // `constructor` and @@toStringTag are accessors (ES2025), so that
    // assigning them on a subclass instance doesn't hit Iterator.prototype.
    const tag_key = try regex_builtins.wellKnownKey(self, "toStringTag");
    defer self.gc_allocator.free(tag_key);
    inline for (.{ .{ "constructor", ctorGetter, ignoringSetter(.constructor) }, .{ "[Symbol.toStringTag]", tagGetter, ignoringSetter(.tag) } }) |e| {
        const g = try native(self, "get " ++ e[0], 0, e[1]);
        const s = try native(self, "set " ++ e[0], 1, e[2]);
        const key: []const u8 = if (comptime std.mem.eql(u8, e[0], "constructor")) "constructor" else tag_key;
        try proto.asObject().value.defineAccessor(key, g, s, JSValue.UNDEFINED);
        const rec = proto.asObject().value.getOwnRecordMut(key).?;
        rec.descriptor.enumerable = false;
        rec.descriptor.configurable = true;
    }

    // %IteratorPrototype%[@@iterator] (RegExp creates the object before
    // Symbol.iterator exists, so it is added here).
    const iter_key = try self.encodeKey(self.symbol_iterator.?);
    defer self.gc_allocator.free(iter_key);
    if (proto.asObject().value.getOwnRecordMut(iter_key) == null)
        try proto.asObject().value.defineProperty(iter_key, try native(self, "[Symbol.iterator]", 0, builtin_helpers.iteratorSelfBuiltin), method_attrs);

    if (self.symbol_dispose) |disp_sym| {
        const disp_key = try self.encodeKey(disp_sym);
        defer self.gc_allocator.free(disp_key);
        if (proto.asObject().value.getOwnRecordMut(disp_key) == null)
            try proto.asObject().value.defineProperty(disp_key, try native(self, "[Symbol.dispose]", 0, iteratorSymbolDispose), method_attrs);
    }

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
    try helper_proto.asObject().value.defineProperty(tag_key, try self.gcNewString("Iterator Helper"), .{ .writable = false, .enumerable = false, .configurable = true });
    self.iterator_helper_proto = helper_proto;
    self.wrap_for_valid_iterator_proto = try subProto(self, wrapNext, wrapReturn);

    var async_iter_proto = try self.ordinaryObject();
    if (self.symbol_async_iterator) |asym| {
        const akey = try self.encodeKey(asym);
        defer self.gc_allocator.free(akey);
        try async_iter_proto.asObject().value.defineProperty(akey, try native(self, "[Symbol.asyncIterator]", 0, builtin_helpers.iteratorSelfBuiltin), method_attrs);
    }
    if (self.symbol_async_dispose) |dsym| {
        const dkey = try self.encodeKey(dsym);
        defer self.gc_allocator.free(dkey);
        try async_iter_proto.asObject().value.defineProperty(dkey, try native(self, "[Symbol.asyncDispose]", 0, asyncIteratorSymbolDispose), method_attrs);
    }
    self.protos.async_iterator_proto = async_iter_proto;

    const iruntime = @import("interpreter_runtime.zig");
    const ro_cfg = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = true };

    var gen_fn_proto = try self.gcNewObject();
    if (self.protos.function.isObject()) {
        try gen_fn_proto.asObject().value.setPrototype(&self.protos.function.asObject().value);
    }
    var gen_proto = try self.gcNewObject();
    try gen_proto.asObject().value.setPrototype(&proto.asObject().value);
    try gen_proto.asObject().value.defineProperty("constructor", gen_fn_proto.retain(), ro_cfg);
    try defineMethod(self, gen_proto, "next", 1, iruntime.generatorProtoNext);
    try defineMethod(self, gen_proto, "return", 1, iruntime.generatorProtoReturn);
    try defineMethod(self, gen_proto, "throw", 1, iruntime.generatorProtoThrow);
    try gen_proto.asObject().value.defineProperty(tag_key, try self.gcNewString("Generator"), ro_cfg);
    const fn_builtins = @import("function_builtins.zig");
    const gen_fn_ctor = try self.gcNewFunction(.{
        .ctx = self,
        .name = "GeneratorFunction",
        .arity = 1,
        .call = fn_builtins.generatorFunctionConstructor,
        .constructable = true,
    });
    gen_fn_ctor.asFunction().value.prototype = gen_fn_proto.retain();
    try gen_fn_proto.asObject().value.defineProperty("constructor", gen_fn_ctor, ro_cfg);
    try gen_fn_proto.asObject().value.defineProperty("prototype", gen_proto.retain(), ro_cfg);
    try gen_fn_proto.asObject().value.defineProperty(tag_key, try self.gcNewString("GeneratorFunction"), ro_cfg);
    self.protos.generator_proto = gen_proto;
    self.protos.generator_function_proto = gen_fn_proto;

    var async_gen_fn_proto = try self.gcNewObject();
    if (self.protos.function.isObject()) {
        try async_gen_fn_proto.asObject().value.setPrototype(&self.protos.function.asObject().value);
    }
    var async_gen_proto = try self.gcNewObject();
    try async_gen_proto.asObject().value.setPrototype(&async_iter_proto.asObject().value);
    try async_gen_proto.asObject().value.defineProperty("constructor", async_gen_fn_proto.retain(), ro_cfg);
    try defineMethod(self, async_gen_proto, "next", 1, iruntime.asyncGeneratorProtoNext);
    try defineMethod(self, async_gen_proto, "return", 1, iruntime.asyncGeneratorProtoReturn);
    try defineMethod(self, async_gen_proto, "throw", 1, iruntime.asyncGeneratorProtoThrow);
    try async_gen_proto.asObject().value.defineProperty(tag_key, try self.gcNewString("AsyncGenerator"), ro_cfg);
    const async_gen_fn_ctor = try self.gcNewFunction(.{
        .ctx = self,
        .name = "AsyncGeneratorFunction",
        .arity = 1,
        .call = fn_builtins.asyncGeneratorFunctionConstructor,
        .constructable = true,
    });
    async_gen_fn_ctor.asFunction().value.prototype = async_gen_fn_proto.retain();
    try async_gen_fn_proto.asObject().value.defineProperty("constructor", async_gen_fn_ctor, ro_cfg);
    try async_gen_fn_proto.asObject().value.defineProperty("prototype", async_gen_proto.retain(), ro_cfg);
    try async_gen_fn_proto.asObject().value.defineProperty(tag_key, try self.gcNewString("AsyncGeneratorFunction"), ro_cfg);
    self.protos.async_generator_proto = async_gen_proto;
    self.protos.async_generator_function_proto = async_gen_fn_proto;

    var async_fn_proto = try self.gcNewObject();
    if (self.protos.function.isObject()) {
        try async_fn_proto.asObject().value.setPrototype(&self.protos.function.asObject().value);
    }
    const async_fn_ctor = try self.gcNewFunction(.{
        .ctx = self,
        .name = "AsyncFunction",
        .arity = 1,
        .call = fn_builtins.asyncFunctionConstructor,
        .constructable = true,
    });
    async_fn_ctor.asFunction().value.prototype = async_fn_proto.retain();
    try async_fn_proto.asObject().value.defineProperty("constructor", async_fn_ctor, ro_cfg);
    try async_fn_proto.asObject().value.defineProperty(tag_key, try self.gcNewString("AsyncFunction"), ro_cfg);
    self.protos.async_function_proto = async_fn_proto;

    var arr_iter_proto = try self.gcNewObject();
    try arr_iter_proto.asObject().value.setPrototype(&proto.asObject().value);
    try defineMethod(self, arr_iter_proto, "next", 0, builtin_helpers.arrayIterProtoNext);
    var map_iter_proto = try self.gcNewObject();
    try map_iter_proto.asObject().value.setPrototype(&proto.asObject().value);
    try defineMethod(self, map_iter_proto, "next", 0, builtin_helpers.mapIterProtoNext);
    var set_iter_proto = try self.gcNewObject();
    try set_iter_proto.asObject().value.setPrototype(&proto.asObject().value);
    try defineMethod(self, set_iter_proto, "next", 0, builtin_helpers.setIterProtoNext);
    var str_iter_proto = try self.gcNewObject();
    try str_iter_proto.asObject().value.setPrototype(&proto.asObject().value);
    try defineMethod(self, str_iter_proto, "next", 0, builtin_helpers.stringIterProtoNext);
    if (self.symbol_to_string_tag) |tsym| {
        const tkey = try self.encodeKey(tsym);
        defer self.gc_allocator.free(tkey);
        const tag_desc = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = true };
        try arr_iter_proto.asObject().value.defineProperty(tkey, try self.gcNewString("Array Iterator"), tag_desc);
        try map_iter_proto.asObject().value.defineProperty(tkey, try self.gcNewString("Map Iterator"), tag_desc);
        try set_iter_proto.asObject().value.defineProperty(tkey, try self.gcNewString("Set Iterator"), tag_desc);
        try str_iter_proto.asObject().value.defineProperty(tkey, try self.gcNewString("String Iterator"), tag_desc);
    }
    self.protos.array_iterator_proto = arr_iter_proto;
    self.protos.map_iterator_proto = map_iter_proto;
    self.protos.set_iterator_proto = set_iter_proto;
    self.protos.string_iterator_proto = str_iter_proto;
}
