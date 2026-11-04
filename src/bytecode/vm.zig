//! Register VM for the initial arithmetic, branch, and bare-call subset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const Environment = @import("../environment.zig").Environment;
const codeblock = @import("codeblock.zig");
const interpreter_class = @import("../interpreter_class.zig");
const interpreter_mod = @import("../interpreter.zig");
const ClosureCtx = interpreter_mod.ClosureCtx;

pub const MAX_FRAMES = 1024;
pub const MAX_REGISTERS = 8192;

pub const CatchHandler = struct {
    target_pc: usize,
    error_reg: u8,
    reg_top: usize,
};

pub const CallFrame = struct {
    block: *const codeblock.CodeBlock,
    pc: usize,
    reg_base: usize,
    this_value: JSValue,
    closure_env: ?*Environment,
    return_reg: u8,
    interp: ?*interpreter_mod.Interpreter = null,
    catch_stack: [8]CatchHandler = undefined,
    catch_count: usize = 0,
};

const BytecodeTarget = struct {
    block: *const codeblock.CodeBlock,
    closure_env: ?*Environment,
    interp: ?*interpreter_mod.Interpreter = null,
};

fn getBytecodeTarget(callee: JSValue) ?BytecodeTarget {
    if (callee != .function) return null;
    if (callee.function.value.call != interpreter_class.closureCall) return null;
    const cc: *ClosureCtx = @ptrCast(@alignCast(callee.function.value.ctx));
    if (cc.function_node.is_generator or cc.function_node.is_async) return null;
    if (!cc.interp.compile_options.use_bytecode_vm) return null;
    const cb = interpreter_class.getOrCompileBytecode(cc.interp, cc.function_node) orelse return null;
    return .{
        .block = &cb.block,
        .closure_env = cc.closure_env,
        .interp = cc.interp,
    };
}

fn deinitSlot(v: *JSValue) void {
    switch (v.*) {
        .undefined, .null, .boolean, .number => {},
        else => {
            v.deinit();
            v.* = JSValue.UNDEFINED;
        },
    }
}

fn callFallback(allocator: Allocator, callee: JSValue, args_slice: []const JSValue) !JSValue {
    if (callee != .function) return error.UnsupportedOpcode;
    var inline_args: [4]JSValue = undefined;
    const is_heap = args_slice.len > inline_args.len;
    const call_args = if (is_heap)
        try allocator.alloc(JSValue, args_slice.len)
    else
        inline_args[0..args_slice.len];
    defer {
        for (call_args) |arg| arg.deinit();
        if (is_heap) allocator.free(call_args);
    }
    for (call_args, args_slice) |*dest, src| dest.* = src.retain();
    return try callee.function.value.call(callee.function.value.ctx, allocator, JSValue.UNDEFINED, call_args);
}

fn constantKey(block: *const codeblock.CodeBlock, index: u8) ![]const u8 {
    if (index >= block.constants.len) return error.InvalidConstant;
    return switch (block.constants[index]) {
        .string, .property_key => |s| s,
        else => return error.InvalidConstant,
    };
}

fn keyToString(allocator: Allocator, key_val: JSValue, buf: *[32]u8) ![]const u8 {
    _ = allocator;
    return switch (key_val) {
        .string => |s| s.value.data,
        .number => |n| blk: {
            if (std.math.isNan(n) or std.math.isInf(n)) return error.UnsupportedOpcode;
            const idx: i64 = @intFromFloat(n);
            if (@as(f64, @floatFromInt(idx)) == n) {
                break :blk std.fmt.bufPrint(buf, "{d}", .{idx}) catch return error.UnsupportedOpcode;
            } else {
                break :blk std.fmt.bufPrint(buf, "{d}", .{n}) catch return error.UnsupportedOpcode;
            }
        },
        else => return error.UnsupportedOpcode,
    };
}

