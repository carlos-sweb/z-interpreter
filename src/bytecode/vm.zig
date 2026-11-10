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
const nan_box = @import("nan_box.zig");
const NaNBoxedValue = nan_box.NaNBoxedValue;

pub const MAX_FRAMES = 1024;
pub const MAX_REGISTERS = 8192;

threadlocal var current_allocator: ?Allocator = null;

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

fn calleeMatches(cached: JSValue, current: JSValue) bool {
    if (cached != .function or current != .function) return false;
    return cached.function == current.function or (cached.function.value.ctx == current.function.value.ctx and cached.function.value.call == current.function.value.call);
}

fn makeNumberBox(n: f64) nan_box.NaNBoxedValue {
    if (std.math.isNan(n)) {
        return .{ .bits = nan_box.NaNBoxedValue.CANONICAL_NAN };
    }
    return .{ .bits = @bitCast(n) };
}

fn isBoxTruthy(b: nan_box.NaNBoxedValue) bool {
    if (b.isNumber()) {
        const n = b.asNumber();
        return n != 0 and !std.math.isNan(n);
    }
    if (b.bits == nan_box.NaNBoxedValue.TAG_TRUE) return true;
    if (b.bits == nan_box.NaNBoxedValue.TAG_FALSE) return false;
    if (b.bits == nan_box.NaNBoxedValue.TAG_NULL) return false;
    if (b.bits == nan_box.NaNBoxedValue.TAG_UNDEFINED) return false;
    if (b.bits & nan_box.NaNBoxedValue.TAG_MASK == nan_box.NaNBoxedValue.TAG_STRING) {
        const s = b.toJSValueNoRetain();
        return s.string.value.data.len > 0;
    }
    return true;
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
    clearGlobalCache();
    defer clearGlobalCache();

    current_allocator = allocator;
    defer current_allocator = null;

    const frames = try allocator.alloc(CallFrame, MAX_FRAMES);
    defer allocator.free(frames);
    const registers = try allocator.alloc(nan_box.NaNBoxedValue, MAX_REGISTERS);
    defer allocator.free(registers);
    @memset(registers, .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED });

    var frame_count: usize = 0;
    var reg_top: usize = 0;

    defer {
        for (registers[0..reg_top]) |r| r.deinit();
    }

    if (block.register_count > MAX_REGISTERS) return error.OutOfMemory;

    reg_top = block.register_count;

    const parameter_count = @min(args.len, block.param_count);
    for (0..parameter_count) |index| {
        try setReg(registers, @intCast(index), args[index].retain());
    }

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
            .load_const => {
                if (op.b >= frame.block.constants.len) return error.InvalidConstant;
                const c = frame.block.constants[op.b];
                switch (c) {
                    .number => |n| try setRegBox(frame_regs, op.a, makeNumberBox(n)),
                    .boolean => |b| try setRegBox(frame_regs, op.a, .{ .bits = if (b) nan_box.NaNBoxedValue.TAG_TRUE else nan_box.NaNBoxedValue.TAG_FALSE }),
                    else => {
                        const val = try constantValue(allocator, frame.block, op.b);
                        try setReg(frame_regs, op.a, val);
                    },
                }
            },
            .load_undefined => try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED }),
            .new_object => try setReg(frame_regs, op.a, try JSValue.newObject(allocator)),
            .new_array => {
                const arr = try JSValue.newArray(allocator);
                if (op.b > 0) {
                    try arr.array.value.reserve(op.b);
                }
                try setReg(frame_regs, op.a, arr);
            },
            .get_prop => {
                const obj = try getRegRef(frame_regs, op.b);
                const key = try constantKey(frame.block, op.c);
                const result = try getProp(allocator, obj, key);
                try setReg(frame_regs, op.a, result);
            },
            .set_prop => {
                const obj = try getRegRef(frame_regs, op.a);
                const key = try constantKey(frame.block, op.b);
                const val = try getRegRef(frame_regs, op.c);
                try setProp(allocator, obj, key, val);
            },
            .get_elem => {
                const obj = try getRegRef(frame_regs, op.b);
                const key_val = try getRegRef(frame_regs, op.c);
                const result = try getElem(allocator, obj, key_val);
                try setReg(frame_regs, op.a, result);
            },
            .get_elem_const => {
                const obj = try getRegRef(frame_regs, op.b);
                if (obj == .array and op.c < frame.block.constants.len) {
                    const c = frame.block.constants[op.c];
                    if (c == .number) {
                        const idx: usize = @intFromFloat(c.number);
                        if (idx < obj.array.value.length()) {
                            try setReg(frame_regs, op.a, obj.array.value.get(idx).retain());
                        } else {
                            try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED });
                        }
                    } else {
                        const key_val = try constantValue(allocator, frame.block, op.c);
                        defer key_val.deinit();
                        try setReg(frame_regs, op.a, try getElem(allocator, obj, key_val));
                    }
                } else {
                    const key_val = try constantValue(allocator, frame.block, op.c);
                    defer key_val.deinit();
                    try setReg(frame_regs, op.a, try getElem(allocator, obj, key_val));
                }
            },
            .set_elem => {
                const obj = try getRegRef(frame_regs, op.a);
                const key_val = try getRegRef(frame_regs, op.b);
                const val = try getRegRef(frame_regs, op.c);
                try setElem(allocator, obj, key_val, val);
            },
            .load_null => try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_NULL }),
            .load_true => try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_TRUE }),
            .load_false => try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_FALSE }),
            .move, .load_local, .store_local => {
                if (op.b >= frame_regs.len) return error.InvalidRegister;
                const b = frame_regs[op.b];
                b.retain();
                try setRegBox(frame_regs, op.a, b);
            },
            .load_global => try setReg(frame_regs, op.a, try loadGlobal(frame.block, frame.closure_env, op.b)),
            .store_global => {
                const val = try getRegRef(frame_regs, op.b);
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
            .sub_local_const => try arithmeticLocalConst(frame_regs, frame.block, op, .sub),
            .add_local_const => try addLocalConst(frame_regs, allocator, frame.block, op),
            .lt_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .lt),
            .gt_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .gt),
            .le_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .le),
            .ge_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .ge),
            .eq_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .eq),
            .neg => {
                if (op.b >= frame_regs.len) return error.InvalidRegister;
                const b = frame_regs[op.b];
                if (b.isNumber()) {
                    try setRegBox(frame_regs, op.a, makeNumberBox(-b.asNumber()));
                } else return error.UnsupportedOpcode;
            },
            .not => {
                const truthy = try isTruthy(frame_regs, op.b);
                try setRegBox(frame_regs, op.a, .{ .bits = if (truthy) nan_box.NaNBoxedValue.TAG_FALSE else nan_box.NaNBoxedValue.TAG_TRUE });
            },
            .jump => frame.pc = try jumpTarget(frame.block, op),
            .jump_if_true => {
                if (try isTruthy(frame_regs, op.a)) frame.pc = try jumpTarget(frame.block, op);
            },
            .jump_if_false => {
                if (!try isTruthy(frame_regs, op.a)) frame.pc = try jumpTarget(frame.block, op);
            },
            .call => {
                const callee = try getRegRef(frame_regs, op.b);
                const cache_slice: []codeblock.CallSiteCache = @constCast(frame.block.call_target_cache);
                if (op.c >= cache_slice.len) return error.InvalidRegister;
                const cache = &cache_slice[op.c];
                const arg_count = cache.arg_count;
                const start = @as(usize, op.b) + 1;
                const end = start + arg_count;
                if (end > frame_regs.len) return error.InvalidRegister;

                const hit = if (cache.callee) |cached| calleeMatches(cached, callee) else false;
                if (!hit) {
                    if (cache.callee) |old| {
                        var v = old;
                        v.deinit();
                    }
                    cache.callee = callee.retain();
                    if (getBytecodeTarget(callee)) |target| {
                        cache.target_block = target.block;
                        cache.closure_env = target.closure_env;
                        cache.interp = target.interp;
                    } else {
                        cache.target_block = null;
                        cache.closure_env = null;
                        cache.interp = null;
                    }
                }

                if (cache.target_block) |callee_block| {
                    if (frame_count >= MAX_FRAMES) return error.StackOverflow;
                    const callee_reg_base = reg_top;
                    const new_reg_top = callee_reg_base + callee_block.register_count;
                    if (new_reg_top > MAX_REGISTERS) return error.OutOfMemory;

                    const param_count = @min(arg_count, callee_block.param_count);
                    for (0..param_count) |i| {
                        const arg_box = frame_regs[start + i];
                        arg_box.retain();
                        registers[callee_reg_base + i] = arg_box;
                    }
                    for (param_count..callee_block.register_count) |i| {
                        registers[callee_reg_base + i] = .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED };
                    }

                    frames[frame_count] = CallFrame{
                        .block = callee_block,
                        .pc = 0,
                        .reg_base = callee_reg_base,
                        .this_value = JSValue.UNDEFINED,
                        .closure_env = if (cache.closure_env) |env| @ptrCast(@alignCast(env)) else null,
                        .return_reg = op.a,
                        .interp = if (cache.interp) |itp| @ptrCast(@alignCast(itp)) else null,
                        .catch_count = 0,
                    };
                    frame_count += 1;
                    reg_top = new_reg_top;
                } else {
                    var fb_args_buf: [8]JSValue = undefined;
                    const fb_heap = arg_count > fb_args_buf.len;
                    const fb_args = if (fb_heap)
                        try allocator.alloc(JSValue, arg_count)
                    else
                        fb_args_buf[0..arg_count];
                    defer if (fb_heap) allocator.free(fb_args);
                    for (0..arg_count) |i| {
                        fb_args[i] = frame_regs[start + i].toJSValueNoRetain();
                    }
                    const result = try callFallback(allocator, callee, fb_args);
                    try setReg(frame_regs, op.a, result);
                }
            },
            .return_value => {
                if (op.a >= frame_regs.len) return error.InvalidRegister;
                const ret_box = frame_regs[op.a];
                ret_box.retain();
                for (registers[frame.reg_base..reg_top]) |r| r.deinit();
                reg_top = frame.reg_base;
                frame_count -= 1;
                if (frame_count == 0) {
                    defer ret_box.deinit();
                    return ret_box.toJSValue();
                }
                const caller_frame = &frames[frame_count - 1];
                const caller_regs = registers[caller_frame.reg_base .. caller_frame.reg_base + caller_frame.block.register_count];
                try setRegBox(caller_regs, frame.return_reg, ret_box);
            },
            .return_undefined => {
                for (registers[frame.reg_base..reg_top]) |r| r.deinit();
                reg_top = frame.reg_base;
                frame_count -= 1;
                if (frame_count == 0) {
                    return JSValue.UNDEFINED;
                }
                const caller_frame = &frames[frame_count - 1];
                const caller_regs = registers[caller_frame.reg_base .. caller_frame.reg_base + caller_frame.block.register_count];
                try setRegBox(caller_regs, frame.return_reg, .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED });
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
                try setReg(frame_regs, op.a, closure);
            },
            .iter_init => {
                const iterable = try getRegRef(frame_regs, op.b);
                if (iterable != .array and iterable != .string) return error.UnsupportedOpcode;
                const it = try JSValue.newArray(allocator);
                _ = try it.array.value.push(iterable.retain());
                _ = try it.array.value.push(JSValue.fromNumber(0));
                try setReg(frame_regs, op.a, it);
            },
            .iter_next => {
                const it = try getRegRef(frame_regs, op.c);
                if (it != .array or it.array.value.length() < 2) return error.UnsupportedOpcode;
                const target = it.array.value.get(0);
                const idx_val = it.array.value.get(1);
                if (idx_val != .number) return error.UnsupportedOpcode;
                const idx: usize = @intFromFloat(idx_val.number);
                if (target == .array) {
                    if (idx < target.array.value.length()) {
                        const val = target.array.value.get(idx).retain();
                        it.array.value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
                        try setReg(frame_regs, op.a, val);
                        try setRegBox(frame_regs, op.b, .{ .bits = nan_box.NaNBoxedValue.TAG_FALSE });
                    } else {
                        try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED });
                        try setRegBox(frame_regs, op.b, .{ .bits = nan_box.NaNBoxedValue.TAG_TRUE });
                    }
                } else if (target == .string) {
                    if (idx < target.string.value.data.len) {
                        const ch = try JSValue.newString(allocator, target.string.value.data[idx .. idx + 1]);
                        it.array.value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
                        try setReg(frame_regs, op.a, ch);
                        try setRegBox(frame_regs, op.b, .{ .bits = nan_box.NaNBoxedValue.TAG_FALSE });
                    } else {
                        try setRegBox(frame_regs, op.a, .{ .bits = nan_box.NaNBoxedValue.TAG_UNDEFINED });
                        try setRegBox(frame_regs, op.b, .{ .bits = nan_box.NaNBoxedValue.TAG_TRUE });
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
                if (op.a >= frame_regs.len) return error.InvalidRegister;
                const thrown_box = frame_regs[op.a];
                thrown_box.retain();
                var handled = false;
                while (frame_count > 0) {
                    const cur_frame = &frames[frame_count - 1];
                    if (cur_frame.catch_count > 0) {
                        cur_frame.catch_count -= 1;
                        const handler = cur_frame.catch_stack[cur_frame.catch_count];
                        for (registers[handler.reg_top..reg_top]) |r| r.deinit();
                        reg_top = handler.reg_top;
                        cur_frame.pc = handler.target_pc;
                        const hregs = registers[cur_frame.reg_base .. cur_frame.reg_base + cur_frame.block.register_count];
                        try setRegBox(hregs, handler.error_reg, thrown_box);
                        handled = true;
                        break;
                    }
                    for (registers[cur_frame.reg_base..reg_top]) |r| r.deinit();
                    reg_top = cur_frame.reg_base;
                    frame_count -= 1;
                }
                if (!handled) {
                    thrown_box.deinit();
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

fn arithmetic(registers: []nan_box.NaNBoxedValue, op: codeblock.Op, kind: Arithmetic) !void {
    if (op.b >= registers.len or op.c >= registers.len) return error.InvalidRegister;
    const left_box = registers[op.b];
    const right_box = registers[op.c];
    if (left_box.isNumber() and right_box.isNumber()) {
        const left = left_box.asNumber();
        const right = right_box.asNumber();
        const result = switch (kind) {
            .add => left + right,
            .sub => left - right,
            .mul => left * right,
            .div => left / right,
            .mod => @mod(left, right),
        };
        try setRegBox(registers, op.a, makeNumberBox(result));
    } else return error.UnsupportedOpcode;
}

fn comparison(registers: []nan_box.NaNBoxedValue, op: codeblock.Op, kind: Comparison) !void {
    if (op.b >= registers.len or op.c >= registers.len) return error.InvalidRegister;
    const left_box = registers[op.b];
    const right_box = registers[op.c];
    if (left_box.isNumber() and right_box.isNumber()) {
        const left = left_box.asNumber();
        const right = right_box.asNumber();
        const result = switch (kind) {
            .lt => left < right,
            .gt => left > right,
            .le => left <= right,
            .ge => left >= right,
            .eq => left == right,
            .ne => left != right,
        };
        try setRegBox(registers, op.a, .{ .bits = if (result) nan_box.NaNBoxedValue.TAG_TRUE else nan_box.NaNBoxedValue.TAG_FALSE });
    } else {
        const left = try getRegRef(registers, op.b);
        const right = try getRegRef(registers, op.c);
        if (left == .string and right == .string) {
            const eq = std.mem.eql(u8, left.string.value.data, right.string.value.data);
            const result = switch (kind) {
                .eq => eq,
                .ne => !eq,
                else => return error.UnsupportedOpcode,
            };
            try setRegBox(registers, op.a, .{ .bits = if (result) nan_box.NaNBoxedValue.TAG_TRUE else nan_box.NaNBoxedValue.TAG_FALSE });
        } else return error.UnsupportedOpcode;
    }
}

fn addOp(registers: []nan_box.NaNBoxedValue, allocator: Allocator, op: codeblock.Op) !void {
    if (op.b >= registers.len or op.c >= registers.len) return error.InvalidRegister;
    const left_box = registers[op.b];
    const right_box = registers[op.c];
    if (left_box.isNumber() and right_box.isNumber()) {
        try setRegBox(registers, op.a, makeNumberBox(left_box.asNumber() + right_box.asNumber()));
        return;
    }
    const left = try getRegRef(registers, op.b);
    const right = try getRegRef(registers, op.c);
    if (left == .string or right == .string) {
        var buf_l: [32]u8 = undefined;
        var buf_r: [32]u8 = undefined;
        const sl = stringSlice(left, &buf_l) orelse return error.UnsupportedOpcode;
        const sr = stringSlice(right, &buf_r) orelse return error.UnsupportedOpcode;
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sl, sr });
        defer allocator.free(combined);
        const result = try JSValue.newString(allocator, combined);
        try setReg(registers, op.a, result);
        return;
    }
    return error.UnsupportedOpcode;
}

fn arithmeticLocalConst(registers: []nan_box.NaNBoxedValue, block: *const codeblock.CodeBlock, op: codeblock.Op, kind: Arithmetic) !void {
    if (op.b >= registers.len) return error.InvalidRegister;
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const left_box = registers[op.b];
    const c = block.constants[op.c];
    if (left_box.isNumber() and c == .number) {
        const left = left_box.asNumber();
        const result = switch (kind) {
            .add => left + c.number,
            .sub => left - c.number,
            .mul => left * c.number,
            .div => left / c.number,
            .mod => @mod(left, c.number),
        };
        try setRegBox(registers, op.a, makeNumberBox(result));
    } else return error.UnsupportedOpcode;
}

fn comparisonLocalConst(registers: []nan_box.NaNBoxedValue, block: *const codeblock.CodeBlock, op: codeblock.Op, kind: Comparison) !void {
    if (op.b >= registers.len) return error.InvalidRegister;
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const left_box = registers[op.b];
    const c = block.constants[op.c];
    if (left_box.isNumber() and c == .number) {
        const left = left_box.asNumber();
        const result = switch (kind) {
            .lt => left < c.number,
            .gt => left > c.number,
            .le => left <= c.number,
            .ge => left >= c.number,
            .eq => left == c.number,
            .ne => left != c.number,
        };
        try setRegBox(registers, op.a, .{ .bits = if (result) nan_box.NaNBoxedValue.TAG_TRUE else nan_box.NaNBoxedValue.TAG_FALSE });
    } else if (c == .string) {
        const left = try getRegRef(registers, op.b);
        if (left == .string) {
            const eq = std.mem.eql(u8, left.string.value.data, c.string);
            const result = switch (kind) {
                .eq => eq,
                .ne => !eq,
                else => return error.UnsupportedOpcode,
            };
            try setRegBox(registers, op.a, .{ .bits = if (result) nan_box.NaNBoxedValue.TAG_TRUE else nan_box.NaNBoxedValue.TAG_FALSE });
        } else return error.UnsupportedOpcode;
    } else if (c == .boolean) {
        if (left_box.bits == nan_box.NaNBoxedValue.TAG_TRUE or left_box.bits == nan_box.NaNBoxedValue.TAG_FALSE) {
            const left_bool = (left_box.bits == nan_box.NaNBoxedValue.TAG_TRUE);
            const eq = (left_bool == c.boolean);
            const result = switch (kind) {
                .eq => eq,
                .ne => !eq,
                else => return error.UnsupportedOpcode,
            };
            try setRegBox(registers, op.a, .{ .bits = if (result) nan_box.NaNBoxedValue.TAG_TRUE else nan_box.NaNBoxedValue.TAG_FALSE });
        } else return error.UnsupportedOpcode;
    } else return error.UnsupportedOpcode;
}

fn addLocalConst(registers: []nan_box.NaNBoxedValue, allocator: Allocator, block: *const codeblock.CodeBlock, op: codeblock.Op) !void {
    if (op.b >= registers.len) return error.InvalidRegister;
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const left_box = registers[op.b];
    const c = block.constants[op.c];
    if (left_box.isNumber() and c == .number) {
        try setRegBox(registers, op.a, makeNumberBox(left_box.asNumber() + c.number));
        return;
    }
    const left = try getRegRef(registers, op.b);
    const right = try constantValue(allocator, block, op.c);
    defer right.deinit();
    if (left == .string or right == .string) {
        var buf_l: [32]u8 = undefined;
        var buf_r: [32]u8 = undefined;
        const sl = stringSlice(left, &buf_l) orelse return error.UnsupportedOpcode;
        const sr = stringSlice(right, &buf_r) orelse return error.UnsupportedOpcode;
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sl, sr });
        defer allocator.free(combined);
        const result = try JSValue.newString(allocator, combined);
        try setReg(registers, op.a, result);
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

fn isTruthy(registers: []const nan_box.NaNBoxedValue, index: u8) !bool {
    if (index >= registers.len) return error.InvalidRegister;
    return isBoxTruthy(registers[index]);
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
        .function_node => return error.InvalidConstant,
    };
}

