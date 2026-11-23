//! Step 5 Phase C batch 7: the binding+iter cluster -- destructuring/
//! binding-pattern initialization, destructuring assignment, for-in/
//! for-of iteration, and the iterator-protocol helpers (resolveIterator/
//! drainIterator/iterableItems/yield*). Split out of interpreter.zig;
//! see z-interpreter-refactor.md.

const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zstring = @import("zstring");

const coercion = @import("coercion.zig");
const builtins = @import("builtins.zig");
const array_builtins = @import("array_builtins.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Completion = interpreter_mod.Completion;
const FiberState = interpreter_mod.FiberState;

pub fn isIntactArrayIterator(self: *Interpreter, value: JSValue) bool {
    if (!value.isArray()) return false;
    const sym = self.symbol_iterator orelse return true;
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\x00S{x}", .{@intFromPtr(sym.asSymbol())}) catch return false;
    if (self.array_props.get(@intFromPtr(value.asArray()))) |bag| {
        if (bag.asObject().value.getOwnRecord(key) != null) return false;
    }
    if (!self.protos.array.isObject()) return false;
    const rec = self.protos.array.asObject().value.getOwnRecord(key) orelse return false;
    if (rec.isAccessor()) return false;
    if (!rec.value.isFunction()) return false;
    return rec.value.asFunction().value.call == array_builtins.arrayValues;
}

/// The source side of array destructuring, shared by binding patterns
/// and destructuring assignment: the same narrowed iterables as for-of
/// (arrays by element, strings by code point); anything else is the
/// real TypeError Node raises.
/// Every branch returns a FRESH, caller-owned slice (the container
/// only -- the `JSValue`s inside are the same already-alive
/// references the source held, not retained here; callers `.retain()`
/// individually wherever they actually store one). Callers must
/// free the returned slice with `self.gc_allocator.free(...)` once
/// done. The `.array` case dupes rather than returning
/// `box.value.toSlice()`'s borrowed slice directly -- a single
/// uniform contract across every branch, same reasoning as
/// `ownEnumerableKeys`/`freeOwnedKeys`'s always-owned contract.
///
/// Ownership is mixed (pre-existing, not fixed): array and set sources
/// hand back BORROWED elements, string, map and iterator sources OWNED
/// ones (fresh strings, fresh pairs, drained values). Callers that
/// retain every item are right for the borrowed case and leak for the
/// owned one.
pub fn iterableItems(self: *Interpreter, value: JSValue) anyerror![]const JSValue {
    const arena = self.gc_allocator;
    return switch (value.unpack()) {
        .array => |box| blk: {
            if (!isIntactArrayIterator(self, value)) {
                break :blk try self.drainIterator(try self.resolveIterator(value));
            }
            const src = box.value.toSlice();
            const out = try arena.alloc(JSValue, src.len);
            @memcpy(out, src);
            break :blk out;
        },
        .string => |box| blk: {
            var cps: std.ArrayList(JSValue) = .empty;
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                try cps.append(arena, try self.gcNewString(cp));
            }
            break :blk try cps.toOwnedSlice(arena);
        },
        // A user iterable (Symbol.iterator) or a hand-written iterator
        // (duck-typed `next`) -- drained fully.
        .object => try self.drainIterator(try self.resolveIterator(value)),
        // Sets iterate their values; Maps their [key, value] pairs --
        // so `[...set]`, `Array.from(map)`, `f(...set)` all work.
        .set => |box| blk: {
            const vals = box.value.values();
            const out = try arena.alloc(JSValue, vals.len);
            for (vals, 0..) |v, i| out[i] = v;
            break :blk out;
        },
        .map => |box| blk: {
            const ks = box.value.keys();
            const vs = box.value.values();
            var out: std.ArrayList(JSValue) = .empty;
            for (ks, vs) |k, v| {
                var pair = try self.gcNewArray();
                _ = try pair.asArray().value.push(k.retain());
                _ = try pair.asArray().value.push(v.retain());
                try out.append(arena, pair);
            }
            break :blk try out.toOwnedSlice(arena);
        },
        // Structurally recognized like array/set/map above (no
        // Symbol.iterator lookup) -- needed for `[...ta]`/`for...of`/
        // `Array.from(ta)` AND for this engine's own TypedArray
        // constructors' iterable-source overload
        // (`new Int32Array(new Uint8Array([1,2,3]))`).
        .typed_array => |box| blk: {
            const out = try arena.alloc(JSValue, box.value.len);
            var i: usize = 0;
            while (i < box.value.len) : (i += 1) {
                out[i] = try builtins.typedElemGet(self, box.value.kind, &box.value.owner.asArrayBuffer().value, box.value.byte_offset, box.value.len, i);
            }
            break :blk out;
        },
        else => self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()}),
    };
}

fn isCallableVal(v: JSValue) bool {
    return switch (v.unpack()) {
        .function => true,
        .proxy => |box| isCallableVal(box.value.target),
        else => false,
    };
}

pub const ResolvedAsyncIter = struct {
    iter: JSValue,
    is_async: bool,
};

/// ECMA-262 GetIterator(obj, sync): strictly calls GetMethod(obj, @@iterator).
/// Throws TypeError if @@iterator is neither undefined/null nor callable, or
/// if undefined/null (no `.next` duck-typing fallback).
pub fn resolveIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
    const sym = self.symbol_iterator orelse return self.throwError(.type_error, "{s} is not iterable", .{obj.typeOf()});
    const key = try self.encodeKey(sym);
    defer self.gc_allocator.free(key);
    const method = try self.getProperty(obj, key);
    defer method.deinit();
    if (method.isUndefined() or method.isNull()) {
        return self.throwError(.type_error, "{s} is not iterable", .{obj.typeOf()});
    }
    if (!isCallableVal(method)) {
        return self.throwError(.type_error, "Symbol.iterator is not a function", .{});
    }
    const iter = try self.callValue(method, obj, &.{}, "[Symbol.iterator]");
    errdefer iter.deinit();
    if (!@import("builtin_helpers.zig").isObjectLike(iter)) {
        return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
    }
    return iter;
}

/// ECMA-262 GetIterator(obj, async): checks GetMethod(obj, @@asyncIterator)
/// strictly (throwing TypeError if non-nullish and non-callable without
/// falling back to @@iterator), and falls back to resolveIterator only when
/// @@asyncIterator is undefined or null.
pub fn resolveAsyncIteratorDetail(self: *Interpreter, obj: JSValue) anyerror!ResolvedAsyncIter {
    if (self.symbol_async_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        const method = try self.getProperty(obj, key);
        defer method.deinit();
        if (!method.isUndefined() and !method.isNull()) {
            if (!isCallableVal(method)) {
                return self.throwError(.type_error, "Symbol.asyncIterator is not a function", .{});
            }
            const iter = try self.callValue(method, obj, &.{}, "[Symbol.asyncIterator]");
            errdefer iter.deinit();
            if (!@import("builtin_helpers.zig").isObjectLike(iter)) {
                return self.throwError(.type_error, "Result of the Symbol.asyncIterator method is not an object", .{});
            }
            return .{ .iter = iter, .is_async = true };
        }
    }
    return .{ .iter = try self.resolveIterator(obj), .is_async = false };
}

