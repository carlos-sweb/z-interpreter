const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const JSValue = zvalue.JSValue;

/// A small, standalone `console.log`-style renderer -- deliberately NOT
/// `z-json`'s `stringify()`: JSON.stringify's rules (omits undefined/
/// functions, quotes every string) are wrong for console.log (top-level
/// strings shouldn't be quoted; undefined/functions should still print
/// something). Not spec-exact (real `util.inspect` is a large algorithm on
/// its own) -- just legible and non-crashing for every JSValue shape.
pub fn inspect(allocator: Allocator, buf: *std.ArrayList(u8), v: JSValue) !void {
    switch (v) {
        .@"undefined" => try buf.appendSlice(allocator, "undefined"),
        .@"null" => try buf.appendSlice(allocator, "null"),
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .number => |n| {
            const s = try znumber.FormattingMethods.toString(n, allocator, null);
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .string => |box| try buf.appendSlice(allocator, box.value.data),
        .array => |box| {
            try buf.append(allocator, '[');
            for (box.value.toSlice(), 0..) |item, i| {
                if (i != 0) try buf.appendSlice(allocator, ", ");
                try inspect(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |box| {
            try buf.appendSlice(allocator, "{ ");
            const keys = try box.value.keys(allocator);
            defer allocator.free(keys);
            for (keys, 0..) |key, i| {
                if (i != 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, key);
                try buf.appendSlice(allocator, ": ");
                try inspect(allocator, buf, box.value.get(key).?);
            }
            try buf.appendSlice(allocator, " }");
        },
        .function => |box| {
            try buf.appendSlice(allocator, "[Function");
            if (box.value.name.len > 0) {
                try buf.append(allocator, ':');
                try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, box.value.name);
            }
            try buf.append(allocator, ']');
        },
        .symbol => try buf.appendSlice(allocator, "[Symbol]"),
        .regex => try buf.appendSlice(allocator, "[RegExp]"),
        .map => try buf.appendSlice(allocator, "[Map]"),
        .set => try buf.appendSlice(allocator, "[Set]"),
        .@"error" => try buf.appendSlice(allocator, "[Error]"),
    }
}

/// Writes every arg's `inspect()` rendering, space-separated, plus a
/// trailing newline -- matching Node's `console.log` convention.
pub fn writeConsoleLog(allocator: Allocator, writer: *std.Io.Writer, args: []const JSValue) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (args, 0..) |arg, i| {
        if (i != 0) try buf.append(allocator, ' ');
        try inspect(allocator, &buf, arg);
    }
    try buf.append(allocator, '\n');
    try writer.writeAll(buf.items);
}
