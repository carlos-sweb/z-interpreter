//! `JSON`: a statics-only namespace, no constructor, no prototype.
//! Full ECMA-262 JSON.parse(text, reviver) and JSON.stringify(value, replacer, space).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zjson = @import("zjson");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const property_desc = @import("property_desc.zig");
const object_builtins = @import("object_builtins.zig");

pub const NativeFn = native_helpers.NativeFn;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const installBuiltin = builtin_helpers.installBuiltin;

fn isArrayValue(self: *Interpreter, v: JSValue) anyerror!bool {
    var cur = v;
    while (cur.isProxy()) {
        if (cur.asProxy().value.handler.isNull()) {
            return self.throwError(.type_error, "Cannot perform 'IsArray' on a proxy that has been revoked", .{});
        }
        cur = cur.asProxy().value.target;
    }
    return cur.isArray();
}

fn createDataProperty(self: *Interpreter, obj: JSValue, key: []const u8, val: JSValue) anyerror!bool {
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
    return property_desc.defineOwnProperty(self, obj, key, &d);
}

const StringifyState = struct {
    self: *Interpreter,
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(usize) = .empty,
    replacer_fn: ?JSValue = null,
    property_list: ?std.ArrayList([]const u8) = null,
    gap: []const u8 = "",
    gap_owned: bool = false,
    indent: std.ArrayList(u8) = .empty,

    fn deinit(st: *StringifyState) void {
        st.buf.deinit(st.allocator);
        st.stack.deinit(st.allocator);
        if (st.property_list) |*pl| {
            for (pl.items) |k| st.allocator.free(k);
            pl.deinit(st.allocator);
        }
        if (st.gap_owned) st.allocator.free(st.gap);
        st.indent.deinit(st.allocator);
    }
};

fn quoteJsonString(buf: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        switch (b) {
            '"' => {
                try buf.appendSlice(allocator, "\\\"");
                i += 1;
            },
            '\\' => {
                try buf.appendSlice(allocator, "\\\\");
                i += 1;
            },
            0x08 => {
                try buf.appendSlice(allocator, "\\b");
                i += 1;
            },
            0x0C => {
                try buf.appendSlice(allocator, "\\f");
                i += 1;
            },
            '\n' => {
                try buf.appendSlice(allocator, "\\n");
                i += 1;
            },
            '\r' => {
                try buf.appendSlice(allocator, "\\r");
                i += 1;
            },
            '\t' => {
                try buf.appendSlice(allocator, "\\t");
                i += 1;
            },
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var esc: [6]u8 = undefined;
                const slice = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{b}) catch unreachable;
                try buf.appendSlice(allocator, slice);
                i += 1;
            },
            0xED => {
                // Lone WTF-8 surrogate (U+D800..U+DFFF): 0xED 0xA0..0xBF 0x80..0xBF
                if (i + 2 < s.len and s[i + 1] >= 0xA0 and s[i + 1] <= 0xBF and (s[i + 2] & 0xC0) == 0x80) {
                    const cp: u32 = (@as(u32, s[i] & 0x0F) << 12) | (@as(u32, s[i + 1] & 0x3F) << 6) | @as(u32, s[i + 2] & 0x3F);
                    var esc: [6]u8 = undefined;
                    const slice = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{cp}) catch unreachable;
                    try buf.appendSlice(allocator, slice);
                    i += 3;
                } else {
                    try buf.append(allocator, b);
                    i += 1;
                }
            },
            else => {
                try buf.append(allocator, b);
                i += 1;
            },
        }
    }
    try buf.append(allocator, '"');
}

fn serializeJsonArray(st: *StringifyState, value: JSValue) anyerror!void {
    const self = st.self;
    const len_v = try self.getProperty(value, "length");
    defer len_v.deinit();
    const len = try builtin_helpers.toLength(self, len_v);
    if (len == 0) {
        try st.buf.appendSlice(st.allocator, "[]");
        return;
    }
    const prev_indent_len = st.indent.items.len;
    if (st.gap.len > 0) try st.indent.appendSlice(st.allocator, st.gap);
    defer st.indent.shrinkRetainingCapacity(prev_indent_len);

    try st.buf.append(st.allocator, '[');
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try st.buf.append(st.allocator, ',');
        if (st.gap.len > 0) {
            try st.buf.append(st.allocator, '\n');
            try st.buf.appendSlice(st.allocator, st.indent.items);
        }
        var kbuf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch unreachable;
        const wrote = try serializeJsonProperty(st, key, value);
        if (!wrote) try st.buf.appendSlice(st.allocator, "null");
    }
    if (st.gap.len > 0) {
        try st.buf.append(st.allocator, '\n');
        try st.buf.appendSlice(st.allocator, st.indent.items[0..prev_indent_len]);
    }
    try st.buf.append(st.allocator, ']');
}