pub fn resolveAsyncIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
    return (try self.resolveAsyncIteratorDetail(obj)).iter;
}

/// Runs an iterator object to completion, collecting its values.
pub fn drainIterator(self: *Interpreter, iter: JSValue) anyerror![]const JSValue {
    const arena = self.gc_allocator;
    const next_fn = try self.getProperty(iter, "next");
    defer next_fn.deinit();
    if (!isCallableVal(next_fn)) return self.throwError(.type_error, "iterator.next is not a function", .{});
    var out: std.ArrayList(JSValue) = .empty;
    errdefer {
        for (out.items) |it| it.deinit();
        out.deinit(arena);
    }
    while (true) {
        const step = try self.callValue(next_fn, iter, &.{}, "next");
        defer step.deinit();
        if (!@import("builtin_helpers.zig").isObjectLike(step)) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
        const done = try self.getProperty(step, "done");
        defer done.deinit();
        if (coercion.isTruthy(done)) break;
        try out.append(arena, try self.getProperty(step, "value"));
    }
    return out.toOwnedSlice(arena);
}

fn iteratorComplete(self: *Interpreter, step: JSValue) anyerror!bool {
    const done = try self.getProperty(step, "done");
    defer done.deinit();
    return coercion.isTruthy(done);
}

fn awaitValueAndDeinit(self: *Interpreter, fs: *FiberState, val: JSValue) anyerror!JSValue {
    const aw = self.awaitValue(fs, val) catch |err| {
        val.deinit();
        return err;
    };
    val.deinit();
    return aw;
}

/// `yield* iterable`: ECMA-262 15.5.5 spec-compliant delegation for both sync
/// and async generators, forwarding `.next(v)`, `.throw(e)` (closing the
/// inner iterator and raising TypeError if `.throw` is missing), and
/// `.return(v)`.
pub fn evalYieldDelegate(self: *Interpreter, env: *Environment, fs: *FiberState, arg_node: *zparser.Node) anyerror!JSValue {
    const arena = self.gc_allocator;
    const iterable = try self.evalExpression(env, arg_node);
    defer iterable.deinit();

    // Fast path for built-in non-object iterables (strings, sets, maps,
    // typed arrays, and intact arrays in sync generators).
    const use_builtin_fast = !fs.is_async and (isIntactArrayIterator(self, iterable) or iterable.isString() or iterable.isSet() or iterable.isMap() or iterable.isTypedArray());
    if (use_builtin_fast or (!iterable.isObject() and !iterable.isArray() and (iterable.isString() or iterable.isSet() or iterable.isMap() or iterable.isTypedArray()))) {
        const items = try self.iterableItems(iterable);
        defer arena.free(items);
        for (items) |item| {
            var v = item.retain();
            if (fs.is_async) v = try awaitValueAndDeinit(self, fs, v);
            fs.yielded = v;
            fs.fiber.suspendSelf();
            if (fs.resume_is_return) {
                fs.resume_is_return = false;
                if (self.pending_return) |pr| pr.deinit();
                var rv = fs.takeResumeValue();
                if (fs.is_async) rv = try awaitValueAndDeinit(self, fs, rv);
                self.pending_return = rv;
                return error.JsReturn;
            }
            if (fs.resume_is_throw) {
                fs.resume_is_throw = false;
                fs.takeResumeValue().deinit();
                return self.throwError(.type_error, "The iterator does not provide a 'throw' method", .{});
            }
            fs.takeResumeValue().deinit();
        }
        return JSValue.UNDEFINED;
    }

    if (!@import("builtin_helpers.zig").isObjectLike(iterable)) {
        return self.throwError(.type_error, "{s} is not iterable", .{iterable.typeOf()});
    }

    const resolved = if (fs.is_async)
        try resolveAsyncIteratorDetail(self, iterable)
    else
        ResolvedAsyncIter{ .iter = try self.resolveIterator(iterable), .is_async = false };
    const iter = resolved.iter;
    defer iter.deinit();
    const is_async_iter = resolved.is_async;

    const next_fn = try self.getProperty(iter, "next");
    defer next_fn.deinit();

    const ResumeKind = enum { normal, throw, @"return" };
    var resume_kind: ResumeKind = .normal;
    var resume_val: JSValue = JSValue.UNDEFINED;
    defer resume_val.deinit();

    while (true) {
        var inner_result: JSValue = undefined;
        var close_on_sync_reject = false;
        switch (resume_kind) {
            .normal => {
                if (!isCallableVal(next_fn)) {
                    return self.throwError(.type_error, "iterator.next is not a function", .{});
                }
                inner_result = try self.callValue(next_fn, iter, &.{resume_val}, "next");
                close_on_sync_reject = true;
            },
            .throw => {
                const throw_fn = try self.getProperty(iter, "throw");
                defer throw_fn.deinit();
                if (throw_fn.isUndefined() or throw_fn.isNull()) {
                    if (fs.is_async and is_async_iter) {
                        try closeAsyncIteratorNormal(self, fs, iter);
                    } else {
                        try closeIterator(self, iter);
                    }
                    return self.throwError(.type_error, "The iterator does not provide a 'throw' method", .{});
                }
                if (!isCallableVal(throw_fn)) {
                    return self.throwError(.type_error, "iterator.throw is not a function", .{});
                }
                inner_result = try self.callValue(throw_fn, iter, &.{resume_val}, "throw");
                close_on_sync_reject = true;
            },
            .@"return" => {
                const return_fn = try self.getProperty(iter, "return");
                defer return_fn.deinit();
                if (return_fn.isUndefined() or return_fn.isNull()) {
                    if (fs.is_async) {
                        resume_val = try awaitValueAndDeinit(self, fs, resume_val);
                    }
                    if (self.pending_return) |pr| pr.deinit();
                    self.pending_return = resume_val;
                    resume_val = JSValue.UNDEFINED;
                    return error.JsReturn;
                }
                if (!isCallableVal(return_fn)) {
                    return self.throwError(.type_error, "iterator.return is not a function", .{});
                }
                inner_result = try self.callValue(return_fn, iter, &.{resume_val}, "return");
                close_on_sync_reject = false;
            },
        }
        if (fs.is_async and is_async_iter) {
            inner_result = try awaitValueAndDeinit(self, fs, inner_result);
        }
        defer inner_result.deinit();
        if (!@import("builtin_helpers.zig").isObjectLike(inner_result)) {
            return self.throwError(.type_error, "Iterator result {s} is not an object", .{inner_result.typeOf()});
        }
        const done = try iteratorComplete(self, inner_result);
        var val = try self.getProperty(inner_result, "value");
        if (done) {
            if (fs.is_async and !is_async_iter) {
                val = try awaitValueAndDeinit(self, fs, val);
            }
            if (resume_kind == .@"return") {
                if (self.pending_return) |pr| pr.deinit();
                self.pending_return = val;
                return error.JsReturn;
            }
            return val;
        }
        if (fs.is_async and !is_async_iter) {
            const aw = self.awaitValue(fs, val) catch |err| {
                val.deinit();
                if (close_on_sync_reject) {
                    if (err == error.JsReturn) {
                        try closeIteratorOnReturn(self, iter);
                    } else {
                        closeIteratorOnThrow(self, iter);
                    }
                }
                return err;
            };
            val.deinit();
            val = aw;
        }
        fs.yielded = val;
        fs.fiber.suspendSelf();
        if (fs.resume_is_return) {
            fs.resume_is_return = false;
            resume_kind = .@"return";
        } else if (fs.resume_is_throw) {
            fs.resume_is_throw = false;
            resume_kind = .throw;
        } else {
            resume_kind = .normal;
        }
        resume_val.deinit();
        resume_val = fs.takeResumeValue();
    }
}

