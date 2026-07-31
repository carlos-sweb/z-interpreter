//! z-interpreter-refactor.md, Step 1a: the regression test the `.temporal`
//! leak bug should have tripped immediately, if it had existed. `gcTrack`'s
//! `else => return;` fallback has NO compiler exhaustiveness check -- a new
//! JSValue variant added without also adding a `gcTrack` case is silently
//! dropped from the GC registry (a permanent leak) instead of failing to
//! compile or failing a test. That's exactly what happened with `.temporal`.
//!
//! `makeOneOf` below switches on every `JSValue` tag with NO `else` branch,
//! so it alone already forces a compile error the day a new variant is
//! added. The `inline for (std.meta.fields(JSValue))` loop in the test
//! walks the union's field list at comptime, so covering a new variant here
//! requires touching this file (compile error until you do), not trusting
//! someone to remember. Each constructed value is tracked via the normal
//! `gcNew*`/`gcTrack` path and immediately released; `testing.allocator`
//! (not the arena) catches any leak on either front: a case unregistered by
//! `gcTrack`, or a container-shaped value whose registry entry never gets
//! swept.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

fn dummyNativeCall(ctx: *anyopaque, allocator: std.mem.Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = this_value;
    _ = args;
    return JSValue.UNDEFINED;
}

/// Constructs one instance of the given `JSValue` tag, gc-tracked exactly
/// like real production code would create it (via `gcNew*`/`makeRegex`, not
/// a raw `zvalue.JSValue.new*` that would bypass the registry). No `else`
/// branch -- see the file doc comment.
fn makeOneOf(interp: *zinterpreter.Interpreter, comptime tag: std.meta.Tag(JSValue)) !JSValue {
    var dummy_ctx: u8 = 0;
    return switch (tag) {
        .@"undefined" => JSValue.UNDEFINED,
        .@"null" => JSValue.NULL,
        .boolean => JSValue{ .boolean = true },
        .number => JSValue{ .number = 1 },
        .string => try interp.gcNewString("x"),
        .array => try interp.gcNewArray(),
        .object => try interp.gcNewObject(),
        .regex => try interp.makeRegex("a", ""),
        .symbol => try interp.gcNewSymbol(null),
        .map => try interp.gcNewMap(),
        .set => try interp.gcNewSet(),
        .@"error" => try interp.gcNewError(.generic, "x"),
        .function => try interp.gcNewFunction(.{ .ctx = @ptrCast(&dummy_ctx), .call = dummyNativeCall }),
        .promise => try interp.gcNewPromise(),
        .date => try interp.gcNewDate(0),
        .bigint => try interp.gcNewBigInt("1"),
        .proxy => try interp.gcNewProxy(JSValue.UNDEFINED, JSValue.UNDEFINED),
        .array_buffer => try interp.gcNewArrayBuffer(4),
        .data_view => blk: {
            const buf = try interp.gcNewArrayBuffer(4);
            const dv = try interp.gcNewDataView(buf.retain(), 0, null);
            buf.deinit();
            break :blk dv;
        },
        .typed_array => blk: {
            const buf = try interp.gcNewArrayBuffer(4);
            const ta = try interp.gcNewTypedArray(buf.retain(), 0, null, .u8);
            buf.deinit();
            break :blk ta;
        },
        .temporal => try interp.gcNewTemporal(.{ .instant = .{ .epoch_nanoseconds = 0 } }),
    };
}

test "gcTrack covers every JSValue variant without leaking" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    inline for (std.meta.fields(JSValue)) |field| {
        const tag: std.meta.Tag(JSValue) = @field(std.meta.Tag(JSValue), field.name);
        const v = try makeOneOf(&interp, tag);
        v.deinit();
    }
}
