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
const zstring = @import("zstring");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const object_builtins = @import("object_builtins.zig");
const property_desc = @import("property_desc.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const installBuiltin = builtin_helpers.installBuiltin;
const requireTag = builtin_helpers.requireTag;
const requireCallback = builtin_helpers.requireCallback;
const callCallback = builtin_helpers.callCallback;
const callCallbackWithThis = builtin_helpers.callCallbackWithThis;
const toIntSat = builtin_helpers.toIntSat;
const toLength = builtin_helpers.toLength;
const hasIteratorMethod = builtin_helpers.hasIteratorMethod;
const arrayLikeToList = builtin_helpers.arrayLikeToList;
const makeArrayIterator = builtin_helpers.makeArrayIterator;

/// See interpreter_expr.zig's twin of this helper: merges a WTF-8
/// high-surrogate tail with a low-surrogate head into the real 4-byte
/// UTF-8 astral sequence instead of leaving two lone WTF-8 surrogate
/// halves adjacent (z-string-surrogate-charat.md). Duplicated locally
/// rather than made pub+shared across files for one 8-line helper.
fn appendWtf8Merged(buf: *std.ArrayList(u8), allocator: Allocator, chunk: []const u8) !void {
    if (zstring.utf16.mergeSurrogateBoundary(buf.items, chunk)) |merged| {
        buf.items.len -= 3;
        try buf.appendSlice(allocator, &merged);
        try buf.appendSlice(allocator, chunk[3..]);
    } else {
        try buf.appendSlice(allocator, chunk);
    }
}

pub const array_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "push", MethodSpec{ .call = arrayPush, .arity = 1 } },
    .{ "pop", MethodSpec{ .call = arrayPop, .arity = 0 } },
    .{ "shift", MethodSpec{ .call = arrayShift, .arity = 0 } },
    .{ "unshift", MethodSpec{ .call = arrayUnshift, .arity = 1 } },
    .{ "indexOf", MethodSpec{ .call = arrayIndexOf, .arity = 1 } },
    .{ "includes", MethodSpec{ .call = arrayIncludes, .arity = 1 } },
    .{ "join", MethodSpec{ .call = arrayJoin, .arity = 1 } },
    .{ "slice", MethodSpec{ .call = arraySlice, .arity = 2 } },
    .{ "concat", MethodSpec{ .call = arrayConcat, .arity = 1 } },
    .{ "reverse", MethodSpec{ .call = arrayReverse, .arity = 0 } },
    .{ "map", MethodSpec{ .call = arrayMap, .arity = 1 } },
    .{ "filter", MethodSpec{ .call = arrayFilter, .arity = 1 } },
    .{ "forEach", MethodSpec{ .call = arrayForEach, .arity = 1 } },
    .{ "reduce", MethodSpec{ .call = arrayReduce, .arity = 1 } },
    .{ "find", MethodSpec{ .call = arrayFind, .arity = 1 } },
    .{ "findIndex", MethodSpec{ .call = arrayFindIndex, .arity = 1 } },
    .{ "findLast", MethodSpec{ .call = arrayFindLast, .arity = 1 } },
    .{ "findLastIndex", MethodSpec{ .call = arrayFindLastIndex, .arity = 1 } },
    .{ "some", MethodSpec{ .call = arraySome, .arity = 1 } },
    .{ "every", MethodSpec{ .call = arrayEvery, .arity = 1 } },
    .{ "reduceRight", MethodSpec{ .call = arrayReduceRight, .arity = 1 } },
    .{ "flatMap", MethodSpec{ .call = arrayFlatMap, .arity = 1 } },
    .{ "at", MethodSpec{ .call = arrayAt, .arity = 1 } },
    .{ "lastIndexOf", MethodSpec{ .call = arrayLastIndexOf, .arity = 1 } },
    .{ "fill", MethodSpec{ .call = arrayFill, .arity = 1 } },
    .{ "copyWithin", MethodSpec{ .call = arrayCopyWithin, .arity = 2 } },
    .{ "flat", MethodSpec{ .call = arrayFlat, .arity = 0 } },
    .{ "splice", MethodSpec{ .call = arraySplice, .arity = 2 } },
    .{ "sort", MethodSpec{ .call = arraySort, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = arrayToStringMethod, .arity = 0 } },
    .{ "toReversed", MethodSpec{ .call = arrayToReversed, .arity = 0 } },
    .{ "toSorted", MethodSpec{ .call = arrayToSorted, .arity = 1 } },
    .{ "toSpliced", MethodSpec{ .call = arrayToSpliced, .arity = 2 } },
    .{ "with", MethodSpec{ .call = arrayWith, .arity = 2 } },
    .{ "keys", MethodSpec{ .call = arrayKeys, .arity = 0 } },
    .{ "values", MethodSpec{ .call = arrayValues, .arity = 0 } },
    .{ "entries", MethodSpec{ .call = arrayEntries, .arity = 0 } },
});

// ===== Array.prototype =====