fn isInternalKey(k: []const u8) bool {
    return k.len >= 2 and k[0] == 0 and (k[1] == 'S' or k[1] == 'P');
}

fn serializeJsonObject(st: *StringifyState, value: JSValue) anyerror!void {
    const self = st.self;
    var owned_keys: ?[][]const u8 = null;
    defer if (owned_keys) |ks| {
        for (ks) |k| st.allocator.free(k);
        st.allocator.free(ks);
    };
    const keys: []const []const u8 = if (st.property_list) |pl|
        pl.items
    else blk: {
        const ks = try object_builtins.ownEnumerableKeys(@ptrCast(self), st.allocator, value);
        owned_keys = ks;
        break :blk ks;
    };

    const prev_indent_len = st.indent.items.len;
    if (st.gap.len > 0) try st.indent.appendSlice(st.allocator, st.gap);
    defer st.indent.shrinkRetainingCapacity(prev_indent_len);

    const start_pos = st.buf.items.len;
    try st.buf.append(st.allocator, '{');
    var count: usize = 0;
    for (keys) |k| {
        if (isInternalKey(k)) continue;
        const before_prop = st.buf.items.len;
        if (count > 0) try st.buf.append(st.allocator, ',');
        if (st.gap.len > 0) {
            try st.buf.append(st.allocator, '\n');
            try st.buf.appendSlice(st.allocator, st.indent.items);
        }
        try quoteJsonString(&st.buf, st.allocator, k);
        try st.buf.append(st.allocator, ':');
        if (st.gap.len > 0) try st.buf.append(st.allocator, ' ');
        const wrote = try serializeJsonProperty(st, k, value);
        if (wrote) {
            count += 1;
        } else {
            st.buf.shrinkRetainingCapacity(before_prop);
        }
    }
    if (count == 0) {
        st.buf.shrinkRetainingCapacity(start_pos);
        try st.buf.appendSlice(st.allocator, "{}");
        return;
    }
    if (st.gap.len > 0) {
        try st.buf.append(st.allocator, '\n');
        try st.buf.appendSlice(st.allocator, st.indent.items[0..prev_indent_len]);
    }
    try st.buf.append(st.allocator, '}');
}

fn serializeJsonProperty(st: *StringifyState, key: []const u8, holder: JSValue) anyerror!bool {
    const self = st.self;
    var value = try self.getProperty(holder, key);
    defer value.deinit();

    if (builtin_helpers.isObjectLike(value) or value.isBigInt()) {
        const to_json = try self.getProperty(value, "toJSON");
        defer to_json.deinit();
        if (property_desc.isCallable(to_json)) {
            const key_val = try self.gcNewString(key);
            defer key_val.deinit();
            const next = try self.callValue(to_json, value, &.{key_val}, "toJSON");
            value.deinit();
            value = next;
        }
    }

    if (st.replacer_fn) |rfn| {
        const key_val = try self.gcNewString(key);
        defer key_val.deinit();
        const next = try self.callValue(rfn, holder, &.{ key_val, value }, "replacer");
        value.deinit();
        value = next;
    }

    if (value.isObject()) {
        if (self.primitive_wrapper_data.get(@intFromPtr(value.asObject()))) |boxed| {
            if (boxed.isNumber()) {
                const n = try builtin_helpers.toNumberStrict(self, value);
                value.deinit();
                value = JSValue.fromNumber(n);
            } else if (boxed.isString()) {
                const s = try self.toDisplayStringJS(st.allocator, value);
                defer st.allocator.free(s);
                value.deinit();
                value = try self.gcNewString(s);
            } else if (boxed.isBool()) {
                const b = boxed.asBool();
                value.deinit();
                value = JSValue.fromBool(b);
            } else if (boxed.isBigInt()) {
                const bi = boxed.retain();
                value.deinit();
                value = bi;
            }
        }
    }

    switch (value.unpack()) {
        .null => {
            try st.buf.appendSlice(st.allocator, "null");
            return true;
        },
        .boolean => |b| {
            try st.buf.appendSlice(st.allocator, if (b) "true" else "false");
            return true;
        },
        .string => |box| {
            try quoteJsonString(&st.buf, st.allocator, box.value.data);
            return true;
        },
        .number => |n| {
            if (std.math.isFinite(n)) {
                const s = try coercion.toDisplayString(st.allocator, value);
                defer st.allocator.free(s);
                try st.buf.appendSlice(st.allocator, s);
            } else {
                try st.buf.appendSlice(st.allocator, "null");
            }
            return true;
        },
        .bigint => return self.throwError(.type_error, "Do not know how to serialize a BigInt", .{}),
        .undefined, .symbol => return false,
        else => {},
    }

    if (property_desc.isCallable(value)) return false;

    const addr = Interpreter.heapBoxAddress(value) orelse 0;
    if (addr != 0) {
        for (st.stack.items) |prev| {
            if (prev == addr) return self.throwError(.type_error, "Converting circular structure to JSON", .{});
        }
        try st.stack.append(st.allocator, addr);
    }
    defer if (addr != 0) {
        _ = st.stack.pop();
    };

    if (try isArrayValue(self, value)) {
        try serializeJsonArray(st, value);
    } else {
        try serializeJsonObject(st, value);
    }
    return true;
}

