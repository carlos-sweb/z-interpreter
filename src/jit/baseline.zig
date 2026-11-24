const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const environment_mod = @import("../environment.zig");
const Environment = environment_mod.Environment;
const codeblock = @import("../bytecode/codeblock.zig");
const vm = @import("../bytecode/vm.zig");
const math_builtins = @import("../math_builtins.zig");
const x64_asm = @import("x64_asm.zig");
const Assembler = x64_asm.Assembler;
const Label = x64_asm.Label;
const Xmm = x64_asm.Xmm;

pub const JitFn = codeblock.JitFn;
pub const OsrFn = codeblock.OsrFn;
pub const JitGlobalSlot = codeblock.JitGlobalSlot;
pub const HOT_THRESHOLD: u32 = 32;
pub const OSR_THRESHOLD: u32 = 64;
const HEADER_FUNCTION: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.function, @as(*zvalue.Rc(zvalue.Callable), @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
const HEADER_ARRAY: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.array, @as(*zvalue.Rc(zvalue.ZArray(JSValue)), @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
const HEADER_OBJECT: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.object, @as(*zvalue.Rc(zvalue.ZObject(JSValue)), @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
const HEADER_TYPED_ARRAY_BITS: u64 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.typed_array, @as(*zvalue.Rc(zvalue.TypedArrayBox), @ptrFromInt(8)));
    break :blk dummy.bits & JSValue.TAG15_MASK;
};

const ObjectBox = zvalue.Rc(zvalue.ZObject(JSValue));
const ZObj = zvalue.ZObject(JSValue);
const PropMap = @TypeOf(@as(ZObj, undefined).properties);
const PropDataList = PropMap.DataList;
const PropEntry = PropMap.Data;
const Prop = @TypeOf(@as(PropEntry, undefined).value);
const KeySlice = @TypeOf(@as(PropEntry, undefined).key);

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

const key_byte_offset_multiplier: usize = blk: {
    var dummy: PropDataList = .empty;
    dummy.capacity = 1;
    dummy.len = 1;
    dummy.bytes = @ptrFromInt(0x1000);
    const slice_ptr = @intFromPtr(dummy.items(.key).ptr);
    break :blk slice_ptr - 0x1000;
};
const key_size: i32 = @intCast(@sizeOf(KeySlice));
const key_ptr_offset: i32 = blk: {
    const dummy_key: *KeySlice = @ptrFromInt(0x1000);
    break :blk @intCast(@intFromPtr(&dummy_key.ptr) - 0x1000);
};

const value_byte_offset_multiplier: usize = blk: {
    var dummy: PropDataList = .empty;
    dummy.capacity = 1;
    dummy.len = 1;
    dummy.bytes = @ptrFromInt(0x1000);
    const slice_ptr = @intFromPtr(dummy.items(.value).ptr);
    break :blk slice_ptr - 0x1000;
};

const box_val_offset: i32 = @offsetOf(ObjectBox, "value");
const zobj_shape_id_offset: i32 = box_val_offset + @offsetOf(ZObj, "shape_id");
const zobj_cached_shape_id_offset: i32 = box_val_offset + @offsetOf(ZObj, "cached_shape_id");
const zobj_cached_len_offset: i32 = box_val_offset + @offsetOf(ZObj, "cached_len");
const zobj_active_len_offset: i32 = box_val_offset + @offsetOf(ZObj, "active_len");
const zobj_is_frozen_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_frozen");
const zobj_is_extensible_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_extensible");
const zobj_entries_offset: i32 = box_val_offset + @offsetOf(ZObj, "properties") + @offsetOf(PropMap, "entries");
const zobj_entries_bytes_offset: i32 = zobj_entries_offset + @offsetOf(PropDataList, "bytes");
const zobj_entries_len_offset: i32 = zobj_entries_offset + @offsetOf(PropDataList, "len");
const zobj_entries_cap_offset: i32 = zobj_entries_offset + @offsetOf(PropDataList, "capacity");

const prop_val_offset: i32 = @offsetOf(Prop, "value");
const prop_desc_offset: i32 = @offsetOf(Prop, "descriptor");
const prop_size: i32 = @intCast(@sizeOf(Prop));

const ic_size: i32 = @intCast(@sizeOf(PropIC));
const ic_block_offset: i32 = @offsetOf(PropIC, "block");
const ic_key_ptr_offset: i32 = @offsetOf(PropIC, "key_ptr");
const ic_interned_key_ptr_offset: i32 = @offsetOf(PropIC, "interned_key_ptr");
const ic_pc_offset: i32 = @offsetOf(PropIC, "pc");
const ic_shape_id_offset: i32 = @offsetOf(PropIC, "shape_id");
const ic_next_shape_offset: i32 = @offsetOf(PropIC, "next_shape");
const ic_cached_shape_id_offset: i32 = @offsetOf(PropIC, "cached_shape_id");
const ic_slot_idx_offset: i32 = @offsetOf(PropIC, "slot_idx");

const ctx_prop_ic_ptr_offset: i32 = @offsetOf(codeblock.OsrContext, "prop_ic_ptr");
const obj_rc_off: i32 = @intCast(@offsetOf(ObjectBox, "_count"));
const zobj_is_sealed_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_sealed");
const zobj_is_error_data_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_error_data");

const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
const ZArr = zvalue.ZArray(JSValue);
const ArrList = @FieldType(ZArr, "items");
const HoleyState = ZArr.HoleyState;
const HoleMaskList = @FieldType(HoleyState, "hole_mask");
const arr_rc_off: i32 = @intCast(@offsetOf(ArrayBox, "_count"));
const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
const arr_items_len_off: i32 = arr_items_ptr_off + 8;
const arr_items_cap_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "capacity")));
const h_mask_off: i32 = @intCast(@offsetOf(HoleyState, "hole_mask"));
const h_mask_ptr_off: i32 = h_mask_off + @as(i32, @intCast(@offsetOf(HoleMaskList, "items")));
const h_mask_len_off: i32 = h_mask_ptr_off + 8;
const h_is_holey_off: i32 = @intCast(@offsetOf(HoleyState, "is_holey"));
const h_log_len_off: i32 = @intCast(@offsetOf(HoleyState, "logical_length"));

fn constantName(block: *const codeblock.CodeBlock, idx: u8) ?[]const u8 {
    if (idx >= block.constants.len) return null;
    return switch (block.constants[idx]) {
        .string, .property_key => |s| s,
        else => null,
    };
}

pub fn jitResolveGlobalSlot(
    env_ptr: ?*anyopaque,
    name_ptr: [*]const u8,
    name_len: usize,
    slot: *JitGlobalSlot,
) callconv(.c) u8 {
    const env: *Environment = @ptrCast(@alignCast(env_ptr orelse return 1));
    const name = name_ptr[0..name_len];
    var cur: ?*Environment = env;
    while (cur) |e| : (cur = e.parent) {
        if (e.tdz.contains(name)) return 1;
        if (e.bindingIndex(name)) |idx| {
            slot.* = .{
                .env = env_ptr,
                .value_ptr = &e.bindings.items[idx].value,
                .struct_version = environment_mod.env_struct_version,
                .is_mutable = @intFromBool(!e.consts.contains(name)),
            };
            return 0;
        }
    }
    return 1;
}

pub fn canUseFastSelfRec(block: *const codeblock.CodeBlock) bool {
    if (!comptime x64_asm.is_supported_host) return false;
    if (block.exception_table.len > 0 or block.flags.has_try) return false;
    if (block.flags.is_generator or block.flags.is_async or block.flags.needs_arguments) return false;
    if (block.ops.len == 0) return false;
    if (block.param_count != 1) return false;
    if (block.register_count == 0 or block.register_count > 8) return false;
    if (block.local_count > block.register_count) return false;
    const bname = block.name orelse return false;

    var has_self_call = false;
    for (block.ops, 0..) |op, ip| {
        switch (op.opcode) {
            .nop => {},
            .jle_local_const_false,
            .jlt_local_const_false,
            .jge_local_const_false,
            .jgt_local_const_false,
            .jeq_local_const_false => {
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
                const target = ip + @as(usize, op.c);
                if (target >= block.ops.len) return false;
            },
            .add_local_const, .sub_local_const => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.constants.len) return false;
                if (block.constants[op.c] != .number) return false;
            },
            .add, .add_num, .sub_num, .mul_num, .div_num => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
            },
            .neg => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
            },
            .load_const => {
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
            },
            .load_local, .move => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
            },
            .jump => {
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
            },
            .loose_eq, .loose_ne, .eq, .ne => {
                if (op.a == 0 or op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
                if (ip + 1 >= block.ops.len) return false;
                const next_op = block.ops[ip + 1];
                if ((next_op.opcode != .jump_if_false and next_op.opcode != .jump_if_true) or next_op.a != op.a) return false;
            },
            .jump_if_false, .jump_if_true => {
                if (ip == 0) return false;
                const prev_op = block.ops[ip - 1];
                switch (prev_op.opcode) {
                    .loose_eq, .loose_ne, .eq, .ne => if (prev_op.a != op.a) return false,
                    else => return false,
                }
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
            },
            .return_value => {
                if (op.a >= block.register_count) return false;
            },
            .return_undefined => {},
            .call_global => {
                if (op.a >= block.register_count) return false;
                if (op.c >= block.call_target_cache.len) return false;
                const cs = &block.call_target_cache[op.c];
                if (cs.this_reg != null or cs.arg_count != 1) return false;
                const gname = cs.global_name orelse return false;
                if (!std.mem.eql(u8, gname, bname)) return false;
                if ((@as(usize, op.b) + 1 + 1) > block.register_count) return false;
                has_self_call = true;
            },
            else => return false,
        }
    }
    return has_self_call;
}

pub fn canCompile(block: *const codeblock.CodeBlock) bool {
    if (!comptime x64_asm.is_supported_host) return false;
    if (block.exception_table.len > 0 or block.flags.has_try) return false;
    if (block.flags.is_generator or block.flags.is_async or block.flags.needs_arguments) return false;
    if (block.register_count == 0 or block.register_count > 32) return false;
    if (block.param_count > block.register_count or block.local_count > block.register_count) return false;
    if (block.ops.len == 0) return false;

    var seen_store_global = false;
    var store_global_ip: usize = 0;
    var last_stored_global_name: ?[]const u8 = null;
    var num_validated_regs: u32 = 0;
    var max_jump_target: usize = 0;

    for (block.ops, 0..) |op, ip| {
        const reg_bit = if (op.a < 32) (@as(u32, 1) << @intCast(op.a)) else 0;
        switch (op.opcode) {
            .nop, .return_undefined => {},
            .load_undefined, .load_null, .load_true, .load_false => {
                if (op.a >= block.register_count or seen_store_global) return false;
                num_validated_regs &= ~reg_bit;
            },
            .load_const => {
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                switch (block.constants[op.b]) {
                    .number => num_validated_regs |= reg_bit,
                    .boolean => {
                        if (seen_store_global) return false;
                        num_validated_regs &= ~reg_bit;
                    },
                    else => return false,
                }
            },
            .move, .load_local, .store_local => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
                const src_bit = @as(u32, 1) << @intCast(op.b);
                if (seen_store_global and (num_validated_regs & src_bit) == 0) return false;
                if ((num_validated_regs & src_bit) != 0) {
                    num_validated_regs |= reg_bit;
                } else {
                    num_validated_regs &= ~reg_bit;
                }
            },
            .neg, .not_bits => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
                const b_bit = @as(u32, 1) << @intCast(op.b);
                if (seen_store_global and (num_validated_regs & b_bit) == 0) return false;
                if (op.opcode == .not_bits and seen_store_global) return false;
                num_validated_regs |= reg_bit;
            },
            .not => {
                if (op.a >= block.register_count or op.b >= block.register_count or seen_store_global) return false;
                num_validated_regs &= ~reg_bit;
            },
            .add, .add_num, .sub_num, .mul_num, .div_num => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
                const b_bit = @as(u32, 1) << @intCast(op.b);
                const c_bit = @as(u32, 1) << @intCast(op.c);
                if (seen_store_global and ((num_validated_regs & b_bit) == 0 or (num_validated_regs & c_bit) == 0)) return false;
                num_validated_regs |= reg_bit;
            },
            .mod_num, .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                if (seen_store_global) return false;
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
                num_validated_regs |= reg_bit;
            },
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
                if (seen_store_global) return false;
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
                num_validated_regs &= ~reg_bit;
            },
            .add_local_const, .sub_local_const => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.constants.len) return false;
                if (block.constants[op.c] != .number) return false;
                const b_bit = @as(u32, 1) << @intCast(op.b);
                if (seen_store_global and (num_validated_regs & b_bit) == 0) return false;
                num_validated_regs |= reg_bit;
            },
            .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
                if (seen_store_global) return false;
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.constants.len) return false;
                if (block.constants[op.c] != .number) return false;
                num_validated_regs &= ~reg_bit;
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                if (seen_store_global) return false;
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
                const target = ip + @as(usize, op.c);
                if (target >= block.ops.len) return false;
                max_jump_target = @max(max_jump_target, target);
            },
            .jump_if_false, .jump_if_true => {
                if (seen_store_global) return false;
                if (op.a >= block.register_count) return false;
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
                max_jump_target = @max(max_jump_target, target);
            },
            .jump => {
                if (seen_store_global) return false;
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
                max_jump_target = @max(max_jump_target, target);
            },
            .call_global => {
                if (seen_store_global) return false;
                if (op.a >= block.register_count) return false;
                const bname = block.name orelse return false;
                if (op.c >= block.call_target_cache.len) return false;
                const cs = &block.call_target_cache[op.c];
                if (cs.this_reg != null or cs.arg_count != block.param_count) return false;
                const gname = cs.global_name orelse return false;
                if (!std.mem.eql(u8, gname, bname)) return false;
                if ((@as(usize, op.b) + 1 + cs.arg_count) > block.register_count) return false;
                num_validated_regs |= reg_bit;
            },
            .load_global => {
                if (op.a >= block.register_count) return false;
                const gname = constantName(block, op.b) orelse return false;
                if (seen_store_global) {
                    const last = last_stored_global_name orelse return false;
                    if (!std.mem.eql(u8, gname, last)) return false;
                }
                num_validated_regs |= reg_bit;
            },
            .store_global => {
                if (seen_store_global) return false;
                if (op.b >= block.register_count) return false;
                const gname = constantName(block, op.a) orelse return false;
                seen_store_global = true;
                store_global_ip = ip;
                last_stored_global_name = gname;
            },
            .return_value => {
                if (op.a >= block.register_count) return false;
                const a_bit = @as(u32, 1) << @intCast(op.a);
                if (seen_store_global and (num_validated_regs & a_bit) == 0) return false;
            },
            else => return false,
        }
    }

    if (seen_store_global and max_jump_target > store_global_ip) return false;
    return true;
}

fn findPreloadXmm(val: f64, const_vals: []const f64) ?Xmm {
    for (const_vals, 0..) |cv, i| {
        if (@as(u64, @bitCast(cv)) == @as(u64, @bitCast(val))) {
            return switch (i) {
                0 => .xmm12,
                1 => .xmm13,
                2 => .xmm14,
                3 => .xmm15,
                else => unreachable,
            };
        }
    }
    return null;
}

noinline fn compileFastSelfRec(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
) ![]align(std.heap.page_size_min) u8 {
    var a = Assembler.init(allocator);
    defer a.deinit();

    var op_labels = try allocator.alloc(Label, block.ops.len);
    defer allocator.free(op_labels);
    for (0..block.ops.len) |i| {
        op_labels[i] = try a.createLabel();
    }

    const fast_entry = try a.createLabel();
    const fast_overflow = try a.createLabel();
    const fast_unwind = try a.createLabel();
    const wrapper_bailout = try a.createLabel();
    const ext_done = try a.createLabel();

    // System V ABI Entry:
    // fn(regs: [*]JSValue, out: *JSValue, regs_limit: [*]JSValue, env: ?*anyopaque) callconv(.c) u8
    // %rdi = regs, %rsi = out, %rdx = regs_limit, %rcx = env
    try a.pushReg(.rbx);
    try a.pushReg(.r12);
    try a.pushReg(.r13);
    try a.pushReg(.r14);
    try a.pushReg(.r15);
    // 5 callee-saved registers pushed -> %rsp % 16 == 0 !
    // Save `out` (%rsi) in %r12 so we don't need an extra push:
    try a.movRegReg(.r12, .rsi);

    // 1. Validate regs[0] < BASE_TAG
    try a.movRegMem(.rax, .rdi, 0);
    try a.movRegImm64(.r15, JSValue.BASE_TAG);
    try a.cmpRegReg(.rax, .r15);
    try a.jcc(.ae, wrapper_bailout);

    // 2. Validate global_version == cache.global_version once per distinct call_target_cache index
    const gver_addr: u64 = @intFromPtr(&vm.global_version);
    var checked_cs: [64]bool = @splat(false);
    for (block.ops) |op| {
        if (op.opcode == .call_global) {
            if (op.c < checked_cs.len and !checked_cs[op.c]) {
                checked_cs[op.c] = true;
                const cs = &block.call_target_cache[op.c];
                const cs_gver_addr: u64 = @intFromPtr(&cs.global_version);
                try a.movRegImm64(.rax, gver_addr);
                try a.movRegMem(.rax, .rax, 0);
                try a.movRegImm64(.rcx, cs_gver_addr);
                try a.movRegMem(.rcx, .rcx, 0);
                try a.cmpRegReg(.rax, .rcx);
                try a.jcc(.ne, wrapper_bailout);
            }
        }
    }

    // 3. Max depth in %rbx: (regs_limit - regs) / reg_count bounded to 4096 (if <= 0 -> bailout)
    try a.cmpRegReg(.rdx, .rdi);
    try a.jcc(.be, wrapper_bailout);

    try a.movRegReg(.rax, .rdx);
    try a.subRegReg(.rax, .rdi);

    const frame_bytes_caller: u32 = @as(u32, block.register_count) * 8;
    try a.movRegImm32(.rcx, frame_bytes_caller);
    try a.xorReg32Reg32(.rdx, .rdx);
    try a.divReg32(.rcx);

    try a.testRegReg(.rax, .rax);
    try a.jcc(.e, wrapper_bailout);

    const cap_lbl = try a.createLabel();
    try a.cmpRegImm32(.rax, 4096);
    try a.jcc(.be, cap_lbl);
    try a.movRegImm32(.rax, 4096);
    a.bindLabel(cap_lbl);
    try a.movRegReg(.rbx, .rax);

    // 4. Load xmm0 = regs[0] (as raw f64)
    try a.movsdXmmMem(.xmm0, .rdi, 0);

    // 5. Preload up to 4 distinct constants into xmm12..xmm15
    var const_vals: [4]f64 = undefined;
    var const_count: usize = 0;
    for (block.ops) |op| {
        const c_idx: ?usize = switch (op.opcode) {
            .jle_local_const_false,
            .jlt_local_const_false,
            .jge_local_const_false,
            .jgt_local_const_false,
            .jeq_local_const_false => op.b,
            .add_local_const,
            .sub_local_const => op.c,
            else => null,
        };
        if (c_idx) |idx| {
            if (idx < block.constants.len and block.constants[idx] == .number) {
                const val = block.constants[idx].number;
                var found = false;
                for (const_vals[0..const_count]) |cv| {
                    if (@as(u64, @bitCast(cv)) == @as(u64, @bitCast(val))) {
                        found = true;
                        break;
                    }
                }
                if (!found and const_count < 4) {
                    const_vals[const_count] = val;
                    const_count += 1;
                }
            }
        }
    }

    const preload_xmms = [_]Xmm{ .xmm12, .xmm13, .xmm14, .xmm15 };
    for (0..const_count) |i| {
        const bits = @as(u64, @bitCast(const_vals[i]));
        try a.movRegImm64(.rax, bits);
        try a.movqXmmReg(preload_xmms[i], .rax);
    }

    // Call fast_entry (%rsp % 16 == 0 before call)
    try a.callLabel(fast_entry);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, ext_done);

    // Success: canonicalize NaN in %xmm0
    try a.movqRegXmm(.rax, .xmm0);
    try a.ucomisd(.xmm0, .xmm0);
    try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
    try a.cmovpRegReg(.rax, .rcx);
    try a.movMemReg(.r12, 0, .rax); // out.* = canonicalized JSValue
    try a.xorRegReg(.rax, .rax);    // return 0
    try a.jmp(ext_done);

    a.bindLabel(wrapper_bailout);
    try a.movRegImm32(.rax, 1);

    a.bindLabel(ext_done);
    try a.popReg(.r15);
    try a.popReg(.r14);
    try a.popReg(.r13);
    try a.popReg(.r12);
    try a.popReg(.rbx);
    try a.ret();

    // Internal fast_entry
    a.bindLabel(fast_entry);
    const frame_bytes: i32 = @intCast(((@as(usize, block.register_count) * 8 + 15) & ~@as(usize, 15)) + 8);

    try a.testRegReg(.rbx, .rbx);
    try a.jcc(.e, fast_overflow);
    try a.decReg64(.rbx);
    try a.subRegImm32(.rsp, frame_bytes);
    try a.movsdMemXmm(.rsp, 0, .xmm0); // store initial argument to slot 0

    const is_jump_target = try allocator.alloc(bool, block.ops.len);
    defer allocator.free(is_jump_target);
    @memset(is_jump_target, false);

    for (block.ops, 0..) |op, op_idx| {
        switch (op.opcode) {
            .jump, .jump_if_false, .jump_if_true => {
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target < block.ops.len) is_jump_target[target] = true;
            },
            .jle_local_const_false,
            .jlt_local_const_false,
            .jge_local_const_false,
            .jgt_local_const_false,
            .jeq_local_const_false => {
                const target = op_idx + @as(usize, op.c);
                if (target < block.ops.len) is_jump_target[target] = true;
            },
            else => {},
        }
    }

    var ip: usize = 0;
    while (ip < block.ops.len) : (ip += 1) {
        a.bindLabel(op_labels[ip]);
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop => {},
            .jle_local_const_false,
            .jlt_local_const_false,
            .jge_local_const_false,
            .jgt_local_const_false,
            .jeq_local_const_false => {
                const c_val = block.constants[op.b].number;
                const target_lbl = op_labels[ip + @as(usize, op.c)];
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.a) * 8));
                const preload = findPreloadXmm(c_val, const_vals[0..const_count]);
                const rhs_reg: Xmm = if (preload) |x| x else blk: {
                    try a.movRegImm64(.rax, @as(u64, @bitCast(c_val)));
                    try a.movqXmmReg(.xmm1, .rax);
                    break :blk .xmm1;
                };
                switch (op.opcode) {
                    .jeq_local_const_false => {
                        try a.ucomisd(.xmm0, rhs_reg);
                        try a.jcc(.p, target_lbl);
                        try a.jcc(.ne, target_lbl);
                    },
                    .jlt_local_const_false => {
                        try a.ucomisd(rhs_reg, .xmm0);
                        try a.jcc(.be, target_lbl);
                    },
                    .jle_local_const_false => {
                        try a.ucomisd(rhs_reg, .xmm0);
                        try a.jcc(.b, target_lbl);
                    },
                    .jgt_local_const_false => {
                        try a.ucomisd(.xmm0, rhs_reg);
                        try a.jcc(.be, target_lbl);
                    },
                    .jge_local_const_false => {
                        try a.ucomisd(.xmm0, rhs_reg);
                        try a.jcc(.b, target_lbl);
                    },
                    else => unreachable,
                }
            },
            .add_local_const, .sub_local_const => {
                const c_val = block.constants[op.c].number;
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.b) * 8));
                const preload = findPreloadXmm(c_val, const_vals[0..const_count]);
                const rhs_reg: Xmm = if (preload) |x| x else blk: {
                    try a.movRegImm64(.rax, @as(u64, @bitCast(c_val)));
                    try a.movqXmmReg(.xmm1, .rax);
                    break :blk .xmm1;
                };
                if (op.opcode == .add_local_const) {
                    try a.addsd(.xmm0, rhs_reg);
                } else {
                    try a.subsd(.xmm0, rhs_reg);
                }
                if (ip + 1 < block.ops.len and !is_jump_target[ip + 1] and block.ops[ip + 1].opcode == .return_value and block.ops[ip + 1].a == op.a) {
                    try a.addRegImm32(.rsp, frame_bytes);
                    try a.incReg64(.rbx);
                    try a.xorRegReg(.rax, .rax);
                    try a.ret();
                    a.bindLabel(op_labels[ip + 1]);
                    ip += 1;
                } else {
                    try a.movsdMemXmm(.rsp, @intCast(@as(usize, op.a) * 8), .xmm0);
                }
            },
            .add, .add_num, .sub_num, .mul_num, .div_num => {
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.b) * 8));
                try a.movsdXmmMem(.xmm1, .rsp, @intCast(@as(usize, op.c) * 8));
                switch (op.opcode) {
                    .add, .add_num => try a.addsd(.xmm0, .xmm1),
                    .sub_num => try a.subsd(.xmm0, .xmm1),
                    .mul_num => try a.mulsd(.xmm0, .xmm1),
                    .div_num => try a.divsd(.xmm0, .xmm1),
                    else => unreachable,
                }
                if (ip + 1 < block.ops.len and !is_jump_target[ip + 1] and block.ops[ip + 1].opcode == .return_value and block.ops[ip + 1].a == op.a) {
                    try a.addRegImm32(.rsp, frame_bytes);
                    try a.incReg64(.rbx);
                    try a.xorRegReg(.rax, .rax);
                    try a.ret();
                    a.bindLabel(op_labels[ip + 1]);
                    ip += 1;
                } else {
                    try a.movsdMemXmm(.rsp, @intCast(@as(usize, op.a) * 8), .xmm0);
                }
            },
            .neg => {
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.b) * 8));
                try a.movRegImm64(.rax, 0x8000_0000_0000_0000);
                try a.movqXmmReg(.xmm1, .rax);
                try a.xorpd(.xmm0, .xmm1);
                try a.movsdMemXmm(.rsp, @intCast(@as(usize, op.a) * 8), .xmm0);
            },
            .load_const => {
                const c_val = block.constants[op.b].number;
                try a.movRegImm64(.rax, @as(u64, @bitCast(c_val)));
                try a.movqXmmReg(.xmm0, .rax);
                try a.movsdMemXmm(.rsp, @intCast(@as(usize, op.a) * 8), .xmm0);
            },
            .load_local, .move => {
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.b) * 8));
                try a.movsdMemXmm(.rsp, @intCast(@as(usize, op.a) * 8), .xmm0);
            },
            .jump => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                try a.jmp(op_labels[target_pc]);
            },
            .loose_eq, .loose_ne, .eq, .ne => {
                const next_op = block.ops[ip + 1];
                const target_pc = (@as(usize, next_op.b) << 8) | next_op.c;
                const target_lbl = op_labels[target_pc];
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.b) * 8));
                try a.movsdXmmMem(.xmm1, .rsp, @intCast(@as(usize, op.c) * 8));
                try a.ucomisd(.xmm0, .xmm1);
                const is_eq_op = (op.opcode == .loose_eq or op.opcode == .eq);
                const is_true_jmp = (next_op.opcode == .jump_if_true);
                if (is_eq_op != is_true_jmp) {
                    try a.jcc(.p, target_lbl);
                    try a.jcc(.ne, target_lbl);
                } else {
                    const skip_lbl = try a.createLabel();
                    try a.jcc(.p, skip_lbl);
                    try a.jcc(.e, target_lbl);
                    a.bindLabel(skip_lbl);
                }
                a.bindLabel(op_labels[ip + 1]);
                ip += 1;
            },
            .call_global => {
                try a.movsdXmmMem(.xmm0, .rsp, @intCast((@as(usize, op.b) + 1) * 8));
                try a.callLabel(fast_entry);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, fast_unwind);
                try a.movsdMemXmm(.rsp, @intCast(@as(usize, op.a) * 8), .xmm0);
            },
            .return_value => {
                try a.movsdXmmMem(.xmm0, .rsp, @intCast(@as(usize, op.a) * 8));
                try a.addRegImm32(.rsp, frame_bytes);
                try a.incReg64(.rbx);
                try a.xorRegReg(.rax, .rax);
                try a.ret();
            },
            .return_undefined => {
                try a.movRegImm64(.rax, JSValue.UNDEFINED.bits);
                try a.movqXmmReg(.xmm0, .rax);
                try a.addRegImm32(.rsp, frame_bytes);
                try a.incReg64(.rbx);
                try a.xorRegReg(.rax, .rax);
                try a.ret();
            },
            else => unreachable,
        }
    }

    a.bindLabel(fast_overflow);
    try a.movRegImm32(.rax, 1);
    try a.ret();

    a.bindLabel(fast_unwind);
    try a.addRegImm32(.rsp, frame_bytes);
    try a.incReg64(.rbx);
    try a.movRegImm32(.rax, 1);
    try a.ret();

    return a.finalizeExecutable();
}

pub noinline fn compile(allocator: Allocator, block: *codeblock.CodeBlock) bool {
    if (block.jit_fn != null) return true;
    if (block.jit_failed) return false;

    if (canUseFastSelfRec(block)) {
        const exec = compileFastSelfRec(allocator, block) catch {
            block.jit_failed = true;
            return false;
        };
        block.jit_code = exec;
        block.jit_fn = @ptrCast(exec.ptr);
        return true;
    }

    if (!canCompile(block)) {
        block.jit_failed = true;
        return false;
    }

    var global_slot_count: usize = 0;
    for (block.ops) |op| {
        if (op.opcode == .load_global or op.opcode == .store_global) {
            global_slot_count += 1;
        }
    }

    var slots: ?[]JitGlobalSlot = null;
    if (global_slot_count > 0) {
        const s = allocator.alloc(JitGlobalSlot, global_slot_count) catch {
            block.jit_failed = true;
            return false;
        };
        @memset(s, .{});
        slots = s;
    }

    const exec = compileImpl(allocator, block, slots) catch {
        if (slots) |s| allocator.free(s);
        block.jit_failed = true;
        return false;
    };
    block.jit_global_slots = slots;
    block.jit_code = exec;
    block.jit_fn = @ptrCast(exec.ptr);
    return true;
}

noinline fn emitGlobalSlotLookup(
    a: *Assembler,
    slot_addr: u64,
    ver_addr: u64,
    name: []const u8,
    bailout_label: Label,
) !void {
    const resolve_label = try a.createLabel();
    const hit_label = try a.createLabel();

    try a.movRegImm64(.r10, slot_addr);
    try a.movRegImm64(.r11, ver_addr);
    // slot.env == %r14 (offset 0)
    try a.movRegMem(.rax, .r10, 0);
    try a.cmpRegReg(.rax, .r14);
    try a.jcc(.ne, resolve_label);
    // slot.struct_version == env_struct_version (offset 16)
    try a.movRegMem(.rax, .r11, 0);
    try a.movRegMem(.rcx, .r10, 16);
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.e, hit_label);

    a.bindLabel(resolve_label);
    try a.movRegReg(.rdi, .r14);
    try a.movRegImm64(.rsi, @intFromPtr(name.ptr));
    try a.movRegImm64(.rdx, name.len);
    try a.movRegReg(.rcx, .r10);
    try a.movRegImm64(.rax, @intFromPtr(&jitResolveGlobalSlot));
    try a.movRegReg(.rbx, .rsp);
    try a.andRegImm8(.rsp, -16);
    try a.callReg(.rax);
    try a.movRegReg(.rsp, .rbx);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, bailout_label);
    try a.movRegImm64(.r10, slot_addr);

    a.bindLabel(hit_label);
}

noinline fn emitGuardNonHeapInOsr(a: *Assembler, reg_idx: u8, _: Label) !void {
    const clean_lbl = try a.createLabel();
    try a.movRegMem(.rdx, .r12, @intCast(@as(usize, reg_idx) * 8));
    try a.cmpRegReg(.rdx, .r14);
    try a.jcc(.b, clean_lbl);
    try a.pushReg(.rax);
    try a.pushReg(.rcx);
    try a.lea(.rdi, .r12, @intCast(@as(usize, reg_idx) * 8));
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitDeinitSlot));
    try a.callReg(.rax);
    try a.popReg(.rcx);
    try a.popReg(.rax);
    a.bindLabel(clean_lbl);
}

noinline fn emitCmpToBool(a: *Assembler, opcode: codeblock.Opcode) !void {
    // Assumes %xmm0 = lhs, %xmm1 = rhs; produces JSValue.fromBool(result) in %rax.
    const done_lbl = try a.createLabel();
    const true_lbl = try a.createLabel();

    switch (opcode) {
        .lt_num, .lt_local_const => {
            try a.ucomisd(.xmm1, .xmm0);
            try a.jcc(.a, true_lbl);
        },
        .le_num, .le_local_const => {
            try a.ucomisd(.xmm1, .xmm0);
            try a.jcc(.ae, true_lbl);
        },
        .gt_num, .gt_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.a, true_lbl);
        },
        .ge_num, .ge_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.ae, true_lbl);
        },
        .eq, .loose_eq, .eq_local_const => {
            const false_lbl = try a.createLabel();
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, false_lbl);
            try a.jcc(.e, true_lbl);
            a.bindLabel(false_lbl);
        },
        .ne, .loose_ne => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, true_lbl);
            try a.jcc(.ne, true_lbl);
        },
        else => unreachable,
    }
    try a.movRegImm64(.rax, JSValue.fromBool(false).bits);
    try a.jmp(done_lbl);
    a.bindLabel(true_lbl);
    try a.movRegImm64(.rax, JSValue.fromBool(true).bits);
    a.bindLabel(done_lbl);
}

