//! Register VM for the initial arithmetic, branch, and bare-call subset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zmath = @import("zmath");
const JSValue = zvalue.JSValue;
const Environment = @import("../environment.zig").Environment;
const codeblock = @import("codeblock.zig");
const interpreter_class = @import("../interpreter_class.zig");
const interpreter_mod = @import("../interpreter.zig");
const ClosureCtx = interpreter_mod.ClosureCtx;

pub const MAX_FRAMES = 1024;
pub const MAX_REGISTERS = 8192;

pub const MAX_CATCH_HANDLERS = 64;

pub const CatchHandler = struct {
    frame_idx: u16,
    error_reg: u8,
    target_pc: u32,
    reg_top: u32,
};

const ObjectBox = @typeInfo(@FieldType(JSValue, "object")).pointer.child;
const ArrayBox = @typeInfo(@FieldType(JSValue, "array")).pointer.child;

threadlocal var obj_pool: [32]*ObjectBox = undefined;
threadlocal var obj_pool_len: usize = 0;
threadlocal var arr_pool: [32]*ArrayBox = undefined;
threadlocal var arr_pool_len: usize = 0;

pub const CallFrame = struct {
    block: *const codeblock.CodeBlock,
    closure_env: ?*Environment,
    interp: ?*interpreter_mod.Interpreter = null,
    this_value: JSValue,
    pc: u32,
    reg_base: u32,
    return_reg: u8,
    has_rc: bool = false,
};

const PropIC = struct {
    block: ?*const codeblock.CodeBlock = null,
    pc: u32 = 0,
    shape_id: u32 = 0,
    next_shape: u32 = 0,
    slot_idx: u32 = 0,
    key_ptr: [*]const u8 = undefined,
    interned_key: []const u8 = &.{},
};

inline fn needsDeinit(v: JSValue) bool {
    return switch (v) {
        .undefined, .null, .boolean, .number => false,
        else => true,
    };
}

inline fn setRegPrimitive(registers: []JSValue, index: u8, val: JSValue) !void {
    if (index >= registers.len) return error.InvalidRegister;
    const slot = &registers[index];
    if (needsDeinit(slot.*)) deinitSlot(slot);
    slot.* = val;
}

inline fn setRegValue(frame: *CallFrame, registers: []JSValue, index: u8, val: JSValue) !void {
    if (index >= registers.len) {
        val.deinit();
        return error.InvalidRegister;
    }
    const slot = &registers[index];
    if (needsDeinit(slot.*)) deinitSlot(slot);
    slot.* = val;
    if (needsDeinit(val)) frame.has_rc = true;
}

const setRegTracked = setRegValue;

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

fn deinitSlot(v: *JSValue) void {
    switch (v.*) {
        .undefined, .null, .boolean, .number => {},
        .object => |box| {
            if (box._count == 1 and obj_pool_len < 32 and !box.value.is_frozen and box.value.is_extensible and box.value.properties.capacity() <= 16) {
                var has_accessor = false;
                for (box.value.properties.entries.items(.value)) |*prop| {
                    if (prop.isAccessor()) {
                        has_accessor = true;
                        break;
                    }
                }
                if (!has_accessor) {
                    for (box.value.properties.entries.items(.value)) |*prop| {
                        if (needsDeinit(prop.value)) prop.value.deinit();
                    }
                    box.value.clearRetainingCapacity();
                    obj_pool[obj_pool_len] = box;
                    obj_pool_len += 1;
                    v.* = JSValue.UNDEFINED;
                    return;
                }
            }
            v.deinit();
            v.* = JSValue.UNDEFINED;
        },
        .array => |box| {
            if (box._count == 1 and arr_pool_len < 32 and box.value.holey == null and box.value.items.capacity <= 16) {
                for (box.value.items.items) |*el| {
                    if (needsDeinit(el.*)) el.deinit();
                }
                box.value.clear();
                arr_pool[arr_pool_len] = box;
                arr_pool_len += 1;
                v.* = JSValue.UNDEFINED;
                return;
            }
            v.deinit();
            v.* = JSValue.UNDEFINED;
        },
        else => {
            v.deinit();
            v.* = JSValue.UNDEFINED;
        },
    }
}

