//! `Array.prototype` (basic + extended coverage) and the `Array`
//! constructor + statics. `normIndex` is `pub` here (used by
//! `arrayCopyWithin`/`arrayFill`/`arraySplice` in this file) -- also
//! reused by TypedArray's `taCopyWithin`/`taFill`/`taSlice`, which reach
//! it via `builtins.normIndex` (re-exported below, unchanged since batch
//! 4 -- `arraybuffer_builtins.zig` needs no edits for this move).
//! z-interpreter-refactor.md, Step 5 Phase A batch 5.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const requireTag = builtin_helpers.requireTag;
const requireCallback = builtin_helpers.requireCallback;
const callCallback = builtin_helpers.callCallback;
const toIntSat = builtin_helpers.toIntSat;
const toLength = builtin_helpers.toLength;
const hasIteratorMethod = builtin_helpers.hasIteratorMethod;
const arrayLikeToList = builtin_helpers.arrayLikeToList;
const makeArrayIterator = builtin_helpers.makeArrayIterator;

pub const array_methods = std.StaticStringMap(NativeFn).initComptime(.{
    .{ "push", arrayPush },
    .{ "pop", arrayPop },
    .{ "shift", arrayShift },
    .{ "unshift", arrayUnshift },
    .{ "indexOf", arrayIndexOf },
    .{ "includes", arrayIncludes },
    .{ "join", arrayJoin },
    .{ "slice", arraySlice },
    .{ "concat", arrayConcat },
    .{ "reverse", arrayReverse },
    .{ "map", arrayMap },
    .{ "filter", arrayFilter },
    .{ "forEach", arrayForEach },
    .{ "reduce", arrayReduce },
    .{ "find", arrayFind },
    .{ "findIndex", arrayFindIndex },
    .{ "findLast", arrayFindLast },
    .{ "findLastIndex", arrayFindLastIndex },
    .{ "some", arraySome },
    .{ "every", arrayEvery },
    .{ "reduceRight", arrayReduceRight },
    .{ "flatMap", arrayFlatMap },
    .{ "at", arrayAt },
    .{ "lastIndexOf", arrayLastIndexOf },
    .{ "fill", arrayFill },
    .{ "copyWithin", arrayCopyWithin },
    .{ "flat", arrayFlat },
    .{ "splice", arraySplice },
    .{ "sort", arraySort },
    .{ "toString", arrayToStringMethod },
    .{ "keys", arrayKeys },
    .{ "values", arrayValues },
    .{ "entries", arrayEntries },
});

// ===== Array.prototype =====

fn requireArray(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!void {
    _ = try requireTag(ctx, this_value, .array, "Array.prototype.{s} called on a non-array", method);
}

fn arrayPush(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "push");
    for (args) |a| _ = try this_value.array.value.push(a.retain());
    return JSValue.fromNumber(@floatFromInt(this_value.array.value.length()));
}

fn arrayPop(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireArray(ctx, this_value, "pop");
    return this_value.array.value.pop() orelse JSValue.UNDEFINED;
}

fn arrayShift(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireArray(ctx, this_value, "shift");
    return this_value.array.value.shift() orelse JSValue.UNDEFINED;
}

fn arrayUnshift(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "unshift");
    // Insert in reverse so the args end up in order at the front.
    var i = args.len;
    while (i > 0) {
        i -= 1;
        _ = try this_value.array.value.unshift(args[i].retain());
    }
    return JSValue.fromNumber(@floatFromInt(this_value.array.value.length()));
}

fn arrayIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "indexOf");
    const idx = this_value.array.value.indexOf(arg(args, 0), null) orelse return JSValue.fromNumber(-1);
    return JSValue.fromNumber(@floatFromInt(idx));
}

fn arrayIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "includes");
    return JSValue.fromBool(this_value.array.value.includes(arg(args, 0), null));
}

fn arrayJoin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "join");
    const sep = if (arg(args, 0) == .string) arg(args, 0).string.value.data else ",";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (this_value.array.value.toSlice(), 0..) |item, i| {
        if (i != 0) try buf.appendSlice(allocator, sep);
        switch (item) {
            .undefined, .null => {},
            else => {
                const s = try coercion.toDisplayString(allocator, item);
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
            },
        }
    }
    return interp(ctx).gcNewString(buf.items);
}