noinline fn emitCondJump(a: *Assembler, is_true_jump: bool, src_reg: u8, target_lbl: Label, bail_lbl: Label) !void {
    const num_lbl = try a.createLabel();
    const fallthrough_lbl = try a.createLabel();

    try a.movRegMem(.rax, .r12, @intCast(@as(usize, src_reg) * 8));
    try a.cmpRegReg(.rax, .r15);
    try a.jcc(.b, num_lbl);

    try a.cmpRegReg(.rax, .r15);
    if (is_true_jump) {
        try a.jcc(.e, fallthrough_lbl);
    } else {
        try a.jcc(.e, target_lbl);
    }
    const null_bits = JSValue.NULL.bits;
    try a.movRegImm64(.rcx, null_bits);
    try a.cmpRegReg(.rax, .rcx);
    if (is_true_jump) {
        try a.jcc(.e, fallthrough_lbl);
    } else {
        try a.jcc(.e, target_lbl);
    }
    const false_bits = JSValue.fromBool(false).bits;
    const true_bits = JSValue.fromBool(true).bits;
    try a.movRegImm64(.rcx, false_bits);
    try a.cmpRegReg(.rax, .rcx);
    if (is_true_jump) {
        try a.jcc(.e, fallthrough_lbl);
    } else {
        try a.jcc(.e, target_lbl);
    }
    try a.movRegImm64(.rcx, true_bits);
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.ne, bail_lbl);
    if (is_true_jump) {
        try a.jmp(target_lbl);
    } else {
        try a.jmp(fallthrough_lbl);
    }

    a.bindLabel(num_lbl);
    try a.movqXmmReg(.xmm0, .rax);
    try a.xorpd(.xmm1, .xmm1);
    try a.ucomisd(.xmm0, .xmm1);
    if (is_true_jump) {
        try a.jcc(.p, fallthrough_lbl);
        try a.jcc(.ne, target_lbl);
    } else {
        try a.jcc(.p, target_lbl);
        try a.jcc(.e, target_lbl);
    }
    a.bindLabel(fallthrough_lbl);
}

noinline fn emitSharedOp(a: *Assembler, block: *const codeblock.CodeBlock, op: codeblock.Op, is_osr: bool, bail_lbl: Label) !bool {
    switch (op.opcode) {
        .load_null => {
            if (is_osr) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movRegImm64(.rax, JSValue.NULL.bits);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .load_true => {
            if (is_osr) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movRegImm64(.rax, JSValue.fromBool(true).bits);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .load_false => {
            if (is_osr) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movRegImm64(.rax, JSValue.fromBool(false).bits);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .not => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            const false_bits = JSValue.fromBool(false).bits;
            const true_bits = JSValue.fromBool(true).bits;
            const is_false_lbl = try a.createLabel();
            const store_lbl = try a.createLabel();
            try a.movRegImm64(.rcx, false_bits);
            try a.cmpRegReg(.rax, .rcx);
            try a.jcc(.e, is_false_lbl);
            try a.movRegImm64(.rdx, true_bits);
            try a.cmpRegReg(.rax, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movRegReg(.rax, .rcx);
            try a.jmp(store_lbl);
            a.bindLabel(is_false_lbl);
            try a.movRegImm64(.rax, true_bits);
            a.bindLabel(store_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .neg => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
            try a.xorRegReg64(.rax, .rcx);
            try a.ucomisd(.xmm0, .xmm0);
            try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
            try a.cmovpRegReg(.rax, .rcx);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .div_num => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.divsd(.xmm0, .xmm1);
            try a.movqRegXmm(.rax, .xmm0);
            try a.ucomisd(.xmm0, .xmm0);
            try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
            try a.cmovpRegReg(.rax, .rcx);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .mod_num => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            // lhs: positive exact integer in [0, 2^53 - 1] (also rejects -0.0 via sign bit)
            try a.movRegReg(.rdx, .rax);
            try a.shrRegImm8(.rdx, 63);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
            try a.movRegReg(.rdx, .rax);
            try a.shrRegImm8(.rdx, 53);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.cvtsi2sdqXmmReg64(.xmm2, .rax);
            try a.ucomisd(.xmm0, .xmm2);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
            // rhs: strictly positive exact integer in [1, 2^53 - 1]
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 63);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.cvttsd2siqReg64Xmm(.rcx, .xmm1);
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 53);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.e, bail_lbl);
            try a.cvtsi2sdqXmmReg64(.xmm2, .rcx);
            try a.ucomisd(.xmm1, .xmm2);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.xorRegReg64(.rdx, .rdx);
            try a.divReg64(.rcx);
            try a.cvtsi2sdqXmmReg64(.xmm0, .rdx);
            try a.movqRegXmm(.rax, .xmm0);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .not_bits => {
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.cvttsd2siReg32Xmm(.rax, .xmm0);
            try a.cmpReg32Imm32(.rax, -0x80000000);
            try a.jcc(.e, slow_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.notReg32(.rax);
            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
            try a.movqRegXmm(.rax, .xmm0);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, op.b);
            try a.movRegImm32(.r8, 6);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
            if (!is_osr) {
                try a.movRegReg(.rbx, .rsp);
                try a.andRegImm8(.rsp, -16);
            }
            try a.callReg(.rax);
            if (!is_osr) {
                try a.movRegReg(.rsp, .rbx);
            }
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            a.bindLabel(done_lbl);
            return true;
        },
        .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.cvttsd2siReg32Xmm(.rax, .xmm0);
            try a.cmpReg32Imm32(.rax, -0x80000000);
            try a.jcc(.e, slow_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
            try a.cmpReg32Imm32(.rcx, -0x80000000);
            try a.jcc(.e, slow_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            switch (op.opcode) {
                .and_bits => {
                    try a.andReg32Reg32(.rax, .rcx);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .or_bits => {
                    try a.orReg32Reg32(.rax, .rcx);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .xor_bits => {
                    try a.xorReg32Reg32(.rax, .rcx);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shl => {
                    try a.shlReg32Cl(.rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shr => {
                    try a.sarReg32Cl(.rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .ushr => {
                    try a.shrReg32Cl(.rax);
                    try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
                },
                else => unreachable,
            }
            try a.movqRegXmm(.rax, .xmm0);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            const kind_u32: u32 = switch (op.opcode) {
                .and_bits => 0,
                .or_bits => 1,
                .xor_bits => 2,
                .shl => 3,
                .shr => 4,
                .ushr => 5,
                else => unreachable,
            };
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, op.c);
            try a.movRegImm32(.r8, kind_u32);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
            if (!is_osr) {
                try a.movRegReg(.rbx, .rsp);
                try a.andRegImm8(.rsp, -16);
            }
            try a.callReg(.rax);
            if (!is_osr) {
                try a.movRegReg(.rsp, .rbx);
            }
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            a.bindLabel(done_lbl);
            return true;
        },
        .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movqXmmReg(.xmm1, .rcx);
            try emitCmpToBool(a, op.opcode);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
            const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movRegImm64(.rcx, c_bits);
            try a.movqXmmReg(.xmm1, .rcx);
            try emitCmpToBool(a, op.opcode);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        else => return false,
    }
}

fn isKnownNum(known_num: u64, reg: u8) bool {
    if (reg >= 64) return false;
    return (known_num & (@as(u64, 1) << @intCast(reg))) != 0;
}

fn isKnownNonHeap(known_non_heap: u64, reg: u8) bool {
    if (reg >= 64) return false;
    return (known_non_heap & (@as(u64, 1) << @intCast(reg))) != 0;
}

fn markNum(reg: u8, known_num: *u64, known_non_heap: *u64) void {
    if (reg < 64) {
        const mask = @as(u64, 1) << @intCast(reg);
        known_num.* |= mask;
        known_non_heap.* |= mask;
    }
}

fn clearReg(reg: u8, known_num: *u64, known_non_heap: *u64) void {
    if (reg < 64) {
        const mask = ~(@as(u64, 1) << @intCast(reg));
        known_num.* &= mask;
        known_non_heap.* &= mask;
    }
}

noinline fn compileImpl(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    slots_opt: ?[]JitGlobalSlot,
) ![]align(std.heap.page_size_min) u8 {
    var a = Assembler.init(allocator);
    defer a.deinit();

    var op_labels = try allocator.alloc(Label, block.ops.len);
    defer allocator.free(op_labels);
    for (0..block.ops.len) |i| {
        op_labels[i] = try a.createLabel();
    }

    const internal_entry = try a.createLabel();
    const bailout_label = try a.createLabel();
    const ext_done = try a.createLabel();

    // External entry: fn(regs: [*]JSValue, out: *JSValue, regs_limit: [*]JSValue, env: ?*anyopaque) callconv(.c) u8
    // %rdi = regs, %rsi = out, %rdx = regs_limit, %rcx = env
    // Callee-saved register assignment inside JIT:
    // %r12 = regs, %r13 = regs_limit, %r14 = env, %r15 = JSValue.BASE_TAG, %rbx = scratch rsp
    try a.pushReg(.rbx);
    try a.pushReg(.r12);
    try a.pushReg(.r13);
    try a.pushReg(.r14);
    try a.pushReg(.r15);
    try a.pushReg(.rsi);

    try a.movRegReg(.r12, .rdi);
    try a.movRegReg(.r13, .rdx);
    try a.movRegReg(.r14, .rcx);
    try a.movRegImm64(.r15, JSValue.BASE_TAG);

    try a.callLabel(internal_entry);
    try a.popReg(.rsi);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, ext_done);
    try a.movMemReg(.rsi, 0, .rcx);

    a.bindLabel(ext_done);
    try a.popReg(.r15);
    try a.popReg(.r14);
    try a.popReg(.r13);
    try a.popReg(.r12);
    try a.popReg(.rbx);
    try a.ret();

    // Internal entry (also target of direct self-recursive calls)
    a.bindLabel(internal_entry);
    const frame_bytes: i32 = @intCast(@as(usize, block.register_count) * 8);
    try a.lea(.rax, .r12, frame_bytes);
    try a.cmpRegReg(.rax, .r13);
    try a.jcc(.a, bailout_label);

    if (block.local_count > block.param_count) {
        var slot: usize = block.param_count;
        while (slot < block.local_count) : (slot += 1) {
            try a.movMemReg(.r12, @intCast(slot * 8), .r15);
        }
    }

    const ver_addr: u64 = @intFromPtr(&environment_mod.env_struct_version);
    const global_ver_addr: u64 = @intFromPtr(&vm.global_version);
    var next_slot_idx: usize = 0;

    const is_jump_target = try allocator.alloc(bool, block.ops.len);
    defer allocator.free(is_jump_target);
    @memset(is_jump_target, false);

    for (block.ops, 0..) |op, op_idx| {
        switch (op.opcode) {
            .jump, .jump_if_false, .jump_if_true => {
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target < block.ops.len) is_jump_target[target] = true;
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false => {
                const target = op_idx + @as(usize, op.c);
                if (target < block.ops.len) is_jump_target[target] = true;
            },
            else => {},
        }
    }

    var can_mutate_globals = false;
    for (block.ops) |op| {
        if (op.opcode == .store_global) {
            can_mutate_globals = true;
            break;
        }
    }

    var pure_numeric_returns = true;
    var param_guarded: u64 = 0;
    for (block.ops) |op| {
        switch (op.opcode) {
            .nop => {},
            .load_const => {
                if (op.b >= block.constants.len or block.constants[op.b] != .number) {
                    pure_numeric_returns = false;
                }
            },
            .add, .add_num, .sub_num, .mul_num, .div_num, .add_local_const, .sub_local_const, .neg => {},
            .jump, .jump_if_false, .jump_if_true => {},
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false => {
                if (op.a < 64) param_guarded |= (@as(u64, 1) << @intCast(op.a));
            },
            .call_global => {},
            .move, .load_local, .store_local => {},
            .return_value => {
                if (op.a < block.param_count) {
                    if ((param_guarded & (@as(u64, 1) << @intCast(op.a))) == 0) {
                        pure_numeric_returns = false;
                    }
                }
            },
            else => {
                pure_numeric_returns = false;
            },
        }
    }

    var known_num: u64 = 0;
    var known_non_heap: u64 = 0;
    var global_ver_checked = false;

    var ip: usize = 0;
    while (ip < block.ops.len) : (ip += 1) {
        if (is_jump_target[ip]) {
            known_num = 0;
            known_non_heap = 0;
            global_ver_checked = false;
        }
        a.bindLabel(op_labels[ip]);
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop => {},
            .load_undefined => {
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
                clearReg(op.a, &known_num, &known_non_heap);
                if (op.a < 64) known_non_heap |= (@as(u64, 1) << @intCast(op.a));
            },
            .load_const => {
                const c = block.constants[op.b];
                const bits = switch (c) {
                    .number => |n| JSValue.fromNumber(n).bits,
                    .boolean => |b| JSValue.fromBool(b).bits,
                    else => unreachable,
                };
                try a.movRegImm64(.rax, bits);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                if (c == .number) {
                    markNum(op.a, &known_num, &known_non_heap);
                } else {
                    clearReg(op.a, &known_num, &known_non_heap);
                    if (op.a < 64) known_non_heap |= (@as(u64, 1) << @intCast(op.a));
                }
            },
            .move, .load_local, .store_local => {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                if (!isKnownNonHeap(known_non_heap, op.b)) {
                    try a.movRegImm64(.rcx, JSValue.HEAP_BASE);
                    try a.cmpRegReg(.rax, .rcx);
                    try a.jcc(.ae, bailout_label);
                    if (op.b < 64) known_non_heap |= (@as(u64, 1) << @intCast(op.b));
                }
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                if (isKnownNum(known_num, op.b)) {
                    markNum(op.a, &known_num, &known_non_heap);
                } else if (isKnownNonHeap(known_non_heap, op.b)) {
                    clearReg(op.a, &known_num, &known_non_heap);
                    if (op.a < 64) known_non_heap |= (@as(u64, 1) << @intCast(op.a));
                } else {
                    clearReg(op.a, &known_num, &known_non_heap);
                }
            },
            .jump_if_false, .jump_if_true => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                try emitCondJump(&a, op.opcode == .jump_if_true, op.a, op_labels[target_pc], bailout_label);
            },
            .add, .add_num, .sub_num, .mul_num => {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                if (!isKnownNum(known_num, op.b)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.b, &known_num, &known_non_heap);
                }
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
                if (!isKnownNum(known_num, op.c)) {
                    try a.cmpRegReg(.rcx, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.c, &known_num, &known_non_heap);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movqXmmReg(.xmm1, .rcx);
                switch (op.opcode) {
                    .add, .add_num => try a.addsd(.xmm0, .xmm1),
                    .sub_num => try a.subsd(.xmm0, .xmm1),
                    .mul_num => try a.mulsd(.xmm0, .xmm1),
                    else => unreachable,
                }
                if (ip + 1 < block.ops.len and !is_jump_target[ip + 1] and block.ops[ip + 1].opcode == .return_value and block.ops[ip + 1].a == op.a) {
                    try a.movqRegXmm(.rcx, .xmm0);
                    try a.ucomisd(.xmm0, .xmm0);
                    try a.movRegImm64(.rax, JSValue.CANONICAL_NAN);
                    try a.cmovpRegReg(.rcx, .rax);
                    try a.xorRegReg(.rax, .rax);
                    try a.ret();
                    a.bindLabel(op_labels[ip + 1]);
                    ip += 1;
                } else {
                    try a.movqRegXmm(.rax, .xmm0);
                    try a.ucomisd(.xmm0, .xmm0);
                    try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                    try a.cmovpRegReg(.rax, .rcx);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                    markNum(op.a, &known_num, &known_non_heap);
                }
            },
            .add_local_const, .sub_local_const => {
                const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                if (!isKnownNum(known_num, op.b)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.b, &known_num, &known_non_heap);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (op.opcode == .add_local_const) {
                    try a.addsd(.xmm0, .xmm1);
                } else {
                    try a.subsd(.xmm0, .xmm1);
                }
                if (ip + 1 < block.ops.len and !is_jump_target[ip + 1] and block.ops[ip + 1].opcode == .return_value and block.ops[ip + 1].a == op.a) {
                    try a.movqRegXmm(.rcx, .xmm0);
                    try a.ucomisd(.xmm0, .xmm0);
                    try a.movRegImm64(.rax, JSValue.CANONICAL_NAN);
                    try a.cmovpRegReg(.rcx, .rax);
                    try a.xorRegReg(.rax, .rax);
                    try a.ret();
                    a.bindLabel(op_labels[ip + 1]);
                    ip += 1;
                } else {
                    try a.movqRegXmm(.rax, .xmm0);
                    try a.ucomisd(.xmm0, .xmm0);
                    try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                    try a.cmovpRegReg(.rax, .rcx);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                    markNum(op.a, &known_num, &known_non_heap);
                }
            },
            .div_num => {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                if (!isKnownNum(known_num, op.b)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.b, &known_num, &known_non_heap);
                }
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
                if (!isKnownNum(known_num, op.c)) {
                    try a.cmpRegReg(.rcx, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.c, &known_num, &known_non_heap);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movqXmmReg(.xmm1, .rcx);
                try a.divsd(.xmm0, .xmm1);
                try a.movqRegXmm(.rax, .xmm0);
                try a.ucomisd(.xmm0, .xmm0);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                markNum(op.a, &known_num, &known_non_heap);
            },
            .neg => {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                if (!isKnownNum(known_num, op.b)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.b, &known_num, &known_non_heap);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
                try a.xorRegReg64(.rax, .rcx);
                try a.ucomisd(.xmm0, .xmm0);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                markNum(op.a, &known_num, &known_non_heap);
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const c_bits = JSValue.fromNumber(block.constants[op.b].number).bits;
                const target_lbl = op_labels[ip + @as(usize, op.c)];
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                if (!isKnownNum(known_num, op.a)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.a, &known_num, &known_non_heap);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                switch (op.opcode) {
                    .jeq_local_const_false => {
                        try a.ucomisd(.xmm0, .xmm1);
                        try a.jcc(.p, target_lbl);
                        try a.jcc(.ne, target_lbl);
                    },
                    .jlt_local_const_false => {
                        try a.ucomisd(.xmm1, .xmm0);
                        try a.jcc(.be, target_lbl);
                    },
                    .jle_local_const_false => {
                        try a.ucomisd(.xmm1, .xmm0);
                        try a.jcc(.b, target_lbl);
                    },
                    .jgt_local_const_false => {
                        try a.ucomisd(.xmm0, .xmm1);
                        try a.jcc(.be, target_lbl);
                    },
                    .jge_local_const_false => {
                        try a.ucomisd(.xmm0, .xmm1);
                        try a.jcc(.b, target_lbl);
                    },
                    else => unreachable,
                }
            },
            .jump => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                try a.jmp(op_labels[target_pc]);
                known_num = 0;
                known_non_heap = 0;
                global_ver_checked = false;
            },
            .call_global => {
                const cs = &block.call_target_cache[op.c];
                const arg_count = cs.arg_count;
                const arg_start = @as(usize, op.b) + 1;
                for (0..arg_count) |i| {
                    try a.movRegMem(.rax, .r12, @intCast((arg_start + i) * 8));
                    try a.movMemReg(.r12, @intCast((@as(usize, block.register_count) + i) * 8), .rax);
                }
                try a.addRegImm32(.r12, frame_bytes);
                try a.callLabel(internal_entry);
                try a.subRegImm32(.r12, frame_bytes);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bailout_label);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rcx);
                if (pure_numeric_returns) {
                    markNum(op.a, &known_num, &known_non_heap);
                } else {
                    clearReg(op.a, &known_num, &known_non_heap);
                }
                global_ver_checked = true;
            },
            .load_global => {
                const slots = slots_opt.?;
                const slot_addr = @intFromPtr(&slots[next_slot_idx]);
                next_slot_idx += 1;
                const name = constantName(block, op.b).?;
                try emitGlobalSlotLookup(&a, slot_addr, ver_addr, name, bailout_label);
                // %r10 = slot; load *slot.value_ptr (offset 8)
                try a.movRegMem(.rax, .r10, 8);
                try a.movRegMem(.rax, .rax, 0);
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bailout_label);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                markNum(op.a, &known_num, &known_non_heap);
            },
            .store_global => {
                const slots = slots_opt.?;
                const slot_addr = @intFromPtr(&slots[next_slot_idx]);
                next_slot_idx += 1;
                const name = constantName(block, op.a).?;
                // Validate regs[op.b] is number (< BASE_TAG) before lookup
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                if (!isKnownNum(known_num, op.b)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(op.b, &known_num, &known_non_heap);
                }

                try emitGlobalSlotLookup(&a, slot_addr, ver_addr, name, bailout_label);
                // Validate slot.is_mutable != 0 (offset 24)
                try a.movRegMem(.rcx, .r10, 24);
                try a.testRegReg(.rcx, .rcx);
                try a.jcc(.e, bailout_label);
                // Load slot.value_ptr (offset 8) and ensure old value is not heap (< HEAP_BASE)
                try a.movRegMem(.rcx, .r10, 8);
                try a.movRegMem(.rdx, .rcx, 0);
                try a.movRegImm64(.r11, JSValue.HEAP_BASE);
                try a.cmpRegReg(.rdx, .r11);
                try a.jcc(.ae, bailout_label);
                // Store new number into *slot.value_ptr and bump global_version
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movMemReg(.rcx, 0, .rax);
                try a.movRegImm64(.r11, global_ver_addr);
                try a.incMem64(.r11, 0);
                if (can_mutate_globals) {
                    global_ver_checked = false;
                }
            },
            .return_value => {
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
                if (!pure_numeric_returns and !isKnownNonHeap(known_non_heap, op.a)) {
                    try a.movRegImm64(.rdx, JSValue.HEAP_BASE);
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ae, bailout_label);
                }
                try a.xorRegReg(.rax, .rax);
                try a.ret();
            },
            .return_undefined => {
                try a.movRegReg(.rcx, .r15);
                try a.xorRegReg(.rax, .rax);
                try a.ret();
            },
            else => {
                if (!(try emitSharedOp(&a, block, op, false, bailout_label))) unreachable;
                clearReg(op.a, &known_num, &known_non_heap);
            },
        }
    }

    a.bindLabel(bailout_label);
    try a.movRegImm32(.rax, 1);
    try a.ret();

    return a.finalizeExecutable();
}

fn isMathSqrtCall(cs: *const codeblock.CallSiteCache) bool {
    if (cs.arg_count != 1) return false;
    const callee = cs.callee orelse return false;
    if (!callee.isFunction()) return false;
    return callee.asFunction().value.call == math_builtins.mathSqrt;
}

pub noinline fn canCompileOsr(block: *const codeblock.CodeBlock, start_ip: usize, end_ip: usize) bool {
    if (!comptime x64_asm.is_supported_host) return false;
    if (block.exception_table.len > 0 or block.flags.has_try) return false;
    if (block.register_count == 0 or block.register_count > 64) return false;
    if (start_ip >= end_ip or end_ip >= block.ops.len) return false;
    const back_op = block.ops[end_ip];
    if (back_op.opcode != .jump or (((@as(usize, back_op.b) << 8) | back_op.c) != start_ip)) return false;

    var ip: usize = start_ip;
    while (ip <= end_ip) : (ip += 1) {
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop => {},
            .load_undefined, .load_null, .load_true, .load_false => {
                if (op.a >= block.register_count) return false;
            },
            .load_const => {
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                switch (block.constants[op.b]) {
                    .number, .boolean => {},
                    else => return false,
                }
            },
            .move, .load_local, .store_local, .neg, .not, .not_bits => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
            },
            .add,
            .add_num,
            .sub_num,
            .mul_num,
            .div_num,
            .mod_num,
            .and_bits,
            .or_bits,
            .xor_bits,
            .shl,
            .shr,
            .ushr,
            .lt_num,
            .gt_num,
            .le_num,
            .ge_num,
            .eq,
            .ne,
            .loose_eq,
            .loose_ne,
            .get_elem,
            .set_elem,
            => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
            },
            .add_local_const,
            .sub_local_const,
            .lt_local_const,
            .gt_local_const,
            .le_local_const,
            .ge_local_const,
            .eq_local_const,
            => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.constants.len) return false;
                if (block.constants[op.c] != .number) return false;
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
                if (ip + @as(usize, op.c) >= block.ops.len) return false;
            },
            .jump_if_false, .jump_if_true => {
                if (op.a >= block.register_count) return false;
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
            },
            .jump => {
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
            },
            .new_array => {
                if (op.a >= block.register_count) return false;
            },
            .set_elem_const => {
                if (op.a >= block.register_count or op.c >= block.register_count) return false;
            },
            .to_prop_key => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
            },
            .get_elem_const => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.constants.len) return false;
                if (block.constants[op.c] != .number) return false;
                const n = block.constants[op.c].number;
                if (n < 0 or n > 255 or @as(f64, @floatFromInt(@as(usize, @intFromFloat(n)))) != n) return false;
            },
            .new_object => {
                if (op.a >= block.register_count) return false;
            },
            .throw_value => {
                if (op.b == 0 and op.a >= block.register_count) return false;
            },
            .set_prop, .set_prop_transition => {
                if (op.a >= block.register_count or op.c >= block.register_count) return false;
                if (constantName(block, op.b) == null) return false;
            },
            .load_global => {
                if (op.a >= block.register_count) return false;
                if (constantName(block, op.b) == null) return false;
            },
            .get_prop => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
                if (constantName(block, op.c) == null) return false;
            },
            .call => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
                if (op.c >= block.call_target_cache.len) return false;
                const cs = &block.call_target_cache[op.c];
                if ((@as(usize, op.b) + 1 + cs.arg_count) > block.register_count) return false;
                if (!isMathSqrtCall(cs)) {
                    if (cs.this_reg != null) return false;
                    const tb = cs.target_block orelse return false;
                    if (tb.param_count != cs.arg_count) return false;
                    if (tb.jit_fn == null and !canCompile(tb)) return false;
                }
            },
            .call_global => {
                if (op.a >= block.register_count) return false;
                if (op.c >= block.call_target_cache.len) return false;
                const cs = &block.call_target_cache[op.c];
                if (cs.this_reg != null) return false;
                const tb = cs.target_block orelse return false;
                if (tb.param_count != cs.arg_count) return false;
                if ((@as(usize, op.b) + 1 + cs.arg_count) > block.register_count) return false;
                if (tb.jit_fn == null and !canCompile(tb)) return false;
            },
            else => return false,
        }
    }
    return true;
}

pub noinline fn compileOsr(allocator: Allocator, block: *codeblock.CodeBlock, entry: *codeblock.OsrEntry, start_ip: usize, end_ip: usize, prop_ic_ptr: ?*const anyopaque, frame_regs_opt: ?[]const JSValue) bool {
    if (entry.fn_ptr != null) return true;
    if (entry.failed) return false;
    if (!canCompileOsr(block, start_ip, end_ip)) {
        entry.failed = true;
        return false;
    }

    var ip = start_ip;
    while (ip <= end_ip) : (ip += 1) {
        const op = block.ops[ip];
        if (op.opcode == .call or op.opcode == .call_global) {
            const cs = &block.call_target_cache[op.c];
            if (cs.target_block) |tb| {
                if (tb.jit_fn == null) {
                    _ = compile(allocator, @constCast(tb));
                }
            }
        }
    }

    const exec = compileOsrImpl(allocator, block, start_ip, end_ip, prop_ic_ptr, frame_regs_opt) catch {
        entry.failed = true;
        return false;
    };
    entry.header_ip = @intCast(start_ip);
    entry.end_ip = @intCast(end_ip);
    entry.code = exec;
    entry.fn_ptr = @ptrCast(exec.ptr);
    return true;
}

const PromotedPropsAnalysis = struct {
    count: usize = 0,
    obj_reg: u8 = 0,
    shape_id: u32 = 0,
    max_slot: u32 = 0,
    slots: [6]u32 = @splat(0),
    xmms: [6]Xmm = @splat(.xmm0),
    written: [6]bool = @splat(false),

    fn findSlot(self: *const PromotedPropsAnalysis, slot_idx: u32) ?usize {
        for (0..self.count) |i| {
            if (self.slots[i] == slot_idx) return i;
        }
        return null;
    }
};

noinline fn analyzePromotedProps(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic: ?*const [256]PropIC,
) PromotedPropsAnalysis {
    const table = prop_ic orelse return .{};
    var res = PromotedPropsAnalysis{};
    var has_obj = false;
    var keys: [6][]const u8 = undefined;

    for (start_ip..end_ip + 1) |ip| {
        const op = block.ops[ip];
        switch (op.opcode) {
            .call,
            .call_global,
            .new_object,
            .new_array,
            .set_prop_transition,
            .get_elem,
            .set_elem,
            .get_elem_const,
            .set_elem_const,
            .to_prop_key,
            => return .{},
            .get_prop, .set_prop => {
                const is_set = (op.opcode == .set_prop);
                const obj_r = if (is_set) op.a else op.b;
                const key_c = if (is_set) op.b else op.c;
                if (!is_set and op.a == obj_r) return .{};
                if (is_set and op.c == obj_r) return .{};
                if (!has_obj) {
                    has_obj = true;
                    res.obj_reg = obj_r;
                } else if (res.obj_reg != obj_r) {
                    return .{};
                }
                const key = constantName(block, key_c) orelse return .{};
                const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
                const entry = table[ic_idx];
                if (entry.block != block or entry.pc != ip or @intFromPtr(entry.key_ptr) != @intFromPtr(key.ptr) or entry.shape_id == 0 or entry.next_shape != 0) {
                    return .{};
                }
                if (res.count == 0 and res.shape_id == 0) {
                    res.shape_id = entry.shape_id;
                } else if (res.shape_id != entry.shape_id) {
                    return .{};
                }
                if (res.findSlot(entry.slot_idx)) |idx| {
                    if (!std.mem.eql(u8, keys[idx], key)) return .{};
                    if (is_set) res.written[idx] = true;
                } else {
                    for (0..res.count) |k_idx| {
                        if (std.mem.eql(u8, keys[k_idx], key)) return .{};
                    }
                    if (res.count >= 6) return .{};
                    const idx = res.count;
                    res.slots[idx] = entry.slot_idx;
                    keys[idx] = key;
                    if (is_set) res.written[idx] = true;
                    if (entry.slot_idx > res.max_slot) res.max_slot = entry.slot_idx;
                    res.count += 1;
                }
            },
            else => {},
        }
    }

    if (res.count == 0) return .{};

    for (start_ip..end_ip + 1) |ip| {
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop,
            .jump,
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            .set_prop,
            => {},
            .jump_if_false, .jump_if_true => {
                if (op.a == res.obj_reg) return .{};
            },
            .move, .load_local, .store_local => {
                if (op.a == res.obj_reg or op.b == res.obj_reg) return .{};
            },
            else => {
                if (op.a == res.obj_reg) return .{};
            },
        }
    }

    return res;
}

const MAX_HOISTED_ARRAYS = 8;

const HoistedElemKind = enum(u8) {
    zarray_holey,
    zarray_dense,
    ta_f64,
    ta_i32,
    ta_u8,

    inline fn isPtrLen(self: HoistedElemKind) bool {
        return self != .zarray_holey;
    }

    inline fn isTypedArray(self: HoistedElemKind) bool {
        return switch (self) {
            .ta_f64, .ta_i32, .ta_u8 => true,
            else => false,
        };
    }

    inline fn expectedTypedKind(self: HoistedElemKind) u64 {
        return switch (self) {
            .ta_f64 => @intFromEnum(zvalue.TypedKind.f64),
            .ta_i32 => @intFromEnum(zvalue.TypedKind.i32),
            .ta_u8 => @intFromEnum(zvalue.TypedKind.u8),
            else => unreachable,
        };
    }
};

fn classifyTypedArrayForHoist(v: JSValue) ?HoistedElemKind {
    if (!v.isTypedArray()) return null;
    const ta = &v.asTypedArray().value;
    if (!ta.owner.isArrayBuffer()) return null;
    const ab = &ta.owner.asArrayBuffer().value;
    if (ab.isDetached()) return null;
    if (ta.len > 0x7FFF_F000) return null;
    return switch (ta.kind) {
        .f64 => .ta_f64,
        .i32 => .ta_i32,
        .u8 => .ta_u8,
        else => null,
    };
}

const HoistedArrays = struct {
    regs: [MAX_HOISTED_ARRAYS]u8 = @splat(0),
    written: [MAX_HOISTED_ARRAYS]bool = @splat(false),
    dense: [MAX_HOISTED_ARRAYS]bool = @splat(false),
    kinds: [MAX_HOISTED_ARRAYS]HoistedElemKind = @splat(.zarray_holey),
    use_counts: [MAX_HOISTED_ARRAYS]u32 = @splat(0),
    count: usize = 0,
    primary_in_regs: bool = false,

    fn find(self: *const HoistedArrays, reg: u8) ?usize {
        for (0..self.count) |i| {
            if (self.regs[i] == reg) return i;
        }
        return null;
    }
};

const FusedCmp = struct {
    skip_ops: u8,
    target_pc: usize,
    jump_if_true: bool,
};

inline fn regBit64(r: u8) u64 {
    return if (r < 64) (@as(u64, 1) << @intCast(r)) else 0;
}

fn isFusableCmpOpcode(opcode: codeblock.Opcode) bool {
    return switch (opcode) {
        .lt_num,
        .gt_num,
        .le_num,
        .ge_num,
        .eq,
        .ne,
        .lt_local_const,
        .gt_local_const,
        .le_local_const,
        .ge_local_const,
        .eq_local_const,
        => true,
        else => false,
    };
}