fn truncateUtf16Units(s: []const u8, max_units: usize) []const u8 {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len and units < max_units) {
        const b = s[i];
        const seq_len: usize = if (b < 0x80) 1 else if ((b & 0xE0) == 0xC0) 2 else if ((b & 0xF0) == 0xE0) 3 else 4;
        if (i + seq_len > s.len) break;
        const u: usize = if (seq_len == 4) 2 else 1;
        if (units + u > max_units) break;
        units += u;
        i += seq_len;
    }
    return s[0..i];
}

fn jsonStringify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const v = arg(args, 0);
    const replacer = arg(args, 1);
    const space_arg = arg(args, 2);

    var st = StringifyState{ .self = self, .allocator = allocator };
    defer st.deinit();

    if (builtin_helpers.isObjectLike(replacer)) {
        if (property_desc.isCallable(replacer)) {
            st.replacer_fn = replacer;
        } else if (try isArrayValue(self, replacer)) {
            var pl: std.ArrayList([]const u8) = .empty;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            errdefer {
                for (pl.items) |k| allocator.free(k);
                pl.deinit(allocator);
            }
            const len_v = try self.getProperty(replacer, "length");
            defer len_v.deinit();
            const len = try builtin_helpers.toLength(self, len_v);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                var kbuf: [32]u8 = undefined;
                const k = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch unreachable;
                const item = try self.getProperty(replacer, k);
                defer item.deinit();
                var item_str: ?[]const u8 = null;
                if (item.isString()) {
                    item_str = try allocator.dupe(u8, item.asString().value.data);
                } else if (item.isNumber()) {
                    item_str = try coercion.toDisplayString(allocator, item);
                } else if (item.isObject()) {
                    if (self.primitive_wrapper_data.get(@intFromPtr(item.asObject()))) |boxed| {
                        if (boxed.isString() or boxed.isNumber()) {
                            item_str = try self.toDisplayStringJS(allocator, item);
                        }
                    }
                }
                if (item_str) |s| {
                    if (seen.contains(s)) {
                        allocator.free(s);
                    } else {
                        try seen.put(allocator, s, {});
                        try pl.append(allocator, s);
                    }
                }
            }
            st.property_list = pl;
        }
    }

    var space_val = space_arg.retain();
    defer space_val.deinit();
    if (space_val.isObject()) {
        if (self.primitive_wrapper_data.get(@intFromPtr(space_val.asObject()))) |boxed| {
            if (boxed.isNumber()) {
                const n = try builtin_helpers.toNumberStrict(self, space_val);
                space_val.deinit();
                space_val = JSValue.fromNumber(n);
            } else if (boxed.isString()) {
                const s = try self.toDisplayStringJS(allocator, space_val);
                defer allocator.free(s);
                space_val.deinit();
                space_val = try self.gcNewString(s);
            }
        }
    }
    if (space_val.isNumber()) {
        const n = space_val.asNumber();
        const clamped: usize = if (std.math.isNan(n) or n <= 0) 0 else @intFromFloat(@min(@trunc(n), 10.0));
        const spaces = "          ";
        st.gap = spaces[0..clamped];
    } else if (space_val.isString()) {
        const trunc = truncateUtf16Units(space_val.asString().value.data, 10);
        if (trunc.len > 0) {
            st.gap = try allocator.dupe(u8, trunc);
            st.gap_owned = true;
        }
    }

    const wrapper = try self.ordinaryObject();
    defer wrapper.deinit();
    try wrapper.asObject().value.set("", v.retain());

    const wrote = try serializeJsonProperty(&st, "", wrapper);
    if (!wrote) return JSValue.UNDEFINED;
    return self.gcNewString(st.buf.items);
}