fn arraySlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "slice");
    const start: ?isize = if (arg(args, 0) == .undefined) null else toIntSat(try coercion.toNumber(arg(args, 0)));
    const end: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try coercion.toNumber(arg(args, 1)));
    // z-array's own slice() does the negative-index/clamping arithmetic
    // (same rules ECMA-262 wants); it just copies the raw JSValue bytes
    // without retaining (it doesn't know T might be refcounted), so we
    // retain each element ourselves on the way into the GC-tracked result.
    var sliced = try this_value.array.value.slice(start, end);
    defer sliced.deinit();
    var result = try interp(ctx).gcNewArray();
    for (sliced.toSlice()) |item| _ = try result.array.value.push(item.retain());
    return result;
}

fn arrayConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "concat");
    var result = try interp(ctx).gcNewArray();
    for (this_value.array.value.toSlice()) |item| _ = try result.array.value.push(item.retain());
    for (args) |a| {
        if (a == .array) {
            for (a.array.value.toSlice()) |item| _ = try result.array.value.push(item.retain());
        } else {
            _ = try result.array.value.push(a.retain());
        }
    }
    return result;
}

fn arrayReverse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = args;
    try requireArray(ctx, this_value, "reverse");
    this_value.array.value.reverse();
    return this_value.retain();
}

/// Live element at `i`, retained so it stays valid across a callback that
/// mutates the array (e.g. `arr.length = k`, which would otherwise free the
/// element and leave a cached `toSlice()` dangling -> "switch on corrupt
/// value"). Null when `i` is now out of bounds (removed mid-iteration ->
/// skip, matching the spec's per-index HasProperty check). The extra ref is
/// reclaimed with the run's arena; callers needn't release it.
fn liveElem(array: JSValue, i: usize) ?JSValue {
    if (i >= array.array.value.length()) return null;
    return array.array.value.get(i).retain();
}

fn arrayMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "map");
    const cb = try requireCallback(ctx, args);
    var result = try interp(ctx).gcNewArray();
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        // A removed index leaves a hole (undefined) so result.length stays
        // the originally-observed length, like real Array.prototype.map.
        if (liveElem(this_value, i)) |item| {
            const v = try callCallback(cb, allocator, item, i, this_value);
            _ = try result.array.value.push(v.retain());
        } else {
            _ = try result.array.value.push(JSValue.UNDEFINED);
        }
    }
    return result;
}

fn arrayFilter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "filter");
    const cb = try requireCallback(ctx, args);
    var result = try interp(ctx).gcNewArray();
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) {
            _ = try result.array.value.push(item.retain());
        }
    }
    return result;
}

fn arrayForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "forEach");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        _ = try callCallback(cb, allocator, item, i, this_value);
    }
    return JSValue.UNDEFINED;
}

fn arrayReduce(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "reduce");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1];
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
            acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value,
        });
    }
    if (!have) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn arrayFind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "find");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        // find visits absent indices as `undefined` (unlike forEach/map).
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arraySome(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "some");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn arrayEvery(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "every");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        if (!coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromBool(false);
    }
    return JSValue.fromBool(true);
}

fn arrayIsArray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    return JSValue.fromBool(arg(args, 0) == .array);
}

// ===== Array / Function constructors and statics =====

fn arrayConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    var result = try self.gcNewArray();
    if (args.len == 1 and args[0] == .number) {
        const n = args[0].number;
        if (n < 0 or n != @trunc(n) or n > 4294967294.0) {
            return self.throwError(.range_error, "Invalid array length", .{});
        }
        var i: usize = 0;
        const len: usize = @intFromFloat(n);
        while (i < len) : (i += 1) _ = try result.array.value.push(JSValue.UNDEFINED);
        return result;
    }
    for (args) |a| _ = try result.array.value.push(a.retain());
    return result;
}

fn arrayOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    var result = try interp(ctx).gcNewArray();
    for (args) |a| _ = try result.array.value.push(a.retain());
    return result;
}

