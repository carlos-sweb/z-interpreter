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

pub const JitFn = codeblock.JitFn;
pub const OsrFn = codeblock.OsrFn;
pub const JitGlobalSlot = codeblock.JitGlobalSlot;
pub const HOT_THRESHOLD: u32 = 32;
pub const OSR_THRESHOLD: u32 = 64;

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
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne => {
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

pub fn compile(allocator: Allocator, block: *codeblock.CodeBlock) bool {
    if (block.jit_fn != null) return true;
    if (block.jit_failed) return false;
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
    try a.movRegReg(.rdi, .r12);
    try a.movRegImm32(.rsi, reg_idx);
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
        .eq, .eq_local_const => {
            const false_lbl = try a.createLabel();
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, false_lbl);
            try a.jcc(.e, true_lbl);
            a.bindLabel(false_lbl);
        },
        .ne => {
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
        .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne => {
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

    for (block.ops, 0..) |op, ip| {
        a.bindLabel(op_labels[ip]);
        switch (op.opcode) {
            .nop => {},
            .load_undefined => {
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
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
            },
            .move, .load_local, .store_local => {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movRegImm64(.rcx, JSValue.HEAP_BASE);
                try a.cmpRegReg(.rax, .rcx);
                try a.jcc(.ae, bailout_label);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .jump_if_false, .jump_if_true => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                try emitCondJump(&a, op.opcode == .jump_if_true, op.a, op_labels[target_pc], bailout_label);
            },
            .add, .add_num, .sub_num, .mul_num => {
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bailout_label);
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.rcx, .r15);
                try a.jcc(.ae, bailout_label);
                try a.movqXmmReg(.xmm0, .rax);
                try a.movqXmmReg(.xmm1, .rcx);
                switch (op.opcode) {
                    .add, .add_num => try a.addsd(.xmm0, .xmm1),
                    .sub_num => try a.subsd(.xmm0, .xmm1),
                    .mul_num => try a.mulsd(.xmm0, .xmm1),
                    else => unreachable,
                }
                try a.movqRegXmm(.rax, .xmm0);
                try a.ucomisd(.xmm0, .xmm0);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .add_local_const, .sub_local_const => {
                const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bailout_label);
                try a.movqXmmReg(.xmm0, .rax);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (op.opcode == .add_local_const) {
                    try a.addsd(.xmm0, .xmm1);
                } else {
                    try a.subsd(.xmm0, .xmm1);
                }
                try a.movqRegXmm(.rax, .xmm0);
                try a.ucomisd(.xmm0, .xmm0);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
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
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bailout_label);
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
            },
            .store_global => {
                const slots = slots_opt.?;
                const slot_addr = @intFromPtr(&slots[next_slot_idx]);
                next_slot_idx += 1;
                const name = constantName(block, op.a).?;
                // Validate regs[op.b] is number (< BASE_TAG) before lookup
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bailout_label);

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
            },
            .return_value => {
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
                try a.movRegImm64(.rdx, JSValue.HEAP_BASE);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bailout_label);
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
            else => return false,
        }
    }
    return true;
}

pub fn compileOsr(allocator: Allocator, block: *codeblock.CodeBlock, start_ip: usize, end_ip: usize) bool {
    if (block.osr_fn != null) return true;
    if (block.osr_failed) return false;
    if (!canCompileOsr(block, start_ip, end_ip)) {
        block.osr_failed = true;
        return false;
    }

    const exec = compileOsrImpl(allocator, block, start_ip, end_ip) catch {
        block.osr_failed = true;
        return false;
    };
    block.osr_header_ip = @intCast(start_ip);
    block.osr_end_ip = @intCast(end_ip);
    block.osr_code = exec;
    block.osr_fn = @ptrCast(exec.ptr);
    return true;
}