/// How bindPattern lands a name: `.define` creates the binding in
/// `env` (let/const/params/catch); `.assign` writes to an existing
/// binding up the chain -- `var` declarators, whose bindings the
/// hoisting pre-pass already created at function scope.
const BindMode = enum { define, assign };

/// Recursive BindingInitialization (ECMA-262 8.6.2) -- every binding
/// position (declarators, params, catch, for-in/of declared bindings)
/// funnels here. Destructuring as an assignment target (`[a, b] =
/// arr` without a declaration) is separate machinery (phase 8b), not
/// this. Defaults are evaluated in `env` itself, so a later element's
/// default can reference an earlier binding (`[a, b = a]` -- real
/// spec order). Ownership: the caller keeps its reference to `value`;
/// identifier bindings retain. Tried making this a straight ownership
/// TRANSFER instead (uniform-ownership-contract.md, Etapa 2) -- broke
/// callers that pass native-call arguments through bindPattern (e.g.
/// function parameters bound from `args[]`) and then free their OWN
/// copy of those same arguments afterward, a widespread, pre-existing
/// convention across builtins (confirmed: string_builtins.zig's
/// replace callback explicitly `.deinit()`s every `call_args` entry
/// after the call). Reverted -- the retain here is load-bearing, not
/// redundant, given that wider convention.
pub const DestructureResult = struct {
    items: []const JSValue,
    iter_to_close: ?JSValue = null,
};

pub fn getDestructureItems(self: *Interpreter, arena: std.mem.Allocator, value: JSValue, count: usize, has_rest: bool) anyerror!DestructureResult {
    if (value.isArray() and isIntactArrayIterator(self, value)) {
        const src = value.asArray().value.toSlice();
        const out = try arena.alloc(JSValue, src.len);
        @memcpy(out, src);
        return .{ .items = out };
    }
    if (value.isString() or value.isSet() or value.isMap() or value.isTypedArray()) {
        const out = try self.iterableItems(value);
        return .{ .items = out };
    }
    if (value.isObject() or value.isArray()) {
        const iter = try self.resolveIterator(value);
        const next_fn = try self.getProperty(iter, "next");
        if (!next_fn.isFunction()) return self.throwError(.type_error, "iterator.next is not a function", .{});
        var list: std.ArrayList(JSValue) = .empty;
        errdefer {
            for (list.items) |item| item.deinit();
            list.deinit(arena);
        }
        var done = false;
        while (!done) {
            if (!has_rest and list.items.len >= count) break;
            const step = try next_fn.asFunction().value.call(next_fn.asFunction().value.ctx, arena, iter, &.{});
            if (!step.isObject()) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
            done = coercion.isTruthy(try self.getProperty(step, "done"));
            if (done) break;
            try list.append(arena, try self.getProperty(step, "value"));
        }
        const iter_to_close: ?JSValue = if (!has_rest and !done) iter else null;
        return .{
            .items = try list.toOwnedSlice(arena),
            .iter_to_close = iter_to_close,
        };
    }
    return self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()});
}

fn closeIteratorOnThrow(self: *Interpreter, iterator: JSValue) void {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer self.pending_exception = saved;
    closeIterator(self, iterator) catch {
        if (self.pending_exception) |ie| ie.deinit();
        self.pending_exception = null;
    };
}

fn closeIteratorOnReturn(self: *Interpreter, iterator: JSValue) anyerror!void {
    const saved_ret = self.pending_return;
    self.pending_return = null;
    closeIterator(self, iterator) catch |err| {
        if (saved_ret) |sr| sr.deinit();
        return err;
    };
    self.pending_return = saved_ret;
}

fn stepIteratorValue(self: *Interpreter, arena: std.mem.Allocator, iter: JSValue, next_fn: JSValue, iterator_done: *bool) anyerror!JSValue {
    if (iterator_done.*) return JSValue.UNDEFINED;
    const step = next_fn.asFunction().value.call(next_fn.asFunction().value.ctx, arena, iter, &.{}) catch |err| {
        iterator_done.* = true;
        return err;
    };
    defer step.deinit();
    if (!@import("builtin_helpers.zig").isObjectLike(step)) {
        iterator_done.* = true;
        return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
    }
    const done_val = self.getProperty(step, "done") catch |err| {
        iterator_done.* = true;
        return err;
    };
    const is_done = coercion.isTruthy(done_val);
    done_val.deinit();
    if (is_done) {
        iterator_done.* = true;
        return JSValue.UNDEFINED;
    }
    return self.getProperty(step, "value") catch |err| {
        iterator_done.* = true;
        return err;
    };
}

pub fn copyDataProperties(self: *Interpreter, arena: std.mem.Allocator, target: JSValue, source: JSValue, excluded: []const []const u8) anyerror!void {
    if (source.isUndefined() or source.isNull()) return;
    const property_desc = @import("property_desc.zig");
    const object_builtins = @import("object_builtins.zig");
    const from = try property_desc.toObject(self, source);
    defer from.deinit();
    const keys = try object_builtins.ownPropertyKeyList(self, arena, from);
    defer object_builtins.freeOwnedKeys(arena, keys);
    outer: for (keys) |k| {
        if (k.len >= 2 and k[0] == 0 and k[1] == 'P') continue;
        for (excluded) |ex| {
            if (std.mem.eql(u8, ex, k)) continue :outer;
        }
        const kv = try property_desc.keyToValue(self, k);
        defer kv.deinit();
        const desc = try object_builtins.objectGetOwnPropertyDescriptor(self, arena, JSValue.UNDEFINED, &.{ from, kv });
        defer desc.deinit();
        if (desc.isObject()) {
            if (desc.asObject().value.get("enumerable")) |en| {
                if (coercion.isTruthy(en)) {
                    const prop_val = try self.getProperty(from, k);
                    try target.objectDefine(k, prop_val, .{ .writable = true, .enumerable = true, .configurable = true });
                }
            }
        }
    }
}