/// Array.from over arrays, strings (code points), and iterator-protocol
/// objects (callable `next`), with the optional mapFn.
fn arrayFrom(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const src = arg(args, 0);
    const map_fn = arg(args, 1);
    var result = try interp(ctx).gcNewArray();
    var index: f64 = 0;

    const push_mapped = struct {
        fn go(s: *Interpreter, alloc: Allocator, res: *JSValue, mf: JSValue, item: JSValue, i: f64) anyerror!void {
            var v = item;
            if (mf == .function) {
                v = try mf.function.value.call(mf.function.value.ctx, alloc, JSValue.UNDEFINED, &.{ item, JSValue.fromNumber(i) });
            }
            _ = s;
            _ = try res.array.value.push(v.retain());
        }
    }.go;

    switch (src) {
        .array => |box| for (box.value.toSlice()) |item| {
            try push_mapped(self, allocator, &result, map_fn, item, index);
            index += 1;
        },
        // Sets/Maps are iterable -- drain via the shared iterable path.
        .set, .map => {
            const items = try self.iterableItems(src);
            defer self.gc_allocator.free(items);
            for (items) |item| {
                try push_mapped(self, allocator, &result, map_fn, item, index);
                index += 1;
            }
        },
        .string => |box| {
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                try push_mapped(self, allocator, &result, map_fn, try interp(ctx).gcNewString(cp), index);
                index += 1;
            }
        },
        .object => {
            // Real @@iterator-presence-first, array-like fallback --
            // the array-like helper is shared with the TypedArray
            // constructor's equivalent overload (also fixes the
            // previous inline version's two spec inaccuracies: string
            // `length` now coerces, and a bare `{next(){...}}` object
            // with no `Symbol.iterator` is now correctly treated as
            // array-like, matching real Node).
            if (!(try hasIteratorMethod(self, src))) {
                const items = try arrayLikeToList(self, allocator, src);
                defer {
                    for (items) |it| it.deinit();
                    allocator.free(items);
                }
                for (items) |item| {
                    try push_mapped(self, allocator, &result, map_fn, item, index);
                    index += 1;
                }
            } else {
                // Manual per-step drain (NOT `iterableItems`, which
                // eagerly drains to completion before any caller code
                // runs) -- `mapFn` must be applied INLINE per `next()`
                // step so an infinite iterator combined with an
                // early-throwing `mapFn` still terminates (a real,
                // tested pattern: Array.from(infiniteIter, fnThatThrows)).
                const iter = try self.resolveIterator(src);
                const next_fn = try self.getProperty(iter, "next");
                while (true) {
                    const step = try next_fn.function.value.call(next_fn.function.value.ctx, allocator, iter, &.{});
                    if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                    if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
                    try push_mapped(self, allocator, &result, map_fn, try self.getProperty(step, "value"), index);
                    index += 1;
                }
            }
        },
        else => return self.throwError(.type_error, "{s} is not iterable", .{src.typeOf()}),
    }
    return result;
}

// ===== Array.prototype (extended coverage) =====

pub fn normIndex(raw: f64, len: usize) usize {
    const i = toIntSat(raw); // NaN/Infinity-safe
    if (i < 0) {
        const from_end = @as(isize, @intCast(len)) + i;
        return if (from_end < 0) 0 else @intCast(from_end);
    }
    return @min(@as(usize, @intCast(i)), len);
}

fn arrayAt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "at");
    const len: isize = @intCast(this_value.array.value.length());
    const rel = toIntSat(try coercion.toNumber(arg(args, 0)));
    const idx = if (rel < 0) len + rel else rel;
    if (idx < 0 or idx >= len) return JSValue.UNDEFINED;
    return this_value.array.value.get(@intCast(idx)).retain();
}