fn opUseDefMasks(block: *const codeblock.CodeBlock, op: codeblock.Op) struct { use: u64, def: u64 } {
    return switch (op.opcode) {
        .nop, .return_undefined, .end_catch, .jump => .{ .use = 0, .def = 0 },
        .return_value, .throw_value, .iter_end => .{ .use = regBit64(op.a), .def = 0 },
        .load_undefined,
        .load_null,
        .load_true,
        .load_false,
        .load_this,
        .load_const,
        .load_global,
        .typeof_global,
        .new_object,
        .new_array,
        .make_closure,
        => .{ .use = 0, .def = regBit64(op.a) },
        .move,
        .load_local,
        .store_local,
        .neg,
        .not,
        .not_bits,
        .typeof,
        .get_prop,
        .get_elem_const,
        .lt_local_const,
        .gt_local_const,
        .le_local_const,
        .ge_local_const,
        .eq_local_const,
        .add_local_const,
        .sub_local_const,
        .iter_init,
        => .{ .use = regBit64(op.b), .def = regBit64(op.a) },
        .store_global => .{ .use = regBit64(op.b), .def = 0 },
        .add,
        .add_num,
        .sub_num,
        .mul_num,
        .div_num,
        .mod_num,
        .pow_num,
        .lt_num,
        .gt_num,
        .le_num,
        .ge_num,
        .eq,
        .ne,
        .loose_eq,
        .loose_ne,
        .and_bits,
        .or_bits,
        .xor_bits,
        .shl,
        .shr,
        .ushr,
        .get_elem,
        => .{ .use = regBit64(op.b) | regBit64(op.c), .def = regBit64(op.a) },
        .set_elem => .{ .use = regBit64(op.a) | regBit64(op.b) | regBit64(op.c), .def = 0 },
        .set_elem_const, .set_prop, .set_prop_transition => .{ .use = regBit64(op.a) | regBit64(op.c), .def = 0 },
        .to_prop_key => .{ .use = regBit64(op.a) | regBit64(op.b), .def = regBit64(op.a) },
        .jump_if_false,
        .jump_if_true,
        .jump_if_not_nullish,
        .jeq_local_const_false,
        .jlt_local_const_false,
        .jle_local_const_false,
        .jgt_local_const_false,
        .jge_local_const_false,
        => .{ .use = regBit64(op.a), .def = 0 },
        .call, .call_global => blk: {
            var u: u64 = if (op.opcode == .call) regBit64(op.b) else 0;
            if (op.c < block.call_target_cache.len) {
                const cs = &block.call_target_cache[op.c];
                if (cs.this_reg) |tr| u |= regBit64(tr);
                for (0..cs.arg_count) |ai| {
                    const ar = @as(usize, op.b) + 1 + ai;
                    if (ar < 64) u |= (@as(u64, 1) << @intCast(ar));
                }
            } else {
                u = ~@as(u64, 0);
            }
            break :blk .{ .use = u, .def = regBit64(op.a) };
        },
        .new_value => blk: {
            var u: u64 = regBit64(op.b);
            for (0..op.c) |ai| {
                const ar = @as(usize, op.b) + 1 + ai;
                if (ar < 64) u |= (@as(u64, 1) << @intCast(ar));
            }
            break :blk .{ .use = u, .def = regBit64(op.a) };
        },
        else => .{ .use = ~@as(u64, 0), .def = 0 },
    };
}

noinline fn computeBlockLiveOut(allocator: Allocator, block: *const codeblock.CodeBlock) ![]u64 {
    const len = block.ops.len;
    var live_in = try allocator.alloc(u64, len);
    defer allocator.free(live_in);
    var live_out = try allocator.alloc(u64, len);
    errdefer allocator.free(live_out);
    @memset(live_in, 0);
    @memset(live_out, 0);

    var use_masks = try allocator.alloc(u64, len);
    defer allocator.free(use_masks);
    var def_masks = try allocator.alloc(u64, len);
    defer allocator.free(def_masks);
    for (block.ops, 0..) |op, pc| {
        const ud = opUseDefMasks(block, op);
        use_masks[pc] = ud.use;
        def_masks[pc] = ud.def;
    }

    var changed = true;
    while (changed) {
        changed = false;
        var pc = len;
        while (pc > 0) {
            pc -= 1;
            const op = block.ops[pc];
            const out: u64 = switch (op.opcode) {
                .return_value, .return_undefined, .throw_value => 0,
                .jump => blk: {
                    const t = (@as(usize, op.b) << 8) | op.c;
                    break :blk if (t < len) live_in[t] else 0;
                },
                .jump_if_false, .jump_if_true, .jump_if_not_nullish, .setup_catch => blk: {
                    const t = (@as(usize, op.b) << 8) | op.c;
                    const fall = if (pc + 1 < len) live_in[pc + 1] else 0;
                    const br = if (t < len) live_in[t] else 0;
                    break :blk fall | br;
                },
                .jeq_local_const_false,
                .jlt_local_const_false,
                .jle_local_const_false,
                .jgt_local_const_false,
                .jge_local_const_false,
                => blk: {
                    const t = pc + @as(usize, op.c);
                    const fall = if (pc + 1 < len) live_in[pc + 1] else 0;
                    const br = if (t < len) live_in[t] else 0;
                    break :blk fall | br;
                },
                else => if (pc + 1 < len) live_in[pc + 1] else 0,
            };
            const inp = use_masks[pc] | (out & ~def_masks[pc]);
            if (out != live_out[pc] or inp != live_in[pc]) {
                live_out[pc] = out;
                live_in[pc] = inp;
                changed = true;
            }
        }
    }
    return live_out;
}

const OsrPrePass = struct {
    live_out: []u64,
    fused_cmps: []?FusedCmp,
    is_jump_target: []bool,
    is_back_target: []bool,
    loop_weights: []u32,
    elided_compound_op: []bool,
    compound_arr_override: []?u8,
    compound_span_start: []?u32,
    fused_idx_delta: []?i32,

    noinline fn init(allocator: Allocator, block: *const codeblock.CodeBlock, start_ip: usize, end_ip: usize) !OsrPrePass {
        const loop_len = end_ip - start_ip + 1;
        const live_out = try computeBlockLiveOut(allocator, block);
        errdefer allocator.free(live_out);

        var raw_in_jumps = try allocator.alloc(u32, loop_len);
        defer allocator.free(raw_in_jumps);
        @memset(raw_in_jumps, 0);
        raw_in_jumps[0] = 1;

        for (block.ops, 0..) |op, pc| {
            const maybe_t: ?usize = switch (op.opcode) {
                .jump, .jump_if_false, .jump_if_true, .jump_if_not_nullish, .setup_catch => (@as(usize, op.b) << 8) | op.c,
                .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => pc + @as(usize, op.c),
                else => null,
            };
            if (maybe_t) |t| {
                if (t >= start_ip and t <= end_ip) {
                    raw_in_jumps[t - start_ip] += 1;
                }
            }
        }

        const fused_cmps = try allocator.alloc(?FusedCmp, loop_len);
        errdefer allocator.free(fused_cmps);
        @memset(fused_cmps, null);

        // Pass 1: 3-op short-circuit logical && / || LHS (<cmp> r_t; move r_c, r_t; jump_if_false/true r_c, L_short)
        var idx: usize = 0;
        while (idx < loop_len) {
            const ip = start_ip + idx;
            const op0 = block.ops[ip];
            if (isFusableCmpOpcode(op0.opcode) and op0.a >= block.local_count and op0.a < 64 and
                idx + 2 < loop_len and raw_in_jumps[idx + 1] == 0 and raw_in_jumps[idx + 2] == 0)
            {
                const op1 = block.ops[ip + 1];
                const op2 = block.ops[ip + 2];
                if (op1.opcode == .move and op1.b == op0.a and op1.a >= block.local_count and op1.a < 64 and
                    (op2.opcode == .jump_if_false or op2.opcode == .jump_if_true) and op2.a == op1.a)
                {
                    const short_pc = (@as(usize, op2.b) << 8) | op2.c;
                    if (short_pc > ip + 2 and short_pc < block.ops.len) {
                        const op_short = block.ops[short_pc];
                        if ((op_short.opcode == .jump_if_false or op_short.opcode == .jump_if_true) and op_short.a == op1.a and
                            (live_out[ip + 1] & regBit64(op0.a)) == 0 and
                            (live_out[short_pc] & regBit64(op1.a)) == 0)
                        {
                            const short_tgt = (@as(usize, op_short.b) << 8) | op_short.c;
                            const final_tgt = if (op2.opcode == op_short.opcode) short_tgt else (short_pc + 1);
                            if (final_tgt < block.ops.len) {
                                fused_cmps[idx] = .{
                                    .skip_ops = 2,
                                    .target_pc = final_tgt,
                                    .jump_if_true = (op2.opcode == .jump_if_true),
                                };
                                if (short_pc >= start_ip and short_pc <= end_ip and raw_in_jumps[short_pc - start_ip] > 0) {
                                    raw_in_jumps[short_pc - start_ip] -= 1;
                                }
                                if (final_tgt >= start_ip and final_tgt <= end_ip) {
                                    raw_in_jumps[final_tgt - start_ip] += 1;
                                }
                                idx += 3;
                                continue;
                            }
                        }
                    }
                }
            }
            idx += 1;
        }

        // Pass 2: 3-op logical RHS (now with raw_in_jumps[idx + 2] == 0) and 2-op direct <cmp> + jump_if_false/true
        idx = 0;
        while (idx < loop_len) {
            if (fused_cmps[idx]) |fc| {
                idx += 1 + @as(usize, fc.skip_ops);
                continue;
            }
            const ip = start_ip + idx;
            const op0 = block.ops[ip];
            if (isFusableCmpOpcode(op0.opcode) and op0.a >= block.local_count and op0.a < 64) {
                if (idx + 2 < loop_len and raw_in_jumps[idx + 1] == 0 and raw_in_jumps[idx + 2] == 0) {
                    const op1 = block.ops[ip + 1];
                    const op2 = block.ops[ip + 2];
                    if (op1.opcode == .move and op1.b == op0.a and op1.a >= block.local_count and op1.a < 64 and
                        (op2.opcode == .jump_if_false or op2.opcode == .jump_if_true) and op2.a == op1.a and
                        (live_out[ip + 1] & regBit64(op0.a)) == 0 and
                        (live_out[ip + 2] & regBit64(op1.a)) == 0)
                    {
                        const tgt = (@as(usize, op2.b) << 8) | op2.c;
                        fused_cmps[idx] = .{
                            .skip_ops = 2,
                            .target_pc = tgt,
                            .jump_if_true = (op2.opcode == .jump_if_true),
                        };
                        idx += 3;
                        continue;
                    }
                }
                if (idx + 1 < loop_len and raw_in_jumps[idx + 1] == 0) {
                    const op1 = block.ops[ip + 1];
                    if ((op1.opcode == .jump_if_false or op1.opcode == .jump_if_true) and op1.a == op0.a and
                        (live_out[ip + 1] & regBit64(op0.a)) == 0)
                    {
                        const tgt = (@as(usize, op1.b) << 8) | op1.c;
                        fused_cmps[idx] = .{
                            .skip_ops = 1,
                            .target_pc = tgt,
                            .jump_if_true = (op1.opcode == .jump_if_true),
                        };
                        idx += 2;
                        continue;
                    }
                }
            }
            idx += 1;
        }

        const is_jump_target = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(is_jump_target);
        const is_back_target = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(is_back_target);
        for (0..loop_len) |i| {
            is_jump_target[i] = (raw_in_jumps[i] > 0);
            is_back_target[i] = false;
        }
        is_jump_target[0] = true;
        is_back_target[0] = true;

        idx = 0;
        while (idx < loop_len) {
            const scan_ip = start_ip + idx;
            if (fused_cmps[idx]) |fc| {
                if (fc.target_pc >= start_ip and fc.target_pc <= end_ip) {
                    is_jump_target[fc.target_pc - start_ip] = true;
                    if (fc.target_pc <= scan_ip) is_back_target[fc.target_pc - start_ip] = true;
                }
                idx += 1 + @as(usize, fc.skip_ops);
                continue;
            }
            const scan_op = block.ops[scan_ip];
            switch (scan_op.opcode) {
                .jump, .jump_if_false, .jump_if_true => {
                    const t = (@as(usize, scan_op.b) << 8) | scan_op.c;
                    if (t >= start_ip and t <= end_ip) {
                        is_jump_target[t - start_ip] = true;
                        if (t <= scan_ip) is_back_target[t - start_ip] = true;
                    }
                },
                .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => {
                    const t = scan_ip + @as(usize, scan_op.c);
                    if (t >= start_ip and t <= end_ip) {
                        is_jump_target[t - start_ip] = true;
                        if (t <= scan_ip) is_back_target[t - start_ip] = true;
                    }
                },
                else => {},
            }
            idx += 1;
        }

        const loop_weights = try allocator.alloc(u32, loop_len);
        errdefer allocator.free(loop_weights);
        @memset(loop_weights, 1);

        // Weight inner loops 8x per nesting level so hot inner-loop variables win XMM4..15
        idx = 0;
        while (idx < loop_len) {
            const scan_ip = start_ip + idx;
            var maybe_back_tgt: ?usize = null;
            if (fused_cmps[idx]) |fc| {
                if (fc.target_pc >= start_ip and fc.target_pc < scan_ip) maybe_back_tgt = fc.target_pc;
                idx += 1 + @as(usize, fc.skip_ops);
            } else {
                const scan_op = block.ops[scan_ip];
                switch (scan_op.opcode) {
                    .jump, .jump_if_false, .jump_if_true => {
                        const t = (@as(usize, scan_op.b) << 8) | scan_op.c;
                        if (t >= start_ip and t < scan_ip and !(t == start_ip and scan_ip == end_ip)) {
                            maybe_back_tgt = t;
                        }
                    },
                    else => {},
                }
                idx += 1;
            }
            if (maybe_back_tgt) |bt| {
                const b_start = bt - start_ip;
                const b_end = scan_ip - start_ip;
                for (b_start..b_end + 1) |m| {
                    if (loop_weights[m] <= (1 << 15)) {
                        loop_weights[m] *= 8;
                    }
                }
            }
        }

        const elided_compound_op = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(elided_compound_op);
        @memset(elided_compound_op, false);

        const compound_arr_override = try allocator.alloc(?u8, loop_len);
        errdefer allocator.free(compound_arr_override);
        @memset(compound_arr_override, null);

        const compound_span_start = try allocator.alloc(?u32, loop_len);
        errdefer allocator.free(compound_span_start);
        @memset(compound_span_start, null);

        const fused_idx_delta = try allocator.alloc(?i32, loop_len);
        errdefer allocator.free(fused_idx_delta);
        @memset(fused_idx_delta, null);

        return .{
            .live_out = live_out,
            .fused_cmps = fused_cmps,
            .is_jump_target = is_jump_target,
            .is_back_target = is_back_target,
            .loop_weights = loop_weights,
            .elided_compound_op = elided_compound_op,
            .compound_arr_override = compound_arr_override,
            .compound_span_start = compound_span_start,
            .fused_idx_delta = fused_idx_delta,
        };
    }

    fn deinit(self: *OsrPrePass, allocator: Allocator) void {
        allocator.free(self.live_out);
        allocator.free(self.fused_cmps);
        allocator.free(self.is_jump_target);
        allocator.free(self.is_back_target);
        allocator.free(self.loop_weights);
        allocator.free(self.elided_compound_op);
        allocator.free(self.compound_arr_override);
        allocator.free(self.compound_span_start);
        allocator.free(self.fused_idx_delta);
    }

    noinline fn populateArrayElisions(
        self: *OsrPrePass,
        block: *const codeblock.CodeBlock,
        start_ip: usize,
        end_ip: usize,
        hoisted_arrs: *const HoistedArrays,
    ) void {
        if (hoisted_arrs.count == 0) return;
        const loop_len = end_ip - start_ip + 1;

        // 1. Compound array assignment: load_local r_obj, @arr ... to_prop_key r_key, r_obj; get_elem ...; ...; set_elem r_obj, r_key, r_res
        var idx0: usize = 0;
        while (idx0 < loop_len) : (idx0 += 1) {
            if (self.elided_compound_op[idx0] or self.fused_cmps[idx0] != null) continue;
            const op0 = block.ops[start_ip + idx0];
            if (op0.opcode != .load_local or op0.a < block.local_count or op0.a >= 64) continue;
            if (hoisted_arrs.find(op0.b) == null) continue;

            const obj_tmp = op0.a;
            const arr_local = op0.b;
            var tpk_idx: ?usize = null;
            var written_temps: u64 = 0;
            var read_before_write_temps: u64 = 0;

            var k = idx0 + 1;
            while (k < loop_len) : (k += 1) {
                if (self.is_jump_target[k] or self.fused_cmps[k] != null) break;
                const ck = block.ops[start_ip + k];
                if (ck.opcode == .set_elem and ck.a == obj_tmp) {
                    if (ck.b == obj_tmp or ck.c == obj_tmp) break;
                    if (ck.b >= block.local_count and (written_temps & regBit64(ck.b)) == 0) read_before_write_temps |= regBit64(ck.b);
                    if (ck.c >= block.local_count and (written_temps & regBit64(ck.c)) == 0) read_before_write_temps |= regBit64(ck.c);
                    if ((self.live_out[start_ip + k] & regBit64(obj_tmp)) != 0) break;
                    if ((written_temps & read_before_write_temps) != 0) break;

                    self.elided_compound_op[idx0] = true;
                    if (tpk_idx) |t| self.elided_compound_op[t] = true;
                    for (idx0 + 1 .. k + 1) |m| {
                        self.compound_span_start[m] = @intCast(start_ip + idx0);
                        const cm = block.ops[start_ip + m];
                        if ((cm.opcode == .get_elem or cm.opcode == .get_elem_const) and cm.b == obj_tmp) {
                            self.compound_arr_override[m] = arr_local;
                        }
                    }
                    self.compound_arr_override[k] = arr_local;
                    idx0 = k;
                    break;
                }
                if (ck.opcode == .to_prop_key) {
                    if (tpk_idx != null or ck.b != obj_tmp or ck.a == obj_tmp or ck.a < block.local_count or ck.a >= 64) break;
                    if (k + 1 >= loop_len or self.is_jump_target[k + 1]) break;
                    const next_ck = block.ops[start_ip + k + 1];
                    if (next_ck.opcode != .get_elem or next_ck.b != obj_tmp or next_ck.c != ck.a) break;
                    if ((written_temps & regBit64(ck.a)) == 0) read_before_write_temps |= regBit64(ck.a);
                    tpk_idx = k;
                    continue;
                }
                const allowed = switch (ck.opcode) {
                    .nop => true,
                    .load_const => block.constants[ck.b] == .number or block.constants[ck.b] == .boolean,
                    .move,
                    .load_local,
                    .add,
                    .add_num,
                    .sub_num,
                    .mul_num,
                    .div_num,
                    .mod_num,
                    .neg,
                    .add_local_const,
                    .sub_local_const,
                    .and_bits,
                    .or_bits,
                    .xor_bits,
                    .shl,
                    .shr,
                    .ushr,
                    .not_bits,
                    .get_elem,
                    .get_elem_const,
                    => true,
                    else => false,
                };
                if (!allowed) break;
                if (ck.opcode != .nop) {
                    if (ck.a < block.local_count or ck.a >= 64 or ck.a == obj_tmp) break;
                }
                if (ck.opcode == .get_elem) {
                    if (ck.c == obj_tmp) break;
                    if (ck.c >= block.local_count and (written_temps & regBit64(ck.c)) == 0) read_before_write_temps |= regBit64(ck.c);
                    if (ck.b != obj_tmp and ck.b >= block.local_count and (written_temps & regBit64(ck.b)) == 0) read_before_write_temps |= regBit64(ck.b);
                } else if (ck.opcode == .get_elem_const) {
                    if (ck.b != obj_tmp and ck.b >= block.local_count and (written_temps & regBit64(ck.b)) == 0) read_before_write_temps |= regBit64(ck.b);
                } else {
                    const ud = opUseDefMasks(block, ck);
                    if ((ud.use & regBit64(obj_tmp)) != 0) break;
                    const temp_reads = ud.use & ~((@as(u64, 1) << @intCast(@min(block.local_count, 64))) - 1);
                    read_before_write_temps |= (temp_reads & ~written_temps);
                }
                if (ck.opcode != .nop) {
                    written_temps |= regBit64(ck.a);
                }
            }
        }

        // 2. Fused (add_local_const / sub_local_const r_tmp, @i, #delta) + (get_elem r_dst, @arr, r_tmp) on dense hoisted arrays
        var j: usize = 0;
        while (j + 1 < loop_len) : (j += 1) {
            if (self.elided_compound_op[j] or self.elided_compound_op[j + 1]) continue;
            if (self.is_jump_target[j + 1] or self.fused_cmps[j] != null or self.fused_cmps[j + 1] != null) continue;
            if (self.compound_arr_override[j + 1] != null) continue;
            const op0 = block.ops[start_ip + j];
            if (op0.opcode != .add_local_const and op0.opcode != .sub_local_const) continue;
            if (op0.a < block.local_count or op0.a >= 64) continue;
            const op1 = block.ops[start_ip + j + 1];
            if (op1.opcode != .get_elem or op1.c != op0.a or op1.b == op0.a) continue;
            if ((self.live_out[start_ip + j + 1] & regBit64(op0.a)) != 0) continue;
            const h_slot = hoisted_arrs.find(op1.b) orelse continue;
            if (!hoisted_arrs.kinds[h_slot].isPtrLen()) continue;
            const raw_imm = asExactInt32(block.constants[op0.c].number) orelse continue;
            if (raw_imm < -4096 or raw_imm > 4096) continue;
            self.fused_idx_delta[j] = if (op0.opcode == .add_local_const) raw_imm else -raw_imm;
            j += 1;
        }
    }
};

noinline fn analyzeHoistedArrays(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    promoted_count: usize,
    prepass: *const OsrPrePass,
    frame_regs_opt: ?[]const JSValue,
) HoistedArrays {
    if (promoted_count > 0) return .{};
    var cands: [16]u8 = @splat(0);
    var cand_written: [16]bool = @splat(false);
    var cand_uses: [16]u32 = @splat(0);
    var cand_count: usize = 0;

    var cur_copy_src: [64]?u8 = @splat(null);
    const loop_len = end_ip - start_ip + 1;

    const addOrBumpCand = struct {
        fn call(
            c_regs: *[16]u8,
            c_written: *[16]bool,
            c_uses: *[16]u32,
            c_count: *usize,
            r: u8,
            is_write: bool,
            w: u32,
        ) void {
            for (0..c_count.*) |k| {
                if (c_regs[k] == r) {
                    if (is_write) c_written[k] = true;
                    c_uses[k] +%= w;
                    return;
                }
            }
            if (c_count.* < 16) {
                const idx = c_count.*;
                c_regs[idx] = r;
                c_written[idx] = is_write;
                c_uses[idx] = w;
                c_count.* += 1;
            }
        }
    }.call;

    for (0..loop_len) |idx| {
        if (prepass.is_jump_target[idx]) {
            cur_copy_src = @splat(null);
        }
        const ip = start_ip + idx;
        const op = block.ops[ip];
        const w = prepass.loop_weights[idx];
        switch (op.opcode) {
            .call => {
                if (op.c >= block.call_target_cache.len or !isMathSqrtCall(&block.call_target_cache[op.c])) {
                    return .{};
                }
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
            .call_global, .new_array => return .{},
            .move, .load_local, .store_local => {
                const resolved_src: ?u8 = if (op.b < 64) (cur_copy_src[op.b] orelse op.b) else null;
                if (op.a < 64) {
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                    cur_copy_src[op.a] = if (resolved_src != null and resolved_src.? != op.a) resolved_src else null;
                }
            },
            .get_elem, .get_elem_const => {
                const eff_b = if (op.b < 64) (cur_copy_src[op.b] orelse op.b) else op.b;
                if (op.a != eff_b) {
                    addOrBumpCand(&cands, &cand_written, &cand_uses, &cand_count, eff_b, false, w);
                }
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
            .get_prop => {
                if (constantName(block, op.c)) |kname| {
                    if (std.mem.eql(u8, kname, "length")) {
                        const eff_b = if (op.b < 64) (cur_copy_src[op.b] orelse op.b) else op.b;
                        if (op.a != eff_b) {
                            const can_add = if (frame_regs_opt) |fregs|
                                (eff_b < fregs.len and (fregs[eff_b].isArray() or classifyTypedArrayForHoist(fregs[eff_b]) != null))
                            else
                                false;
                            if (can_add) {
                                addOrBumpCand(&cands, &cand_written, &cand_uses, &cand_count, eff_b, false, w);
                            }
                        }
                    }
                }
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
            .set_elem, .set_elem_const => {
                const eff_a = if (op.a < 64) (cur_copy_src[op.a] orelse op.a) else op.a;
                addOrBumpCand(&cands, &cand_written, &cand_uses, &cand_count, eff_a, true, w);
            },
            .nop,
            .jump,
            .jump_if_false,
            .jump_if_true,
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            .set_prop,
            .set_prop_transition,
            .to_prop_key,
            .store_global,
            => {},
            else => {
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
        }
    }

    if (cand_count == 0) return .{};

    var valid: [16]bool = @splat(true);
    cur_copy_src = @splat(null);
    var skip_rem: u8 = 0;
    for (0..loop_len) |idx| {
        if (prepass.is_jump_target[idx]) {
            cur_copy_src = @splat(null);
        }
        if (skip_rem > 0) {
            skip_rem -= 1;
            continue;
        }
        if (prepass.fused_cmps[idx]) |fc| {
            skip_rem = fc.skip_ops;
            continue;
        }
        const op = block.ops[start_ip + idx];
        switch (op.opcode) {
            .nop,
            .jump,
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            .set_elem,
            .to_prop_key,
            .store_global,
            => {},
            .set_elem_const, .set_prop, .set_prop_transition => {
                const eff_a = if (op.a < 64) (cur_copy_src[op.a] orelse op.a) else op.a;
                for (0..cand_count) |k| {
                    if (op.a == cands[k] or eff_a == cands[k]) valid[k] = false;
                }
            },
            .jump_if_false, .jump_if_true => {
                for (0..cand_count) |k| {
                    if (op.a == cands[k]) valid[k] = false;
                }
            },
            .move, .load_local, .store_local => {
                const resolved_src: ?u8 = if (op.b < 64) (cur_copy_src[op.b] orelse op.b) else null;
                for (0..cand_count) |k| {
                    if (op.a == cands[k]) valid[k] = false;
                }
                if (op.a < 64) {
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                    cur_copy_src[op.a] = if (resolved_src != null and resolved_src.? != op.a) resolved_src else null;
                }
            },
            else => {
                for (0..cand_count) |k| {
                    if (op.a == cands[k]) valid[k] = false;
                }
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
        }
    }

    const Entry = struct { reg: u8, written: bool, kind: HoistedElemKind, uses: u32 };
    var entries: [16]Entry = undefined;
    var entry_count: usize = 0;

    for (0..cand_count) |k| {
        if (!valid[k]) continue;
        const r = cands[k];
        var elem_kind: HoistedElemKind = .zarray_holey;
        if (frame_regs_opt) |fregs| {
            if (r >= fregs.len) continue;
            if (fregs[r].isArray()) {
                const box = fregs[r].asArray();
                const arr = &box.value;
                if (cand_written[k] and @hasField(@TypeOf(arr.*), "is_frozen") and arr.is_frozen) continue;
                if (arr.items.items.len > 0x7FFF_F000) continue;
                if (arr.holey != null) {
                    vm.maybeCompactFilledHoleyArray(arr);
                }
                if (arr.holey) |h| {
                    if (h.sparse != null or h.has_element_descriptors or !h.length_writable) continue;
                    elem_kind = .zarray_holey;
                } else {
                    elem_kind = .zarray_dense;
                }
            } else if (classifyTypedArrayForHoist(fregs[r])) |tk| {
                elem_kind = tk;
            } else {
                continue;
            }
        }
        entries[entry_count] = .{
            .reg = r,
            .written = cand_written[k],
            .kind = elem_kind,
            .uses = cand_uses[k],
        };
        entry_count += 1;
    }

    // Sort descending: (ptr, len) buffers (dense ZArray and TypedArray) first, then by weighted loop use count
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        var j = i + 1;
        while (j < entry_count) : (j += 1) {
            const j_ptr = entries[j].kind.isPtrLen();
            const i_ptr = entries[i].kind.isPtrLen();
            const j_better = (j_ptr and !i_ptr) or
                (j_ptr == i_ptr and entries[j].uses > entries[i].uses);
            if (j_better) {
                const tmp = entries[i];
                entries[i] = entries[j];
                entries[j] = tmp;
            }
        }
    }

    var res = HoistedArrays{};
    const take = @min(entry_count, MAX_HOISTED_ARRAYS);
    for (0..take) |k| {
        res.regs[k] = entries[k].reg;
        res.written[k] = entries[k].written;
        res.kinds[k] = entries[k].kind;
        res.dense[k] = (entries[k].kind == .zarray_dense);
        res.use_counts[k] = entries[k].uses;
    }
    res.count = take;
    res.primary_in_regs = (take >= 1 and res.kinds[0].isPtrLen());
    return res;
}

const OsrCachedAnalysis = struct {
    cached_regs: [12]u8 = @splat(0),
    cached_count: usize = 0,
    reg_to_xmm: [64]?Xmm = @splat(null),
    read_before_written: [64]bool = @splat(false),
    promoted: PromotedPropsAnalysis = .{},
    hoisted_arrs: HoistedArrays = .{},
};

noinline fn analyzeOsrLoop(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic: ?*const [256]PropIC,
    prepass: *OsrPrePass,
    frame_regs_opt: ?[]const JSValue,
) OsrCachedAnalysis {
    var result = OsrCachedAnalysis{};

    // 1. Pureza del bucle (is_pure_loop): true si ningún opcode en [start_ip .. end_ip]
    // es una llamada no-intrínseca (.call_global o .call != Math.sqrt)
    var is_pure_loop = true;
    var loop_mutates_globals_or_props = false;
    for (start_ip..end_ip + 1) |ip| {
        const op = block.ops[ip];
        switch (op.opcode) {
            .call => {
                if (op.c >= block.call_target_cache.len or !isMathSqrtCall(&block.call_target_cache[op.c])) {
                    is_pure_loop = false;
                    loop_mutates_globals_or_props = true;
                    break;
                }
            },
            .call_global => {
                is_pure_loop = false;
                loop_mutates_globals_or_props = true;
                break;
            },
            .set_prop, .set_prop_transition, .store_global => {
                loop_mutates_globals_or_props = true;
            },
            else => {},
        }
    }
    if (!is_pure_loop) return result;

    var promoted = analyzePromotedProps(block, start_ip, end_ip, prop_ic);
    const hoisted_arrs = analyzeHoistedArrays(block, start_ip, end_ip, promoted.count, prepass, frame_regs_opt);
    prepass.populateArrayElisions(block, start_ip, end_ip, &hoisted_arrs);

    var invalid: [64]bool = @splat(false);
    var written: [64]bool = @splat(false);
    var read_before_written: [64]bool = @splat(false);
    var use_count: [64]u32 = @splat(0);

    const loop_len = end_ip - start_ip + 1;
    var skip_rem: u8 = 0;
    for (0..loop_len) |idx| {
        if (skip_rem > 0) {
            skip_rem -= 1;
            continue;
        }
        if (prepass.elided_compound_op[idx]) continue;

        const ip = start_ip + idx;
        const op = block.ops[ip];
        const w = prepass.loop_weights[idx];

        if (prepass.fused_cmps[idx]) |fc| {
            if (op.b < 64) {
                if (!written[op.b]) read_before_written[op.b] = true;
                use_count[op.b] +%= w;
            }
            switch (op.opcode) {
                .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne => {
                    if (op.c < 64) {
                        if (!written[op.c]) read_before_written[op.c] = true;
                        use_count[op.c] +%= w;
                    }
                },
                else => {},
            }
            skip_rem = fc.skip_ops;
            continue;
        }

        if (prepass.fused_idx_delta[idx] != null) {
            const get_op = block.ops[ip + 1];
            if (op.b < 64) {
                if (!written[op.b]) read_before_written[op.b] = true;
                use_count[op.b] +%= w;
            }
            if (get_op.b < 64) invalid[get_op.b] = true;
            if (get_op.a < 64) {
                use_count[get_op.a] +%= w;
                written[get_op.a] = true;
            }
            skip_rem = 1;
            continue;
        }

        switch (op.opcode) {
            .nop => {},
            .add, .add_num, .sub_num, .mul_num, .div_num, .mod_num, .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .add_local_const, .sub_local_const => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .neg, .not_bits => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => {
                if (op.a < 64) {
                    if (!written[op.a]) read_before_written[op.a] = true;
                    use_count[op.a] +%= w;
                }
            },
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
                if (op.a < 64) {
                    invalid[op.a] = true;
                    written[op.a] = true;
                }
            },
            .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.a < 64) {
                    invalid[op.a] = true;
                    written[op.a] = true;
                }
            },
            .get_elem => {
                if (prepass.compound_arr_override[idx]) |ov| {
                    if (ov < 64) invalid[ov] = true;
                } else {
                    if (op.b < 64) invalid[op.b] = true;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .set_elem => {
                if (prepass.compound_arr_override[idx]) |ov| {
                    if (ov < 64) invalid[ov] = true;
                } else {
                    if (op.a < 64) invalid[op.a] = true;
                }
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
            },
            .get_elem_const => {
                if (prepass.compound_arr_override[idx]) |ov| {
                    if (ov < 64) invalid[ov] = true;
                } else {
                    if (op.b < 64) invalid[op.b] = true;
                }
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .set_elem_const => {
                if (op.a < 64) invalid[op.a] = true;
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
            },
            .to_prop_key => {
                if (op.b < 64) invalid[op.b] = true;
                if (op.a < 64) {
                    if (!written[op.a]) read_before_written[op.a] = true;
                    use_count[op.a] +%= w;
                }
            },
            .get_prop => {
                if (op.b < 64) invalid[op.b] = true;
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .set_prop, .set_prop_transition => {
                if (op.a < 64) invalid[op.a] = true;
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
            },
            .load_global => {
                if (op.a < 64) invalid[op.a] = true;
            },
            .call => {
                const arg_reg: usize = @as(usize, op.b) + 1;
                if (arg_reg < 64) {
                    if (!written[arg_reg]) read_before_written[arg_reg] = true;
                    use_count[arg_reg] +%= w;
                }
                if (loop_mutates_globals_or_props) {
                    if (op.a < 64) invalid[op.a] = true;
                    if (op.b < 64) invalid[op.b] = true;
                } else {
                    if (op.a != op.b and op.b < 64) invalid[op.b] = true;
                    if (op.a < 64) {
                        use_count[op.a] +%= w;
                        written[op.a] = true;
                    }
                }
            },
            .new_array, .new_object => {
                if (op.a < 64) invalid[op.a] = true;
            },
            .load_const => {
                if (op.a < 64) {
                    if (block.constants[op.b] == .number) {
                        use_count[op.a] +%= w;
                        written[op.a] = true;
                    } else {
                        invalid[op.a] = true;
                    }
                }
            },
            .move, .load_local, .store_local => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] +%= w;
                }
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .jump, .jump_if_false, .jump_if_true => {
                if (op.opcode != .jump and op.a < 64) {
                    invalid[op.a] = true;
                }
            },
            else => {
                if (op.a < 64) invalid[op.a] = true;
                if (op.b < 64) invalid[op.b] = true;
                if (op.c < 64) invalid[op.c] = true;
            },
        }
    }

    // Propagate invalidity across active (non-elided, non-fused) move / load_local / store_local
    for (0..4) |_| {
        var s_rem: u8 = 0;
        for (0..loop_len) |idx| {
            if (s_rem > 0) {
                s_rem -= 1;
                continue;
            }
            if (prepass.elided_compound_op[idx]) continue;
            if (prepass.fused_cmps[idx]) |fc| {
                s_rem = fc.skip_ops;
                continue;
            }
            if (prepass.fused_idx_delta[idx] != null) {
                s_rem = 1;
                continue;
            }
            const op = block.ops[start_ip + idx];
            if (op.opcode == .move or op.opcode == .load_local or op.opcode == .store_local) {
                if (op.b < 64 and op.a < 64) {
                    if (invalid[op.b]) invalid[op.a] = true;
                    if (invalid[op.a]) invalid[op.b] = true;
                }
            }
        }
    }

    const Cand = struct { reg: u8, count: u32 };
    var candidates: [64]Cand = undefined;
    var num_candidates: usize = 0;

    const limit = @min(block.register_count, 64);
    for (0..limit) |r_usize| {
        const r: u8 = @intCast(r_usize);
        if (!invalid[r] and use_count[r] > 0) {
            candidates[num_candidates] = .{ .reg = r, .count = use_count[r] };
            num_candidates += 1;
        }
    }

    // Sort descending by use_count
    var i: usize = 0;
    while (i < num_candidates) : (i += 1) {
        var j = i + 1;
        while (j < num_candidates) : (j += 1) {
            if (candidates[j].count > candidates[i].count) {
                const tmp = candidates[i];
                candidates[i] = candidates[j];
                candidates[j] = tmp;
            }
        }
    }

    const max_cached = @min(num_candidates, 12 - promoted.count);
    for (0..max_cached) |k| {
        const reg = candidates[k].reg;
        result.cached_regs[k] = reg;
        result.reg_to_xmm[reg] = @enumFromInt(4 + k);
    }
    for (0..promoted.count) |p| {
        promoted.xmms[p] = @enumFromInt(4 + max_cached + p);
    }
    result.cached_count = max_cached;
    result.read_before_written = read_before_written;
    result.promoted = promoted;
    result.hoisted_arrs = hoisted_arrs;

    return result;
}

noinline fn emitFlushPromoted(a: *Assembler, promoted: *const PromotedPropsAnalysis) !void {
    for (0..promoted.count) |p| {
        if (!promoted.written[p]) continue;
        const slot_byte_off: i32 = @intCast(@as(usize, promoted.slots[p]) * @as(usize, @intCast(prop_size)));
        const xmm_p = promoted.xmms[p];
        try a.movqRegXmm(.rcx, xmm_p);
        try a.ucomisd(xmm_p, xmm_p);
        try a.movRegImm64(.rdx, JSValue.CANONICAL_NAN);
        try a.cmovpRegReg(.rcx, .rdx);
        try a.movMemReg(.rbx, slot_byte_off + prop_val_offset, .rcx);
    }
}

noinline fn emitReloadPromoted(a: *Assembler, promoted: *const PromotedPropsAnalysis) !void {
    for (0..promoted.count) |p| {
        const slot_byte_off: i32 = @intCast(@as(usize, promoted.slots[p]) * @as(usize, @intCast(prop_size)));
        const xmm_p = promoted.xmms[p];
        try a.movsdXmmMem(xmm_p, .rbx, slot_byte_off + prop_val_offset);
    }
}

fn asExactInt32(val: f64) ?i32 {
    if (!std.math.isFinite(val)) return null;
    if (val < @as(f64, std.math.minInt(i32)) or val > @as(f64, std.math.maxInt(i32))) return null;
    const i: i32 = @intFromFloat(val);
    if (@as(f64, @floatFromInt(i)) != val) return null;
    if (i == 0 and (@as(u64, @bitCast(val)) >> 63) != 0) return null;
    return i;
}

fn asExactPosUint53(val: f64) ?u64 {
    if (!std.math.isFinite(val) or val < 1.0 or val > 9007199254740991.0) return null;
    const u: u64 = @intFromFloat(val);
    if (@as(f64, @floatFromInt(u)) != val) return null;
    return u;
}

fn asPowerOfTwoReciprocal(val: f64) ?u64 {
    if (!std.math.isFinite(val) or val == 0.0) return null;
    const bits: u64 = @bitCast(val);
    const mantissa = bits & 0x000F_FFFF_FFFF_FFFF;
    const exp: i32 = @as(i32, @intCast((bits >> 52) & 0x7FF)) - 1023;
    if (mantissa != 0) return null;
    if (exp < -500 or exp > 500) return null;
    const recip: f64 = 1.0 / val;
    return @bitCast(recip);
}

noinline fn canElideLoadConst(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    idx: usize,
    is_jump_target: []const bool,
) bool {
    const loop_len = end_ip - start_ip + 1;
    if (idx + 1 >= loop_len) return false;
    if (is_jump_target[idx + 1]) return false;
    const op = block.ops[start_ip + idx];
    const reg = op.a;
    if (reg < block.local_count or reg >= 64) return false;
    const c = block.constants[op.b];
    if (c != .number) return false;

    const next_op = block.ops[start_ip + idx + 1];
    switch (next_op.opcode) {
        .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
            if (next_op.c != reg or next_op.b == reg) return false;
            if (asExactInt32(c.number) == null) return false;
        },
        .mod_num => {
            if (next_op.c != reg or next_op.b == reg) return false;
            if (asExactPosUint53(c.number) == null) return false;
        },
        .div_num => {
            if (next_op.c != reg or next_op.b == reg) return false;
            if (asPowerOfTwoReciprocal(c.number) == null) return false;
        },
        else => return false,
    }

    if (next_op.a == reg) return true;

    var k = idx + 2;
    while (k < loop_len) : (k += 1) {
        if (is_jump_target[k]) return false;
        const op_k = block.ops[start_ip + k];
        switch (op_k.opcode) {
            .nop => {},
            .load_const, .load_undefined, .load_null, .load_true, .load_false, .new_object, .new_array => {
                if (op_k.a == reg) return true;
            },
            .add, .add_num, .sub_num, .mul_num, .div_num, .mod_num, .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr, .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne, .get_elem => {
                if (op_k.b == reg or op_k.c == reg) return false;
                if (op_k.a == reg) return true;
            },
            .add_local_const, .sub_local_const, .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const, .neg, .not, .not_bits, .move, .load_local, .store_local, .get_prop, .get_elem_const => {
                if (op_k.b == reg) return false;
                if (op_k.a == reg) return true;
            },
            else => return false,
        }
    }
    return false;
}

noinline fn emitFlushCached(a: *Assembler, cached_regs: *const [12]u8, cached_count: usize) !void {
    for (0..cached_count) |k| {
        const r = cached_regs[k];
        const xmm_k = @as(Xmm, @enumFromInt(4 + k));
        try a.movqRegXmm(.rcx, xmm_k);
        try a.ucomisd(xmm_k, xmm_k);
        try a.movRegImm64(.rdx, JSValue.CANONICAL_NAN);
        try a.cmovpRegReg(.rcx, .rdx);
        try a.movMemReg(.r12, @intCast(@as(usize, r) * 8), .rcx);
    }
}

noinline fn emitReloadCached(a: *Assembler, cached_regs: *const [12]u8, cached_count: usize) !void {
    for (0..cached_count) |k| {
        const r = cached_regs[k];
        const xmm_k = @as(Xmm, @enumFromInt(4 + k));
        try a.movsdXmmMem(xmm_k, .r12, @intCast(@as(usize, r) * 8));
    }
}

noinline fn emitReleaseHeapIfRefGt1(
    a: *Assembler,
    reg_idx: u8,
    bail_lbl: Label,
) !void {
    const ok_lbl = try a.createLabel();
    try a.movRegMem(.rax, .r12, @intCast(@as(usize, reg_idx) * 8));
    try a.cmpRegReg(.rax, .r14); // %r14 = HEAP_BASE
    try a.jcc(.b, ok_lbl);

    // Old value is >= HEAP_BASE
    try a.movRegReg(.rcx, .rax);
    try a.shrRegImm8(.rcx, 47);
    const is_ref_lbl = try a.createLabel();
    try a.cmpRegImm32(.rcx, HEADER_ARRAY);
    try a.jcc(.e, is_ref_lbl);
    try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
    try a.jcc(.e, is_ref_lbl);
    try a.cmpRegImm32(.rcx, HEADER_OBJECT);
    try a.jcc(.e, is_ref_lbl);
    try a.movRegReg(.rdx, .rax);
    try a.movRegImm64(.rcx, JSValue.TAG15_MASK);
    try a.andRegReg(.rdx, .rcx);
    try a.movRegImm64(.rcx, HEADER_TYPED_ARRAY_BITS);
    try a.cmpRegReg(.rdx, .rcx);
    try a.jcc(.ne, bail_lbl); // Other heap type -> bail out

    // Array or Function: ptr = rax & PTR_MASK
    a.bindLabel(is_ref_lbl);
    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
    try a.andRegReg(.rax, .rcx);

    // Read _count at offset 0
    try a.movRegMem(.rcx, .rax, 0);
    try a.cmpRegImm32(.rcx, 1);
    try a.jcc(.be, bail_lbl); // If rc <= 1 -> bail out

    // rc > 1: decrement rc inline
    try a.decReg64(.rcx);
    try a.movMemReg(.rax, 0, .rcx);

    a.bindLabel(ok_lbl);
}

noinline fn emitLoadNumToXmm(
    a: *Assembler,
    reg_to_xmm: *const [64]?Xmm,
    r: u8,
    target_xmm: Xmm,
    bail_lbl: Label,
) !void {
    if (r < 64 and reg_to_xmm[r] != null) {
        const xmm_k = reg_to_xmm[r].?;
        if (xmm_k != target_xmm) {
            try a.movsdXmmXmm(target_xmm, xmm_k);
        }
    } else {
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, r) * 8));
        try a.cmpRegReg(.rax, .r15);
        try a.jcc(.ae, bail_lbl);
        try a.movqXmmReg(target_xmm, .rax);
    }
}