pub fn bindPattern(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern, value: JSValue, mode: BindMode) anyerror!void {

    const arena = self.gc_allocator;
    switch (pattern.*) {
        .identifier => |id| {
            const v = value.retain();
            switch (mode) {
                .define => try env.define(arena, id.name, v),
                // The pre-pass defined every var name; the fallback
                // define is belt-and-braces, not a real path.
                .assign => env.assign(id.name, v) catch try env.define(arena, id.name, v),
            }
        },
        .array => |arr_pat| {
            if (isIntactArrayIterator(self, value) or value.isString() or value.isSet() or value.isMap() or value.isTypedArray()) {
                const items = try self.iterableItems(value);
                defer arena.free(items);
                for (arr_pat.elements, 0..) |maybe_el, i| {
                    const el = maybe_el orelse continue; // elision hole
                    var v = if (i < items.len) items[i] else JSValue.UNDEFINED;
                    var from_default = false;
                    defer if (from_default) v.deinit();
                    if (v.isUndefined()) {
                        if (el.default) |def| {
                            v = try self.evalExpression(env, def);
                            from_default = true;
                            if (el.pattern.* == .identifier) {
                                try self.maybeNameAnonymousValue(def, v, el.pattern.identifier.name);
                            }
                        }
                    }
                    try self.bindPattern(env, el.pattern, v, mode);
                }
                if (arr_pat.rest) |rest_pat| {
                    var rest_arr = try self.gcNewArray();
                    defer rest_arr.deinit();
                    if (arr_pat.elements.len < items.len) {
                        for (items[arr_pat.elements.len..]) |item| {
                            _ = try rest_arr.asArray().value.push(item.retain());
                        }
                    }
                    try self.bindPattern(env, rest_pat, rest_arr, mode);
                }
                return;
            }
            if (!@import("builtin_helpers.zig").isObjectLike(value)) {
                return self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()});
            }
            const iter = try self.resolveIterator(value);
            defer iter.deinit();
            const next_fn = try self.getProperty(iter, "next");
            defer next_fn.deinit();
            if (!next_fn.isFunction()) return self.throwError(.type_error, "iterator.next is not a function", .{});
            var iterator_done = false;
            errdefer {
                if (!iterator_done) {
                    iterator_done = true;
                    closeIteratorOnThrow(self, iter);
                }
            }
            for (arr_pat.elements) |maybe_el| {
                var v = try stepIteratorValue(self, arena, iter, next_fn, &iterator_done);
                defer v.deinit();
                const el = maybe_el orelse continue; // elision hole still steps iterator
                if (v.isUndefined()) {
                    if (el.default) |def| {
                        v = self.evalExpression(env, def) catch |err| {
                            if (err == error.JsReturn and !iterator_done) {
                                iterator_done = true;
                                try closeIteratorOnReturn(self, iter);
                            }
                            return err;
                        };
                        if (el.pattern.* == .identifier) {
                            try self.maybeNameAnonymousValue(def, v, el.pattern.identifier.name);
                        }
                    }
                }
                self.bindPattern(env, el.pattern, v, mode) catch |err| {
                    if (err == error.JsReturn and !iterator_done) {
                        iterator_done = true;
                        try closeIteratorOnReturn(self, iter);
                    }
                    return err;
                };
            }
            if (arr_pat.rest) |rest_pat| {
                var rest_arr = try self.gcNewArray();
                defer rest_arr.deinit();
                while (!iterator_done) {
                    const item = try stepIteratorValue(self, arena, iter, next_fn, &iterator_done);
                    if (iterator_done) {
                        item.deinit();
                        break;
                    }
                    _ = try rest_arr.asArray().value.push(item);
                }
                self.bindPattern(env, rest_pat, rest_arr, mode) catch |err| {
                    if (err == error.JsReturn and !iterator_done) {
                        iterator_done = true;
                        try closeIteratorOnReturn(self, iter);
                    }
                    return err;
                };
            }
            if (!iterator_done) {
                iterator_done = true;
                try closeIterator(self, iter);
            }
        },
        .object => |obj_pat| {
            if (value.isUndefined() or value.isNull()) {
                const what: []const u8 = if (value.isNull()) "null" else "undefined";
                if (obj_pat.properties.len > 0 and obj_pat.properties[0].computed_key == null) {
                    return self.throwError(.type_error, "Cannot destructure property '{s}' of '{s}' as it is {s}.", .{ obj_pat.properties[0].key, what, what });
                }
                return self.throwError(.type_error, "Cannot destructure '{s}' as it is {s}.", .{ what, what });
            }
            var excluded_keys: std.ArrayList(Interpreter.PropKey) = .empty;
            defer {
                for (excluded_keys.items) |pk| pk.free(arena);
                excluded_keys.deinit(arena);
            }
            // getProperty is the whole point of the reuse: string
            // `.length`, error `.message`, prototype-chain lookups on
            // objects -- all already live there.
            for (obj_pat.properties) |prop| {
                const pk: Interpreter.PropKey = if (prop.computed_key) |ck| blk: {
                    const kv = try self.evalExpression(env, ck);
                    defer kv.deinit();
                    break :blk .{ .key = try self.encodeKey(kv), .owned = true };
                } else .{ .key = prop.key, .owned = false };
                var pk_stored = false;
                defer if (!pk_stored) pk.free(arena);
                if (obj_pat.rest != null) {
                    try excluded_keys.append(arena, pk);
                    pk_stored = true;
                }
                var v = try self.getProperty(value, pk.key);
                // Owned either way (getProperty's, or the default's) and
                // bindPattern retains what it binds: always released here.
                defer v.deinit();
                if (v.isUndefined()) {
                    if (prop.default) |def| {
                        v = try self.evalExpression(env, def);
                        // NamedEvaluation: `{a = AnonFn}` names it "a".
                        if (prop.value.* == .identifier) {
                            try self.maybeNameAnonymousValue(def, v, prop.value.identifier.name);
                        }
                    }
                }
                try self.bindPattern(env, prop.value, v, mode);
            }
            if (obj_pat.rest) |rest_name| {
                var rest_obj = try self.ordinaryObject();
                errdefer rest_obj.deinit();
                var excl = try arena.alloc([]const u8, excluded_keys.items.len);
                defer arena.free(excl);
                for (excluded_keys.items, 0..) |pk, pi| excl[pi] = pk.key;
                try copyDataProperties(self, arena, rest_obj, value, excl);
                switch (mode) {
                    .define => try env.define(arena, rest_name.name, rest_obj),
                    .assign => env.assign(rest_name.name, rest_obj) catch try env.define(arena, rest_name.name, rest_obj),
                }
            }
        },
    }
}

/// Destructuring *assignment* (ECMA-262 13.15.5
/// DestructuringAssignmentEvaluation): the target is an array/object
/// *literal* node reinterpreted as a pattern -- already validated at
/// parse time by z-parser's isValidAssignmentPattern, so the shapes
/// seen here are exactly the valid ones. Mirrors bindPattern's source
/// semantics (iterableItems, getProperty lookups, defaults only on
/// undefined), but every leaf goes through assignTo -- which is what
/// makes member-expression targets (`[o.x] = [1]`) work, something
/// BindingPattern can't even represent.
const PreEvalMember = struct {
    obj: JSValue,
    pk: ?Interpreter.PropKey = null,
    private_name: ?[]const u8 = null,

    fn deinit(self: PreEvalMember, allocator: std.mem.Allocator) void {
        self.obj.deinit();
        if (self.pk) |pk| pk.free(allocator);
    }
};

fn unwrapParenNode(node: *zparser.Node) *zparser.Node {
    var cur = node;
    while (cur.data == .paren) cur = cur.data.paren;
    return cur;
}

fn preEvaluateMemberTarget(self: *Interpreter, env: *Environment, target_node: *zparser.Node) anyerror!?PreEvalMember {
    const unwrapped = unwrapParenNode(target_node);
    if (unwrapped.data != .member) return null;
    const m = unwrapped.data.member;
    const obj = try self.evalExpression(env, m.object);
    errdefer obj.deinit();
    if (!m.computed and m.property.data == .identifier) {
        const id_name = m.property.data.identifier;
        if (id_name.len > 0 and id_name[0] == '#') {
            return .{ .obj = obj, .private_name = id_name };
        }
    }
    const pk = try self.memberKeyString(env, m);
    return .{ .obj = obj, .pk = pk };
}

