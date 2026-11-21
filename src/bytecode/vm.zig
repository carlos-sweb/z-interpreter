//! Register VM for the initial arithmetic, branch, and bare-call subset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zmath = @import("zmath");
const JSValue = zvalue.JSValue;
const environment_mod = @import("../environment.zig");
const Environment = environment_mod.Environment;
const codeblock = @import("codeblock.zig");
const baseline_jit = @import("../jit/baseline.zig");
const interpreter_class = @import("../interpreter_class.zig");
const interpreter_mod = @import("../interpreter.zig");
const zparser = @import("zparser");
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

const ObjectBox = zvalue.Rc(zvalue.ZObject(JSValue));
const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));

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
    key_ptr: [*]const u8 = undefined,
    interned_key_ptr: ?[*]const u8 = null,
    pc: u32 = 0,
    shape_id: u32 = 0,
    next_shape: u32 = 0,
    cached_shape_id: u32 = 0,
    slot_idx: u32 = 0,
};

inline fn needsDeinit(v: JSValue) bool {
    return v.needsDeinit();
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
    if (!callee.isFunction()) return null;
    if (callee.asFunction().value.call != interpreter_class.closureCall) return null;
    const cc: *ClosureCtx = @ptrCast(@alignCast(callee.asFunction().value.ctx));
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
    if (!cached.isFunction() or !current.isFunction()) return false;
    return cached.asFunction() == current.asFunction() or (cached.asFunction().value.ctx == current.asFunction().value.ctx and cached.asFunction().value.call == current.asFunction().value.call);
}

inline fn deinitSlot(v: *JSValue) void {
    const val = v.*;
    if (!val.needsDeinit()) return;
    if (val.isObject()) {
        const box = val.asObject();
        if (box._count > 1) {
            box._count -= 1;
            v.* = JSValue.UNDEFINED;
            return;
        }
    } else if (val.isArray()) {
        const box = val.asArray();
        if (box._count > 1) {
            box._count -= 1;
            v.* = JSValue.UNDEFINED;
            return;
        }
    }
    deinitSlotSlow(v);
}

noinline fn deinitSlotSlow(v: *JSValue) void {
    @branchHint(.cold);
    if (!v.needsDeinit()) return;
    if (v.isObject()) {
        const box = v.asObject();
        if (box._count == 1 and obj_pool_len < 32 and !box.value.is_frozen and box.value.is_extensible and box.value.properties.capacity() <= 16) {
            const props = box.value.properties.entries.items(.value);
            var can_preserve = box.value.cached_len == 0 and props.len > 0 and props.len <= 8;
            var has_accessor = false;
            for (props) |*prop| {
                if (prop.isAccessor()) {
                    has_accessor = true;
                    can_preserve = false;
                    break;
                }
                const d = prop.descriptor;
                if (!d.borrowed_key or !d.writable or !d.enumerable or !d.configurable) {
                    can_preserve = false;
                }
                if (prop.value.needsDeinit()) prop.value.deinit();
                prop.value = JSValue.UNDEFINED;
            }
            if (!has_accessor) {
                if (can_preserve) {
                    box.value.recyclePreserveShape();
                } else {
                    box.value.clearRetainingCapacity();
                }
                obj_pool[obj_pool_len] = box;
                obj_pool_len += 1;
                v.* = JSValue.UNDEFINED;
                return;
            }
        }
        v.deinit();
        v.* = JSValue.UNDEFINED;
    } else if (v.isArray()) {
        const box = v.asArray();
        if (box._count == 1 and arr_pool_len < 32 and box.value.holey == null and box.value.items.capacity <= 16) {
            for (box.value.items.items) |*el| {
                if (el.needsDeinit()) el.deinit();
            }
            box.value.items.items.len = 0;
            arr_pool[arr_pool_len] = box;
            arr_pool_len += 1;
            v.* = JSValue.UNDEFINED;
            return;
        }
        v.deinit();
        v.* = JSValue.UNDEFINED;
    } else {
        v.deinit();
        v.* = JSValue.UNDEFINED;
    }
}

fn callFallback(frame: *CallFrame, allocator: Allocator, callee: JSValue, this_value: JSValue, args_slice: []const JSValue) !JSValue {
    if (!callee.isFunction()) {
        if (frame.interp) |it| return it.throwError(.type_error, "{s} is not a function", .{callee.typeOf()});
        return error.UnsupportedOpcode;
    }
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
    return try callee.asFunction().value.call(callee.asFunction().value.ctx, allocator, this_value, call_args);
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
    if (key_val.isString()) {
        return key_val.asString().value.data;
    } else if (key_val.isNumber()) {
        const n = key_val.asNumber();
        if (std.math.isNan(n) or std.math.isInf(n)) return error.UnsupportedOpcode;
        const idx: i64 = @intFromFloat(n);
        if (@as(f64, @floatFromInt(idx)) == n) {
            return std.fmt.bufPrint(buf, "{d}", .{idx}) catch return error.UnsupportedOpcode;
        } else {
            return std.fmt.bufPrint(buf, "{d}", .{n}) catch return error.UnsupportedOpcode;
        }
    }
    return error.UnsupportedOpcode;
}

fn getProp(frame: *CallFrame, allocator: Allocator, obj: JSValue, key: []const u8) !JSValue {
    if (obj.isObject()) {
        const box = obj.asObject();
        if (box.value.getOwnRecord(key)) |rec| {
            if (rec.isAccessor()) {
                if (frame.interp) |it| return it.getProperty(obj, key);
                return error.UnsupportedOpcode;
            }
            return rec.value.retain();
        }
        var current = box.value.getPrototype();
        while (current) |p| : (current = p.getPrototype()) {
            if (p.getOwnRecord(key)) |rec| {
                if (rec.isAccessor()) {
                    if (frame.interp) |it| return it.getProperty(obj, key);
                    return error.UnsupportedOpcode;
                }
                return rec.value.retain();
            }
        }
        return JSValue.UNDEFINED;
    } else if (obj.isArray()) {
        const box = obj.asArray();
        if (std.mem.eql(u8, key, "length")) {
            return JSValue.fromNumber(@floatFromInt(box.value.length()));
        }
        const idx = std.fmt.parseInt(usize, key, 10) catch return if (frame.interp) |it| it.getProperty(obj, key) else JSValue.UNDEFINED;
        if (idx >= box.value.length()) return if (frame.interp) |it| it.getProperty(obj, key) else JSValue.UNDEFINED;
        return box.value.get(idx).retain();
    } else if (obj.isString()) {
        const box = obj.asString();
        if (std.mem.eql(u8, key, "length")) {
            return JSValue.fromNumber(@floatFromInt(box.value.data.len));
        }
        const idx = std.fmt.parseInt(usize, key, 10) catch return if (frame.interp) |it| it.getProperty(obj, key) else JSValue.UNDEFINED;
        if (idx >= box.value.data.len) return if (frame.interp) |it| it.getProperty(obj, key) else JSValue.UNDEFINED;
        return try JSValue.newString(allocator, box.value.data[idx .. idx + 1]);
    } else if (frame.interp) |it| {
        return it.getProperty(obj, key);
    }
    return error.UnsupportedOpcode;
}

fn setProp(frame: *CallFrame, allocator: Allocator, obj: JSValue, key: []const u8, val: JSValue) !void {
    _ = allocator;
    if (obj.isObject()) {
        const box = obj.asObject();
        if (box.value.getOwnRecord(key)) |rec| {
            if (rec.isAccessor()) {
                if (frame.interp) |it| return it.setPropertyOnValue(obj, key, val);
                return error.UnsupportedOpcode;
            }
        }
        const old = box.value.getOwn(key);
        box.value.set(key, val.retain()) catch |err| switch (err) {
            error.ObjectIsFrozen, error.ObjectNotExtensible, error.PropertyNotWritable => {
                if (frame.interp) |it| return it.setPropertyOnValue(obj, key, val);
                return err;
            },
            else => return err,
        };
        if (old) |o| o.deinit();
    } else if (obj.isArray()) {
        const box = obj.asArray();
        const idx = std.fmt.parseInt(usize, key, 10) catch return if (frame.interp) |it| it.setPropertyOnValue(obj, key, val) else error.UnsupportedOpcode;
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
    } else if (frame.interp) |it| {
        return it.setPropertyOnValue(obj, key, val);
    } else return error.UnsupportedOpcode;
}

noinline fn getElem(frame: *CallFrame, allocator: Allocator, obj: JSValue, key_val: JSValue) !JSValue {
    if (obj.isArray() and key_val.isNumber()) {
        const arr = &obj.asArray().value;
        if (arr.holey == null) {
            const n = key_val.asNumber();
            if (n >= 0 and !std.math.isNan(n) and !std.math.isInf(n)) {
                const idx: usize = @intFromFloat(n);
                if (@as(f64, @floatFromInt(idx)) == n) {
                    if (idx < arr.length()) return arr.get(idx).retain();
                    return JSValue.UNDEFINED;
                }
            }
        }
    }
    var buf: [32]u8 = undefined;
    if (keyToString(allocator, key_val, &buf)) |key| {
        return getProp(frame, allocator, obj, key) catch |err| {
            if (frame.interp) |it| {
                return it.getProperty(obj, key);
            }
            return err;
        };
    } else |_| {
        if (frame.interp) |it| {
            const key = try it.encodeKey(key_val);
            defer it.gc_allocator.free(key);
            return try it.getProperty(obj, key);
        }
        return error.UnsupportedOpcode;
    }
}

noinline fn setElem(frame: *CallFrame, allocator: Allocator, obj: JSValue, key_val: JSValue, val: JSValue) !void {
    if (obj.isArray() and key_val.isNumber()) {
        const arr = &obj.asArray().value;
        const frozen = if (@hasField(@TypeOf(arr.*), "is_frozen")) arr.is_frozen else false;
        if (!frozen and arr.holey == null) {
            const n = key_val.asNumber();
            if (n >= 0 and !std.math.isNan(n) and !std.math.isInf(n)) {
                const idx: usize = @intFromFloat(n);
                if (@as(f64, @floatFromInt(idx)) == n) {
                    const cur = arr.length();
                    if (idx < cur) {
                        arr.toSliceMut()[idx].deinit();
                        arr.toSliceMut()[idx] = val.retain();
                    } else {
                        while (arr.length() < idx) {
                            _ = try arr.push(JSValue.UNDEFINED);
                        }
                        _ = try arr.push(val.retain());
                    }
                    return;
                }
            }
        }
    }
    var buf: [32]u8 = undefined;
    if (keyToString(allocator, key_val, &buf)) |key| {
        setProp(frame, allocator, obj, key, val) catch |err| {
            if (frame.interp) |it| {
                return it.setPropertyOnValue(obj, key, val);
            }
            return err;
        };
        return;
    } else |_| {
        if (frame.interp) |it| {
            const key = try it.encodeKey(key_val);
            defer it.gc_allocator.free(key);
            return it.setPropertyOnValue(obj, key, val);
        }
        return error.UnsupportedOpcode;
    }
}