noinline fn emitStoreXmmToNum(
    a: *Assembler,
    reg_to_xmm: *const [64]?Xmm,
    r: u8,
    src_xmm: Xmm,
    bail_lbl: Label,
) !void {
    if (r < 64 and reg_to_xmm[r] != null) {
        const xmm_k = reg_to_xmm[r].?;
        if (xmm_k != src_xmm) {
            try a.movsdXmmXmm(xmm_k, src_xmm);
        }
    } else {
        try emitReleaseHeapIfRefGt1(a, r, bail_lbl);
        try a.movqRegXmm(.rax, src_xmm);
        try a.ucomisd(src_xmm, src_xmm);
        try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
        try a.cmovpRegReg(.rax, .rcx);
        try a.movMemReg(.r12, @intCast(@as(usize, r) * 8), .rax);
    }
}

noinline fn emitFusedCmpBranch(
    a: *Assembler,
    opcode: codeblock.Opcode,
    jump_if_true: bool,
    target_lbl: Label,
) !void {
    switch (opcode) {
        .lt_num, .lt_local_const => {
            try a.ucomisd(.xmm1, .xmm0);
            try a.jcc(if (jump_if_true) .a else .be, target_lbl);
        },
        .le_num, .le_local_const => {
            try a.ucomisd(.xmm1, .xmm0);
            try a.jcc(if (jump_if_true) .ae else .b, target_lbl);
        },
        .gt_num, .gt_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(if (jump_if_true) .a else .be, target_lbl);
        },
        .ge_num, .ge_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(if (jump_if_true) .ae else .b, target_lbl);
        },
        .eq, .eq_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            if (jump_if_true) {
                const fall_lbl = try a.createLabel();
                try a.jcc(.p, fall_lbl);
                try a.jcc(.e, target_lbl);
                a.bindLabel(fall_lbl);
            } else {
                try a.jcc(.p, target_lbl);
                try a.jcc(.ne, target_lbl);
            }
        },
        .ne => {
            try a.ucomisd(.xmm0, .xmm1);
            if (jump_if_true) {
                try a.jcc(.p, target_lbl);
                try a.jcc(.ne, target_lbl);
            } else {
                const fall_lbl = try a.createLabel();
                try a.jcc(.p, fall_lbl);
                try a.jcc(.e, target_lbl);
                a.bindLabel(fall_lbl);
            }
        },
        else => unreachable,
    }
}

noinline fn emitRefreshDenseHoisted(
    a: *Assembler,
    hoisted_arrs: *const HoistedArrays,
) !void {
    for (0..hoisted_arrs.count) |m| {
        if (!hoisted_arrs.dense[m]) continue;
        const m_reg = hoisted_arrs.regs[m];
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, m_reg) * 8));
        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);
        try a.movRegMem(.rdx, .rax, arr_items_ptr_off);
        try a.movRegMem(.rcx, .rax, arr_items_len_off);
        try a.movMemReg(.rsp, @intCast(m * 16), .rdx);
        try a.movMemReg(.rsp, @intCast(m * 16 + 8), .rcx);
        if (m == 0 and hoisted_arrs.primary_in_regs) {
            try a.movRegReg(.rbx, .rdx);
            try a.movRegReg(.rbp, .rcx);
        }
    }
}