fn assignToPreEvalMember(self: *Interpreter, env: *Environment, pre: PreEvalMember, value: JSValue) anyerror!void {
    if (pre.private_name) |pn| {
        return self.privateSet(env, pre.obj, pn, value);
    }
    return self.setPropertyOnValue(pre.obj, pre.pk.?.key, value);
}

pub fn destructuringAssign(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
    const arena = self.gc_allocator;
    switch (target.data) {
        .array_literal => |elements| {
            if (isIntactArrayIterator(self, value) or value.isString() or value.isSet() or value.isMap() or value.isTypedArray()) {
                const items = try self.iterableItems(value);
                defer arena.free(items);
                for (elements, 0..) |maybe_el, i| {
                    const el = maybe_el orelse continue; // hole still consumes its index
                    if (el.data == .spread) {
                        const rest_target = el.data.spread;
                        const pre_member = try preEvaluateMemberTarget(self, env, rest_target);
                        defer if (pre_member) |pm| pm.deinit(arena);
                        var rest_arr = try self.gcNewArray();
                        defer rest_arr.deinit();
                        if (i < items.len) {
                            for (items[i..]) |item| _ = try rest_arr.asArray().value.push(item.retain());
                        }
                        if (pre_member) |pm| {
                            try assignToPreEvalMember(self, env, pm, rest_arr);
                        } else {
                            try self.destructuringAssignTarget(env, rest_target, rest_arr);
                        }
                        break;
                    }
                    var el_target = el;
                    var default_node: ?*zparser.Node = null;
                    if (el.data == .assignment and el.data.assignment.op == .assign) {
                        default_node = el.data.assignment.value;
                        el_target = el.data.assignment.target;
                    }
                    const pre_member = try preEvaluateMemberTarget(self, env, el_target);
                    defer if (pre_member) |pm| pm.deinit(arena);
                    var v = if (i < items.len) items[i] else JSValue.UNDEFINED;
                    var from_default = false;
                    defer if (from_default) v.deinit();
                    if (v.isUndefined()) {
                        if (default_node) |def| {
                            v = try self.evalExpression(env, def);
                            from_default = true;
                            if (el_target.data == .identifier) {
                                try self.maybeNameAnonymousValue(def, v, el_target.data.identifier);
                            }
                        }
                    }
                    if (pre_member) |pm| {
                        try assignToPreEvalMember(self, env, pm, v);
                    } else {
                        try self.destructuringAssignTarget(env, el_target, v);
                    }
                }
                return;
            }
            if (!@import("builtin_helpers.zig").isObjectLike(value)) {
                return self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()});
            }
            const iter = try self.resolveIterator(value);
            defer iter.deinit();
            const next_fn = try self.getProperty(iter, "next");
            defer next_fn.deinit();
            if (!next_fn.isFunction()) return self.throwError(.type_error, "iterator.next is not a function", .{});
            var iterator_done = false;
            for (elements) |maybe_el| {
                if (maybe_el == null) {
                    const v = try stepIteratorValue(self, arena, iter, next_fn, &iterator_done);
                    v.deinit();
                    continue;
                }
                const el = maybe_el.?;
                if (el.data == .spread) {
                    const rest_target = el.data.spread;
                    const pre_member = preEvaluateMemberTarget(self, env, rest_target) catch |err| {
                        if (!iterator_done) {
                            iterator_done = true;
                            if (err == error.JsReturn) try closeIteratorOnReturn(self, iter) else closeIteratorOnThrow(self, iter);
                        }
                        return err;
                    };
                    defer if (pre_member) |pm| pm.deinit(arena);
                    var rest_arr = try self.gcNewArray();
                    defer rest_arr.deinit();
                    while (!iterator_done) {
                        const item = try stepIteratorValue(self, arena, iter, next_fn, &iterator_done);
                        if (iterator_done) {
                            item.deinit();
                            break;
                        }
                        _ = try rest_arr.asArray().value.push(item);
                    }
                    if (pre_member) |pm| {
                        try assignToPreEvalMember(self, env, pm, rest_arr);
                    } else {
                        try self.destructuringAssignTarget(env, rest_target, rest_arr);
                    }
                    break;
                }
                var el_target = el;
                var default_node: ?*zparser.Node = null;
                if (el.data == .assignment and el.data.assignment.op == .assign) {
                    default_node = el.data.assignment.value;
                    el_target = el.data.assignment.target;
                }
                const pre_member = preEvaluateMemberTarget(self, env, el_target) catch |err| {
                    if (!iterator_done) {
                        iterator_done = true;
                        if (err == error.JsReturn) try closeIteratorOnReturn(self, iter) else closeIteratorOnThrow(self, iter);
                    }
                    return err;
                };
                defer if (pre_member) |pm| pm.deinit(arena);
                var v = try stepIteratorValue(self, arena, iter, next_fn, &iterator_done);
                defer v.deinit();
                if (v.isUndefined()) {
                    if (default_node) |def| {
                        v = self.evalExpression(env, def) catch |err| {
                            if (!iterator_done) {
                                iterator_done = true;
                                if (err == error.JsReturn) try closeIteratorOnReturn(self, iter) else closeIteratorOnThrow(self, iter);
                            }
                            return err;
                        };
                        if (el_target.data == .identifier) {
                            try self.maybeNameAnonymousValue(def, v, el_target.data.identifier);
                        }
                    }
                }
                if (pre_member) |pm| {
                    assignToPreEvalMember(self, env, pm, v) catch |err| {
                        if (!iterator_done) {
                            iterator_done = true;
                            if (err == error.JsReturn) try closeIteratorOnReturn(self, iter) else closeIteratorOnThrow(self, iter);
                        }
                        return err;
                    };
                } else {
                    self.destructuringAssignTarget(env, el_target, v) catch |err| {
                        if (!iterator_done) {
                            iterator_done = true;
                            if (err == error.JsReturn) try closeIteratorOnReturn(self, iter) else closeIteratorOnThrow(self, iter);
                        }
                        return err;
                    };
                }
            }
            if (!iterator_done) {
                iterator_done = true;
                try closeIterator(self, iter);
            }
        },
        .object_literal => |elements| {
            if (value.isUndefined() or value.isNull()) {
                const what: []const u8 = if (value.isNull()) "null" else "undefined";
                const first_key: ?[]const u8 = for (elements) |el| {
                    switch (el) {
                        .property => |p| if (!p.computed and p.key.data == .identifier) break p.key.data.identifier,
                        .spread => {},
                    }
                } else null;
                if (first_key) |k| {
                    return self.throwError(.type_error, "Cannot destructure property '{s}' of '{s}' as it is {s}.", .{ k, what, what });
                }
                return self.throwError(.type_error, "Cannot destructure '{s}' as it is {s}.", .{ what, what });
            }
            var consumed: std.ArrayList(Interpreter.PropKey) = .empty;
            defer {
                for (consumed.items) |pk| pk.free(arena);
                consumed.deinit(arena);
            }
            for (elements) |el| {
                switch (el) {
                    .property => |prop| {
                        const pk = try self.propertyKeyString(env, prop.computed, prop.key);
                        const key = pk.key;
                        try consumed.append(arena, pk);
                        var v = try self.getProperty(value, key);
                        var el_target = prop.value;
                        // Owned either way (getProperty's, or the
                        // default's) and assignTo retains what it stores:
                        // always released here.
                        defer v.deinit();
                        if (el_target.data == .assignment and el_target.data.assignment.op == .assign) {
                            const def = el_target.data.assignment.value;
                            el_target = el_target.data.assignment.target;
                            if (v.isUndefined()) {
                                v = try self.evalExpression(env, def);
                                if (el_target.data == .identifier) {
                                    try self.maybeNameAnonymousValue(def, v, el_target.data.identifier);
                                }
                            }
                        }
                        try self.destructuringAssignTarget(env, el_target, v);
                    },
                    .spread => |sp| {
                        const arg = sp.data.spread;
                        var rest_obj = try self.ordinaryObject();
                        defer rest_obj.deinit();
                        var excl = try arena.alloc([]const u8, consumed.items.len);
                        defer arena.free(excl);
                        for (consumed.items, 0..) |c, ci| excl[ci] = c.key;
                        try copyDataProperties(self, arena, rest_obj, value, excl);
                        try self.destructuringAssignTarget(env, arg, rest_obj);
                    },
                }
            }
        },
        else => unreachable, // only ever called with array/object literal targets
    }
}