/// Executes a CodeBlock without consulting the AST. The caller owns the
/// returned value. Every register owns its value for the duration of the
/// call, including values copied from arguments and locals.
noinline fn deinitFrameRegs(slots: []JSValue) void {
    @branchHint(.cold);
    for (slots) |*slot| {
        if (needsDeinit(slot.*)) deinitSlot(slot);
    }
}

noinline fn loadConstSlow(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const v = try constantValue(allocator, frame.block, op.b);
    try setRegValue(frame, frame_regs, op.a, v);
}

noinline fn newObjectSlow(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const obj = if (frame.interp) |itp| try itp.ordinaryObject() else try JSValue.newObject(allocator);
    try setRegValue(frame, frame_regs, op.a, obj);
}

noinline fn newArraySlow(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const arr = try JSValue.newArray(allocator);
    const cap = @max(@as(usize, op.b), 4);
    try arr.asArray().value.reserve(cap);
    try setRegValue(frame, frame_regs, op.a, arr);
}

noinline fn getPropSlow(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op, op_pc: u32, obj: JSValue, key: []const u8, ic: *PropIC) !void {
    @branchHint(.cold);
    if (obj.isObject()) {
        const box = obj.asObject();
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
                return;
            }
        }
    }
    const result = try getProp(frame, allocator, obj, key);
    if (!needsDeinit(result)) {
        try setRegPrimitive(frame_regs, op.a, result);
    } else {
        try setRegValue(frame, frame_regs, op.a, result);
    }
}

noinline fn setPropSlow(allocator: Allocator, frame: *CallFrame, op: codeblock.Op, op_pc: u32, obj: JSValue, key: []const u8, val: JSValue, ic: *PropIC) !void {
    @branchHint(.cold);
    if (obj.isObject()) {
        const box = obj.asObject();
        if (ic.block == frame.block and ic.pc == op_pc and ic.shape_id == box.value.shape_id and ic.key_ptr == key.ptr) {
            if (ic.next_shape != 0) {
                if (ic.interned_key_ptr) |ik_ptr| {
                    const prev_cached_shape = box.value.cached_shape_id;
                    const was_recycled_hit = prev_cached_shape != 0 and ic.slot_idx == box.value.active_len and ic.slot_idx < box.value.cached_len;
                    const interned = ik_ptr[0..key.len];
                    const val_to_store = if (needsDeinit(val)) val.retain() else val;
                    if (box.value.putBorrowedTransition(interned, val_to_store, ic.slot_idx, ic.next_shape) catch false) {
                        if (was_recycled_hit) {
                            ic.cached_shape_id = prev_cached_shape;
                            @constCast(frame.block.ops)[op_pc].opcode = .set_prop_transition;
                        } else if (op.opcode == .set_prop_transition) {
                            @constCast(frame.block.ops)[op_pc].opcode = .set_prop;
                        }
                        return;
                    } else if (needsDeinit(val)) {
                        val_to_store.deinit();
                    }
                }
            }
        }
        if (op.opcode == .set_prop_transition) {
            @constCast(frame.block.ops)[op_pc].opcode = .set_prop;
        }
        if (box.value.cached_len > 0) box.value.syncPartialRecycle();
        if (frame.interp) |itp| {
            const proto_is_obj_proto = if (box.value.prototype) |p| (itp.protos.object.isObject() and p == &itp.protos.object.asObject().value) else true;
            if (box.value.properties.getIndex(key) == null and proto_is_obj_proto) {
                const prev_shape = box.value.shape_id;
                const prev_count = box.value.properties.count();
                const interned = if (ic.block == frame.block and ic.pc == op_pc and ic.key_ptr == key.ptr and ic.interned_key_ptr != null)
                    ic.interned_key_ptr.?[0..key.len]
                else
                    try itp.internPropKey(key);
                const val_to_store = if (needsDeinit(val)) val.retain() else val;
                box.value.setBorrowedKey(interned, val_to_store) catch |err| switch (err) {
                    error.ObjectIsFrozen, error.ObjectNotExtensible, error.PropertyNotWritable => {
                        if (needsDeinit(val)) val_to_store.deinit();
                        return itp.setPropertyOnValue(obj, key, val);
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
                    .cached_shape_id = 0,
                    .slot_idx = @intCast(prev_count),
                    .key_ptr = key.ptr,
                    .interned_key_ptr = interned.ptr,
                };
                return;
            }
        }
        try setProp(frame, allocator, obj, key, val);
        if (box.value.properties.getIndex(key)) |slot_idx| {
            const rec = &box.value.properties.entries.items(.value)[slot_idx];
            if (!rec.isAccessor() and rec.descriptor.writable and !box.value.is_frozen) {
                ic.* = .{
                    .block = frame.block,
                    .pc = op_pc,
                    .shape_id = box.value.shape_id,
                    .next_shape = 0,
                    .cached_shape_id = 0,
                    .slot_idx = @intCast(slot_idx),
                    .key_ptr = key.ptr,
                };
            }
        }
    } else {
        if (op.opcode == .set_prop_transition) {
            @constCast(frame.block.ops)[op_pc].opcode = .set_prop;
        }
        try setProp(frame, allocator, obj, key, val);
    }
}

noinline fn getElemConstSlow(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op, obj: JSValue) !void {
    @branchHint(.cold);
    const key_val = try constantValue(allocator, frame.block, op.c);
    defer key_val.deinit();
    const result = try getElem(frame, allocator, obj, key_val);
    if (!needsDeinit(result)) {
        try setRegPrimitive(frame_regs, op.a, result);
    } else {
        try setRegValue(frame, frame_regs, op.a, result);
    }
}

noinline fn setElemConstSlow(frame: *CallFrame, allocator: Allocator, obj: JSValue, idx: usize, val: JSValue) !void {
    @branchHint(.cold);
    if (obj.isArray()) {
        const arr = &obj.asArray().value;
        const val_to_store = if (needsDeinit(val)) val.retain() else val;
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
    } else {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "{d}", .{idx});
        try setProp(frame, allocator, obj, key, val);
    }
}

noinline fn resolveCallCache(cache: *codeblock.CallSiteCache, callee: JSValue) void {
    @branchHint(.cold);
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

noinline fn resolveCallGlobalCache(cache: *codeblock.CallSiteCache, env: *Environment, gname: []const u8) !void {
    @branchHint(.cold);
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

noinline fn callNativeFallback(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op_a: u8, callee: JSValue, this_value: JSValue, args_slice: []const JSValue) !void {
    @branchHint(.cold);
    defer clearGlobalCache();
    const result = try callFallback(frame, allocator, callee, this_value, args_slice);
    try setRegValue(frame, frame_regs, op_a, result);
}

noinline fn makeClosureOp(frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const vm_interp = frame.interp orelse return error.UnsupportedOpcode;
    const env = frame.closure_env orelse return error.UnsupportedOpcode;
    if (op.b >= frame.block.constants.len) return error.InvalidConstant;
    const fnode = switch (frame.block.constants[op.b]) {
        .function_node => |fn_node| fn_node,
        else => return error.InvalidConstant,
    };
    const closure = try interpreter_class.makeClosure(vm_interp, env, fnode);
    try setRegTracked(frame, frame_regs, op.a, closure);
}

noinline fn iterInitOp(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const iterable = try getRegister(frame_regs, op.b);
    if (!iterable.isArray() and !iterable.isString()) return error.UnsupportedOpcode;
    const it = try JSValue.newArray(allocator);
    _ = try it.asArray().value.push(iterable.retain());
    _ = try it.asArray().value.push(JSValue.fromNumber(0));
    try setRegTracked(frame, frame_regs, op.a, it);
}

noinline fn iterNextOp(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const it = try getRegister(frame_regs, op.c);
    if (!it.isArray() or it.asArray().value.length() < 2) return error.UnsupportedOpcode;
    const target = it.asArray().value.get(0);
    const idx_val = it.asArray().value.get(1);
    if (!idx_val.isNumber()) return error.UnsupportedOpcode;
    const idx: usize = @intFromFloat(idx_val.asNumber());
    if (target.isArray()) {
        if (idx < target.asArray().value.length()) {
            const val = target.asArray().value.get(idx).retain();
            it.asArray().value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
            try setRegTracked(frame, frame_regs, op.a, val);
            try setRegister(frame_regs, op.b, JSValue.fromBool(false));
        } else {
            try setRegister(frame_regs, op.a, JSValue.UNDEFINED);
            try setRegister(frame_regs, op.b, JSValue.fromBool(true));
        }
    } else if (target.isString()) {
        if (idx < target.asString().value.data.len) {
            const ch = try JSValue.newString(allocator, target.asString().value.data[idx .. idx + 1]);
            it.asArray().value.toSliceMut()[1] = JSValue.fromNumber(@floatFromInt(idx + 1));
            try setRegTracked(frame, frame_regs, op.a, ch);
            try setRegister(frame_regs, op.b, JSValue.fromBool(false));
        } else {
            try setRegister(frame_regs, op.a, JSValue.UNDEFINED);
            try setRegister(frame_regs, op.b, JSValue.fromBool(true));
        }
    } else return error.UnsupportedOpcode;
}

noinline fn handleJsThrow(
    frames: []CallFrame,
    frame_count: *usize,
    registers: []JSValue,
    reg_top: *usize,
    catch_stack: []CatchHandler,
    catch_top: *usize,
    thrown: JSValue,
) !*CallFrame {
    if (catch_top.* > 0) {
        catch_top.* -= 1;
        const handler = catch_stack[catch_top.*];
        const target_frame_idx = @as(usize, handler.frame_idx);
        while (frame_count.* > target_frame_idx + 1) {
            const cur_frame = &frames[frame_count.* - 1];
            for (registers[cur_frame.reg_base..reg_top.*]) |*r| deinitSlot(r);
            reg_top.* = cur_frame.reg_base;
            frame_count.* -= 1;
        }
        const cur_frame = &frames[target_frame_idx];
        for (registers[handler.reg_top..reg_top.*]) |*r| deinitSlot(r);
        reg_top.* = handler.reg_top;
        cur_frame.pc = handler.target_pc;
        const hregs = registers[cur_frame.reg_base .. cur_frame.reg_base + cur_frame.block.register_count];
        try setRegTracked(cur_frame, hregs, handler.error_reg, thrown);
        return cur_frame;
    }
    for (registers[0..reg_top.*]) |*r| deinitSlot(r);
    reg_top.* = 0;
    frame_count.* = 0;
    thrown.deinit();
    return error.JsThrow;
}

noinline fn throwValueOp(
    frames: []CallFrame,
    frame_count: *usize,
    registers: []JSValue,
    reg_top: *usize,
    catch_stack: []CatchHandler,
    catch_top: *usize,
    frame_regs: []JSValue,
    op: codeblock.Op,
) !*CallFrame {
    @branchHint(.cold);
    const thrown = (try getRegister(frame_regs, op.a)).retain();
    return handleJsThrow(frames, frame_count, registers, reg_top, catch_stack, catch_top, thrown);
}

noinline fn jcmpLocalConstSlow(frame: *CallFrame, frame_regs: []const JSValue, constants: []const codeblock.Constant, op: codeblock.Op, kind: Comparison) !bool {
    @branchHint(.cold);
    if (op.a >= frame_regs.len) return error.InvalidRegister;
    if (op.b >= constants.len) return error.InvalidConstant;
    const left = frame_regs[op.a];
    const c = constants[op.b];
    if (left.isNumber() and c == .number) {
        const lnum = left.asNumber();
        return switch (kind) {
            .lt => lnum < c.number,
            .gt => lnum > c.number,
            .le => lnum <= c.number,
            .ge => lnum >= c.number,
            .eq => lnum == c.number,
            .ne => lnum != c.number,
        };
    } else if (left.isString() and c == .string) {
        const eq = std.mem.eql(u8, left.asString().value.data, c.string);
        return switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => {
                if (frame.interp) |it| {
                    var rval = try constantValue(it.gc_allocator, frame.block, op.b);
                    defer rval.deinit();
                    const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, rval);
                    return res.isTruthy();
                }
                return error.UnsupportedOpcode;
            },
        };
    } else if (left.isBool() and c == .boolean) {
        const eq = (left.asBool() == c.boolean);
        return switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => error.UnsupportedOpcode,
        };
    } else if (kind == .eq or kind == .ne) {
        if (left.isNumber() and c != .number) {
            return kind == .ne;
        } else if (left.isString() and c != .string) {
            return kind == .ne;
        } else if (left.isBool() and c != .boolean) {
            return kind == .ne;
        } else if (left.isNull() or left.isUndefined()) {
            return kind == .ne;
        } else if (frame.interp) |it| {
            var rval = try constantValue(it.gc_allocator, frame.block, op.b);
            defer rval.deinit();
            const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, rval);
            return res.isTruthy();
        }
        return error.UnsupportedOpcode;
    } else if (frame.interp) |it| {
        var rval = try constantValue(it.gc_allocator, frame.block, op.b);
        defer rval.deinit();
        const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, rval);
        return res.isTruthy();
    }
    return error.UnsupportedOpcode;
}