fn getReg(registers: []const nan_box.NaNBoxedValue, index: u8) !JSValue {
    if (index >= registers.len) return error.InvalidRegister;
    return registers[index].toJSValue();
}

fn getRegRef(registers: []const nan_box.NaNBoxedValue, index: u8) !JSValue {
    if (index >= registers.len) return error.InvalidRegister;
    return registers[index].toJSValueNoRetain();
}

fn setReg(registers: []nan_box.NaNBoxedValue, index: u8, value: JSValue) !void {
    if (index >= registers.len) {
        value.deinit();
        return error.InvalidRegister;
    }
    const alloc = current_allocator orelse return error.OutOfMemory;
    const boxed = nan_box.NaNBoxedValue.fromJSValue(value, alloc) catch {
        value.deinit();
        return error.OutOfMemory;
    };
    switch (value) {
        .set, .@"error", .date, .promise, .proxy, .array_buffer, .data_view, .typed_array, .temporal => value.deinit(),
        else => {},
    }
    const old = registers[index];
    registers[index] = boxed;
    old.deinit();
}

fn setRegBox(registers: []nan_box.NaNBoxedValue, index: u8, box: nan_box.NaNBoxedValue) !void {
    if (index >= registers.len) return error.InvalidRegister;
    const old = registers[index];
    registers[index] = box;
    old.deinit();
}