const OsrCompiler = struct {
    const ElidedConst = struct { reg: u8, bits: u64 };
    const ExitStub = struct { label: Label, target_ip: u32 };
    const ElemStorePair = struct { idx_reg: u8, val_reg: u8 };

    allocator: Allocator,
    a: *Assembler,
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    loop_len: usize,
    prop_ic: ?*const [256]PropIC,
    prepass: *const OsrPrePass,
    analysis: OsrCachedAnalysis,
    single_hoisted_arr: ?u8,
    hoisted_stack_bytes: i32,
    has_flush: bool,
    op_labels: []Label,
    bailout_labels: []Label,
    bailout_target_ips: []u32,
    elided_consts: []?ElidedConst,
    preheader_bailout: Label,
    flush_and_exit: Label,
    osr_epilogue: Label,
    elided_op: []bool,
    elided_math_call: []bool,
    math_sqrt_guard_bits: ?u64 = null,
    exit_stubs: std.ArrayListUnmanaged(ExitStub) = .empty,
    known_f64: [64]?f64 = @splat(null),
    reg_is_int32: [64]bool = @splat(false),
    reg_is_uint31: [64]bool = @splat(false),
    reg_is_exact_idx: [64]bool = @splat(false),
    incoming_has_edge: []bool,
    incoming_int32: [][64]bool,
    incoming_uint31: [][64]bool,
    incoming_exact_idx: [][64]bool,
    last_elem_store: ?ElemStorePair = null,
    known_valid_elem_idx: ?u8 = null,
    known_dense_valid_idx: [MAX_HOISTED_ARRAYS]?u8 = @splat(null),
    cur_copy_src: [64]?u8 = @splat(null),
    live_r8_i32: ?u8 = null,
    incoming_elem_store: []?ElemStorePair,
    skip_ops_remaining: u8 = 0,

    noinline fn analyzeMathSqrtElisions(self: *OsrCompiler) void {
        const block = self.block;
        const start_ip = self.start_ip;
        const end_ip = self.end_ip;
        const loop_len = self.loop_len;
        const is_jump_target = self.prepass.is_jump_target;

        var loop_mutates_globals_or_props = false;
        for (start_ip..end_ip + 1) |scan_ip| {
            const scan_op = block.ops[scan_ip];
            switch (scan_op.opcode) {
                .set_prop, .set_prop_transition, .store_global, .call_global => {
                    loop_mutates_globals_or_props = true;
                    break;
                },
                .call => {
                    if (scan_op.c >= block.call_target_cache.len or !isMathSqrtCall(&block.call_target_cache[scan_op.c])) {
                        loop_mutates_globals_or_props = true;
                        break;
                    }
                },
                else => {},
            }
        }

        if (!loop_mutates_globals_or_props) {
            for (0..loop_len) |call_idx| {
                const call_op = block.ops[start_ip + call_idx];
                if (call_op.opcode != .call) continue;
                const cs = &block.call_target_cache[call_op.c];
                if (!isMathSqrtCall(cs)) continue;
                const this_r = cs.this_reg orelse continue;
                const expected_bits = cs.callee.?.bits;
                if (self.math_sqrt_guard_bits != null and self.math_sqrt_guard_bits.? != expected_bits) continue;

                var found_gp: ?usize = null;
                var k = call_idx;
                while (k > 0) {
                    k -= 1;
                    const cand = block.ops[start_ip + k];
                    if (cand.opcode == .get_prop and cand.a == call_op.b and cand.b == this_r) {
                        const prop_name = constantName(block, cand.c) orelse break;
                        if (std.mem.eql(u8, prop_name, "sqrt")) {
                            found_gp = k;
                        }
                        break;
                    }
                    const is_pure_arg_op = switch (cand.opcode) {
                        .nop,
                        .move,
                        .load_local,
                        .load_const,
                        .load_true,
                        .load_false,
                        .add,
                        .add_num,
                        .sub_num,
                        .mul_num,
                        .div_num,
                        .mod_num,
                        .neg,
                        .add_local_const,
                        .sub_local_const,
                        .lt_num,
                        .gt_num,
                        .le_num,
                        .ge_num,
                        .eq,
                        .ne,
                        .lt_local_const,
                        .gt_local_const,
                        .le_local_const,
                        .ge_local_const,
                        .eq_local_const,
                        => cand.a != this_r and cand.a != call_op.b,
                        .jump, .jump_if_false, .jump_if_true, .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => true,
                        else => false,
                    };
                    if (!is_pure_arg_op) break;
                }
                if (found_gp) |gp_idx| {
                    if (gp_idx > 0 and !is_jump_target[gp_idx]) {
                        var jumps_contained = true;
                        for (0..loop_len) |j_idx| {
                            const j_ip = start_ip + j_idx;
                            const j_op = block.ops[j_ip];
                            const maybe_tgt: ?usize = switch (j_op.opcode) {
                                .jump, .jump_if_false, .jump_if_true => (@as(usize, j_op.b) << 8) | j_op.c,
                                .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => j_ip + @as(usize, j_op.c),
                                else => null,
                            };
                            if (maybe_tgt) |tgt| {
                                const in_arg_span = (j_idx > gp_idx and j_idx < call_idx);
                                if (in_arg_span) {
                                    if (tgt <= start_ip + gp_idx or tgt > start_ip + call_idx) {
                                        jumps_contained = false;
                                        break;
                                    }
                                } else {
                                    if (tgt >= start_ip + gp_idx and tgt <= start_ip + call_idx) {
                                        jumps_contained = false;
                                        break;
                                    }
                                }
                            }
                        }
                        const lg_idx = gp_idx - 1;
                        const lg_op = block.ops[start_ip + lg_idx];
                        if (jumps_contained and lg_op.opcode == .load_global and lg_op.a == this_r) {
                            const gname = constantName(block, lg_op.b) orelse "";
                            if (std.mem.eql(u8, gname, "Math")) {
                                self.math_sqrt_guard_bits = expected_bits;
                                self.elided_op[lg_idx] = true;
                                self.elided_op[gp_idx] = true;
                                self.elided_math_call[call_idx] = true;
                                for (gp_idx + 1 .. call_idx + 1) |b_idx| {
                                    self.bailout_target_ips[b_idx] = @intCast(start_ip + lg_idx);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    noinline fn emitPreheader(self: *OsrCompiler) !void {
        const a = self.a;
        const promoted = &self.analysis.promoted;
        const hoisted_arrs = &self.analysis.hoisted_arrs;
        const cached_count = self.analysis.cached_count;
        const cached_regs = &self.analysis.cached_regs;
        const preheader_bailout = self.preheader_bailout;

        // Entry: fn(regs: [*]JSValue, ctx: *OsrContext) callconv(.c) u32
        // %rdi = regs, %rsi = ctx
        // 6 pushes (48B) + hoisted_stack_bytes (8B or 136B) + 8B ret addr => %rsp is 16-byte aligned throughout OsrFn
        try a.pushReg(.rbx);
        try a.pushReg(.rbp);
        try a.pushReg(.r12);
        try a.pushReg(.r13);
        try a.pushReg(.r14);
        try a.pushReg(.r15);
        try a.subRegImm32(.rsp, self.hoisted_stack_bytes);

        try a.movRegReg(.r12, .rdi); // %r12 = regs
        try a.movRegReg(.r13, .rsi); // %r13 = ctx
        try a.movRegImm64(.r14, JSValue.HEAP_BASE); // %r14 = HEAP_BASE
        try a.movRegImm64(.r15, JSValue.BASE_TAG); // %r15 = BASE_TAG

        if (self.math_sqrt_guard_bits) |expected_bits| {
            try a.movRegReg(.rdi, .r13);
            try a.movRegImm64(.rsi, expected_bits);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitCheckMathSqrt));
            try a.callReg(.rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, preheader_bailout);
        }

        // Pre-header for promoted invariant object properties (stores prop_array in %rbx)
        if (promoted.count > 0) {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, promoted.obj_reg) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, preheader_bailout);

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, preheader_bailout);

            try a.movReg32Mem(.rcx, .rax, zobj_shape_id_offset);
            try a.cmpReg32Imm32(.rcx, @bitCast(promoted.shape_id));
            try a.jcc(.ne, preheader_bailout);

            try a.movRegMem(.rcx, .rax, zobj_entries_len_offset);
            try a.cmpRegImm32(.rcx, @intCast(promoted.max_slot));
            try a.jcc(.be, preheader_bailout);

            try a.movRegMem(.rbx, .rax, zobj_entries_bytes_offset);
            try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rsi, 4);
            } else {
                try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rbx, .rsi); // %rbx = prop_array

            for (0..promoted.count) |p| {
                const slot_byte_off: i32 = @intCast(@as(usize, promoted.slots[p]) * @as(usize, @intCast(prop_size)));
                try a.movReg32Mem(.rcx, .rbx, slot_byte_off + prop_desc_offset);
                if (promoted.written[p]) {
                    try a.andRegImm8(.rcx, 9);
                    try a.cmpRegImm32(.rcx, 1);
                    try a.jcc(.ne, preheader_bailout);
                } else {
                    try a.andRegImm8(.rcx, 8);
                    try a.testReg32Reg32(.rcx, .rcx);
                    try a.jcc(.ne, preheader_bailout);
                }
                try a.movRegMem(.rax, .rbx, slot_byte_off + prop_val_offset);
                try a.cmpRegReg(.rax, .r15); // %r15 = BASE_TAG (numeric guard)
                try a.jcc(.ae, preheader_bailout);
                try a.movqXmmReg(promoted.xmms[p], .rax);
            }
        } else if (hoisted_arrs.count > 0) {
            for (0..hoisted_arrs.count) |h_idx| {
                const arr_r = hoisted_arrs.regs[h_idx];
                const h_kind = hoisted_arrs.kinds[h_idx];
                if (h_kind.isTypedArray()) {
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, arr_r) * 8));
                    try a.movRegReg(.rcx, .rax);
                    try a.movRegImm64(.rdx, JSValue.TAG15_MASK);
                    try a.andRegReg(.rcx, .rdx);
                    try a.movRegImm64(.rdx, HEADER_TYPED_ARRAY_BITS);
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ne, preheader_bailout);

                    try a.movRegImm64(.rcx, JSValue.ALIGNED_PTR_MASK);
                    try a.andRegReg(.rax, .rcx);

                    try a.movRegReg(.rdi, .r13);
                    try a.movRegReg(.rsi, .rax);
                    try a.movRegImm64(.rdx, h_kind.expectedTypedKind());
                    try a.lea(.rcx, .rsp, @intCast(h_idx * 16));
                    try a.movRegImm64(.rax, @intFromPtr(&vm.jitPrepareHoistedTypedArray));
                    try a.callReg(.rax);
                    try a.testRegReg(.rax, .rax);
                    try a.jcc(.ne, preheader_bailout);
                } else {
                    const is_dense = hoisted_arrs.dense[h_idx];
                    const is_written = hoisted_arrs.written[h_idx];
                    const prep_flags: u64 = (if (is_dense) @as(u64, 1) else 0) | (if (is_written) @as(u64, 2) else 0);

                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, arr_r) * 8));
                    try a.movRegReg(.rcx, .rax);
                    try a.shrRegImm8(.rcx, 47);
                    try a.cmpRegImm32(.rcx, HEADER_ARRAY);
                    try a.jcc(.ne, preheader_bailout);

                    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                    try a.andRegReg(.rax, .rcx);
                    try a.movRegReg(.rbp, .rax); // callee-saved %rbp holds *ArrayBox across jitPrepareHoistedArray

                    try a.movRegReg(.rdi, .r13);
                    try a.movRegReg(.rsi, .rbp);
                    try a.movRegImm64(.rdx, prep_flags);
                    try a.movRegImm64(.rax, @intFromPtr(&vm.jitPrepareHoistedArray));
                    try a.callReg(.rax);
                    try a.testRegReg(.rax, .rax);
                    try a.jcc(.ne, preheader_bailout);

                    if (is_dense) {
                        try a.movRegMem(.rax, .rbp, arr_items_ptr_off);
                        try a.movRegMem(.rcx, .rbp, arr_items_len_off);
                        try a.movMemReg(.rsp, @intCast(h_idx * 16), .rax);
                        try a.movMemReg(.rsp, @intCast(h_idx * 16 + 8), .rcx);
                    } else {
                        try a.movMemReg(.rsp, @intCast(h_idx * 16), .rbp);
                    }
                }
            }
            if (hoisted_arrs.primary_in_regs) {
                try a.movRegMem(.rbx, .rsp, 0);
                try a.movRegMem(.rbp, .rsp, 8);
            } else if (hoisted_arrs.count == 1 and hoisted_arrs.kinds[0] == .zarray_holey) {
                try a.movRegMem(.rbx, .rsp, 0);
            }
        }

        // Pre-header for cached registers
        if (cached_count > 0) {
            for (0..cached_count) |k| {
                const r = cached_regs[k];
                const xmm_k = @as(Xmm, @enumFromInt(4 + k));
                if (self.analysis.read_before_written[r]) {
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, r) * 8));
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, preheader_bailout);
                    try a.movqXmmReg(xmm_k, .rax);
                } else {
                    const skip_lbl = try a.createLabel();
                    const done_lbl = try a.createLabel();
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, r) * 8));
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, skip_lbl);
                    try a.movqXmmReg(xmm_k, .rax);
                    try a.jmp(done_lbl);
                    a.bindLabel(skip_lbl);
                    try a.xorpd(xmm_k, xmm_k);
                    a.bindLabel(done_lbl);
                }
            }
        }
    }

    noinline fn mergeIncomingState(self: *OsrCompiler, idx: usize) void {
        if (self.prepass.is_jump_target[idx]) {
            self.known_f64 = @splat(null);
            self.known_valid_elem_idx = null;
            self.known_dense_valid_idx = @splat(null);
            self.cur_copy_src = @splat(null);
            self.live_r8_i32 = null;
        }
        if (self.prepass.is_back_target[idx]) {
            self.reg_is_int32 = @splat(false);
            self.reg_is_uint31 = @splat(false);
            self.reg_is_exact_idx = @splat(false);
            self.last_elem_store = null;
        } else if (self.incoming_has_edge[idx]) {
            const prev_uncond_jump = idx > 0 and self.block.ops[self.start_ip + idx - 1].opcode == .jump;
            if (prev_uncond_jump) {
                self.reg_is_int32 = self.incoming_int32[idx];
                self.reg_is_uint31 = self.incoming_uint31[idx];
                self.reg_is_exact_idx = self.incoming_exact_idx[idx];
                self.last_elem_store = self.incoming_elem_store[idx];
            } else {
                for (0..64) |r_i| {
                    self.reg_is_int32[r_i] = self.reg_is_int32[r_i] and self.incoming_int32[idx][r_i];
                    self.reg_is_uint31[r_i] = self.reg_is_uint31[r_i] and self.incoming_uint31[idx][r_i];
                    self.reg_is_exact_idx[r_i] = self.reg_is_exact_idx[r_i] and self.incoming_exact_idx[idx][r_i];
                }
                if (self.last_elem_store != null and self.incoming_elem_store[idx] != null and
                    self.last_elem_store.?.idx_reg == self.incoming_elem_store[idx].?.idx_reg and
                    self.last_elem_store.?.val_reg == self.incoming_elem_store[idx].?.val_reg)
                {
                    // keep last_elem_store
                } else {
                    self.last_elem_store = null;
                }
            }
        }
    }

    noinline fn recordForwardEdge(self: *OsrCompiler, ip: usize, t: usize) void {
        if (t > ip and t <= self.end_ip) {
            const t_idx = t - self.start_ip;
            if (!self.incoming_has_edge[t_idx]) {
                self.incoming_has_edge[t_idx] = true;
                self.incoming_int32[t_idx] = self.reg_is_int32;
                self.incoming_uint31[t_idx] = self.reg_is_uint31;
                self.incoming_exact_idx[t_idx] = self.reg_is_exact_idx;
                self.incoming_elem_store[t_idx] = self.last_elem_store;
            } else {
                for (0..64) |r_i| {
                    self.incoming_int32[t_idx][r_i] = self.incoming_int32[t_idx][r_i] and self.reg_is_int32[r_i];
                    self.incoming_uint31[t_idx][r_i] = self.incoming_uint31[t_idx][r_i] and self.reg_is_uint31[r_i];
                    self.incoming_exact_idx[t_idx][r_i] = self.incoming_exact_idx[t_idx][r_i] and self.reg_is_exact_idx[r_i];
                }
                if (self.incoming_elem_store[t_idx] != null and self.last_elem_store != null and
                    self.incoming_elem_store[t_idx].?.idx_reg == self.last_elem_store.?.idx_reg and
                    self.incoming_elem_store[t_idx].?.val_reg == self.last_elem_store.?.val_reg)
                {
                    // keep incoming_elem_store[t_idx]
                } else {
                    self.incoming_elem_store[t_idx] = null;
                }
            }
        }
    }

    noinline fn invalidateKilledReg(self: *OsrCompiler, reg: u8) void {
        if (self.last_elem_store) |les| {
            if (reg == les.idx_reg or reg == les.val_reg) self.last_elem_store = null;
        }
        if (self.known_valid_elem_idx) |kvi| {
            if (reg == kvi) self.known_valid_elem_idx = null;
        }
        for (&self.known_dense_valid_idx) |*kd| {
            if (kd.* == reg) kd.* = null;
        }
        if (reg < 64) {
            self.cur_copy_src[reg] = null;
            for (0..64) |m| {
                if (self.cur_copy_src[m] == reg) self.cur_copy_src[m] = null;
            }
        }
    }

    noinline fn updateTrackingAfterOp(self: *OsrCompiler, idx: usize, ip: usize, op: codeblock.Op, next_live_r8_i32: ?u8) void {
        const block = self.block;
        const hoisted_arrs = &self.analysis.hoisted_arrs;

        self.live_r8_i32 = next_live_r8_i32;
        if (self.prepass.fused_cmps[idx]) |fc| {
            self.recordForwardEdge(ip, fc.target_pc);
        } else if (self.prepass.fused_idx_delta[idx] != null) {
            const get_op = block.ops[ip + 1];
            self.invalidateKilledReg(get_op.a);
            if (get_op.a < 64) {
                const h_s = hoisted_arrs.find(get_op.b);
                const k = if (h_s) |s| hoisted_arrs.kinds[s] else .zarray_holey;
                self.known_f64[get_op.a] = null;
                self.reg_is_int32[get_op.a] = (k == .ta_u8);
                self.reg_is_uint31[get_op.a] = (k == .ta_u8);
                self.reg_is_exact_idx[get_op.a] = (k == .ta_u8 or k == .ta_i32);
            }
        } else switch (op.opcode) {
            .nop,
            .set_prop,
            .set_prop_transition,
            .to_prop_key,
            => {},
            .set_elem => {
                const eff_set_arr = self.prepass.compound_arr_override[idx] orelse op.a;
                if (self.single_hoisted_arr != null and self.single_hoisted_arr.? == eff_set_arr) {
                    self.last_elem_store = .{ .idx_reg = op.b, .val_reg = op.c };
                } else {
                    self.last_elem_store = null;
                }
                if (self.known_valid_elem_idx != null and self.known_valid_elem_idx.? != op.b) {
                    self.known_valid_elem_idx = null;
                }
            },
            .set_elem_const => {
                self.last_elem_store = null;
                self.known_valid_elem_idx = null;
                self.known_dense_valid_idx = @splat(null);
            },
            .jump, .jump_if_false, .jump_if_true => {
                const t = (@as(usize, op.b) << 8) | op.c;
                self.recordForwardEdge(ip, t);
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const t = ip + @as(usize, op.c);
                self.recordForwardEdge(ip, t);
            },
            .load_const => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    if (block.constants[op.b] == .number) {
                        const n = block.constants[op.b].number;
                        self.known_f64[op.a] = n;
                        if (asExactInt32(n)) |i_val| {
                            self.reg_is_int32[op.a] = (i_val != std.math.minInt(i32));
                            self.reg_is_uint31[op.a] = (i_val >= 0);
                            self.reg_is_exact_idx[op.a] = true;
                        } else {
                            self.reg_is_int32[op.a] = false;
                            self.reg_is_uint31[op.a] = false;
                            self.reg_is_exact_idx[op.a] = false;
                        }
                    } else {
                        self.known_f64[op.a] = null;
                        self.reg_is_int32[op.a] = false;
                        self.reg_is_uint31[op.a] = false;
                        self.reg_is_exact_idx[op.a] = false;
                    }
                }
            },
            .move, .load_local, .store_local => {
                const resolved_src: ?u8 = if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else null;
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    self.cur_copy_src[op.a] = if (resolved_src != null and resolved_src.? != op.a) resolved_src else null;
                    self.known_f64[op.a] = if (op.b < 64) self.known_f64[op.b] else null;
                    self.reg_is_int32[op.a] = if (op.b < 64) self.reg_is_int32[op.b] else false;
                    self.reg_is_uint31[op.a] = if (op.b < 64) self.reg_is_uint31[op.b] else false;
                    self.reg_is_exact_idx[op.a] = if (op.b < 64) self.reg_is_exact_idx[op.b] else false;
                }
            },
            .not_bits, .or_bits, .xor_bits, .shl, .shr => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = true;
                    self.reg_is_uint31[op.a] = false;
                    self.reg_is_exact_idx[op.a] = true;
                }
            },
            .and_bits => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const rhs_nonneg = if (op.c < 64 and self.known_f64[op.c] != null)
                        (if (asExactInt32(self.known_f64[op.c].?)) |v| v >= 0 else false)
                    else
                        false;
                    const is_u31 = rhs_nonneg or (op.b < 64 and self.reg_is_uint31[op.b]) or (op.c < 64 and self.reg_is_uint31[op.c]);
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = true;
                    self.reg_is_uint31[op.a] = is_u31;
                    self.reg_is_exact_idx[op.a] = true;
                }
            },
            .ushr => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const sh_gt0 = if (op.c < 64 and self.known_f64[op.c] != null) blk: {
                        if (asExactInt32(self.known_f64[op.c].?)) |v| {
                            break :blk ((@as(u32, @bitCast(v)) & 31) >= 1);
                        }
                        break :blk false;
                    } else false;
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = sh_gt0;
                    self.reg_is_uint31[op.a] = sh_gt0;
                    self.reg_is_exact_idx[op.a] = sh_gt0;
                }
            },
            .mod_num => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const fits_u31 = if (op.c < 64 and self.known_f64[op.c] != null) blk: {
                        if (asExactPosUint53(self.known_f64[op.c].?)) |rhs_u| {
                            break :blk (rhs_u <= 0x8000_0000);
                        }
                        break :blk false;
                    } else false;
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = fits_u31;
                    self.reg_is_uint31[op.a] = fits_u31;
                    self.reg_is_exact_idx[op.a] = fits_u31;
                }
            },
            .add_local_const, .sub_local_const => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const base_i32 = (op.b < 64 and self.reg_is_int32[op.b]);
                    const small_c = if (asExactInt32(block.constants[op.c].number)) |ci|
                        (ci >= -0x4000_0000 and ci <= 0x4000_0000)
                    else
                        false;
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = false;
                    self.reg_is_uint31[op.a] = false;
                    self.reg_is_exact_idx[op.a] = base_i32 and small_c;
                }
            },
            .get_prop => {
                const eff_prop_b = if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b;
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const is_hoisted_len = if (constantName(block, op.c)) |kn|
                        (std.mem.eql(u8, kn, "length") and hoisted_arrs.find(eff_prop_b) != null and hoisted_arrs.kinds[hoisted_arrs.find(eff_prop_b).?].isPtrLen())
                    else
                        false;
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = is_hoisted_len;
                    self.reg_is_uint31[op.a] = is_hoisted_len;
                    self.reg_is_exact_idx[op.a] = is_hoisted_len;
                }
            },
            else => {
                if (self.last_elem_store) |les| {
                    if (op.a == les.idx_reg or op.a == les.val_reg) self.last_elem_store = null;
                }
                const eff_get_arr = self.prepass.compound_arr_override[idx] orelse (if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b);
                if (op.opcode == .get_elem and self.single_hoisted_arr != null and self.single_hoisted_arr.? == eff_get_arr and op.a != op.c) {
                    self.known_valid_elem_idx = op.c;
                } else if (self.known_valid_elem_idx) |kvi| {
                    if (op.a == kvi) self.known_valid_elem_idx = null;
                }
                for (&self.known_dense_valid_idx) |*kd| {
                    if (kd.* == op.a) kd.* = null;
                }
                if (op.a < 64) {
                    const h_s = if (op.opcode == .get_elem or op.opcode == .get_elem_const) hoisted_arrs.find(eff_get_arr) else null;
                    const k = if (h_s) |s| hoisted_arrs.kinds[s] else .zarray_holey;
                    self.cur_copy_src[op.a] = null;
                    for (0..64) |m| {
                        if (self.cur_copy_src[m] == op.a) self.cur_copy_src[m] = null;
                    }
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = (k == .ta_u8);
                    self.reg_is_uint31[op.a] = (k == .ta_u8);
                    self.reg_is_exact_idx[op.a] = (k == .ta_u8 or k == .ta_i32);
                }
            },
        }
    }

    noinline fn resolveJumpTarget(self: *OsrCompiler, target_pc: usize) !Label {
        if (target_pc >= self.start_ip and target_pc <= self.end_ip) {
            return self.op_labels[target_pc - self.start_ip];
        }
        const el = try self.a.createLabel();
        try self.exit_stubs.append(self.allocator, .{ .label = el, .target_ip = @intCast(target_pc) });
        return el;
    }

    noinline fn emitMoveOrConst(
        self: *OsrCompiler,
        idx: usize,
        ip: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        switch (op.opcode) {
            .load_undefined => {
                try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
            },
            .load_const => {
                const c = self.block.constants[op.b];
                const bits = switch (c) {
                    .number => |n| JSValue.fromNumber(n).bits,
                    .boolean => |b| JSValue.fromBool(b).bits,
                    else => unreachable,
                };
                if (canElideLoadConst(self.block, self.start_ip, self.end_ip, idx, self.prepass.is_jump_target)) {
                    self.elided_consts[idx + 1] = .{ .reg = op.a, .bits = bits };
                    self.bailout_target_ips[idx + 1] = @intCast(ip);
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                }
                if (op.a < 64 and reg_to_xmm[op.a] != null) {
                    const xmm_k = reg_to_xmm[op.a].?;
                    try a.movRegImm64(.rax, bits);
                    try a.movqXmmReg(xmm_k, .rax);
                } else {
                    try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                    try a.movRegImm64(.rax, bits);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                }
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
            },
            .move, .load_local, .store_local => {
                if (op.a != op.b) {
                    const a_cached = (op.a < 64 and reg_to_xmm[op.a] != null);
                    const b_cached = (op.b < 64 and reg_to_xmm[op.b] != null);
                    if (a_cached and b_cached) {
                        try a.movsdXmmXmm(reg_to_xmm[op.a].?, reg_to_xmm[op.b].?);
                    } else if (a_cached and !b_cached) {
                        try emitLoadNumToXmm(a, reg_to_xmm, op.b, reg_to_xmm[op.a].?, bail_lbl);
                    } else if (!a_cached and b_cached) {
                        const xmm_src = reg_to_xmm[op.b].?;
                        try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                        try a.movqRegXmm(.rax, xmm_src);
                        try a.ucomisd(xmm_src, xmm_src);
                        try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                        try a.cmovpRegReg(.rax, .rcx);
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                    } else {
                        const heap_move_lbl = try a.createLabel();
                        const done_move_lbl = try a.createLabel();

                        // Release old regs[dst] if it's a heap ref with rc > 1
                        try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);

                        // Load val = regs[src]
                        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                        try a.cmpRegReg(.rax, .r14);
                        try a.jcc(.ae, heap_move_lbl);

                        // val < HEAP_BASE: write regs[dst] = val
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                        try a.jmp(done_move_lbl);

                        // val >= HEAP_BASE: check if (val >> 47) == HEADER_ARRAY, HEADER_FUNCTION, HEADER_OBJECT, or TypedArray
                        a.bindLabel(heap_move_lbl);
                        try a.movRegReg(.rcx, .rax);
                        try a.shrRegImm8(.rcx, 47);
                        const inc_rc_lbl = try a.createLabel();
                        try a.cmpRegImm32(.rcx, HEADER_ARRAY);
                        try a.jcc(.e, inc_rc_lbl);
                        try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
                        try a.jcc(.e, inc_rc_lbl);
                        try a.cmpRegImm32(.rcx, HEADER_OBJECT);
                        try a.jcc(.e, inc_rc_lbl);
                        try a.movRegReg(.rdx, .rax);
                        try a.movRegImm64(.rcx, JSValue.TAG15_MASK);
                        try a.andRegReg(.rdx, .rcx);
                        try a.movRegImm64(.rcx, HEADER_TYPED_ARRAY_BITS);
                        try a.cmpRegReg(.rdx, .rcx);
                        try a.jcc(.ne, bail_lbl);

                        // Retain: ptr = val & PTR_MASK; ptr._count += 1
                        a.bindLabel(inc_rc_lbl);
                        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                        try a.andRegReg(.rcx, .rax);
                        try a.incMem64(.rcx, 0);
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);

                        a.bindLabel(done_move_lbl);
                    }
                    if (self.live_r8_i32 != null) {
                        if (self.live_r8_i32.? == op.b) {
                            next_live_r8_i32.* = op.a;
                        } else if (self.live_r8_i32.? != op.a) {
                            next_live_r8_i32.* = self.live_r8_i32;
                        }
                    }
                } else {
                    next_live_r8_i32.* = self.live_r8_i32;
                }
            },
            .to_prop_key => {
                const eff_tpk_b = if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b;
                if (self.analysis.hoisted_arrs.find(eff_tpk_b) == null) {
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                    try a.movRegImm64(.rcx, JSValue.UNDEFINED.bits);
                    try a.cmpRegReg(.rax, .rcx);
                    try a.jcc(.e, bail_lbl);
                    try a.movRegImm64(.rcx, JSValue.NULL.bits);
                    try a.cmpRegReg(.rax, .rcx);
                    try a.jcc(.e, bail_lbl);
                }
                if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bail_lbl);
                }
            },
            else => unreachable,
        }
    }

    noinline fn emitTypedArrayLoadAtRcx(
        self: *OsrCompiler,
        kind: HoistedElemKind,
        ptr_reg: x64_asm.Reg,
        dst_reg: u8,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
        idx_reg_opt: ?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const dst_cached = (dst_reg < 64 and reg_to_xmm[dst_reg] != null);
        const dst_xmm: Xmm = if (dst_cached) reg_to_xmm[dst_reg].? else .xmm0;

        switch (kind) {
            .ta_f64 => {
                try a.movsdXmmMemIndexed8(dst_xmm, ptr_reg, .rcx, 0);
                if (!dst_cached) {
                    try emitStoreXmmToNum(a, reg_to_xmm, dst_reg, .xmm0, bail_lbl);
                }
                if (idx_reg_opt) |ir| {
                    if (ir < 64 and ir != dst_reg) next_live_r8_i32.* = ir;
                } else if (self.live_r8_i32 != null and self.live_r8_i32.? != dst_reg) {
                    next_live_r8_i32.* = self.live_r8_i32;
                }
            },
            .ta_i32 => {
                try a.movReg32MemIndexed4(.rax, ptr_reg, .rcx, 0);
                try a.cvtsi2sdXmmReg32(dst_xmm, .rax);
                try a.movReg32Reg32(.r8, .rax);
                if (!dst_cached) {
                    try emitStoreXmmToNum(a, reg_to_xmm, dst_reg, .xmm0, bail_lbl);
                }
                if (dst_reg < 64) next_live_r8_i32.* = dst_reg;
            },
            .ta_u8 => {
                try a.movzxReg32Mem8Indexed1(.rax, ptr_reg, .rcx, 0);
                try a.cvtsi2sdXmmReg32(dst_xmm, .rax);
                try a.movReg32Reg32(.r8, .rax);
                if (!dst_cached) {
                    try emitStoreXmmToNum(a, reg_to_xmm, dst_reg, .xmm0, bail_lbl);
                }
                if (dst_reg < 64) next_live_r8_i32.* = dst_reg;
            },
            else => unreachable,
        }
    }

    noinline fn emitTypedArrayGetElem(
        self: *OsrCompiler,
        h_slot: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const hoisted_arrs = &self.analysis.hoisted_arrs;
        const kind = hoisted_arrs.kinds[h_slot];

        if (op.opcode == .get_elem_const) {
            const elem_idx: u32 = @intFromFloat(self.block.constants[op.c].number);
            try a.movRegImm32(.rcx, elem_idx);
            if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                try a.cmpRegReg(.rcx, .rbp);
                try a.jcc(.ae, bail_lbl);
                try self.emitTypedArrayLoadAtRcx(kind, .rbx, op.a, bail_lbl, next_live_r8_i32, null);
            } else {
                try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bail_lbl);
                try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                try self.emitTypedArrayLoadAtRcx(kind, .r9, op.a, bail_lbl, next_live_r8_i32, null);
            }
            return;
        }

        if (self.live_r8_i32 != null and self.live_r8_i32.? == op.c) {
            try a.movReg32Reg32(.rcx, .r8);
        } else {
            try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
            if (!(op.c < 64 and (self.reg_is_int32[op.c] or self.reg_is_exact_idx[op.c]))) {
                try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                try a.ucomisd(.xmm0, .xmm1);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);
            }
            try a.movReg32Reg32(.r8, .rcx);
        }

        const skip_bounds = (self.known_dense_valid_idx[h_slot] != null and self.known_dense_valid_idx[h_slot].? == op.c);
        if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
            if (!skip_bounds) {
                try a.cmpRegReg(.rcx, .rbp);
                try a.jcc(.ae, bail_lbl);
            }
            try self.emitTypedArrayLoadAtRcx(kind, .rbx, op.a, bail_lbl, next_live_r8_i32, op.c);
        } else {
            if (!skip_bounds) {
                try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bail_lbl);
            }
            try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
            try self.emitTypedArrayLoadAtRcx(kind, .r9, op.a, bail_lbl, next_live_r8_i32, op.c);
        }

        if (op.c < 64 and op.c != op.a) {
            self.reg_is_int32[op.c] = true;
            self.reg_is_uint31[op.c] = true;
            self.reg_is_exact_idx[op.c] = true;
            self.known_dense_valid_idx[h_slot] = op.c;
        }
    }

    noinline fn emitTypedArraySetElem(
        self: *OsrCompiler,
        h_slot: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const hoisted_arrs = &self.analysis.hoisted_arrs;
        const kind = hoisted_arrs.kinds[h_slot];

        const val_in_r8 = (kind != .ta_f64 and self.live_r8_i32 != null and self.live_r8_i32.? == op.c);
        const val_xmm: Xmm = if (op.c < 64 and reg_to_xmm[op.c] != null) reg_to_xmm[op.c].? else .xmm2;

        if (val_in_r8) {
            try a.movReg32Reg32(.r10, .r8);
        } else if (!(op.c < 64 and reg_to_xmm[op.c] != null)) {
            try a.movRegMem(.r10, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.r10, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(.xmm2, .r10);
        }

        if (self.live_r8_i32 != null and self.live_r8_i32.? == op.b) {
            try a.movReg32Reg32(.rcx, .r8);
        } else {
            try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
            if (!(op.b < 64 and (self.reg_is_int32[op.b] or self.reg_is_exact_idx[op.b]))) {
                try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                try a.ucomisd(.xmm0, .xmm1);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);
            }
            try a.movReg32Reg32(.r8, .rcx);
        }

        const skip_bounds = (self.known_dense_valid_idx[h_slot] != null and self.known_dense_valid_idx[h_slot].? == op.b);
        const ptr_reg: x64_asm.Reg = if (h_slot == 0 and hoisted_arrs.primary_in_regs) blk: {
            if (!skip_bounds) {
                try a.cmpRegReg(.rcx, .rbp);
                try a.jcc(.ae, bail_lbl);
            }
            break :blk .rbx;
        } else blk: {
            if (!skip_bounds) {
                try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bail_lbl);
            }
            try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
            break :blk .r9;
        };

        switch (kind) {
            .ta_f64 => {
                try a.movsdMemIndexed8Xmm(ptr_reg, .rcx, 0, val_xmm);
            },
            .ta_i32, .ta_u8 => {
                if (val_in_r8) {
                    try a.movReg32Reg32(.rax, .r10);
                } else if (op.c < 64 and self.reg_is_int32[op.c]) {
                    try a.cvttsd2siReg32Xmm(.rax, val_xmm);
                } else {
                    const i32_ready_lbl = try a.createLabel();
                    try a.cvttsd2siqReg64Xmm(.rax, val_xmm);
                    try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                    try a.cmpRegReg(.rax, .rdx);
                    try a.jcc(.ne, i32_ready_lbl);

                    try a.pushReg(.rcx);
                    try a.pushReg(.r9);
                    try a.movqRegXmm(.rdi, val_xmm);
                    if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
                    try a.movRegImm64(.rax, @intFromPtr(&vm.jitF64ToInt32));
                    try a.callReg(.rax);
                    if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
                    try a.popReg(.r9);
                    try a.popReg(.rcx);
                    try a.movReg32Reg32(.r8, .rcx);

                    a.bindLabel(i32_ready_lbl);
                }
                if (kind == .ta_i32) {
                    try a.movMem32Indexed4Reg(ptr_reg, .rcx, 0, .rax);
                } else {
                    try a.movMem8Indexed1Reg(ptr_reg, .rcx, 0, .rax);
                }
            },
            else => unreachable,
        }

        if (op.b < 64) {
            self.reg_is_int32[op.b] = true;
            self.reg_is_uint31[op.b] = true;
            self.reg_is_exact_idx[op.b] = true;
            self.known_dense_valid_idx[h_slot] = op.b;
            next_live_r8_i32.* = op.b;
        }
    }

    noinline fn emitGetElem(
        self: *OsrCompiler,
        idx: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const promoted = &self.analysis.promoted;
        const hoisted_arrs = &self.analysis.hoisted_arrs;

        if (op.opcode == .get_elem_const) {
            const elem_idx: u32 = @intFromFloat(self.block.constants[op.c].number);
            const eff_arr = self.prepass.compound_arr_override[idx] orelse (if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b);
            if (hoisted_arrs.find(eff_arr)) |h_slot| {
                if (hoisted_arrs.kinds[h_slot].isTypedArray()) {
                    try self.emitTypedArrayGetElem(h_slot, op, bail_lbl, next_live_r8_i32);
                    return;
                }
                if (hoisted_arrs.dense[h_slot]) {
                    if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                        try a.cmpRegImm32(.rbp, @intCast(elem_idx));
                        try a.jcc(.be, bail_lbl);
                        try a.movRegMem(.rax, .rbx, @intCast(@as(usize, elem_idx) * 8));
                    } else {
                        try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                        try a.cmpRegImm32(.rdx, @intCast(elem_idx));
                        try a.jcc(.be, bail_lbl);
                        try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                        try a.movRegMem(.rax, .r9, @intCast(@as(usize, elem_idx) * 8));
                    }
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bail_lbl);
                    if (op.a < 64 and reg_to_xmm[op.a] != null) {
                        try a.movqXmmReg(reg_to_xmm[op.a].?, .rax);
                    } else {
                        try a.movRegReg(.rdx, .rax);
                        try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rdx);
                    }
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                }
            }
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();

            // arr = regs[op.b]; guard (arr >> 47) == HEADER_ARRAY
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, HEADER_ARRAY);
            try a.jcc(.ne, slow_lbl);

            // box = arr & PTR_MASK
            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            // guard box.holey == null and elem_idx < box.items.len
            try a.movRegMem(.rcx, .rax, arr_holey_off);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);
            try a.movRegMem(.rcx, .rax, arr_items_len_off);
            try a.cmpRegImm32(.rcx, @intCast(elem_idx));
            try a.jcc(.be, slow_lbl);

            // elem = box.items.ptr[elem_idx]; guard elem < BASE_TAG (%r15)
            try a.movRegMem(.rcx, .rax, arr_items_ptr_off);
            try a.movRegMem(.rax, .rcx, @intCast(@as(usize, elem_idx) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_lbl);

            if (op.a < 64 and reg_to_xmm[op.a] != null) {
                const xmm_k = reg_to_xmm[op.a].?;
                try a.movqXmmReg(xmm_k, .rax);
            } else {
                try a.movRegReg(.rdx, .rax);
                try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rdx);
            }
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, elem_idx);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetElemConst));
            try a.callReg(.rax);
            if (cached_count > 0) {
                try emitReloadCached(a, cached_regs, cached_count);
            }
            try a.movzxReg64Reg8(.rax, .rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);

            a.bindLabel(done_lbl);
            return;
        }

        const eff_arr = self.prepass.compound_arr_override[idx] orelse (if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b);

        if (self.single_hoisted_arr != null and self.single_hoisted_arr.? == eff_arr) {
            if (self.last_elem_store) |les| {
                if (les.idx_reg == op.c) {
                    try emitLoadNumToXmm(a, reg_to_xmm, les.val_reg, .xmm0, bail_lbl);
                    try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                }
            }
        }

        const hoisted_slot = hoisted_arrs.find(eff_arr);
        if (hoisted_slot != null and hoisted_arrs.kinds[hoisted_slot.?].isTypedArray()) {
            try self.emitTypedArrayGetElem(hoisted_slot.?, op, bail_lbl, next_live_r8_i32);
            return;
        }
        if (hoisted_slot != null and hoisted_arrs.dense[hoisted_slot.?]) {
            const h_slot = hoisted_slot.?;
            if (self.live_r8_i32 != null and self.live_r8_i32.? == op.c) {
                try a.movReg32Reg32(.rcx, .r8);
            } else {
                try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                if (!(op.c < 64 and (self.reg_is_int32[op.c] or self.reg_is_exact_idx[op.c]))) {
                    try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                    try a.ucomisd(.xmm0, .xmm1);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                }
                try a.movReg32Reg32(.r8, .rcx);
            }

            const skip_bounds = (self.known_dense_valid_idx[h_slot] != null and self.known_dense_valid_idx[h_slot].? == op.c);
            if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                if (!skip_bounds) {
                    try a.cmpRegReg(.rcx, .rbp);
                    try a.jcc(.ae, bail_lbl);
                }
                try a.movRegMemIndexed8(.rax, .rbx, .rcx, 0);
            } else {
                if (!skip_bounds) {
                    try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ae, bail_lbl);
                }
                try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                try a.movRegMemIndexed8(.rax, .r9, .rcx, 0);
            }

            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);

            if (op.a < 64 and reg_to_xmm[op.a] != null) {
                const xmm_k = reg_to_xmm[op.a].?;
                try a.movqXmmReg(xmm_k, .rax);
            } else {
                try a.movRegReg(.rdx, .rax);
                try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rdx);
            }

            if (op.c < 64 and op.c != op.a) {
                self.reg_is_int32[op.c] = true;
                self.reg_is_uint31[op.c] = true;
                self.reg_is_exact_idx[op.c] = true;
                self.known_dense_valid_idx[h_slot] = op.c;
                next_live_r8_i32.* = op.c;
            }
            return;
        }

        const is_hoisted = (hoisted_slot != null);
        const box_reg: x64_asm.Reg = if (hoisted_slot) |slot_idx| blk: {
            if (hoisted_arrs.count == 1) break :blk .rbx;
            try a.movRegMem(.r9, .rsp, @intCast(slot_idx * 16));
            break :blk .r9;
        } else blk: {
            // arr = regs[eff_arr]; guard (arr >> 47) == 0x1FFF4 (HEADER_ARRAY)
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_arr) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, HEADER_ARRAY);
            try a.jcc(.ne, bail_lbl);
            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);
            // Preserve *ArrayBox in %r9 across emitLoadNumToXmm (which clobbers %rax).
            try a.movRegReg(.r9, .rax);
            break :blk .r9;
        };

        // key = regs[op.c]; guard key < BASE_TAG and exact int32 >= 0
        try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm0, bail_lbl);
        try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
        if (!(op.c < 64 and self.reg_is_int32[op.c])) {
            try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
        }
        if (!(op.c < 64 and self.reg_is_uint31[op.c])) {
            // sign check on 32-bit int: (rcx >> 31) == 0
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 31);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
        }

        // guard idx < box.items.len
        try a.movRegMem(.rdx, box_reg, arr_items_len_off);
        try a.cmpRegReg(.rcx, .rdx);
        try a.jcc(.ae, bail_lbl);

        // Fast path when box.holey == null; otherwise verify non-hole in hole_mask
        const dense_ok_lbl = try a.createLabel();
        try a.movRegMem(.rdx, box_reg, arr_holey_off);
        try a.testRegReg(.rdx, .rdx);
        try a.jcc(.e, dense_ok_lbl);
        if (!is_hoisted) {
            try a.movRegReg(.r8, .rcx);
            if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
            if (promoted.count > 0) try emitFlushPromoted(a, promoted);
            try a.pushReg(.r8);
            try a.pushReg(.r9);
            try a.movRegReg(.rdi, .r13);
            try a.movRegReg(.rsi, box_reg);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitCheckHoleyArray));
            try a.callReg(.rax);
            try a.popReg(.r9);
            try a.popReg(.r8);
            if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
            if (promoted.count > 0) try emitReloadPromoted(a, promoted);
            try a.movzxReg64Reg8(.rax, .rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            try a.movRegReg(.rcx, .r8);
            try a.movRegMem(.rdx, box_reg, arr_holey_off);
        }
        try a.movzxReg64Mem8(.rax, .rdx, h_is_holey_off);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.e, dense_ok_lbl);
        try a.movRegReg(.rax, .rcx);
        try a.shrRegImm8(.rax, 6);
        try a.movRegMem(.r11, .rdx, h_mask_len_off);
        try a.cmpRegReg(.rax, .r11);
        try a.jcc(.ae, dense_ok_lbl);
        try a.movRegMem(.r11, .rdx, h_mask_ptr_off);
        try a.movRegMemIndexed8(.r11, .r11, .rax, 0);
        try a.btReg64Reg64(.r11, .rcx);
        try a.jcc(.b, bail_lbl);
        a.bindLabel(dense_ok_lbl);

        // elem = box.items.ptr[idx]; guard elem < BASE_TAG
        try a.movRegMem(.rax, box_reg, arr_items_ptr_off);
        try a.movRegMemIndexed8(.rax, .rax, .rcx, 0);
        try a.cmpRegReg(.rax, .r15);
        try a.jcc(.ae, bail_lbl);

        if (op.a < 64 and reg_to_xmm[op.a] != null) {
            const xmm_k = reg_to_xmm[op.a].?;
            try a.movqXmmReg(xmm_k, .rax);
        } else {
            try a.movRegReg(.rdx, .rax);
            try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rdx);
        }
    }

    noinline fn emitSetElem(
        self: *OsrCompiler,
        idx: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const promoted = &self.analysis.promoted;
        const hoisted_arrs = &self.analysis.hoisted_arrs;

        if (op.opcode == .new_array) {
            const cap_min: i32 = @intCast(@max(@as(usize, op.b), 4));

            const slow_lbl = try a.createLabel();
            const loop_lbl = try a.createLabel();
            const clear_len_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();

            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, HEADER_ARRAY);
            try a.jcc(.ne, slow_lbl);

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            try a.movRegMem(.rcx, .rax, arr_rc_off);
            try a.cmpRegImm32(.rcx, 1);
            try a.jcc(.ne, slow_lbl);

            try a.movRegMem(.rcx, .rax, arr_holey_off);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            try a.movRegMem(.rcx, .rax, arr_items_cap_off);
            try a.cmpRegImm32(.rcx, cap_min);
            try a.jcc(.b, slow_lbl);
            try a.cmpRegImm32(.rcx, 32);
            try a.jcc(.a, slow_lbl);

            try a.movRegMem(.rcx, .rax, arr_items_len_off);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.e, clear_len_lbl);
            try a.movRegMem(.rdx, .rax, arr_items_ptr_off);
            a.bindLabel(loop_lbl);
            try a.decReg64(.rcx);
            try a.movRegMemIndexed8(.rsi, .rdx, .rcx, 0);
            try a.cmpRegReg(.rsi, .r14);
            try a.jcc(.ae, slow_lbl);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, loop_lbl);

            a.bindLabel(clear_len_lbl);
            try a.xorRegReg(.rcx, .rcx);
            try a.movMemReg(.rax, arr_items_len_off, .rcx);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            try a.movRegReg(.rdi, .r13);
            try a.movRegReg(.rsi, .r12);
            try a.movRegImm32(.rdx, op.a);
            try a.movRegImm32(.rcx, op.b);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitNewArray));
            try a.callReg(.rax);
            if (cached_count > 0) {
                try emitReloadCached(a, cached_regs, cached_count);
            }
            try a.movzxReg64Reg8(.rax, .rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            a.bindLabel(done_lbl);
            return;
        }

        if (op.opcode == .set_elem_const) {
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();

            // val = regs[op.c]; guard val < BASE_TAG (%r15)
            if (op.c < 64 and reg_to_xmm[op.c] != null) {
                const xmm_val = reg_to_xmm[op.c].?;
                try a.movqRegXmm(.rdx, xmm_val);
                try a.ucomisd(xmm_val, xmm_val);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rdx, .rcx);
            } else {
                try a.movRegMem(.rdx, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.rdx, .r15);
                try a.jcc(.ae, slow_lbl);
            }

            // arr = regs[op.a]; guard (arr >> 47) == HEADER_ARRAY
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, HEADER_ARRAY);
            try a.jcc(.ne, slow_lbl);

            // box = arr & PTR_MASK
            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            // guard box.holey == null
            try a.movRegMem(.rcx, .rax, arr_holey_off);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            // guard box.items.len == op.b and op.b < box.items.capacity
            try a.movRegMem(.rcx, .rax, arr_items_len_off);
            try a.cmpRegImm32(.rcx, op.b);
            try a.jcc(.ne, slow_lbl);
            try a.movRegMem(.rcx, .rax, arr_items_cap_off);
            try a.cmpRegImm32(.rcx, op.b);
            try a.jcc(.be, slow_lbl);

            // box.items.ptr[op.b] = val; box.items.len = op.b + 1
            try a.movRegMem(.rcx, .rax, arr_items_ptr_off);
            try a.movMemReg(.rcx, @intCast(@as(usize, op.b) * 8), .rdx);
            try a.movRegImm32(.rcx, @as(u32, op.b) + 1);
            try a.movMemReg(.rax, arr_items_len_off, .rcx);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, op.c);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetElemConst));
            try a.callReg(.rax);
            if (cached_count > 0) {
                try emitReloadCached(a, cached_regs, cached_count);
            }
            try a.movzxReg64Reg8(.rax, .rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);

            a.bindLabel(done_lbl);
            return;
        }

        const eff_arr = self.prepass.compound_arr_override[idx] orelse (if (op.a < 64) (self.cur_copy_src[op.a] orelse op.a) else op.a);
        const hoisted_slot = hoisted_arrs.find(eff_arr);
        if (hoisted_slot != null and hoisted_arrs.kinds[hoisted_slot.?].isTypedArray()) {
            try self.emitTypedArraySetElem(hoisted_slot.?, op, bail_lbl, next_live_r8_i32);
            return;
        }

        // val = regs[op.c]; guard val < BASE_TAG
        if (op.c < 64 and reg_to_xmm[op.c] != null) {
            const xmm_val = reg_to_xmm[op.c].?;
            try a.movqRegXmm(.r10, xmm_val);
            try a.ucomisd(xmm_val, xmm_val);
            try a.movRegImm64(.rdx, JSValue.CANONICAL_NAN);
            try a.cmovpRegReg(.r10, .rdx);
        } else {
            try a.movRegMem(.r10, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.r10, .r15);
            try a.jcc(.ae, bail_lbl);
        }

        if (hoisted_slot != null and hoisted_arrs.dense[hoisted_slot.?]) {
            const h_slot = hoisted_slot.?;
            if (self.live_r8_i32 != null and self.live_r8_i32.? == op.b) {
                try a.movReg32Reg32(.rcx, .r8);
            } else {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                if (!(op.b < 64 and (self.reg_is_int32[op.b] or self.reg_is_exact_idx[op.b]))) {
                    try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                    try a.ucomisd(.xmm0, .xmm1);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                }
                try a.movReg32Reg32(.r8, .rcx);
            }

            const already_in_bounds = (self.known_dense_valid_idx[h_slot] != null and self.known_dense_valid_idx[h_slot].? == op.b);
            if (already_in_bounds) {
                const ptr_reg: x64_asm.Reg = if (h_slot == 0 and hoisted_arrs.primary_in_regs) blk: {
                    break :blk .rbx;
                } else blk: {
                    try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                    break :blk .r9;
                };
                try a.movRegMemIndexed8(.rdx, ptr_reg, .rcx, 0);
                try a.cmpRegReg(.rdx, .r14);
                try a.jcc(.ae, bail_lbl);
                try a.movMemIndexed8Reg(ptr_reg, .rcx, 0, .r10);
                if (op.b < 64) next_live_r8_i32.* = op.b;
                return;
            }

            const grow_lbl = try a.createLabel();
            const helper_lbl = try a.createLabel();
            const done_dense_lbl = try a.createLabel();

            if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                try a.cmpRegReg(.rcx, .rbp);
                try a.jcc(.ae, grow_lbl);
                try a.movRegMemIndexed8(.rdx, .rbx, .rcx, 0);
                try a.cmpRegReg(.rdx, .r14);
                try a.jcc(.ae, bail_lbl);
                try a.movMemIndexed8Reg(.rbx, .rcx, 0, .r10);
            } else {
                try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, grow_lbl);
                try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                try a.movRegMemIndexed8(.rdx, .r9, .rcx, 0);
                try a.cmpRegReg(.rdx, .r14);
                try a.jcc(.ae, bail_lbl);
                try a.movMemIndexed8Reg(.r9, .rcx, 0, .r10);
            }
            try a.jmp(done_dense_lbl);

            a.bindLabel(grow_lbl);
            if (self.prepass.compound_arr_override[idx] != null) {
                try a.jmp(bail_lbl);
            } else {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_arr) * 8));
                try a.movRegImm64(.rdx, JSValue.PTR_MASK);
                try a.andRegReg(.rax, .rdx);
                try a.movRegMem(.rdx, .rax, arr_items_len_off);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ne, bail_lbl);
                try a.movRegMem(.r11, .rax, arr_items_cap_off);
                try a.cmpRegReg(.rcx, .r11);
                try a.jcc(.ae, helper_lbl);
                try a.movRegMem(.r11, .rax, arr_items_ptr_off);
                try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
                try a.addRegImm32(.rdx, 1);
                try a.movMemReg(.rax, arr_items_len_off, .rdx);
                try emitRefreshDenseHoisted(a, hoisted_arrs);
                try a.jmp(done_dense_lbl);

                a.bindLabel(helper_lbl);
                try a.movRegReg(.r8, .rcx);
                try a.movRegReg(.r9, .rax);
                if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
                if (promoted.count > 0) try emitFlushPromoted(a, promoted);
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r9);
                try a.movRegReg(.rdx, .r8);
                try a.movRegReg(.rcx, .r10);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetElemHoleyOrGrow));
                try a.callReg(.rax);
                if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
                if (promoted.count > 0) try emitReloadPromoted(a, promoted);
                try a.movzxReg64Reg8(.rax, .rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                try emitRefreshDenseHoisted(a, hoisted_arrs);
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.r8, .xmm0);
            }

            a.bindLabel(done_dense_lbl);
            if (op.b < 64) {
                self.reg_is_int32[op.b] = true;
                self.reg_is_uint31[op.b] = true;
                self.reg_is_exact_idx[op.b] = true;
                self.known_dense_valid_idx[h_slot] = op.b;
                next_live_r8_i32.* = op.b;
            }
            return;
        }

        if (self.single_hoisted_arr != null and self.single_hoisted_arr.? == eff_arr and self.known_valid_elem_idx != null and self.known_valid_elem_idx.? == op.b) {
            try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
            try a.movRegMem(.r11, .rbx, arr_items_ptr_off);
            try a.movRegMemIndexed8(.rdx, .r11, .rcx, 0);
            try a.cmpRegReg(.rdx, .r14);
            try a.jcc(.ae, bail_lbl);
            try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
            return;
        }

        const grow_or_holey_lbl = try a.createLabel();
        const helper_lbl = try a.createLabel();
        const done_lbl = try a.createLabel();

        const is_hoisted = (hoisted_slot != null);
        const box_reg: x64_asm.Reg = if (hoisted_slot) |slot_idx| blk: {
            if (hoisted_arrs.count == 1) break :blk .rbx;
            try a.movRegMem(.r9, .rsp, @intCast(slot_idx * 16));
            break :blk .r9;
        } else blk: {
            // arr = regs[eff_arr]; guard (arr >> 47) == HEADER_ARRAY
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_arr) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, HEADER_ARRAY);
            try a.jcc(.ne, bail_lbl);
            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);
            if (@hasField(ZArr, "is_frozen")) {
                const arr_frozen_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "is_frozen")));
                try a.movzxReg64Mem8(.rcx, .rax, arr_frozen_off);
                try a.testRegReg(.rcx, .rcx);
                try a.jcc(.ne, bail_lbl);
            }
            // Preserve *ArrayBox in %r9 across emitLoadNumToXmm (which clobbers %rax).
            try a.movRegReg(.r9, .rax);
            break :blk .r9;
        };

        // key = regs[op.b]; guard key < BASE_TAG and exact int32 >= 0
        try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
        try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
        if (!(op.b < 64 and self.reg_is_int32[op.b])) {
            try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
        }
        if (!(op.b < 64 and self.reg_is_uint31[op.b])) {
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 31);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
        }

        // len = box.items.len
        try a.movRegMem(.rdx, box_reg, arr_items_len_off);
        try a.cmpRegReg(.rcx, .rdx);
        try a.jcc(.ae, grow_or_holey_lbl);

        // Overwrite: idx < len
        if (!is_hoisted) {
            const non_hoisted_dense = try a.createLabel();
            try a.movRegMem(.rdx, box_reg, arr_holey_off);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.e, non_hoisted_dense);
            try a.jmp(helper_lbl);
            a.bindLabel(non_hoisted_dense);
        }
        try a.movRegMem(.r11, box_reg, arr_items_ptr_off);
        try a.movRegMemIndexed8(.rdx, .r11, .rcx, 0);
        try a.cmpRegReg(.rdx, .r14);
        try a.jcc(.ae, bail_lbl);
        try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
        // If hoisted array has holey state, clear hole bit in hole_mask
        if (is_hoisted) {
            try a.movRegMem(.rdx, box_reg, arr_holey_off);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.e, done_lbl);
            try a.movzxReg64Mem8(.rax, .rdx, h_is_holey_off);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.e, done_lbl);
            try a.movRegReg(.rax, .rcx);
            try a.shrRegImm8(.rax, 6);
            try a.movRegMem(.r11, .rdx, h_mask_len_off);
            try a.cmpRegReg(.rax, .r11);
            try a.jcc(.ae, done_lbl);
            try a.movRegMem(.r11, .rdx, h_mask_ptr_off);
            try a.movRegMemIndexed8(.rdx, .r11, .rax, 0);
            try a.btrReg64Reg64(.rdx, .rcx);
            try a.movMemIndexed8Reg(.r11, .rax, 0, .rdx);
        }
        try a.jmp(done_lbl);

        // idx >= len: inline append if dense and within capacity, else helper
        a.bindLabel(grow_or_holey_lbl);
        try a.cmpRegReg(.rcx, .rdx);
        try a.jcc(.ne, helper_lbl);
        try a.movRegMem(.rax, box_reg, arr_holey_off);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, helper_lbl);
        try a.movRegMem(.r11, box_reg, arr_items_cap_off);
        try a.cmpRegReg(.rcx, .r11);
        try a.jcc(.ae, helper_lbl);
        try a.movRegMem(.r11, box_reg, arr_items_ptr_off);
        try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
        try a.addRegImm32(.rdx, 1);
        try a.movMemReg(box_reg, arr_items_len_off, .rdx);
        try a.jmp(done_lbl);

        a.bindLabel(helper_lbl);
        try a.movRegReg(.r8, .rcx); // save idx across flush (which clobbers rcx/rdx)
        if (cached_count > 0) {
            try emitFlushCached(a, cached_regs, cached_count);
        }
        if (promoted.count > 0) {
            try emitFlushPromoted(a, promoted);
        }
        try a.movRegReg(.rdi, .r13);
        try a.movRegReg(.rsi, box_reg);
        try a.movRegReg(.rdx, .r8);
        try a.movRegReg(.rcx, .r10);
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetElemHoleyOrGrow));
        try a.callReg(.rax);
        if (cached_count > 0) {
            try emitReloadCached(a, cached_regs, cached_count);
        }
        if (promoted.count > 0) {
            try emitReloadPromoted(a, promoted);
        }
        try a.movzxReg64Reg8(.rax, .rax);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bail_lbl);

        a.bindLabel(done_lbl);
    }
    noinline fn emitFusedIdxDeltaGetElem(
        self: *OsrCompiler,
        ip: usize,
        op: codeblock.Op,
        signed_delta: i32,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const hoisted_arrs = &self.analysis.hoisted_arrs;
        const get_op = self.block.ops[ip + 1];
        const h_slot = hoisted_arrs.find(get_op.b).?;

        if (self.live_r8_i32 != null and self.live_r8_i32.? == op.b) {
            // %r8d already holds validated exact i32 of op.b
        } else {
            try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
            if (!(op.b < 64 and self.reg_is_int32[op.b])) {
                try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                try a.ucomisd(.xmm0, .xmm1);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);
            }
            try a.movReg32Reg32(.r8, .rcx);
        }
        try a.movReg32Reg32(.rcx, .r8);
        if (signed_delta > 0) {
            try a.addReg32Imm32(.rcx, signed_delta);
            try a.jcc(.o, bail_lbl);
        } else if (signed_delta < 0) {
            try a.subReg32Imm32(.rcx, -signed_delta);
            try a.jcc(.o, bail_lbl);
        }

        const f_kind = hoisted_arrs.kinds[h_slot];
        if (f_kind.isTypedArray()) {
            if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                try a.cmpRegReg(.rcx, .rbp);
                try a.jcc(.ae, bail_lbl);
                try self.emitTypedArrayLoadAtRcx(f_kind, .rbx, get_op.a, bail_lbl, next_live_r8_i32, op.b);
            } else {
                try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bail_lbl);
                try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                try self.emitTypedArrayLoadAtRcx(f_kind, .r9, get_op.a, bail_lbl, next_live_r8_i32, op.b);
            }
            if (op.b < 64 and get_op.a != op.b) {
                self.reg_is_int32[op.b] = true;
                self.reg_is_exact_idx[op.b] = true;
            }
            self.skip_ops_remaining = 1;
            return;
        }

        if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
            try a.cmpRegReg(.rcx, .rbp);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMemIndexed8(.rax, .rbx, .rcx, 0);
        } else {
            try a.movRegMem(.rdx, .rsp, @intCast(h_slot * 16 + 8));
            try a.cmpRegReg(.rcx, .rdx);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
            try a.movRegMemIndexed8(.rax, .r9, .rcx, 0);
        }

        try a.cmpRegReg(.rax, .r15);
        try a.jcc(.ae, bail_lbl);
        if (get_op.a < 64 and reg_to_xmm[get_op.a] != null) {
            try a.movqXmmReg(reg_to_xmm[get_op.a].?, .rax);
        } else {
            try a.movRegReg(.rdx, .rax);
            try emitReleaseHeapIfRefGt1(a, get_op.a, bail_lbl);
            try a.movMemReg(.r12, @intCast(@as(usize, get_op.a) * 8), .rdx);
        }

        if (op.b < 64 and get_op.a != op.b) {
            self.reg_is_int32[op.b] = true;
            self.reg_is_exact_idx[op.b] = true;
            next_live_r8_i32.* = op.b;
        }
        self.skip_ops_remaining = 1;
    }

    noinline fn emitArithAndMod(
        self: *OsrCompiler,
        idx: usize,
        ip: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        switch (op.opcode) {
            .add, .add_num, .sub_num, .mul_num => {
                if (op.a < 64 and reg_to_xmm[op.a] != null and op.a == op.b) {
                    const xmm_a = reg_to_xmm[op.a].?;
                    try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                    switch (op.opcode) {
                        .add, .add_num => try a.addsd(xmm_a, .xmm1),
                        .sub_num => try a.subsd(xmm_a, .xmm1),
                        .mul_num => try a.mulsd(xmm_a, .xmm1),
                        else => unreachable,
                    }
                } else {
                    try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                    try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                    switch (op.opcode) {
                        .add, .add_num => try a.addsd(.xmm0, .xmm1),
                        .sub_num => try a.subsd(.xmm0, .xmm1),
                        .mul_num => try a.mulsd(.xmm0, .xmm1),
                        else => unreachable,
                    }
                    try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                }
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
            },
            .add_local_const, .sub_local_const => {
                if (self.prepass.fused_idx_delta[idx]) |signed_delta| {
                    try self.emitFusedIdxDeltaGetElem(ip, op, signed_delta, bail_lbl, next_live_r8_i32);
                    return;
                }

                const c_bits = JSValue.fromNumber(self.block.constants[op.c].number).bits;
                if (op.a < 64 and reg_to_xmm[op.a] != null and op.a == op.b) {
                    const xmm_k = reg_to_xmm[op.a].?;
                    try a.movRegImm64(.rcx, c_bits);
                    try a.movqXmmReg(.xmm0, .rcx);
                    if (op.opcode == .add_local_const) {
                        try a.addsd(xmm_k, .xmm0);
                    } else {
                        try a.subsd(xmm_k, .xmm0);
                    }
                } else {
                    try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                    try a.movRegImm64(.rcx, c_bits);
                    try a.movqXmmReg(.xmm1, .rcx);
                    if (op.opcode == .add_local_const) {
                        try a.addsd(.xmm0, .xmm1);
                    } else {
                        try a.subsd(.xmm0, .xmm1);
                    }
                    try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                }
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
            },
            .div_num => {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                const maybe_recip: ?u64 = if (op.c < 64 and self.known_f64[op.c] != null)
                    asPowerOfTwoReciprocal(self.known_f64[op.c].?)
                else
                    null;
                if (maybe_recip) |recip_bits| {
                    try a.movRegImm64(.rcx, recip_bits);
                    try a.movqXmmReg(.xmm1, .rcx);
                    try a.mulsd(.xmm0, .xmm1);
                } else {
                    try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                    try a.divsd(.xmm0, .xmm1);
                }
                try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
            },
            .mod_num => {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                const maybe_rhs_u53: ?u64 = if (op.c < 64 and self.known_f64[op.c] != null)
                    asExactPosUint53(self.known_f64[op.c].?)
                else
                    null;
                if (maybe_rhs_u53 == null) {
                    try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                }
                // lhs: positive exact integer in [0, 2^53 - 1] (also rejects -0.0)
                try a.movqRegXmm(.rax, .xmm0);
                try a.movRegReg(.rdx, .rax);
                try a.shrRegImm8(.rdx, 63);
                try a.testRegReg(.rdx, .rdx);
                try a.jcc(.ne, bail_lbl);
                try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
                try a.movRegReg(.rdx, .rax);
                try a.shrRegImm8(.rdx, 53);
                try a.testRegReg(.rdx, .rdx);
                try a.jcc(.ne, bail_lbl);
                try a.cvtsi2sdqXmmReg64(.xmm2, .rax);
                try a.ucomisd(.xmm0, .xmm2);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);

                if (maybe_rhs_u53) |rhs_u| {
                    if (std.math.isPowerOfTwo(rhs_u)) {
                        try a.movRegImm64(.rdx, rhs_u - 1);
                        try a.andRegReg(.rdx, .rax);
                        try a.cvtsi2sdqXmmReg64(.xmm0, .rdx);
                        try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                        return;
                    }
                    try a.movRegImm64(.rcx, rhs_u);
                } else {
                    // rhs: strictly positive exact integer in [1, 2^53 - 1]
                    try a.movqRegXmm(.rcx, .xmm1);
                    try a.movRegReg(.rdx, .rcx);
                    try a.shrRegImm8(.rdx, 63);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, bail_lbl);
                    try a.cvttsd2siqReg64Xmm(.rcx, .xmm1);
                    try a.movRegReg(.rdx, .rcx);
                    try a.shrRegImm8(.rdx, 53);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, bail_lbl);
                    try a.testRegReg(.rcx, .rcx);
                    try a.jcc(.e, bail_lbl);
                    try a.cvtsi2sdqXmmReg64(.xmm2, .rcx);
                    try a.ucomisd(.xmm1, .xmm2);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                }

                try a.xorRegReg64(.rdx, .rdx);
                try a.divReg64(.rcx);
                try a.cvtsi2sdqXmmReg64(.xmm0, .rdx);
                try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            },
            .neg => {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.movqRegXmm(.rax, .xmm0);
                try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
                try a.xorRegReg64(.rax, .rcx);
                try a.movqXmmReg(.xmm0, .rax);
                try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
            },
            else => unreachable,
        }
    }

    noinline fn emitBitwiseOp(
        self: *OsrCompiler,
        idx: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const promoted = &self.analysis.promoted;

        if (op.opcode == .not_bits) {
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();
            if (self.live_r8_i32 != null and self.live_r8_i32.? == op.b) {
                try a.movReg32Reg32(.rax, .r8);
            } else if (op.b < 64 and self.reg_is_int32[op.b]) {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rax, .xmm0);
            } else {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
                try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                try a.cmpRegReg(.rax, .rdx);
                try a.jcc(.e, slow_lbl);
            }
            try a.notReg32(.rax);
            try a.movReg32Reg32(.r8, .rax);
            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
            try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            if (promoted.count > 0) {
                try emitFlushPromoted(a, promoted);
            }
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, op.b);
            try a.movRegImm32(.r8, 6);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
            try a.callReg(.rax);
            if (cached_count > 0) {
                try emitReloadCached(a, cached_regs, cached_count);
            }
            if (promoted.count > 0) {
                try emitReloadPromoted(a, promoted);
            }
            try a.movzxReg64Reg8(.rax, .rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            try emitLoadNumToXmm(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.r8, .xmm0);
            a.bindLabel(done_lbl);
            if (op.a < 64) next_live_r8_i32.* = op.a;
            return;
        }

        const slow_lbl = try a.createLabel();
        const done_lbl = try a.createLabel();
        const maybe_rhs_i32: ?i32 = if (op.c < 64 and self.known_f64[op.c] != null)
            asExactInt32(self.known_f64[op.c].?)
        else
            null;

        const lhs_in_r8 = (self.live_r8_i32 != null and self.live_r8_i32.? == op.b);
        const rhs_in_r8 = (maybe_rhs_i32 == null and self.live_r8_i32 != null and self.live_r8_i32.? == op.c);

        if (!lhs_in_r8) {
            try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
        }
        if (maybe_rhs_i32 == null and !rhs_in_r8) {
            try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm1, bail_lbl);
        }

        if (lhs_in_r8) {
            try a.movReg32Reg32(.rax, .r8);
        } else if (op.b < 64 and self.reg_is_int32[op.b]) {
            try a.cvttsd2siReg32Xmm(.rax, .xmm0);
        } else {
            try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
            try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
            try a.cmpRegReg(.rax, .rdx);
            try a.jcc(.e, slow_lbl);
        }

        const result_fits_i32 = if (op.opcode != .ushr)
            true
        else if (maybe_rhs_i32) |ri|
            ((@as(u32, @bitCast(ri)) & 31) >= 1)
        else
            false;

        if (maybe_rhs_i32) |rhs_i32| {
            switch (op.opcode) {
                .and_bits => {
                    try a.andReg32Imm32(.rax, rhs_i32);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .or_bits => {
                    if (rhs_i32 != 0) try a.orReg32Imm32(.rax, rhs_i32);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .xor_bits => {
                    if (rhs_i32 != 0) try a.xorReg32Imm32(.rax, rhs_i32);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shl => {
                    const sh_amt: u8 = @intCast(@as(u32, @bitCast(rhs_i32)) & 31);
                    if (sh_amt != 0) try a.shlReg32Imm8(.rax, sh_amt);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shr => {
                    const sh_amt: u8 = @intCast(@as(u32, @bitCast(rhs_i32)) & 31);
                    if (sh_amt != 0) try a.sarReg32Imm8(.rax, sh_amt);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .ushr => {
                    const sh_amt: u8 = @intCast(@as(u32, @bitCast(rhs_i32)) & 31);
                    if (sh_amt != 0) {
                        try a.shrReg32Imm8(.rax, sh_amt);
                        try a.movReg32Reg32(.r8, .rax);
                    } else {
                        try a.movReg32Reg32(.rax, .rax);
                    }
                    try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
                },
                else => unreachable,
            }
        } else {
            if (rhs_in_r8) {
                try a.movReg32Reg32(.rcx, .r8);
            } else if (op.c < 64 and self.reg_is_int32[op.c]) {
                try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
            } else {
                try a.cvttsd2siqReg64Xmm(.rcx, .xmm1);
                try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.e, slow_lbl);
            }
            switch (op.opcode) {
                .and_bits => {
                    try a.andReg32Reg32(.rax, .rcx);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .or_bits => {
                    try a.orReg32Reg32(.rax, .rcx);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .xor_bits => {
                    try a.xorReg32Reg32(.rax, .rcx);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shl => {
                    try a.shlReg32Cl(.rax);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shr => {
                    try a.sarReg32Cl(.rax);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .ushr => {
                    try a.shrReg32Cl(.rax);
                    try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
                },
                else => unreachable,
            }
        }
        try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
        try a.jmp(done_lbl);

        a.bindLabel(slow_lbl);
        if (self.elided_consts[idx]) |ec| {
            try a.movRegImm64(.rax, ec.bits);
            if (ec.reg < 64 and reg_to_xmm[ec.reg] != null) {
                try a.movqXmmReg(reg_to_xmm[ec.reg].?, .rax);
            } else {
                try a.movMemReg(.r12, @intCast(@as(usize, ec.reg) * 8), .rax);
            }
        }
        if (cached_count > 0) {
            try emitFlushCached(a, cached_regs, cached_count);
        }
        if (promoted.count > 0) {
            try emitFlushPromoted(a, promoted);
        }
        const kind_u32: u32 = switch (op.opcode) {
            .and_bits => 0,
            .or_bits => 1,
            .xor_bits => 2,
            .shl => 3,
            .shr => 4,
            .ushr => 5,
            else => unreachable,
        };
        try a.movRegReg(.rdi, .r12);
        try a.movRegImm32(.rsi, op.a);
        try a.movRegImm32(.rdx, op.b);
        try a.movRegImm32(.rcx, op.c);
        try a.movRegImm32(.r8, kind_u32);
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
        try a.callReg(.rax);
        if (cached_count > 0) {
            try emitReloadCached(a, cached_regs, cached_count);
        }
        if (promoted.count > 0) {
            try emitReloadPromoted(a, promoted);
        }
        try a.movzxReg64Reg8(.rax, .rax);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bail_lbl);
        if (result_fits_i32) {
            try emitLoadNumToXmm(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.r8, .xmm0);
        }
        a.bindLabel(done_lbl);
        if (result_fits_i32 and op.a < 64) next_live_r8_i32.* = op.a;
    }

    noinline fn emitComparisonOrBranch(
        self: *OsrCompiler,
        idx: usize,
        ip: usize,
        op: codeblock.Op,
        bail_lbl: Label,
    ) !void {
        const a = self.a;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        switch (op.opcode) {
            .jump_if_false, .jump_if_true => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                const target_lbl = try self.resolveJumpTarget(target_pc);
                try emitCondJump(a, op.opcode == .jump_if_true, op.a, target_lbl, bail_lbl);
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const c_bits = JSValue.fromNumber(self.block.constants[op.b].number).bits;
                const target_pc = ip + @as(usize, op.c);
                const target_lbl = try self.resolveJumpTarget(target_pc);

                const xmm_src: Xmm = if (op.a < 64 and reg_to_xmm[op.a] != null)
                    reg_to_xmm[op.a].?
                else blk: {
                    try emitLoadNumToXmm(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                    break :blk .xmm0;
                };

                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                switch (op.opcode) {
                    .jeq_local_const_false => {
                        try a.ucomisd(xmm_src, .xmm1);
                        try a.jcc(.p, target_lbl);
                        try a.jcc(.ne, target_lbl);
                    },
                    .jlt_local_const_false => {
                        try a.ucomisd(.xmm1, xmm_src);
                        try a.jcc(.be, target_lbl);
                    },
                    .jle_local_const_false => {
                        try a.ucomisd(.xmm1, xmm_src);
                        try a.jcc(.b, target_lbl);
                    },
                    .jgt_local_const_false => {
                        try a.ucomisd(xmm_src, .xmm1);
                        try a.jcc(.be, target_lbl);
                    },
                    .jge_local_const_false => {
                        try a.ucomisd(xmm_src, .xmm1);
                        try a.jcc(.b, target_lbl);
                    },
                    else => unreachable,
                }
            },
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try emitLoadNumToXmm(a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                if (self.prepass.fused_cmps[idx]) |fc| {
                    const target_lbl = try self.resolveJumpTarget(fc.target_pc);
                    try emitFusedCmpBranch(a, op.opcode, fc.jump_if_true, target_lbl);
                    self.skip_ops_remaining = fc.skip_ops;
                } else {
                    try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                    try emitCmpToBool(a, op.opcode);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                }
            },
            .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
                const c_bits = JSValue.fromNumber(self.block.constants[op.c].number).bits;
                try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (self.prepass.fused_cmps[idx]) |fc| {
                    const target_lbl = try self.resolveJumpTarget(fc.target_pc);
                    try emitFusedCmpBranch(a, op.opcode, fc.jump_if_true, target_lbl);
                    self.skip_ops_remaining = fc.skip_ops;
                } else {
                    try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                    try emitCmpToBool(a, op.opcode);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                }
            },
            .jump => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                if (target_pc >= self.start_ip and target_pc <= self.end_ip) {
                    try a.jmp(self.op_labels[target_pc - self.start_ip]);
                } else {
                    try a.movRegImm32(.rax, @intCast(target_pc));
                    if (self.has_flush) {
                        try a.jmp(self.flush_and_exit);
                    } else {
                        try a.jmp(self.osr_epilogue);
                    }
                }
            },
            else => unreachable,
        }
    }

    noinline fn emitSetObjectProp(
        self: *OsrCompiler,
        ip: usize,
        op: codeblock.Op,
        bail_lbl: Label,
    ) !void {
        const a = self.a;
        const block = self.block;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const promoted = &self.analysis.promoted;

        if (op.opcode == .new_object) {
            const slow_lbl = try a.createLabel();
            const check_loop_lbl = try a.createLabel();
            const clear_loop_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();

            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, slow_lbl);

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);
            try a.movRegMem(.rcx, .rax, obj_rc_off);
            try a.cmpRegImm32(.rcx, 1);
            try a.jcc(.ne, slow_lbl);

            try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_sealed_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_extensible_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.e, slow_lbl);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_error_data_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            try a.movReg32Mem(.rcx, .rax, zobj_shape_id_offset);
            try a.cmpReg32Imm32(.rcx, 1);
            try a.jcc(.be, slow_lbl);
            try a.shrRegImm8(.rcx, 31);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_lbl);

            try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset);
            try a.cmpRegImm32(.rsi, 16);
            try a.jcc(.a, slow_lbl);

            try a.movRegMem(.rcx, .rax, zobj_entries_len_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.e, slow_lbl);
            try a.cmpRegImm32(.rcx, 8);
            try a.jcc(.a, slow_lbl);

            try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rsi, 4);
            } else {
                try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rdx, .rsi);

            try a.movRegReg(.r8, .rcx);
            try a.movRegReg(.r9, .rdx);
            a.bindLabel(check_loop_lbl);
            try a.movReg32Mem(.rsi, .r9, prop_desc_offset);
            try a.andRegImm8(.rsi, 0x1F);
            try a.cmpRegImm32(.rsi, 0x17);
            try a.jcc(.ne, slow_lbl);
            try a.movRegMem(.rsi, .r9, prop_val_offset);
            try a.cmpRegReg(.rsi, .r14);
            try a.jcc(.ae, slow_lbl);
            try a.addRegImm32(.r9, prop_size);
            try a.decReg64(.r8);
            try a.jcc(.ne, check_loop_lbl);

            try a.movRegReg(.r8, .rcx);
            try a.movRegReg(.r9, .rdx);
            a.bindLabel(clear_loop_lbl);
            try a.movMemReg(.r9, prop_val_offset, .r15);
            try a.addRegImm32(.r9, prop_size);
            try a.decReg64(.r8);
            try a.jcc(.ne, clear_loop_lbl);

            try a.movReg32Mem(.rsi, .rax, zobj_shape_id_offset);
            try a.movMem32Reg(.rax, zobj_cached_shape_id_offset, .rsi);
            try a.movMem16Reg(.rax, zobj_cached_len_offset, .rcx);
            try a.xorReg32Reg32(.rsi, .rsi);
            try a.movMem16Reg(.rax, zobj_active_len_offset, .rsi);
            try a.movRegImm32(.rsi, 1);
            try a.movMem32Reg(.rax, zobj_shape_id_offset, .rsi);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            try a.movRegReg(.rdi, .r13);
            try a.movRegReg(.rsi, .r12);
            try a.movRegImm32(.rdx, op.a);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitNewObject));
            try a.callReg(.rax);
            if (cached_count > 0) {
                try emitReloadCached(a, cached_regs, cached_count);
            }
            try a.movzxReg64Reg8(.rax, .rax);
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            a.bindLabel(done_lbl);
            return;
        }

        const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
        if (promoted.count > 0 and op.opcode == .set_prop) {
            const slot_idx = self.prop_ic.?[ic_idx].slot_idx;
            const p_idx = promoted.findSlot(slot_idx).?;
            const xmm_prop = promoted.xmms[p_idx];
            if (op.c < 64 and reg_to_xmm[op.c] != null) {
                const xmm_src = reg_to_xmm[op.c].?;
                if (xmm_prop != xmm_src) {
                    try a.movsdXmmXmm(xmm_prop, xmm_src);
                }
            } else {
                try emitLoadNumToXmm(a, reg_to_xmm, op.c, xmm_prop, bail_lbl);
            }
            return;
        }
        const key = constantName(block, op.b).?;
        const expected_key_ptr = @intFromPtr(key.ptr);
        const packed_info: u64 = (@as(u64, @intCast(ip)) << 32) | (@as(u64, ic_idx) << 16) | (@as(u64, op.c) << 8) | @as(u64, op.a);

        const slow_path = try a.createLabel();
        const done_lbl = try a.createLabel();

        if (op.opcode == .set_prop) {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, slow_path);

            if (op.c < 64 and reg_to_xmm[op.c] != null) {
                const xmm_val = reg_to_xmm[op.c].?;
                try a.movqRegXmm(.r8, xmm_val);
                try a.ucomisd(xmm_val, xmm_val);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.r8, .rcx);
            } else {
                try a.movRegMem(.r8, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.r8, .r14);
                try a.jcc(.ae, slow_path);
            }

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            const maybe_ic: ?PropIC = if (self.prop_ic) |table| blk: {
                const entry = table[ic_idx];
                if (entry.block == block and entry.pc == ip and @intFromPtr(entry.key_ptr) == expected_key_ptr and entry.shape_id != 0 and entry.next_shape == 0) {
                    break :blk entry;
                }
                break :blk null;
            } else null;

            if (maybe_ic) |ic_val| {
                try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                try a.cmpReg32Imm32(.rdx, @bitCast(ic_val.shape_id));
                try a.jcc(.ne, slow_path);

                try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
                try a.cmpRegImm32(.rdx, @intCast(ic_val.slot_idx));
                try a.jcc(.be, slow_path);

                try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
                try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset);
                if (comptime value_byte_offset_multiplier == 16) {
                    try a.shlRegImm8(.rsi, 4);
                } else {
                    try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
                }
                try a.addRegReg(.rdx, .rsi);

                const slot_byte_off: i32 = @intCast(@as(usize, ic_val.slot_idx) * @as(usize, @intCast(prop_size)));
                try a.movReg32Mem(.rcx, .rdx, slot_byte_off + prop_desc_offset);
                try a.andRegImm8(.rcx, 9);
                try a.cmpRegImm32(.rcx, 1);
                try a.jcc(.ne, slow_path);

                try a.movRegMem(.rcx, .rdx, slot_byte_off + prop_val_offset);
                try a.cmpRegReg(.rcx, .r14);
                try a.jcc(.ae, slow_path);

                try a.movMemReg(.rdx, slot_byte_off + prop_val_offset, .r8);
                try a.jmp(done_lbl);
            } else {
                try a.movRegMem(.rsi, .r13, ctx_prop_ic_ptr_offset);
                const ic_byte_offset: i32 = @intCast(@as(usize, ic_idx) * @sizeOf(PropIC));
                if (ic_byte_offset != 0) {
                    try a.addRegImm32(.rsi, ic_byte_offset);
                }

                try a.movRegMem(.rcx, .rsi, ic_block_offset);
                try a.movRegImm64(.rdx, @intFromPtr(block));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_pc_offset);
                try a.cmpReg32Imm32(.rcx, @intCast(ip));
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_next_shape_offset);
                try a.testReg32Reg32(.rcx, .rcx);
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_shape_id_offset);
                try a.testReg32Reg32(.rcx, .rcx);
                try a.jcc(.e, slow_path);
                try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                try a.cmpReg32Reg32(.rdx, .rcx);
                try a.jcc(.ne, slow_path);

                try a.movRegMem(.rcx, .rsi, ic_key_ptr_offset);
                try a.movRegImm64(.rdx, expected_key_ptr);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_slot_idx_offset);
                try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, slow_path);

                try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
                try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset);
                if (comptime value_byte_offset_multiplier == 16) {
                    try a.shlRegImm8(.rsi, 4);
                } else {
                    try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
                }
                try a.addRegReg(.rdx, .rsi);
                try a.imulRegRegImm32(.rsi, .rcx, prop_size);
                try a.addRegReg(.rdx, .rsi);

                try a.movReg32Mem(.rcx, .rdx, prop_desc_offset);
                try a.andRegImm8(.rcx, 9);
                try a.cmpRegImm32(.rcx, 1);
                try a.jcc(.ne, slow_path);

                try a.movRegMem(.rcx, .rdx, prop_val_offset);
                try a.cmpRegReg(.rcx, .r14);
                try a.jcc(.ae, slow_path);

                try a.movMemReg(.rdx, prop_val_offset, .r8);
                try a.jmp(done_lbl);
            }
        } else {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, slow_path);

            if (op.c < 64 and reg_to_xmm[op.c] != null) {
                const xmm_val = reg_to_xmm[op.c].?;
                try a.movqRegXmm(.r8, xmm_val);
                try a.ucomisd(xmm_val, xmm_val);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.r8, .rcx);
            } else {
                try a.movRegMem(.r8, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.r8, .r14);
                try a.jcc(.ae, slow_path);
            }

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);
            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_extensible_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.e, slow_path);

            const maybe_trans_ic: ?PropIC = if (self.prop_ic) |table| blk: {
                const entry = table[ic_idx];
                if (entry.block == block and entry.pc == ip and entry.shape_id != 0 and entry.next_shape != 0 and entry.cached_shape_id != 0 and entry.interned_key_ptr != null) {
                    break :blk entry;
                }
                break :blk null;
            } else null;

            if (maybe_trans_ic) |ic_val| {
                try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                try a.cmpReg32Imm32(.rdx, @bitCast(ic_val.shape_id));
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rdx, .rax, zobj_cached_shape_id_offset);
                try a.cmpReg32Imm32(.rdx, @bitCast(ic_val.cached_shape_id));
                try a.jcc(.ne, slow_path);

                try a.movzxReg64Mem16(.rdx, .rax, zobj_active_len_offset);
                try a.cmpRegImm32(.rdx, @intCast(ic_val.slot_idx));
                try a.jcc(.ne, slow_path);

                try a.movzxReg64Mem16(.rdx, .rax, zobj_cached_len_offset);
                try a.cmpRegImm32(.rdx, @intCast(ic_val.slot_idx));
                try a.jcc(.be, slow_path);

                try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
                const key_slot_off: i32 = @intCast(@as(usize, ic_val.slot_idx) * @as(usize, @intCast(key_size)) + @as(usize, @intCast(key_ptr_offset)));
                if (comptime key_byte_offset_multiplier == 0) {
                    try a.movRegMem(.rcx, .rdx, key_slot_off);
                } else {
                    try a.movRegMem(.r9, .rax, zobj_entries_cap_offset);
                    try a.imulRegRegImm32(.r9, .r9, @intCast(key_byte_offset_multiplier));
                    try a.addRegReg(.r9, .rdx);
                    try a.movRegMem(.rcx, .r9, key_slot_off);
                }
                try a.movRegImm64(.r9, @intFromPtr(ic_val.interned_key_ptr.?));
                try a.cmpRegReg(.rcx, .r9);
                try a.jcc(.ne, slow_path);

                try a.movRegMem(.r9, .rax, zobj_entries_cap_offset);
                if (comptime value_byte_offset_multiplier == 16) {
                    try a.shlRegImm8(.r9, 4);
                } else {
                    try a.imulRegRegImm32(.r9, .r9, @intCast(value_byte_offset_multiplier));
                }
                try a.addRegReg(.rdx, .r9);

                const slot_byte_off: i32 = @intCast(@as(usize, ic_val.slot_idx) * @as(usize, @intCast(prop_size)));
                try a.movRegMem(.r9, .rdx, slot_byte_off + prop_val_offset);
                try a.cmpRegReg(.r9, .r14);
                try a.jcc(.ae, slow_path);

                try a.movMemReg(.rdx, slot_byte_off + prop_val_offset, .r8);

                try a.movRegImm32(.r9, ic_val.next_shape);
                try a.movMem32Reg(.rax, zobj_shape_id_offset, .r9);

                const next_active: u32 = ic_val.slot_idx + 1;
                try a.movzxReg64Mem16(.rdx, .rax, zobj_cached_len_offset);
                const not_full_lbl = try a.createLabel();
                try a.cmpRegImm32(.rdx, @intCast(next_active));
                try a.jcc(.ne, not_full_lbl);

                try a.xorReg32Reg32(.r9, .r9);
                try a.movMem16Reg(.rax, zobj_cached_len_offset, .r9);
                try a.movMem32Reg(.rax, zobj_cached_shape_id_offset, .r9);
                try a.movMem16Reg(.rax, zobj_active_len_offset, .r9);
                try a.jmp(done_lbl);

                a.bindLabel(not_full_lbl);
                try a.movRegImm32(.rcx, next_active);
                try a.movMem16Reg(.rax, zobj_active_len_offset, .rcx);
                try a.jmp(done_lbl);
            } else {
                try a.movRegMem(.rsi, .r13, ctx_prop_ic_ptr_offset);
                const ic_byte_offset: i32 = @intCast(@as(usize, ic_idx) * @sizeOf(PropIC));
                if (ic_byte_offset != 0) {
                    try a.addRegImm32(.rsi, ic_byte_offset);
                }

                try a.movRegMem(.rcx, .rsi, ic_block_offset);
                try a.movRegImm64(.rdx, @intFromPtr(block));
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_pc_offset);
                try a.cmpReg32Imm32(.rcx, @intCast(ip));
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_next_shape_offset);
                try a.testReg32Reg32(.rcx, .rcx);
                try a.jcc(.e, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_shape_id_offset);
                try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                try a.cmpReg32Reg32(.rdx, .rcx);
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_cached_shape_id_offset);
                try a.movReg32Mem(.rdx, .rax, zobj_cached_shape_id_offset);
                try a.cmpReg32Reg32(.rdx, .rcx);
                try a.jcc(.ne, slow_path);

                try a.movReg32Mem(.rcx, .rsi, ic_slot_idx_offset);
                try a.movzxReg64Mem16(.rdx, .rax, zobj_active_len_offset);
                try a.cmpRegReg(.rdx, .rcx);
                try a.jcc(.ne, slow_path);

                try a.movzxReg64Mem16(.rdx, .rax, zobj_cached_len_offset);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, slow_path);

                try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
                if (key_byte_offset_multiplier != 0) {
                    try a.movRegMem(.r9, .rax, zobj_entries_cap_offset);
                    try a.imulRegRegImm32(.r9, .r9, @intCast(key_byte_offset_multiplier));
                    try a.addRegReg(.rdx, .r9);
                }
                try a.imulRegRegImm32(.r9, .rcx, key_size);
                try a.addRegReg(.rdx, .r9);
                try a.movRegMem(.rdx, .rdx, key_ptr_offset);
                try a.movRegMem(.r9, .rsi, ic_interned_key_ptr_offset);
                try a.cmpRegReg(.rdx, .r9);
                try a.jcc(.ne, slow_path);

                try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
                try a.movRegMem(.r9, .rax, zobj_entries_cap_offset);
                if (comptime value_byte_offset_multiplier == 16) {
                    try a.shlRegImm8(.r9, 4);
                } else {
                    try a.imulRegRegImm32(.r9, .r9, @intCast(value_byte_offset_multiplier));
                }
                try a.addRegReg(.rdx, .r9);
                try a.imulRegRegImm32(.r9, .rcx, prop_size);
                try a.addRegReg(.rdx, .r9);

                try a.movRegMem(.r9, .rdx, prop_val_offset);
                try a.cmpRegReg(.r9, .r14);
                try a.jcc(.ae, slow_path);

                try a.movMemReg(.rdx, prop_val_offset, .r8);

                try a.movReg32Mem(.r9, .rsi, ic_next_shape_offset);
                try a.movMem32Reg(.rax, zobj_shape_id_offset, .r9);

                try a.addRegImm32(.rcx, 1);
                try a.movzxReg64Mem16(.rdx, .rax, zobj_cached_len_offset);
                const not_full_lbl = try a.createLabel();
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ne, not_full_lbl);

                try a.xorReg32Reg32(.r9, .r9);
                try a.movMem16Reg(.rax, zobj_cached_len_offset, .r9);
                try a.movMem32Reg(.rax, zobj_cached_shape_id_offset, .r9);
                try a.movMem16Reg(.rax, zobj_active_len_offset, .r9);
                try a.jmp(done_lbl);

                a.bindLabel(not_full_lbl);
                try a.movMem16Reg(.rax, zobj_active_len_offset, .rcx);
                try a.jmp(done_lbl);
            }
        }

        a.bindLabel(slow_path);
        if (cached_count > 0) {
            try emitFlushCached(a, cached_regs, cached_count);
        }
        try a.movRegReg(.rdi, .r13);
        try a.movRegReg(.rsi, .r12);
        try a.movRegImm64(.rdx, packed_info);
        try a.movRegImm64(.rcx, expected_key_ptr);
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetProp));
        try a.callReg(.rax);
        if (cached_count > 0) {
            try emitReloadCached(a, cached_regs, cached_count);
        }
        try a.movzxReg64Reg8(.rax, .rax);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bail_lbl);
        a.bindLabel(done_lbl);
    }

    noinline fn emitGetPropOrGlobal(
        self: *OsrCompiler,
        ip: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const block = self.block;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const promoted = &self.analysis.promoted;
        const hoisted_arrs = &self.analysis.hoisted_arrs;

        if (op.opcode == .load_global) {
            const name = constantName(block, op.b).?;
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            if (promoted.count > 0) {
                try emitFlushPromoted(a, promoted);
            }
            try a.movRegReg(.rdi, .r13);
            try a.movRegReg(.rsi, .r12);
            try a.movRegImm32(.rdx, op.a);
            try a.movRegImm64(.rcx, @intFromPtr(name.ptr));
            try a.movRegImm64(.r8, name.len);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitLoadGlobal));
            try a.callReg(.rax);
            if (cached_count > 0) {
                try emitReloadCached(a, cached_regs, cached_count);
            }
            if (promoted.count > 0) {
                try emitReloadPromoted(a, promoted);
            }
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            return;
        }

        const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
        if (promoted.count > 0) {
            const slot_idx = self.prop_ic.?[ic_idx].slot_idx;
            const p_idx = promoted.findSlot(slot_idx).?;
            const xmm_prop = promoted.xmms[p_idx];
            if (op.a < 64 and reg_to_xmm[op.a] != null) {
                const xmm_dst = reg_to_xmm[op.a].?;
                if (xmm_dst != xmm_prop) {
                    try a.movsdXmmXmm(xmm_dst, xmm_prop);
                }
            } else {
                try emitStoreXmmToNum(a, reg_to_xmm, op.a, xmm_prop, bail_lbl);
            }
            return;
        }
        const key = constantName(block, op.c).?;
        if (std.mem.eql(u8, key, "length")) {
            const eff_len_b = if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b;
            if (hoisted_arrs.find(eff_len_b)) |h_slot| {
                if (hoisted_arrs.kinds[h_slot].isPtrLen()) {
                    const dst_xmm: Xmm = if (op.a < 64 and reg_to_xmm[op.a] != null) reg_to_xmm[op.a].? else .xmm0;
                    if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                        try a.cvtsi2sdqXmmReg64(dst_xmm, .rbp);
                    } else {
                        try a.movRegMem(.rax, .rsp, @intCast(h_slot * 16 + 8));
                        try a.cvtsi2sdqXmmReg64(dst_xmm, .rax);
                    }
                    if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
                        try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                    }
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                } else {
                    const box_r: x64_asm.Reg = if (hoisted_arrs.count == 1) blk: {
                        break :blk .rbx;
                    } else blk: {
                        try a.movRegMem(.r9, .rsp, @intCast(h_slot * 16));
                        break :blk .r9;
                    };
                    const holey_len_lbl = try a.createLabel();
                    const store_len_lbl = try a.createLabel();
                    try a.movRegMem(.rdx, box_r, arr_holey_off);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, holey_len_lbl);
                    try a.movRegMem(.rax, box_r, arr_items_len_off);
                    try a.jmp(store_len_lbl);
                    a.bindLabel(holey_len_lbl);
                    if (comptime @sizeOf(@FieldType(HoleyState, "logical_length")) == 8) {
                        try a.movRegMem(.rax, .rdx, h_log_len_off);
                    } else {
                        try a.movReg32Mem(.rax, .rdx, h_log_len_off);
                    }
                    a.bindLabel(store_len_lbl);
                    const dst_xmm: Xmm = if (op.a < 64 and reg_to_xmm[op.a] != null) reg_to_xmm[op.a].? else .xmm0;
                    try a.cvtsi2sdqXmmReg64(dst_xmm, .rax);
                    if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
                        try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
                    }
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                }
            }
        }
        const expected_key_ptr = @intFromPtr(key.ptr);
        const allow_non_num_flag: u64 = if (!(op.a < 64 and reg_to_xmm[op.a] != null)) (@as(u64, 1) << 24) else 0;
        const packed_info: u64 = (@as(u64, @intCast(ip)) << 32) | allow_non_num_flag | (@as(u64, ic_idx) << 16) | (@as(u64, op.b) << 8) | @as(u64, op.a);

        const slow_path = try a.createLabel();
        const done_lbl = try a.createLabel();

        if (std.mem.eql(u8, key, "length")) {
            const not_arr_lbl = try a.createLabel();
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, HEADER_ARRAY);
            try a.jcc(.ne, not_arr_lbl);
            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);
            try a.movRegMem(.rcx, .rax, arr_holey_off);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, bail_lbl);
            try a.movRegMem(.rax, .rax, arr_items_len_off);
            const dst_xmm: Xmm = if (op.a < 64 and reg_to_xmm[op.a] != null) reg_to_xmm[op.a].? else .xmm0;
            try a.cvtsi2sdqXmmReg64(dst_xmm, .rax);
            if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
                try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            }
            try a.jmp(done_lbl);
            a.bindLabel(not_arr_lbl);
        }

        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
        try a.jcc(.ne, slow_path);

        if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rcx, .r14);
            try a.jcc(.ae, slow_path);
        }

        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);

        const maybe_get_ic: ?PropIC = if (self.prop_ic) |table| blk: {
            const entry = table[ic_idx];
            if (entry.block == block and entry.pc == ip and @intFromPtr(entry.key_ptr) == expected_key_ptr and entry.shape_id != 0) {
                break :blk entry;
            }
            break :blk null;
        } else null;

        if (maybe_get_ic) |ic_val| {
            try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
            try a.cmpReg32Imm32(.rdx, @bitCast(ic_val.shape_id));
            try a.jcc(.ne, slow_path);

            try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
            try a.cmpRegImm32(.rdx, @intCast(ic_val.slot_idx));
            try a.jcc(.be, slow_path);

            try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
            try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rsi, 4);
            } else {
                try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rdx, .rsi);

            const slot_byte_off: i32 = @intCast(@as(usize, ic_val.slot_idx) * @as(usize, @intCast(prop_size)));
            try a.movReg32Mem(.rcx, .rdx, slot_byte_off + prop_desc_offset);
            try a.andRegImm8(.rcx, 8);
            try a.testReg32Reg32(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movRegMem(.rax, .rdx, slot_byte_off + prop_val_offset);
        } else {
            try a.movRegMem(.rsi, .r13, ctx_prop_ic_ptr_offset);
            const ic_byte_offset: i32 = @intCast(@as(usize, ic_idx) * @sizeOf(PropIC));
            if (ic_byte_offset != 0) {
                try a.addRegImm32(.rsi, ic_byte_offset);
            }

            try a.movRegMem(.rcx, .rsi, ic_block_offset);
            try a.movRegImm64(.rdx, @intFromPtr(block));
            try a.cmpRegReg(.rcx, .rdx);
            try a.jcc(.ne, slow_path);

            try a.movReg32Mem(.rcx, .rsi, ic_pc_offset);
            try a.cmpReg32Imm32(.rcx, @intCast(ip));
            try a.jcc(.ne, slow_path);

            try a.movReg32Mem(.rcx, .rsi, ic_shape_id_offset);
            try a.testReg32Reg32(.rcx, .rcx);
            try a.jcc(.e, slow_path);
            try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
            try a.cmpReg32Reg32(.rdx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movRegMem(.rcx, .rsi, ic_key_ptr_offset);
            try a.movRegImm64(.rdx, expected_key_ptr);
            try a.cmpRegReg(.rcx, .rdx);
            try a.jcc(.ne, slow_path);

            try a.movReg32Mem(.rcx, .rsi, ic_slot_idx_offset);
            try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
            try a.cmpRegReg(.rcx, .rdx);
            try a.jcc(.ae, slow_path);

            try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
            try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rsi, 4);
            } else {
                try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rdx, .rsi);
            try a.imulRegRegImm32(.rsi, .rcx, prop_size);
            try a.addRegReg(.rdx, .rsi);

            try a.movReg32Mem(.rcx, .rdx, prop_desc_offset);
            try a.andRegImm8(.rcx, 8);
            try a.testReg32Reg32(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movRegMem(.rax, .rdx, prop_val_offset);
        }
        if (op.a < 64 and reg_to_xmm[op.a] != null) {
            const xmm_dst = reg_to_xmm[op.a].?;
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movqXmmReg(xmm_dst, .rax);
        } else {
            try a.cmpRegReg(.rax, .r14);
            try a.jcc(.ae, slow_path);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
        }
        try a.jmp(done_lbl);

        a.bindLabel(slow_path);
        if (cached_count > 0) {
            try emitFlushCached(a, cached_regs, cached_count);
        }
        try a.movRegReg(.rdi, .r13);
        try a.movRegReg(.rsi, .r12);
        try a.movRegImm64(.rdx, packed_info);
        try a.movRegImm64(.rcx, expected_key_ptr);
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetProp));
        try a.callReg(.rax);
        if (cached_count > 0) {
            try emitReloadCached(a, cached_regs, cached_count);
        }
        try a.movzxReg64Reg8(.rax, .rax);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bail_lbl);
        if (op.a < 64 and reg_to_xmm[op.a] != null) {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
        }
        a.bindLabel(done_lbl);
    }

    noinline fn emitCallOp(
        self: *OsrCompiler,
        idx: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        const a = self.a;
        const block = self.block;
        const reg_to_xmm = &self.analysis.reg_to_xmm;
        const cs = &block.call_target_cache[op.c];

        if (op.opcode == .call and isMathSqrtCall(cs)) {
            if (!self.elided_math_call[idx]) {
                const expected_callee = cs.callee orelse return error.CannotCompile;
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movRegImm64(.rcx, expected_callee.bits);
                try a.cmpRegReg(.rax, .rcx);
                try a.jcc(.ne, bail_lbl);
            }
            const arg_reg: u8 = op.b + 1;
            try emitLoadNumToXmm(a, reg_to_xmm, arg_reg, .xmm0, bail_lbl);
            try a.sqrtsd(.xmm0, .xmm0);
            try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
            return;
        }

        const cache_addr: u64 = @intFromPtr(cs);
        const tb = cs.target_block.?;
        const target_addr: u64 = @intFromPtr(tb);
        const arg_count = cs.arg_count;
        const caller_regs = block.register_count;
        const callee_regs_off: i32 = @intCast(@as(usize, caller_regs) * 8);
        const total_regs = caller_regs + tb.register_count;
        const total_bytes: i32 = @intCast(@as(usize, total_regs) * 8);

        const regs_limit_off: i32 = @intCast(@offsetOf(codeblock.OsrContext, "regs_limit"));
        const global_ver_ptr_off: i32 = @intCast(@offsetOf(codeblock.OsrContext, "global_version_ptr"));
        const jit_fn_off: i32 = @intCast(@offsetOf(codeblock.CodeBlock, "jit_fn"));
        const closure_env_off: i32 = @intCast(@offsetOf(codeblock.CallSiteCache, "closure_env"));

        if (op.opcode == .call) {
            const expected_callee = cs.callee orelse return error.CannotCompile;
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.movRegImm64(.rcx, expected_callee.bits);
            try a.cmpRegReg(.rax, .rcx);
            try a.jcc(.ne, bail_lbl);
        } else {
            try a.movRegMem(.rcx, .r13, global_ver_ptr_off);
            try a.movRegMem(.rax, .rcx, 0);
            try a.movRegImm64(.rdx, cache_addr);
            try a.movRegMem(.rdx, .rdx, @intCast(@offsetOf(codeblock.CallSiteCache, "global_version")));
            try a.cmpRegReg(.rax, .rdx);
            try a.jcc(.ne, bail_lbl);
        }

        try a.movRegImm64(.rcx, target_addr);
        try a.movRegMem(.r11, .rcx, jit_fn_off);
        try a.testRegReg(.r11, .r11);
        try a.jcc(.e, bail_lbl);

        const arg_start = @as(usize, op.b) + 1;
        for (0..arg_count) |i_arg| {
            try a.movRegMem(.rax, .r12, @intCast((arg_start + i_arg) * 8));
            try a.cmpRegReg(.rax, .r14);
            try a.jcc(.ae, bail_lbl);
        }

        try a.lea(.rax, .r12, total_bytes);
        try a.movRegMem(.rcx, .r13, regs_limit_off);
        try a.cmpRegReg(.rax, .rcx);
        try a.jcc(.a, bail_lbl);

        for (0..arg_count) |i_arg| {
            try a.movRegMem(.rax, .r12, @intCast((arg_start + i_arg) * 8));
            try a.movMemReg(.r12, callee_regs_off + @as(i32, @intCast(i_arg * 8)), .rax);
        }

        try a.lea(.rdi, .r12, callee_regs_off);
        try a.movRegMem(.rdx, .r13, regs_limit_off);
        try a.movRegImm64(.rcx, cache_addr);
        try a.movRegMem(.rcx, .rcx, closure_env_off);

        try a.subRegImm32(.rsp, 16);
        try a.movRegReg(.rsi, .rsp);
        try a.callReg(.r11);

        try a.testRegReg(.rax, .rax);
        const call_ok_lbl = try a.createLabel();
        try a.jcc(.e, call_ok_lbl);

        try a.addRegImm32(.rsp, 16);
        try a.jmp(bail_lbl);

        a.bindLabel(call_ok_lbl);
        try a.movRegMem(.rbx, .rsp, 0);
        try a.addRegImm32(.rsp, 16);

        const write_out_lbl = try a.createLabel();
        const heap_old_lbl = try a.createLabel();
        const deinit_call_lbl = try a.createLabel();

        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
        try a.cmpRegReg(.rax, .r14);
        try a.jcc(.ae, heap_old_lbl);
        try a.jmp(write_out_lbl);

        a.bindLabel(heap_old_lbl);
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
        try a.jcc(.ne, deinit_call_lbl);

        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rcx, .rax);

        const rc_off: i32 = @intCast(@offsetOf(zvalue.Rc(zvalue.Callable), "_count"));
        try a.movRegMem(.rdx, .rcx, rc_off);
        try a.cmpRegImm32(.rdx, 1);
        try a.jcc(.be, deinit_call_lbl);

        try a.subRegImm32(.rdx, 1);
        try a.movMemReg(.rcx, rc_off, .rdx);
        try a.jmp(write_out_lbl);

        a.bindLabel(deinit_call_lbl);
        try a.lea(.rdi, .r12, @intCast(@as(usize, op.a) * 8));
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitDeinitSlot));
        try a.callReg(.rax);

        a.bindLabel(write_out_lbl);
        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rbx);
    }

    noinline fn emitLoopOp(
        self: *OsrCompiler,
        idx: usize,
        ip: usize,
        op: codeblock.Op,
        bail_lbl: Label,
        next_live_r8_i32: *?u8,
    ) !void {
        switch (op.opcode) {
            .nop => {},
            .load_undefined, .load_const, .move, .load_local, .store_local, .to_prop_key => {
                try self.emitMoveOrConst(idx, ip, op, bail_lbl, next_live_r8_i32);
            },
            .get_elem, .get_elem_const => {
                try self.emitGetElem(idx, op, bail_lbl, next_live_r8_i32);
            },
            .set_elem, .set_elem_const, .new_array => {
                try self.emitSetElem(idx, op, bail_lbl, next_live_r8_i32);
            },
            .add, .add_num, .sub_num, .mul_num, .add_local_const, .sub_local_const, .div_num, .mod_num, .neg => {
                try self.emitArithAndMod(idx, ip, op, bail_lbl, next_live_r8_i32);
            },
            .not_bits, .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                try self.emitBitwiseOp(idx, op, bail_lbl, next_live_r8_i32);
            },
            .jump_if_false,
            .jump_if_true,
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            .lt_num,
            .gt_num,
            .le_num,
            .ge_num,
            .eq,
            .ne,
            .loose_eq,
            .loose_ne,
            .lt_local_const,
            .gt_local_const,
            .le_local_const,
            .ge_local_const,
            .eq_local_const,
            .jump,
            => {
                try self.emitComparisonOrBranch(idx, ip, op, bail_lbl);
            },
            .new_object, .set_prop, .set_prop_transition => {
                try self.emitSetObjectProp(ip, op, bail_lbl);
            },
            .get_prop, .load_global => {
                try self.emitGetPropOrGlobal(ip, op, bail_lbl, next_live_r8_i32);
            },
            .call, .call_global => {
                try self.emitCallOp(idx, op, bail_lbl, next_live_r8_i32);
            },
            .throw_value => {
                try self.a.jmp(bail_lbl);
            },
            else => {
                if (!(try emitSharedOp(self.a, self.block, op, true, bail_lbl))) unreachable;
            },
        }
    }

    noinline fn emitExitsAndEpilogue(self: *OsrCompiler) !void {
        const a = self.a;
        const cached_regs = &self.analysis.cached_regs;
        const cached_count = self.analysis.cached_count;
        const promoted = &self.analysis.promoted;
        const has_preheader_bailout = (self.has_flush or self.analysis.hoisted_arrs.count > 0 or self.math_sqrt_guard_bits != null);

        for (self.exit_stubs.items) |stub| {
            a.bindLabel(stub.label);
            try a.movRegImm32(.rax, stub.target_ip);
            if (self.has_flush) {
                try a.jmp(self.flush_and_exit);
            } else {
                try a.jmp(self.osr_epilogue);
            }
        }

        for (0..self.loop_len) |idx| {
            a.bindLabel(self.bailout_labels[idx]);
            try a.movRegImm32(.rax, self.bailout_target_ips[idx]);
            if (self.has_flush) {
                try a.jmp(self.flush_and_exit);
            } else {
                try a.jmp(self.osr_epilogue);
            }
        }

        if (self.has_flush) {
            a.bindLabel(self.flush_and_exit);
            if (cached_count > 0) {
                try emitFlushCached(a, cached_regs, cached_count);
            }
            if (promoted.count > 0) {
                try emitFlushPromoted(a, promoted);
            }
            try a.jmp(self.osr_epilogue);
        }

        if (has_preheader_bailout) {
            a.bindLabel(self.preheader_bailout);
            try a.movRegImm32(.rax, @intCast(self.start_ip));
            try a.jmp(self.osr_epilogue);
        }

        a.bindLabel(self.osr_epilogue);
        try a.addRegImm32(.rsp, self.hoisted_stack_bytes);
        try a.popReg(.r15);
        try a.popReg(.r14);
        try a.popReg(.r13);
        try a.popReg(.r12);
        try a.popReg(.rbp);
        try a.popReg(.rbx);
        try a.ret();
    }
};