noinline fn setupCatchOp(
    catch_stack: []CatchHandler,
    catch_top: *usize,
    frame_count: usize,
    reg_top: usize,
    block: *const codeblock.CodeBlock,
    op: codeblock.Op,
) !void {
    @branchHint(.cold);
    if (catch_top.* >= MAX_CATCH_HANDLERS) return error.UnsupportedOpcode;
    catch_stack[catch_top.*] = .{
        .frame_idx = @intCast(frame_count - 1),
        .error_reg = op.a,
        .target_pc = @intCast(try jumpTarget(block, op)),
        .reg_top = @intCast(reg_top),
    };
    catch_top.* += 1;
}

noinline fn vmCallCleanup(registers: []JSValue, reg_top: usize, prev_obj_pool_len: usize, prev_arr_pool_len: usize) void {
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

noinline fn allocCapturedEnv(interp_opt: ?*interpreter_mod.Interpreter, parent_opt: ?*Environment) !?*Environment {
    @branchHint(.cold);
    const itp = interp_opt orelse return parent_opt;
    const parent = parent_opt orelse return parent_opt;
    return try itp.gcChildEnv(parent);
}

fn checkSelfRecursionGuard(callee_block: *const codeblock.CodeBlock, env_opt: ?*Environment) bool {
    for (callee_block.call_target_cache) |*cs| {
        if (cs.global_name) |gname| {
            const env = env_opt orelse return false;
            const val = env.get(gname) orelse return false;
            const target = getBytecodeTarget(val) orelse return false;
            if (target.block != callee_block) return false;
        }
    }
    return true;
}

noinline fn tryInvokeJitTopLevel(
    allocator: Allocator,
    mut_cb: *codeblock.CodeBlock,
    cenv: ?*Environment,
    args: []const JSValue,
    registers: []JSValue,
) ?JSValue {
    @branchHint(.cold);
    if (mut_cb.jit_fn == null) {
        if (!baseline_jit.compile(allocator, mut_cb)) return null;
    }
    const jfn = mut_cb.jit_fn orelse return null;
    if (args.len != mut_cb.param_count) return null;
    for (args) |a| {
        if (needsDeinit(a)) return null;
    }
    if (!checkSelfRecursionGuard(mut_cb, cenv)) return null;
    for (0..mut_cb.param_count) |i| {
        registers[i] = args[i];
    }
    const limit_idx = @min(MAX_REGISTERS, MAX_FRAMES * @as(usize, mut_cb.register_count));
    var jit_out: JSValue = JSValue.UNDEFINED;
    if (jfn(registers.ptr, &jit_out, registers.ptr + limit_idx, cenv) == 0) {
        return jit_out;
    }
    return null;
}

noinline fn tryInvokeJit(
    allocator: Allocator,
    mut_cb: *codeblock.CodeBlock,
    cenv: ?*Environment,
    registers: []JSValue,
    callee_reg_base: usize,
    frame_count: usize,
    frame_regs: []JSValue,
    arg_start: usize,
    arg_count: usize,
    param_count: usize,
    dst_reg: u8,
) bool {
    @branchHint(.cold);
    if (dst_reg >= frame_regs.len) return false;
    if (mut_cb.jit_fn == null) {
        if (!baseline_jit.compile(allocator, mut_cb)) return false;
    }
    const jfn = mut_cb.jit_fn orelse return false;
    if (arg_count != mut_cb.param_count or param_count != mut_cb.param_count) return false;
    if (!checkSelfRecursionGuard(mut_cb, cenv)) return false;
    const remaining_frames = MAX_FRAMES - frame_count;
    const limit_idx = @min(MAX_REGISTERS, callee_reg_base + remaining_frames * @as(usize, mut_cb.register_count));
    var jit_out: JSValue = JSValue.UNDEFINED;
    if (jfn(registers.ptr + callee_reg_base, &jit_out, registers.ptr + limit_idx, cenv) == 0) {
        const slot = &frame_regs[dst_reg];
        if (needsDeinit(slot.*)) deinitSlot(slot);
        slot.* = jit_out;
        return true;
    }
    for (0..param_count) |i| {
        registers[callee_reg_base + i] = frame_regs[arg_start + i];
    }
    if (frame_count > 64) {
        mut_cb.jit_fn = null;
        mut_cb.jit_failed = true;
    }
    return false;
}

pub fn jitNewArray(ctx: *codeblock.OsrContext, regs: [*]JSValue, dst: u32, len_hint: u32) callconv(.c) u8 {
    const frame: *CallFrame = @ptrCast(@alignCast(ctx.frame_ptr));
    const allocator: *const Allocator = @ptrCast(@alignCast(ctx.allocator_ptr));
    const slot = &regs[dst];
    const cap = @max(@as(usize, len_hint), 4);
    if (slot.isArray()) {
        const box = slot.asArray();
        if (box._count == 1 and box.value.holey == null and box.value.items.capacity >= cap and box.value.items.capacity <= 16) {
            for (box.value.items.items) |*el| {
                if (el.needsDeinit()) el.deinit();
            }
            box.value.items.items.len = 0;
            frame.has_rc = true;
            return 0;
        }
    }
    if (needsDeinit(slot.*)) deinitSlot(slot);
    if (arr_pool_len > 0) {
        arr_pool_len -= 1;
        const box = arr_pool[arr_pool_len];
        box._count = 1;
        if (box.value.items.capacity < cap) {
            box.value.reserve(cap) catch {
                box.value.deinit();
                box.destroy();
                return 1;
            };
        }
        slot.* = JSValue.fromArray(box);
        frame.has_rc = true;
        return 0;
    }
    const arr = JSValue.newArray(allocator.*) catch return 1;
    arr.asArray().value.reserve(cap) catch {
        arr.deinit();
        return 1;
    };
    slot.* = arr;
    frame.has_rc = true;
    return 0;
}

pub fn jitSetElemConst(regs: [*]JSValue, arr_reg: u32, idx: u32, val_reg: u32) callconv(.c) u8 {
    const obj = regs[arr_reg];
    if (!obj.isArray()) return 1;
    const arr = &obj.asArray().value;
    if (arr.holey != null) return 1;
    const val = regs[val_reg];
    const len = arr.items.items.len;
    if (idx == len) {
        const val_to_store = if (needsDeinit(val)) val.retain() else val;
        if (len < arr.items.capacity) {
            arr.items.items.len = len + 1;
            arr.items.items.ptr[len] = val_to_store;
            return 0;
        }
        arr.items.append(arr.allocator, val_to_store) catch {
            if (needsDeinit(val_to_store)) val_to_store.deinit();
            return 1;
        };
        return 0;
    } else if (idx < len) {
        const val_to_store = if (needsDeinit(val)) val.retain() else val;
        const old = arr.items.items[idx];
        arr.items.items[idx] = val_to_store;
        if (needsDeinit(old)) old.deinit();
        return 0;
    }
    return 1;
}

pub fn jitGetElemConst(regs: [*]JSValue, dst: u32, arr_reg: u32, idx: u32) callconv(.c) u8 {
    const obj = regs[arr_reg];
    if (!obj.isArray()) return 1;
    const arr = &obj.asArray().value;
    if (arr.holey != null or idx >= arr.items.items.len) return 1;
    const elem = arr.items.items[idx];
    if (!elem.isNumber()) return 1;
    const slot = &regs[dst];
    if (needsDeinit(slot.*)) deinitSlot(slot);
    slot.* = elem;
    return 0;
}

pub fn jitMoveSlot(ctx: *codeblock.OsrContext, regs: [*]JSValue, dst: u32, src: u32) callconv(.c) u8 {
    const frame: *CallFrame = @ptrCast(@alignCast(ctx.frame_ptr));
    const v = regs[src];
    const slot = &regs[dst];
    if (!needsDeinit(v)) {
        if (needsDeinit(slot.*)) deinitSlot(slot);
        slot.* = v;
    } else {
        const retained = v.retain();
        if (needsDeinit(slot.*)) deinitSlot(slot);
        slot.* = retained;
        frame.has_rc = true;
    }
    return 0;
}

pub fn jitDeinitSlot(slot: *JSValue) callconv(.c) void {
    if (needsDeinit(slot.*)) deinitSlot(slot);
}

pub fn jitBitwise(regs: [*]JSValue, dst: u32, lhs_reg: u32, rhs_reg: u32, kind_u32: u32) callconv(.c) u8 {
    const left = regs[lhs_reg];
    const right = regs[rhs_reg];
    if (!left.isNumber() or !right.isNumber()) return 1;
    const lnum = left.asNumber();
    const rnum = right.asNumber();
    const result: f64 = switch (kind_u32) {
        0 => @floatFromInt(numberToInt32(lnum) & numberToInt32(rnum)),
        1 => @floatFromInt(numberToInt32(lnum) | numberToInt32(rnum)),
        2 => @floatFromInt(numberToInt32(lnum) ^ numberToInt32(rnum)),
        3 => @floatFromInt(numberToInt32(lnum) << @as(u5, @intCast(numberToUint32(rnum) & 31))),
        4 => @floatFromInt(numberToInt32(lnum) >> @as(u5, @intCast(numberToUint32(rnum) & 31))),
        5 => @floatFromInt(numberToUint32(lnum) >> @as(u5, @intCast(numberToUint32(rnum) & 31))),
        6 => @floatFromInt(~numberToInt32(lnum)),
        else => return 1,
    };
    const slot = &regs[dst];
    if (needsDeinit(slot.*)) deinitSlot(slot);
    slot.* = JSValue.fromNumberFast(result);
    return 0;
}

pub fn jitNewObject(ctx: *codeblock.OsrContext, regs: [*]JSValue, dst: u32) callconv(.c) u8 {
    const frame: *CallFrame = @ptrCast(@alignCast(ctx.frame_ptr));
    const allocator: *const Allocator = @ptrCast(@alignCast(ctx.allocator_ptr));
    const slot = &regs[dst];
    if (slot.isObject()) {
        const box = slot.asObject();
        if (box._count == 1 and box.value.cached_len == 0 and !box.value.is_frozen and box.value.is_extensible and box.value.properties.capacity() <= 16) {
            const props = box.value.properties.entries.items(.value);
            var can_preserve = props.len > 0 and props.len <= 8;
            var has_accessor = false;
            for (props) |*prop| {
                if (prop.isAccessor()) {
                    has_accessor = true;
                    can_preserve = false;
                    break;
                }
                const d = prop.descriptor;
                if (!d.borrowed_key or !d.writable or !d.enumerable or !d.configurable) {
                    can_preserve = false;
                }
                if (prop.value.needsDeinit()) prop.value.deinit();
                prop.value = JSValue.UNDEFINED;
            }
            if (!has_accessor) {
                if (can_preserve) {
                    box.value.recyclePreserveShape();
                } else {
                    box.value.clearRetainingCapacity();
                }
                if (frame.interp) |itp| {
                    if (itp.protos.object.isObject()) {
                        box.value.prototype = &itp.protos.object.asObject().value;
                    } else {
                        box.value.prototype = null;
                    }
                } else {
                    box.value.prototype = null;
                }
                frame.has_rc = true;
                return 0;
            }
        }
    }
    if (needsDeinit(slot.*)) deinitSlot(slot);
    if (obj_pool_len > 0) {
        obj_pool_len -= 1;
        const box = obj_pool[obj_pool_len];
        box._count = 1;
        if (frame.interp) |itp| {
            if (itp.protos.object.isObject()) {
                box.value.prototype = &itp.protos.object.asObject().value;
            } else {
                box.value.prototype = null;
            }
        } else {
            box.value.prototype = null;
        }
        slot.* = JSValue.fromObject(box);
        frame.has_rc = true;
        return 0;
    }
    const obj = (if (frame.interp) |itp| itp.ordinaryObject() else JSValue.newObject(allocator.*)) catch return 1;
    slot.* = obj;
    frame.has_rc = true;
    return 0;
}

pub fn jitSetProp(ctx: *codeblock.OsrContext, regs: [*]JSValue, packed_info: u64, key_ptr: [*]const u8) callconv(.c) u8 {
    const obj_reg: u8 = @truncate(packed_info);
    const val_reg: u8 = @truncate(packed_info >> 8);
    const ic_idx: u8 = @truncate(packed_info >> 16);
    const op_pc: u32 = @truncate(packed_info >> 32);
    const frame: *CallFrame = @ptrCast(@alignCast(ctx.frame_ptr));
    const prop_ic: *[256]PropIC = @ptrCast(@alignCast(ctx.prop_ic_ptr));
    const obj = regs[obj_reg];
    if (!obj.isObject()) return 1;
    const box = obj.asObject();
    const val = regs[val_reg];
    const ic = &prop_ic[ic_idx];
    const slot = ic.slot_idx;

    if (ic.block == frame.block and ic.pc == op_pc and box.value.shape_id == ic.shape_id) {
        if (ic.next_shape != 0) {
            if (box.value.cached_shape_id == ic.cached_shape_id and
                box.value.active_len == slot and
                slot < box.value.cached_len and
                !box.value.is_frozen and
                box.value.is_extensible and
                box.value.properties.entries.items(.key)[slot].ptr == ic.interned_key_ptr)
            {
                box.value.properties.entries.items(.value)[slot].value = if (needsDeinit(val)) val.retain() else val;
                const next_active = box.value.active_len + 1;
                box.value.shape_id = ic.next_shape;
                if (next_active == box.value.cached_len) {
                    box.value.cached_len = 0;
                    box.value.cached_shape_id = 0;
                    box.value.active_len = 0;
                } else {
                    box.value.active_len = next_active;
                }
                return 0;
            }
        } else {
            if (ic.key_ptr == key_ptr and slot < box.value.properties.count()) {
                const rec = &box.value.properties.entries.items(.value)[slot];
                if (!rec.isAccessor() and rec.descriptor.writable and !box.value.is_frozen) {
                    if (!needsDeinit(rec.value) and !needsDeinit(val)) {
                        rec.value = val;
                    } else {
                        const old = rec.value;
                        rec.value = val.retain();
                        old.deinit();
                    }
                    return 0;
                }
            }
        }
    }
    return 1;
}

pub fn jitGetProp(ctx: *codeblock.OsrContext, regs: [*]JSValue, packed_info: u64, key_ptr: [*]const u8) callconv(.c) u8 {
    const dst_reg: u8 = @truncate(packed_info);
    const obj_reg: u8 = @truncate(packed_info >> 8);
    const ic_idx: u8 = @truncate(packed_info >> 16);
    const op_pc: u32 = @truncate(packed_info >> 32);
    const frame: *CallFrame = @ptrCast(@alignCast(ctx.frame_ptr));
    const prop_ic: *[256]PropIC = @ptrCast(@alignCast(ctx.prop_ic_ptr));
    const obj = regs[obj_reg];
    if (!obj.isObject()) return 1;
    const box = obj.asObject();
    const ic = &prop_ic[ic_idx];
    if (ic.block == frame.block and ic.pc == op_pc and ic.shape_id == box.value.shape_id and ic.key_ptr == key_ptr and ic.slot_idx < box.value.properties.count()) {
        const rec = &box.value.properties.entries.items(.value)[ic.slot_idx];
        if (!rec.isAccessor()) {
            const v = rec.value;
            if (!v.isNumber()) return 1;
            const slot = &regs[dst_reg];
            if (needsDeinit(slot.*)) deinitSlot(slot);
            slot.* = v;
            return 0;
        }
    }
    return 1;
}

noinline fn tryEnterOsr(
    allocator: *const Allocator,
    frame: *CallFrame,
    frame_regs: []JSValue,
    prop_ic: *[256]PropIC,
    start_ip: usize,
    end_ip: usize,
    regs_limit: [*]JSValue,
) usize {
    @branchHint(.cold);
    const mut_cb = @constCast(frame.block);
    if (mut_cb.osr_fn == null) {
        mut_cb.osr_count +%= 1;
        if (mut_cb.osr_count < baseline_jit.OSR_THRESHOLD) return start_ip;
        if (!baseline_jit.compileOsr(allocator.*, mut_cb, start_ip, end_ip)) return start_ip;
    }
    const ofn = mut_cb.osr_fn orelse return start_ip;
    if (mut_cb.osr_header_ip != start_ip or mut_cb.osr_end_ip != end_ip) return start_ip;
    var ctx = codeblock.OsrContext{
        .allocator_ptr = allocator,
        .frame_ptr = frame,
        .prop_ic_ptr = prop_ic,
        .regs_limit = regs_limit,
        .global_version_ptr = &global_version,
    };
    const next_ip: usize = ofn(frame_regs.ptr, &ctx);
    if (next_ip >= start_ip and next_ip <= end_ip) {
        mut_cb.osr_fn = null;
        mut_cb.osr_failed = true;
    }
    return next_ip;
}

pub fn vmCall(allocator: Allocator, block: *const codeblock.CodeBlock, closure_env: ?*Environment, this_value: JSValue, args: []const JSValue, interp: ?*interpreter_mod.Interpreter) !JSValue {
    const registers = try allocator.alloc(JSValue, MAX_REGISTERS);
    defer allocator.free(registers);

    if (!block.jit_failed) {
        const mut_cb = @constCast(block);
        mut_cb.call_count +%= 1;
        if (mut_cb.jit_fn != null or mut_cb.call_count >= baseline_jit.HOT_THRESHOLD) {
            if (tryInvokeJitTopLevel(allocator, mut_cb, closure_env, args, registers)) |res| {
                return res;
            }
        }
    }

    clearGlobalCache();
    defer clearGlobalCache();

    const frames = try allocator.alloc(CallFrame, MAX_FRAMES);
    defer allocator.free(frames);

    var reg_top: usize = 0;
    const prev_obj_pool_len = obj_pool_len;
    const prev_arr_pool_len = arr_pool_len;
    defer vmCallCleanup(registers, reg_top, prev_obj_pool_len, prev_arr_pool_len);

    return vmCallDispatch(allocator, block, closure_env, this_value, args, interp, frames, registers, &reg_top);
}

noinline fn vmCallDispatch(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    closure_env: ?*Environment,
    initial_this: JSValue,
    args: []const JSValue,
    interp: ?*interpreter_mod.Interpreter,
    frames: []CallFrame,
    registers: []JSValue,
    reg_top_out: *usize,
) !JSValue {
    var catch_stack: [MAX_CATCH_HANDLERS]CatchHandler = undefined;
    var catch_top: usize = 0;
    var prop_ic: [256]PropIC = @splat(.{});

    var frame_count: usize = 0;
    var reg_top: usize = 0;
    var max_reg_water_mark: usize = 0;

    if (block.register_count > MAX_REGISTERS) return error.OutOfMemory;

    reg_top = block.register_count;
    reg_top_out.* = reg_top;
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
        .this_value = initial_this,
        .closure_env = if (block.capture_count > 0) try allocCapturedEnv(interp, closure_env) else closure_env,
        .has_rc = init_has_rc,
        .return_reg = 0,
        .interp = interp,
    };
    frame_count = 1;

    while (true) {
        const val = vmExecLoop(
            allocator,
            frames,
            &frame_count,
            registers,
            &reg_top,
            reg_top_out,
            &max_reg_water_mark,
            &catch_stack,
            &catch_top,
            &prop_ic,
        ) catch |err| {
            if (err == error.JsThrow and catch_top > 0 and interp != null and interp.?.pending_exception != null) {
                const thrown = interp.?.pending_exception.?;
                interp.?.pending_exception = null;
                _ = try handleJsThrow(frames, &frame_count, registers, &reg_top, &catch_stack, &catch_top, thrown);
                reg_top_out.* = reg_top;
                continue;
            }
            return err;
        };
        return val;
    }
}