fn requireArray(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!void {
    _ = try requireTag(ctx, this_value, .array, "Array.prototype.{s} called on a non-array", method);
}

/// array-generic-methods.md: real spec's `Array.prototype.*` methods
/// are generic -- they only require `this` to be object-coercible
/// (ToObject(this) fails solely for null/undefined), not a real
/// Array. Used by the methods converted below to accept any
/// array-like (`{length: N, 0: ..., 1: ...}`), matching
/// `Array.prototype.slice.call(arguments)`-style patterns. Kept
/// SEPARATE from `requireArray` (still used, unchanged, by the
/// mutators below whose bodies still do a direct `.array` union-field
/// access -- loosening THEIR guard without also rewriting their
/// bodies would trade a clean TypeError for a Zig-level union-access
/// panic; that conversion is Fase 2, not attempted here).
fn requireArrayLike(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!void {
    if (this_value == .undefined or this_value == .null) {
        return interp(ctx).throwError(.type_error, "Array.prototype.{s} called on null or undefined", .{method});
    }
}

fn toArrayLikeObject(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    if (this_value == .undefined or this_value == .null) {
        return interp(ctx).throwError(.type_error, "Array.prototype.{s} called on null or undefined", .{method});
    }
    if (this_value == .array) return this_value.retain();
    return try property_desc.toObject(interp(ctx), this_value);
}

fn setArrayLikeIndex(self: *Interpreter, obj: JSValue, i: usize, val: JSValue) anyerror!void {
    var buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    try self.setPropertyOnValue(obj, key, val);
}

fn deleteArrayLikeIndexOrThrow(self: *Interpreter, obj: JSValue, i: usize) anyerror!void {
    var buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    if (!try self.deletePropertyOnValue(obj, key)) {
        return self.throwError(.type_error, "Cannot delete property '{s}'", .{key});
    }
}

fn setArrayLikeLength(self: *Interpreter, obj: JSValue, len: usize) anyerror!void {
    try self.setPropertyOnValue(obj, "length", JSValue.fromNumber(@floatFromInt(len)));
}

/// Generic array-like length (ECMA-262 LengthOfArrayLike): a real
/// `.array` keeps the existing fast path; anything else does
/// Get(obj, "length") + ToLength.
fn arrayLikeLength(ctx: *anyopaque, this_value: JSValue) anyerror!usize {
    if (this_value == .array) return this_value.array.value.length();
    const self = interp(ctx);
    const len_v = try self.getProperty(this_value, "length");
    defer len_v.deinit();
    return toLength(self, len_v);
}

/// Generic array-like element read at index `i`: a real `.array` uses
/// the existing `liveElem` fast path; anything else checks `HasProperty`
/// first and returns `null` for missing properties, then `Get(obj, i)`.
fn arrayLikeElem(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, i: usize) anyerror!?JSValue {
    if (this_value == .array) return liveElem(ctx, allocator, this_value, i);
    const self = interp(ctx);
    var buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    if (!try property_desc.hasProperty(self, this_value, key)) return null;
    return try self.getProperty(this_value, key);
}

const MAX_ARRAY_LIKE_LEN: usize = 9007199254740991; // 2^53 - 1

fn isArrayValue(self: *Interpreter, v: JSValue) anyerror!bool {
    var cur = v;
    while (cur == .proxy) {
        if (cur.proxy.value.handler == .null) {
            return self.throwError(.type_error, "Cannot perform 'IsArray' on a proxy that has been revoked", .{});
        }
        cur = cur.proxy.value.target;
    }
    return cur == .array;
}

fn createDataPropertyOrThrow(self: *Interpreter, obj: JSValue, idx: usize, val: JSValue) anyerror!void {
    var buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable;
    var d = property_desc.ParsedDesc{
        .has_value = true,
        .value = val,
        .has_writable = true,
        .writable = true,
        .has_enumerable = true,
        .enumerable = true,
        .has_configurable = true,
        .configurable = true,
    };
    if (!try property_desc.defineOwnProperty(self, obj, key, &d)) {
        return self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{key});
    }
}

const SpeciesResult = struct {
    arr: JSValue,
    is_default: bool,
};

fn arraySpeciesCreate(self: *Interpreter, allocator: Allocator, original: JSValue, len: usize) anyerror!SpeciesResult {
    // Fast path for ordinary arrays without own "constructor" or altered prototype/Array[@@species]
    if (original == .array and self.array_props.get(@intFromPtr(original.array)) == null and self.proto_refs.get(@intFromPtr(original.array)) == null) {
        if (self.global_env.get("Array")) |array_ctor| {
            const proto_ctor = self.protos.array.object.value.getOwn("constructor");
            if (proto_ctor != null and zvalue.equality.strictEquals(proto_ctor.?, array_ctor)) {
                const skey = try @import("regex_builtins.zig").wellKnownKey(self, "species");
                defer allocator.free(skey);
                if (array_ctor == .function) {
                    if (array_ctor.function.value.statics) |bag| {
                        if (bag.object.value.getOwnRecord(skey)) |rec| {
                            if (rec.isAccessor() and rec.getter != null) {
                                // Check if species getter was overridden? Just fall through if overridden, or check fast.
                                // Actually calling species only takes 1 check; let's fall through to full path only if needed,
                                // or check if rec.getter.?.function.value.ctx == @ptrCast(self) (default speciesGetter!).
                                if (rec.getter.?.function.value.ctx == @as(*anyopaque, @ptrCast(self))) {
                                    return .{ .arr = try self.gcNewArray(), .is_default = true };
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (!try isArrayValue(self, original)) {
        return .{ .arr = try self.gcNewArray(), .is_default = true };
    }
    var ctor = try self.getProperty(original, "constructor");
    defer ctor.deinit();
    if (builtin_helpers.isObjectLike(ctor)) {
        const skey = try @import("regex_builtins.zig").wellKnownKey(self, "species");
        defer allocator.free(skey);
        const s = try self.getProperty(ctor, skey);
        ctor.deinit();
        ctor = s;
        if (ctor == .null) {
            ctor.deinit();
            ctor = JSValue.UNDEFINED;
        }
    }
    if (ctor == .undefined) {
        return .{ .arr = try self.gcNewArray(), .is_default = true };
    }
    if (!self.isConstructor(ctor)) {
        return self.throwError(.type_error, "Species is not a constructor", .{});
    }
    if (self.global_env.get("Array")) |array_ctor| {
        if (zvalue.equality.strictEquals(ctor, array_ctor)) {
            return .{ .arr = try self.gcNewArray(), .is_default = true };
        }
    }
    const len_val = JSValue.fromNumber(@floatFromInt(len));
    const res = try self.constructValue(ctor, &.{len_val}, "species");
    return .{ .arr = res, .is_default = false };
}

fn isConcatSpreadable(self: *Interpreter, allocator: Allocator, val: JSValue) anyerror!bool {
    if (!builtin_helpers.isObjectLike(val)) return false;
    const key = try @import("regex_builtins.zig").wellKnownKey(self, "isConcatSpreadable");
    defer allocator.free(key);
    const sp = try self.getProperty(val, key);
    defer sp.deinit();
    if (sp != .undefined) return coercion.isTruthy(sp);
    return isArrayValue(self, val);
}

fn arrayPush(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    if (this_value == .array) {
        for (args) |a| _ = try this_value.array.value.push(a.retain());
        return JSValue.fromNumber(@floatFromInt(this_value.array.value.length()));
    }
    const obj = try toArrayLikeObject(ctx, this_value, "push");
    defer obj.deinit();
    const self = interp(ctx);
    var len = try arrayLikeLength(ctx, obj);
    if (args.len > MAX_ARRAY_LIKE_LEN or len > MAX_ARRAY_LIKE_LEN - args.len) {
        return self.throwError(.type_error, "Invalid array length", .{});
    }
    for (args) |a| {
        try setArrayLikeIndex(self, obj, len, a);
        len += 1;
    }
    try setArrayLikeLength(self, obj, len);
    return JSValue.fromNumber(@floatFromInt(len));
}

fn arrayPop(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    if (this_value == .array) {
        return this_value.array.value.pop() orelse JSValue.UNDEFINED;
    }
    const obj = try toArrayLikeObject(ctx, this_value, "pop");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    if (len == 0) {
        try setArrayLikeLength(self, obj, 0);
        return JSValue.UNDEFINED;
    }
    const new_len = len - 1;
    const element = (try arrayLikeElem(ctx, allocator, obj, new_len)) orelse JSValue.UNDEFINED;
    errdefer element.deinit();
    try deleteArrayLikeIndexOrThrow(self, obj, new_len);
    try setArrayLikeLength(self, obj, new_len);
    return element;
}

fn arrayShift(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    if (this_value == .array) {
        return this_value.array.value.shift() orelse JSValue.UNDEFINED;
    }
    const obj = try toArrayLikeObject(ctx, this_value, "shift");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    if (len == 0) {
        try setArrayLikeLength(self, obj, 0);
        return JSValue.UNDEFINED;
    }
    const first = (try arrayLikeElem(ctx, allocator, obj, 0)) orelse JSValue.UNDEFINED;
    errdefer first.deinit();
    var k: usize = 1;
    while (k < len) : (k += 1) {
        if (try arrayLikeElem(ctx, allocator, obj, k)) |from_val| {
            defer from_val.deinit();
            try setArrayLikeIndex(self, obj, k - 1, from_val);
        } else {
            try deleteArrayLikeIndexOrThrow(self, obj, k - 1);
        }
    }
    try deleteArrayLikeIndexOrThrow(self, obj, len - 1);
    try setArrayLikeLength(self, obj, len - 1);
    return first;
}

fn arrayUnshift(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    if (this_value == .array) {
        // Insert in reverse so the args end up in order at the front.
        var i = args.len;
        while (i > 0) {
            i -= 1;
            _ = try this_value.array.value.unshift(args[i].retain());
        }
        return JSValue.fromNumber(@floatFromInt(this_value.array.value.length()));
    }
    const obj = try toArrayLikeObject(ctx, this_value, "unshift");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const arg_count = args.len;
    if (arg_count > 0) {
        if (arg_count > MAX_ARRAY_LIKE_LEN or len > MAX_ARRAY_LIKE_LEN - arg_count) {
            return self.throwError(.type_error, "Invalid array length", .{});
        }
        var k = len;
        while (k > 0) {
            k -= 1;
            if (try arrayLikeElem(ctx, allocator, obj, k)) |from_val| {
                defer from_val.deinit();
                try setArrayLikeIndex(self, obj, k + arg_count, from_val);
            } else {
                try deleteArrayLikeIndexOrThrow(self, obj, k + arg_count);
            }
        }
        for (args, 0..) |a, j| {
            try setArrayLikeIndex(self, obj, j, a);
        }
    }
    try setArrayLikeLength(self, obj, len + arg_count);
    return JSValue.fromNumber(@floatFromInt(len + arg_count));
}

fn arrayIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "indexOf");
    defer obj.deinit();
    const target = arg(args, 0);
    if (obj == .array and !obj.array.value.isHoley() and !obj.array.value.isSparse()) {
        const idx = obj.array.value.indexOf(target, null) orelse return JSValue.fromNumber(-1);
        return JSValue.fromNumber(@floatFromInt(idx));
    }
    const len = try arrayLikeLength(ctx, obj);
    var i: usize = if (arg(args, 1) == .undefined) 0 else normIndex(try interp(ctx).toNumberJS(arg(args, 1)), len);
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (zvalue.equality.strictEquals(item, target)) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayIncludes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const obj = try toArrayLikeObject(ctx, this_value, "includes");
    defer obj.deinit();
    const target = arg(args, 0);
    if (obj == .array and !obj.array.value.isHoley() and !obj.array.value.isSparse()) return JSValue.fromBool(obj.array.value.includes(target, null));
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    var buf: [32]u8 = undefined;
    var i: usize = if (arg(args, 1) == .undefined) 0 else normIndex(try self.toNumberJS(arg(args, 1)), len);
    while (i < len) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        const item = try self.getProperty(obj, key);
        defer item.deinit();
        if (zvalue.equality.sameValueZero(item, target)) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn arrayJoin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "join");
    defer obj.deinit();
    const self = interp(ctx);
    const sep_arg = arg(args, 0);
    const owned_sep: ?[]const u8 = if (sep_arg == .undefined) null else try self.toDisplayStringJS(allocator, sep_arg);
    defer if (owned_sep) |s| allocator.free(s);
    const sep = owned_sep orelse ",";
    if (obj == .array) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (obj.array.value.toSlice(), 0..) |item, i| {
            if (i > 0) try appendWtf8Merged(&buf, allocator, sep);
            const piece = try Interpreter.joinElementToStringJS(self, item, allocator);
            defer allocator.free(piece);
            try appendWtf8Merged(&buf, allocator, piece);
        }
        return self.gcNewString(buf.items);
    }
    const len = try arrayLikeLength(ctx, obj);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try appendWtf8Merged(&buf, allocator, sep);
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        const piece = try Interpreter.joinElementToStringJS(self, item, allocator);
        defer allocator.free(piece);
        try appendWtf8Merged(&buf, allocator, piece);
    }
    return self.gcNewString(buf.items);
}

fn arraySlice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "slice");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const start_raw = if (arg(args, 0) == .undefined) 0 else try self.toNumberJS(arg(args, 0));
    const end_raw = if (arg(args, 1) == .undefined) @as(f64, @floatFromInt(len)) else try self.toNumberJS(arg(args, 1));
    const start = normIndex(start_raw, len);
    const end = @max(start, normIndex(end_raw, len));
    const count = end - start;
    const sp = try arraySpeciesCreate(self, allocator, obj, count);
    var result = sp.arr;
    errdefer result.deinit();
    if (sp.is_default) {
        if (count > 4294967295) return self.throwError(.range_error, "Invalid array length", .{});
        if (obj == .array and !obj.array.value.isHoley() and !obj.array.value.isSparse()) {
            const slice_items = obj.array.value.toSlice();
            const safe_end = @min(end, slice_items.len);
            const safe_start = @min(start, safe_end);
            for (slice_items[safe_start..safe_end]) |item| {
                _ = try result.array.value.push(item.retain());
            }
            return result;
        }
        var i = start;
        while (i < end) : (i += 1) {
            if (try arrayLikeElem(ctx, allocator, obj, i)) |item| {
                _ = try result.array.value.push(item.retain());
            } else {
                try result.array.value.appendHole();
            }
        }
        return result;
    }
    var n: usize = 0;
    var k = start;
    while (k < end) : (k += 1) {
        if (try arrayLikeElem(ctx, allocator, obj, k)) |item| {
            defer item.deinit();
            try createDataPropertyOrThrow(self, result, n, item);
        }
        n += 1;
    }
    try setArrayLikeLength(self, result, n);
    return result;
}

fn arrayConcat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "concat");
    defer obj.deinit();
    const self = interp(ctx);
    const sp = try arraySpeciesCreate(self, allocator, obj, 0);
    var result = sp.arr;
    errdefer result.deinit();
    var n: usize = 0;

    // Process `obj` followed by each `args` element
    var idx: usize = 0;
    while (idx <= args.len) : (idx += 1) {
        const elem = if (idx == 0) obj else args[idx - 1];
        if (try isConcatSpreadable(self, allocator, elem)) {
            if (sp.is_default and elem == .array and !elem.array.value.isHoley() and !elem.array.value.isSparse() and self.array_props.get(@intFromPtr(elem.array)) == null) {
                const slice_items = elem.array.value.toSlice();
                if (slice_items.len > MAX_ARRAY_LIKE_LEN or n > MAX_ARRAY_LIKE_LEN - slice_items.len) {
                    return self.throwError(.type_error, "Invalid array length", .{});
                }
                for (slice_items) |it| {
                    _ = try result.array.value.push(it.retain());
                }
                n += slice_items.len;
            } else {
                const elen = try arrayLikeLength(ctx, elem);
                if (elen > MAX_ARRAY_LIKE_LEN or n > MAX_ARRAY_LIKE_LEN - elen) {
                    return self.throwError(.type_error, "Invalid array length", .{});
                }
                var k: usize = 0;
                while (k < elen) : (k += 1) {
                    if (try arrayLikeElem(ctx, allocator, elem, k)) |sub| {
                        defer sub.deinit();
                        if (sp.is_default) {
                            _ = try result.array.value.push(sub.retain());
                        } else {
                            try createDataPropertyOrThrow(self, result, n, sub);
                        }
                    } else if (sp.is_default) {
                        try result.array.value.appendHole();
                    }
                    n += 1;
                }
            }
        } else {
            if (n >= MAX_ARRAY_LIKE_LEN) return self.throwError(.type_error, "Invalid array length", .{});
            if (sp.is_default) {
                _ = try result.array.value.push(elem.retain());
            } else {
                try createDataPropertyOrThrow(self, result, n, elem);
            }
            n += 1;
        }
    }
    if (!sp.is_default) try setArrayLikeLength(self, result, n);
    return result;
}

