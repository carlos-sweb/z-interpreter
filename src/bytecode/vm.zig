//! Register VM for the initial arithmetic, branch, and bare-call subset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const Environment = @import("../environment.zig").Environment;
const codeblock = @import("codeblock.zig");

/// Executes a CodeBlock without consulting the AST. The caller owns the
/// returned value. Every register owns its value for the duration of the
/// call, including values copied from arguments and locals.
pub fn vmCall(allocator: Allocator, block: *const codeblock.CodeBlock, closure_env: ?*Environment, args: []const JSValue) !JSValue {
    var registers = try allocator.alloc(JSValue, block.register_count);
    for (registers) |*register| register.* = JSValue.UNDEFINED;
    defer {
        for (registers) |register| register.deinit();
        allocator.free(registers);
    }

    const parameter_count = @min(args.len, block.param_count);
    for (0..parameter_count) |index| registers[index] = args[index].retain();

    var pc: usize = 0;
    while (pc < block.ops.len) {
        const op = block.ops[pc];
        pc += 1;
        switch (op.opcode) {
            .load_const => try setRegister(registers, op.a, try constantValue(allocator, block, op.b)),
            .load_undefined => try setRegister(registers, op.a, JSValue.UNDEFINED),
            .load_null => try setRegister(registers, op.a, JSValue.NULL),
            .load_true => try setRegister(registers, op.a, JSValue.fromBool(true)),
            .load_false => try setRegister(registers, op.a, JSValue.fromBool(false)),
            .move, .load_local => try setRegister(registers, op.a, (try getRegister(registers, op.b)).retain()),
            .store_local => try setRegister(registers, op.a, (try getRegister(registers, op.b)).retain()),
            .load_global => try setRegister(registers, op.a, try loadGlobal(block, closure_env, op.b)),
            .add, .add_num => try arithmetic(registers, op, .add),
            .sub_num => try arithmetic(registers, op, .sub),
            .mul_num => try arithmetic(registers, op, .mul),
            .div_num => try arithmetic(registers, op, .div),
            .mod_num => try arithmetic(registers, op, .mod),
            .lt_num => try comparison(registers, op, .lt),
            .gt_num => try comparison(registers, op, .gt),
            .le_num => try comparison(registers, op, .le),
            .ge_num => try comparison(registers, op, .ge),
            .eq => try comparison(registers, op, .eq),
            .ne => try comparison(registers, op, .ne),
            .jump => pc = try jumpTarget(block, op),
            .jump_if_true => {
                if (try isTruthy(registers, op.a)) pc = try jumpTarget(block, op);
            },
            .jump_if_false => {
                if (!try isTruthy(registers, op.a)) pc = try jumpTarget(block, op);
            },
            .call => try call(registers, allocator, op),
            .return_value => return (try getRegister(registers, op.a)).retain(),
            .return_undefined => return JSValue.UNDEFINED,
            else => return error.UnsupportedOpcode,
        }
    }
    return error.MissingReturn;
}

const Arithmetic = enum { add, sub, mul, div, mod };
const Comparison = enum { lt, gt, le, ge, eq, ne };

fn arithmetic(registers: []JSValue, op: codeblock.Op, kind: Arithmetic) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left != .number or right != .number) return error.UnsupportedOpcode;
    const result = switch (kind) {
        .add => left.number + right.number,
        .sub => left.number - right.number,
        .mul => left.number * right.number,
        .div => left.number / right.number,
        .mod => @mod(left.number, right.number),
    };
    try setRegister(registers, op.a, JSValue.fromNumber(result));
}

fn comparison(registers: []JSValue, op: codeblock.Op, kind: Comparison) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left != .number or right != .number) return error.UnsupportedOpcode;
    const result = switch (kind) {
        .lt => left.number < right.number,
        .gt => left.number > right.number,
        .le => left.number <= right.number,
        .ge => left.number >= right.number,
        .eq => left.number == right.number,
        .ne => left.number != right.number,
    };
    try setRegister(registers, op.a, JSValue.fromBool(result));
}

fn isTruthy(registers: []const JSValue, index: u8) !bool {
    const value = try getRegister(registers, index);
    return switch (value) {
        .undefined, .null => false,
        .boolean => value.boolean,
        .number => value.number != 0 and !std.math.isNan(value.number),
        else => return error.UnsupportedOpcode,
    };
}

fn call(registers: []JSValue, allocator: Allocator, op: codeblock.Op) !void {
    const callee = try getRegister(registers, op.b);
    if (callee != .function) return error.UnsupportedOpcode;
    const start: usize = @as(usize, op.b) + 1;
    const end = start + op.c;
    if (end > registers.len) return error.InvalidRegister;
    const call_args = try allocator.alloc(JSValue, op.c);
    defer {
        for (call_args) |arg| arg.deinit();
        allocator.free(call_args);
    }
    for (call_args, registers[start..end]) |*destination, source| destination.* = source.retain();
    const result = try callee.function.value.call(callee.function.value.ctx, allocator, JSValue.UNDEFINED, call_args);
    try setRegister(registers, op.a, result);
}

fn loadGlobal(block: *const codeblock.CodeBlock, closure_env: ?*Environment, index: u8) !JSValue {
    const env = closure_env orelse return error.UnsupportedOpcode;
    if (index >= block.constants.len) return error.InvalidConstant;
    const name = switch (block.constants[index]) {
        .string, .property_key => |text| text,
        else => return error.InvalidConstant,
    };
    return (env.get(name) orelse return error.UnsupportedOpcode).retain();
}

fn jumpTarget(block: *const codeblock.CodeBlock, op: codeblock.Op) !usize {
    const target = (@as(usize, op.b) << 8) | op.c;
    if (target > block.ops.len) return error.InvalidJump;
    return target;
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
    const value = try vmCall(std.testing.allocator, &block, null, &.{ JSValue.fromNumber(2), JSValue.fromNumber(3) });
    defer value.deinit();
    try std.testing.expect(value == .number);
    try std.testing.expectEqual(@as(f64, 5), value.number);
}