noinline fn vmExecLoop(
    allocator: Allocator,
    frames: []CallFrame,
    frame_count_ptr: *usize,
    registers: []JSValue,
    reg_top_ptr: *usize,
    reg_top_out: *usize,
    max_reg_water_mark_ptr: *usize,
    catch_stack: []CatchHandler,
    catch_top_ptr: *usize,
    prop_ic: *[256]PropIC,
) !JSValue {
    var frame_count: usize = frame_count_ptr.*;
    var reg_top: usize = reg_top_ptr.*;
    var catch_top: usize = catch_top_ptr.*;
    var max_reg_water_mark: usize = max_reg_water_mark_ptr.*;

    var frame: *CallFrame = &frames[frame_count - 1];
    var code: []const codeblock.Op = frame.block.ops;
    var ip: usize = frame.pc;
    var frame_regs: []JSValue = registers[frame.reg_base .. frame.reg_base + frame.block.register_count];

    defer {
        frame_count_ptr.* = frame_count;
        reg_top_ptr.* = reg_top;
        catch_top_ptr.* = catch_top;
        max_reg_water_mark_ptr.* = max_reg_water_mark;
        frame.pc = @intCast(ip);
    }

    if (ip >= code.len) return error.MissingReturn;

    dispatch: switch (code[ip].opcode) {
        .nop => {
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_const => {
            const op = code[ip];
            if (op.b >= frame.block.constants.len) return error.InvalidConstant;
            const c = frame.block.constants[op.b];
            switch (c) {
                .number => |n| try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(n)),
                .boolean => |b| try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(b)),
                else => try loadConstSlow(allocator, frame, frame_regs, op),
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_undefined => {
            try setRegPrimitive(frame_regs, code[ip].a, JSValue.UNDEFINED);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .new_object => {
            const op = code[ip];
            if (op.a >= frame_regs.len) return error.InvalidRegister;
            const slot = &frame_regs[op.a];
            if (needsDeinit(slot.*)) deinitSlot(slot);
            if (obj_pool_len > 0) {
                obj_pool_len -= 1;
                const box = obj_pool[obj_pool_len];
                box._count = 1;
                if (frame.interp) |itp| {
                    if (itp.protos.object.isObject()) {
                        box.value.prototype = &itp.protos.object.asObject().value;
                    } else {
                        box.value.prototype = null;
                    }
                } else {
                    box.value.prototype = null;
                }
                slot.* = JSValue.fromObject(box);
                frame.has_rc = true;
            } else {
                try newObjectSlow(allocator, frame, frame_regs, op);
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .new_array => {
            const op = code[ip];
            if (op.a >= frame_regs.len) return error.InvalidRegister;
            const slot = &frame_regs[op.a];
            if (needsDeinit(slot.*)) deinitSlot(slot);
            if (arr_pool_len > 0) {
                arr_pool_len -= 1;
                const box = arr_pool[arr_pool_len];
                box._count = 1;
                const cap = @max(@as(usize, op.b), 4);
                if (box.value.items.capacity < cap) try box.value.reserve(cap);
                slot.* = JSValue.fromArray(box);
                frame.has_rc = true;
            } else {
                try newArraySlow(allocator, frame, frame_regs, op);
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .get_prop => {
            const op_pc: u32 = @intCast(ip);
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.b);
            const key = try constantKey(frame.block, op.c);
            const ic_idx = ((@intFromPtr(frame.block) >> 4) +% op_pc) & 255;
            const ic = &prop_ic[ic_idx];
            if (obj.isObject()) {
                const box = obj.asObject();
                if (ic.block == frame.block and ic.pc == op_pc and ic.shape_id == box.value.shape_id and ic.key_ptr == key.ptr and ic.slot_idx < box.value.properties.count()) {
                    const rec = &box.value.properties.entries.items(.value)[ic.slot_idx];
                    if (!rec.isAccessor()) {
                        if (!needsDeinit(rec.value)) {
                            try setRegPrimitive(frame_regs, op.a, rec.value);
                        } else {
                            try setRegValue(frame, frame_regs, op.a, rec.value.retain());
                        }
                        ip += 1;
                        if (ip >= code.len) return error.MissingReturn;
                        continue :dispatch code[ip].opcode;
                    }
                }
            }
            try getPropSlow(allocator, frame, frame_regs, op, op_pc, obj, key, ic);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .set_prop => {
            const op_pc: u32 = @intCast(ip);
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.a);
            const key = try constantKey(frame.block, op.b);
            const val = try getRegister(frame_regs, op.c);
            const ic_idx = ((@intFromPtr(frame.block) >> 4) +% op_pc) & 255;
            const ic = &prop_ic[ic_idx];
            if (obj.isObject()) {
                const box = obj.asObject();
                if (ic.block == frame.block and ic.pc == op_pc and ic.shape_id == box.value.shape_id and ic.key_ptr == key.ptr and ic.next_shape == 0 and ic.slot_idx < box.value.properties.count()) {
                    const rec = &box.value.properties.entries.items(.value)[ic.slot_idx];
                    if (!rec.isAccessor() and rec.descriptor.writable and !box.value.is_frozen) {
                        if (!needsDeinit(rec.value) and !needsDeinit(val)) {
                            rec.value = val;
                        } else {
                            const old = rec.value;
                            rec.value = val.retain();
                            old.deinit();
                        }
                        ip += 1;
                        if (ip >= code.len) return error.MissingReturn;
                        continue :dispatch code[ip].opcode;
                    }
                }
            }
            try setPropSlow(allocator, frame, op, op_pc, obj, key, val, ic);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .set_prop_transition => {
            const op_pc: u32 = @intCast(ip);
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.a);
            const val = try getRegister(frame_regs, op.c);
            const ic_idx = ((@intFromPtr(frame.block) >> 4) +% op_pc) & 255;
            const ic = &prop_ic[ic_idx];
            if (obj.isObject()) {
                const box = obj.asObject();
                const slot = ic.slot_idx;
                if (ic.block == frame.block and
                    ic.pc == op_pc and
                    box.value.shape_id == ic.shape_id and
                    box.value.cached_shape_id == ic.cached_shape_id and
                    box.value.active_len == slot and
                    slot < box.value.cached_len and
                    !box.value.is_frozen and
                    box.value.is_extensible and
                    box.value.properties.entries.items(.key)[slot].ptr == ic.interned_key_ptr)
                {
                    box.value.properties.entries.items(.value)[slot].value = if (needsDeinit(val)) val.retain() else val;
                    const next_active = box.value.active_len + 1;
                    box.value.shape_id = ic.next_shape;
                    if (next_active == box.value.cached_len) {
                        box.value.cached_len = 0;
                        box.value.cached_shape_id = 0;
                        box.value.active_len = 0;
                    } else {
                        box.value.active_len = next_active;
                    }
                    ip += 1;
                    if (ip >= code.len) return error.MissingReturn;
                    continue :dispatch code[ip].opcode;
                }
            }
            const key = try constantKey(frame.block, op.b);
            try setPropSlow(allocator, frame, op, op_pc, obj, key, val, ic);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .get_elem => {
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.b);
            const key_val = try getRegister(frame_regs, op.c);
            const result = try getElem(frame, allocator, obj, key_val);
            try setRegTracked(frame, frame_regs, op.a, result);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .get_elem_const => {
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.b);
            if (obj.isArray() and op.c < frame.block.constants.len) {
                const c = frame.block.constants[op.c];
                if (c == .number) {
                    const idx: usize = @intFromFloat(c.number);
                    const arr = &obj.asArray().value;
                    if (arr.holey == null) {
                        if (idx < arr.items.items.len) {
                            const elem = arr.items.items[idx];
                            if (!needsDeinit(elem)) {
                                try setRegPrimitive(frame_regs, op.a, elem);
                            } else {
                                try setRegValue(frame, frame_regs, op.a, elem.retain());
                            }
                        } else {
                            try setRegPrimitive(frame_regs, op.a, JSValue.UNDEFINED);
                        }
                        ip += 1;
                        if (ip >= code.len) return error.MissingReturn;
                        continue :dispatch code[ip].opcode;
                    }
                }
            }
            try getElemConstSlow(allocator, frame, frame_regs, op, obj);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .set_elem => {
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.a);
            const key_val = try getRegister(frame_regs, op.b);
            const val = try getRegister(frame_regs, op.c);
            try setElem(frame, allocator, obj, key_val, val);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .set_elem_const => {
            const op = code[ip];
            const obj = try getRegister(frame_regs, op.a);
            const val = try getRegister(frame_regs, op.c);
            const idx: usize = op.b;
            if (obj.isArray() and obj.asArray().value.holey == null and idx == obj.asArray().value.items.items.len) {
                const arr = &obj.asArray().value;
                const val_to_store = if (needsDeinit(val)) val.retain() else val;
                try arr.items.append(arr.allocator, val_to_store);
            } else {
                try setElemConstSlow(frame, allocator, obj, idx, val);
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_null => {
            try setRegPrimitive(frame_regs, code[ip].a, JSValue.NULL);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_true => {
            try setRegPrimitive(frame_regs, code[ip].a, JSValue.fromBool(true));
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_false => {
            try setRegPrimitive(frame_regs, code[ip].a, JSValue.fromBool(false));
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_this => {
            try setRegValue(frame, frame_regs, code[ip].a, frame.this_value.retain());
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .move, .load_local, .store_local => {
            const op = code[ip];
            const v = try getRegister(frame_regs, op.b);
            if (!needsDeinit(v)) {
                try setRegPrimitive(frame_regs, op.a, v);
            } else {
                try setRegValue(frame, frame_regs, op.a, v.retain());
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .load_global => {
            const op = code[ip];
            const env = frame.closure_env orelse return error.UnsupportedOpcode;
            const name = try constantKey(frame.block, op.b);
            const slot_idx = ((@intFromPtr(env) >> 4) +% (@intFromPtr(name.ptr) >> 3)) & 31;
            const entry = &global_cache[slot_idx];
            if (entry.env == env and entry.name_ptr == name.ptr and entry.binding_idx < entry.target_env.bindings.items.len) {
                const v = entry.target_env.bindings.items[entry.binding_idx].value;
                if (!needsDeinit(v)) {
                    try setRegPrimitive(frame_regs, op.a, v);
                } else {
                    try setRegValue(frame, frame_regs, op.a, v.retain());
                }
            } else {
                try loadGlobalSlow(frame, frame_regs, op, env, name, entry);
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .store_global => {
            const op = code[ip];
            const env = frame.closure_env orelse return error.UnsupportedOpcode;
            const name = try constantKey(frame.block, op.a);
            const val = try getRegister(frame_regs, op.b);
            const slot_idx = ((@intFromPtr(env) >> 4) +% (@intFromPtr(name.ptr) >> 3)) & 31;
            const entry = &global_cache[slot_idx];
            if (entry.env == env and entry.name_ptr == name.ptr and entry.is_mutable and entry.binding_idx < entry.target_env.bindings.items.len) {
                global_version +%= 1;
                const slot = &entry.target_env.bindings.items[entry.binding_idx].value;
                if (!needsDeinit(slot.*) and !needsDeinit(val)) {
                    slot.* = val;
                } else {
                    const old = slot.*;
                    slot.* = val.retain();
                    old.deinit();
                }
            } else {
                try storeGlobalSlow(frame, allocator, env, name, val, entry);
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .add => {
            const op = code[ip];
            const left = try getRegister(frame_regs, op.b);
            const right = try getRegister(frame_regs, op.c);
            if (left.isNumber() and right.isNumber()) {
                try setRegPrimitive(frame_regs, op.a, JSValue.fromNumberFast(left.asNumber() + right.asNumber()));
            } else {
                try addOp(frame, frame_regs, allocator, op);
            }
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .add_num => {
            try arithmetic(frame, frame_regs, code[ip], .add);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .sub_num => {
            try arithmetic(frame, frame_regs, code[ip], .sub);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .mul_num => {
            try arithmetic(frame, frame_regs, code[ip], .mul);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .div_num => {
            try arithmetic(frame, frame_regs, code[ip], .div);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .mod_num => {
            try arithmetic(frame, frame_regs, code[ip], .mod);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .pow_num => {
            try arithmetic(frame, frame_regs, code[ip], .pow);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .lt_num => {
            try comparison(frame, frame_regs, code[ip], .lt);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .gt_num => {
            try comparison(frame, frame_regs, code[ip], .gt);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .le_num => {
            try comparison(frame, frame_regs, code[ip], .le);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .ge_num => {
            try comparison(frame, frame_regs, code[ip], .ge);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .eq => {
            try comparison(frame, frame_regs, code[ip], .eq);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .ne => {
            try comparison(frame, frame_regs, code[ip], .ne);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .loose_eq => {
            try looseEquality(frame, frame_regs, code[ip], false);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .loose_ne => {
            try looseEquality(frame, frame_regs, code[ip], true);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .and_bits => {
            try bitwise(frame, frame_regs, code[ip], .bit_and);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .or_bits => {
            try bitwise(frame, frame_regs, code[ip], .bit_or);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .xor_bits => {
            try bitwise(frame, frame_regs, code[ip], .bit_xor);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .shl => {
            try bitwise(frame, frame_regs, code[ip], .shl);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .shr => {
            try bitwise(frame, frame_regs, code[ip], .shr);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .ushr => {
            try bitwise(frame, frame_regs, code[ip], .ushr);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .sub_local_const => {
            const op = code[ip];
            const left = try getRegister(frame_regs, op.b);
            if (op.c < frame.block.constants.len) {
                const c = frame.block.constants[op.c];
                if (left.isNumber() and c == .number) {
                    try setRegPrimitive(frame_regs, op.a, JSValue.fromNumberFast(left.asNumber() - c.number));
                } else {
                    try arithmeticLocalConst(frame, frame_regs, frame.block, op, .sub);
                }
            } else return error.InvalidConstant;
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .add_local_const => {
            const op = code[ip];
            const left = try getRegister(frame_regs, op.b);
            if (op.c < frame.block.constants.len) {
                const c = frame.block.constants[op.c];
                if (left.isNumber() and c == .number) {
                    try setRegPrimitive(frame_regs, op.a, JSValue.fromNumberFast(left.asNumber() + c.number));
                } else {
                    try addLocalConst(frame, frame_regs, allocator, frame.block, op);
                }
            } else return error.InvalidConstant;
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .lt_local_const => {
            const op = code[ip];
            const left = try getRegister(frame_regs, op.b);
            if (op.c < frame.block.constants.len) {
                const c = frame.block.constants[op.c];
                if (left.isNumber() and c == .number) {
                    try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(left.asNumber() < c.number));
                } else {
                    try comparisonLocalConst(frame, frame_regs, frame.block, op, .lt);
                }
            } else return error.InvalidConstant;
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .gt_local_const => {
            try comparisonLocalConst(frame, frame_regs, frame.block, code[ip], .gt);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .le_local_const => {
            try comparisonLocalConst(frame, frame_regs, frame.block, code[ip], .le);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .ge_local_const => {
            try comparisonLocalConst(frame, frame_regs, frame.block, code[ip], .ge);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .eq_local_const => {
            const op = code[ip];
            const left = try getRegister(frame_regs, op.b);
            if (op.c < frame.block.constants.len) {
                const c = frame.block.constants[op.c];
                if (left.isNumber() and c == .number) {
                    try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(left.asNumber() == c.number));
                } else {
                    try comparisonLocalConst(frame, frame_regs, frame.block, op, .eq);
                }
            } else return error.InvalidConstant;
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jeq_local_const_false => {
            const op = code[ip];
            const consts = frame.block.constants;
            const cond = if (op.a < frame_regs.len and op.b < consts.len and frame_regs[op.a].isNumber() and consts[op.b] == .number)
                frame_regs[op.a].asNumber() == consts[op.b].number
            else
                try jcmpLocalConstSlow(frame, frame_regs, consts, op, .eq);
            ip += if (cond) 1 else op.c;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jlt_local_const_false => {
            const op = code[ip];
            const consts = frame.block.constants;
            const cond = if (op.a < frame_regs.len and op.b < consts.len and frame_regs[op.a].isNumber() and consts[op.b] == .number)
                frame_regs[op.a].asNumber() < consts[op.b].number
            else
                try jcmpLocalConstSlow(frame, frame_regs, consts, op, .lt);
            ip += if (cond) 1 else op.c;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jle_local_const_false => {
            const op = code[ip];
            const consts = frame.block.constants;
            const cond = if (op.a < frame_regs.len and op.b < consts.len and frame_regs[op.a].isNumber() and consts[op.b] == .number)
                frame_regs[op.a].asNumber() <= consts[op.b].number
            else
                try jcmpLocalConstSlow(frame, frame_regs, consts, op, .le);
            ip += if (cond) 1 else op.c;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jgt_local_const_false => {
            const op = code[ip];
            const consts = frame.block.constants;
            const cond = if (op.a < frame_regs.len and op.b < consts.len and frame_regs[op.a].isNumber() and consts[op.b] == .number)
                frame_regs[op.a].asNumber() > consts[op.b].number
            else
                try jcmpLocalConstSlow(frame, frame_regs, consts, op, .gt);
            ip += if (cond) 1 else op.c;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jge_local_const_false => {
            const op = code[ip];
            const consts = frame.block.constants;
            const cond = if (op.a < frame_regs.len and op.b < consts.len and frame_regs[op.a].isNumber() and consts[op.b] == .number)
                frame_regs[op.a].asNumber() >= consts[op.b].number
            else
                try jcmpLocalConstSlow(frame, frame_regs, consts, op, .ge);
            ip += if (cond) 1 else op.c;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .neg => {
            const op = code[ip];
            const src = try getRegister(frame_regs, op.b);
            if (!src.isNumber()) {
                if (frame.interp) |it| {
                    const n = try it.toNumericJS(src);
                    defer n.deinit();
                    if (n.isBigInt()) {
                        const res = try it.gcNewBigIntValue(try n.asBigInt().value.negate());
                        try setRegTracked(frame, frame_regs, op.a, res);
                    } else {
                        try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(-n.asNumber()));
                    }
                    ip += 1;
                    if (ip >= code.len) return error.MissingReturn;
                    continue :dispatch code[ip].opcode;
                }
                return error.UnsupportedOpcode;
            }
            try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(-src.asNumber()));
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .not => {
            const op = code[ip];
            const truthy = try isTruthy(frame_regs, op.b);
            try setRegPrimitive(frame_regs, op.a, JSValue.fromBool(!truthy));
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .not_bits => {
            try notBitsOp(frame, frame_regs, code[ip]);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .typeof => {
            const op = code[ip];
            const src = try getRegister(frame_regs, op.b);
            const str = try JSValue.newString(allocator, src.typeOf());
            try setRegTracked(frame, frame_regs, op.a, str);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .typeof_global => {
            try typeofGlobal(allocator, frame, frame_regs, code[ip]);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jump => {
            const target_ip: usize = @intCast(try jumpTarget(frame.block, code[ip]));
            if (target_ip < ip and !frame.block.osr_failed) {
                const remaining_frames = MAX_FRAMES - frame_count;
                const limit_idx = @min(MAX_REGISTERS, frame.reg_base + remaining_frames * @as(usize, frame.block.register_count));
                ip = tryEnterOsr(&allocator, frame, frame_regs, prop_ic, target_ip, ip, registers.ptr + limit_idx);
            } else {
                ip = target_ip;
            }
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jump_if_true => {
            const op = code[ip];
            const val = try getRegister(frame_regs, op.a);
            const truthy = if (val.isBool()) val.asBool() else try isTruthy(frame_regs, op.a);
            ip = if (truthy) @intCast(try jumpTarget(frame.block, op)) else ip + 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jump_if_false => {
            const op = code[ip];
            const val = try getRegister(frame_regs, op.a);
            const truthy = if (val.isBool()) val.asBool() else try isTruthy(frame_regs, op.a);
            ip = if (!truthy) @intCast(try jumpTarget(frame.block, op)) else ip + 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .jump_if_not_nullish => {
            const op = code[ip];
            const val = try getRegister(frame_regs, op.a);
            ip = if (!val.isUndefined() and !val.isNull()) @intCast(try jumpTarget(frame.block, op)) else ip + 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .call => {
            const op = code[ip];
            const callee = try getRegister(frame_regs, op.b);
            const cache_slice: []codeblock.CallSiteCache = @constCast(frame.block.call_target_cache);
            if (op.c >= cache_slice.len) return error.InvalidRegister;
            const cache = &cache_slice[op.c];
            const arg_count = cache.arg_count;
            const start = @as(usize, op.b) + 1;
            const end = start + arg_count;
            if (end > frame_regs.len) return error.InvalidRegister;

            const hit = if (cache.callee) |cached| calleeMatches(cached, callee) else false;
            if (!hit) resolveCallCache(cache, callee);

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
                if (!callee_has_rc and !callee_block.jit_failed) {
                    const mut_cb = @constCast(callee_block);
                    mut_cb.call_count +%= 1;
                    if (mut_cb.jit_fn != null or mut_cb.call_count >= baseline_jit.HOT_THRESHOLD) {
                        const cenv: ?*Environment = if (cache.closure_env) |ce| @ptrCast(@alignCast(ce)) else frame.closure_env;
                        if (tryInvokeJit(allocator, mut_cb, cenv, registers, callee_reg_base, frame_count, frame_regs, start, arg_count, param_count, op.a)) {
                            ip += 1;
                            if (ip >= code.len) return error.MissingReturn;
                            continue :dispatch code[ip].opcode;
                        }
                    }
                }

                const base_cenv: ?*Environment = if (cache.closure_env) |env| @ptrCast(@alignCast(env)) else null;
                frame.pc = @intCast(ip + 1);
                frames[frame_count] = CallFrame{
                    .block = callee_block,
                    .pc = 0,
                    .reg_base = @intCast(callee_reg_base),
                    .this_value = this_value,
                    .closure_env = if (callee_block.capture_count > 0) try allocCapturedEnv(frame.interp, base_cenv) else base_cenv,
                    .has_rc = callee_has_rc,
                    .return_reg = op.a,
                    .interp = if (cache.interp) |itp| @ptrCast(@alignCast(itp)) else null,
                };
                frame = &frames[frame_count];
                frame_count += 1;
                reg_top = new_reg_top;
                reg_top_out.* = new_reg_top;
                code = callee_block.ops;
                ip = 0;
                frame_regs = registers[callee_reg_base .. callee_reg_base + callee_block.register_count];
                if (ip >= code.len) return error.MissingReturn;
                continue :dispatch code[0].opcode;
            } else {
                try callNativeFallback(allocator, frame, frame_regs, op.a, callee, this_value, frame_regs[start..end]);
                ip += 1;
                if (ip >= code.len) return error.MissingReturn;
                continue :dispatch code[ip].opcode;
            }
        },
        .call_global => {
            const op = code[ip];
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
                try resolveCallGlobalCache(cache, env, gname);
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
                if (!callee_has_rc and !callee_block.jit_failed) {
                    const mut_cb = @constCast(callee_block);
                    mut_cb.call_count +%= 1;
                    if (mut_cb.jit_fn != null or mut_cb.call_count >= baseline_jit.HOT_THRESHOLD) {
                        const cenv: ?*Environment = if (cache.closure_env) |ce| @ptrCast(@alignCast(ce)) else frame.closure_env;
                        if (tryInvokeJit(allocator, mut_cb, cenv, registers, callee_reg_base, frame_count, frame_regs, start, arg_count, param_count, op.a)) {
                            ip += 1;
                            if (ip >= code.len) return error.MissingReturn;
                            continue :dispatch code[ip].opcode;
                        }
                    }
                }

                const base_cenv: ?*Environment = if (cache.closure_env) |cenv| @ptrCast(@alignCast(cenv)) else null;
                frame.pc = @intCast(ip + 1);
                frames[frame_count] = CallFrame{
                    .block = callee_block,
                    .pc = 0,
                    .reg_base = @intCast(callee_reg_base),
                    .this_value = JSValue.UNDEFINED,
                    .closure_env = if (callee_block.capture_count > 0) try allocCapturedEnv(frame.interp, base_cenv) else base_cenv,
                    .has_rc = callee_has_rc,
                    .return_reg = op.a,
                    .interp = if (cache.interp) |itp| @ptrCast(@alignCast(itp)) else null,
                };
                frame = &frames[frame_count];
                frame_count += 1;
                reg_top = new_reg_top;
                reg_top_out.* = new_reg_top;
                code = callee_block.ops;
                ip = 0;
                frame_regs = registers[callee_reg_base .. callee_reg_base + callee_block.register_count];
                if (ip >= code.len) return error.MissingReturn;
                continue :dispatch code[0].opcode;
            } else {
                try callNativeFallback(allocator, frame, frame_regs, op.a, callee, JSValue.UNDEFINED, frame_regs[start..end]);
                ip += 1;
                if (ip >= code.len) return error.MissingReturn;
                continue :dispatch code[ip].opcode;
            }
        },
        .return_value => {
            const raw_val = try getRegister(frame_regs, code[ip].a);
            const is_prim = !needsDeinit(raw_val);
            const val = if (is_prim) raw_val else raw_val.retain();
            if (frame.has_rc) deinitFrameRegs(registers[frame.reg_base..reg_top]);
            reg_top = frame.reg_base;
            reg_top_out.* = reg_top;
            if (catch_top > 0) {
                while (catch_top > 0 and catch_stack[catch_top - 1].frame_idx >= frame_count - 1) catch_top -= 1;
            }
            const return_reg = frame.return_reg;
            frame_count -= 1;
            if (frame_count == 0) return val;
            frame = &frames[frame_count - 1];
            code = frame.block.ops;
            ip = frame.pc;
            frame_regs = registers[frame.reg_base .. frame.reg_base + frame.block.register_count];
            if (is_prim) {
                try setRegPrimitive(frame_regs, return_reg, val);
            } else {
                try setRegValue(frame, frame_regs, return_reg, val);
            }
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .return_undefined => {
            if (frame.has_rc) deinitFrameRegs(registers[frame.reg_base..reg_top]);
            reg_top = frame.reg_base;
            reg_top_out.* = reg_top;
            if (catch_top > 0) {
                while (catch_top > 0 and catch_stack[catch_top - 1].frame_idx >= frame_count - 1) catch_top -= 1;
            }
            const return_reg = frame.return_reg;
            frame_count -= 1;
            if (frame_count == 0) return JSValue.UNDEFINED;
            frame = &frames[frame_count - 1];
            code = frame.block.ops;
            ip = frame.pc;
            frame_regs = registers[frame.reg_base .. frame.reg_base + frame.block.register_count];
            try setRegPrimitive(frame_regs, return_reg, JSValue.UNDEFINED);
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .make_closure => {
            try makeClosureOp(frame, frame_regs, code[ip]);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .iter_init => {
            try iterInitOp(allocator, frame, frame_regs, code[ip]);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .iter_next => {
            try iterNextOp(allocator, frame, frame_regs, code[ip]);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .iter_end => {
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .setup_catch => {
            try setupCatchOp(catch_stack, &catch_top, frame_count, reg_top, frame.block, code[ip]);
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .end_catch => {
            if (catch_top > 0 and catch_stack[catch_top - 1].frame_idx == frame_count - 1) catch_top -= 1;
            ip += 1;
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        .throw_value => {
            frame = try throwValueOp(frames, &frame_count, registers, &reg_top, catch_stack, &catch_top, frame_regs, code[ip]);
            reg_top_out.* = reg_top;
            code = frame.block.ops;
            ip = frame.pc;
            frame_regs = registers[frame.reg_base .. frame.reg_base + frame.block.register_count];
            if (ip >= code.len) return error.MissingReturn;
            continue :dispatch code[ip].opcode;
        },
        else => return error.UnsupportedOpcode,
    }
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

fn isDifferentType(l: JSValue, r: JSValue) bool {
    if (l.isNumber() != r.isNumber()) return true;
    if (l.isString() != r.isString()) return true;
    if (l.isBool() != r.isBool()) return true;
    if (l.isNull() != r.isNull()) return true;
    if (l.isUndefined() != r.isUndefined()) return true;
    return false;
}

noinline fn looseEquality(frame: *CallFrame, registers: []JSValue, op: codeblock.Op, is_ne: bool) !void {
    @branchHint(.cold);
    if (frame.interp) |it| {
        const left = try getRegister(registers, op.b);
        const right = try getRegister(registers, op.c);
        const res = try it.applyBinaryOp(if (is_ne) .ne else .eq, left, right);
        try setRegTracked(frame, registers, op.a, res);
    } else return error.UnsupportedOpcode;
}

noinline fn typeofGlobal(allocator: Allocator, frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    @branchHint(.cold);
    const name = try constantKey(frame.block, op.b);
    if (frame.closure_env) |env| {
        switch (env.lookup(name)) {
            .value => |v| {
                const str = try JSValue.newString(allocator, v.typeOf());
                try setRegTracked(frame, frame_regs, op.a, str);
                return;
            },
            .tdz => {
                if (frame.interp) |it| {
                    return it.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name});
                }
                return error.UnsupportedOpcode;
            },
            .not_found => {},
        }
    }
    if (frame.interp) |it| {
        if (it.global_object) |go| {
            if (go.isObject()) {
                if (go.asObject().value.getOwn(name)) |v| {
                    const str = try JSValue.newString(allocator, v.typeOf());
                    try setRegTracked(frame, frame_regs, op.a, str);
                    return;
                }
            }
        }
    }
    const str = try JSValue.newString(allocator, "undefined");
    try setRegTracked(frame, frame_regs, op.a, str);
}

noinline fn notBitsOp(frame: *CallFrame, frame_regs: []JSValue, op: codeblock.Op) !void {
    const src = try getRegister(frame_regs, op.b);
    if (src.isNumber()) {
        try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(@floatFromInt(~numberToInt32(src.asNumber()))));
    } else if (frame.interp) |it| {
        const i = try it.toInt32JS(src);
        try setRegPrimitive(frame_regs, op.a, JSValue.fromNumber(@floatFromInt(~i)));
    } else return error.UnsupportedOpcode;
}

noinline fn bitwise(frame: *CallFrame, registers: []JSValue, op: codeblock.Op, kind: BitwiseOp) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left.isNumber() and right.isNumber()) {
        const lnum = left.asNumber();
        const rnum = right.asNumber();
        const result: f64 = switch (kind) {
            .bit_and => @floatFromInt(numberToInt32(lnum) & numberToInt32(rnum)),
            .bit_or => @floatFromInt(numberToInt32(lnum) | numberToInt32(rnum)),
            .bit_xor => @floatFromInt(numberToInt32(lnum) ^ numberToInt32(rnum)),
            .shl => @floatFromInt(numberToInt32(lnum) << @as(u5, @intCast(numberToUint32(rnum) & 31))),
            .shr => @floatFromInt(numberToInt32(lnum) >> @as(u5, @intCast(numberToUint32(rnum) & 31))),
            .ushr => @floatFromInt(numberToUint32(lnum) >> @as(u5, @intCast(numberToUint32(rnum) & 31))),
        };
        try setRegister(registers, op.a, JSValue.fromNumberFast(result));
        return;
    }
    if (frame.interp) |it| {
        const bop: zparser.BinaryOp = switch (kind) {
            .bit_and => .bitand,
            .bit_or => .bitor,
            .bit_xor => .bitxor,
            .shl => .shl,
            .shr => .shr,
            .ushr => .ushr,
        };
        const res = try it.applyBinaryOp(bop, left, right);
        try setRegTracked(frame, registers, op.a, res);
        return;
    }
    return error.UnsupportedOpcode;
}

fn arithmetic(frame: *CallFrame, registers: []JSValue, op: codeblock.Op, kind: Arithmetic) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left.isNumber() and right.isNumber()) {
        const lnum = left.asNumber();
        const rnum = right.asNumber();
        const result = switch (kind) {
            .add => lnum + rnum,
            .sub => lnum - rnum,
            .mul => lnum * rnum,
            .div => lnum / rnum,
            .mod => @rem(lnum, rnum),
            .pow => zmath.pow(lnum, rnum),
        };
        try setRegister(registers, op.a, JSValue.fromNumberFast(result));
    } else if (frame.interp) |it| {
        const bop: zparser.BinaryOp = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
        };
        const res = try it.applyBinaryOp(bop, left, right);
        try setRegTracked(frame, registers, op.a, res);
    } else return error.UnsupportedOpcode;
}

fn comparisonToBinaryOp(kind: Comparison) zparser.BinaryOp {
    return switch (kind) {
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        .eq => .eqeqeq,
        .ne => .noteqeq,
    };
}

fn comparison(frame: *CallFrame, registers: []JSValue, op: codeblock.Op, kind: Comparison) !void {
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left.isNumber() and right.isNumber()) {
        const lnum = left.asNumber();
        const rnum = right.asNumber();
        const result = switch (kind) {
            .lt => lnum < rnum,
            .gt => lnum > rnum,
            .le => lnum <= rnum,
            .ge => lnum >= rnum,
            .eq => lnum == rnum,
            .ne => lnum != rnum,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (left.isString() and right.isString()) {
        const eq = std.mem.eql(u8, left.asString().value.data, right.asString().value.data);
        const result = switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => {
                if (frame.interp) |it| {
                    const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, right);
                    try setRegTracked(frame, registers, op.a, res);
                    return;
                }
                return error.UnsupportedOpcode;
            },
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (kind == .eq or kind == .ne) {
        if (left.isBool() and right.isBool()) {
            const eq = (left.asBool() == right.asBool());
            try setRegister(registers, op.a, JSValue.fromBool(if (kind == .eq) eq else !eq));
        } else if (left.isNull() and right.isNull()) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .eq));
        } else if (left.isUndefined() and right.isUndefined()) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .eq));
        } else if (isDifferentType(left, right)) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .ne));
        } else if (frame.interp) |it| {
            const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, right);
            try setRegTracked(frame, registers, op.a, res);
        } else return error.UnsupportedOpcode;
    } else if (frame.interp) |it| {
        const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, right);
        try setRegTracked(frame, registers, op.a, res);
    } else return error.UnsupportedOpcode;
}

noinline fn addOp(frame: *CallFrame, registers: []JSValue, allocator: Allocator, op: codeblock.Op) !void {
    @branchHint(.cold);
    const left = try getRegister(registers, op.b);
    const right = try getRegister(registers, op.c);
    if (left.isNumber() and right.isNumber()) {
        try setRegister(registers, op.a, JSValue.fromNumberFast(left.asNumber() + right.asNumber()));
        return;
    }
    if (left.isString() or right.isString()) {
        var buf_l: [32]u8 = undefined;
        var buf_r: [32]u8 = undefined;
        const sl = stringSlice(left, &buf_l);
        const sr = stringSlice(right, &buf_r);
        if (sl != null and sr != null) {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sl.?, sr.? });
            defer allocator.free(combined);
            const result = try JSValue.newString(allocator, combined);
            try setRegTracked(frame, registers, op.a, result);
            return;
        }
    }
    if (frame.interp) |it| {
        const res = try it.applyBinaryOp(.add, left, right);
        try setRegTracked(frame, registers, op.a, res);
        return;
    }
    return error.UnsupportedOpcode;
}

fn arithmeticLocalConst(frame: *CallFrame, registers: []JSValue, block: *const codeblock.CodeBlock, op: codeblock.Op, kind: Arithmetic) !void {
    const left = try getRegister(registers, op.b);
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const c = block.constants[op.c];
    if (left.isNumber() and c == .number) {
        const lnum = left.asNumber();
        const result = switch (kind) {
            .add => lnum + c.number,
            .sub => lnum - c.number,
            .mul => lnum * c.number,
            .div => lnum / c.number,
            .mod => @rem(lnum, c.number),
            .pow => zmath.pow(lnum, c.number),
        };
        try setRegister(registers, op.a, JSValue.fromNumberFast(result));
    } else if (frame.interp) |it| {
        var rval = try constantValue(it.gc_allocator, block, op.c);
        defer rval.deinit();
        const bop: zparser.BinaryOp = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
        };
        const res = try it.applyBinaryOp(bop, left, rval);
        try setRegTracked(frame, registers, op.a, res);
    } else return error.UnsupportedOpcode;
}

fn comparisonLocalConst(frame: *CallFrame, registers: []JSValue, block: *const codeblock.CodeBlock, op: codeblock.Op, kind: Comparison) !void {
    const left = try getRegister(registers, op.b);
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const c = block.constants[op.c];
    if (left.isNumber() and c == .number) {
        const lnum = left.asNumber();
        const result = switch (kind) {
            .lt => lnum < c.number,
            .gt => lnum > c.number,
            .le => lnum <= c.number,
            .ge => lnum >= c.number,
            .eq => lnum == c.number,
            .ne => lnum != c.number,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (left.isString() and c == .string) {
        const eq = std.mem.eql(u8, left.asString().value.data, c.string);
        const result = switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => {
                if (frame.interp) |it| {
                    var rval = try constantValue(it.gc_allocator, block, op.c);
                    defer rval.deinit();
                    const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, rval);
                    try setRegTracked(frame, registers, op.a, res);
                    return;
                }
                return error.UnsupportedOpcode;
            },
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (left.isBool() and c == .boolean) {
        const eq = (left.asBool() == c.boolean);
        const result = switch (kind) {
            .eq => eq,
            .ne => !eq,
            else => return error.UnsupportedOpcode,
        };
        try setRegister(registers, op.a, JSValue.fromBool(result));
    } else if (kind == .eq or kind == .ne) {
        if (left.isNumber() and c != .number) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .ne));
        } else if (left.isString() and c != .string) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .ne));
        } else if (left.isBool() and c != .boolean) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .ne));
        } else if (left.isNull() or left.isUndefined()) {
            try setRegister(registers, op.a, JSValue.fromBool(kind == .ne));
        } else if (frame.interp) |it| {
            var rval = try constantValue(it.gc_allocator, block, op.c);
            defer rval.deinit();
            const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, rval);
            try setRegTracked(frame, registers, op.a, res);
        } else return error.UnsupportedOpcode;
    } else if (frame.interp) |it| {
        var rval = try constantValue(it.gc_allocator, block, op.c);
        defer rval.deinit();
        const res = try it.applyBinaryOp(comparisonToBinaryOp(kind), left, rval);
        try setRegTracked(frame, registers, op.a, res);
    } else return error.UnsupportedOpcode;
}

noinline fn addLocalConst(frame: *CallFrame, registers: []JSValue, allocator: Allocator, block: *const codeblock.CodeBlock, op: codeblock.Op) !void {
    @branchHint(.cold);
    const left = try getRegister(registers, op.b);
    if (op.c >= block.constants.len) return error.InvalidConstant;
    const c = block.constants[op.c];
    if (left.isNumber() and c == .number) {
        try setRegister(registers, op.a, JSValue.fromNumberFast(left.asNumber() + c.number));
        return;
    }
    const right = try constantValue(allocator, block, op.c);
    defer right.deinit();
    if (left.isString() or right.isString()) {
        var buf_l: [32]u8 = undefined;
        var buf_r: [32]u8 = undefined;
        const sl = stringSlice(left, &buf_l);
        const sr = stringSlice(right, &buf_r);
        if (sl != null and sr != null) {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sl.?, sr.? });
            defer allocator.free(combined);
            const result = try JSValue.newString(allocator, combined);
            try setRegTracked(frame, registers, op.a, result);
            return;
        }
    }
    if (frame.interp) |it| {
        const res = try it.applyBinaryOp(.add, left, right);
        try setRegTracked(frame, registers, op.a, res);
        return;
    }
    return error.UnsupportedOpcode;
}

fn stringSlice(v: JSValue, buf: *[32]u8) ?[]const u8 {
    if (v.isString()) return v.asString().value.data;
    if (v.isNumber()) return std.fmt.bufPrint(buf, "{d}", .{v.asNumber()}) catch null;
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    if (v.isNull()) return "null";
    if (v.isUndefined()) return "undefined";
    return null;
}

fn isTruthy(registers: []const JSValue, index: u8) !bool {
    const value = try getRegister(registers, index);
    return value.isTruthy();
}

const GlobalCacheEntry = struct {
    env: ?*Environment = null,
    target_env: *Environment = undefined,
    name_ptr: [*]const u8 = undefined,
    binding_idx: u32 = 0,
    is_mutable: bool = false,
};

var global_cache: [32]GlobalCacheEntry = @splat(.{});
pub var global_version: u64 = 1;

pub fn clearGlobalCache() void {
    @memset(&global_cache, .{});
    global_version +%= 1;
    environment_mod.env_struct_version +%= 1;
}

noinline fn loadGlobalSlow(
    frame: *CallFrame,
    frame_regs: []JSValue,
    op: codeblock.Op,
    env: *Environment,
    name: []const u8,
    entry: *GlobalCacheEntry,
) !void {
    @branchHint(.cold);
    var cur: ?*Environment = env;
    while (cur) |e| : (cur = e.parent) {
        if (e.tdz.contains(name)) {
            if (frame.interp) |it| return it.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name});
            return error.UnsupportedOpcode;
        }
        if (e.bindingIndex(name)) |idx| {
            const v = e.bindings.items[idx].value;
            entry.* = .{
                .env = env,
                .target_env = e,
                .name_ptr = name.ptr,
                .binding_idx = @intCast(idx),
                .is_mutable = !e.consts.contains(name),
            };
            if (!needsDeinit(v)) {
                try setRegPrimitive(frame_regs, op.a, v);
            } else {
                try setRegValue(frame, frame_regs, op.a, v.retain());
            }
            return;
        }
    }
    if (frame.interp) |it| return it.throwError(.reference_error, "{s} is not defined", .{name});
    return error.UnsupportedOpcode;
}

noinline fn storeGlobalSlow(
    frame: *CallFrame,
    allocator: Allocator,
    env: *Environment,
    name: []const u8,
    val: JSValue,
    entry: *GlobalCacheEntry,
) !void {
    @branchHint(.cold);
    global_version +%= 1;
    var cur: ?*Environment = env;
    while (cur) |e| : (cur = e.parent) {
        if (e.tdz.contains(name)) {
            if (e.bindingIndex(name) == null) {
                clearGlobalCache();
                try e.define(allocator, name, val.retain());
                entry.* = .{
                    .env = env,
                    .target_env = e,
                    .name_ptr = name.ptr,
                    .binding_idx = @intCast(e.bindingIndex(name).?),
                    .is_mutable = !e.consts.contains(name),
                };
                return;
            }
            if (frame.interp) |it| return it.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name});
            return error.UnsupportedOpcode;
        }
        if (e.bindingIndex(name)) |idx| {
            if (e.consts.contains(name)) {
                if (frame.interp) |it| return it.throwError(.type_error, "Assignment to constant variable.", .{});
                return error.UnsupportedOpcode;
            }
            const slot = &e.bindings.items[idx].value;
            const old = slot.*;
            slot.* = val.retain();
            old.deinit();
            entry.* = .{
                .env = env,
                .target_env = e,
                .name_ptr = name.ptr,
                .binding_idx = @intCast(idx),
                .is_mutable = true,
            };
            return;
        }
    }
    clearGlobalCache();
    try env.define(allocator, name, val.retain());
    if (env.bindingIndex(name)) |idx| {
        entry.* = .{
            .env = env,
            .target_env = env,
            .name_ptr = name.ptr,
            .binding_idx = @intCast(idx),
            .is_mutable = !env.consts.contains(name),
        };
    }
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
    const value = try vmCall(std.testing.allocator, &block, null, JSValue.UNDEFINED, &.{ JSValue.fromNumber(2), JSValue.fromNumber(3) }, null);
    defer value.deinit();
    try std.testing.expect(value.isNumber());
    try std.testing.expectEqual(@as(f64, 5), value.asNumber());
}

test {
    _ = @import("../jit/x64_asm.zig");
    _ = @import("../jit/baseline.zig");
}