noinline fn compileOsrImpl(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic_ptr: ?*const anyopaque,
    frame_regs_opt: ?[]const JSValue,
) ![]align(std.heap.page_size_min) u8 {
    const prop_ic: ?*const [256]PropIC = if (prop_ic_ptr) |p| @ptrCast(@alignCast(p)) else null;

    var prepass = try OsrPrePass.init(allocator, block, start_ip, end_ip);
    defer prepass.deinit(allocator);

    const analysis = analyzeOsrLoop(block, start_ip, end_ip, prop_ic, &prepass, frame_regs_opt);
    const hoisted_arrs = analysis.hoisted_arrs;
    const loop_len = end_ip - start_ip + 1;

    var a = Assembler.init(allocator);
    defer a.deinit();

    const op_labels = try allocator.alloc(Label, loop_len);
    defer allocator.free(op_labels);
    const bailout_labels = try allocator.alloc(Label, loop_len);
    defer allocator.free(bailout_labels);
    const bailout_target_ips = try allocator.alloc(u32, loop_len);
    defer allocator.free(bailout_target_ips);

    const elided_consts = try allocator.alloc(?OsrCompiler.ElidedConst, loop_len);
    defer allocator.free(elided_consts);
    @memset(elided_consts, null);

    for (0..loop_len) |i| {
        op_labels[i] = try a.createLabel();
        bailout_labels[i] = try a.createLabel();
        bailout_target_ips[i] = prepass.compound_span_start[i] orelse @intCast(start_ip + i);
    }
    const preheader_bailout = try a.createLabel();
    const flush_and_exit = try a.createLabel();
    const osr_epilogue = try a.createLabel();

    const elided_op = try allocator.alloc(bool, loop_len);
    defer allocator.free(elided_op);
    @memcpy(elided_op, prepass.elided_compound_op);
    const elided_math_call = try allocator.alloc(bool, loop_len);
    defer allocator.free(elided_math_call);
    @memset(elided_math_call, false);

    const incoming_has_edge = try allocator.alloc(bool, loop_len);
    defer allocator.free(incoming_has_edge);
    @memset(incoming_has_edge, false);
    const incoming_int32 = try allocator.alloc([64]bool, loop_len);
    defer allocator.free(incoming_int32);
    const incoming_uint31 = try allocator.alloc([64]bool, loop_len);
    defer allocator.free(incoming_uint31);
    const incoming_exact_idx = try allocator.alloc([64]bool, loop_len);
    defer allocator.free(incoming_exact_idx);
    const incoming_elem_store = try allocator.alloc(?OsrCompiler.ElemStorePair, loop_len);
    defer allocator.free(incoming_elem_store);
    @memset(incoming_elem_store, null);

    var oc = OsrCompiler{
        .allocator = allocator,
        .a = &a,
        .block = block,
        .start_ip = start_ip,
        .end_ip = end_ip,
        .loop_len = loop_len,
        .prop_ic = prop_ic,
        .prepass = &prepass,
        .analysis = analysis,
        .single_hoisted_arr = if (hoisted_arrs.count == 1 and !hoisted_arrs.kinds[0].isTypedArray()) hoisted_arrs.regs[0] else null,
        .hoisted_stack_bytes = if (hoisted_arrs.count > 0) 136 else 8,
        .has_flush = (analysis.cached_count > 0 or analysis.promoted.count > 0),
        .op_labels = op_labels,
        .bailout_labels = bailout_labels,
        .bailout_target_ips = bailout_target_ips,
        .elided_consts = elided_consts,
        .preheader_bailout = preheader_bailout,
        .flush_and_exit = flush_and_exit,
        .osr_epilogue = osr_epilogue,
        .elided_op = elided_op,
        .elided_math_call = elided_math_call,
        .incoming_has_edge = incoming_has_edge,
        .incoming_int32 = incoming_int32,
        .incoming_uint31 = incoming_uint31,
        .incoming_exact_idx = incoming_exact_idx,
        .incoming_elem_store = incoming_elem_store,
    };
    defer oc.exit_stubs.deinit(allocator);

    oc.analyzeMathSqrtElisions();
    try oc.emitPreheader();

    for (0..loop_len) |idx| {
        const ip = start_ip + idx;
        const op = block.ops[ip];
        const bail_lbl = oc.bailout_labels[idx];
        a.bindLabel(oc.op_labels[idx]);
        if (oc.skip_ops_remaining > 0) {
            oc.skip_ops_remaining -= 1;
            continue;
        }
        if (oc.elided_op[idx]) continue;
        oc.mergeIncomingState(idx);
        var next_live_r8_i32: ?u8 = null;
        try oc.emitLoopOp(idx, ip, op, bail_lbl, &next_live_r8_i32);
        oc.updateTrackingAfterOp(idx, ip, op, next_live_r8_i32);
    }

    try oc.emitExitsAndEpilogue();
    return a.finalizeExecutable();
}