fn arrayReverse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    if (this_value == .array) {
        if (!this_value.array.value.isHoley() and !this_value.array.value.isSparse()) {
            this_value.array.value.reverse();
            return this_value.retain();
        }
        const arr = &this_value.array.value;
        const len = arr.length();
        var lower: usize = 0;
        while (lower < len / 2) : (lower += 1) {
            const upper = len - lower - 1;
            const lower_val = arr.getOpt(lower);
            const upper_val = arr.getOpt(upper);
            if (lower_val != null and upper_val != null) {
                try arr.set(lower, upper_val.?);
                try arr.set(upper, lower_val.?);
            } else if (lower_val != null and upper_val == null) {
                try arr.set(upper, lower_val.?);
                arr.delete(lower);
            } else if (lower_val == null and upper_val != null) {
                try arr.set(lower, upper_val.?);
                arr.delete(upper);
            }
        }
        return this_value.retain();
    }
    const obj = try toArrayLikeObject(ctx, this_value, "reverse");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    var lower: usize = 0;
    while (lower < len / 2) : (lower += 1) {
        const upper = len - lower - 1;
        const lower_val = try arrayLikeElem(ctx, allocator, obj, lower);
        defer if (lower_val) |v| v.deinit();
        const upper_val = try arrayLikeElem(ctx, allocator, obj, upper);
        defer if (upper_val) |v| v.deinit();
        if (lower_val != null and upper_val != null) {
            try setArrayLikeIndex(self, obj, lower, upper_val.?);
            try setArrayLikeIndex(self, obj, upper, lower_val.?);
        } else if (lower_val == null and upper_val != null) {
            try setArrayLikeIndex(self, obj, lower, upper_val.?);
            try deleteArrayLikeIndexOrThrow(self, obj, upper);
        } else if (lower_val != null and upper_val == null) {
            try deleteArrayLikeIndexOrThrow(self, obj, lower);
            try setArrayLikeIndex(self, obj, upper, lower_val.?);
        }
    }
    return obj.retain();
}