fn getProp(allocator: Allocator, obj: JSValue, key: []const u8) !JSValue {
    switch (obj) {
        .object => |box| {
            if (box.value.getOwnRecord(key)) |rec| {
                if (rec.isAccessor()) return error.UnsupportedOpcode;
                return rec.value.retain();
            }
            var current = box.value.getPrototype();
            while (current) |p| : (current = p.getPrototype()) {
                if (p.getOwnRecord(key)) |rec| {
                    if (rec.isAccessor()) return error.UnsupportedOpcode;
                    return rec.value.retain();
                }
            }
            return JSValue.UNDEFINED;
        },
        .array => |box| {
            if (std.mem.eql(u8, key, "length")) {
                return JSValue.fromNumber(@floatFromInt(box.value.length()));
            }
            const idx = std.fmt.parseInt(usize, key, 10) catch return JSValue.UNDEFINED;
            if (idx >= box.value.length()) return JSValue.UNDEFINED;
            return box.value.get(idx).retain();
        },
        .string => |box| {
            if (std.mem.eql(u8, key, "length")) {
                return JSValue.fromNumber(@floatFromInt(box.value.data.len));
            }
            const idx = std.fmt.parseInt(usize, key, 10) catch return JSValue.UNDEFINED;
            if (idx >= box.value.data.len) return JSValue.UNDEFINED;
            return try JSValue.newString(allocator, box.value.data[idx .. idx + 1]);
        },
        else => return error.UnsupportedOpcode,
    }
}

fn setProp(allocator: Allocator, obj: JSValue, key: []const u8, val: JSValue) !void {
    _ = allocator;
    switch (obj) {
        .object => |box| {
            if (box.value.getOwnRecord(key)) |rec| {
                if (rec.isAccessor()) return error.UnsupportedOpcode;
            }
            const old = box.value.getOwn(key);
            try box.value.set(key, val.retain());
            if (old) |o| o.deinit();
        },
        .array => |box| {
            const idx = std.fmt.parseInt(usize, key, 10) catch return error.UnsupportedOpcode;
            const cur = box.value.length();
            if (idx < cur) {
                box.value.toSliceMut()[idx].deinit();
                box.value.toSliceMut()[idx] = val.retain();
            } else {
                while (box.value.length() < idx) {
                    _ = try box.value.push(JSValue.UNDEFINED);
                }
                _ = try box.value.push(val.retain());
            }
        },
        else => return error.UnsupportedOpcode,
    }
}

fn getElem(allocator: Allocator, obj: JSValue, key_val: JSValue) !JSValue {
    if (obj == .array and key_val == .number) {
        const n = key_val.number;
        if (n >= 0 and !std.math.isNan(n) and !std.math.isInf(n)) {
            const idx: usize = @intFromFloat(n);
            if (@as(f64, @floatFromInt(idx)) == n) {
                if (idx < obj.array.value.length()) return obj.array.value.get(idx).retain();
                return JSValue.UNDEFINED;
            }
        }
    }
    var buf: [32]u8 = undefined;
    const key = try keyToString(allocator, key_val, &buf);
    return try getProp(allocator, obj, key);
}

fn setElem(allocator: Allocator, obj: JSValue, key_val: JSValue, val: JSValue) !void {
    if (obj == .array and key_val == .number) {
        const n = key_val.number;
        if (n >= 0 and !std.math.isNan(n) and !std.math.isInf(n)) {
            const idx: usize = @intFromFloat(n);
            if (@as(f64, @floatFromInt(idx)) == n) {
                const cur = obj.array.value.length();
                if (idx < cur) {
                    obj.array.value.toSliceMut()[idx].deinit();
                    obj.array.value.toSliceMut()[idx] = val.retain();
                } else {
                    while (obj.array.value.length() < idx) {
                        _ = try obj.array.value.push(JSValue.UNDEFINED);
                    }
                    _ = try obj.array.value.push(val.retain());
                }
                return;
            }
        }
    }
    var buf: [32]u8 = undefined;
    const key = try keyToString(allocator, key_val, &buf);
    return try setProp(allocator, obj, key, val);
}

