//! Roadmap item 19, phase 1: `ArrayBuffer`/`DataView` (TypedArray
//! construction and `%TypedArray%.prototype` are a separate, not-yet-
//! started follow-up). First section exercises `gcNewArrayBuffer`/
//! `gcNewDataView` directly (GC lifecycle); second section runs real JS
//! source through the actual globals/prototype methods, cross-checked
//! against real Node during development.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const helpers = @import("helpers.zig");

test "gcNewArrayBuffer registers a GC-tracked, zero-initialized buffer" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const buf = try interp.gcNewArrayBuffer(8);
    defer buf.deinit();
    try testing.expectEqualStrings("object", buf.typeOf());
    try testing.expectEqual(@as(usize, 8), buf.array_buffer.value.byteLength());
    for (buf.array_buffer.value.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "gcNewDataView reads/writes through to the owning buffer, typeof is object" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const buf = try interp.gcNewArrayBuffer(4);
    defer buf.deinit();
    const dv = try interp.gcNewDataView(buf.retain(), 0, null);
    defer dv.deinit();

    try testing.expectEqualStrings("object", dv.typeOf());
    try dv.data_view.value.view.setInt32(0, -1, false);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, buf.array_buffer.value.bytes);
}

test "gcNewDataView out-of-range window is a real error" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const buf = try interp.gcNewArrayBuffer(4);
    defer buf.deinit();
    try testing.expectError(error.OutOfBounds, interp.gcNewDataView(buf.retain(), 2, 4));
}

test "an unreferenced ArrayBuffer is reclaimed by collectGarbage" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();

    const buf = try interp.gcNewArrayBuffer(4);
    buf.deinit(); // drop the only reference (refcount -> 0, freed immediately here since ArrayBuffer has no cycle)
    interp.collectGarbage(); // should not crash / double-free
}

// ===== Real JS source, through the actual globals/prototype methods =====

test "new ArrayBuffer(n) is zero-filled, byteLength is a real accessor" {
    try helpers.expectNumber("new ArrayBuffer(8).byteLength;", 8);
    try helpers.expectNumber("new ArrayBuffer().byteLength;", 0); // no-arg default
}

test "ArrayBuffer() without new is a TypeError, matching real Node" {
    try helpers.expectUncaught("ArrayBuffer(4);", .type_error, "Constructor ArrayBuffer requires 'new'");
}

test "DataView() without new is a TypeError, matching real Node" {
    try helpers.expectUncaught("DataView(new ArrayBuffer(4));", .type_error, "Constructor DataView requires 'new'");
}

test "DataView's first argument must be an ArrayBuffer" {
    try helpers.expectUncaught("new DataView({});", .type_error, "First argument to DataView constructor must be an ArrayBuffer");
}

test "DataView() constructed with an out-of-range window is a RangeError" {
    try helpers.expectUncaught("new DataView(new ArrayBuffer(4), 2, 4);", .range_error, "Offset is outside the bounds of the buffer");
}

test "dv.buffer === the ArrayBuffer it was constructed from (real Node: true)" {
    try helpers.expectStdout(
        \\const buf = new ArrayBuffer(4);
        \\const dv = new DataView(buf);
        \\console.log(dv.buffer === buf, dv.byteOffset, dv.byteLength);
    ,
        "true 0 4\n",
    );
}

test "setInt32/getInt32 round-trip, both endiannesses" {
    try helpers.expectStdout(
        \\const dv = new DataView(new ArrayBuffer(4));
        \\dv.setInt32(0, -1, true);
        \\console.log(dv.getInt32(0, true));
    ,
        "-1\n",
    );
}

test "Int8/Uint8 wrap modulo 256, no clamping (real Node: 44, not 255)" {
    try helpers.expectStdout(
        \\const dv = new DataView(new ArrayBuffer(1));
        \\dv.setUint8(0, 300);
        \\console.log(dv.getUint8(0));
    ,
        "44\n",
    );
}

test "Float64 round-trips Math.PI exactly (real Node byte pattern verified during planning)" {
    try helpers.expectStdout(
        \\const dv = new DataView(new ArrayBuffer(8));
        \\dv.setFloat64(0, Math.PI, false);
        \\console.log(dv.getFloat64(0, false));
    ,
        "3.141592653589793\n",
    );
}

test "BigInt64 round-trips min/max, and wraps beyond the i64 range (real Node: wraps, not throws)" {
    try helpers.expectStdout(
        \\const dv = new DataView(new ArrayBuffer(8));
        \\dv.setBigInt64(0, -1n, false);
        \\console.log(dv.getBigInt64(0, false));
        \\dv.setBigUint64(0, 18446744073709551615n, false);
        \\console.log(dv.getBigUint64(0, false));
        \\dv.setBigInt64(0, 18446744073709551621n, false); // 2^64 + 5 -> wraps to 5
        \\console.log(dv.getBigInt64(0, false));
    ,
        "-1n\n18446744073709551615n\n5n\n",
    );
}

test "ArrayBuffer.prototype.slice copies, never aliases (real Node: distinct buffer, same bytes)" {
    try helpers.expectStdout(
        \\const b1 = new ArrayBuffer(4);
        \\new DataView(b1).setUint32(0, 0x11223344, false);
        \\const b2 = b1.slice(1, 3);
        \\console.log(b2.byteLength, b2 === b1);
        \\console.log(new DataView(b2).getUint8(0), new DataView(b2).getUint8(1));
    ,
        "2 false\n34 51\n",
    );
}

test "JSON.stringify(ArrayBuffer) is {} (real Node behavior, not a crash)" {
    try helpers.expectStdout("console.log(JSON.stringify(new ArrayBuffer(4)));", "{}\n");
}

test "a huge index (e.g. Number.MAX_VALUE) is a RangeError, not a panic (real Test262 crash found and fixed)" {
    try helpers.expectUncaught("new ArrayBuffer(4).slice(0, Number.MAX_VALUE);", .range_error, "Invalid end: must be a non-negative safe integer");
    try helpers.expectUncaught("new DataView(new ArrayBuffer(4)).getInt32(Number.MAX_VALUE);", .range_error, "Invalid byteOffset: must be a non-negative safe integer");
    try helpers.expectUncaught("new DataView(new ArrayBuffer(4), Number.MAX_VALUE);", .range_error, "Invalid byteOffset: must be a non-negative safe integer");
}

test "ArrayBuffer/DataView compare by identity, are truthy" {
    try helpers.expectStdout(
        \\const b1 = new ArrayBuffer(4), b2 = new ArrayBuffer(4);
        \\console.log(b1 === b1, b1 === b2, !!b1, !!new ArrayBuffer(0));
    ,
        "true false true true\n",
    );
}
