//! Register VM for the initial arithmetic bytecode subset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const codeblock = @import("codeblock.zig");

/// Executes a CodeBlock without consulting the AST. The caller owns the
/// returned value. Every register owns its value for the duration of the
/// call, including values copied from arguments and locals.
pub fn vmCall(allocator: Allocator, block: *const codeblock.CodeBlock, args: []const JSValue) !JSValue {
    var registers = try allocator.alloc(JSValue, block.register_count);
    for (registers) |*register| register.* = JSValue.UNDEFINED;
    defer {
        for (registers) |register| register.deinit();
        allocator.free(registers);
    }

    const parameter_count = @min(args.len, block.param_count);
    for (0..parameter_count) |index| registers[index] = args[index].retain();

    var pc: usize = 0;
    while (pc < block.ops.len) : (pc += 1) {
        const op = block.ops[pc];
        switch (op.opcode) {
            .load_const => try setRegister(&registers, op.a, try constantValue(allocator, block, op.b)),
            .load_local => try setRegister(&registers, op.a, try getRegister(registers, op.b).retain()),
            .store_local => try setRegister(&registers, op.a, try getRegister(registers, op.b).retain()),
            .add, .add_num => try arithmetic(&registers, op, .add),
            .sub_num => try arithmetic(&registers, op, .sub),
            .mul_num => try arithmetic(&registers, op, .mul),
            .div_num => try arithmetic(&registers, op, .div),
            .return_value => return getRegister(registers, op.a).retain(),
            .return_undefined => return JSValue.UNDEFINED,
            else => return error.UnsupportedOpcode,
        }
    }
    return error.MissingReturn;
}

const Arithmetic = enum { add, sub, mul, div };

fn arithmetic(registers: []JSValue, op: codeblock.Op, kind: Arithmetic) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left != .number or right != .number) return error.NonNumericOperand;
    const result = switch (kind) {
        .add => left.number + right.number,
        .sub => left.number - right.number,
        .mul => left.number * right.number,
        .div => left.number / right.number,
    };
    try setRegister(registers, op.a, JSValue.fromNumber(result));
}

fn constantValue(allocator: Allocator, block: *const codeblock.CodeBlock, index: u8) !JSValue {
    if (index >= block.constants.len) return error.InvalidConstant;
    return switch (block.constants[index]) {
        .number => |number| JSValue.fromNumber(number),
        .boolean => |boolean| JSValue.fromBool(boolean),
        .string, .property_key, .bigint => |text| try JSValue.newString(allocator, text),
    };
}

fn getRegister(registers: []const JSValue, index: u8) !JSValue {
    if (index >= registers.len) return error.InvalidRegister;
    return registers[index];
}

fn setRegister(registers: []JSValue, index: u8, value: JSValue) !void {
    if (index >= registers.len) {
        value.deinit();
        return error.InvalidRegister;
    }
    registers[index].deinit();
    registers[index] = value;
}

test "vm executes arithmetic and retains its result" {
    const block = codeblock.CodeBlock{
        .ops = &.{
            .{ .opcode = .load_local, .a = 2, .b = 0 },
            .{ .opcode = .load_local, .a = 3, .b = 1 },
            .{ .opcode = .add, .a = 4, .b = 2, .c = 3 },
            .{ .opcode = .return_value, .a = 4 },
        },
        .local_count = 2,
        .register_count = 5,
        .param_count = 2,
    };
    const value = try vmCall(std.testing.allocator, &block, &.{ JSValue.fromNumber(2), JSValue.fromNumber(3) });
    defer value.deinit();
    try std.testing.expect(value == .number);
    try std.testing.expectEqual(@as(f64, 5), value.number);
}