/// Executes a CodeBlock without consulting the AST. The caller owns the
/// returned value. Every register owns its value for the duration of the
/// call, including values copied from arguments and locals.
pub fn vmCall(allocator: Allocator, block: *const codeblock.CodeBlock, closure_env: ?*Environment, args: []const JSValue, interp: ?*interpreter_mod.Interpreter) !JSValue {
    var frames: [MAX_FRAMES]CallFrame = undefined;
    var frame_count: usize = 0;
    var registers: [MAX_REGISTERS]JSValue = @splat(JSValue.UNDEFINED);
    var reg_top: usize = 0;

    defer {
        for (registers[0..reg_top]) |*register| deinitSlot(register);
    }

    if (block.register_count > MAX_REGISTERS) return error.OutOfMemory;

    reg_top = block.register_count;

    const parameter_count = @min(args.len, block.param_count);
    for (0..parameter_count) |index| registers[index] = args[index].retain();

    frames[0] = CallFrame{
        .block = block,
        .pc = 0,
        .reg_base = 0,
        .this_value = JSValue.UNDEFINED,
        .closure_env = closure_env,
        .return_reg = 0,
        .interp = interp,
        .catch_count = 0,
    };
    frame_count = 1;

    while (frame_count > 0) {
        const frame = &frames[frame_count - 1];
        if (frame.pc >= frame.block.ops.len) return error.MissingReturn;
        const op = frame.block.ops[frame.pc];
        frame.pc += 1;
        const frame_regs = registers[frame.reg_base .. frame.reg_base + frame.block.register_count];
        switch (op.opcode) {
            .load_const => try setRegister(frame_regs, op.a, try constantValue(allocator, frame.block, op.b)),
            .load_undefined => try setRegister(frame_regs, op.a, JSValue.UNDEFINED),
            .new_object => try setRegister(frame_regs, op.a, try JSValue.newObject(allocator)),
            .new_array => try setRegister(frame_regs, op.a, try JSValue.newArray(allocator)),
            .get_prop => {
                const obj = try getRegister(frame_regs, op.b);
                const key = try constantKey(frame.block, op.c);
                const result = try getProp(allocator, obj, key);
                try setRegister(frame_regs, op.a, result);
            },
            .set_prop => {
                const obj = try getRegister(frame_regs, op.a);
                const key = try constantKey(frame.block, op.b);
                const val = try getRegister(frame_regs, op.c);
                try setProp(allocator, obj, key, val);
            },
            .get_elem => {
                const obj = try getRegister(frame_regs, op.b);
                const key_val = try getRegister(frame_regs, op.c);
                const result = try getElem(allocator, obj, key_val);
                try setRegister(frame_regs, op.a, result);
            },
            .set_elem => {
                const obj = try getRegister(frame_regs, op.a);
                const key_val = try getRegister(frame_regs, op.b);
                const val = try getRegister(frame_regs, op.c);
                try setElem(allocator, obj, key_val, val);
            },
            .load_null => try setRegister(frame_regs, op.a, JSValue.NULL),
            .load_true => try setRegister(frame_regs, op.a, JSValue.fromBool(true)),
            .load_false => try setRegister(frame_regs, op.a, JSValue.fromBool(false)),
            .move, .load_local => try setRegister(frame_regs, op.a, (try getRegister(frame_regs, op.b)).retain()),
            .store_local => try setRegister(frame_regs, op.a, (try getRegister(frame_regs, op.b)).retain()),
            .load_global => try setRegister(frame_regs, op.a, try loadGlobal(frame.block, frame.closure_env, op.b)),
            .store_global => {
                const val = try getRegister(frame_regs, op.b);
                try storeGlobal(allocator, frame.block, frame.closure_env, op.a, val);
            },
            .add => try addOp(frame_regs, allocator, op),
            .add_num => try arithmetic(frame_regs, op, .add),
            .sub_num => try arithmetic(frame_regs, op, .sub),
            .mul_num => try arithmetic(frame_regs, op, .mul),
            .div_num => try arithmetic(frame_regs, op, .div),
            .mod_num => try arithmetic(frame_regs, op, .mod),
            .lt_num => try comparison(frame_regs, op, .lt),
            .gt_num => try comparison(frame_regs, op, .gt),
            .le_num => try comparison(frame_regs, op, .le),
            .ge_num => try comparison(frame_regs, op, .ge),
            .eq => try comparison(frame_regs, op, .eq),
            .ne => try comparison(frame_regs, op, .ne),
            .neg => {
                const src = try getRegister(frame_regs, op.b);
                if (src != .number) return error.UnsupportedOpcode;
                try setRegister(frame_regs, op.a, JSValue.fromNumber(-src.number));
            },
            .not => {
                const truthy = try isTruthy(frame_regs, op.b);
                try setRegister(frame_regs, op.a, JSValue.fromBool(!truthy));
            },
            .jump => frame.pc = try jumpTarget(frame.block, op),
            .jump_if_true => {
                if (try isTruthy(frame_regs, op.a)) frame.pc = try jumpTarget(frame.block, op);
            },
            .jump_if_false => {
                if (!try isTruthy(frame_regs, op.a)) frame.pc = try jumpTarget(frame.block, op);
            },
            .call => {
                const callee = try getRegister(frame_regs, op.b);
                const start = @as(usize, op.b) + 1;
                const end = start + op.c;
                if (end > frame_regs.len) return error.InvalidRegister;

                if (getBytecodeTarget(callee)) |target| {
                    if (frame_count >= MAX_FRAMES) return error.StackOverflow;
                    const callee_block = target.block;
                    const callee_reg_base = reg_top;
                    const new_reg_top = callee_reg_base + callee_block.register_count;
                    if (new_reg_top > MAX_REGISTERS) return error.OutOfMemory;

                    const param_count = @min(op.c, callee_block.param_count);
                    for (0..param_count) |i| {
                        registers[callee_reg_base + i] = frame_regs[start + i].retain();
                    }
                    for (param_count..callee_block.param_count) |i| {
                        registers[callee_reg_base + i] = JSValue.UNDEFINED;
                    }

                    frames[frame_count] = CallFrame{
                        .block = callee_block,
                        .pc = 0,
                        .reg_base = callee_reg_base,
                        .this_value = JSValue.UNDEFINED,
                        .closure_env = target.closure_env,
                        .return_reg = op.a,
                        .interp = target.interp,
                        .catch_count = 0,
                    };
                    frame_count += 1;
                    reg_top = new_reg_top;
                } else {
                    const result = try callFallback(allocator, callee, frame_regs[start..end]);
                    try setRegister(frame_regs, op.a, result);
                }
            },
            .return_value => {
                const val = (try getRegister(frame_regs, op.a)).retain();
                for (registers[frame.reg_base..reg_top]) |*r| deinitSlot(r);
                reg_top = frame.reg_base;
                frame_count -= 1;
                if (frame_count == 0) {
                    return val;
                }
                const caller_frame = &frames[frame_count - 1];
                const caller_regs = registers[caller_frame.reg_base .. caller_frame.reg_base + caller_frame.block.register_count];
                try setRegister(caller_regs, frame.return_reg, val);
            },
            .return_undefined => {
                for (registers[frame.reg_base..reg_top]) |*r| deinitSlot(r);
                reg_top = frame.reg_base;
                frame_count -= 1;
                if (frame_count == 0) {
                    return JSValue.UNDEFINED;
                }
                const caller_frame = &frames[frame_count - 1];
                const caller_regs = registers[caller_frame.reg_base .. caller_frame.reg_base + caller_frame.block.register_count];
                try setRegister(caller_regs, frame.return_reg, JSValue.UNDEFINED);
            },
            .make_closure => {
                const vm_interp = frame.interp orelse return error.UnsupportedOpcode;
                const env = frame.closure_env orelse return error.UnsupportedOpcode;
                if (op.b >= frame.block.constants.len) return error.InvalidConstant;
                const fnode = switch (frame.block.constants[op.b]) {
                    .function_node => |fn_node| fn_node,
                    else => return error.InvalidConstant,
                };
                const closure = try interpreter_class.makeClosure(vm_interp, env, fnode);
                try setRegister(frame_regs, op.a, closure);
            },
            .iter_init => {
                const iterable = try getRegister(frame_regs, op.b);
                if (iterable != .array and iterable != .string) return error.UnsupportedOpcode;
                const it = try JSValue.newArray(allocator);
                _ = try it.array.value.push(iterable.retain());
                _ = try it.array.value.push(JSValue.fromNumber(0));
                try setRegister(frame_regs, op.a, it);
            },
            .iter_next => {
                const it = try getRegister(frame_regs, op.c);
                if (it != .array or it.array.value.length() < 2) return error.UnsupportedOpcode;
                const target = it.array.value.get(0);
                const idx_val = it.array.value.get(1);
                if (idx_val != .number) return error.UnsupportedOpcode;
                const idx: usize = @intFromFloat(idx_val.number);
                if (target == .array) {
                    if (idx < target.array.value.length()) {
                        const val = target.array.value.get(idx).retain();
                        it.array.value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
                        try setRegister(frame_regs, op.a, val);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(false));
                    } else {
                        try setRegister(frame_regs, op.a, JSValue.UNDEFINED);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(true));
                    }
                } else if (target == .string) {
                    if (idx < target.string.value.data.len) {
                        const ch = try JSValue.newString(allocator, target.string.value.data[idx .. idx + 1]);
                        it.array.value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
                        try setRegister(frame_regs, op.a, ch);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(false));
                    } else {
                        try setRegister(frame_regs, op.a, JSValue.UNDEFINED);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(true));
                    }
                } else return error.UnsupportedOpcode;
            },
            .iter_end => {},
            .setup_catch => {
                if (frame.catch_count >= frame.catch_stack.len) return error.UnsupportedOpcode;
                frame.catch_stack[frame.catch_count] = .{
                    .target_pc = try jumpTarget(frame.block, op),
                    .error_reg = op.a,
                    .reg_top = reg_top,
                };
                frame.catch_count += 1;
            },
            .end_catch => {
                if (frame.catch_count > 0) frame.catch_count -= 1;
            },
            .throw_value => {
                const thrown = (try getRegister(frame_regs, op.a)).retain();
                var handled = false;
                while (frame_count > 0) {
                    const cur_frame = &frames[frame_count - 1];
                    if (cur_frame.catch_count > 0) {
                        cur_frame.catch_count -= 1;
                        const handler = cur_frame.catch_stack[cur_frame.catch_count];
                        for (registers[handler.reg_top..reg_top]) |*r| deinitSlot(r);
                        reg_top = handler.reg_top;
                        cur_frame.pc = handler.target_pc;
                        const hregs = registers[cur_frame.reg_base .. cur_frame.reg_base + cur_frame.block.register_count];
                        try setRegister(hregs, handler.error_reg, thrown);
                        handled = true;
                        break;
                    }
                    for (registers[cur_frame.reg_base..reg_top]) |*r| deinitSlot(r);
                    reg_top = cur_frame.reg_base;
                    frame_count -= 1;
                }
                if (!handled) {
                    thrown.deinit();
                    return error.UnsupportedOpcode;
                }
            },
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
    if (left == .number and right == .number) {
        const result = switch (kind) {
            .lt => left.number < right.number,
            .gt => left.number > right.number,
            .le => left.number <= right.number,
            .ge => left.number >= right.number,
            .eq => left.number == right.number,
            .ne => left.number != right.number,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (left == .string and right == .string) {
        const eq = std.mem.eql(u8, left.string.value.data, right.string.value.data);
        const result = switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => return error.UnsupportedOpcode,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else return error.UnsupportedOpcode;
}

fn addOp(registers: []JSValue, allocator: Allocator, op: codeblock.Op) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left == .number and right == .number) {
        try setRegister(registers, op.a, JSValue.fromNumber(left.number + right.number));
        return;
    }
    if (left == .string or right == .string) {
        var buf_l: [32]u8 = undefined;
        var buf_r: [32]u8 = undefined;
        const sl = stringSlice(left, &buf_l) orelse return error.UnsupportedOpcode;
        const sr = stringSlice(right, &buf_r) orelse return error.UnsupportedOpcode;
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sl, sr });
        defer allocator.free(combined);
        const result = try JSValue.newString(allocator, combined);
        try setRegister(registers, op.a, result);
        return;
    }
    return error.UnsupportedOpcode;
}