/// Live element at `i`, retained so it stays valid across a callback that
/// mutates the array (e.g. `arr.length = k`, which would otherwise free the
/// element and leave a cached `toSlice()` dangling -> "switch on corrupt
/// value"). Null when `i` is now out of bounds (removed mid-iteration ->
/// skip, matching the spec's per-index HasProperty check). The extra ref is
/// reclaimed with the run's arena; callers needn't release it.
fn liveElem(ctx: *anyopaque, allocator: Allocator, array: JSValue, i: usize) anyerror!?JSValue {
    _ = allocator;
    if (i >= array.array.value.length()) return null;
    if (array.array.value.isHole(i)) {
        const self = interp(ctx);
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        if (try self.getFromProto(array, self.protos.array, key)) |v| return v;
        return null;
    }
    return array.array.value.get(i).retain();
}

fn arrayMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "map");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    if (len > 4294967295) return self.throwError(.range_error, "Invalid array length", .{});
    const sp = try arraySpeciesCreate(self, allocator, obj, len);
    var result = sp.arr;
    errdefer result.deinit();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (try arrayLikeElem(ctx, allocator, obj, i)) |item| {
            const v = try callCallbackWithThis(cb, allocator, this_arg, item, i, obj);
            if (sp.is_default) {
                _ = try result.array.value.push(v);
            } else {
                defer v.deinit();
                try createDataPropertyOrThrow(self, result, i, v);
            }
        } else if (sp.is_default) {
            try result.array.value.appendHole();
        }
    }
    return result;
}