fn arrayFindIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findIndex");
    const cb = try requireCallback(ctx, args);
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFindLast(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findLast");
    const cb = try requireCallback(ctx, args);
    var i = this_value.array.value.length();
    while (i > 0) {
        i -= 1;
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arrayFindLastIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "findLastIndex");
    const cb = try requireCallback(ctx, args);
    var i = this_value.array.value.length();
    while (i > 0) {
        i -= 1;
        const item = liveElem(this_value, i) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallback(cb, allocator, item, i, this_value))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayReduceRight(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "reduceRight");
    const cb = try requireCallback(ctx, args);
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1];
    var i: usize = this_value.array.value.length();
    while (i > 0) {
        i -= 1;
        const item = liveElem(this_value, i) orelse continue;
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ acc, item, JSValue.fromNumber(@floatFromInt(i)), this_value });
    }
    if (!have) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn arrayFlatMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "flatMap");
    const cb = try requireCallback(ctx, args);
    var result = try interp(ctx).gcNewArray();
    const len = this_value.array.value.length();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = liveElem(this_value, i) orelse continue;
        const v = try callCallback(cb, allocator, item, i, this_value);
        if (v == .array) {
            for (v.array.value.toSlice()) |sub| _ = try result.array.value.push(sub.retain());
        } else {
            _ = try result.array.value.push(v.retain());
        }
    }
    return result;
}

fn arrayLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "lastIndexOf");
    const target = arg(args, 0);
    const slice = this_value.array.value.toSlice();
    var i = slice.len;
    while (i > 0) {
        i -= 1;
        if (zvalue.equality.strictEquals(slice[i], target)) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFill(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "fill");
    const arr = &this_value.array.value;
    const val = arg(args, 0);
    const start: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try coercion.toNumber(arg(args, 1)));
    const end: ?isize = if (arg(args, 2) == .undefined) null else toIntSat(try coercion.toNumber(arg(args, 2)));
    // z-array's fill() copies `val`'s raw bytes into every touched slot
    // without retaining (doesn't know T is refcounted) and without
    // releasing what was there before. Use slice() as a read-only probe
    // over the SAME index math fill() will use internally, purely to
    // find out which slots are about to be touched: release what's
    // there now, retain `val` once per slot, then let fill() do the
    // actual write.
    var touched = try arr.slice(start, end);
    defer touched.deinit();
    for (touched.toSlice()) |v| v.deinit();
    for (touched.toSlice()) |_| _ = val.retain();
    arr.fill(val, start, end);
    return this_value.retain();
}

fn arrayCopyWithin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    try requireArray(ctx, this_value, "copyWithin");
    const arr = &this_value.array.value;
    const len = arr.length();
    const target = normIndex(try coercion.toNumber(arg(args, 0)), len);
    const start = if (arg(args, 1) == .undefined) 0 else normIndex(try coercion.toNumber(arg(args, 1)), len);
    const end = if (arg(args, 2) == .undefined) len else normIndex(try coercion.toNumber(arg(args, 2)), len);
    // Snapshot the source slice (retained) so overlapping copies are correct.
    var tmp: std.ArrayList(JSValue) = .empty;
    defer tmp.deinit(std.heap.page_allocator);
    var i = start;
    while (i < end) : (i += 1) try tmp.append(std.heap.page_allocator, arr.toSlice()[i]);
    const mut = arr.toSliceMut();
    var t = target;
    for (tmp.items) |src| {
        if (t >= len) break;
        mut[t].deinit();
        mut[t] = src.retain();
        t += 1;
    }
    return this_value.retain();
}

fn flattenInto(result: *JSValue, allocator: Allocator, slice: []const JSValue, depth: i64) anyerror!void {
    for (slice) |item| {
        if (depth > 0 and item == .array) {
            try flattenInto(result, allocator, item.array.value.toSlice(), depth - 1);
        } else {
            _ = try result.array.value.push(item.retain());
        }
    }
}

fn arrayFlat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "flat");
    const depth: i64 = if (arg(args, 0) == .undefined) 1 else toIntSat(try coercion.toNumber(arg(args, 0)));
    var result = try interp(ctx).gcNewArray();
    try flattenInto(&result, allocator, this_value.array.value.toSlice(), depth);
    return result;
}