const ParseRecord = union(enum) {
    primitive: struct { src: []const u8, val: JSValue },
    array: []const ParseRecord,
    object: std.StringHashMapUnmanaged(ParseRecord),
};

const JsonSourceScanner = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,

    fn skipWs(s: *JsonSourceScanner) void {
        while (s.pos < s.src.len) : (s.pos += 1) {
            switch (s.src[s.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => break,
            }
        }
    }

    fn scanStringRaw(s: *JsonSourceScanner) []const u8 {
        const start = s.pos;
        s.pos += 1; // opening '"'
        while (s.pos < s.src.len) {
            const b = s.src[s.pos];
            if (b == '\\') {
                s.pos += 2;
            } else if (b == '"') {
                s.pos += 1;
                break;
            } else {
                s.pos += 1;
            }
        }
        return s.src[start..s.pos];
    }

    fn scanValue(s: *JsonSourceScanner, val: JSValue) anyerror!ParseRecord {
        s.skipWs();
        if (s.pos >= s.src.len) return .{ .primitive = .{ .src = "", .val = val } };
        switch (s.src[s.pos]) {
            '[' => {
                s.pos += 1;
                s.skipWs();
                var items: std.ArrayList(ParseRecord) = .empty;
                if (s.pos < s.src.len and s.src[s.pos] == ']') {
                    s.pos += 1;
                    return .{ .array = items.items };
                }
                var idx: usize = 0;
                while (s.pos < s.src.len) {
                    const elem_val = if (val.isArray() and idx < val.asArray().value.length())
                        val.asArray().value.get(idx)
                    else
                        JSValue.UNDEFINED;
                    try items.append(s.arena, try s.scanValue(elem_val));
                    idx += 1;
                    s.skipWs();
                    if (s.pos < s.src.len and s.src[s.pos] == ',') {
                        s.pos += 1;
                        continue;
                    }
                    if (s.pos < s.src.len and s.src[s.pos] == ']') s.pos += 1;
                    break;
                }
                return .{ .array = items.items };
            },
            '{' => {
                s.pos += 1;
                s.skipWs();
                var map: std.StringHashMapUnmanaged(ParseRecord) = .empty;
                if (s.pos < s.src.len and s.src[s.pos] == '}') {
                    s.pos += 1;
                    return .{ .object = map };
                }
                while (s.pos < s.src.len) {
                    s.skipWs();
                    const raw_key = s.scanStringRaw();
                    // Decode key via zjson.parse so escapes match JS object key
                    const key_val = zjson.parse(s.arena, raw_key) catch null;
                    const key_str: []const u8 = if (key_val) |kv|
                        if (kv.isString()) kv.asString().value.data else raw_key[1 .. raw_key.len - 1]
                    else
                        raw_key[1 .. raw_key.len - 1];
                    s.skipWs();
                    if (s.pos < s.src.len and s.src[s.pos] == ':') s.pos += 1;
                    const prop_val = if (val.isObject())
                        val.asObject().value.get(key_str) orelse JSValue.UNDEFINED
                    else
                        JSValue.UNDEFINED;
                    const rec = try s.scanValue(prop_val);
                    try map.put(s.arena, key_str, rec);
                    s.skipWs();
                    if (s.pos < s.src.len and s.src[s.pos] == ',') {
                        s.pos += 1;
                        continue;
                    }
                    if (s.pos < s.src.len and s.src[s.pos] == '}') s.pos += 1;
                    break;
                }
                return .{ .object = map };
            },
            '"' => {
                const raw = s.scanStringRaw();
                return .{ .primitive = .{ .src = raw, .val = val } };
            },
            else => {
                const start = s.pos;
                while (s.pos < s.src.len) {
                    switch (s.src[s.pos]) {
                        ' ', '\t', '\n', '\r', ',', ']', '}' => break,
                        else => s.pos += 1,
                    }
                }
                return .{ .primitive = .{ .src = s.src[start..s.pos], .val = val } };
            },
        }
    }
};