fn arrayFilter(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "filter");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    const sp = try arraySpeciesCreate(self, allocator, obj, 0);
    var result = sp.arr;
    errdefer result.deinit();
    var to: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) {
            if (sp.is_default) {
                _ = try result.array.value.push(item.retain());
            } else {
                try createDataPropertyOrThrow(self, result, to, item);
                to += 1;
            }
        }
    }
    return result;
}

fn arrayForEach(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "forEach");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        _ = try callCallbackWithThis(cb, allocator, this_arg, item, i, obj);
    }
    return JSValue.UNDEFINED;
}

fn arrayReduce(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "reduce");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1].retain();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{
            acc, item, JSValue.fromNumber(@floatFromInt(i)), obj,
        });
    }
    if (!have) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn arrayFind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "find");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arraySome(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "some");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

fn arrayEvery(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "every");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (!coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) return JSValue.fromBool(false);
    }
    return JSValue.fromBool(true);
}

fn arrayIsArray(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    return JSValue.fromBool(try isArrayValue(interp(ctx), arg(args, 0)));
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
    const obj = try toArrayLikeObject(ctx, this_value, "at");
    defer obj.deinit();
    const len: isize = @intCast(try arrayLikeLength(ctx, obj));
    const rel = toIntSat(try interp(ctx).toNumberJS(arg(args, 0)));
    const idx = if (rel < 0) len + rel else rel;
    if (idx < 0 or idx >= len) return JSValue.UNDEFINED;
    return (try arrayLikeElem(ctx, allocator, obj, @intCast(idx))) orelse JSValue.UNDEFINED;
}

fn arrayFindIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "findIndex");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFindLast(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "findLast");
    defer obj.deinit();
    var i = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    while (i > 0) {
        i -= 1;
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) return item.retain();
    }
    return JSValue.UNDEFINED;
}

fn arrayFindLastIndex(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "findLastIndex");
    defer obj.deinit();
    var i = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    while (i > 0) {
        i -= 1;
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        if (coercion.isTruthy(try callCallbackWithThis(cb, allocator, this_arg, item, i, obj))) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayReduceRight(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "reduceRight");
    defer obj.deinit();
    var i: usize = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    var acc: JSValue = undefined;
    var have = args.len > 1;
    if (have) acc = args[1].retain();
    while (i > 0) {
        i -= 1;
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (!have) {
            acc = item;
            have = true;
            continue;
        }
        acc = try cb.function.value.call(cb.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ acc, item, JSValue.fromNumber(@floatFromInt(i)), obj });
    }
    if (!have) return interp(ctx).throwError(.type_error, "Reduce of empty array with no initial value", .{});
    return acc;
}

fn arrayFlatMap(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "flatMap");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const cb = try requireCallback(ctx, args);
    const this_arg = if (args.len > 1) args[1] else JSValue.UNDEFINED;
    const sp = try arraySpeciesCreate(self, allocator, obj, 0);
    var result = sp.arr;
    errdefer result.deinit();
    var target_idx: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        const v = try callCallbackWithThis(cb, allocator, this_arg, item, i, obj);
        if (try isArrayValue(self, v)) {
            const vlen = try arrayLikeLength(ctx, v);
            var j: usize = 0;
            while (j < vlen) : (j += 1) {
                const sub = try arrayLikeElem(ctx, allocator, v, j) orelse continue;
                defer sub.deinit();
                if (sp.is_default) {
                    _ = try result.array.value.push(sub.retain());
                } else {
                    try createDataPropertyOrThrow(self, result, target_idx, sub);
                }
                target_idx += 1;
            }
        } else {
            if (sp.is_default) {
                _ = try result.array.value.push(v.retain());
            } else {
                try createDataPropertyOrThrow(self, result, target_idx, v);
            }
            target_idx += 1;
        }
    }
    return result;
}

fn arrayLastIndexOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "lastIndexOf");
    defer obj.deinit();
    const target = arg(args, 0);
    const len = try arrayLikeLength(ctx, obj);
    if (len == 0) return JSValue.fromNumber(-1);
    const self = interp(ctx);
    const n: f64 = if (args.len > 1) blk: {
        const raw = try self.toNumberJS(args[1]);
        if (std.math.isNan(raw) or raw == 0) break :blk 0;
        break :blk @trunc(raw);
    } else @as(f64, @floatFromInt(len - 1));
    if (std.math.isNegativeInf(n)) return JSValue.fromNumber(-1);
    const k: usize = if (n >= 0) blk: {
        const max_k: f64 = @floatFromInt(len - 1);
        break :blk if (n >= max_k) len - 1 else @intFromFloat(n);
    } else blk: {
        const kf = @as(f64, @floatFromInt(len)) + n;
        if (kf < 0) return JSValue.fromNumber(-1);
        break :blk @intFromFloat(kf);
    };
    if (obj == .array and !obj.array.value.isHoley() and !obj.array.value.isSparse()) {
        const slice = obj.array.value.toSlice();
        var i = @min(k + 1, slice.len);
        while (i > 0) {
            i -= 1;
            if (zvalue.equality.strictEquals(slice[i], target)) return JSValue.fromNumber(@floatFromInt(i));
        }
        return JSValue.fromNumber(-1);
    }
    var i = k + 1;
    while (i > 0) {
        i -= 1;
        const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
        if (zvalue.equality.strictEquals(item, target)) return JSValue.fromNumber(@floatFromInt(i));
    }
    return JSValue.fromNumber(-1);
}