fn arraySplice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "splice");
    const arr = &this_value.array.value;
    const start: isize = if (args.len == 0) 0 else toIntSat(try coercion.toNumber(arg(args, 0)));
    // Spec nuance z-array's own `null` default doesn't capture: with
    // ZERO arguments at all, deleteCount is 0 (not "delete the rest");
    // with exactly one argument (start only, no deleteCount), it IS
    // "delete the rest" -- z-array's `null` already means that.
    const delete_count: ?usize = if (args.len == 0)
        0
    else if (args.len == 1)
        null
    else blk: {
        const dc = try coercion.toNumber(arg(args, 1));
        if (dc <= 0) break :blk 0;
        break :blk @intCast(toIntSat(dc));
    };
    // Retain each inserted value once (the array gains a reference,
    // separate from whatever the caller still holds) -- z-array's own
    // splice() copies raw bytes in, no retain of its own.
    const raw_inserts = if (args.len > 2) args[2..] else &[_]JSValue{};
    const inserts = try allocator.alloc(JSValue, raw_inserts.len);
    defer allocator.free(inserts);
    for (raw_inserts, 0..) |item, i| inserts[i] = item.retain();

    var deleted = try arr.splice(start, delete_count, inserts);
    defer deleted.deinit();
    // z-array's splice() already physically removed these from `arr`
    // (self.items.replaceRange), so `deleted` is the sole owner of that
    // reference -- moving it into the GC-tracked result is NOT a retain,
    // same "shallow move" contract as everywhere else this file talks to
    // z-array's raw ZArray(T).
    var removed = try interp(ctx).gcNewArray();
    for (deleted.toSlice()) |item| _ = try removed.array.value.push(item);
    return removed;
}

fn arraySort(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    try requireArray(ctx, this_value, "sort");
    const self = interp(ctx);
    const cmp = arg(args, 0);
    if (cmp != .undefined and cmp != .function) return self.throwError(.type_error, "The comparison function must be either a function or undefined", .{});
    const arr = &this_value.array.value;
    const n = arr.length();
    // Insertion sort over the live backing (stable; O(n^2) is fine for
    // the sizes involved and lets us call a JS comparator per compare).
    var i: usize = 1;
    const mut = arr.toSliceMut();
    while (i < n) : (i += 1) {
        const key = mut[i];
        var j = i;
        while (j > 0) {
            const before = try sortLess(allocator, cmp, key, mut[j - 1]);
            if (!before) break;
            mut[j] = mut[j - 1];
            j -= 1;
        }
        mut[j] = key;
    }
    return this_value.retain();
}

/// Whether `a` should sort before `b` (comparator < 0, or default string
/// order). undefined always sorts last (spec).
fn sortLess(allocator: Allocator, cmp: JSValue, a: JSValue, b: JSValue) anyerror!bool {
    if (a == .undefined) return false;
    if (b == .undefined) return true;
    if (cmp == .function) {
        const r = try cmp.function.value.call(cmp.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ a, b });
        return (try coercion.toNumber(r)) < 0;
    }
    const sa = try coercion.toDisplayString(allocator, a);
    defer allocator.free(sa);
    const sb = try coercion.toDisplayString(allocator, b);
    defer allocator.free(sb);
    return std.mem.order(u8, sa, sb) == .lt;
}

fn arrayToStringMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "toString");
    const s = try coercion.toDisplayString(allocator, this_value);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn arrayKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "keys");
    return makeArrayIterator(interp(ctx), allocator, this_value, .keys);
}

fn arrayValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "values");
    return makeArrayIterator(interp(ctx), allocator, this_value, .values);
}

fn arrayEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    try requireArray(ctx, this_value, "entries");
    return makeArrayIterator(interp(ctx), allocator, this_value, .entries);
}

/// Installs the `Array` constructor + statics.
pub fn install(self: *Interpreter) !void {
    // Array: constructable (new Array(n) / Array(a, b, c)) + statics.
    _ = try installBuiltin(self, .{ .name = "Array", .ctor = .{ .arity = 1, .call = arrayConstructor, .constructable = true }, .statics = &.{
        .{ .name = "isArray", .value = .{ .method = arrayIsArray } },
        .{ .name = "of", .value = .{ .method = arrayOf } },
        .{ .name = "from", .value = .{ .method = arrayFrom } },
    } });
}