fn stringSlice(v: JSValue, buf: *[32]u8) ?[]const u8 {
    return switch (v) {
        .string => |s| s.value.data,
        .number => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
        .boolean => |b| if (b) "true" else "false",
        .null => "null",
        .undefined => "undefined",
        else => null,
    };
}

fn isTruthy(registers: []const JSValue, index: u8) !bool {
    const value = try getRegister(registers, index);
    return switch (value) {
        .undefined, .null => false,
        .boolean => value.boolean,
        .number => value.number != 0 and !std.math.isNan(value.number),
        .string => |s| s.value.data.len > 0,
        else => return error.UnsupportedOpcode,
    };
}

const GlobalCacheEntry = struct {
    name: []const u8,
    env: *const Environment,
    value: JSValue,
};

var global_cache: [16]?GlobalCacheEntry = @splat(null);
var global_cache_next: usize = 0;

pub fn clearGlobalCache() void {
    for (&global_cache) |*slot| slot.* = null;
    global_cache_next = 0;
}

fn loadGlobal(block: *const codeblock.CodeBlock, closure_env: ?*Environment, index: u8) !JSValue {
    const env = closure_env orelse return error.UnsupportedOpcode;
    if (index >= block.constants.len) return error.InvalidConstant;
    const name = switch (block.constants[index]) {
        .string, .property_key => |text| text,
        else => return error.InvalidConstant,
    };
    for (&global_cache) |*slot| {
        if (slot.*) |entry| {
            if (entry.env == env and (entry.name.ptr == name.ptr or std.mem.eql(u8, entry.name, name))) {
                return entry.value.retain();
            }
        }
    }
    const val = env.get(name) orelse return error.UnsupportedOpcode;
    global_cache[global_cache_next] = .{
        .name = name,
        .env = env,
        .value = val,
    };
    global_cache_next = (global_cache_next + 1) % global_cache.len;
    return val.retain();
}

fn storeGlobal(allocator: Allocator, block: *const codeblock.CodeBlock, closure_env: ?*Environment, index: u8, val: JSValue) !void {
    const env = closure_env orelse return error.UnsupportedOpcode;
    if (index >= block.constants.len) return error.InvalidConstant;
    const name = switch (block.constants[index]) {
        .string, .property_key => |text| text,
        else => return error.InvalidConstant,
    };
    for (&global_cache) |*slot| {
        if (slot.*) |entry| {
            if (entry.name.ptr == name.ptr or std.mem.eql(u8, entry.name, name)) {
                slot.* = null;
            }
        }
    }
    const retained = val.retain();
    env.assign(name, retained) catch |err| switch (err) {
        error.ReferenceError => {
            try env.define(allocator, name, retained);
        },
        else => {
            retained.deinit();
            return error.UnsupportedOpcode;
        },
    };
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
    deinitSlot(&registers[index]);
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
    const value = try vmCall(std.testing.allocator, &block, null, &.{ JSValue.fromNumber(2), JSValue.fromNumber(3) }, null);
    defer value.deinit();
    try std.testing.expect(value == .number);
    try std.testing.expectEqual(@as(f64, 5), value.number);
}