/// One target position inside a destructuring assignment: nested
/// literals recurse as patterns; everything else (identifier, member,
/// paren-wrapped) is an ordinary assignment leaf.
pub fn destructuringAssignTarget(self: *Interpreter, env: *Environment, node: *zparser.Node, value: JSValue) anyerror!void {
    switch (node.data) {
        .array_literal, .object_literal => try self.destructuringAssign(env, node, value),
        else => try self.assignTo(env, node, value),
    }
}

/// Binds the loop variable for one for-in/for-of iteration. Declared
/// let/const bindings get a FRESH child env per iteration, so
/// closures created in the body capture that iteration's value (real
/// let/const semantics); `for (var x of ...)` assigns to the single
/// hoisted function-scope binding instead (real shared-var
/// semantics). Existing bindings assign into the enclosing scope
/// chain.
pub fn bindForIteration(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding, value: JSValue) anyerror!*Environment {
    switch (binding) {
        .declared => |d| {
            if (d.kind == .@"var") {
                try self.bindPattern(env, d.pattern, value, .assign);
                return env;
            }
            const iter_env = try self.gcChildEnv(env);
            try self.bindPattern(iter_env, d.pattern, value, .define);
            if (d.kind == .@"const") try self.markPatternConst(iter_env, d.pattern);
            return iter_env;
        },
        .existing => |name| {
            // env.assign takes ownership -- retain, matching bindPattern's
            // convention (the caller keeps its own reference to `value`).
            env.assign(name.name, value.retain()) catch |err| return switch (err) {
                error.ReferenceError => self.throwError(.reference_error, "{s} is not defined", .{name.name}),
                error.BeforeInitialization => self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name.name}),
                error.ImmutableBinding => self.throwError(.type_error, "Assignment to constant variable.", .{}),
            };
            return env;
        },
        // `for ([a, b] of x)` over existing bindings -- a destructuring
        // assignment per iteration, no fresh env.
        .existing_pattern => |node| {
            try self.destructuringAssignTarget(env, node, value);
            return env;
        },
    }
}

/// Runs one for-in/for-of iteration with the loop variable bound to
/// `value`. Returns null to proceed to the next iteration, or a
/// Completion the whole loop must deliver (an owned break converts to
/// normal-and-stop; everything else abrupt propagates).
pub fn forIterationStep(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding, value: JSValue, body: *zstatements.Statement, labels: []const []const u8) anyerror!?Completion {
    const iter_env = try self.bindForIteration(env, binding, value);
    const c = try self.evalStatement(iter_env, body);
    switch (c.type) {
        .break_completion => {
            if (Interpreter.loopOwns(c.target, labels)) return Completion{ .type = .normal, .value = c.value };
            return c;
        },
        .continue_completion => {
            if (!Interpreter.loopOwns(c.target, labels)) return c;
            return null;
        },
        .return_completion => return c,
        .normal => {
            c.value.deinit();
            return null;
        },
    }
}

pub fn closeIterator(self: *Interpreter, iterator: JSValue) anyerror!void {
    const ret = try self.getProperty(iterator, "return");
    defer ret.deinit();
    if (ret.isUndefined() or ret.isNull()) return;
    if (!isCallableVal(ret)) return self.throwError(.type_error, "iterator.return is not a function", .{});
    const r = try self.callValue(ret, iterator, &.{}, "return");
    defer r.deinit();
    if (!@import("builtin_helpers.zig").isObjectLike(r)) return self.throwError(.type_error, "Iterator result {s} is not an object", .{r.typeOf()});
}

pub fn closeAsyncIteratorNormal(self: *Interpreter, fs: *FiberState, iterator: JSValue) anyerror!void {
    const ret = try self.getProperty(iterator, "return");
    defer ret.deinit();
    if (ret.isUndefined() or ret.isNull()) return;
    if (!isCallableVal(ret)) return self.throwError(.type_error, "iterator.return is not a function", .{});
    const raw = try self.callValue(ret, iterator, &.{}, "return");
    const r = self.awaitValue(fs, raw) catch |err| {
        raw.deinit();
        return err;
    };
    raw.deinit();
    defer r.deinit();
    if (!@import("builtin_helpers.zig").isObjectLike(r)) {
        return self.throwError(.type_error, "Iterator result {s} is not an object", .{r.typeOf()});
    }
}

fn closeAsyncIteratorOnThrow(self: *Interpreter, fs: *FiberState, iterator: JSValue) void {
    const saved = self.pending_exception;
    self.pending_exception = null;
    defer self.pending_exception = saved;
    closeAsyncIteratorNormal(self, fs, iterator) catch {
        if (self.pending_exception) |ie| ie.deinit();
        self.pending_exception = null;
    };
}

fn closeAsyncIteratorOnReturn(self: *Interpreter, fs: *FiberState, iterator: JSValue) anyerror!void {
    const saved_ret = self.pending_return;
    self.pending_return = null;
    closeAsyncIteratorNormal(self, fs, iterator) catch |err| {
        if (saved_ret) |sr| sr.deinit();
        return err;
    };
    self.pending_return = saved_ret;
}