fn callFallback(allocator: Allocator, callee: JSValue, this_value: JSValue, args_slice: []const JSValue) !JSValue {
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
    return try callee.function.value.call(callee.function.value.ctx, allocator, this_value, call_args);
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

    const frames = try allocator.alloc(CallFrame, MAX_FRAMES);
    defer allocator.free(frames);
    const registers = try allocator.alloc(JSValue, MAX_REGISTERS);
    defer allocator.free(registers);

    var catch_stack: [MAX_CATCH_HANDLERS]CatchHandler = undefined;
    var catch_top: usize = 0;
    var prop_ic: [256]PropIC = @splat(.{});

    var frame_count: usize = 0;
    var reg_top: usize = 0;
    var max_reg_water_mark: usize = 0;

    const prev_obj_pool_len = obj_pool_len;
    const prev_arr_pool_len = arr_pool_len;
    defer {
        for (registers[0..reg_top]) |*register| deinitSlot(register);
        while (obj_pool_len > prev_obj_pool_len) {
            obj_pool_len -= 1;
            const b = obj_pool[obj_pool_len];
            b.value.deinit();
            b.destroy();
        }
        while (arr_pool_len > prev_arr_pool_len) {
            arr_pool_len -= 1;
            const b = arr_pool[arr_pool_len];
            b.value.deinit();
            b.destroy();
        }
    }

    if (block.register_count > MAX_REGISTERS) return error.OutOfMemory;

    reg_top = block.register_count;
    max_reg_water_mark = reg_top;

    var init_has_rc = false;
    const parameter_count = @min(args.len, block.param_count);
    for (0..parameter_count) |index| {
        const v = args[index].retain();
        registers[index] = v;
        if (needsDeinit(v)) init_has_rc = true;
    }
    @memset(registers[parameter_count..reg_top], JSValue.UNDEFINED);

    frames[0] = CallFrame{
        .block = block,
        .pc = 0,
        .reg_base = 0,
        .this_value = JSValue.UNDEFINED,
        .closure_env = closure_env,
        .has_rc = init_has_rc,
        .return_reg = 0,
        .interp = interp,
    };
    frame_count = 1;

    while (frame_count > 0) {
        const frame = &frames[frame_count - 1];
        if (frame.pc >= frame.block.ops.len) return error.MissingReturn;
        const op_pc = frame.pc;
        const op = frame.block.ops[op_pc];
        frame.pc = op_pc + 1;
        const frame_regs = registers[frame.reg_base .. frame.reg_base + frame.block.register_count];
        switch (op.opcode) {
            .load_const => {
                if (op.b >= frame.block.constants.len) return error.InvalidConstant;
                const c = frame.block.constants[op.b];
                switch (c) {
                    .number => |n| try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(n)),
                    .boolean => |b| try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(b)),
                    else => {
                        const v = try constantValue(allocator, frame.block, op.b);
                        try setRegValue(frame, frame_regs, op.a, v);
                    },
                }
            },
            .load_undefined => try setRegPrimitive(frame_regs, op.a, JSValue.UNDEFINED),
            .new_object => {
                if (obj_pool_len > 0) {
                    obj_pool_len -= 1;
                    const box = obj_pool[obj_pool_len];
                    box._count = 1;
                    if (frame.interp) |itp| {
                        if (itp.protos.object == .object) {
                            box.value.prototype = &itp.protos.object.object.value;
                        } else {
                            box.value.prototype = null;
                        }
                    } else {
                        box.value.prototype = null;
                    }
                    try setRegValue(frame, frame_regs, op.a, JSValue{ .object = box });
                } else {
                    const obj = if (frame.interp) |itp| try itp.ordinaryObject() else try JSValue.newObject(allocator);
                    try setRegValue(frame, frame_regs, op.a, obj);
                }
            },
            .new_array => {
                if (arr_pool_len > 0) {
                    arr_pool_len -= 1;
                    const box = arr_pool[arr_pool_len];
                    box._count = 1;
                    const cap = @max(@as(usize, op.b), 4);
                    try box.value.reserve(cap);
                    try setRegValue(frame, frame_regs, op.a, JSValue{ .array = box });
                } else {
                    const arr = try JSValue.newArray(allocator);
                    const cap = @max(@as(usize, op.b), 4);
                    try arr.array.value.reserve(cap);
                    try setRegValue(frame, frame_regs, op.a, arr);
                }
            },
            .get_prop => {
                const obj = try getRegister(frame_regs, op.b);
                const key = try constantKey(frame.block, op.c);
                if (obj == .object) {
                    const box = obj.object;
                    const ic_idx = ((@intFromPtr(frame.block) >> 4) +% op_pc) & 255;
                    const ic = &prop_ic[ic_idx];
                    if (ic.block == frame.block and ic.pc == op_pc and ic.shape_id == box.value.shape_id and ic.key_ptr == key.ptr and ic.slot_idx < box.value.properties.count()) {
                        const rec = &box.value.properties.entries.items(.value)[ic.slot_idx];
                        if (!rec.isAccessor()) {
                            if (!needsDeinit(rec.value)) {
                                try setRegPrimitive(frame_regs, op.a, rec.value);
                            } else {
                                try setRegValue(frame, frame_regs, op.a, rec.value.retain());
                            }
                            continue;
                        }
                    }
                    if (box.value.properties.getIndex(key)) |slot_idx| {
                        const rec = &box.value.properties.entries.items(.value)[slot_idx];
                        if (!rec.isAccessor()) {
                            ic.* = .{
                                .block = frame.block,
                                .pc = op_pc,
                                .shape_id = box.value.shape_id,
                                .slot_idx = @intCast(slot_idx),
                                .key_ptr = key.ptr,
                            };
                            if (!needsDeinit(rec.value)) {
                                try setRegPrimitive(frame_regs, op.a, rec.value);
                            } else {
                                try setRegValue(frame, frame_regs, op.a, rec.value.retain());
                            }
                            continue;
                        }
                    }
                    const result = try getProp(allocator, obj, key);
                    if (!needsDeinit(result)) {
                        try setRegPrimitive(frame_regs, op.a, result);
                    } else {
                        try setRegValue(frame, frame_regs, op.a, result);
                    }
                } else {
                    const result = try getProp(allocator, obj, key);
                    if (!needsDeinit(result)) {
                        try setRegPrimitive(frame_regs, op.a, result);
                    } else {
                        try setRegValue(frame, frame_regs, op.a, result);
                    }
                }
            },
            .set_prop => {
                const obj = try getRegister(frame_regs, op.a);
                const key = try constantKey(frame.block, op.b);
                const val = try getRegister(frame_regs, op.c);
                if (obj == .object) {
                    const box = obj.object;
                    const ic_idx = ((@intFromPtr(frame.block) >> 4) +% op_pc) & 255;
                    const ic = &prop_ic[ic_idx];
                    if (ic.block == frame.block and ic.pc == op_pc and ic.shape_id == box.value.shape_id and ic.key_ptr == key.ptr) {
                        if (ic.next_shape == 0) {
                            if (ic.slot_idx < box.value.properties.count()) {
                                const rec = &box.value.properties.entries.items(.value)[ic.slot_idx];
                                if (!rec.isAccessor() and rec.descriptor.writable and !box.value.is_frozen) {
                                    if (!needsDeinit(rec.value) and !needsDeinit(val)) {
                                        rec.value = val;
                                        continue;
                                    }
                                    const old = rec.value;
                                    rec.value = val.retain();
                                    old.deinit();
                                    continue;
                                }
                            }
                        } else if (ic.interned_key.len > 0) {
                            const val_to_store = if (needsDeinit(val)) val.retain() else val;
                            if (box.value.putBorrowedTransition(ic.interned_key, val_to_store, ic.slot_idx, ic.next_shape) catch false) {
                                continue;
                            } else if (needsDeinit(val)) {
                                val_to_store.deinit();
                            }
                        }
                    }
                    if (frame.interp) |itp| {
                        const proto_is_obj_proto = if (box.value.prototype) |p| (itp.protos.object == .object and p == &itp.protos.object.object.value) else true;
                        if (box.value.properties.getIndex(key) == null and proto_is_obj_proto) {
                            const prev_shape = box.value.shape_id;
                            const prev_count = box.value.properties.count();
                            const interned = if (ic.block == frame.block and ic.pc == op_pc and ic.key_ptr == key.ptr and ic.interned_key.len > 0)
                                ic.interned_key
                            else
                                try itp.internPropKey(key);
                            const val_to_store = if (needsDeinit(val)) val.retain() else val;
                            box.value.setBorrowedKey(interned, val_to_store) catch |err| switch (err) {
                                error.ObjectIsFrozen, error.ObjectNotExtensible, error.PropertyNotWritable => {
                                    if (needsDeinit(val)) val_to_store.deinit();
                                    return error.UnsupportedOpcode;
                                },
                                else => {
                                    if (needsDeinit(val)) val_to_store.deinit();
                                    return err;
                                },
                            };
                            ic.* = .{
                                .block = frame.block,
                                .pc = op_pc,
                                .shape_id = prev_shape,
                                .next_shape = box.value.shape_id,
                                .slot_idx = @intCast(prev_count),
                                .key_ptr = key.ptr,
                                .interned_key = interned,
                            };
                            continue;
                        }
                    }
                    try setProp(allocator, obj, key, val);
                    if (box.value.properties.getIndex(key)) |slot_idx| {
                        const rec = &box.value.properties.entries.items(.value)[slot_idx];
                        if (!rec.isAccessor() and rec.descriptor.writable and !box.value.is_frozen) {
                            ic.* = .{
                                .block = frame.block,
                                .pc = op_pc,
                                .shape_id = box.value.shape_id,
                                .next_shape = 0,
                                .slot_idx = @intCast(slot_idx),
                                .key_ptr = key.ptr,
                            };
                        }
                    }
                } else {
                    try setProp(allocator, obj, key, val);
                }
            },
            .get_elem => {
                const obj = try getRegister(frame_regs, op.b);
                const key_val = try getRegister(frame_regs, op.c);
                const result = try getElem(allocator, obj, key_val);
                try setRegTracked(frame, frame_regs, op.a, result);
            },
            .get_elem_const => {
                const obj = try getRegister(frame_regs, op.b);
                if (obj == .array and op.c < frame.block.constants.len) {
                    const c = frame.block.constants[op.c];
                    if (c == .number) {
                        const idx: usize = @intFromFloat(c.number);
                        if (idx < obj.array.value.length()) {
                            const elem = obj.array.value.get(idx);
                            if (!needsDeinit(elem)) {
                                try setRegPrimitive(frame_regs, op.a, elem);
                            } else {
                                try setRegValue(frame, frame_regs, op.a, elem.retain());
                            }
                        } else {
                            try setRegPrimitive(frame_regs, op.a, JSValue.UNDEFINED);
                        }
                    } else {
                        const key_val = try constantValue(allocator, frame.block, op.c);
                        defer key_val.deinit();
                        const result = try getElem(allocator, obj, key_val);
                        if (!needsDeinit(result)) {
                            try setRegPrimitive(frame_regs, op.a, result);
                        } else {
                            try setRegValue(frame, frame_regs, op.a, result);
                        }
                    }
                } else {
                    const key_val = try constantValue(allocator, frame.block, op.c);
                    defer key_val.deinit();
                    const result = try getElem(allocator, obj, key_val);
                    if (!needsDeinit(result)) {
                        try setRegPrimitive(frame_regs, op.a, result);
                    } else {
                        try setRegValue(frame, frame_regs, op.a, result);
                    }
                }
            },
            .set_elem => {
                const obj = try getRegister(frame_regs, op.a);
                const key_val = try getRegister(frame_regs, op.b);
                const val = try getRegister(frame_regs, op.c);
                try setElem(allocator, obj, key_val, val);
            },
            .set_elem_const => {
                const obj = try getRegister(frame_regs, op.a);
                const val = try getRegister(frame_regs, op.c);
                const idx: usize = op.b;
                if (obj == .array) {
                    const arr = &obj.array.value;
                    const val_to_store = if (needsDeinit(val)) val.retain() else val;
                    if (arr.holey == null and idx == arr.items.items.len) {
                        try arr.items.append(arr.allocator, val_to_store);
                    } else {
                        const cur = arr.length();
                        if (idx < cur) {
                            const old = arr.toSliceMut()[idx];
                            arr.toSliceMut()[idx] = val_to_store;
                            if (needsDeinit(old)) old.deinit();
                        } else {
                            while (arr.length() < idx) {
                                _ = try arr.push(JSValue.UNDEFINED);
                            }
                            _ = try arr.push(val_to_store);
                        }
                    }
                } else {
                    var buf: [32]u8 = undefined;
                    const key = try std.fmt.bufPrint(&buf, "{d}", .{idx});
                    try setProp(allocator, obj, key, val);
                }
            },
            .load_null => try setRegPrimitive(frame_regs, op.a, JSValue.NULL),
            .load_true => try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(true)),
            .load_false => try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(false)),
            .load_this => try setRegValue(frame, frame_regs, op.a, frame.this_value.retain()),
            .move, .load_local => {
                const v = try getRegister(frame_regs, op.b);
                if (!needsDeinit(v)) {
                    try setRegPrimitive(frame_regs, op.a, v);
                } else {
                    try setRegValue(frame, frame_regs, op.a, v.retain());
                }
            },
            .store_local => {
                const v = try getRegister(frame_regs, op.b);
                if (!needsDeinit(v)) {
                    try setRegPrimitive(frame_regs, op.a, v);
                } else {
                    try setRegValue(frame, frame_regs, op.a, v.retain());
                }
            },
            .load_global => try setRegValue(frame, frame_regs, op.a, try loadGlobalFast(frame.block, frame.closure_env, op.b, op_pc)),
            .store_global => {
                const val = try getRegister(frame_regs, op.b);
                try storeGlobal(allocator, frame.block, frame.closure_env, op.a, val);
            },
            .add => {
                const left = try getRegister(frame_regs, op.b);
                const right = try getRegister(frame_regs, op.c);
                if (left == .number and right == .number) {
                    try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(left.number + right.number));
                } else {
                    try addOp(frame, frame_regs, allocator, op);
                }
            },
            .add_num => try arithmetic(frame_regs, op, .add),
            .sub_num => try arithmetic(frame_regs, op, .sub),
            .mul_num => try arithmetic(frame_regs, op, .mul),
            .div_num => try arithmetic(frame_regs, op, .div),
            .mod_num => try arithmetic(frame_regs, op, .mod),
            .pow_num => try arithmetic(frame_regs, op, .pow),
            .lt_num => try comparison(frame_regs, op, .lt),
            .gt_num => try comparison(frame_regs, op, .gt),
            .le_num => try comparison(frame_regs, op, .le),
            .ge_num => try comparison(frame_regs, op, .ge),
            .eq => try comparison(frame_regs, op, .eq),
            .ne => try comparison(frame_regs, op, .ne),
            .and_bits => try bitwise(frame_regs, op, .bit_and),
            .or_bits => try bitwise(frame_regs, op, .bit_or),
            .xor_bits => try bitwise(frame_regs, op, .bit_xor),
            .shl => try bitwise(frame_regs, op, .shl),
            .shr => try bitwise(frame_regs, op, .shr),
            .ushr => try bitwise(frame_regs, op, .ushr),
            .sub_local_const => {
                const left = try getRegister(frame_regs, op.b);
                if (op.c < frame.block.constants.len) {
                    const c = frame.block.constants[op.c];
                    if (left == .number and c == .number) {
                        try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(left.number - c.number));
                    } else return error.UnsupportedOpcode;
                } else return error.InvalidConstant;
            },
            .add_local_const => {
                const left = try getRegister(frame_regs, op.b);
                if (op.c < frame.block.constants.len) {
                    const c = frame.block.constants[op.c];
                    if (left == .number and c == .number) {
                        try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(left.number + c.number));
                    } else {
                        try addLocalConst(frame_regs, allocator, frame.block, op);
                    }
                } else return error.InvalidConstant;
            },
            .lt_local_const => {
                const left = try getRegister(frame_regs, op.b);
                if (op.c < frame.block.constants.len) {
                    const c = frame.block.constants[op.c];
                    if (left == .number and c == .number) {
                        try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(left.number < c.number));
                    } else return error.UnsupportedOpcode;
                } else return error.InvalidConstant;
            },
            .gt_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .gt),
            .le_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .le),
            .ge_local_const => try comparisonLocalConst(frame_regs, frame.block, op, .ge),
            .eq_local_const => {
                const left = try getRegister(frame_regs, op.b);
                if (op.c < frame.block.constants.len) {
                    const c = frame.block.constants[op.c];
                    if (left == .number and c == .number) {
                        try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(left.number == c.number));
                    } else return error.UnsupportedOpcode;
                } else return error.InvalidConstant;
            },
            .neg => {
                const src = try getRegister(frame_regs, op.b);
                if (src != .number) return error.UnsupportedOpcode;
                try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(-src.number));
            },
            .not => {
                const truthy = try isTruthy(frame_regs, op.b);
                try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(!truthy));
            },
            .not_bits => {
                const src = try getRegister(frame_regs, op.b);
                if (src != .number) return error.UnsupportedOpcode;
                try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(@floatFromInt(~numberToInt32(src.number))));
            },
            .typeof => {
                const src = try getRegister(frame_regs, op.b);
                const str = try JSValue.newString(allocator, src.typeOf());
                try setRegTracked(frame, frame_regs, op.a, str);
            },
            .jump => frame.pc = @intCast(try jumpTarget(frame.block, op)),
            .jump_if_true => {
                const val = try getRegister(frame_regs, op.a);
                const truthy = if (val == .boolean) val.boolean else try isTruthy(frame_regs, op.a);
                if (truthy) frame.pc = @intCast(try jumpTarget(frame.block, op));
            },
            .jump_if_false => {
                const val = try getRegister(frame_regs, op.a);
                const truthy = if (val == .boolean) val.boolean else try isTruthy(frame_regs, op.a);
                if (!truthy) frame.pc = @intCast(try jumpTarget(frame.block, op));
            },
            .jump_if_not_nullish => {
                const val = try getRegister(frame_regs, op.a);
                if (val != .undefined and val != .null) frame.pc = @intCast(try jumpTarget(frame.block, op));
            },
            .call => {
                const callee = try getRegister(frame_regs, op.b);
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

                const this_value = if (cache.this_reg) |r| frame_regs[r] else JSValue.UNDEFINED;
                if (cache.target_block) |callee_block| {
                    if (frame_count >= MAX_FRAMES) return error.StackOverflow;
                    const callee_reg_base = reg_top;
                    const new_reg_top = callee_reg_base + callee_block.register_count;
                    if (new_reg_top > MAX_REGISTERS) return error.OutOfMemory;

                    if (new_reg_top > max_reg_water_mark) {
                        @memset(registers[max_reg_water_mark..new_reg_top], JSValue.UNDEFINED);
                        max_reg_water_mark = new_reg_top;
                    }
                    var callee_has_rc = false;
                    const param_count = @min(arg_count, callee_block.param_count);
                    if (param_count == 1) {
                        const v = frame_regs[start];
                        if (!needsDeinit(v)) {
                            registers[callee_reg_base] = v;
                        } else {
                            registers[callee_reg_base] = v.retain();
                            callee_has_rc = true;
                        }
                    } else {
                        for (0..param_count) |i| {
                            const v = frame_regs[start + i].retain();
                            registers[callee_reg_base + i] = v;
                            if (needsDeinit(v)) callee_has_rc = true;
                        }
                    }

                    frames[frame_count] = CallFrame{
                        .block = callee_block,
                        .pc = 0,
                        .reg_base = @intCast(callee_reg_base),
                        .this_value = this_value,
                        .closure_env = if (cache.closure_env) |env| @ptrCast(@alignCast(env)) else null,
                        .has_rc = callee_has_rc,
                        .return_reg = op.a,
                        .interp = if (cache.interp) |itp| @ptrCast(@alignCast(itp)) else null,
                    };
                    frame_count += 1;
                    reg_top = new_reg_top;
                } else {
                    const result = try callFallback(allocator, callee, this_value, frame_regs[start..end]);
                    try setRegValue(frame, frame_regs, op.a, result);
                }
            },
            .call_global => {
                const cache_slice: []codeblock.CallSiteCache = @constCast(frame.block.call_target_cache);
                if (op.c >= cache_slice.len) return error.InvalidRegister;
                const cache = &cache_slice[op.c];
                const arg_count = cache.arg_count;
                const start = @as(usize, op.b) + 1;
                const end = start + arg_count;
                if (end > frame_regs.len) return error.InvalidRegister;

                const gname = cache.global_name orelse return error.InvalidConstant;
                const env = frame.closure_env orelse return error.UnsupportedOpcode;
                if (cache.callee == null or cache.global_version != global_version) {
                    const callee = env.get(gname) orelse return error.UnsupportedOpcode;
                    if (cache.callee) |old| {
                        var v = old;
                        v.deinit();
                    }
                    cache.callee = callee.retain();
                    cache.global_version = global_version;
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
                const callee = cache.callee.?;
                if (cache.target_block) |callee_block| {
                    if (frame_count >= MAX_FRAMES) return error.StackOverflow;
                    const callee_reg_base = reg_top;
                    const new_reg_top = callee_reg_base + callee_block.register_count;
                    if (new_reg_top > MAX_REGISTERS) return error.OutOfMemory;

                    if (new_reg_top > max_reg_water_mark) {
                        @memset(registers[max_reg_water_mark..new_reg_top], JSValue.UNDEFINED);
                        max_reg_water_mark = new_reg_top;
                    }
                    var callee_has_rc = false;
                    const param_count = @min(arg_count, callee_block.param_count);
                    if (param_count == 1) {
                        const v = frame_regs[start];
                        if (!needsDeinit(v)) {
                            registers[callee_reg_base] = v;
                        } else {
                            registers[callee_reg_base] = v.retain();
                            callee_has_rc = true;
                        }
                    } else {
                        for (0..param_count) |i| {
                            const v = frame_regs[start + i].retain();
                            registers[callee_reg_base + i] = v;
                            if (needsDeinit(v)) callee_has_rc = true;
                        }
                    }

                    frames[frame_count] = CallFrame{
                        .block = callee_block,
                        .pc = 0,
                        .reg_base = @intCast(callee_reg_base),
                        .this_value = JSValue.UNDEFINED,
                        .closure_env = if (cache.closure_env) |cenv| @ptrCast(@alignCast(cenv)) else null,
                        .has_rc = callee_has_rc,
                        .return_reg = op.a,
                        .interp = if (cache.interp) |itp| @ptrCast(@alignCast(itp)) else null,
                    };
                    frame_count += 1;
                    reg_top = new_reg_top;
                } else {
                    const result = try callFallback(allocator, callee, JSValue.UNDEFINED, frame_regs[start..end]);
                    try setRegValue(frame, frame_regs, op.a, result);
                }
            },
            .return_value => {
                const raw_val = try getRegister(frame_regs, op.a);
                const is_prim = !needsDeinit(raw_val);
                const val = if (is_prim) raw_val else raw_val.retain();
                if (frame.has_rc) {
                    for (registers[frame.reg_base..reg_top]) |*slot| {
                        if (needsDeinit(slot.*)) deinitSlot(slot);
                    }
                }
                reg_top = frame.reg_base;
                if (catch_top > 0) {
                    while (catch_top > 0 and catch_stack[catch_top - 1].frame_idx >= frame_count - 1) catch_top -= 1;
                }
                frame_count -= 1;
                if (frame_count == 0) {
                    return val;
                }
                const caller_frame = &frames[frame_count - 1];
                const caller_regs = registers[caller_frame.reg_base .. caller_frame.reg_base + caller_frame.block.register_count];
                if (is_prim) {
                    try setRegPrimitive(caller_regs, frame.return_reg, val);
                } else {
                    try setRegValue(caller_frame, caller_regs, frame.return_reg, val);
                }
            },
            .return_undefined => {
                if (frame.has_rc) {
                    for (registers[frame.reg_base..reg_top]) |*slot| {
                        if (needsDeinit(slot.*)) deinitSlot(slot);
                    }
                }
                reg_top = frame.reg_base;
                if (catch_top > 0) {
                    while (catch_top > 0 and catch_stack[catch_top - 1].frame_idx >= frame_count - 1) catch_top -= 1;
                }
                frame_count -= 1;
                if (frame_count == 0) {
                    return JSValue.UNDEFINED;
                }
                const caller_frame = &frames[frame_count - 1];
                const caller_regs = registers[caller_frame.reg_base .. caller_frame.reg_base + caller_frame.block.register_count];
                try setRegPrimitive(caller_regs, frame.return_reg, JSValue.UNDEFINED);
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
                try setRegTracked(frame, frame_regs, op.a, closure);
            },
            .iter_init => {
                const iterable = try getRegister(frame_regs, op.b);
                if (iterable != .array and iterable != .string) return error.UnsupportedOpcode;
                const it = try JSValue.newArray(allocator);
                _ = try it.array.value.push(iterable.retain());
                _ = try it.array.value.push(JSValue.fromNumber(0));
                try setRegTracked(frame, frame_regs, op.a, it);
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
                        try setRegTracked(frame, frame_regs, op.a, val);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(false));
                    } else {
                        try setRegister(frame_regs, op.a, JSValue.UNDEFINED);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(true));
                    }
                } else if (target == .string) {
                    if (idx < target.string.value.data.len) {
                        const ch = try JSValue.newString(allocator, target.string.value.data[idx .. idx + 1]);
                        it.array.value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
                        try setRegTracked(frame, frame_regs, op.a, ch);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(false));
                    } else {
                        try setRegister(frame_regs, op.a, JSValue.UNDEFINED);
                        try setRegister(frame_regs, op.b, JSValue.fromBool(true));
                    }
                } else return error.UnsupportedOpcode;
            },
            .iter_end => {},
            .setup_catch => {
                if (catch_top >= MAX_CATCH_HANDLERS) return error.UnsupportedOpcode;
                catch_stack[catch_top] = .{
                    .frame_idx = @intCast(frame_count - 1),
                    .error_reg = op.a,
                    .target_pc = @intCast(try jumpTarget(frame.block, op)),
                    .reg_top = @intCast(reg_top),
                };
                catch_top += 1;
            },
            .end_catch => {
                if (catch_top > 0 and catch_stack[catch_top - 1].frame_idx == frame_count - 1) catch_top -= 1;
            },
            .throw_value => {
                const thrown = (try getRegister(frame_regs, op.a)).retain();
                var handled = false;
                if (catch_top > 0) {
                    catch_top -= 1;
                    const handler = catch_stack[catch_top];
                    const target_frame_idx = @as(usize, handler.frame_idx);
                    while (frame_count > target_frame_idx + 1) {
                        const cur_frame = &frames[frame_count - 1];
                        for (registers[cur_frame.reg_base..reg_top]) |*r| deinitSlot(r);
                        reg_top = cur_frame.reg_base;
                        frame_count -= 1;
                    }
                    const cur_frame = &frames[target_frame_idx];
                    for (registers[handler.reg_top..reg_top]) |*r| deinitSlot(r);
                    reg_top = handler.reg_top;
                    cur_frame.pc = handler.target_pc;
                    const hregs = registers[cur_frame.reg_base .. cur_frame.reg_base + cur_frame.block.register_count];
                    try setRegTracked(cur_frame, hregs, handler.error_reg, thrown);
                    handled = true;
                }
                if (!handled) {
                    for (registers[0..reg_top]) |*r| deinitSlot(r);
                    reg_top = 0;
                    frame_count = 0;
                    thrown.deinit();
                    return error.UnsupportedOpcode;
                }
            },
            else => return error.UnsupportedOpcode,
        }
    }
    return error.MissingReturn;
}