fn arrayFill(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    if (this_value == .array) {
        const arr = &this_value.array.value;
        const val = arg(args, 0);
        const start: ?isize = if (arg(args, 1) == .undefined) null else toIntSat(try interp(ctx).toNumberJS(arg(args, 1)));
        const end: ?isize = if (arg(args, 2) == .undefined) null else toIntSat(try interp(ctx).toNumberJS(arg(args, 2)));
        var touched = try arr.slice(start, end);
        defer touched.deinit();
        for (touched.toSlice()) |v| v.deinit();
        for (touched.toSlice()) |_| _ = val.retain();
        arr.fill(val, start, end);
        return this_value.retain();
    }
    const obj = try toArrayLikeObject(ctx, this_value, "fill");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const val = arg(args, 0);
    const start = if (arg(args, 1) == .undefined) 0 else normIndex(try self.toNumberJS(arg(args, 1)), len);
    const end = if (arg(args, 2) == .undefined) len else normIndex(try self.toNumberJS(arg(args, 2)), len);
    var k = start;
    while (k < end) : (k += 1) {
        try setArrayLikeIndex(self, obj, k, val);
    }
    return obj.retain();
}

fn arrayCopyWithin(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    if (this_value == .array) {
        const arr = &this_value.array.value;
        const len = arr.length();
        const target = normIndex(try interp(ctx).toNumberJS(arg(args, 0)), len);
        const start = if (arg(args, 1) == .undefined) 0 else normIndex(try interp(ctx).toNumberJS(arg(args, 1)), len);
        const end = if (arg(args, 2) == .undefined) len else normIndex(try interp(ctx).toNumberJS(arg(args, 2)), len);
        if (start >= end or start == target) return this_value.retain();
        const count = @min(end - start, len - target);
        if (count == 0) return this_value.retain();
        for (arr.toSlice()[start..][0..count]) |v| _ = v.retain();
        for (arr.toSlice()[target..][0..count]) |v| v.deinit();
        arr.copyWithin(@intCast(target), @intCast(start), @intCast(end));
        return this_value.retain();
    }
    const obj = try toArrayLikeObject(ctx, this_value, "copyWithin");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const to = normIndex(try self.toNumberJS(arg(args, 0)), len);
    const from = if (arg(args, 1) == .undefined) 0 else normIndex(try self.toNumberJS(arg(args, 1)), len);
    const final = if (arg(args, 2) == .undefined) len else normIndex(try self.toNumberJS(arg(args, 2)), len);
    if (from >= final or to >= len) return obj.retain();
    const count = @min(final - from, len - to);
    if (count == 0) return obj.retain();
    if (from < to and to < from + count) {
        var rem = count;
        while (rem > 0) {
            rem -= 1;
            const from_idx = from + rem;
            const to_idx = to + rem;
            if (try arrayLikeElem(ctx, allocator, obj, from_idx)) |v| {
                defer v.deinit();
                try setArrayLikeIndex(self, obj, to_idx, v);
            } else {
                try deleteArrayLikeIndexOrThrow(self, obj, to_idx);
            }
        }
    } else {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const from_idx = from + i;
            const to_idx = to + i;
            if (try arrayLikeElem(ctx, allocator, obj, from_idx)) |v| {
                defer v.deinit();
                try setArrayLikeIndex(self, obj, to_idx, v);
            } else {
                try deleteArrayLikeIndexOrThrow(self, obj, to_idx);
            }
        }
    }
    return obj.retain();
}

fn flattenInto(result: *JSValue, allocator: Allocator, arr_val: JSValue, depth: i64) anyerror!void {
    if (arr_val == .array) {
        const arr = &arr_val.array.value;
        var i: usize = 0;
        while (i < arr.length()) : (i += 1) {
            if (arr.isHole(i)) continue;
            const item = arr.get(i);
            if (depth > 0 and item == .array) {
                try flattenInto(result, allocator, item, depth - 1);
            } else {
                _ = try result.array.value.push(item.retain());
            }
        }
    }
}

fn arrayFlat(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "flat");
    defer obj.deinit();
    const self = interp(ctx);
    const depth: i64 = if (arg(args, 0) == .undefined) 1 else toIntSat(try self.toNumberJS(arg(args, 0)));
    const sp = try arraySpeciesCreate(self, allocator, obj, 0);
    var result = sp.arr;
    errdefer result.deinit();
    if (sp.is_default and obj == .array) {
        try flattenInto(&result, allocator, obj, depth);
        return result;
    }
    var tmp = try self.gcNewArray();
    defer tmp.deinit();
    if (obj == .array) {
        try flattenInto(&tmp, allocator, obj, depth);
    } else {
        const len = try arrayLikeLength(ctx, obj);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const item = try arrayLikeElem(ctx, allocator, obj, i) orelse continue;
            defer item.deinit();
            if (depth > 0 and item == .array) {
                try flattenInto(&tmp, allocator, item, depth - 1);
            } else {
                _ = try tmp.array.value.push(item.retain());
            }
        }
    }
    for (tmp.array.value.toSlice(), 0..) |it, idx| {
        if (sp.is_default) {
            _ = try result.array.value.push(it.retain());
        } else {
            try createDataPropertyOrThrow(self, result, idx, it);
        }
    }
    return result;
}