fn compileOsrImpl(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
) ![]align(std.heap.page_size_min) u8 {
    var a = Assembler.init(allocator);
    defer a.deinit();

    const loop_len = end_ip - start_ip + 1;
    var op_labels = try allocator.alloc(Label, loop_len);
    defer allocator.free(op_labels);
    var bailout_labels = try allocator.alloc(Label, loop_len);
    defer allocator.free(bailout_labels);
    for (0..loop_len) |i| {
        op_labels[i] = try a.createLabel();
        bailout_labels[i] = try a.createLabel();
    }
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

    for (0..loop_len) |idx| {
        const ip = start_ip + idx;
        const op = block.ops[ip];
        const bail_lbl = bailout_labels[idx];
        a.bindLabel(op_labels[idx]);

        switch (op.opcode) {
            .nop => {},
            .load_undefined => {
                try emitGuardNonHeapInOsr(&a, op.a, bail_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
            },
            .load_const => {
                try emitGuardNonHeapInOsr(&a, op.a, bail_lbl);
                const c = block.constants[op.b];
                const bits = switch (c) {
                    .number => |n| JSValue.fromNumber(n).bits,
                    .boolean => |b| JSValue.fromBool(b).bits,
                    else => unreachable,
                };
                try a.movRegImm64(.rax, bits);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .move, .load_local, .store_local => {
                if (op.a != op.b) {
                    const slow_move_lbl = try a.createLabel();
                    const done_move_lbl = try a.createLabel();
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                    try a.cmpRegReg(.rax, .r14);
                    try a.jcc(.ae, slow_move_lbl);
                    try a.movRegMem(.rdx, .r12, @intCast(@as(usize, op.a) * 8));
                    try a.cmpRegReg(.rdx, .r14);
                    try a.jcc(.ae, slow_move_lbl);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                    try a.jmp(done_move_lbl);
                    a.bindLabel(slow_move_lbl);
                    try a.movRegReg(.rdi, .r13);
                    try a.movRegReg(.rsi, .r12);
                    try a.movRegImm32(.rdx, op.a);
                    try a.movRegImm32(.rcx, op.b);
                    try a.movRegImm64(.rax, @intFromPtr(&vm.jitMoveSlot));
                    try a.callReg(.rax);
                    a.bindLabel(done_move_lbl);
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
                try a.cmpRegImm32(.rcx, 0x1FFF4);
                try a.jcc(.ne, bail_lbl);
                try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                try a.andRegReg(.rax, .rcx);

                // guard box.holey == null
                try a.movRegMem(.rcx, .rax, arr_holey_off);
                try a.testRegReg(.rcx, .rcx);
                try a.jcc(.ne, bail_lbl);

                // key = regs[op.c]; guard key < BASE_TAG and exact int32 >= 0
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.rcx, .r15);
                try a.jcc(.ae, bail_lbl);
                try a.movqXmmReg(.xmm0, .rcx);
                try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                try a.ucomisd(.xmm0, .xmm1);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);
                // sign check on 32-bit int: (rcx >> 31) == 0
                try a.movRegReg(.rdx, .rcx);
                try a.shrRegImm8(.rdx, 31);
                try a.testRegReg(.rdx, .rdx);
                try a.jcc(.ne, bail_lbl);

                // guard idx < box.items.len
                try a.movRegMem(.rdx, .rax, arr_items_len_off);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.ae, bail_lbl);

                // elem = box.items.ptr[idx]; guard elem < BASE_TAG and clean destination if needed
                try a.movRegMem(.rax, .rax, arr_items_ptr_off);
                try a.movRegMemIndexed8(.rax, .rax, .rcx, 0);
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bail_lbl);
                try emitGuardNonHeapInOsr(&a, op.a, bail_lbl);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
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
                try a.movRegMem(.r10, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.r10, .r15);
                try a.jcc(.ae, bail_lbl);

                // arr = regs[op.a]; guard (arr >> 47) == 0x1FFF4 (HEADER_ARRAY)
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, 0x1FFF4);
                try a.jcc(.ne, bail_lbl);
                try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                try a.andRegReg(.rax, .rcx);

                // guard box.holey == null
                try a.movRegMem(.rcx, .rax, arr_holey_off);
                try a.testRegReg(.rcx, .rcx);
                try a.jcc(.ne, bail_lbl);

                // key = regs[op.b]; guard key < BASE_TAG and exact int32 >= 0
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rcx, .r15);
                try a.jcc(.ae, bail_lbl);
                try a.movqXmmReg(.xmm0, .rcx);
                try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                try a.ucomisd(.xmm0, .xmm1);
                try a.jcc(.p, bail_lbl);
                try a.jcc(.ne, bail_lbl);
                try a.movRegReg(.rdx, .rcx);
                try a.shrRegImm8(.rdx, 31);
                try a.testRegReg(.rdx, .rdx);
                try a.jcc(.ne, bail_lbl);

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
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bail_lbl);
                try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.rcx, .r15);
                try a.jcc(.ae, bail_lbl);
                if (op.a != op.b and op.a != op.c) {
                    try emitGuardNonHeapInOsr(&a, op.a, bail_lbl);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movqXmmReg(.xmm1, .rcx);
                switch (op.opcode) {
                    .add, .add_num => try a.addsd(.xmm0, .xmm1),
                    .sub_num => try a.subsd(.xmm0, .xmm1),
                    .mul_num => try a.mulsd(.xmm0, .xmm1),
                    else => unreachable,
                }
                try a.movqRegXmm(.rax, .xmm0);
                try a.ucomisd(.xmm0, .xmm0);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .add_local_const, .sub_local_const => {
                const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bail_lbl);
                if (op.a != op.b) {
                    try emitGuardNonHeapInOsr(&a, op.a, bail_lbl);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (op.opcode == .add_local_const) {
                    try a.addsd(.xmm0, .xmm1);
                } else {
                    try a.subsd(.xmm0, .xmm1);
                }
                try a.movqRegXmm(.rax, .xmm0);
                try a.ucomisd(.xmm0, .xmm0);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
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
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bail_lbl);
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
                if (target_pc >= start_ip and target_pc <= end_ip) {
                    try a.jmp(op_labels[target_pc - start_ip]);
                } else {
                    try a.movRegImm32(.rax, @intCast(target_pc));
                    try a.jmp(osr_epilogue);
                }
            },
            .new_array => {
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm32(.rdx, op.a);
                try a.movRegImm32(.rcx, op.b);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitNewArray));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
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
                try a.movRegMem(.rdx, .r12, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.rdx, .r15);
                try a.jcc(.ae, slow_lbl);

                // arr = regs[op.a]; guard (arr >> 47) == 0x1FFF4 (HEADER_ARRAY)
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, 0x1FFF4);
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
                try a.movRegReg(.rdi, .r12);
                try a.movRegImm32(.rsi, op.a);
                try a.movRegImm32(.rdx, op.b);
                try a.movRegImm32(.rcx, op.c);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetElemConst));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);

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

                // arr = regs[op.b]; guard (arr >> 47) == 0x1FFF4 (HEADER_ARRAY)
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, 0x1FFF4);
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

                // elem = box.items.ptr[elem_idx]; guard elem < BASE_TAG (%r15) and regs[op.a] < HEAP_BASE (%r14)
                try a.movRegMem(.rcx, .rax, arr_items_ptr_off);
                try a.movRegMem(.rax, .rcx, @intCast(@as(usize, elem_idx) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, slow_lbl);
                try a.movRegMem(.rdx, .r12, @intCast(@as(usize, op.a) * 8));
                try a.cmpRegReg(.rdx, .r14);
                try a.jcc(.ae, slow_lbl);

                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                try a.jmp(done_lbl);

                a.bindLabel(slow_lbl);
                try a.movRegReg(.rdi, .r12);
                try a.movRegImm32(.rsi, op.a);
                try a.movRegImm32(.rdx, op.b);
                try a.movRegImm32(.rcx, elem_idx);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetElemConst));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);

                a.bindLabel(done_lbl);
            },
            .new_object => {
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm32(.rdx, op.a);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitNewObject));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
            },
            .set_prop, .set_prop_transition => {
                const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
                const key = constantName(block, op.b).?;
                const packed_info: u64 = (@as(u64, @intCast(ip)) << 32) | (@as(u64, ic_idx) << 16) | (@as(u64, op.c) << 8) | @as(u64, op.a);
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm64(.rdx, packed_info);
                try a.movRegImm64(.rcx, @intFromPtr(key.ptr));
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetProp));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
            },
            .get_prop => {
                const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
                const key = constantName(block, op.c).?;
                const packed_info: u64 = (@as(u64, @intCast(ip)) << 32) | (@as(u64, ic_idx) << 16) | (@as(u64, op.b) << 8) | @as(u64, op.a);
                try a.movRegReg(.rdi, .r13);
                try a.movRegReg(.rsi, .r12);
                try a.movRegImm64(.rdx, packed_info);
                try a.movRegImm64(.rcx, @intFromPtr(key.ptr));
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetProp));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
            },
            else => {
                if (!(try emitSharedOp(&a, block, op, true, bail_lbl))) unreachable;
            },
        }
    }

    for (exit_stubs.items) |stub| {
        a.bindLabel(stub.label);
        try a.movRegImm32(.rax, stub.target_ip);
        try a.jmp(osr_epilogue);
    }

    for (0..loop_len) |idx| {
        a.bindLabel(bailout_labels[idx]);
        try a.movRegImm32(.rax, @intCast(start_ip + idx));
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