const Arithmetic = enum { add, sub, mul, div, mod, pow };
const Comparison = enum { lt, gt, le, ge, eq, ne };

const BitwiseOp = enum { bit_and, bit_or, bit_xor, shl, shr, ushr };

fn numberToUint32(n: f64) u32 {
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return 0;
    const wrapped = @mod(@trunc(n), 4294967296.0);
    return @intFromFloat(wrapped);
}

fn numberToInt32(n: f64) i32 {
    return @bitCast(numberToUint32(n));
}

fn bitwise(registers: []JSValue, op: codeblock.Op, kind: BitwiseOp) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left != .number or right != .number) return error.UnsupportedOpcode;
    const result: f64 = switch (kind) {
        .bit_and => @floatFromInt(numberToInt32(left.number) & numberToInt32(right.number)),
        .bit_or => @floatFromInt(numberToInt32(left.number) | numberToInt32(right.number)),
        .bit_xor => @floatFromInt(numberToInt32(left.number) ^ numberToInt32(right.number)),
        .shl => @floatFromInt(numberToInt32(left.number) << @as(u5, @intCast(numberToUint32(right.number) & 31))),
        .shr => @floatFromInt(numberToInt32(left.number) >> @as(u5, @intCast(numberToUint32(right.number) & 31))),
        .ushr => @floatFromInt(numberToUint32(left.number) >> @as(u5, @intCast(numberToUint32(right.number) & 31))),
    };
    try setRegister(registers, op.a, JSValue.fromNumber(result));
}

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
        .pow => zmath.pow(left.number, right.number),
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