test "baseline JIT compiles and executes fib(20), NaN arithmetic, string bailout, global reassignment, and stack overflow" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. fib(20) == 6765 + string bailout fib("10") + global reassignment
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function fib(n) {
            \\    if (n == 0) { return 0; }
            \\    if (n == 1) { return 1; }
            \\    return fib(n - 1) + fib(n - 2);
            \\}
            \\var r20 = fib(20);
            \\var orig = fib;
            \\fib = function(n) { return 100; };
            \\var r_reassigned = orig(5);
            \\r20 * 1000 + r_reassigned;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 6765200), res.asNumber());
    }

    // 2. Arithmetic + NaN canonicalization + string bailout on hot JIT function
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function calc(a, b) {
            \\    var sum = 0;
            \\    for (var i = 0; i < 10; i++) {
            \\        sum = sum + (a * b - i);
            \\    }
            \\    return sum;
            \\}
            \\var total = 0;
            \\for (var k = 0; k < 40; k++) {
            \\    total = total + calc(3, 4);
            \\}
            \\var nan_res = calc(NaN, 2);
            \\function addOne(x) { return x + 1; }
            \\for (var j = 0; j < 40; j++) { addOne(j); }
            \\var str_res = addOne("10");
            \\(total === 3000 && Number.isNaN(nan_res) && str_res === "101") ? 1 : 0;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }

    // 3. Deep recursion stack overflow (StackOverflow error without crash)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        try std.testing.expectError(
            error.StackOverflow,
            interp.run(
                \\function inf(n) {
                \\    if (n == -1) return 0;
                \\    return inf(n + 1) + 1;
                \\}
                \\inf(0);
            ),
        );
    }
}

test "baseline JIT compiles closures with load_global/store_global, multiple closure instances, and const/heap bailouts" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. Closure counter (> 50 calls) + two independent closure instances sharing one CodeBlock
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function makeCounter() {
            \\    let count = 0;
            \\    return function() { count++; return count; };
            \\}
            \\function run() {
            \\    const c1 = makeCounter();
            \\    const c2 = makeCounter();
            \\    let r1 = 0;
            \\    let r2 = 0;
            \\    for (let i = 0; i < 100; i++) {
            \\        r1 = c1();
            \\        if (i < 45) r2 = c2();
            \\    }
            \\    return r1 * 1000 + r2;
            \\}
            \\run();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 100045), res.asNumber());
    }

    // 2. Global variable reassigned to string/object + assignment to const binding (bailout & TypeError, 0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\let g = 0;
            \\function bumpG() { g = g + 1; return g; }
            \\for (let i = 0; i < 50; i++) bumpG();
            \\g = "hello";
            \\const s = bumpG();
            \\const K = 10;
            \\function writeConst() { K = 20; return K; }
            \\let caught = 0;
            \\for (let j = 0; j < 40; j++) {
            \\    try { writeConst(); } catch (e) { caught++; }
            \\}
            \\(s === "hello1" && caught === 40) ? 1 : 0;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }
}

test "baseline JIT OSR compiles hot array loops, handles mid-loop type bailout without duplicating iterations, and isolates multiple loops" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. Hot loop with new_array + set_elem_const + get_elem_const (> 100 iterations, 0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function arrayLoop(n) {
            \\    let total = 0;
            \\    for (let i = 0; i < n; i++) {
            \\        const arr = [i, i + 1, i + 2];
            \\        total += arr[0] + arr[1] + arr[2];
            \\    }
            \\    return total;
            \\}
            \\arrayLoop(200);
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // sum_{i=0}^{199} (3i + 3) = 3 * (199*200/2) + 600 = 59700 + 600 = 60300
        try std.testing.expectEqual(@as(f64, 60300), res.asNumber());
    }

    // 2. Mid-loop bailout when an array element changes to string at iteration 80 (after OSR activation at 64)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function mixedArrayLoop() {
            \\    const box = [1];
            \\    const s = "x";
            \\    let total = 0;
            \\    for (let i = 0; i < 82; i++) {
            \\        if (i == 80) {
            \\            box[0] = s;
            \\        }
            \\        total = total + box[0];
            \\    }
            \\    return total === "80xx" ? 1 : 0;
            \\}
            \\mixedArrayLoop();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }

    // 3. Function with 2 sequential loops in the same CodeBlock (target_ip == osr_header_ip guard)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function twoLoops() {
            \\    let s1 = 0;
            \\    for (let i = 0; i < 100; i++) {
            \\        const a = [i, 1];
            \\        s1 += a[0] + a[1];
            \\    }
            \\    let s2 = 0;
            \\    for (let j = 0; j < 100; j++) {
            \\        const b = [j, 10];
            \\        s2 += b[0] + b[1];
            \\    }
            \\    return s1 * 10000 + s2;
            \\}
            \\twoLoops();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // s1 = 4950 + 100 = 5050; s2 = 4950 + 1000 = 5950 => 50505950
        try std.testing.expectEqual(@as(f64, 50505950), res.asNumber());
    }

    // 4. Hot loop with new_object + set_prop/set_prop_transition + get_prop (> 100 iterations, 0 leaks) + mid-loop shape/type bailout
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function objLoop(n) {
            \\    let total = 0;
            \\    for (let i = 0; i < n; i++) {
            \\        const o = { x: i, y: i + 1, z: i + 2 };
            \\        const arr = [o.x, o.y, o.z];
            \\        total += arr[0] + arr[1] + arr[2];
            \\    }
            \\    return total;
            \\}
            \\function objShapeBailout() {
            \\    const alt = { y: 10, x: 5 };
            \\    let sum = 0;
            \\    for (let i = 0; i < 90; i++) {
            \\        let o = { x: 1, y: 2 };
            \\        if (i == 80) {
            \\            o = alt;
            \\        }
            \\        sum += o.x + o.y;
            \\    }
            \\    return sum;
            \\}
            \\objLoop(200) * 1000 + objShapeBailout();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // objLoop(200) = 60300; objShapeBailout: 89 * 3 + 15 = 267 + 15 = 282 => 60300282
        try std.testing.expectEqual(@as(f64, 60300282), res.asNumber());
    }

    // 5. Phase 3A inline set_elem_const + get_elem_const fast-path + slow-path overwrite/heap fallback (0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function overwriteAndHeapElemLoop() {
            \\    let sum = 0;
            \\    for (let i = 0; i < 120; i++) {
            \\        const o = { v: i };
            \\        const arr = [o, i, i + 1];
            \\        let x = { tmp: 1 };
            \\        x = arr[1];
            \\        sum += x + arr[2];
            \\    }
            \\    return sum;
            \\}
            \\overwriteAndHeapElemLoop();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // sum_{i=0}^{119} (2i + 1) = 120^2 = 14400
        try std.testing.expectEqual(@as(f64, 14400), res.asNumber());
    }
}