fn arrayToReversed(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const obj = try toArrayLikeObject(ctx, this_value, "toReversed");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    if (len > 4294967295) return interp(ctx).throwError(.range_error, "Invalid array length", .{});
    var result = try interp(ctx).gcNewArray();
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        _ = try result.array.value.push(item.retain());
    }
    return result;
}

fn arrayToSorted(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "toSorted");
    defer obj.deinit();
    const cmp = arg(args, 0);
    const self = interp(ctx);
    if (cmp != .undefined and cmp != .function) return self.throwError(.type_error, "The comparison function must be either a function or undefined", .{});
    const len = try arrayLikeLength(ctx, obj);
    if (len > 4294967295) return interp(ctx).throwError(.range_error, "Invalid array length", .{});
    const items = try allocator.alloc(JSValue, len);
    defer allocator.free(items);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        items[i] = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
    }
    var idx: usize = 1;
    while (idx < len) : (idx += 1) {
        const key = items[idx];
        var j = idx;
        while (j > 0) {
            const before = try sortLess(self, allocator, cmp, key, items[j - 1]);
            if (!before) break;
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
    var result = try interp(ctx).gcNewArray();
    for (items) |it| _ = try result.array.value.push(it.retain());
    return result;
}

fn arrayToSpliced(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "toSpliced");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const start_raw = if (args.len == 0) 0 else try interp(ctx).toNumberJS(arg(args, 0));
    const start_int = toIntSat(start_raw);
    const actual_start: usize = if (start_int < 0) blk: {
        const p = @as(isize, @intCast(len)) + start_int;
        break :blk if (p < 0) 0 else @intCast(p);
    } else @min(@as(usize, @intCast(start_int)), len);

    const delete_count: usize = if (args.len <= 1)
        len - actual_start
    else blk: {
        const dc = try interp(ctx).toNumberJS(arg(args, 1));
        if (dc <= 0) break :blk 0;
        break :blk @min(@as(usize, @intCast(toIntSat(dc))), len - actual_start);
    };

    const raw_inserts = if (args.len > 2) args[2..] else &[_]JSValue{};
    const new_len = len + raw_inserts.len - delete_count;
    if (new_len > 4294967295) return interp(ctx).throwError(.range_error, "Invalid array length", .{});

    var result = try interp(ctx).gcNewArray();
    var i: usize = 0;
    while (i < actual_start) : (i += 1) {
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        _ = try result.array.value.push(item.retain());
    }
    for (raw_inserts) |ins| _ = try result.array.value.push(ins.retain());
    i = actual_start + delete_count;
    while (i < len) : (i += 1) {
        const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
        _ = try result.array.value.push(item.retain());
    }
    return result;
}

fn arrayWith(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = try toArrayLikeObject(ctx, this_value, "with");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    const raw_index = try interp(ctx).toNumberJS(arg(args, 0));
    const actual_index = toIntSat(raw_index);
    const idx: usize = if (actual_index < 0) blk: {
        const p = @as(isize, @intCast(len)) + actual_index;
        if (p < 0 or p >= len) return interp(ctx).throwError(.range_error, "Invalid index", .{});
        break :blk @intCast(p);
    } else blk: {
        if (actual_index >= len) return interp(ctx).throwError(.range_error, "Invalid index", .{});
        break :blk @intCast(actual_index);
    };
    const value = arg(args, 1);
    var result = try interp(ctx).gcNewArray();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i == idx) {
            _ = try result.array.value.push(value.retain());
        } else {
            const item = (try arrayLikeElem(ctx, allocator, obj, i)) orelse JSValue.UNDEFINED;
            _ = try result.array.value.push(item.retain());
        }
    }
    return result;
}

fn arraySplice(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    if (this_value == .array) {
        const arr = &this_value.array.value;
        const start: isize = if (args.len == 0) 0 else toIntSat(try interp(ctx).toNumberJS(arg(args, 0)));
        const delete_count: ?usize = if (args.len == 0)
            0
        else if (args.len == 1)
            null
        else blk: {
            const dc = try interp(ctx).toNumberJS(arg(args, 1));
            if (dc <= 0) break :blk 0;
            break :blk @intCast(toIntSat(dc));
        };
        const raw_inserts = if (args.len > 2) args[2..] else &[_]JSValue{};
        const inserts = try allocator.alloc(JSValue, raw_inserts.len);
        defer allocator.free(inserts);
        for (raw_inserts, 0..) |item, i| inserts[i] = item.retain();

        var deleted = try arr.splice(start, delete_count, inserts);
        defer deleted.deinit();
        const self = interp(ctx);
        const del_slice = deleted.toSlice();
        const sp = try arraySpeciesCreate(self, allocator, this_value, del_slice.len);
        var removed = sp.arr;
        errdefer removed.deinit();
        if (sp.is_default) {
            for (del_slice) |item| _ = try removed.array.value.push(item);
        } else {
            for (del_slice, 0..) |item, idx| {
                defer item.deinit();
                try createDataPropertyOrThrow(self, removed, idx, item);
            }
            try setArrayLikeLength(self, removed, del_slice.len);
        }
        return removed;
    }
    const obj = try toArrayLikeObject(ctx, this_value, "splice");
    defer obj.deinit();
    const self = interp(ctx);
    const len = try arrayLikeLength(ctx, obj);
    const actual_start = if (args.len == 0) 0 else normIndex(try self.toNumberJS(args[0]), len);
    const actual_delete_count: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - actual_start
    else blk: {
        const dc = try self.toNumberJS(args[1]);
        if (dc <= 0) break :blk 0;
        break :blk @min(@as(usize, @intCast(toIntSat(dc))), len - actual_start);
    };
    const items = if (args.len > 2) args[2..] else &[_]JSValue{};
    if (len - actual_delete_count > MAX_ARRAY_LIKE_LEN - items.len) {
        return self.throwError(.type_error, "Invalid array length", .{});
    }
    var removed = try self.gcNewArray();
    var k: usize = 0;
    while (k < actual_delete_count) : (k += 1) {
        if (try arrayLikeElem(ctx, allocator, obj, actual_start + k)) |v| {
            _ = try removed.array.value.push(v);
        } else {
            try removed.array.value.appendHole();
        }
    }
    if (items.len < actual_delete_count) {
        var from = actual_start + actual_delete_count;
        while (from < len) : (from += 1) {
            const to = from - actual_delete_count + items.len;
            if (try arrayLikeElem(ctx, allocator, obj, from)) |v| {
                defer v.deinit();
                try setArrayLikeIndex(self, obj, to, v);
            } else {
                try deleteArrayLikeIndexOrThrow(self, obj, to);
            }
        }
        var d = len;
        const target_len = len - actual_delete_count + items.len;
        while (d > target_len) {
            d -= 1;
            try deleteArrayLikeIndexOrThrow(self, obj, d);
        }
    } else if (items.len > actual_delete_count) {
        var from = len;
        while (from > actual_start + actual_delete_count) {
            from -= 1;
            const to = from - actual_delete_count + items.len;
            if (try arrayLikeElem(ctx, allocator, obj, from)) |v| {
                defer v.deinit();
                try setArrayLikeIndex(self, obj, to, v);
            } else {
                try deleteArrayLikeIndexOrThrow(self, obj, to);
            }
        }
    }
    for (items, 0..) |ins, j| {
        try setArrayLikeIndex(self, obj, actual_start + j, ins);
    }
    try setArrayLikeLength(self, obj, len - actual_delete_count + items.len);
    return removed;
}