fn addOp(frame: *CallFrame, registers: []JSValue, allocator: Allocator, op: codeblock.Op) !void {
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
        try setRegTracked(frame, registers, op.a, result);
        return;
    }
    return error.UnsupportedOpcode;
}

fn arithmeticLocalConst(registers: []JSValue, block: *const codeblock.CodeBlock, op: codeblock.Op, kind: Arithmetic) !void {
    const left = try getRegister(registers, op.b);
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const c = block.constants[op.c];
    if (left == .number and c == .number) {
        const result = switch (kind) {
            .add => left.number + c.number,
            .sub => left.number - c.number,
            .mul => left.number * c.number,
            .div => left.number / c.number,
            .mod => @mod(left.number, c.number),
            .pow => zmath.pow(left.number, c.number),
        };
        try setRegister(registers, op.a, JSValue.fromNumber(result));
    } else return error.UnsupportedOpcode;
}

fn comparisonLocalConst(registers: []JSValue, block: *const codeblock.CodeBlock, op: codeblock.Op, kind: Comparison) !void {
    const left = try getRegister(registers, op.b);
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const c = block.constants[op.c];
    if (left == .number and c == .number) {
        const result = switch (kind) {
            .lt => left.number < c.number,
            .gt => left.number > c.number,
            .le => left.number <= c.number,
            .ge => left.number >= c.number,
            .eq => left.number == c.number,
            .ne => left.number != c.number,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (left == .string and c == .string) {
        const eq = std.mem.eql(u8, left.string.value.data, c.string);
        const result = switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => return error.UnsupportedOpcode,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (left == .boolean and c == .boolean) {
        const eq = (left.boolean == c.boolean);
        const result = switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => return error.UnsupportedOpcode,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else return error.UnsupportedOpcode;
}

fn addLocalConst(registers: []JSValue, allocator: Allocator, block: *const codeblock.CodeBlock, op: codeblock.Op) !void {
    const left = try getRegister(registers, op.b);
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const c = block.constants[op.c];
    if (left == .number and c == .number) {
        try setRegister(registers, op.a, JSValue.fromNumber(left.number + c.number));
        return;
    }
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
var global_version: u64 = 1;

pub fn clearGlobalCache() void {
    for (&global_cache) |*slot| slot.* = null;
    global_cache_next = 0;
    global_version +%= 1;
}

fn loadGlobalFast(block: *const codeblock.CodeBlock, closure_env: ?*Environment, index: u8, op_pc: u32) !JSValue {
    const env = closure_env orelse return error.UnsupportedOpcode;
    if (index >= block.constants.len) return error.InvalidConstant;
    const name = switch (block.constants[index]) {
        .string, .property_key => |text| text,
        else => return error.InvalidConstant,
    };
    const slot_idx = ((@intFromPtr(block) >> 4) +% op_pc) & 15;
    if (global_cache[slot_idx]) |entry| {
        if (entry.env == env and (entry.name.ptr == name.ptr or std.mem.eql(u8, entry.name, name))) {
            return entry.value.retain();
        }
    }
    const val = env.get(name) orelse return error.UnsupportedOpcode;
    global_cache[slot_idx] = .{
        .name = name,
        .env = env,
        .value = val,
    };
    return val.retain();
}

fn storeGlobal(allocator: Allocator, block: *const codeblock.CodeBlock, closure_env: ?*Environment, index: u8, val: JSValue) !void {
    const env = closure_env orelse return error.UnsupportedOpcode;
    if (index >= block.constants.len) return error.InvalidConstant;
    const name = switch (block.constants[index]) {
        .string, .property_key => |text| text,
        else => return error.InvalidConstant,
    };
    global_version +%= 1;
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

fn getRegister(registers: []const JSValue, index: u8) !JSValue {
    if (index >= registers.len) return error.InvalidRegister;
    return registers[index];
}

fn setRegister(registers: []JSValue, index: u8, value: JSValue) !void {
    try setRegPrimitive(registers, index, value);
}

test "vm executes arithmetic and retains its result" {
    try std.testing.expect(@sizeOf(CallFrame) <= 64);
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