pub const getRegister = getRegRef;
pub const setRegister = setReg;

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

fn runTestSnippet(allocator: Allocator, source: []const u8) !JSValue {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var interp = try interpreter_mod.Interpreter.init(allocator, &output.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    return try interp.run(source);
}

test "nan-boxing vm: fib(10) == 55" {
    const res = try runTestSnippet(std.testing.allocator, "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(10);");
    defer res.deinit();
    try std.testing.expect(res == .number);
    try std.testing.expectEqual(@as(f64, 55), res.number);
}

test "nan-boxing vm: closure counter capture" {
    const res = try runTestSnippet(std.testing.allocator, "function makeCounter() { let count = 0; return function() { count = count + 1; return count; }; } let c = makeCounter(); c(); c();");
    defer res.deinit();
    try std.testing.expect(res == .number);
    try std.testing.expectEqual(@as(f64, 2), res.number);
}

test "nan-boxing vm: object property access" {
    const res = try runTestSnippet(std.testing.allocator, "let obj = { x: 1 }; obj.x;");
    defer res.deinit();
    try std.testing.expect(res == .number);
    try std.testing.expectEqual(@as(f64, 1), res.number);
}

test "nan-boxing vm: array element access" {
    const res = try runTestSnippet(std.testing.allocator, "let arr = [1, 2, 3]; arr[1];");
    defer res.deinit();
    try std.testing.expect(res == .number);
    try std.testing.expectEqual(@as(f64, 2), res.number);
}

test "nan-boxing vm: builtin boundary Math.max" {
    const res = try runTestSnippet(std.testing.allocator, "Math.max(1, 2);");
    defer res.deinit();
    try std.testing.expect(res == .number);
    try std.testing.expectEqual(@as(f64, 2), res.number);
}

test "nan-boxing vm: string concat" {
    const res = try runTestSnippet(std.testing.allocator, "'a' + 'b';");
    defer res.deinit();
    try std.testing.expect(res == .string);
    try std.testing.expectEqualStrings("ab", res.string.value.data);
}

test "nan-boxing vm: async fallback returns promise" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var interp = try interpreter_mod.Interpreter.init(std.testing.allocator, &output.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;
    const res = try interp.run("async function foo() { return 42; } foo();");
    defer res.deinit();
    try std.testing.expect(res == .promise);
}