fn evalForOfIterator(
    self: *Interpreter,
    env: *Environment,
    fs: ?*FiberState,
    is_await: bool,
    iterable: JSValue,
    binding: zstatements.ForBinding,
    body: *zstatements.Statement,
    labels: []const []const u8,
) anyerror!Completion {
    const resolved = if (is_await)
        try resolveAsyncIteratorDetail(self, iterable)
    else
        ResolvedAsyncIter{ .iter = try self.resolveIterator(iterable), .is_async = false };
    const iter = resolved.iter;
    defer iter.deinit();
    const next_fn = try self.getProperty(iter, "next");
    defer next_fn.deinit();
    if (!isCallableVal(next_fn)) {
        return self.throwError(.type_error, "iterator.next is not a function", .{});
    }
    while (true) {
        var step_result = try self.callValue(next_fn, iter, &.{}, "next");
        if (is_await and resolved.is_async) {
            const awaited = self.awaitValue(fs.?, step_result) catch |err| {
                step_result.deinit();
                return err;
            };
            step_result.deinit();
            step_result = awaited;
        }
        defer step_result.deinit();
        if (!@import("builtin_helpers.zig").isObjectLike(step_result)) {
            return self.throwError(.type_error, "Iterator result {s} is not an object", .{step_result.typeOf()});
        }
        const done = try self.getProperty(step_result, "done");
        defer done.deinit();
        if (coercion.isTruthy(done)) break;
        var value = try self.getProperty(step_result, "value");
        if (is_await and !resolved.is_async) {
            const awaited = self.awaitValue(fs.?, value) catch |err| {
                value.deinit();
                if (err == error.JsReturn) {
                    try closeIteratorOnReturn(self, iter);
                } else {
                    closeIteratorOnThrow(self, iter);
                }
                return err;
            };
            value.deinit();
            value = awaited;
        }
        const step = self.forIterationStep(env, binding, value, body, labels) catch |err| {
            value.deinit();
            if (err == error.JsReturn) {
                if (is_await and resolved.is_async) {
                    try closeAsyncIteratorOnReturn(self, fs.?, iter);
                } else {
                    try closeIteratorOnReturn(self, iter);
                }
            } else {
                if (is_await and resolved.is_async) {
                    closeAsyncIteratorOnThrow(self, fs.?, iter);
                } else {
                    closeIteratorOnThrow(self, iter);
                }
            }
            return err;
        };
        value.deinit();
        if (step) |c| {
            errdefer c.value.deinit();
            if (is_await and resolved.is_async) {
                try closeAsyncIteratorNormal(self, fs.?, iter);
            } else {
                try closeIterator(self, iter);
            }
            return c;
        }
    }
    return .{};
}

/// for-of over the built-in iterables, natively: arrays (elements),
/// strings (Unicode code points -- the spec iterates by code point,
/// surrogate pairs together), maps ([key, value] pair arrays), sets
/// (values). Everything else -- plain objects included -- is a real
/// TypeError, exactly like Node (plain objects aren't iterable there
/// either). The one genuine gap vs. spec: user-defined iterables via
/// Symbol.iterator, impossible until ZObject supports symbol keys.
pub fn evalForOf(self: *Interpreter, env: *Environment, head: anytype, body: *zstatements.Statement, labels: []const []const u8) anyerror!Completion {
    const is_await = head.is_await;
    // The parser only ever sets is_await inside an async function/async
    // generator body (await_allowed-gated), so a live fiber always
    // exists here; a missing one would be an interpreter bug -- same
    // contract as `.await_expr`/`.yield_expr`.
    const fs: ?*FiberState = if (is_await) (self.current_fiber orelse return error.NotImplemented) else null;
    const head_env: *Environment = switch (head.binding) {
        .declared => |d| if (d.kind != .@"var") blk: {
            const tdz_env = try self.gcChildEnv(env);
            try @import("interpreter_stmt.zig").markPatternTDZ(self, tdz_env, d.pattern);
            break :blk tdz_env;
        } else env,
        else => env,
    };
    const iterable = try self.evalExpression(head_env, head.iterable);
    defer iterable.deinit();
    switch (iterable.unpack()) {
        .array => |box| {
            if (isIntactArrayIterator(self, iterable)) {
                var i: usize = 0;
                while (i < box.value.length()) : (i += 1) {
                    var item = box.value.get(i).retain();
                    if (is_await) {
                        const awaited = try self.awaitValue(fs.?, item);
                        item.deinit();
                        item = awaited;
                    }
                    const step = try self.forIterationStep(env, head.binding, item, body, labels);
                    item.deinit();
                    if (step) |c| return c;
                }
                return .{};
            }
            return evalForOfIterator(self, env, fs, is_await, iterable, head.binding, body, labels);
        },
        .string => |box| {
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                var ch = try self.gcNewString(cp);
                if (is_await) {
                    const awaited = try self.awaitValue(fs.?, ch);
                    ch.deinit();
                    ch = awaited;
                }
                const step = try self.forIterationStep(env, head.binding, ch, body, labels);
                ch.deinit();
                if (step) |c| return c;
            }
        },
        .map => |box| {
            // Live iteration (MapIterator semantics): re-read the ordered
            // keys each step (delete compacts them), retaining key+value,
            // so a body that mutates the map is observed and never dangles.
            var i: usize = 0;
            while (true) {
                const ks = box.value.keys();
                if (i >= ks.len) break;
                const k = ks[i].retain();
                const v = (box.value.get(k) orelse JSValue.UNDEFINED).retain();
                i += 1;
                var entry = try self.gcNewArray();
                _ = try entry.asArray().value.push(k);
                _ = try entry.asArray().value.push(v);
                if (is_await) {
                    const awaited = try self.awaitValue(fs.?, entry);
                    entry.deinit();
                    entry = awaited;
                }
                const step = try self.forIterationStep(env, head.binding, entry, body, labels);
                entry.deinit();
                if (step) |c| return c;
            }
        },
        .set => |box| {
            // Live iteration (SetIterator semantics): re-read the ordered
            // values each step (delete compacts them) and retain the
            // element, so a body that mutates the set (`set.delete(x)`) is
            // observed and never dangles a cached slice.
            var i: usize = 0;
            while (true) {
                const vals = box.value.values();
                if (i >= vals.len) break;
                var v = vals[i].retain();
                i += 1;
                if (is_await) {
                    const awaited = try self.awaitValue(fs.?, v);
                    v.deinit();
                    v = awaited;
                }
                const step = try self.forIterationStep(env, head.binding, v, body, labels);
                v.deinit();
                if (step) |c| return c;
            }
        },
        .typed_array => |box| {
            // Live TypedArray iteration when intact; falls back to iterator protocol if overridden.
            const is_intact = blk: {
                const sym = self.symbol_iterator orelse break :blk true;
                const k = try self.encodeKey(sym);
                defer self.gc_allocator.free(k);
                const m = try self.getProperty(iterable, k);
                defer m.deinit();
                const expected = self.protos.typed_array_base.asObject().value.getOwn("values") orelse break :blk false;
                break :blk zvalue.equality.strictEquals(m, expected);
            };
            if (is_intact) {
                var i: usize = 0;
                while (i < box.value.len) : (i += 1) {
                    if (@import("builtin_helpers.zig").isTypedArrayDetached(&box.value)) {
                        return self.throwError(.type_error, "Cannot iterate over a detached TypedArray", .{});
                    }
                    var item = try @import("builtins.zig").typedElemGet(self, box.value.kind, &box.value.owner.asArrayBuffer().value, box.value.byte_offset, box.value.len, i);
                    if (is_await) {
                        const awaited = try self.awaitValue(fs.?, item);
                        item.deinit();
                        item = awaited;
                    }
                    const step = try self.forIterationStep(env, head.binding, item, body, labels);
                    item.deinit();
                    if (step) |c| return c;
                }
                return .{};
            }
            return evalForOfIterator(self, env, fs, is_await, iterable, head.binding, body, labels);
        },
        // The iterator protocol: a user iterable via Symbol.iterator
        // (or Symbol.asyncIterator, for `for await`), or an object that
        // IS an iterator (duck-typed `next` -- generator objects,
        // hand-written iterators). The completion value (`done: true`'s
        // value) is excluded, per spec.
        .object, .proxy, .function, .array_buffer, .data_view, .regex, .date, .@"error", .promise, .temporal => return evalForOfIterator(self, env, fs, is_await, iterable, head.binding, body, labels),
        else => return self.throwError(.type_error, "{s} is not iterable", .{iterable.typeOf()}),
    }
    return .{};
}