fn arraySort(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const cmp = arg(args, 0);
    if (cmp != .undefined and cmp != .function) return self.throwError(.type_error, "The comparison function must be either a function or undefined", .{});
    if (this_value == .array) {
        const arr = &this_value.array.value;
        const n = arr.length();
        var i: usize = 1;
        const mut = arr.toSliceMut();
        while (i < n) : (i += 1) {
            const key = mut[i];
            var j = i;
            while (j > 0) {
                const before = try sortLess(self, allocator, cmp, key, mut[j - 1]);
                if (!before) break;
                mut[j] = mut[j - 1];
                j -= 1;
            }
            mut[j] = key;
        }
        return this_value.retain();
    }
    const obj = try toArrayLikeObject(ctx, this_value, "sort");
    defer obj.deinit();
    const len = try arrayLikeLength(ctx, obj);
    var items: std.ArrayList(JSValue) = .empty;
    defer {
        for (items.items) |it| it.deinit();
        items.deinit(allocator);
    }
    var idx: usize = 0;
    while (idx < len) : (idx += 1) {
        if (try arrayLikeElem(ctx, allocator, obj, idx)) |v| {
            try items.append(allocator, v);
        }
    }
    var i: usize = 1;
    while (i < items.items.len) : (i += 1) {
        const key = items.items[i];
        var j = i;
        while (j > 0) {
            const before = try sortLess(self, allocator, cmp, key, items.items[j - 1]);
            if (!before) break;
            items.items[j] = items.items[j - 1];
            j -= 1;
        }
        items.items[j] = key;
    }
    for (items.items, 0..) |it, j| {
        try setArrayLikeIndex(self, obj, j, it);
    }
    var d = items.items.len;
    while (d < len) : (d += 1) {
        try deleteArrayLikeIndexOrThrow(self, obj, d);
    }
    return obj.retain();
}

/// Whether `a` should sort before `b` (comparator < 0, or default string
/// order). undefined always sorts last (spec).
fn sortLess(self: *Interpreter, allocator: Allocator, cmp: JSValue, a: JSValue, b: JSValue) anyerror!bool {
    if (a == .undefined) return false;
    if (b == .undefined) return true;
    if (cmp == .function) {
        const r = try cmp.function.value.call(cmp.function.value.ctx, allocator, JSValue.UNDEFINED, &.{ a, b });
        return (try self.toNumberJS(r)) < 0;
    }
    const sa = try self.toDisplayStringJS(allocator, a);
    defer allocator.free(sa);
    const sb = try self.toDisplayStringJS(allocator, b);
    defer allocator.free(sb);
    return std.mem.order(u8, sa, sb) == .lt;
}

fn arrayToStringMethod(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const obj = try toArrayLikeObject(ctx, this_value, "toString");
    defer obj.deinit();
    const self = interp(ctx);
    if (obj == .array) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        for (obj.array.value.toSlice(), 0..) |item, i| {
            if (i > 0) try appendWtf8Merged(&buf, allocator, ",");
            const piece = try Interpreter.joinElementToStringJS(self, item, allocator);
            defer allocator.free(piece);
            try appendWtf8Merged(&buf, allocator, piece);
        }
        return self.gcNewString(buf.items);
    }
    const join_fn = try self.getProperty(obj, "join");
    defer join_fn.deinit();
    if (join_fn == .function) {
        return try join_fn.function.value.call(join_fn.function.value.ctx, allocator, obj, &.{});
    }
    return object_builtins.objToString(ctx, allocator, obj, &.{});
}

fn arrayKeys(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const obj = try toArrayLikeObject(ctx, this_value, "keys");
    defer obj.deinit();
    return makeArrayIterator(interp(ctx), allocator, obj, .keys);
}

fn arrayValues(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const obj = try toArrayLikeObject(ctx, this_value, "values");
    defer obj.deinit();
    return makeArrayIterator(interp(ctx), allocator, obj, .values);
}

fn arrayEntries(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const obj = try toArrayLikeObject(ctx, this_value, "entries");
    defer obj.deinit();
    return makeArrayIterator(interp(ctx), allocator, obj, .entries);
}

/// Installs the `Array` constructor + statics.
pub fn install(self: *Interpreter) !void {
    // Array: constructable (new Array(n) / Array(a, b, c)) + statics.
    _ = try installBuiltin(self, .{ .name = "Array", .ctor = .{ .arity = 1, .call = arrayConstructor, .constructable = true }, .statics = &.{
        .{ .name = "isArray", .value = .{ .method = .{ .call = arrayIsArray, .arity = 1 } } },
        .{ .name = "of", .value = .{ .method = .{ .call = arrayOf, .arity = 0 } } },
        .{ .name = "from", .value = .{ .method = .{ .call = arrayFrom, .arity = 1 } } },
    } });
}