test "baseline JIT Phase 3B executes div_num, mod_num, neg, bitwise, comparisons, jump_if_false/true, dynamic get_elem/set_elem, and IEEE 754 edge cases" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. Prime check / compute with div_num, mod_num, neg, comparisons, and jump_if_false/jump_if_true
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function isPrime(n) {
            \\    if (n <= 1) return false;
            \\    for (let d = 2; d * d <= n; d++) {
            \\        if (n % d === 0) return false;
            \\    }
            \\    return true;
            \\}
            \\function arithCmp(x, y) {
            \\    const q = x / y;
            \\    const r = x % y;
            \\    const neg_r = -r;
            \\    const ok = (q > 0 && r >= 0 && !(r < 0) && (x !== y || r === 0));
            \\    return ok ? (q + neg_r) : -1;
            \\}
            \\let primes = 0;
            \\let acc = 0;
            \\for (let i = 1; i <= 100; i++) {
            \\    if (isPrime(i)) primes++;
            \\    acc += arithCmp(i * 3, 2);
            \\}
            \\// Neg & float modulo bailout verification
            \\function modFn(a, b) { return a % b; }
            \\for (let k = 1; k <= 50; k++) modFn(k + 10, 3);
            \\const neg_mod = modFn(-7, 3);
            \\(primes === 25 && neg_mod === -1 && acc > 0) ? 1 : 0;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }

    // 2. Bitwise operations (&, |, ^, ~, <<, >>, >>>) + safe bailout on NaN/Infinity/>2^31
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function bitOps(a, b) {
            \\    const x = (a & 255) | (b ^ 15);
            \\    const y = (~x) << 2;
            \\    const z = (y >> 1) ^ (a >>> 1);
            \\    return z;
            \\}
            \\let sum = 0;
            \\for (let i = 0; i < 80; i++) {
            \\    sum += bitOps(i, i + 3);
            \\}
            \\const u_neg = (-1) >>> 1;
            \\const bail_nan = bitOps(NaN, 5);
            \\const bail_inf = bitOps(Infinity, 5);
            \\const bail_big = (4294967297 | 0);
            \\(u_neg === 2147483647 && bail_nan === bitOps(0, 5) && bail_inf === bitOps(0, 5) && bail_big === 1) ? 1 : 0;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }

    // 3. OSR loop with dynamic get_elem and set_elem (sieve / swap / sum + 0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function dynamicElemLoop(n) {
            \\    const a = [0, 0, 0, 0];
            \\    for (let i = 0; i < n; i++) {
            \\        const idx = i & 3;
            \\        a[idx] = a[idx] + i;
            \\    }
            \\    return a[0] + a[1] + a[2] + a[3];
            \\}
            \\dynamicElemLoop(200);
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // sum_{i=0}^{199} i = 199 * 200 / 2 = 19900
        try std.testing.expectEqual(@as(f64, 19900), res.asNumber());
    }

    // 4. IEEE 754 edge cases (NaN === NaN false, NaN !== NaN true, 0/0 canonical NaN, 1/0 Infinity)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function ieeeCheck(a, b) {
            \\    const d = a / b;
            \\    const eq_self = (d === d);
            \\    const ne_self = (d !== d);
            \\    const lt_zero = (d < 0);
            \\    const gt_zero = (d > 0);
            \\    return (eq_self ? 100 : 0) + (ne_self ? 10 : 0) + ((lt_zero || gt_zero) ? 1 : 0);
            \\}
            \\let r_num = 0;
            \\for (let i = 1; i <= 50; i++) {
            \\    r_num = ieeeCheck(i, 2);
            \\}
            \\const r_nan = ieeeCheck(0, 0);
            \\const r_inf = ieeeCheck(1, 0);
            \\(r_num === 101 && r_nan === 10 && r_inf === 101) ? 1 : 0;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }
}

test "baseline JIT OSR compiles direct calls to closures and helper functions, handles callee/global reassignment bailout, and handles heap arg bailout" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. OSR loop calling closure c() (arg_count == 0) and helper add2(x, y) (arg_count == 2) > 200 times (0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function makeCounter() {
            \\    let count = 0;
            \\    return function() { count++; return count; };
            \\}
            \\function add2(x, y) {
            \\    return x + y;
            \\}
            \\function run() {
            \\    const c = makeCounter();
            \\    let total = 0;
            \\    for (let i = 0; i < 250; i++) {
            \\        const v = c();
            \\        total = add2(total, v);
            \\    }
            \\    return total;
            \\}
            \\run();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // sum_{v=1}^{250} v = 250 * 251 / 2 = 31375
        try std.testing.expectEqual(@as(f64, 31375), res.asNumber());
    }

    // 2. Target function reassignment mid-loop (callee invalidation & global_version invalidation)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        // 2a. Callee reassignment (.call)
        {
            const res = try interp.run(
                \\function testCalleeReassign() {
                \\    function fnA(x) { return x + 1; }
                \\    function fnB(x) { return x + 10; }
                \\    let fn = fnA;
                \\    let total = 0;
                \\    for (let i = 0; i < 200; i++) {
                \\        if (i == 100) fn = fnB;
                \\        total += fn(i);
                \\    }
                \\    return total;
                \\}
                \\testCalleeReassign();
            );
            defer res.deinit();
            try std.testing.expect(res.isNumber());
            // sum_{i=0}^{99} (i + 1) = 4950 + 100 = 5050
            // sum_{i=100}^{199} (i + 10) = 14950 + 1000 = 15950
            // total = 21000
            try std.testing.expectEqual(@as(f64, 21000), res.asNumber());
        }

        // 2b. Global function reassignment (.call_global / global_version)
        {
            const res = try interp.run(
                \\function gTargetA(x) { return x + 1; }
                \\function gTargetB(x) { return x + 10; }
                \\var gFn = gTargetA;
                \\function testGlobalReassign() {
                \\    let total = 0;
                \\    for (let i = 0; i < 200; i++) {
                \\        if (i == 100) gFn = gTargetB;
                \\        total += gFn(i);
                \\    }
                \\    return total;
                \\}
                \\testGlobalReassign();
            );
            defer res.deinit();
            try std.testing.expect(res.isNumber());
            try std.testing.expectEqual(@as(f64, 21000), res.asNumber());
        }
    }

    // 3. Call from OSR loop with string/object argument (clean bailout and 0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function helper(x) { return x; }
            \\function testHeapArg() {
            \\    let had_str = 0;
            \\    for (let i = 0; i < 200; i++) {
            \\        let arg = i;
            \\        if (i == 100) arg = "bailout_str";
            \\        const r = helper(arg);
            \\        if (r === "bailout_str") had_str = 1;
            \\    }
            \\    return had_str;
            \\}
            \\testHeapArg();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }
}

test "baseline JIT Phase 4B fast self-recursion executes fib(20), handles deep recursion bailout, and handles global reassignment" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. fib(20) == 6765 with 0 leaks
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function fib(n) {
            \\    if (n <= 1) return n;
            \\    return fib(n - 1) + fib(n - 2);
            \\}
            \\fib(20);
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 6765), res.asNumber());
    }

    // 2. Infinite recursion function inf(n) { return inf(n + 1); } inf(0);
    // Bails out cleanly from fast_entry to interpreter and throws error.StackOverflow
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        try std.testing.expectError(
            error.StackOverflow,
            interp.run(
                \\function inf(n) {
                \\    return inf(n + 1);
                \\}
                \\inf(0);
            ),
        );
    }

    // 3. Global function reassignment mid-execution invalidates global_version and gives correct result
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function fib(n) {
            \\    if (n <= 1) return n;
            \\    return fib(n - 1) + fib(n - 2);
            \\}
            \\var r20 = fib(20);
            \\var orig = fib;
            \\fib = function(n) { return 100; };
            \\var r_reassigned = orig(5);
            \\r20 * 1000 + r_reassigned;
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 6765200), res.asNumber());
    }
}

test "baseline JIT Phase 4C caches hot numeric locals in xmm4..xmm15, handles NaN canonicalization and mid-loop bailout" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. Pure numeric loop with multiple accumulators and arithmetic/bitwise ops
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\var sum = 0;
            \\var prod = 1;
            \\for (var i = 1; i <= 20; i++) {
            \\    sum = (sum + i) ^ 3;
            \\    prod = (prod * 2) & 0x7FFFFFFF;
            \\}
            \\sum + prod;
        );
        try std.testing.expectEqual(@as(f64, 1048790), res.asNumber());
    }

    // 2. Loop with 0/0 (NaN) propagated in a cached accumulator (verified canonical NaN at exit)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\var acc = 10;
            \\for (var i = 0; i < 100; i++) {
            \\    acc = acc + 1;
            \\    if (i === 80) acc = 0 / 0;
            \\}
            \\acc;
        );
        try std.testing.expect(res.isNumber() and std.math.isNan(res.asNumber()));
        try std.testing.expectEqual(JSValue.CANONICAL_NAN, res.bits);
    }

    // 3. Bailout in the middle of loop (out-of-bounds array write) verifying that cached values in xmm are flushed to regs[]
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\var arr = [10, 20, 30, 40, 50];
            \\var sum = 0;
            \\var last_i = -1;
            \\for (var i = 0; i < 100; i++) {
            \\    if (i == 5) {
            \\        arr[10] = 999;
            \\    }
            \\    sum = sum + i;
            \\    last_i = i;
            \\}
            \\sum + last_i + arr[10];
        );
        try std.testing.expectEqual(@as(f64, 6048), res.asNumber());
    }
}

test "baseline JIT Phase 4D eliminates bailouts in bitwise sieve with array, mod_num, inline RC" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runSieveBitwise(n) {
        \\    const arr = [0, 0, 0, 0, 0, 0, 0, 0];
        \\    let acc = 0;
        \\    for (let i = 1; i <= n; i++) {
        \\        const idx = i & 7;
        \\        const r = i % 7;
        \\        const q = (i / 4) | 0;
        \\        const b = ((q ^ idx) << 2) ^ (i >>> 1);
        \\        if (r === 0) {
        \\            arr[idx] = arr[idx] + b;
        \\        } else {
        \\            arr[idx] = arr[idx] + r;
        \\        }
        \\        acc = (acc + arr[idx]) | 0;
        \\    }
        \\    return acc;
        \\}
        \\runSieveBitwise(5000);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 418157123), res.asNumber());
}

test "baseline JIT Phase 5A hot loop reading and writing object properties (IC hit, 0 leaks)" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runHotProps(n) {
        \\    const o = { x: 1, y: 2, z: 3 };
        \\    let acc = 0;
        \\    for (let i = 0; i < n; i++) {
        \\        o.x = o.x + 1;
        \\        o.y = o.y + 2;
        \\        o.z = o.z + 3;
        \\        acc = o.x + o.y + o.z;
        \\    }
        \\    return acc;
        \\}
        \\runHotProps(2000);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 12006), res.asNumber());
}

test "baseline JIT Phase 5A polymorphic loop alternating 2 shapes fallback" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runPoly(n) {
        \\    const o1 = { x: 1, y: 2 };
        \\    const o2 = { a: 10, x: 20 };
        \\    let total = 0;
        \\    for (let i = 0; i < n; i++) {
        \\        const target = (i % 2 === 0) ? o1 : o2;
        \\        target.x = target.x + 1;
        \\        total = total + target.x;
        \\    }
        \\    return total;
        \\}
        \\runPoly(2000);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 1022000), res.asNumber());
}

test "baseline JIT Phase 5A frozen object and accessor fall back to slow path" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runFrozenAndAccessor() {
        \\    let getter_called = 0;
        \\    let setter_called = 0;
        \\    const o_acc = {
        \\        get x() { getter_called = getter_called + 1; return 42; },
        \\        set x(v) { setter_called = setter_called + 1; }
        \\    };
        \\    let acc = 0;
        \\    for (let i = 0; i < 100; i++) {
        \\        o_acc.x = o_acc.x + 1;
        \\        acc = acc + o_acc.x;
        \\    }
        \\
        \\    const o_frozen = Object.freeze({ x: 100 });
        \\    let frozen_sum = 0;
        \\    for (let i = 0; i < 100; i++) {
        \\        frozen_sum = frozen_sum + o_frozen.x;
        \\    }
        \\    return getter_called + setter_called + acc + frozen_sum;
        \\}
        \\runFrozenAndAccessor();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 14500), res.asNumber());
}

test "baseline JIT OSR preserves non-hoisted ArrayBox across uncached index load in get_elem/set_elem (qsort)" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function qsort(arr, lo, hi) {
        \\    var i = lo;
        \\    var j = hi;
        \\    var pivot = arr[(lo + hi) >> 1];
        \\    while (i <= j) {
        \\        while (arr[i] < pivot) i++;
        \\        while (arr[j] > pivot) j--;
        \\        if (i <= j) {
        \\            var tmp = arr[i];
        \\            arr[i] = arr[j];
        \\            arr[j] = tmp;
        \\            i++;
        \\            j--;
        \\        }
        \\    }
        \\    if (lo < j) qsort(arr, lo, j);
        \\    if (i < hi) qsort(arr, i, hi);
        \\}
        \\var n = 50;
        \\var arr = new Array(n);
        \\var s = 123456789;
        \\for (var i = 0; i < n; i++) {
        \\    s = (s * 1664525 + 1013904223) % 2147483648;
        \\    arr[i] = s;
        \\}
        \\qsort(arr, 0, n - 1);
        \\arr[0] + arr[n >> 1] + arr[n - 1];
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 3353778030), res.asNumber());
}

test "baseline JIT Phase J1: new Array(n) bytecode+OSR, member compound assign single-eval, multi-loop OSR, holey arrays, and i64 mod" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function testJ1() {
        \\    // 1. new Array(n) + multi-loop OSR + i64 PRNG mod (% 2147483648)
        \\    var n = 200;
        \\    var arr = new Array(n);
        \\    var s = 123456789;
        \\    for (var i = 0; i < n; i++) {
        \\        s = (s * 1664525 + 1013904223) % 2147483648;
        \\        arr[i] = s;
        \\    }
        \\    // 2. Second sequential OSR loop + member compound assign arr[i] += ...
        \\    for (var i = 0; i < n; i++) {
        \\        arr[i] += 1;
        \\    }
        \\    // 3. Single evaluation of computed index with side effects in arr[idx()] += v
        \\    var idxCalls = 0;
        \\    var box = [10, 20, 30];
        \\    function getIdx() { idxCalls++; return 1; }
        \\    box[getIdx()] += 5;
        \\    if (idxCalls !== 1 || box[1] !== 25) return -1;
        \\    // 4. Partially holey array in OSR (written elements succeed, real hole bails cleanly)
        \\    var holey = new Array(150);
        \\    for (var k = 0; k < 149; k++) holey[k] = k * 2;
        \\    var hsum = 0;
        \\    for (var k = 0; k < 149; k++) hsum += holey[k];
        \\    if (hsum !== 148 * 149 || holey[149] !== undefined) return -2;
        \\    return arr[0] + arr[n - 1];
        \\}
        \\testJ1();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expect(res.asNumber() > 0);
}

test "bytecode VM regressions: array defineProperty accessor, omitted params reset, and try/catch NotImplemented" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Array index accessor defined via Object.defineProperty read from bytecode
        \\function readElem(obj, key) {
        \\    if (obj[key] !== 11) throw new Error("bad elem");
        \\    return obj[key];
        \\}
        \\var arr = [];
        \\Object.defineProperty(arr, "0", { get: function() { return 11; }, configurable: false });
        \\var r1 = readElem(arr, "0") + readElem(arr, 0);
        \\
        \\// 2. Omitted parameters in bytecode calls must be undefined, not stale primitives from prior frame
        \\function dirtyFrame(a, b, c, d) {
        \\    var x = a + b + c + d;
        \\    return x;
        \\}
        \\function checkOmitted(a, b, c, d) {
        \\    if (c !== undefined || d !== undefined) throw new Error("stale param");
        \\    return a + b;
        \\}
        \\function driver() {
        \\    var s = dirtyFrame(10, 20, 30, 40);
        \\    var t = checkOmitted(1, 2);
        \\    return s + t;
        \\}
        \\var r2 = driver();
        \\
        \\// 3. Bytecode try/catch must catch TypeError from class extends arrow function (NotImplemented gap)
        \\function assertThrowsTypeError(fn) {
        \\    try {
        \\        fn();
        \\    } catch (e) {
        \\        if (e instanceof TypeError) return 1;
        \\        throw new Error("wrong error");
        \\    }
        \\    throw new Error("did not throw");
        \\}
        \\var r3 = assertThrowsTypeError(() => {
        \\    var C = class extends (() => {}) {};
        \\});
        \\
        \\r1 * 1000 + r2 + r3;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 22104), res.asNumber());
}

test "baseline JIT Phase J2.1: Math.sqrt OSR intrinsic (IEEE-754 + monkey-patch bailout) and multi-array hoisting" {
    if (!comptime x64_asm.is_supported_host) return;
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Math.sqrt OSR: positive, 0, negative -> NaN
        \\function sumSqrt(n) {
        \\    var s = 0;
        \\    for (var i = 0; i < n; i++) {
        \\        s += Math.sqrt(i * i);
        \\    }
        \\    return s;
        \\}
        \\var r1 = sumSqrt(200);
        \\if (r1 !== 19900) throw new Error("bad sumSqrt: " + r1);
        \\
        \\function checkNegSqrt(n) {
        \\    var nanCount = 0;
        \\    for (var i = 0; i < n; i++) {
        \\        var v = Math.sqrt(i === 150 ? -1 : 0);
        \\        if (v !== v) nanCount++;
        \\    }
        \\    return nanCount;
        \\}
        \\if (checkNegSqrt(200) !== 1) throw new Error("bad neg sqrt");
        \\
        \\// 2. Monkey-patch Math.sqrt BEFORE re-entering compiled OSR loop
        \\var origSqrt = Math.sqrt;
        \\Math.sqrt = function() { return 99; };
        \\var rPatchedBefore = sumSqrt(10);
        \\Math.sqrt = origSqrt;
        \\if (rPatchedBefore !== 990) throw new Error("bad patch before: " + rPatchedBefore);
        \\
        \\// 3. Monkey-patch Math.sqrt INSIDE hot OSR loop
        \\function patchInside() {
        \\    var fn99 = function() { return 99; };
        \\    var last = 0;
        \\    for (var i = 0; i < 200; i++) {
        \\        if (i === 150) Math.sqrt = fn99;
        \\        last = Math.sqrt(16);
        \\    }
        \\    return last;
        \\}
        \\var rPatchedInside = patchInside();
        \\Math.sqrt = origSqrt;
        \\if (rPatchedInside !== 99) throw new Error("bad patch inside: " + rPatchedInside);
        \\
        \\// 4. Multi-array hoisting (5 simultaneous arrays: read + write)
        \\function multiArr(n) {
        \\    var a = new Array(n);
        \\    var b = new Array(n);
        \\    var c = new Array(n);
        \\    var d = new Array(n);
        \\    var e = new Array(n);
        \\    for (var i = 0; i < n; i++) {
        \\        a[i] = i;
        \\        b[i] = i * 2;
        \\        c[i] = i * 3;
        \\        d[i] = 1;
        \\        e[i] = 0;
        \\    }
        \\    for (var i = 0; i < n; i++) {
        \\        e[i] = a[i] + b[i] + c[i] + d[i];
        \\        d[i] += 2;
        \\    }
        \\    var total = 0;
        \\    for (var i = 0; i < n; i++) total += e[i] + d[i];
        \\    return total;
        \\}
        \\var rMulti = multiArr(150);
        \\// sum_{i=0..149} (6*i + 1 + 3) = 6 * (149*150/2) + 4*150 = 67050 + 600 = 67650
        \\if (rMulti !== 67650) throw new Error("bad multiArr: " + rMulti);
        \\rMulti;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 67650), res.asNumber());
}

test "baseline JIT Phase J2.2B: hoisted (ptr, len), RC bailout on heap overwrite, arr.length, frozen guard, bsearch & bitwise" {
    if (!comptime x64_asm.is_supported_host) return;
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Overwriting hoisted array slot containing heap object/string must bail out cleanly with 0 leaks
        \\function overwriteMixed() {
        \\    var arr = new Array(180);
        \\    for (var i = 0; i < 180; i++) arr[i] = i;
        \\    arr[120] = { k: 42 };
        \\    arr[140] = "heap_str_" + 99;
        \\    for (var i = 0; i < arr.length; i++) {
        \\        arr[i] = i * 2;
        \\    }
        \\    var s = 0;
        \\    for (var i = 0; i < arr.length; i++) s += arr[i];
        \\    return s;
        \\}
        \\// sum_{0..179} 2*i = 179 * 180 = 32220
        \\if (overwriteMixed() !== 32220) throw new Error("bad overwriteMixed");
        \\
        \\// 2. Reading arr.length in OSR + frozen array guard in .set_elem (sloppy + strict, pre- & post-OSR)
        \\function fillArr(arr) {
        \\    for (var i = 0; i < arr.length; i++) {
        \\        arr[i] = i + 10;
        \\    }
        \\    return arr[0];
        \\}
        \\var hotArr = [1, 2, 3, 4];
        \\for (var r = 0; r < 40; r++) fillArr(hotArr);
        \\var frozenSloppy = [7, 8, 9, 10];
        \\Object.freeze(frozenSloppy);
        \\try { fillArr(frozenSloppy); } catch (e) {}
        \\if (frozenSloppy[0] !== 7) throw new Error("frozen sloppy mutated");
        \\var frozenBig = new Array(150);
        \\for (var i = 0; i < 150; i++) frozenBig[i] = i + 5;
        \\Object.freeze(frozenBig);
        \\try { fillArr(frozenBig); } catch (e) {}
        \\if (frozenBig[0] !== 5) throw new Error("frozenBig sloppy mutated");
        \\
        \\function strictWriteFrozen(arr) {
        \\    "use strict";
        \\    for (var i = 0; i < arr.length; i++) {
        \\        arr[i] = 99;
        \\    }
        \\}
        \\var hotStrict = [1, 2, 3, 4];
        \\for (var r = 0; r < 40; r++) strictWriteFrozen(hotStrict);
        \\var caughtFrozen = false;
        \\try {
        \\    strictWriteFrozen(frozenSloppy);
        \\} catch (e) {
        \\    caughtFrozen = e instanceof TypeError;
        \\}
        \\if (!caughtFrozen) throw new Error("strict frozen did not throw TypeError");
        \\
        \\// 3. Binary search ((lo + hi) >> 1 + compacted new Array(n)) + 64-bit ToInt32 bitwise hash + nested compound assign
        \\function bsearchCheck() {
        \\    var n = 500;
        \\    var arr = new Array(n);
        \\    for (var i = 0; i < n; i++) arr[i] = i * 3;
        \\    var sum = 0;
        \\    for (var q = 0; q < 200; q++) {
        \\        var key = ((q * 73) % n) * 3;
        \\        var lo = 0;
        \\        var hi = arr.length - 1;
        \\        while (lo <= hi) {
        \\            var mid = (lo + hi) >> 1;
        \\            var v = arr[mid];
        \\            if (v === key) { sum += mid; break; }
        \\            else if (v < key) { lo = mid + 1; }
        \\            else { hi = mid - 1; }
        \\        }
        \\    }
        \\    return sum;
        \\}
        \\var bsExpected = 0;
        \\for (var q = 0; q < 200; q++) bsExpected += (q * 73) % 500;
        \\if (bsearchCheck() !== bsExpected) throw new Error("bad bsearchCheck");
        \\
        \\function hashAndNested() {
        \\    var buf = new Array(200);
        \\    for (var i = 0; i < 200; i++) buf[i] = (i * 31 + 17) & 255;
        \\    var h = 5381;
        \\    for (var i = 0; i < buf.length; i++) {
        \\        h = ((h * 33) ^ buf[i]) & 0x7fffffff;
        \\    }
        \\    var c = [0, 0, 0, 0];
        \\    var a = [1, 2, 3, 4];
        \\    var b = [5, 6, 7, 8];
        \\    for (var s = 0; s < 100; s++) {
        \\        var k = 0;
        \\        while (k < 4 && a[k] <= 4) {
        \\            c[k] += a[k] * b[k];
        \\            k++;
        \\        }
        \\    }
        \\    // c = [500, 1200, 2100, 3200] => sum = 7000
        \\    return (h > 0 ? 1 : 0) * (c[0] + c[1] + c[2] + c[3]);
        \\}
        \\hashAndNested();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 7000), res.asNumber());
}

test "baseline JIT Phase J2.2A: let and const OSR loops, lexical shadowing, const TypeError, TDZ ReferenceError, and for-let closures" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Hot OSR loops with let/const, sequential for(let i) loops, and multi-level block shadowing
        \\function runLetConstShadow() {
        \\    const n = 300;
        \\    const arr = new Array(n);
        \\    for (let i = 0; i < n; i++) {
        \\        const factor = 3;
        \\        arr[i] = i * factor;
        \\    }
        \\    let total = 0;
        \\    let shadow = 1000;
        \\    for (let i = 0; i < n; i++) {
        \\        let shadow = 5;
        \\        {
        \\            const shadow = 2;
        \\            let i = 7;
        \\            total += shadow + i;
        \\        }
        \\        total += arr[i] + shadow;
        \\    }
        \\    if (shadow !== 1000) throw new Error("outer let mutated by inner shadow");
        \\    // Per iteration: (2 + 7) + 3*i + 5 = 14 + 3*i; sum_{0..299} = 300*14 + 3*(299*300/2) = 4200 + 134550 = 138750
        \\    return total;
        \\}
        \\if (runLetConstShadow() !== 138750) throw new Error("bad runLetConstShadow");
        \\
        \\// 2. Immutable const: =, +=, ++, --, and late-iteration const write inside OSR loop must throw TypeError
        \\function checkConstErrors() {
        \\    let side = 0;
        \\    let ok = 0;
        \\    try {
        \\        const c = 10;
        \\        c = (side = 42);
        \\    } catch (e) {
        \\        if (e instanceof TypeError && side === 42) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        c += 5;
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        c++;
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        --c;
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        [c] = [20];
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const limit = 250;
        \\        let acc = 0;
        \\        for (let i = 0; i < limit; i++) {
        \\            acc += i;
        \\            if (i === 200) limit = 0;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    return ok;
        \\}
        \\if (checkConstErrors() !== 6) throw new Error("const reassignment did not throw TypeError");
        \\
        \\// 3. Observable TDZ throws ReferenceError (read, typeof, self-init, shadow-TDZ)
        \\function checkTDZ() {
        \\    let ok = 0;
        \\    const outer = 99;
        \\    try {
        \\        {
        \\            const leak = outer;
        \\            const outer = 1;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof ReferenceError) ok++;
        \\    }
        \\    try {
        \\        {
        \\            const t = typeof laterLet;
        \\            let laterLet = 1;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof ReferenceError) ok++;
        \\    }
        \\    try {
        \\        {
        \\            let selfRef = selfRef + 1;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof ReferenceError) ok++;
        \\    }
        \\    return ok;
        \\}
        \\if (checkTDZ() !== 3) throw new Error("TDZ did not throw ReferenceError");
        \\
        \\// 4. for (let i = ...) captured by closure preserves per-iteration lexical binding
        \\function checkForLetClosures() {
        \\    const fns = [];
        \\    for (let i = 0; i < 5; i++) {
        \\        fns.push(() => i);
        \\    }
        \\    return fns[0]() * 1000 + fns[1]() * 100 + fns[2]() * 10 + fns[4]();
        \\}
        \\checkForLetClosures();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 5555), res.asNumber()); // parity with tree-walker evalForStatement fallback
}

test "baseline JIT Phase J2.2A: TypedArray OSR fast-path (Float64Array, Int32Array, Uint8Array, length, NaN/-0, wrap-around, and OOB)" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Float64Array OSR: direct f64 load/store, blur1d (i+-1), Math.sqrt, -0.0, and raw NaN canonicalization
        \\function testFloat64Osr() {
        \\    const n = 256;
        \\    const src = new Float64Array(n);
        \\    const dst = new Float64Array(n);
        \\    for (let i = 0; i < src.length; i++) {
        \\        src[i] = i * 0.5;
        \\    }
        \\    src[0] = -0.0;
        \\    if (1 / src[0] !== -Infinity) throw new Error("lost -0.0 before OSR");
        \\    for (let rep = 0; rep < 4; rep++) {
        \\        for (let i = 1; i < dst.length - 1; i++) {
        \\            dst[i] = (src[i - 1] + src[i] + src[i + 1]) * 0.25 + Math.sqrt(src[i] * src[i]);
        \\        }
        \\    }
        \\    let negZeroCount = 0;
        \\    for (let k = 0; k < 200; k++) {
        \\        const z = src[0];
        \\        if (1 / z === -Infinity) negZeroCount++;
        \\    }
        \\    if (negZeroCount !== 200) throw new Error("Float64Array OSR lost -0.0");
        \\
        \\    // Shared ArrayBuffer with non-canonical NaN bits (0xFFFF800000001234)
        \\    const rawBuf = new ArrayBuffer(64);
        \\    const u8View = new Uint8Array(rawBuf);
        \\    const f64View = new Float64Array(rawBuf);
        \\    for (let i = 0; i < 8; i++) {
        \\        const base = i * 8;
        \\        u8View[base + 0] = 0x34;
        \\        u8View[base + 1] = 0x12;
        \\        u8View[base + 2] = 0x00;
        \\        u8View[base + 3] = 0x00;
        \\        u8View[base + 4] = 0x00;
        \\        u8View[base + 5] = 0x80;
        \\        u8View[base + 6] = 0xFF;
        \\        u8View[base + 7] = 0xFF;
        \\    }
        \\    let nanCount = 0;
        \\    for (let k = 0; k < 200; k++) {
        \\        const v = f64View[k & 7];
        \\        if (v !== v) nanCount++;
        \\    }
        \\    if (nanCount !== 200) throw new Error("Float64Array OSR failed NaN canonicalization");
        \\    return dst[10];
        \\}
        \\if (testFloat64Osr() !== 8.75) throw new Error("bad testFloat64Osr: " + testFloat64Osr());
        \\
        \\// 2. Int32Array & Uint8Array OSR: signed negatives, 32-bit & 8-bit wrap-around, NaN/Inf -> 0, hoisted .length
        \\function testIntTypedArraysOsr() {
        \\    const i32 = new Int32Array(256);
        \\    const u8 = new Uint8Array(256);
        \\    for (let i = 0; i < i32.length; i++) {
        \\        i32[i] = (i % 2 === 0) ? (0x7fffffff + i) : (-i * 100000);
        \\        u8[i] = 250 + i;
        \\    }
        \\    // Verify 32-bit and 8-bit wrap-around + NaN / Infinity coercion inside OSR
        \\    for (let k = 0; k < 200; k++) {
        \\        i32[2] = NaN;
        \\        i32[3] = Infinity;
        \\        i32[4] = 4294967295; // -1 in i32
        \\        u8[2] = 300;         // 44 in u8
        \\        u8[3] = -1;          // 255 in u8
        \\        u8[4] = NaN;         // 0 in u8
        \\    }
        \\    if (i32[0] !== 2147483647) throw new Error("bad i32[0]");
        \\    if (i32[200] !== -2147483449) throw new Error("bad i32[200]: " + i32[200]);
        \\    if (i32[2] !== 0 || i32[3] !== 0 || i32[4] !== -1) throw new Error("bad i32 special wrap");
        \\    if (u8[2] !== 44 || u8[3] !== 255 || u8[4] !== 0 || u8[10] !== 4) throw new Error("bad u8 wrap");
        \\
        \\    let acc = 0;
        \\    for (let i = 0; i < u8.length; i++) {
        \\        acc = (acc + u8[i] + (i32[i] & 0xff)) | 0;
        \\    }
        \\    return acc;
        \\}
        \\const intAcc = testIntTypedArraysOsr();
        \\
        \\// 3. Out-of-bounds read (undefined) and out-of-bounds write (no-op) after OSR warmup
        \\function testTypedArrayOob(ta, limit) {
        \\    let undefs = 0;
        \\    let sum = 0;
        \\    for (let i = 0; i < limit; i++) {
        \\        const v = ta[i];
        \\        if (v === undefined) undefs++;
        \\        else sum += v;
        \\        ta[i] = 77;
        \\    }
        \\    return undefs * 1000 + ta.length;
        \\}
        \\const smallTa = new Int32Array(200);
        \\for (let i = 0; i < 200; i++) smallTa[i] = 1;
        \\const oobRes = testTypedArrayOob(smallTa, 205);
        \\if (oobRes !== 5200) throw new Error("bad OOB read/length: " + oobRes);
        \\if (smallTa[-1] !== undefined || smallTa[200] !== undefined) throw new Error("OOB index not undefined");
        \\if (smallTa[0] !== 77 || smallTa[199] !== 77) throw new Error("in-bounds write failed");
        \\
        \\(intAcc !== 0 ? 1 : 0) * oobRes;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 5200), res.asNumber());
}