/// for-in over enumerable string keys: own + inherited (walking the
/// prototype chain, shadowed keys seen once), array/string indices as
/// STRINGS (for-in keys are always strings in real JS), and -- per
/// spec -- zero iterations without error over null/undefined. Types
/// with no string-keyed property model here (number, boolean, map,
/// set, ...) iterate zero times.
pub fn evalForIn(self: *Interpreter, env: *Environment, head: anytype, body: *zstatements.Statement, labels: []const []const u8) anyerror!Completion {
    const arena = self.gc_allocator;
    const target = try self.evalExpression(env, head.object);
    defer target.deinit();
    switch (target.unpack()) {
        .object => |box| {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(arena);
            var keys_list: std.ArrayList([]const u8) = .empty;
            defer keys_list.deinit(arena);
            // `globalThis`: top-level var/function names and ad-hoc
            // globals aren't backed by a real ZObject record, so the
            // bag walk below would miss them entirely -- same gap as
            // ownEnumerableKeys (see its global_builtin_names comment).
            if (self.global_object) |go| {
                if (target.asObject() == go.asObject()) {
                    if (self.global_var_env) |gve| {
                        for (gve.bindings.items) |binding| {
                            if (seen.contains(binding.name)) continue;
                            try seen.put(arena, binding.name, {});
                            try keys_list.append(arena, binding.name);
                        }
                    }
                    for (self.global_env.bindings.items) |binding| {
                        if (self.global_builtin_names.contains(binding.name)) continue;
                        if (seen.contains(binding.name)) continue;
                        try seen.put(arena, binding.name, {});
                        try keys_list.append(arena, binding.name);
                    }
                }
            }
            var current: ?*const @TypeOf(box.value) = &box.value;
            while (current) |o| : (current = o.getPrototype()) {
                const ks = try o.keys(arena);
                defer arena.free(ks);
                for (ks) |k| {
                    if (Interpreter.isSymbolKey(k)) continue; // symbols never in for-in
                    if (!seen.contains(k)) {
                        try seen.put(arena, k, {});
                        try keys_list.append(arena, k);
                    }
                }
            }
            for (keys_list.items) |k| {
                const kv = try self.gcNewString(k);
                const step = try self.forIterationStep(env, head.binding, kv, body, labels);
                kv.deinit();
                if (step) |c| return c;
            }
        },
        .array => |box| {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(arena);
            var keys_list: std.ArrayList([]const u8) = .empty;
            defer keys_list.deinit(arena);
            var owned_idx_keys: std.ArrayList([]const u8) = .empty;
            defer {
                for (owned_idx_keys.items) |s| arena.free(s);
                owned_idx_keys.deinit(arena);
            }
            const bag_opt = self.array_props.get(@intFromPtr(box));
            const len = box.value.length();
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (box.value.isHole(i)) continue;
                const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                try owned_idx_keys.append(arena, key_str);
                if (bag_opt) |bag| {
                    if (bag.asObject().value.getOwnRecord(key_str)) |rec| {
                        if (!rec.descriptor.enumerable) {
                            try seen.put(arena, key_str, {});
                            continue;
                        }
                    }
                }
                try seen.put(arena, key_str, {});
                try keys_list.append(arena, key_str);
            }
            if (bag_opt) |bag| {
                const ks = try bag.asObject().value.keys(arena);
                defer arena.free(ks);
                for (ks) |k| {
                    if (Interpreter.isSymbolKey(k)) continue;
                    if (!seen.contains(k)) {
                        try seen.put(arena, k, {});
                        try keys_list.append(arena, k);
                    }
                }
            }
            var current: ?*const @TypeOf(self.protos.array.asObject().value) = &self.protos.array.asObject().value;
            while (current) |o| : (current = o.getPrototype()) {
                const ks = try o.keys(arena);
                defer arena.free(ks);
                for (ks) |k| {
                    if (Interpreter.isSymbolKey(k)) continue;
                    if (!seen.contains(k)) {
                        try seen.put(arena, k, {});
                        try keys_list.append(arena, k);
                    }
                }
            }
            for (keys_list.items) |k| {
                const kv = try self.gcNewString(k);
                const step = try self.forIterationStep(env, head.binding, kv, body, labels);
                kv.deinit();
                if (step) |c| return c;
            }
        },
        .date, .promise, .map, .set, .@"error", .regex, .array_buffer, .data_view => {
            const bag_opt = if (target.isRegex()) self.regexProps(target) else self.extraProps(target);
            if (bag_opt) |bag| {
                const ks = try bag.asObject().value.keys(arena);
                defer arena.free(ks);
                for (ks) |k| {
                    if (Interpreter.isSymbolKey(k)) continue;
                    const kv = try self.gcNewString(k);
                    const step = try self.forIterationStep(env, head.binding, kv, body, labels);
                    kv.deinit();
                    if (step) |c| return c;
                }
            }
        },
        .string => |box| {
            // UTF-16 code unit count, not UTF-8 byte count -- same fix
            // as getProperty's .string case (interpreter_props.zig).
            var i: usize = 0;
            while (i < zstring.utf16.lengthUtf16(box.value.data)) : (i += 1) {
                const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                defer arena.free(key_str);
                const kv = try self.gcNewString(key_str);
                const step = try self.forIterationStep(env, head.binding, kv, body, labels);
                kv.deinit();
                if (step) |c| return c;
            }
        },
        // Narrowing: only the proxy's own (trap-aware) keys -- unlike
        // the .object case above, this does NOT continue walking a
        // prototype chain past the proxy (real for-in would need a
        // getPrototypeOf-trap-aware walk on top of this), matching
        // this engine's already-established "no invariant checking"
        // scope boundary for Proxy.
        .proxy => {
            const ks = try builtins.ownEnumerableKeys(self, arena, target);
            defer builtins.freeOwnedKeys(arena, ks);
            for (ks) |k| {
                if (Interpreter.isSymbolKey(k)) continue;
                const kv = try self.gcNewString(k);
                const step = try self.forIterationStep(env, head.binding, kv, body, labels);
                kv.deinit();
                if (step) |c| return c;
            }
        },
        .typed_array => {
            const ks = try builtins.ownEnumerableKeys(self, arena, target);
            defer builtins.freeOwnedKeys(arena, ks);
            for (ks) |k| {
                if (Interpreter.isSymbolKey(k)) continue;
                const kv = try self.gcNewString(k);
                const step = try self.forIterationStep(env, head.binding, kv, body, labels);
                kv.deinit();
                if (step) |c| return c;
            }
        },
        else => {}, // incl. null/undefined: zero iterations, no error (spec)
    }
    return .{};
}

