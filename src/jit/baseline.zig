const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const environment_mod = @import("../environment.zig");
const Environment = environment_mod.Environment;
const codeblock = @import("../bytecode/codeblock.zig");
const vm = @import("../bytecode/vm.zig");
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

fn compileFastSelfRec(
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

pub fn compile(allocator: Allocator, block: *codeblock.CodeBlock) bool {
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

fn emitGlobalSlotLookup(
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

fn emitGuardNonHeapInOsr(a: *Assembler, reg_idx: u8, _: Label) !void {
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

fn emitCmpToBool(a: *Assembler, opcode: codeblock.Opcode) !void {
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

fn emitCondJump(a: *Assembler, is_true_jump: bool, src_reg: u8, target_lbl: Label, bail_lbl: Label) !void {
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

fn emitSharedOp(a: *Assembler, block: *const codeblock.CodeBlock, op: codeblock.Op, is_osr: bool, bail_lbl: Label) !bool {
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
            // lhs: positive exact int32 (also rejects -0.0 via sign bit check)
            try a.movRegReg(.rdx, .rax);
            try a.shrRegImm8(.rdx, 63);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.cvttsd2siReg32Xmm(.rax, .xmm0);
            try a.cmpReg32Imm32(.rax, -0x80000000);
            try a.jcc(.e, bail_lbl);
            try a.cvtsi2sdXmmReg32(.xmm2, .rax);
            try a.ucomisd(.xmm0, .xmm2);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
            // rhs: strictly positive exact int32 (> 0)
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 63);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
            try a.cmpReg32Imm32(.rcx, -0x80000000);
            try a.jcc(.e, bail_lbl);
            try a.testReg32Reg32(.rcx, .rcx);
            try a.jcc(.e, bail_lbl);
            try a.cvtsi2sdXmmReg32(.xmm2, .rcx);
            try a.ucomisd(.xmm1, .xmm2);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.xorReg32Reg32(.rdx, .rdx);
            try a.divReg32(.rcx);
            try a.cvtsi2sdXmmReg32(.xmm0, .rdx);
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

fn compileImpl(
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

pub fn canCompileOsr(block: *const codeblock.CodeBlock, start_ip: usize, end_ip: usize) bool {
    if (!comptime x64_asm.is_supported_host) return false;
    if (block.exception_table.len > 0 or block.flags.has_try) return false;
    if (block.register_count == 0 or block.register_count > 32) return false;
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
            .get_elem_const => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.constants.len) return false;
                if (block.constants[op.c] != .number) return false;
                const n = block.constants[op.c].number;
                if (n < 0 or n > 255 or @as(f64, @floatFromInt(@as(usize, @intFromFloat(n)))) != n) return false;
            },
            .new_object => {
                if (op.a >= block.register_count) return false;
            },
            .set_prop, .set_prop_transition => {
                if (op.a >= block.register_count or op.c >= block.register_count) return false;
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
                if (cs.this_reg != null) return false;
                const tb = cs.target_block orelse return false;
                if (tb.param_count != cs.arg_count) return false;
                if ((@as(usize, op.b) + 1 + cs.arg_count) > block.register_count) return false;
                if (tb.jit_fn == null and !canCompile(tb)) return false;
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

pub fn compileOsr(allocator: Allocator, block: *codeblock.CodeBlock, start_ip: usize, end_ip: usize, prop_ic_ptr: ?*const anyopaque) bool {
    if (block.osr_fn != null) return true;
    if (block.osr_failed) return false;
    if (!canCompileOsr(block, start_ip, end_ip)) {
        block.osr_failed = true;
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

    const exec = compileOsrImpl(allocator, block, start_ip, end_ip, prop_ic_ptr) catch {
        block.osr_failed = true;
        return false;
    };
    block.osr_header_ip = @intCast(start_ip);
    block.osr_end_ip = @intCast(end_ip);
    block.osr_code = exec;
    block.osr_fn = @ptrCast(exec.ptr);
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

fn analyzePromotedProps(
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

const OsrCachedAnalysis = struct {
    cached_regs: [12]u8 = @splat(0),
    cached_count: usize = 0,
    reg_to_xmm: [64]?Xmm = @splat(null),
    read_before_written: [64]bool = @splat(false),
    promoted: PromotedPropsAnalysis = .{},
};

fn analyzeOsrLoop(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic: ?*const [256]PropIC,
) OsrCachedAnalysis {
    var result = OsrCachedAnalysis{};

    // 1. Pureza del bucle (is_pure_loop): true solo si ningún opcode en [start_ip .. end_ip]
    // es .call, .call_global
    var is_pure_loop = true;
    for (start_ip..end_ip + 1) |ip| {
        switch (block.ops[ip].opcode) {
            .call, .call_global => {
                is_pure_loop = false;
                break;
            },
            else => {},
        }
    }
    if (!is_pure_loop) return result;

    var invalid: [64]bool = @splat(false);
    var written: [64]bool = @splat(false);
    var read_before_written: [64]bool = @splat(false);
    var use_count: [64]u32 = @splat(0);

    for (start_ip..end_ip + 1) |ip| {
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop => {},
            .add, .add_num, .sub_num, .mul_num, .div_num, .mod_num, .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] += 1;
                }
                if (op.a < 64) {
                    use_count[op.a] += 1;
                    written[op.a] = true;
                }
            },
            .add_local_const, .sub_local_const => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.a < 64) {
                    use_count[op.a] += 1;
                    written[op.a] = true;
                }
            },
            .neg, .not_bits => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.a < 64) {
                    use_count[op.a] += 1;
                    written[op.a] = true;
                }
            },
            .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => {
                if (op.a < 64) {
                    if (!written[op.a]) read_before_written[op.a] = true;
                    use_count[op.a] += 1;
                }
            },
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] += 1;
                }
                if (op.a < 64) {
                    invalid[op.a] = true;
                    written[op.a] = true;
                }
            },
            .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.a < 64) {
                    invalid[op.a] = true;
                    written[op.a] = true;
                }
            },
            .get_elem => {
                if (op.b < 64) invalid[op.b] = true;
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] += 1;
                }
                if (op.a < 64) {
                    use_count[op.a] += 1;
                    written[op.a] = true;
                }
            },
            .set_elem => {
                if (op.a < 64) invalid[op.a] = true;
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] += 1;
                }
            },
            .get_elem_const => {
                if (op.b < 64) invalid[op.b] = true;
                if (op.a < 64) {
                    use_count[op.a] += 1;
                    written[op.a] = true;
                }
            },
            .set_elem_const => {
                if (op.a < 64) invalid[op.a] = true;
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] += 1;
                }
            },
            .get_prop => {
                if (op.b < 64) invalid[op.b] = true;
                if (op.a < 64) {
                    use_count[op.a] += 1;
                    written[op.a] = true;
                }
            },
            .set_prop, .set_prop_transition => {
                if (op.a < 64) invalid[op.a] = true;
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] += 1;
                }
            },
            .new_array, .new_object => {
                if (op.a < 64) invalid[op.a] = true;
            },
            .load_const => {
                if (op.a < 64) {
                    if (block.constants[op.b] == .number) {
                        use_count[op.a] += 1;
                        written[op.a] = true;
                    } else {
                        invalid[op.a] = true;
                    }
                }
            },
            .move, .load_local, .store_local => {
                if (op.b < 64) {
                    if (!written[op.b]) read_before_written[op.b] = true;
                    use_count[op.b] += 1;
                }
                if (op.a < 64) {
                    use_count[op.a] += 1;
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

    // Propagate invalidity across move / load_local / store_local
    for (0..4) |_| {
        for (start_ip..end_ip + 1) |ip| {
            const op = block.ops[ip];
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

    var promoted = analyzePromotedProps(block, start_ip, end_ip, prop_ic);
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

    return result;
}

fn emitFlushPromoted(a: *Assembler, promoted: PromotedPropsAnalysis) !void {
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

fn emitReloadPromoted(a: *Assembler, promoted: PromotedPropsAnalysis) !void {
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

fn canElideLoadConst(
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
            const rhs_i32 = asExactInt32(c.number) orelse return false;
            if (rhs_i32 <= 0) return false;
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

fn emitFlushCached(a: *Assembler, cached_regs: [12]u8, cached_count: usize) !void {
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

fn emitReloadCached(a: *Assembler, cached_regs: [12]u8, cached_count: usize) !void {
    for (0..cached_count) |k| {
        const r = cached_regs[k];
        const xmm_k = @as(Xmm, @enumFromInt(4 + k));
        try a.movsdXmmMem(xmm_k, .r12, @intCast(@as(usize, r) * 8));
    }
}

fn emitReleaseHeapIfRefGt1(
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

fn emitLoadNumToXmm(
    a: *Assembler,
    reg_to_xmm: [64]?Xmm,
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

fn emitStoreXmmToNum(
    a: *Assembler,
    reg_to_xmm: [64]?Xmm,
    cached_regs: [12]u8,
    cached_count: usize,
    r: u8,
    src_xmm: Xmm,
    bail_lbl: Label,
) !void {
    _ = cached_regs;
    _ = cached_count;
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

fn compileOsrImpl(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic_ptr: ?*const anyopaque,
) ![]align(std.heap.page_size_min) u8 {
    var a = Assembler.init(allocator);
    defer a.deinit();
    const prop_ic: ?*const [256]PropIC = if (prop_ic_ptr) |p| @ptrCast(@alignCast(p)) else null;

    const analysis = analyzeOsrLoop(block, start_ip, end_ip, prop_ic);
    const cached_regs = analysis.cached_regs;
    const cached_count = analysis.cached_count;
    const reg_to_xmm = analysis.reg_to_xmm;
    const promoted = analysis.promoted;
    const has_flush = (cached_count > 0 or promoted.count > 0);

    const loop_len = end_ip - start_ip + 1;
    var op_labels = try allocator.alloc(Label, loop_len);
    defer allocator.free(op_labels);
    var bailout_labels = try allocator.alloc(Label, loop_len);
    defer allocator.free(bailout_labels);
    var bailout_target_ips = try allocator.alloc(u32, loop_len);
    defer allocator.free(bailout_target_ips);
    var is_jump_target = try allocator.alloc(bool, loop_len);
    defer allocator.free(is_jump_target);
    @memset(is_jump_target, false);
    is_jump_target[0] = true;
    var is_back_target = try allocator.alloc(bool, loop_len);
    defer allocator.free(is_back_target);
    @memset(is_back_target, false);
    is_back_target[0] = true;

    const ElidedConst = struct { reg: u8, bits: u64 };
    var elided_consts = try allocator.alloc(?ElidedConst, loop_len);
    defer allocator.free(elided_consts);
    @memset(elided_consts, null);

    for (0..loop_len) |i| {
        op_labels[i] = try a.createLabel();
        bailout_labels[i] = try a.createLabel();
        bailout_target_ips[i] = @intCast(start_ip + i);
        const scan_ip = start_ip + i;
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
    }
    const preheader_bailout = try a.createLabel();
    const flush_and_exit = try a.createLabel();
    const osr_epilogue = try a.createLabel();

    const ExitStub = struct {
        label: Label,
        target_ip: u32,
    };
    var exit_stubs: std.ArrayListUnmanaged(ExitStub) = .empty;
    defer exit_stubs.deinit(allocator);

    // Entry: fn(regs: [*]JSValue, ctx: *OsrContext) callconv(.c) u32
    // %rdi = regs, %rsi = ctx
    // 5 pushes => %rsp is 16-byte aligned throughout OsrFn
    try a.pushReg(.rbx);
    try a.pushReg(.r12);
    try a.pushReg(.r13);
    try a.pushReg(.r14);
    try a.pushReg(.r15);

    try a.movRegReg(.r12, .rdi); // %r12 = regs
    try a.movRegReg(.r13, .rsi); // %r13 = ctx
    try a.movRegImm64(.r14, JSValue.HEAP_BASE); // %r14 = HEAP_BASE
    try a.movRegImm64(.r15, JSValue.BASE_TAG); // %r15 = BASE_TAG

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
    }

    // Pre-header for cached registers
    if (cached_count > 0) {
        for (0..cached_count) |k| {
            const r = cached_regs[k];
            const xmm_k = @as(Xmm, @enumFromInt(4 + k));
            if (analysis.read_before_written[r]) {
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

    var known_f64: [64]?f64 = @splat(null);
    var reg_is_int32: [64]bool = @splat(false);
    var reg_is_uint31: [64]bool = @splat(false);
    var incoming_has_edge = try allocator.alloc(bool, loop_len);
    defer allocator.free(incoming_has_edge);
    @memset(incoming_has_edge, false);
    var incoming_int32 = try allocator.alloc([64]bool, loop_len);
    defer allocator.free(incoming_int32);
    var incoming_uint31 = try allocator.alloc([64]bool, loop_len);
    defer allocator.free(incoming_uint31);

    for (0..loop_len) |idx| {
        const ip = start_ip + idx;
        const op = block.ops[ip];
        const bail_lbl = bailout_labels[idx];
        a.bindLabel(op_labels[idx]);
        if (is_jump_target[idx]) {
            known_f64 = @splat(null);
        }
        if (is_back_target[idx]) {
            reg_is_int32 = @splat(false);
            reg_is_uint31 = @splat(false);
        } else if (incoming_has_edge[idx]) {
            const prev_uncond_jump = idx > 0 and block.ops[start_ip + idx - 1].opcode == .jump;
            if (prev_uncond_jump) {
                reg_is_int32 = incoming_int32[idx];
                reg_is_uint31 = incoming_uint31[idx];
            } else {
                for (0..64) |r_i| {
                    reg_is_int32[r_i] = reg_is_int32[r_i] and incoming_int32[idx][r_i];
                    reg_is_uint31[r_i] = reg_is_uint31[r_i] and incoming_uint31[idx][r_i];
                }
            }
        }
        defer {
            switch (op.opcode) {
                .nop,
                .set_elem,
                .set_elem_const,
                .set_prop,
                .set_prop_transition,
                => {},
                .jump, .jump_if_false, .jump_if_true => {
                    const t = (@as(usize, op.b) << 8) | op.c;
                    if (t > ip and t <= end_ip) {
                        const t_idx = t - start_ip;
                        if (!incoming_has_edge[t_idx]) {
                            incoming_has_edge[t_idx] = true;
                            incoming_int32[t_idx] = reg_is_int32;
                            incoming_uint31[t_idx] = reg_is_uint31;
                        } else {
                            for (0..64) |r_i| {
                                incoming_int32[t_idx][r_i] = incoming_int32[t_idx][r_i] and reg_is_int32[r_i];
                                incoming_uint31[t_idx][r_i] = incoming_uint31[t_idx][r_i] and reg_is_uint31[r_i];
                            }
                        }
                    }
                },
                .jeq_local_const_false,
                .jlt_local_const_false,
                .jle_local_const_false,
                .jgt_local_const_false,
                .jge_local_const_false,
                => {
                    const t = ip + @as(usize, op.c);
                    if (t > ip and t <= end_ip) {
                        const t_idx = t - start_ip;
                        if (!incoming_has_edge[t_idx]) {
                            incoming_has_edge[t_idx] = true;
                            incoming_int32[t_idx] = reg_is_int32;
                            incoming_uint31[t_idx] = reg_is_uint31;
                        } else {
                            for (0..64) |r_i| {
                                incoming_int32[t_idx][r_i] = incoming_int32[t_idx][r_i] and reg_is_int32[r_i];
                                incoming_uint31[t_idx][r_i] = incoming_uint31[t_idx][r_i] and reg_is_uint31[r_i];
                            }
                        }
                    }
                },
                .load_const => {
                    if (op.a < 64) {
                        if (block.constants[op.b] == .number) {
                            const n = block.constants[op.b].number;
                            known_f64[op.a] = n;
                            if (asExactInt32(n)) |i_val| {
                                reg_is_int32[op.a] = (i_val != std.math.minInt(i32));
                                reg_is_uint31[op.a] = (i_val >= 0);
                            } else {
                                reg_is_int32[op.a] = false;
                                reg_is_uint31[op.a] = false;
                            }
                        } else {
                            known_f64[op.a] = null;
                            reg_is_int32[op.a] = false;
                            reg_is_uint31[op.a] = false;
                        }
                    }
                },
                .move, .load_local, .store_local => {
                    if (op.a < 64) {
                        known_f64[op.a] = if (op.b < 64) known_f64[op.b] else null;
                        reg_is_int32[op.a] = if (op.b < 64) reg_is_int32[op.b] else false;
                        reg_is_uint31[op.a] = if (op.b < 64) reg_is_uint31[op.b] else false;
                    }
                },
                .not_bits, .or_bits, .xor_bits, .shl, .shr => {
                    if (op.a < 64) {
                        known_f64[op.a] = null;
                        reg_is_int32[op.a] = true;
                        reg_is_uint31[op.a] = false;
                    }
                },
                .and_bits => {
                    if (op.a < 64) {
                        const rhs_nonneg = if (op.c < 64 and known_f64[op.c] != null)
                            (if (asExactInt32(known_f64[op.c].?)) |v| v >= 0 else false)
                        else
                            false;
                        const is_u31 = rhs_nonneg or (op.b < 64 and reg_is_uint31[op.b]) or (op.c < 64 and reg_is_uint31[op.c]);
                        known_f64[op.a] = null;
                        reg_is_int32[op.a] = true;
                        reg_is_uint31[op.a] = is_u31;
                    }
                },
                .ushr => {
                    if (op.a < 64) {
                        const sh_gt0 = if (op.c < 64 and known_f64[op.c] != null) blk: {
                            if (asExactInt32(known_f64[op.c].?)) |v| {
                                break :blk ((@as(u32, @bitCast(v)) & 31) >= 1);
                            }
                            break :blk false;
                        } else false;
                        known_f64[op.a] = null;
                        reg_is_int32[op.a] = sh_gt0;
                        reg_is_uint31[op.a] = sh_gt0;
                    }
                },
                .mod_num => {
                    if (op.a < 64) {
                        known_f64[op.a] = null;
                        reg_is_int32[op.a] = true;
                        reg_is_uint31[op.a] = true;
                    }
                },
                else => {
                    if (op.a < 64) {
                        known_f64[op.a] = null;
                        reg_is_int32[op.a] = false;
                        reg_is_uint31[op.a] = false;
                    }
                },
            }
        }

        switch (op.opcode) {
            .nop => {},
            .load_undefined => {
                try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
            },
            .load_const => {
                const c = block.constants[op.b];
                const bits = switch (c) {
                    .number => |n| JSValue.fromNumber(n).bits,
                    .boolean => |b| JSValue.fromBool(b).bits,
                    else => unreachable,
                };
                if (canElideLoadConst(block, start_ip, end_ip, idx, is_jump_target)) {
                    elided_consts[idx + 1] = .{ .reg = op.a, .bits = bits };
                    bailout_target_ips[idx + 1] = @intCast(ip);
                    continue;
                }
                if (op.a < 64 and reg_to_xmm[op.a] != null) {
                    const xmm_k = reg_to_xmm[op.a].?;
                    try a.movRegImm64(.rax, bits);
                    try a.movqXmmReg(xmm_k, .rax);
                } else {
                    try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                    try a.movRegImm64(.rax, bits);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                }
            },
            .move, .load_local, .store_local => {
                if (op.a != op.b) {
                    const a_cached = (op.a < 64 and reg_to_xmm[op.a] != null);
                    const b_cached = (op.b < 64 and reg_to_xmm[op.b] != null);
                    if (a_cached and b_cached) {
                        try a.movsdXmmXmm(reg_to_xmm[op.a].?, reg_to_xmm[op.b].?);
                    } else if (a_cached and !b_cached) {
                        try emitLoadNumToXmm(&a, reg_to_xmm, op.b, reg_to_xmm[op.a].?, bail_lbl);
                    } else if (!a_cached and b_cached) {
                        try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                        try a.movqRegXmm(.rax, reg_to_xmm[op.b].?);
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                    } else {
                        const heap_move_lbl = try a.createLabel();
                        const done_move_lbl = try a.createLabel();

                        // Release old regs[dst] if it's a heap ref with rc > 1
                        try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);

                        // Load val = regs[src]
                        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                        try a.cmpRegReg(.rax, .r14);
                        try a.jcc(.ae, heap_move_lbl);

                        // val < HEAP_BASE: write regs[dst] = val
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                        try a.jmp(done_move_lbl);

                        // val >= HEAP_BASE: check if (val >> 47) == HEADER_ARRAY or HEADER_FUNCTION
                        a.bindLabel(heap_move_lbl);
                        try a.movRegReg(.rcx, .rax);
                        try a.shrRegImm8(.rcx, 47);
                        const inc_rc_lbl = try a.createLabel();
                        try a.cmpRegImm32(.rcx, HEADER_ARRAY);
                        try a.jcc(.e, inc_rc_lbl);
                        try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
                        try a.jcc(.e, inc_rc_lbl);
                        try a.cmpRegImm32(.rcx, HEADER_OBJECT);
                        try a.jcc(.ne, bail_lbl);

                        // Retain: ptr = val & PTR_MASK; ptr._count += 1
                        a.bindLabel(inc_rc_lbl);
                        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                        try a.andRegReg(.rcx, .rax);
                        try a.incMem64(.rcx, 0);
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);

                        a.bindLabel(done_move_lbl);
                    }
                }
            },
            .jump_if_false, .jump_if_true => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                const target_lbl = if (target_pc >= start_ip and target_pc <= end_ip)
                    op_labels[target_pc - start_ip]
                else blk: {
                    const el = try a.createLabel();
                    try exit_stubs.append(allocator, .{ .label = el, .target_ip = @intCast(target_pc) });
                    break :blk el;
                };
                try emitCondJump(&a, op.opcode == .jump_if_true, op.a, target_lbl, bail_lbl);
            },
            .get_elem => {
                const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
                const ZArr = zvalue.ZArray(JSValue);
                const ArrList = @FieldType(ZArr, "items");
                const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
                const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
                const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
                const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
                const arr_items_len_off: i32 = arr_items_ptr_off + 8;

                // arr = regs[op.b]; guard (arr >> 47) == 0x1FFF4 (HEADER_ARRAY)
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, HEADER_ARRAY);
                try a.jcc(.ne, bail_lbl);
                try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                try a.andRegReg(.rax, .rcx);

                // guard box.holey == null
                try a.movRegMem(.rcx, .rax, arr_holey_off);
                try a.testRegReg(.rcx, .rcx);
                try a.jcc(.ne, bail_lbl);

                // key = regs[op.c]; guard key < BASE_TAG and exact int32 >= 0
                try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                if (!(op.c < 64 and reg_is_int32[op.c])) {
                    try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                    try a.ucomisd(.xmm0, .xmm1);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                }
                if (!(op.c < 64 and reg_is_uint31[op.c])) {
                    // sign check on 32-bit int: (rcx >> 31) == 0
                    try a.movRegReg(.rdx, .rcx);
                    try a.shrRegImm8(.rdx, 31);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, bail_lbl);
                }

                // guard idx < box.items.len
                try a.movRegMem(.rdx, .rax, arr_items_len_off);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bail_lbl);

                // elem = box.items.ptr[idx]; guard elem < BASE_TAG
                try a.movRegMem(.rax, .rax, arr_items_ptr_off);
                try a.movRegMemIndexed8(.rax, .rax, .rcx, 0);
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bail_lbl);

                if (op.a < 64 and reg_to_xmm[op.a] != null) {
                    const xmm_k = reg_to_xmm[op.a].?;
                    try a.movqXmmReg(xmm_k, .rax);
                } else {
                    try a.movRegReg(.rdx, .rax);
                    try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rdx);
                }
            },
            .set_elem => {
                const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
                const ZArr = zvalue.ZArray(JSValue);
                const ArrList = @FieldType(ZArr, "items");
                const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
                const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
                const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
                const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
                const arr_items_len_off: i32 = arr_items_ptr_off + 8;
                const arr_items_cap_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "capacity")));

                const append_lbl = try a.createLabel();
                const done_lbl = try a.createLabel();

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

                // arr = regs[op.a]; guard (arr >> 47) == HEADER_ARRAY
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, HEADER_ARRAY);
                try a.jcc(.ne, bail_lbl);
                try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                try a.andRegReg(.rax, .rcx);

                // guard box.holey == null
                try a.movRegMem(.rcx, .rax, arr_holey_off);
                try a.testRegReg(.rcx, .rcx);
                try a.jcc(.ne, bail_lbl);

                // key = regs[op.b]; guard key < BASE_TAG and exact int32 >= 0
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                if (!(op.b < 64 and reg_is_int32[op.b])) {
                    try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                    try a.ucomisd(.xmm0, .xmm1);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                }
                if (!(op.b < 64 and reg_is_uint31[op.b])) {
                    try a.movRegReg(.rdx, .rcx);
                    try a.shrRegImm8(.rdx, 31);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, bail_lbl);
                }

                // len = box.items.len
                try a.movRegMem(.rdx, .rax, arr_items_len_off);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.e, append_lbl);
                try a.jcc(.a, bail_lbl);

                // Overwrite: idx < len; guard old elem < HEAP_BASE (%r14)
                try a.movRegMem(.r11, .rax, arr_items_ptr_off);
                try a.movRegMemIndexed8(.rdx, .r11, .rcx, 0);
                try a.cmpRegReg(.rdx, .r14);
                try a.jcc(.ae, bail_lbl);
                try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
                try a.jmp(done_lbl);

                // Append: idx == len; guard idx < box.items.capacity
                a.bindLabel(append_lbl);
                try a.movRegMem(.r11, .rax, arr_items_cap_off);
                try a.cmpRegReg(.rcx, .r11);
                try a.jcc(.ae, bail_lbl);
                try a.movRegMem(.r11, .rax, arr_items_ptr_off);
                try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
                try a.addRegImm32(.rdx, 1);
                try a.movMemReg(.rax, arr_items_len_off, .rdx);

                a.bindLabel(done_lbl);
            },
            .add, .add_num, .sub_num, .mul_num => {
                if (op.a < 64 and reg_to_xmm[op.a] != null and op.a == op.b) {
                    const xmm_a = reg_to_xmm[op.a].?;
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                    switch (op.opcode) {
                        .add, .add_num => try a.addsd(xmm_a, .xmm1),
                        .sub_num => try a.subsd(xmm_a, .xmm1),
                        .mul_num => try a.mulsd(xmm_a, .xmm1),
                        else => unreachable,
                    }
                } else {
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                    switch (op.opcode) {
                        .add, .add_num => try a.addsd(.xmm0, .xmm1),
                        .sub_num => try a.subsd(.xmm0, .xmm1),
                        .mul_num => try a.mulsd(.xmm0, .xmm1),
                        else => unreachable,
                    }
                    try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
                }
            },
            .add_local_const, .sub_local_const => {
                const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
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
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                    try a.movRegImm64(.rcx, c_bits);
                    try a.movqXmmReg(.xmm1, .rcx);
                    if (op.opcode == .add_local_const) {
                        try a.addsd(.xmm0, .xmm1);
                    } else {
                        try a.subsd(.xmm0, .xmm1);
                    }
                    try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
                }
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const c_bits = JSValue.fromNumber(block.constants[op.b].number).bits;
                const target_pc = ip + @as(usize, op.c);
                const target_lbl = if (target_pc >= start_ip and target_pc <= end_ip)
                    op_labels[target_pc - start_ip]
                else blk: {
                    const el = try a.createLabel();
                    try exit_stubs.append(allocator, .{ .label = el, .target_ip = @intCast(target_pc) });
                    break :blk el;
                };

                const xmm_src: Xmm = if (op.a < 64 and reg_to_xmm[op.a] != null)
                    reg_to_xmm[op.a].?
                else blk: {
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.a, .xmm0, bail_lbl);
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
            .div_num => {
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                const maybe_recip: ?u64 = if (op.c < 64 and known_f64[op.c] != null)
                    asPowerOfTwoReciprocal(known_f64[op.c].?)
                else
                    null;
                if (maybe_recip) |recip_bits| {
                    try a.movRegImm64(.rcx, recip_bits);
                    try a.movqXmmReg(.xmm1, .rcx);
                    try a.mulsd(.xmm0, .xmm1);
                } else {
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                    try a.divsd(.xmm0, .xmm1);
                }
                try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
            },
            .mod_num => {
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                const maybe_rhs_i32: ?i32 = if (op.c < 64 and known_f64[op.c] != null) blk: {
                    if (asExactInt32(known_f64[op.c].?)) |v| {
                        if (v > 0) break :blk v;
                    }
                    break :blk null;
                } else null;
                if (maybe_rhs_i32 == null) {
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                }
                // lhs: positive exact int32
                try a.movqRegXmm(.rax, .xmm0);
                try a.movRegReg(.rdx, .rax);
                try a.shrRegImm8(.rdx, 63);
                try a.testRegReg(.rdx, .rdx);
                try a.jcc(.ne, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rax, .xmm0);
                try a.cmpReg32Imm32(.rax, -0x80000000);
                try a.jcc(.e, bail_lbl);
                try a.cvtsi2sdXmmReg32(.xmm2, .rax);
                try a.ucomisd(.xmm0, .xmm2);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);

                if (maybe_rhs_i32) |rhs_i32| {
                    try a.movRegImm32(.rcx, @bitCast(rhs_i32));
                } else {
                    // rhs: strictly positive exact int32 (> 0)
                    try a.movqRegXmm(.rcx, .xmm1);
                    try a.movRegReg(.rdx, .rcx);
                    try a.shrRegImm8(.rdx, 63);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, bail_lbl);
                    try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
                    try a.cmpReg32Imm32(.rcx, -0x80000000);
                    try a.jcc(.e, bail_lbl);
                    try a.testReg32Reg32(.rcx, .rcx);
                    try a.jcc(.e, bail_lbl);
                    try a.cvtsi2sdXmmReg32(.xmm2, .rcx);
                    try a.ucomisd(.xmm1, .xmm2);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                }

                try a.xorReg32Reg32(.rdx, .rdx);
                try a.divReg32(.rcx);
                try a.cvtsi2sdXmmReg32(.xmm0, .rdx);
                try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
            },
            .neg => {
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.movqRegXmm(.rax, .xmm0);
                try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
                try a.xorRegReg64(.rax, .rcx);
                try a.movqXmmReg(.xmm0, .rax);
                try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
            },
            .not_bits => {
                const slow_lbl = try a.createLabel();
                const done_lbl = try a.createLabel();
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.cvttsd2siReg32Xmm(.rax, .xmm0);
                if (!(op.b < 64 and reg_is_int32[op.b])) {
                    try a.cmpReg32Imm32(.rax, -0x80000000);
                    try a.jcc(.e, slow_lbl);
                }
                try a.notReg32(.rax);
                try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
                try a.jmp(done_lbl);

                a.bindLabel(slow_lbl);
                if (cached_count > 0) {
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                if (promoted.count > 0) {
                    try emitFlushPromoted(&a, promoted);
                }
                try a.movRegReg(.rdi, .r12);
                try a.movRegImm32(.rsi, op.a);
                try a.movRegImm32(.rdx, op.b);
                try a.movRegImm32(.rcx, op.b);
                try a.movRegImm32(.r8, 6);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }
                if (promoted.count > 0) {
                    try emitReloadPromoted(&a, promoted);
                }
                a.bindLabel(done_lbl);
            },
            .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                const slow_lbl = try a.createLabel();
                const done_lbl = try a.createLabel();
                const maybe_rhs_i32: ?i32 = if (op.c < 64 and known_f64[op.c] != null)
                    asExactInt32(known_f64[op.c].?)
                else
                    null;

                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                if (maybe_rhs_i32 == null) {
                    try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                }
                try a.cvttsd2siReg32Xmm(.rax, .xmm0);
                if (!(op.b < 64 and reg_is_int32[op.b])) {
                    try a.cmpReg32Imm32(.rax, -0x80000000);
                    try a.jcc(.e, slow_lbl);
                }

                if (maybe_rhs_i32) |rhs_i32| {
                    switch (op.opcode) {
                        .and_bits => {
                            try a.andReg32Imm32(.rax, rhs_i32);
                            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                        },
                        .or_bits => {
                            if (rhs_i32 != 0) try a.orReg32Imm32(.rax, rhs_i32);
                            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                        },
                        .xor_bits => {
                            if (rhs_i32 != 0) try a.xorReg32Imm32(.rax, rhs_i32);
                            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                        },
                        .shl => {
                            const sh_amt: u8 = @intCast(@as(u32, @bitCast(rhs_i32)) & 31);
                            if (sh_amt != 0) try a.shlReg32Imm8(.rax, sh_amt);
                            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                        },
                        .shr => {
                            const sh_amt: u8 = @intCast(@as(u32, @bitCast(rhs_i32)) & 31);
                            if (sh_amt != 0) try a.sarReg32Imm8(.rax, sh_amt);
                            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                        },
                        .ushr => {
                            const sh_amt: u8 = @intCast(@as(u32, @bitCast(rhs_i32)) & 31);
                            if (sh_amt != 0) try a.shrReg32Imm8(.rax, sh_amt);
                            try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
                        },
                        else => unreachable,
                    }
                } else {
                    try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
                    if (!(op.c < 64 and reg_is_int32[op.c])) {
                        try a.cmpReg32Imm32(.rcx, -0x80000000);
                        try a.jcc(.e, slow_lbl);
                    }
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
                }
                try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, .xmm0, bail_lbl);
                try a.jmp(done_lbl);

                a.bindLabel(slow_lbl);
                if (elided_consts[idx]) |ec| {
                    try a.movRegImm64(.rax, ec.bits);
                    if (ec.reg < 64 and reg_to_xmm[ec.reg] != null) {
                        try a.movqXmmReg(reg_to_xmm[ec.reg].?, .rax);
                    } else {
                        try a.movMemReg(.r12, @intCast(@as(usize, ec.reg) * 8), .rax);
                    }
                }
                if (cached_count > 0) {
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                if (promoted.count > 0) {
                    try emitFlushPromoted(&a, promoted);
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
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }
                if (promoted.count > 0) {
                    try emitReloadPromoted(&a, promoted);
                }
                a.bindLabel(done_lbl);
            },
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try emitLoadNumToXmm(&a, reg_to_xmm, op.c, .xmm1, bail_lbl);
                try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                try emitCmpToBool(&a, op.opcode);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
                const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
                try emitLoadNumToXmm(&a, reg_to_xmm, op.b, .xmm0, bail_lbl);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                try emitCmpToBool(&a, op.opcode);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .jump => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                if (target_pc >= start_ip and target_pc <= end_ip) {
                    try a.jmp(op_labels[target_pc - start_ip]);
                } else {
                    try a.movRegImm32(.rax, @intCast(target_pc));
                    if (has_flush) {
                        try a.jmp(flush_and_exit);
                    } else {
                        try a.jmp(osr_epilogue);
                    }
                }
            },
            .new_array => {
                const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
                const ZArr = zvalue.ZArray(JSValue);
                const ArrList = @FieldType(ZArr, "items");
                const arr_rc_off: i32 = @intCast(@offsetOf(ArrayBox, "_count"));
                const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
                const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
                const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
                const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
                const arr_items_len_off: i32 = arr_items_ptr_off + 8;
                const arr_items_cap_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "capacity")));
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
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm32(.rdx, op.a);
                try a.movRegImm32(.rcx, op.b);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitNewArray));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }
                a.bindLabel(done_lbl);
            },
            .set_elem_const => {
                const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
                const ZArr = zvalue.ZArray(JSValue);
                const ArrList = @FieldType(ZArr, "items");
                const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
                const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
                const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
                const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
                const arr_items_len_off: i32 = arr_items_ptr_off + 8;
                const arr_items_cap_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "capacity")));

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
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                try a.movRegReg(.rdi, .r12);
                try a.movRegImm32(.rsi, op.a);
                try a.movRegImm32(.rdx, op.b);
                try a.movRegImm32(.rcx, op.c);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetElemConst));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }

                a.bindLabel(done_lbl);
            },
            .get_elem_const => {
                const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
                const ZArr = zvalue.ZArray(JSValue);
                const ArrList = @FieldType(ZArr, "items");
                const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
                const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
                const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
                const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
                const arr_items_len_off: i32 = arr_items_ptr_off + 8;

                const elem_idx: u32 = @intFromFloat(block.constants[op.c].number);
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
                    try emitReleaseHeapIfRefGt1(&a, op.a, bail_lbl);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rdx);
                }
                try a.jmp(done_lbl);

                a.bindLabel(slow_lbl);
                if (cached_count > 0) {
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                try a.movRegReg(.rdi, .r12);
                try a.movRegImm32(.rsi, op.a);
                try a.movRegImm32(.rdx, op.b);
                try a.movRegImm32(.rcx, elem_idx);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetElemConst));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }

                a.bindLabel(done_lbl);
            },
            .new_object => {
                const obj_rc_off: i32 = @intCast(@offsetOf(ObjectBox, "_count"));
                const zobj_is_sealed_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_sealed");
                const zobj_is_error_data_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_error_data");

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
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm32(.rdx, op.a);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitNewObject));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }
                a.bindLabel(done_lbl);
            },
            .set_prop, .set_prop_transition => {
                const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
                if (promoted.count > 0 and op.opcode == .set_prop) {
                    const slot_idx = prop_ic.?[ic_idx].slot_idx;
                    const p_idx = promoted.findSlot(slot_idx).?;
                    const xmm_prop = promoted.xmms[p_idx];
                    if (op.c < 64 and reg_to_xmm[op.c] != null) {
                        const xmm_src = reg_to_xmm[op.c].?;
                        if (xmm_prop != xmm_src) {
                            try a.movsdXmmXmm(xmm_prop, xmm_src);
                        }
                    } else {
                        try emitLoadNumToXmm(&a, reg_to_xmm, op.c, xmm_prop, bail_lbl);
                    }
                    continue;
                }
                const key = constantName(block, op.b).?;
                const expected_key_ptr = @intFromPtr(key.ptr);
                const packed_info: u64 = (@as(u64, @intCast(ip)) << 32) | (@as(u64, ic_idx) << 16) | (@as(u64, op.c) << 8) | @as(u64, op.a);

                const slow_path = try a.createLabel();
                const done_lbl = try a.createLabel();

                if (op.opcode == .set_prop) {
                    // 1. Check regs[obj_reg] is object: (bits >> 47) == HEADER_OBJECT
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                    try a.movRegReg(.rcx, .rax);
                    try a.shrRegImm8(.rcx, 47);
                    try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
                    try a.jcc(.ne, slow_path);

                    // 2. Load value into %r8 (from cached Xmm or regs[val_reg] < HEAP_BASE)
                    if (op.c < 64 and reg_to_xmm[op.c] != null) {
                        const xmm_val = reg_to_xmm[op.c].?;
                        try a.movqRegXmm(.r8, xmm_val);
                        try a.ucomisd(xmm_val, xmm_val);
                        try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                        try a.cmovpRegReg(.r8, .rcx);
                    } else {
                        try a.movRegMem(.r8, .r12, @intCast(@as(usize, op.c) * 8));
                        try a.cmpRegReg(.r8, .r14); // %r14 = HEAP_BASE
                        try a.jcc(.ae, slow_path);
                    }

                    // 3. Extract box ptr: rax = rax & PTR_MASK
                    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                    try a.andRegReg(.rax, .rcx); // %rax = *ObjectBox

                    // 4. Check !zobj.is_frozen
                    try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
                    try a.testRegReg(.rcx, .rcx);
                    try a.jcc(.ne, slow_path);

                    const maybe_ic: ?PropIC = if (prop_ic) |table| blk: {
                        const entry = table[ic_idx];
                        if (entry.block == block and entry.pc == ip and @intFromPtr(entry.key_ptr) == expected_key_ptr and entry.shape_id != 0 and entry.next_shape == 0) {
                            break :blk entry;
                        }
                        break :blk null;
                    } else null;

                    if (maybe_ic) |ic_val| {
                        // Monomorphic PropIC specialization at OSR compile time
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
                        // 5. ic_ptr = ctx.prop_ic_ptr + ic_idx * @sizeOf(PropIC)
                        try a.movRegMem(.rsi, .r13, ctx_prop_ic_ptr_offset);
                        const ic_byte_offset: i32 = @intCast(@as(usize, ic_idx) * @sizeOf(PropIC));
                        if (ic_byte_offset != 0) {
                            try a.addRegImm32(.rsi, ic_byte_offset);
                        }

                        // 6. Check ic.block == @intFromPtr(block)
                        try a.movRegMem(.rcx, .rsi, ic_block_offset);
                        try a.movRegImm64(.rdx, @intFromPtr(block));
                        try a.cmpRegReg(.rcx, .rdx);
                        try a.jcc(.ne, slow_path);

                        // 7. Check ic.pc == ip
                        try a.movReg32Mem(.rcx, .rsi, ic_pc_offset);
                        try a.cmpReg32Imm32(.rcx, @intCast(ip));
                        try a.jcc(.ne, slow_path);

                        // 8. Check ic.next_shape == 0 (no shape transition)
                        try a.movReg32Mem(.rcx, .rsi, ic_next_shape_offset);
                        try a.testReg32Reg32(.rcx, .rcx);
                        try a.jcc(.ne, slow_path);

                        // 9. Check ic.shape_id != 0 and zobj.shape_id == ic.shape_id
                        try a.movReg32Mem(.rcx, .rsi, ic_shape_id_offset);
                        try a.testReg32Reg32(.rcx, .rcx);
                        try a.jcc(.e, slow_path);
                        try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                        try a.cmpReg32Reg32(.rdx, .rcx);
                        try a.jcc(.ne, slow_path);

                        // 10. Check ic.key_ptr == expected_key_ptr
                        try a.movRegMem(.rcx, .rsi, ic_key_ptr_offset);
                        try a.movRegImm64(.rdx, expected_key_ptr);
                        try a.cmpRegReg(.rcx, .rdx);
                        try a.jcc(.ne, slow_path);

                        // 11. slot_idx < entries.len
                        try a.movReg32Mem(.rcx, .rsi, ic_slot_idx_offset); // %rcx = slot_idx
                        try a.movRegMem(.rdx, .rax, zobj_entries_len_offset); // %rdx = len
                        try a.cmpRegReg(.rcx, .rdx);
                        try a.jcc(.ae, slow_path);

                        // 12. Compute &prop:
                        try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset); // %rdx = bytes
                        try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset); // %rsi = capacity
                        if (comptime value_byte_offset_multiplier == 16) {
                            try a.shlRegImm8(.rsi, 4);
                        } else {
                            try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
                        }
                        try a.addRegReg(.rdx, .rsi); // %rdx = prop_array
                        try a.imulRegRegImm32(.rsi, .rcx, prop_size);
                        try a.addRegReg(.rdx, .rsi); // %rdx = &prop

                        // 13. Check writable (bit 0) and !is_accessor (bit 3): desc & 9 == 1
                        try a.movReg32Mem(.rcx, .rdx, prop_desc_offset);
                        try a.andRegImm8(.rcx, 9);
                        try a.cmpRegImm32(.rcx, 1);
                        try a.jcc(.ne, slow_path);

                        // 14. Check old prop.value < HEAP_BASE
                        try a.movRegMem(.rcx, .rdx, prop_val_offset);
                        try a.cmpRegReg(.rcx, .r14); // %r14 = HEAP_BASE
                        try a.jcc(.ae, slow_path);

                        // Fast write: prop.value = regs[val_reg]
                        try a.movMemReg(.rdx, prop_val_offset, .r8);
                        try a.jmp(done_lbl);
                    }
                } else {
                    // .set_prop_transition inline fast-path for recycled objects with preserved shape
                    // 1. Check regs[obj_reg] is object: (bits >> 47) == HEADER_OBJECT
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                    try a.movRegReg(.rcx, .rax);
                    try a.shrRegImm8(.rcx, 47);
                    try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
                    try a.jcc(.ne, slow_path);

                    // 2. Load value into %r8 (from cached Xmm or regs[val_reg] < HEAP_BASE)
                    if (op.c < 64 and reg_to_xmm[op.c] != null) {
                        const xmm_val = reg_to_xmm[op.c].?;
                        try a.movqRegXmm(.r8, xmm_val);
                        try a.ucomisd(xmm_val, xmm_val);
                        try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                        try a.cmovpRegReg(.r8, .rcx);
                    } else {
                        try a.movRegMem(.r8, .r12, @intCast(@as(usize, op.c) * 8));
                        try a.cmpRegReg(.r8, .r14); // %r14 = HEAP_BASE
                        try a.jcc(.ae, slow_path);
                    }

                    // 3. Extract box ptr: rax = rax & PTR_MASK
                    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                    try a.andRegReg(.rax, .rcx); // %rax = *ObjectBox

                    // 4. Check !zobj.is_frozen and zobj.is_extensible
                    try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
                    try a.testRegReg(.rcx, .rcx);
                    try a.jcc(.ne, slow_path);
                    try a.movzxReg64Mem8(.rcx, .rax, zobj_is_extensible_offset);
                    try a.testRegReg(.rcx, .rcx);
                    try a.jcc(.e, slow_path);

                    const maybe_trans_ic: ?PropIC = if (prop_ic) |table| blk: {
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
                        // 5. ic_ptr = ctx.prop_ic_ptr + ic_idx * @sizeOf(PropIC)
                        try a.movRegMem(.rsi, .r13, ctx_prop_ic_ptr_offset);
                        const ic_byte_offset: i32 = @intCast(@as(usize, ic_idx) * @sizeOf(PropIC));
                        if (ic_byte_offset != 0) {
                            try a.addRegImm32(.rsi, ic_byte_offset);
                        }

                        // 6. Check ic.block == @intFromPtr(block) and ic.pc == ip
                        try a.movRegMem(.rcx, .rsi, ic_block_offset);
                        try a.movRegImm64(.rdx, @intFromPtr(block));
                        try a.cmpRegReg(.rcx, .rdx);
                        try a.jcc(.ne, slow_path);

                        try a.movReg32Mem(.rcx, .rsi, ic_pc_offset);
                        try a.cmpReg32Imm32(.rcx, @intCast(ip));
                        try a.jcc(.ne, slow_path);

                        // 7. Check ic.next_shape != 0, zobj.shape_id == ic.shape_id, zobj.cached_shape_id == ic.cached_shape_id
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

                        // 8. Check zobj.active_len == ic.slot_idx and ic.slot_idx < zobj.cached_len
                        try a.movReg32Mem(.rcx, .rsi, ic_slot_idx_offset); // %rcx = slot_idx
                        try a.movzxReg64Mem16(.rdx, .rax, zobj_active_len_offset);
                        try a.cmpRegReg(.rdx, .rcx);
                        try a.jcc(.ne, slow_path);

                        try a.movzxReg64Mem16(.rdx, .rax, zobj_cached_len_offset);
                        try a.cmpRegReg(.rcx, .rdx);
                        try a.jcc(.ae, slow_path);

                        // 9. Check entries.items(.key)[slot].ptr == ic.interned_key_ptr
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

                        // 10. Compute &entries.items(.value)[slot], guard old value < HEAP_BASE, and write %r8
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

                        // 11. Advance zobj.shape_id = ic.next_shape and update active_len
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
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm64(.rdx, packed_info);
                try a.movRegImm64(.rcx, expected_key_ptr);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetProp));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }
                a.bindLabel(done_lbl);
            },
            .get_prop => {
                const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
                if (promoted.count > 0) {
                    const slot_idx = prop_ic.?[ic_idx].slot_idx;
                    const p_idx = promoted.findSlot(slot_idx).?;
                    const xmm_prop = promoted.xmms[p_idx];
                    if (op.a < 64 and reg_to_xmm[op.a] != null) {
                        const xmm_dst = reg_to_xmm[op.a].?;
                        if (xmm_dst != xmm_prop) {
                            try a.movsdXmmXmm(xmm_dst, xmm_prop);
                        }
                    } else {
                        try emitStoreXmmToNum(&a, reg_to_xmm, cached_regs, cached_count, op.a, xmm_prop, bail_lbl);
                    }
                    continue;
                }
                const key = constantName(block, op.c).?;
                const expected_key_ptr = @intFromPtr(key.ptr);
                const packed_info: u64 = (@as(u64, @intCast(ip)) << 32) | (@as(u64, ic_idx) << 16) | (@as(u64, op.b) << 8) | @as(u64, op.a);

                const slow_path = try a.createLabel();
                const done_lbl = try a.createLabel();

                // 1. Check regs[obj_reg] is object: (bits >> 47) == HEADER_OBJECT
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
                try a.jcc(.ne, slow_path);

                // 2. Check regs[dst_reg] < HEAP_BASE (avoid RC management on overwritten slot in fast path)
                if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
                    try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
                    try a.cmpRegReg(.rcx, .r14); // %r14 = HEAP_BASE
                    try a.jcc(.ae, slow_path);
                }

                // 3. Extract box ptr: rax = rax & PTR_MASK
                try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                try a.andRegReg(.rax, .rcx); // %rax = *ObjectBox

                const maybe_get_ic: ?PropIC = if (prop_ic) |table| blk: {
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
                    // 4. ic_ptr = ctx.prop_ic_ptr + ic_idx * @sizeOf(PropIC)
                    try a.movRegMem(.rsi, .r13, ctx_prop_ic_ptr_offset);
                    const ic_byte_offset: i32 = @intCast(@as(usize, ic_idx) * @sizeOf(PropIC));
                    if (ic_byte_offset != 0) {
                        try a.addRegImm32(.rsi, ic_byte_offset);
                    }

                    // 5. Check ic.block == @intFromPtr(block)
                    try a.movRegMem(.rcx, .rsi, ic_block_offset);
                    try a.movRegImm64(.rdx, @intFromPtr(block));
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ne, slow_path);

                    // 6. Check ic.pc == ip
                    try a.movReg32Mem(.rcx, .rsi, ic_pc_offset);
                    try a.cmpReg32Imm32(.rcx, @intCast(ip));
                    try a.jcc(.ne, slow_path);

                    // 7. Check ic.shape_id != 0 and zobj.shape_id == ic.shape_id
                    try a.movReg32Mem(.rcx, .rsi, ic_shape_id_offset);
                    try a.testReg32Reg32(.rcx, .rcx);
                    try a.jcc(.e, slow_path);
                    try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                    try a.cmpReg32Reg32(.rdx, .rcx);
                    try a.jcc(.ne, slow_path);

                    // 8. Check ic.key_ptr == expected_key_ptr
                    try a.movRegMem(.rcx, .rsi, ic_key_ptr_offset);
                    try a.movRegImm64(.rdx, expected_key_ptr);
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ne, slow_path);

                    // 9. Check slot_idx < entries.len
                    try a.movReg32Mem(.rcx, .rsi, ic_slot_idx_offset); // %rcx = slot_idx
                    try a.movRegMem(.rdx, .rax, zobj_entries_len_offset); // %rdx = len
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ae, slow_path);

                    // 10. Compute &prop:
                    try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset); // %rdx = bytes
                    try a.movRegMem(.rsi, .rax, zobj_entries_cap_offset); // %rsi = capacity
                    if (comptime value_byte_offset_multiplier == 16) {
                        try a.shlRegImm8(.rsi, 4);
                    } else {
                        try a.imulRegRegImm32(.rsi, .rsi, @intCast(value_byte_offset_multiplier));
                    }
                    try a.addRegReg(.rdx, .rsi); // %rdx = prop_array
                    try a.imulRegRegImm32(.rsi, .rcx, prop_size);
                    try a.addRegReg(.rdx, .rsi); // %rdx = &prop

                    // 11. Check !is_accessor (bit 3 of descriptor at offset 40 is 0)
                    try a.movReg32Mem(.rcx, .rdx, prop_desc_offset);
                    try a.andRegImm8(.rcx, 8);
                    try a.testReg32Reg32(.rcx, .rcx);
                    try a.jcc(.ne, slow_path);

                    // 12. Load prop.value
                    try a.movRegMem(.rax, .rdx, prop_val_offset);
                }
                if (op.a < 64 and reg_to_xmm[op.a] != null) {
                    const xmm_dst = reg_to_xmm[op.a].?;
                    try a.cmpRegReg(.rax, .r15); // %r15 = BASE_TAG
                    try a.jcc(.ae, slow_path);
                    try a.movqXmmReg(xmm_dst, .rax);
                } else {
                    try a.cmpRegReg(.rax, .r14); // %r14 = HEAP_BASE
                    try a.jcc(.ae, slow_path);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                }
                try a.jmp(done_lbl);

                a.bindLabel(slow_path);
                if (cached_count > 0) {
                    try emitFlushCached(&a, cached_regs, cached_count);
                }
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm64(.rdx, packed_info);
                try a.movRegImm64(.rcx, expected_key_ptr);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetProp));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (op.a < 64 and reg_to_xmm[op.a] != null) {
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bail_lbl);
                }
                if (cached_count > 0) {
                    try emitReloadCached(&a, cached_regs, cached_count);
                }
                a.bindLabel(done_lbl);
            },
            .call, .call_global => {
                const cs = &block.call_target_cache[op.c];
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

                // Guard 2:
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

                // Guard 3: target_block.jit_fn != null
                try a.movRegImm64(.rcx, target_addr);
                try a.movRegMem(.r11, .rcx, jit_fn_off);
                try a.testRegReg(.r11, .r11);
                try a.jcc(.e, bail_lbl);

                // Guard 4: All arguments regs[op.b + 1 + i] < HEAP_BASE
                const arg_start = @as(usize, op.b) + 1;
                for (0..arg_count) |i_arg| {
                    try a.movRegMem(.rax, .r12, @intCast((arg_start + i_arg) * 8));
                    try a.cmpRegReg(.rax, .r14);
                    try a.jcc(.ae, bail_lbl);
                }

                // Guard 5: Stack check: callee_regs + target_block.register_count <= regs_limit
                try a.lea(.rax, .r12, total_bytes);
                try a.movRegMem(.rcx, .r13, regs_limit_off);
                try a.cmpRegReg(.rax, .rcx);
                try a.jcc(.a, bail_lbl);

                // Copy arguments to callee_regs[0..arg_count]
                for (0..arg_count) |i_arg| {
                    try a.movRegMem(.rax, .r12, @intCast((arg_start + i_arg) * 8));
                    try a.movMemReg(.r12, callee_regs_off + @as(i32, @intCast(i_arg * 8)), .rax);
                }

                // Set up arguments for jit_fn:
                // %rdi = callee_regs
                try a.lea(.rdi, .r12, callee_regs_off);
                // %rdx = regs_limit
                try a.movRegMem(.rdx, .r13, regs_limit_off);
                // %rcx = cache.closure_env
                try a.movRegImm64(.rcx, cache_addr);
                try a.movRegMem(.rcx, .rcx, closure_env_off);

                // Allocate 16 bytes on stack for out_val
                try a.subRegImm32(.rsp, 16);
                // %rsi = &out_val
                try a.movRegReg(.rsi, .rsp);

                // Call jit_fn (%r11)
                try a.callReg(.r11);

                // Check return code
                try a.testRegReg(.rax, .rax);
                const call_ok_lbl = try a.createLabel();
                try a.jcc(.e, call_ok_lbl);

                // Bailout path: restore %rsp and jump to bail_lbl
                try a.addRegImm32(.rsp, 16);
                try a.jmp(bail_lbl);

                // Success path:
                a.bindLabel(call_ok_lbl);
                try a.movRegMem(.rbx, .rsp, 0); // %rbx = out_val (callee-saved)
                try a.addRegImm32(.rsp, 16);

                const write_out_lbl = try a.createLabel();
                const heap_old_lbl = try a.createLabel();
                const deinit_call_lbl = try a.createLabel();

                // Check old regs[op.a] < HEAP_BASE (%r14)
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                try a.cmpRegReg(.rax, .r14);
                try a.jcc(.ae, heap_old_lbl);
                try a.jmp(write_out_lbl);

                // old regs[op.a] >= HEAP_BASE
                a.bindLabel(heap_old_lbl);
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
                try a.jcc(.ne, deinit_call_lbl);

                // It is a function! Extract ptr = old_val & PTR_MASK
                try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                try a.andRegReg(.rcx, .rax);

                // Check ptr._count > 1
                const rc_off: i32 = @intCast(@offsetOf(zvalue.Rc(zvalue.Callable), "_count"));
                try a.movRegMem(.rdx, .rcx, rc_off);
                try a.cmpRegImm32(.rdx, 1);
                try a.jcc(.be, deinit_call_lbl);

                // ptr._count > 1: decrement ptr._count -= 1
                try a.subRegImm32(.rdx, 1);
                try a.movMemReg(.rcx, rc_off, .rdx);
                try a.jmp(write_out_lbl);

                // Slow path: jitDeinitSlot(&regs[op.a])
                a.bindLabel(deinit_call_lbl);
                try a.lea(.rdi, .r12, @intCast(@as(usize, op.a) * 8));
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitDeinitSlot));
                try a.callReg(.rax);

                // Write out_val into regs[op.a]
                a.bindLabel(write_out_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rbx);
            },
            else => {
                if (!(try emitSharedOp(&a, block, op, true, bail_lbl))) unreachable;
            },
        }
    }

    for (exit_stubs.items) |stub| {
        a.bindLabel(stub.label);
        try a.movRegImm32(.rax, stub.target_ip);
        if (has_flush) {
            try a.jmp(flush_and_exit);
        } else {
            try a.jmp(osr_epilogue);
        }
    }

    for (0..loop_len) |idx| {
        a.bindLabel(bailout_labels[idx]);
        try a.movRegImm32(.rax, bailout_target_ips[idx]);
        if (has_flush) {
            try a.jmp(flush_and_exit);
        } else {
            try a.jmp(osr_epilogue);
        }
    }

    if (has_flush) {
        a.bindLabel(flush_and_exit);
        if (cached_count > 0) {
            try emitFlushCached(&a, cached_regs, cached_count);
        }
        if (promoted.count > 0) {
            try emitFlushPromoted(&a, promoted);
        }
        try a.jmp(osr_epilogue);

        a.bindLabel(preheader_bailout);
        try a.movRegImm32(.rax, @intCast(start_ip));
        try a.jmp(osr_epilogue);
    }

    a.bindLabel(osr_epilogue);
    try a.popReg(.r15);
    try a.popReg(.r14);
    try a.popReg(.r13);
    try a.popReg(.r12);
    try a.popReg(.rbx);
    try a.ret();

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