fn internalizeJsonProperty(self: *Interpreter, allocator: Allocator, holder: JSValue, name: []const u8, reviver: JSValue, parse_rec: ?ParseRecord) anyerror!JSValue {
    const val = try self.getProperty(holder, name);
    defer val.deinit();
    const context = try self.ordinaryObject();
    defer context.deinit();
    if (builtin_helpers.isObjectLike(val)) {
        if (try isArrayValue(self, val)) {
            const len_v = try self.getProperty(val, "length");
            defer len_v.deinit();
            const len = try builtin_helpers.toLength(self, len_v);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                var kbuf: [32]u8 = undefined;
                const k = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch unreachable;
                const child_rec: ?ParseRecord = if (parse_rec) |pr| switch (pr) {
                    .array => |arr| if (i < arr.len) arr[i] else null,
                    else => null,
                } else null;
                const new_el = try internalizeJsonProperty(self, allocator, val, k, reviver, child_rec);
                defer new_el.deinit();
                if (new_el.isUndefined()) {
                    _ = try self.deletePropertyOnValue(val, k);
                } else {
                    _ = try createDataProperty(self, val, k, new_el);
                }
            }
        } else {
            const keys = try object_builtins.ownEnumerableKeys(@ptrCast(self), allocator, val);
            defer {
                for (keys) |k| allocator.free(k);
                allocator.free(keys);
            }
            for (keys) |k| {
                if (isInternalKey(k)) continue;
                const child_rec: ?ParseRecord = if (parse_rec) |pr| switch (pr) {
                    .object => |m| m.get(k),
                    else => null,
                } else null;
                const new_el = try internalizeJsonProperty(self, allocator, val, k, reviver, child_rec);
                defer new_el.deinit();
                if (new_el.isUndefined()) {
                    _ = try self.deletePropertyOnValue(val, k);
                } else {
                    _ = try createDataProperty(self, val, k, new_el);
                }
            }
        }
    } else if (parse_rec) |pr| {
        if (pr == .primitive and zvalue.equality.strictEquals(val, pr.primitive.val)) {
            try context.asObject().value.set("source", try self.gcNewString(pr.primitive.src));
        }
    }
    const name_val = try self.gcNewString(name);
    defer name_val.deinit();
    return self.callValue(reviver, holder, &.{ name_val, val, context }, "reviver");
}

fn jsonParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const json_str = try self.toDisplayStringJS(allocator, arg(args, 0));
    defer allocator.free(json_str);
    const unfiltered = zjson.parse(allocator, json_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError(.syntax_error, "Unexpected token in JSON", .{}),
    };
    try self.gcAdoptTree(unfiltered);
    const reviver = arg(args, 1);
    if (!property_desc.isCallable(reviver)) return unfiltered;

    var rec_arena = std.heap.ArenaAllocator.init(allocator);
    defer rec_arena.deinit();
    var scanner = JsonSourceScanner{ .src = json_str, .arena = rec_arena.allocator() };
    const root_rec = try scanner.scanValue(unfiltered);

    const root = try self.ordinaryObject();
    defer root.deinit();
    try root.asObject().value.set("", unfiltered);
    return internalizeJsonProperty(self, allocator, root, "", reviver, root_rec);
}

/// Installs the `JSON` namespace (no constructor).
pub fn install(self: *Interpreter) !void {
    _ = try installBuiltin(self, .{ .name = "JSON", .statics = &.{
        .{ .name = "stringify", .value = .{ .method = .{ .call = jsonStringify, .arity = 3 } } },
        .{ .name = "parse", .value = .{ .method = .{ .call = jsonParse, .arity = 2 } } },
    } });
}
