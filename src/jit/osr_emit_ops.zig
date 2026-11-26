//! OsrCompiler methods: comparisons, property ICs, calls, loop and exits.

const std = @import("jit_common.zig").std;
const zvalue = @import("jit_common.zig").zvalue;
const JSValue = @import("jit_common.zig").JSValue;
const codeblock = @import("jit_common.zig").codeblock;
const vm = @import("jit_common.zig").vm;
const x64_asm = @import("jit_common.zig").x64_asm;
const Label = @import("jit_common.zig").Label;
const Xmm = @import("jit_common.zig").Xmm;
const HEADER_FUNCTION = @import("jit_common.zig").HEADER_FUNCTION;
const HEADER_ARRAY = @import("jit_common.zig").HEADER_ARRAY;
const HEADER_OBJECT = @import("jit_common.zig").HEADER_OBJECT;
const HEADER_STRING = @import("jit_common.zig").HEADER_STRING;
const str_data_ptr_off = @import("jit_common.zig").str_data_ptr_off;
const str_data_len_off = @import("jit_common.zig").str_data_len_off;
const value_byte_offset_multiplier = @import("jit_common.zig").value_byte_offset_multiplier;
const zobj_shape_id_offset = @import("jit_common.zig").zobj_shape_id_offset;
const zobj_cached_shape_id_offset = @import("jit_common.zig").zobj_cached_shape_id_offset;
const zobj_cached_len_offset = @import("jit_common.zig").zobj_cached_len_offset;
const zobj_active_len_offset = @import("jit_common.zig").zobj_active_len_offset;
const zobj_is_frozen_offset = @import("jit_common.zig").zobj_is_frozen_offset;
const zobj_is_extensible_offset = @import("jit_common.zig").zobj_is_extensible_offset;
const zobj_prototype_offset = @import("jit_common.zig").zobj_prototype_offset;
const raw_zobj_shape_id_offset = @import("jit_common.zig").raw_zobj_shape_id_offset;
const raw_zobj_cached_len_offset = @import("jit_common.zig").raw_zobj_cached_len_offset;
const raw_zobj_entries_bytes_offset = @import("jit_common.zig").raw_zobj_entries_bytes_offset;
const zobj_entries_bytes_offset = @import("jit_common.zig").zobj_entries_bytes_offset;
const zobj_entries_len_offset = @import("jit_common.zig").zobj_entries_len_offset;
const zobj_entries_cap_offset = @import("jit_common.zig").zobj_entries_cap_offset;
const prop_val_offset = @import("jit_common.zig").prop_val_offset;
const prop_desc_offset = @import("jit_common.zig").prop_desc_offset;
const prop_size = @import("jit_common.zig").prop_size;
const ctx_frame_ptr_offset = @import("jit_common.zig").ctx_frame_ptr_offset;
const ctx_global_obj_offset = @import("jit_common.zig").ctx_global_obj_offset;
const frame_closure_env_offset = @import("jit_common.zig").frame_closure_env_offset;
const environment_mod = @import("jit_common.zig").environment_mod;
const jitResolveGlobalSlot = @import("jit_common.zig").jitResolveGlobalSlot;
const osr_ic_shape_off = @import("jit_common.zig").osr_ic_shape_off;
const osr_ic_slot_off = @import("jit_common.zig").osr_ic_slot_off;
const osr_ic_slot_byte_off = @import("jit_common.zig").osr_ic_slot_byte_off;
const osr_ic_next_shape_off = @import("jit_common.zig").osr_ic_next_shape_off;
const osr_ic_cached_shape_off = @import("jit_common.zig").osr_ic_cached_shape_off;
const obj_rc_off = @import("jit_common.zig").obj_rc_off;
const zobj_is_sealed_offset = @import("jit_common.zig").zobj_is_sealed_offset;
const zobj_is_error_data_offset = @import("jit_common.zig").zobj_is_error_data_offset;
const HoleyState = @import("jit_common.zig").HoleyState;
const arr_holey_off = @import("jit_common.zig").arr_holey_off;
const arr_items_ptr_off = @import("jit_common.zig").arr_items_ptr_off;
const arr_items_len_off = @import("jit_common.zig").arr_items_len_off;
const h_log_len_off = @import("jit_common.zig").h_log_len_off;
const constantName = @import("jit_common.zig").constantName;
const jitGetPropInlinedOsr = @import("jit_common.zig").jitGetPropInlinedOsr;
const emitCmpToBool = @import("jit_common.zig").emitCmpToBool;
const emitCondJump = @import("jit_common.zig").emitCondJump;
const emitSharedOp = @import("jit_common.zig").emitSharedOp;
const isMathSqrtCall = @import("osr_analysis.zig").isMathSqrtCall;
const isMathImulCall = @import("osr_analysis.zig").isMathImulCall;
const isMathIntrinsicCall = @import("osr_analysis.zig").isMathIntrinsicCall;
const classifyMathIntrinsicCall = @import("osr_analysis.zig").classifyMathIntrinsicCall;
const MAX_INLINED_CALLEE_OPS = @import("osr_analysis.zig").MAX_INLINED_CALLEE_OPS;
const MAX_INLINED_CALLEE_REGS = @import("osr_analysis.zig").MAX_INLINED_CALLEE_REGS;
const asExactInt32 = @import("osr_emit.zig").asExactInt32;
const asExactPosUint53 = @import("osr_emit.zig").asExactPosUint53;
const emitFlushPromoted = @import("osr_emit.zig").emitFlushPromoted;
const emitReloadPromoted = @import("osr_emit.zig").emitReloadPromoted;
const emitFlushCached = @import("osr_emit.zig").emitFlushCached;
const emitReloadCached = @import("osr_emit.zig").emitReloadCached;
const emitReleaseHeapIfRefGt1 = @import("osr_emit.zig").emitReleaseHeapIfRefGt1;
const emitStoreSlotValOrSlow = @import("osr_emit.zig").emitStoreSlotValOrSlow;
const isNextOpNumericConsumer = @import("osr_emit.zig").isNextOpNumericConsumer;
const emitStoreXmmToNum = @import("osr_emit.zig").emitStoreXmmToNum;
const emitFusedCmpBranch = @import("osr_emit.zig").emitFusedCmpBranch;
const OsrCompiler = @import("osr_emit.zig").OsrCompiler;

pub noinline fn emitComparisonOrBranch(
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
                try self.loadNumToXmm(op.a, .xmm0, bail_lbl);
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
            try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
            try self.loadNumToXmm(op.c, .xmm1, bail_lbl);
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
            try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
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

pub noinline fn emitSetObjectProp(
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
            try self.loadNumToXmm(op.c, xmm_prop, bail_lbl);
        }
        if (self.live_xmm3_reg != null) self.next_live_xmm3 = self.live_xmm3_reg;
        return;
    }

    const idx = ip - self.start_ip;
    const eff_obj = self.prepass.compound_arr_override[idx] orelse (if (op.a < 64) (self.cur_copy_src[op.a] orelse op.a) else op.a);
    const key = constantName(block, op.b).?;
    if (std.mem.eql(u8, key, "__proto__")) {
        self.cached_obj_ptrs = .{ null, null };
        try a.jmp(bail_lbl);
        return;
    }

    const site_ic_addr = self.prop_ic_addrs[idx];
    const compile_ic = self.prop_ics_init[idx];
    const is_trans = (op.opcode == .set_prop_transition);
    const trans_flag: u64 = if (is_trans) (@as(u64, 1) << 24) else 0;
    const packed_info: u64 = trans_flag | (@as(u64, op.b) << 16) | (@as(u64, op.c) << 8) | @as(u64, eff_obj);

    const slow_path = try a.createLabel();
    const done_lbl = try a.createLabel();

    if (!is_trans) {
        if (compile_ic.shape_id == 0 or (compile_ic.shape_id & 0x8000_0000) != 0 or compile_ic.next_shape != 0) {
            self.cached_obj_ptrs = .{ null, null };
        } else {
            for (&self.cached_obj_ptrs) |*cop| {
                if (cop.*) |c| {
                    if (c.obj_reg == eff_obj and c.shape_id != compile_ic.shape_id) {
                        self.cached_obj_ptrs = .{ null, null };
                        break;
                    }
                }
            }
        }
    } else {
        self.cached_obj_ptrs = .{ null, null };
    }

    if (op.c < 64 and reg_to_xmm[op.c] != null) {
        const xmm_val = reg_to_xmm[op.c].?;
        try a.movqRegXmm(.r8, xmm_val);
        try a.ucomisd(xmm_val, xmm_val);
        try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
        try a.cmovpRegReg(.r8, .rcx);
    } else if (self.live_xmm3_reg != null and self.live_xmm3_reg.? == op.c) {
        try a.movRegMem(.r8, .r12, @intCast(@as(usize, op.c) * 8));
    } else {
        try a.movRegMem(.r8, .r12, @intCast(@as(usize, op.c) * 8));
        if (is_trans) {
            try a.cmpRegReg(.r8, .r14);
            try a.jcc(.ae, slow_path);
        }
    }

    if (!is_trans) {
        if (self.findCachedObjPtr(eff_obj, compile_ic.shape_id, compile_ic.slot_idx, true)) |ptr_reg| {
            try a.testRegReg(ptr_reg, ptr_reg);
            try a.jcc(.e, slow_path);

            const slot_off: i32 = @intCast(compile_ic.slot_byte_off);
            try a.movReg32Mem(.rcx, ptr_reg, slot_off + prop_desc_offset);
            try a.andRegImm8(.rcx, 9);
            try a.cmpRegImm32(.rcx, 1);
            try a.jcc(.ne, slow_path);

            try emitStoreSlotValOrSlow(a, ptr_reg, slot_off + prop_val_offset, .r8, slow_path);
            try a.jmp(done_lbl);
        } else if (self.trySetupCachedObjPtr(idx, eff_obj, compile_ic.shape_id, compile_ic.slot_idx, true)) |setup| {
            try a.xorReg32Reg32(setup.reg, setup.reg);

            try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_obj) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, slow_path);

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
            try a.cmpReg32Imm32(.rdx, @bitCast(compile_ic.shape_id));
            try a.jcc(.ne, slow_path);

            try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
            try a.cmpRegImm32(.rdx, @intCast(setup.max_slot));
            try a.jcc(.be, slow_path);

            try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
            try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rcx, 4);
            } else {
                try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rdx, .rcx);

            const slot_off: i32 = @intCast(compile_ic.slot_byte_off);
            try a.movReg32Mem(.rcx, .rdx, slot_off + prop_desc_offset);
            try a.andRegImm8(.rcx, 9);
            try a.cmpRegImm32(.rcx, 1);
            try a.jcc(.ne, slow_path);

            try emitStoreSlotValOrSlow(a, .rdx, slot_off + prop_val_offset, .r8, slow_path);
            try a.movRegReg(setup.reg, .rdx);
            try a.jmp(done_lbl);
        } else {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_obj) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, slow_path);

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);

            try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
            try a.jcc(.e, slow_path);

            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movRegImm64(.rsi, site_ic_addr);
            try a.movReg32Mem(.rcx, .rsi, osr_ic_next_shape_off);
            try a.testReg32Reg32(.rcx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movReg32Mem(.rcx, .rsi, osr_ic_shape_off);
            try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
            try a.cmpReg32Reg32(.rdx, .rcx);
            try a.jcc(.ne, slow_path);

            try a.movReg32Mem(.rcx, .rsi, osr_ic_slot_off);
            try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
            try a.cmpRegReg(.rcx, .rdx);
            try a.jcc(.ae, slow_path);

            try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
            try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rcx, 4);
            } else {
                try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rdx, .rcx);
            try a.movRegMem(.rcx, .rsi, osr_ic_slot_byte_off);
            try a.addRegReg(.rdx, .rcx);

            try a.movReg32Mem(.rcx, .rdx, prop_desc_offset);
            try a.andRegImm8(.rcx, 9);
            try a.cmpRegImm32(.rcx, 1);
            try a.jcc(.ne, slow_path);

            try emitStoreSlotValOrSlow(a, .rdx, prop_val_offset, .r8, slow_path);
            try a.jmp(done_lbl);
        }
    } else {
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_obj) * 8));
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
        try a.jcc(.ne, slow_path);

        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);

        try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
        try a.jcc(.e, slow_path);

        try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
        try a.testRegReg(.rcx, .rcx);
        try a.jcc(.ne, slow_path);

        try a.movzxReg64Mem8(.rcx, .rax, zobj_is_extensible_offset);
        try a.testRegReg(.rcx, .rcx);
        try a.jcc(.e, slow_path);

        try a.movRegImm64(.rsi, site_ic_addr);
        try a.movReg32Mem(.rcx, .rsi, osr_ic_next_shape_off);
        try a.testReg32Reg32(.rcx, .rcx);
        try a.jcc(.e, slow_path);

        try a.movReg32Mem(.rcx, .rsi, osr_ic_cached_shape_off);
        try a.testReg32Reg32(.rcx, .rcx);
        try a.jcc(.e, slow_path);
        try a.movReg32Mem(.rdx, .rax, zobj_cached_shape_id_offset);
        try a.cmpReg32Reg32(.rdx, .rcx);
        try a.jcc(.ne, slow_path);

        try a.movReg32Mem(.rcx, .rsi, osr_ic_shape_off);
        try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
        try a.cmpReg32Reg32(.rdx, .rcx);
        try a.jcc(.ne, slow_path);

        try a.movReg32Mem(.rcx, .rsi, osr_ic_slot_off);
        try a.movzxReg64Mem16(.rdx, .rax, zobj_active_len_offset);
        try a.cmpRegReg(.rdx, .rcx);
        try a.jcc(.ne, slow_path);

        try a.movzxReg64Mem16(.rdx, .rax, zobj_cached_len_offset);
        try a.cmpRegReg(.rcx, .rdx);
        try a.jcc(.ae, slow_path);

        try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
        try a.cmpRegReg(.rcx, .rdx);
        try a.jcc(.ae, slow_path);

        try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
        try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
        if (comptime value_byte_offset_multiplier == 16) {
            try a.shlRegImm8(.rcx, 4);
        } else {
            try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
        }
        try a.addRegReg(.rdx, .rcx);
        try a.movRegMem(.rcx, .rsi, osr_ic_slot_byte_off);
        try a.addRegReg(.rdx, .rcx);

        try a.movReg32Mem(.rcx, .rdx, prop_desc_offset);
        try a.andRegImm8(.rcx, 9);
        try a.cmpRegImm32(.rcx, 1);
        try a.jcc(.ne, slow_path);

        try a.movRegMem(.rcx, .rdx, prop_val_offset);
        try a.cmpRegReg(.rcx, .r14);
        try a.jcc(.ae, slow_path);

        try a.movMemReg(.rdx, prop_val_offset, .r8);

        try a.movReg32Mem(.r9, .rsi, osr_ic_next_shape_off);
        try a.movMem32Reg(.rax, zobj_shape_id_offset, .r9);

        try a.movReg32Mem(.rcx, .rsi, osr_ic_slot_off);
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

    a.bindLabel(slow_path);
    if (cached_count > 0) {
        try emitFlushCached(a, cached_regs, cached_count);
    }
    try a.movRegReg(.rdi, .r13);
    try a.movRegReg(.rsi, .r12);
    try a.movRegImm64(.rdx, packed_info);
    try a.movRegImm64(.rcx, site_ic_addr);
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitSetPropOsr));
    try a.callReg(.rax);
    if (cached_count > 0) {
        try emitReloadCached(a, cached_regs, cached_count);
    }
    if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
    if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
    try a.movzxReg64Reg8(.rax, .rax);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, bail_lbl);
    a.bindLabel(done_lbl);
}

pub noinline fn emitGetPropOrGlobal(
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
        const idx = ip - self.start_ip;
        const name = constantName(block, op.b).?;
        const slot_addr = self.global_slot_addrs[idx];
        const dst_cached = (op.a < 64 and reg_to_xmm[op.a] != null);
        const forward_xmm3 = !dst_cached and isNextOpNumericConsumer(block, self.start_ip, ip, self.end_ip, self.prepass.is_jump_target, reg_to_xmm, op.a);
        const keep_prev_xmm3 = dst_cached and (self.live_xmm3_reg != null and self.live_xmm3_reg.? != op.a);

        const resolve_lbl = try a.createLabel();
        const hit_lbl = try a.createLabel();
        const slow_global_lbl = try a.createLabel();
        const done_global_lbl = try a.createLabel();
        const ver_addr: u64 = @intFromPtr(&environment_mod.env_struct_version);

        try a.movRegMem(.rax, .r13, ctx_frame_ptr_offset);
        try a.movRegMem(.rdx, .rax, frame_closure_env_offset);
        try a.movRegImm64(.rsi, slot_addr);
        try a.cmpRegMem(.rdx, .rsi, 0);
        try a.jcc(.ne, resolve_lbl);
        try a.movRegImm64(.rcx, ver_addr);
        try a.movRegMem(.rax, .rcx, 0);
        try a.cmpRegMem(.rax, .rsi, 16);
        try a.jcc(.e, hit_lbl);

        a.bindLabel(resolve_lbl);
        if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
        if (promoted.count > 0) try emitFlushPromoted(a, promoted);
        try a.movRegMem(.rax, .r13, ctx_frame_ptr_offset);
        try a.movRegMem(.rdi, .rax, frame_closure_env_offset);
        try a.movRegImm64(.rsi, @intFromPtr(name.ptr));
        try a.movRegImm64(.rdx, name.len);
        try a.movRegImm64(.rcx, slot_addr);
        try a.movRegImm64(.rax, @intFromPtr(&jitResolveGlobalSlot));
        try a.callReg(.rax);
        if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
        if (promoted.count > 0) try emitReloadPromoted(a, promoted);
        if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
        if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
        try a.movzxReg64Reg8(.rax, .rax);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bail_lbl);
        if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
            try self.loadNumToXmm(self.live_r8_i32.?, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.r8, .xmm0);
        }
        if (keep_prev_xmm3) {
            try a.movsdXmmMem(.xmm3, .r12, @intCast(@as(usize, self.live_xmm3_reg.?) * 8));
        }
        try a.movRegImm64(.rsi, slot_addr);

        a.bindLabel(hit_lbl);
        try a.movRegMem(.rax, .rsi, 8);
        try a.movRegMem(.rax, .rax, 0);
        if (dst_cached) {
            const xmm_dst = reg_to_xmm[op.a].?;
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(xmm_dst, .rax);
        } else if (forward_xmm3) {
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rcx, .r14);
            try a.jcc(.ae, slow_global_lbl);
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.movqXmmReg(.xmm3, .rax);
        } else {
            try emitStoreSlotValOrSlow(a, .r12, @intCast(@as(usize, op.a) * 8), .rax, slow_global_lbl);
        }
        try a.jmp(done_global_lbl);

        a.bindLabel(slow_global_lbl);
        if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
        if (promoted.count > 0) try emitFlushPromoted(a, promoted);
        try a.movRegReg(.rdi, .r13);
        try a.movRegReg(.rsi, .r12);
        try a.movRegImm32(.rdx, op.a);
        try a.movRegImm64(.rcx, @intFromPtr(name.ptr));
        try a.movRegImm64(.r8, name.len);
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitLoadGlobal));
        try a.callReg(.rax);
        if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
        if (promoted.count > 0) try emitReloadPromoted(a, promoted);
        if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
        if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bail_lbl);
        if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
            try self.loadNumToXmm(self.live_r8_i32.?, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.r8, .xmm0);
        }
        if (forward_xmm3) {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(.xmm3, .rax);
        }

        a.bindLabel(done_global_lbl);
        if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
            next_live_r8_i32.* = self.live_r8_i32;
        }
        if (forward_xmm3) {
            self.next_live_xmm3 = op.a;
        } else if (keep_prev_xmm3) {
            self.next_live_xmm3 = self.live_xmm3_reg;
        }
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
            if (self.live_xmm3_reg != null and self.live_xmm3_reg.? != op.a) self.next_live_xmm3 = self.live_xmm3_reg;
        } else {
            try self.storeXmmToNum(op.a, xmm_prop, bail_lbl);
        }
        return;
    }
    const idx = ip - self.start_ip;
    const eff_obj = self.prepass.compound_arr_override[idx] orelse (if (op.b < 64) (self.cur_copy_src[op.b] orelse op.b) else op.b);
    const key = constantName(block, op.c).?;
    if (std.mem.eql(u8, key, "length")) {
        if (hoisted_arrs.find(eff_obj)) |h_slot| {
            if (hoisted_arrs.kinds[h_slot].isPtrLen()) {
                const dst_xmm: Xmm = if (op.a < 64 and reg_to_xmm[op.a] != null) reg_to_xmm[op.a].? else .xmm0;
                if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                    try a.cvtsi2sdqXmmReg64(dst_xmm, .rbp);
                } else {
                    try a.movRegMem(.rax, .rsp, @intCast(h_slot * 16 + 8));
                    try a.cvtsi2sdqXmmReg64(dst_xmm, .rax);
                }
                if (!(op.a < 64 and reg_to_xmm[op.a] != null)) {
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
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
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                }
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                return;
            }
        }
    }

    const site_ic_addr = self.prop_ic_addrs[idx];
    const compile_ic = self.prop_ics_init[idx];
    const dst_cached = (op.a < 64 and reg_to_xmm[op.a] != null);
    const forward_xmm3 = !dst_cached and isNextOpNumericConsumer(block, self.start_ip, ip, self.end_ip, self.prepass.is_jump_target, reg_to_xmm, op.a);
    const keep_prev_xmm3 = dst_cached and (self.live_xmm3_reg != null and self.live_xmm3_reg.? != op.a);
    const allow_non_num_flag: u64 = if (!dst_cached and !forward_xmm3) (@as(u64, 1) << 24) else 0;
    const packed_info: u64 = allow_non_num_flag | (@as(u64, op.c) << 16) | (@as(u64, eff_obj) << 8) | @as(u64, op.a);

    const slow_path = try a.createLabel();
    const done_lbl = try a.createLabel();

    if (std.mem.eql(u8, key, "length")) {
        const not_arr_lbl = try a.createLabel();
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_obj) * 8));
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
        const dst_xmm: Xmm = if (dst_cached) reg_to_xmm[op.a].? else .xmm0;
        try a.cvtsi2sdqXmmReg64(dst_xmm, .rax);
        if (!dst_cached) {
            try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            if (forward_xmm3) {
                try a.movsdXmmXmm(.xmm3, .xmm0);
            }
        }
        try a.jmp(done_lbl);
        a.bindLabel(not_arr_lbl);

        const not_str_lbl = try a.createLabel();
        const str_slow_lbl = try a.createLabel();
        const str_done_lbl = try a.createLabel();
        try a.cmpRegImm32(.rcx, HEADER_STRING);
        try a.jcc(.ne, not_str_lbl);
        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);

        try a.movRegMem(.rdx, .rax, str_data_len_off);
        try a.cmpRegImm32(.rdx, 8);
        try a.jcc(.ne, str_slow_lbl);
        try a.movRegMem(.rcx, .rax, str_data_ptr_off);
        try a.movRegMem(.rcx, .rcx, 0);
        try a.movRegImm64(.rsi, 0x8080_8080_8080_8080);
        try a.testRegReg(.rcx, .rsi);
        try a.jcc(.ne, str_slow_lbl);
        try a.movRegReg(.rax, .rdx);
        try a.jmp(str_done_lbl);

        a.bindLabel(str_slow_lbl);
        if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
        if (promoted.count > 0) try emitFlushPromoted(a, promoted);
        try a.movRegReg(.rdi, .rax);
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitStringLength));
        try a.callReg(.rax);
        if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
        if (promoted.count > 0) try emitReloadPromoted(a, promoted);
        if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
        if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);

        a.bindLabel(str_done_lbl);
        try a.cvtsi2sdqXmmReg64(dst_xmm, .rax);
        if (!dst_cached) {
            try emitStoreXmmToNum(a, reg_to_xmm, op.a, .xmm0, bail_lbl);
            if (forward_xmm3) {
                try a.movsdXmmXmm(.xmm3, .xmm0);
            }
        }
        try a.jmp(done_lbl);
        a.bindLabel(not_str_lbl);
    }

    if (self.findCachedObjPtr(eff_obj, compile_ic.shape_id, compile_ic.slot_idx, false)) |ptr_reg| {
        if (forward_xmm3) {
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rcx, .r14);
            try a.jcc(.ae, slow_path);
        }
        try a.testRegReg(ptr_reg, ptr_reg);
        try a.jcc(.e, slow_path);

        const slot_off: i32 = @intCast(compile_ic.slot_byte_off);
        try a.testMem32Imm32(ptr_reg, slot_off + prop_desc_offset, 8);
        try a.jcc(.ne, slow_path);

        try a.movRegMem(.rax, ptr_reg, slot_off + prop_val_offset);
        if (dst_cached) {
            const xmm_dst = reg_to_xmm[op.a].?;
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movqXmmReg(xmm_dst, .rax);
        } else if (forward_xmm3) {
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.movqXmmReg(.xmm3, .rax);
        } else {
            try emitStoreSlotValOrSlow(a, .r12, @intCast(@as(usize, op.a) * 8), .rax, slow_path);
        }
        try a.jmp(done_lbl);
    } else if (op.a != eff_obj and !std.mem.eql(u8, key, "length") and compile_ic.next_shape == 0) blk_setup: {
        const setup = self.trySetupCachedObjPtr(idx, eff_obj, compile_ic.shape_id, compile_ic.slot_idx, false) orelse break :blk_setup;
        try a.xorReg32Reg32(setup.reg, setup.reg);

        try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_obj) * 8));
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
        try a.jcc(.ne, slow_path);

        if (forward_xmm3) {
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rcx, .r14);
            try a.jcc(.ae, slow_path);
        }

        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);

        try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
        try a.testRegReg(.rcx, .rcx);
        try a.jcc(.ne, slow_path);

        if (setup.any_written) {
            try a.movzxReg64Mem8(.rcx, .rax, zobj_is_frozen_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, slow_path);
        }

        try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
        try a.cmpReg32Imm32(.rdx, @bitCast(compile_ic.shape_id));
        try a.jcc(.ne, slow_path);

        try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
        try a.cmpRegImm32(.rdx, @intCast(setup.max_slot));
        try a.jcc(.be, slow_path);

        try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
        try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
        if (comptime value_byte_offset_multiplier == 16) {
            try a.shlRegImm8(.rcx, 4);
        } else {
            try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
        }
        try a.addRegReg(.rdx, .rcx);

        const slot_off: i32 = @intCast(compile_ic.slot_byte_off);
        try a.testMem32Imm32(.rdx, slot_off + prop_desc_offset, 8);
        try a.jcc(.ne, slow_path);

        try a.movRegMem(.rax, .rdx, slot_off + prop_val_offset);
        if (dst_cached) {
            const xmm_dst = reg_to_xmm[op.a].?;
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movqXmmReg(xmm_dst, .rax);
        } else if (forward_xmm3) {
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.movqXmmReg(.xmm3, .rax);
        } else {
            try emitStoreSlotValOrSlow(a, .r12, @intCast(@as(usize, op.a) * 8), .rax, slow_path);
        }
        try a.movRegReg(setup.reg, .rdx);
        try a.jmp(done_lbl);
    } else {
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_obj) * 8));
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
        try a.jcc(.ne, slow_path);

        if (forward_xmm3) {
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.a) * 8));
            try a.cmpRegReg(.rcx, .r14);
            try a.jcc(.ae, slow_path);
        }

        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);

        try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
        try a.jcc(.e, slow_path);

        try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
        try a.testRegReg(.rcx, .rcx);
        try a.jcc(.ne, slow_path);

        try a.movRegImm64(.rsi, site_ic_addr);
        try a.movReg32Mem(.rcx, .rsi, osr_ic_shape_off);
        try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
        try a.cmpReg32Reg32(.rdx, .rcx);
        try a.jcc(.ne, slow_path);

        try a.movReg32Mem(.rcx, .rsi, osr_ic_slot_off);
        try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
        try a.cmpRegReg(.rcx, .rdx);
        try a.jcc(.ae, slow_path);

        try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
        try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
        if (comptime value_byte_offset_multiplier == 16) {
            try a.shlRegImm8(.rcx, 4);
        } else {
            try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
        }
        try a.addRegReg(.rdx, .rcx);
        try a.movRegMem(.rcx, .rsi, osr_ic_slot_byte_off);
        try a.addRegReg(.rdx, .rcx);

        try a.testMem32Imm32(.rdx, prop_desc_offset, 8);
        try a.jcc(.ne, slow_path);

        try a.movRegMem(.rax, .rdx, prop_val_offset);
        if (dst_cached) {
            const xmm_dst = reg_to_xmm[op.a].?;
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movqXmmReg(xmm_dst, .rax);
        } else if (forward_xmm3) {
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, slow_path);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.movqXmmReg(.xmm3, .rax);
        } else {
            try emitStoreSlotValOrSlow(a, .r12, @intCast(@as(usize, op.a) * 8), .rax, slow_path);
        }
        try a.jmp(done_lbl);
    }

    a.bindLabel(slow_path);
    if (cached_count > 0) {
        try emitFlushCached(a, cached_regs, cached_count);
    }
    if (promoted.count > 0) {
        try emitFlushPromoted(a, promoted);
    }
    try a.movRegReg(.rdi, .r13);
    try a.movRegReg(.rsi, .r12);
    try a.movRegImm64(.rdx, packed_info);
    try a.movRegImm64(.rcx, site_ic_addr);
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitGetPropOsr));
    try a.callReg(.rax);
    if (cached_count > 0) {
        try emitReloadCached(a, cached_regs, cached_count);
    }
    if (promoted.count > 0) {
        try emitReloadPromoted(a, promoted);
    }
    if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
    if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
    try a.movzxReg64Reg8(.rax, .rax);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, bail_lbl);
    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
        try self.loadNumToXmm(self.live_r8_i32.?, .xmm0, bail_lbl);
        try a.cvttsd2siReg32Xmm(.r8, .xmm0);
    }
    if (dst_cached) {
        const xmm_dst = reg_to_xmm[op.a].?;
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
        try a.cmpRegReg(.rax, .r15);
        try a.jcc(.ae, bail_lbl);
        try a.movqXmmReg(xmm_dst, .rax);
        if (keep_prev_xmm3) {
            try a.movsdXmmMem(.xmm3, .r12, @intCast(@as(usize, self.live_xmm3_reg.?) * 8));
        }
    } else if (forward_xmm3) {
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.a) * 8));
        try a.cmpRegReg(.rax, .r15);
        try a.jcc(.ae, bail_lbl);
        try a.movqXmmReg(.xmm3, .rax);
    }
    a.bindLabel(done_lbl);
    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
        next_live_r8_i32.* = self.live_r8_i32;
    }
    if (forward_xmm3) {
        self.next_live_xmm3 = op.a;
    } else if (keep_prev_xmm3) {
        self.next_live_xmm3 = self.live_xmm3_reg;
    }
}

pub noinline fn emitOsrStringCharCodeAt(
    self: *OsrCompiler,
    str_reg: u8,
    idx_is_exact_int: bool,
    bail_lbl: Label,
) !void {
    const a = self.a;
    const cached_regs = &self.analysis.cached_regs;
    const cached_count = self.analysis.cached_count;
    const promoted = &self.analysis.promoted;
    const slow_lbl = try a.createLabel();
    const done_lbl = try a.createLabel();

    try a.movRegMem(.rax, .r12, @intCast(@as(usize, str_reg) * 8));
    try a.movRegReg(.rcx, .rax);
    try a.shrRegImm8(.rcx, 47);
    try a.cmpRegImm32(.rcx, HEADER_STRING);
    try a.jcc(.ne, bail_lbl);

    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
    try a.andRegReg(.rax, .rcx);

    try a.cvttsd2siqReg64Xmm(.rdx, .xmm0);
    if (!idx_is_exact_int) {
        try a.cvtsi2sdqXmmReg64(.xmm1, .rdx);
        try a.ucomisd(.xmm0, .xmm1);
        try a.jcc(.p, slow_lbl);
        try a.jcc(.ne, slow_lbl);
    }

    try a.movRegMem(.rcx, .rax, str_data_len_off);
    try a.cmpRegImm32(.rcx, 8);
    try a.jcc(.ne, slow_lbl);
    try a.cmpRegReg(.rdx, .rcx);
    try a.jcc(.ae, slow_lbl);

    try a.movRegMem(.rcx, .rax, str_data_ptr_off);
    try a.movRegMem(.rsi, .rcx, 0);
    try a.movRegImm64(.rdi, 0x8080_8080_8080_8080);
    try a.testRegReg(.rsi, .rdi);
    try a.jcc(.ne, slow_lbl);

    try a.movzxReg32Mem8Indexed1(.rcx, .rcx, .rdx, 0);
    try a.cvtsi2sdXmmReg32(.xmm0, .rcx);
    try a.jmp(done_lbl);

    a.bindLabel(slow_lbl);
    try a.movRegReg(.rdi, .rax);
    try a.movqRegXmm(.rsi, .xmm0);
    if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
    if (promoted.count > 0) try emitFlushPromoted(a, promoted);
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitStringCharCodeAt));
    try a.callReg(.rax);
    if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
    if (promoted.count > 0) try emitReloadPromoted(a, promoted);
    if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
    if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
    try a.movqXmmReg(.xmm0, .rax);

    a.bindLabel(done_lbl);
}

pub noinline fn emitCallOp(
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

    if (op.opcode == .call and self.prepass.char_code_at_str_reg[idx] != null) {
        const raw_str_r = self.prepass.char_code_at_str_reg[idx].?;
        const eff_str_r = if (raw_str_r < 64) (self.cur_copy_src[raw_str_r] orelse raw_str_r) else raw_str_r;
        const arg_reg: u8 = op.b + 1;
        try self.loadNumToXmm(arg_reg, .xmm0, bail_lbl);
        const idx_exact = (arg_reg < 64 and (self.reg_is_int32[arg_reg] or self.reg_is_exact_idx[arg_reg]));
        try self.emitOsrStringCharCodeAt(eff_str_r, idx_exact, bail_lbl);
        try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
        if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
        return;
    }

    if (op.opcode == .call) {
        if (classifyMathIntrinsicCall(cs)) |mk| {
            if (!self.elided_math_call[idx]) {
                const expected_callee = cs.callee orelse return error.CannotCompile;
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                try a.movRegImm64(.rcx, expected_callee.bits);
                try a.cmpRegReg(.rax, .rcx);
                try a.jcc(.ne, bail_lbl);
            }
            switch (mk) {
                .sqrt => {
                    const arg_reg: u8 = op.b + 1;
                    try self.loadNumToXmm(arg_reg, .xmm0, bail_lbl);
                    try a.sqrtsd(.xmm0, .xmm0);
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                },
                .abs => {
                    const arg_reg: u8 = op.b + 1;
                    try self.loadNumToXmm(arg_reg, .xmm0, bail_lbl);
                    try a.movRegImm64(.rax, 0x7FFF_FFFF_FFFF_FFFF);
                    try a.movqXmmReg(.xmm1, .rax);
                    try a.andpd(.xmm0, .xmm1);
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                },
                .floor, .ceil, .trunc => {
                    const arg_reg: u8 = op.b + 1;
                    const round_mode: u8 = switch (mk) {
                        .floor => 0x09,
                        .ceil => 0x0A,
                        .trunc => 0x0B,
                        else => unreachable,
                    };
                    try self.loadNumToXmm(arg_reg, .xmm0, bail_lbl);
                    if (!(arg_reg < 64 and self.reg_is_int32[arg_reg])) {
                        try a.roundsd(.xmm0, .xmm0, round_mode);
                    }
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                },
                .min2, .max2 => {
                    const arg0_reg: u8 = op.b + 1;
                    const arg1_reg: u8 = op.b + 2;
                    try self.loadNumToXmm(arg0_reg, .xmm0, bail_lbl);
                    try self.loadNumToXmm(arg1_reg, .xmm1, bail_lbl);
                    const special_lbl = try a.createLabel();
                    const is_nan_lbl = try a.createLabel();
                    const done_mm_lbl = try a.createLabel();
                    try a.ucomisd(.xmm0, .xmm1);
                    try a.jcc(.p, is_nan_lbl);
                    try a.jcc(.e, special_lbl);
                    if (mk == .min2) {
                        try a.minsd(.xmm0, .xmm1);
                    } else {
                        try a.maxsd(.xmm0, .xmm1);
                    }
                    try a.jmp(done_mm_lbl);
                    a.bindLabel(special_lbl);
                    if (mk == .min2) {
                        try a.orpd(.xmm0, .xmm1);
                    } else {
                        try a.andpd(.xmm0, .xmm1);
                    }
                    try a.jmp(done_mm_lbl);
                    a.bindLabel(is_nan_lbl);
                    try a.addsd(.xmm0, .xmm1);
                    a.bindLabel(done_mm_lbl);
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
                    return;
                },
                .imul => {
                    const arg0_reg: u8 = op.b + 1;
                    const arg1_reg: u8 = op.b + 2;
                    const arg0_ok_lbl = try a.createLabel();
                    const arg1_ok_lbl = try a.createLabel();
                    const cached_regs = &self.analysis.cached_regs;
                    const cached_count = self.analysis.cached_count;
                    const promoted = &self.analysis.promoted;

                    if (self.live_r8_i32 != null and self.live_r8_i32.? == arg0_reg) {
                        try a.movReg32Reg32(.rax, .r8);
                    } else if (arg0_reg < 64 and self.reg_is_int32[arg0_reg]) {
                        try self.loadNumToXmm(arg0_reg, .xmm0, bail_lbl);
                        try a.cvttsd2siReg32Xmm(.rax, .xmm0);
                    } else {
                        try self.loadNumToXmm(arg0_reg, .xmm0, bail_lbl);
                        try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
                        try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                        try a.cmpRegReg(.rax, .rdx);
                        try a.jcc(.ne, arg0_ok_lbl);
                        try a.movqRegXmm(.rdi, .xmm0);
                        if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
                        if (promoted.count > 0) try emitFlushPromoted(a, promoted);
                        try a.movRegImm64(.rax, @intFromPtr(&vm.jitF64ToInt32));
                        try a.callReg(.rax);
                        if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
                        if (promoted.count > 0) try emitReloadPromoted(a, promoted);
                        if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
                        if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
                        a.bindLabel(arg0_ok_lbl);
                    }

                    if (arg1_reg < 64 and self.reg_is_int32[arg1_reg]) {
                        try a.movReg32Reg32(.rcx, .rax);
                        try self.loadNumToXmm(arg1_reg, .xmm1, bail_lbl);
                        try a.movReg32Reg32(.rax, .rcx);
                        try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
                    } else {
                        try a.movReg32Reg32(.rcx, .rax);
                        try self.loadNumToXmm(arg1_reg, .xmm1, bail_lbl);
                        try a.movReg32Reg32(.rax, .rcx);
                        try a.cvttsd2siqReg64Xmm(.rcx, .xmm1);
                        try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                        try a.cmpRegReg(.rcx, .rdx);
                        try a.jcc(.ne, arg1_ok_lbl);

                        try a.pushReg(.rax);
                        try a.subRegImm32(.rsp, 8);
                        try a.movqRegXmm(.rdi, .xmm1);
                        if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
                        if (promoted.count > 0) try emitFlushPromoted(a, promoted);
                        try a.movRegImm64(.rax, @intFromPtr(&vm.jitF64ToInt32));
                        try a.callReg(.rax);
                        if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
                        if (promoted.count > 0) try emitReloadPromoted(a, promoted);
                        if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
                        if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
                        try a.movReg32Reg32(.rcx, .rax);
                        try a.addRegImm32(.rsp, 8);
                        try a.popReg(.rax);
                        a.bindLabel(arg1_ok_lbl);
                    }

                    try a.imulReg32Reg32(.rax, .rcx);
                    try a.movReg32Reg32(.r8, .rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                    if (op.a < 64) next_live_r8_i32.* = op.a;
                    return;
                },
            }
        }
    }

    if (self.prepass.inlined_calls[idx]) {
        try emitInlinedCall(self, idx, op, bail_lbl, next_live_r8_i32);
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

    const has_borrowed_arg0 = (idx > 0 and self.prepass.borrowed_str_arg_call[idx - 1]);
    const pre_call_bail_lbl = if (has_borrowed_arg0) try a.createLabel() else bail_lbl;

    if (op.opcode == .call) {
        const expected_callee = cs.callee orelse return error.CannotCompile;
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
        try a.movRegImm64(.rcx, expected_callee.bits);
        try a.cmpRegReg(.rax, .rcx);
        try a.jcc(.ne, pre_call_bail_lbl);
    } else {
        try a.movRegMem(.rcx, .r13, global_ver_ptr_off);
        try a.movRegMem(.rax, .rcx, 0);
        try a.movRegImm64(.rdx, cache_addr);
        try a.movRegMem(.rdx, .rdx, @intCast(@offsetOf(codeblock.CallSiteCache, "global_version")));
        try a.cmpRegReg(.rax, .rdx);
        try a.jcc(.ne, pre_call_bail_lbl);
    }

    try a.movRegImm64(.rcx, target_addr);
    try a.movRegMem(.r11, .rcx, jit_fn_off);
    try a.testRegReg(.r11, .r11);
    try a.jcc(.e, pre_call_bail_lbl);

    const arg_start = @as(usize, op.b) + 1;
    const str_mask = tb.jit_string_param_mask;
    if (has_borrowed_arg0) {
        try a.movRegMem(.rax, .r12, callee_regs_off);
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, HEADER_STRING);
        try a.jcc(.ne, pre_call_bail_lbl);
    } else {
        for (0..arg_count) |i_arg| {
            const ar = arg_start + i_arg;
            if (ar < 64 and reg_to_xmm[ar] != null) continue;
            try a.movRegMem(.rax, .r12, @intCast(ar * 8));
            if (i_arg < 32 and (str_mask & (@as(u32, 1) << @intCast(i_arg))) != 0) {
                const arg_ok_lbl = try a.createLabel();
                try a.cmpRegReg(.rax, .r14);
                try a.jcc(.b, arg_ok_lbl);
                try a.movRegReg(.rcx, .rax);
                try a.shrRegImm8(.rcx, 47);
                try a.cmpRegImm32(.rcx, HEADER_STRING);
                try a.jcc(.ne, pre_call_bail_lbl);
                a.bindLabel(arg_ok_lbl);
            } else {
                try a.cmpRegReg(.rax, .r14);
                try a.jcc(.ae, pre_call_bail_lbl);
            }
        }
    }

    try a.lea(.rax, .r12, total_bytes);
    try a.movRegMem(.rcx, .r13, regs_limit_off);
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.a, pre_call_bail_lbl);

    if (!has_borrowed_arg0) {
        for (0..arg_count) |i_arg| {
            const ar = arg_start + i_arg;
            if (ar < 64 and reg_to_xmm[ar] != null) {
                const xmm_a = reg_to_xmm[ar].?;
                try a.movqRegXmm(.rax, xmm_a);
                try a.ucomisd(xmm_a, xmm_a);
                try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                try a.cmovpRegReg(.rax, .rcx);
                try a.movMemReg(.r12, callee_regs_off + @as(i32, @intCast(i_arg * 8)), .rax);
            } else {
                try a.movRegMem(.rax, .r12, @intCast(ar * 8));
                try a.movMemReg(.r12, callee_regs_off + @as(i32, @intCast(i_arg * 8)), .rax);
            }
        }
    }

    try a.lea(.rdi, .r12, callee_regs_off);
    try a.movRegMem(.rdx, .r13, regs_limit_off);
    try a.movRegImm64(.rcx, cache_addr);
    try a.movRegMem(.rcx, .rcx, closure_env_off);

    try a.subRegImm32(.rsp, 16);
    try a.movRegReg(.rsi, .rsp);
    try a.callReg(.r11);

    if (str_mask != 0) {
        for (0..arg_count) |i_arg| {
            if (i_arg < 32 and (str_mask & (@as(u32, 1) << @intCast(i_arg))) != 0) {
                try a.movMemReg(.r12, callee_regs_off + @as(i32, @intCast(i_arg * 8)), .r15);
            }
        }
    }

    try a.testRegReg(.rax, .rax);
    const call_ok_lbl = try a.createLabel();
    try a.jcc(.e, call_ok_lbl);

    try a.addRegImm32(.rsp, 16);
    try a.jmp(bail_lbl);

    if (has_borrowed_arg0) {
        a.bindLabel(pre_call_bail_lbl);
        try a.movMemReg(.r12, callee_regs_off, .r15);
        try a.jmp(bail_lbl);
    }

    a.bindLabel(call_ok_lbl);
    if (op.a < 64 and reg_to_xmm[op.a] != null) {
        const xmm_dst = reg_to_xmm[op.a].?;
        try a.movsdXmmMem(xmm_dst, .rsp, 0);
        try a.addRegImm32(.rsp, 16);
        if (self.live_xmm3_reg != null and self.live_xmm3_reg.? != op.a) {
            self.next_live_xmm3 = self.live_xmm3_reg;
        }
        return;
    }

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
    try a.movRegMem(.rax, .rsp, 0);
    try a.addRegImm32(.rsp, 16);
    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
}

pub noinline fn emitInlinedCall(
    self: *OsrCompiler,
    idx: usize,
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
    const cs = &block.call_target_cache[op.c];
    const tb = cs.target_block.?;
    const caller_regs: usize = block.register_count;
    const total_regs = caller_regs + tb.register_count;
    const total_bytes: i32 = @intCast(total_regs * 8);

    const regs_limit_off: i32 = @intCast(@offsetOf(codeblock.OsrContext, "regs_limit"));
    const global_ver_ptr_off: i32 = @intCast(@offsetOf(codeblock.OsrContext, "global_version_ptr"));

    try a.lea(.rax, .r12, total_bytes);
    try a.movRegMem(.rcx, .r13, regs_limit_off);
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.a, bail_lbl);

    const this_caller_reg: ?u8 = if (self.prepass.inlined_method_elision[idx]) |ime|
        (if (ime.eff_this_reg < 64) (self.cur_copy_src[ime.eff_this_reg] orelse ime.eff_this_reg) else ime.eff_this_reg)
    else if (cs.this_reg) |tr|
        (if (tr < 64) (self.cur_copy_src[tr] orelse tr) else tr)
    else
        null;

    if (op.opcode == .call_global) {
        try a.movRegMem(.rcx, .r13, global_ver_ptr_off);
        try a.movRegMem(.rax, .rcx, 0);
        try a.movRegImm64(.rdx, @intFromPtr(cs));
        try a.movRegMem(.rdx, .rdx, @intCast(@offsetOf(codeblock.CallSiteCache, "global_version")));
        try a.cmpRegReg(.rax, .rdx);
        try a.jcc(.ne, bail_lbl);
    } else if (self.prepass.inlined_method_elision[idx]) |ime| {
        const eff_tr = this_caller_reg.?;
        if (eff_tr < 64 and reg_to_xmm[eff_tr] != null) return error.CannotCompile;
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_tr) * 8));
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
        try a.jcc(.ne, bail_lbl);

        try a.movRegImm64(.rcx, JSValue.PTR_MASK);
        try a.andRegReg(.rax, .rcx);
        try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
        try a.jcc(.e, bail_lbl);

        try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
        try a.testRegReg(.rcx, .rcx);
        try a.jcc(.ne, bail_lbl);

        try a.movReg32Mem(.rcx, .rax, zobj_shape_id_offset);
        try a.cmpReg32Imm32(.rcx, @bitCast(ime.receiver_shape_id));
        try a.jcc(.ne, bail_lbl);

        if (ime.is_proto) {
            try a.movRegMem(.rcx, .rax, zobj_prototype_offset);
            try a.movRegImm64(.rdx, ime.proto_ptr);
            try a.cmpRegReg(.rcx, .rdx);
            try a.jcc(.ne, bail_lbl);

            try a.movzxReg64Mem16(.rdx, .rcx, raw_zobj_cached_len_offset);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);

            try a.movReg32Mem(.rdx, .rcx, raw_zobj_shape_id_offset);
            try a.cmpReg32Imm32(.rdx, @bitCast(ime.proto_shape_id));
            try a.jcc(.ne, bail_lbl);

            try a.movRegMem(.rdx, .rcx, raw_zobj_entries_bytes_offset);
            try a.movRegImm64(.rsi, ime.proto_bytes_ptr);
            try a.cmpRegReg(.rdx, .rsi);
            try a.jcc(.ne, bail_lbl);

            try a.movRegImm64(.rdx, ime.proto_rec_addr);
            try a.testMem32Imm32(.rdx, prop_desc_offset, 8);
            try a.jcc(.ne, bail_lbl);

            try a.movRegMem(.rax, .rdx, prop_val_offset);
            try a.movRegImm64(.rcx, ime.expected_callee_bits);
            try a.cmpRegReg(.rax, .rcx);
            try a.jcc(.ne, bail_lbl);
        } else {
            try a.movRegMem(.rcx, .rax, zobj_entries_len_offset);
            try a.cmpRegImm32(.rcx, @intCast(ime.own_slot_idx));
            try a.jcc(.be, bail_lbl);

            try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
            try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
            if (comptime value_byte_offset_multiplier == 16) {
                try a.shlRegImm8(.rcx, 4);
            } else {
                try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
            }
            try a.addRegReg(.rdx, .rcx);

            const slot_off: i32 = @intCast(ime.own_slot_byte_off);
            try a.testMem32Imm32(.rdx, slot_off + prop_desc_offset, 8);
            try a.jcc(.ne, bail_lbl);

            try a.movRegMem(.rax, .rdx, slot_off + prop_val_offset);
            try a.movRegImm64(.rcx, ime.expected_callee_bits);
            try a.cmpRegReg(.rax, .rcx);
            try a.jcc(.ne, bail_lbl);
        }
    } else {
        const expected_callee = cs.callee orelse return error.CannotCompile;
        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
        try a.movRegImm64(.rcx, expected_callee.bits);
        try a.cmpRegReg(.rax, .rcx);
        try a.jcc(.ne, bail_lbl);

        if (this_caller_reg) |eff_tr| {
            if (eff_tr < 64 and reg_to_xmm[eff_tr] != null) return error.CannotCompile;
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, eff_tr) * 8));
            try a.movRegReg(.rcx, .rax);
            try a.shrRegImm8(.rcx, 47);
            try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
            try a.jcc(.ne, bail_lbl);

            try a.movRegImm64(.rcx, JSValue.PTR_MASK);
            try a.andRegReg(.rax, .rcx);
            try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
            try a.jcc(.e, bail_lbl);
        }
    }

    var callee_is_jump_target: [MAX_INLINED_CALLEE_OPS]bool = @splat(false);
    var c_labels: [MAX_INLINED_CALLEE_OPS]Label = undefined;
    for (0..tb.ops.len) |c_i| {
        c_labels[c_i] = try a.createLabel();
        const cop = tb.ops[c_i];
        const maybe_t: ?usize = switch (cop.opcode) {
            .jump, .jump_if_false, .jump_if_true => (@as(usize, cop.b) << 8) | cop.c,
            .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => c_i + @as(usize, cop.c),
            else => null,
        };
        if (maybe_t) |t| {
            if (t < tb.ops.len) callee_is_jump_target[t] = true;
        }
    }
    const inlined_done_lbl = try a.createLabel();

    var reg_alias: [MAX_INLINED_CALLEE_REGS]?u8 = @splat(null);
    for (0..tb.param_count) |p| {
        const raw_ar: u8 = @intCast(@as(usize, op.b) + 1 + p);
        reg_alias[p] = if (raw_ar < 64) (self.cur_copy_src[raw_ar] orelse raw_ar) else raw_ar;
    }

    if (tb.local_count > tb.param_count) {
        for (tb.param_count..tb.local_count) |loc_r| {
            try a.movMemReg(.r12, @intCast((caller_regs + loc_r) * 8), .r15);
        }
    }

    const loadCalleeNumToXmm = struct {
        fn call(
            oc: *OsrCompiler,
            aliases: *const [MAX_INLINED_CALLEE_REGS]?u8,
            c_base: usize,
            c_reg: u8,
            target_xmm: Xmm,
            b_lbl: Label,
        ) !void {
            if (aliases[c_reg]) |cr| {
                try oc.loadNumToXmm(cr, target_xmm, b_lbl);
            } else {
                try oc.a.movRegMem(.rax, .r12, @intCast((c_base + c_reg) * 8));
                try oc.a.cmpRegReg(.rax, .r15);
                try oc.a.jcc(.ae, b_lbl);
                try oc.a.movqXmmReg(target_xmm, .rax);
            }
        }
    }.call;

    const storeXmmToCallee = struct {
        fn call(
            asm_a: *x64_asm.Assembler,
            aliases: *[MAX_INLINED_CALLEE_REGS]?u8,
            c_base: usize,
            c_reg: u8,
            src_xmm: Xmm,
        ) !void {
            aliases[c_reg] = null;
            try asm_a.movqRegXmm(.rax, src_xmm);
            try asm_a.ucomisd(src_xmm, src_xmm);
            try asm_a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
            try asm_a.cmovpRegReg(.rax, .rcx);
            try asm_a.movMemReg(.r12, @intCast((c_base + c_reg) * 8), .rax);
        }
    }.call;

    var c_skip: u8 = 0;
    for (0..tb.ops.len) |c_ip| {
        a.bindLabel(c_labels[c_ip]);
        if (callee_is_jump_target[c_ip]) {
            for (tb.param_count..MAX_INLINED_CALLEE_REGS) |r| {
                reg_alias[r] = null;
            }
        }
        if (c_skip > 0) {
            c_skip -= 1;
            continue;
        }
        const c_op = tb.ops[c_ip];
        const next_is_ret_self = (c_ip + 1 < tb.ops.len and !callee_is_jump_target[c_ip + 1] and tb.ops[c_ip + 1].opcode == .return_value and tb.ops[c_ip + 1].a == c_op.a);

        switch (c_op.opcode) {
            .nop => {},
            .load_this => {
                const tr = this_caller_reg.?;
                if (c_op.a >= tb.local_count) {
                    reg_alias[c_op.a] = tr;
                } else {
                    try a.movRegMem(.rax, .r12, @intCast(@as(usize, tr) * 8));
                    try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
                    reg_alias[c_op.a] = null;
                }
            },
            .load_undefined => {
                reg_alias[c_op.a] = null;
                try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .r15);
            },
            .load_null => {
                reg_alias[c_op.a] = null;
                try a.movRegImm64(.rax, JSValue.NULL.bits);
                try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
            },
            .load_true => {
                reg_alias[c_op.a] = null;
                try a.movRegImm64(.rax, JSValue.fromBool(true).bits);
                try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
            },
            .load_false => {
                reg_alias[c_op.a] = null;
                try a.movRegImm64(.rax, JSValue.fromBool(false).bits);
                try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
            },
            .load_const => {
                const c = tb.constants[c_op.b];
                const bits: u64 = switch (c) {
                    .number => |n| JSValue.fromNumber(n).bits,
                    .boolean => |b| JSValue.fromBool(b).bits,
                    else => unreachable,
                };
                if (c == .number and next_is_ret_self) {
                    try a.movRegImm64(.rax, bits);
                    try a.movqXmmReg(.xmm0, .rax);
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    reg_alias[c_op.a] = null;
                    try a.movRegImm64(.rax, bits);
                    try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
                }
            },
            .move, .load_local, .store_local => {
                if (c_op.a >= tb.local_count and reg_alias[c_op.b] != null) {
                    reg_alias[c_op.a] = reg_alias[c_op.b];
                } else {
                    if (reg_alias[c_op.b]) |cr| {
                        if (cr < 64 and reg_to_xmm[cr] != null) {
                            const x = reg_to_xmm[cr].?;
                            try a.movqRegXmm(.rax, x);
                            try a.ucomisd(x, x);
                            try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                            try a.cmovpRegReg(.rax, .rcx);
                        } else if (self.live_xmm3_reg != null and self.live_xmm3_reg.? == cr) {
                            try a.movqRegXmm(.rax, .xmm3);
                            try a.ucomisd(.xmm3, .xmm3);
                            try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
                            try a.cmovpRegReg(.rax, .rcx);
                        } else {
                            try a.movRegMem(.rax, .r12, @intCast(@as(usize, cr) * 8));
                        }
                    } else {
                        try a.movRegMem(.rax, .r12, @intCast((caller_regs + c_op.b) * 8));
                    }
                    reg_alias[c_op.a] = null;
                    try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
                }
            },
            .get_prop => {
                const key = constantName(tb, c_op.c).?;
                const maybe_cr = reg_alias[c_op.b];
                if (maybe_cr != null and maybe_cr.? < 64 and reg_to_xmm[maybe_cr.?] != null) {
                    try a.jmp(bail_lbl);
                    continue;
                }
                const obj_byte_off: i32 = if (maybe_cr) |cr|
                    @intCast(@as(usize, cr) * 8)
                else
                    @intCast((caller_regs + c_op.b) * 8);

                if (std.mem.eql(u8, key, "length") and maybe_cr != null) {
                    if (hoisted_arrs.find(maybe_cr.?)) |h_slot| {
                        if (hoisted_arrs.kinds[h_slot].isPtrLen()) {
                            if (h_slot == 0 and hoisted_arrs.primary_in_regs) {
                                try a.cvtsi2sdqXmmReg64(.xmm0, .rbp);
                            } else {
                                try a.movRegMem(.rax, .rsp, @intCast(h_slot * 16 + 8));
                                try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
                            }
                            if (next_is_ret_self) {
                                try a.jmp(inlined_done_lbl);
                                c_skip = 1;
                            } else {
                                try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                            }
                            continue;
                        }
                    }
                }

                const c_ic_addr = self.inlined_prop_ic_addrs[idx][c_ip];
                const c_ic_init = self.inlined_prop_ics_init[idx][c_ip];
                const gp_slow_lbl = try a.createLabel();
                const gp_done_lbl = try a.createLabel();

                if (maybe_cr != null and self.findCachedObjPtr(maybe_cr.?, c_ic_init.shape_id, c_ic_init.slot_idx, false) != null) {
                    const ptr_reg = self.findCachedObjPtr(maybe_cr.?, c_ic_init.shape_id, c_ic_init.slot_idx, false).?;
                    try a.testRegReg(ptr_reg, ptr_reg);
                    try a.jcc(.e, gp_slow_lbl);

                    const slot_off: i32 = @intCast(c_ic_init.slot_byte_off);
                    try a.testMem32Imm32(ptr_reg, slot_off + prop_desc_offset, 8);
                    try a.jcc(.ne, gp_slow_lbl);

                    try a.movRegMem(.rax, ptr_reg, slot_off + prop_val_offset);
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, gp_slow_lbl);
                    try a.movqXmmReg(.xmm0, .rax);
                    try a.jmp(gp_done_lbl);
                } else {
                    try a.movRegMem(.rax, .r12, obj_byte_off);
                    try a.movRegReg(.rcx, .rax);
                    try a.shrRegImm8(.rcx, 47);
                    try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
                    try a.jcc(.ne, gp_slow_lbl);

                    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
                    try a.andRegReg(.rax, .rcx);

                    try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
                    try a.jcc(.e, gp_slow_lbl);

                    try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
                    try a.testRegReg(.rcx, .rcx);
                    try a.jcc(.ne, gp_slow_lbl);

                    try a.movRegImm64(.rsi, c_ic_addr);
                    try a.movReg32Mem(.rcx, .rsi, osr_ic_shape_off);
                    try a.movReg32Mem(.rdx, .rax, zobj_shape_id_offset);
                    try a.cmpReg32Reg32(.rdx, .rcx);
                    try a.jcc(.ne, gp_slow_lbl);

                    try a.movReg32Mem(.rcx, .rsi, osr_ic_slot_off);
                    try a.movRegMem(.rdx, .rax, zobj_entries_len_offset);
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ae, gp_slow_lbl);

                    try a.movRegMem(.rdx, .rax, zobj_entries_bytes_offset);
                    try a.movRegMem(.rcx, .rax, zobj_entries_cap_offset);
                    if (comptime value_byte_offset_multiplier == 16) {
                        try a.shlRegImm8(.rcx, 4);
                    } else {
                        try a.imulRegRegImm32(.rcx, .rcx, @intCast(value_byte_offset_multiplier));
                    }
                    try a.addRegReg(.rdx, .rcx);
                    try a.movRegMem(.rcx, .rsi, osr_ic_slot_byte_off);
                    try a.addRegReg(.rdx, .rcx);

                    try a.testMem32Imm32(.rdx, prop_desc_offset, 8);
                    try a.jcc(.ne, gp_slow_lbl);

                    try a.movRegMem(.rax, .rdx, prop_val_offset);
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, gp_slow_lbl);
                    try a.movqXmmReg(.xmm0, .rax);
                    try a.jmp(gp_done_lbl);
                }

                a.bindLabel(gp_slow_lbl);
                if (cached_count > 0) try emitFlushCached(a, cached_regs, cached_count);
                if (promoted.count > 0) try emitFlushPromoted(a, promoted);
                try a.movRegReg(.rdi, .r13);
                try a.movRegMem(.rsi, .r12, obj_byte_off);
                try a.movRegImm64(.rdx, @intFromPtr(key.ptr));
                try a.movRegImm64(.rcx, key.len);
                try a.movRegImm64(.r8, c_ic_addr);
                try a.lea(.r9, .r12, @intCast((caller_regs + c_op.a) * 8));
                try a.movRegImm64(.rax, @intFromPtr(&jitGetPropInlinedOsr));
                try a.callReg(.rax);
                if (cached_count > 0) try emitReloadCached(a, cached_regs, cached_count);
                if (promoted.count > 0) try emitReloadPromoted(a, promoted);
                if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
                if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
                try a.movzxReg64Reg8(.rax, .rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bail_lbl);
                if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
                    try self.loadNumToXmm(self.live_r8_i32.?, .xmm0, bail_lbl);
                    try a.cvttsd2siReg32Xmm(.r8, .xmm0);
                }
                if (self.live_xmm3_reg != null) {
                    try a.movsdXmmMem(.xmm3, .r12, @intCast(@as(usize, self.live_xmm3_reg.?) * 8));
                }
                try a.movsdXmmMem(.xmm0, .r12, @intCast((caller_regs + c_op.a) * 8));

                a.bindLabel(gp_done_lbl);
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .get_elem_const, .get_elem => {
                const maybe_arr_cr = reg_alias[c_op.b];
                if (maybe_arr_cr != null and maybe_arr_cr.? < 64 and reg_to_xmm[maybe_arr_cr.?] != null) {
                    try a.jmp(bail_lbl);
                    continue;
                }
                const arr_byte_off: i32 = if (maybe_arr_cr) |cr|
                    @intCast(@as(usize, cr) * 8)
                else
                    @intCast((caller_regs + c_op.b) * 8);

                if (c_op.opcode == .get_elem_const) {
                    const elem_idx: u32 = @intFromFloat(tb.constants[c_op.c].number);
                    try a.movRegImm32(.rcx, elem_idx);
                } else {
                    try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.c, .xmm0, bail_lbl);
                    try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
                    try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                    try a.ucomisd(.xmm0, .xmm1);
                    try a.jcc(.p, bail_lbl);
                    try a.jcc(.ne, bail_lbl);
                    try a.testReg32Reg32(.rcx, .rcx);
                    try a.jcc(.s, bail_lbl);
                }

                if (maybe_arr_cr != null and hoisted_arrs.find(maybe_arr_cr.?) != null and hoisted_arrs.dense[hoisted_arrs.find(maybe_arr_cr.?).?]) {
                    const h_slot = hoisted_arrs.find(maybe_arr_cr.?).?;
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
                } else {
                    try a.movRegMem(.rax, .r12, arr_byte_off);
                    try a.movRegReg(.rdx, .rax);
                    try a.shrRegImm8(.rdx, 47);
                    try a.cmpRegImm32(.rdx, HEADER_ARRAY);
                    try a.jcc(.ne, bail_lbl);

                    try a.movRegImm64(.rdx, JSValue.PTR_MASK);
                    try a.andRegReg(.rax, .rdx);

                    try a.movRegMem(.rdx, .rax, arr_holey_off);
                    try a.testRegReg(.rdx, .rdx);
                    try a.jcc(.ne, bail_lbl);

                    try a.movRegMem(.rdx, .rax, arr_items_len_off);
                    try a.cmpRegReg(.rcx, .rdx);
                    try a.jcc(.ae, bail_lbl);

                    try a.movRegMem(.rax, .rax, arr_items_ptr_off);
                    try a.movRegMemIndexed8(.rax, .rax, .rcx, 0);
                }

                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, bail_lbl);
                try a.movqXmmReg(.xmm0, .rax);
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .add, .add_num, .sub_num, .mul_num, .div_num => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.c, .xmm1, bail_lbl);
                switch (c_op.opcode) {
                    .add, .add_num => try a.addsd(.xmm0, .xmm1),
                    .sub_num => try a.subsd(.xmm0, .xmm1),
                    .mul_num => try a.mulsd(.xmm0, .xmm1),
                    .div_num => try a.divsd(.xmm0, .xmm1),
                    else => unreachable,
                }
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .mod_num => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.c, .xmm1, bail_lbl);
                try a.movqRegXmm(.rax, .xmm0);
                try a.shrRegImm8(.rax, 63);
                try a.testRegReg(.rax, .rax);
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

                try a.movqRegXmm(.rcx, .xmm1);
                try a.shrRegImm8(.rcx, 63);
                try a.testRegReg(.rcx, .rcx);
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

                try a.xorRegReg64(.rdx, .rdx);
                try a.divReg64(.rcx);
                try a.cvtsi2sdqXmmReg64(.xmm0, .rdx);
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .add_local_const, .sub_local_const => {
                const c_bits = JSValue.fromNumber(tb.constants[c_op.c].number).bits;
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (c_op.opcode == .add_local_const) {
                    try a.addsd(.xmm0, .xmm1);
                } else {
                    try a.subsd(.xmm0, .xmm1);
                }
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .neg => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try a.movqRegXmm(.rax, .xmm0);
                try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
                try a.xorRegReg64(.rax, .rcx);
                try a.movqXmmReg(.xmm0, .rax);
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .not_bits => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
                try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                try a.cmpRegReg(.rax, .rdx);
                try a.jcc(.e, bail_lbl);
                try a.notReg32(.rax);
                try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.c, .xmm1, bail_lbl);
                try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
                try a.movRegImm64(.rdx, 0x8000_0000_0000_0000);
                try a.cmpRegReg(.rax, .rdx);
                try a.jcc(.e, bail_lbl);
                try a.cvttsd2siqReg64Xmm(.rcx, .xmm1);
                try a.cmpRegReg(.rcx, .rdx);
                try a.jcc(.e, bail_lbl);
                switch (c_op.opcode) {
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
                if (next_is_ret_self) {
                    try a.jmp(inlined_done_lbl);
                    c_skip = 1;
                } else {
                    try storeXmmToCallee(a, &reg_alias, caller_regs, c_op.a, .xmm0);
                }
            },
            .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.c, .xmm1, bail_lbl);
                if (c_ip + 1 < tb.ops.len and !callee_is_jump_target[c_ip + 1] and
                    (tb.ops[c_ip + 1].opcode == .jump_if_false or tb.ops[c_ip + 1].opcode == .jump_if_true) and
                    tb.ops[c_ip + 1].a == c_op.a)
                {
                    const jop = tb.ops[c_ip + 1];
                    const t_pc = (@as(usize, jop.b) << 8) | jop.c;
                    const eff_cmp_op: codeblock.Opcode = switch (c_op.opcode) {
                        .loose_eq => .eq,
                        .loose_ne => .ne,
                        else => c_op.opcode,
                    };
                    try emitFusedCmpBranch(a, eff_cmp_op, jop.opcode == .jump_if_true, c_labels[t_pc]);
                    c_skip = 1;
                } else {
                    reg_alias[c_op.a] = null;
                    try emitCmpToBool(a, c_op.opcode);
                    try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
                }
            },
            .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
                const c_bits = JSValue.fromNumber(tb.constants[c_op.c].number).bits;
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.b, .xmm0, bail_lbl);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (c_ip + 1 < tb.ops.len and !callee_is_jump_target[c_ip + 1] and
                    (tb.ops[c_ip + 1].opcode == .jump_if_false or tb.ops[c_ip + 1].opcode == .jump_if_true) and
                    tb.ops[c_ip + 1].a == c_op.a)
                {
                    const jop = tb.ops[c_ip + 1];
                    const t_pc = (@as(usize, jop.b) << 8) | jop.c;
                    try emitFusedCmpBranch(a, c_op.opcode, jop.opcode == .jump_if_true, c_labels[t_pc]);
                    c_skip = 1;
                } else {
                    reg_alias[c_op.a] = null;
                    try emitCmpToBool(a, c_op.opcode);
                    try a.movMemReg(.r12, @intCast((caller_regs + c_op.a) * 8), .rax);
                }
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const c_bits = JSValue.fromNumber(tb.constants[c_op.b].number).bits;
                const t_pc = c_ip + @as(usize, c_op.c);
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.a, .xmm0, bail_lbl);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                try emitFusedCmpBranch(a, switch (c_op.opcode) {
                    .jeq_local_const_false => .eq_local_const,
                    .jlt_local_const_false => .lt_local_const,
                    .jle_local_const_false => .le_local_const,
                    .jgt_local_const_false => .gt_local_const,
                    .jge_local_const_false => .ge_local_const,
                    else => unreachable,
                }, false, c_labels[t_pc]);
            },
            .not => {
                if (reg_alias[c_op.b]) |cr| {
                    if (cr < 64 and reg_to_xmm[cr] != null) return error.CannotCompile;
                    _ = try emitSharedOp(a, tb, .{ .opcode = .not, .a = @intCast(caller_regs + c_op.a), .b = cr }, true, bail_lbl);
                } else {
                    _ = try emitSharedOp(a, tb, .{ .opcode = .not, .a = @intCast(caller_regs + c_op.a), .b = @intCast(caller_regs + c_op.b) }, true, bail_lbl);
                }
                reg_alias[c_op.a] = null;
            },
            .jump_if_false, .jump_if_true => {
                const t_pc = (@as(usize, c_op.b) << 8) | c_op.c;
                const cond_slot: u8 = if (reg_alias[c_op.a]) |cr| blk: {
                    if (cr < 64 and reg_to_xmm[cr] != null) return error.CannotCompile;
                    break :blk cr;
                } else @intCast(caller_regs + c_op.a);
                try emitCondJump(a, c_op.opcode == .jump_if_true, cond_slot, c_labels[t_pc], bail_lbl);
            },
            .jump => {
                const t_pc = (@as(usize, c_op.b) << 8) | c_op.c;
                try a.jmp(c_labels[t_pc]);
            },
            .return_value => {
                try loadCalleeNumToXmm(self, &reg_alias, caller_regs, c_op.a, .xmm0, bail_lbl);
                try a.jmp(inlined_done_lbl);
            },
            .return_undefined => {
                try a.jmp(bail_lbl);
            },
            else => unreachable,
        }
    }

    a.bindLabel(inlined_done_lbl);
    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
    if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) {
        next_live_r8_i32.* = self.live_r8_i32;
    }
}

pub noinline fn emitLoopOp(
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
            self.cached_obj_ptrs = .{ null, null };
            try self.emitGetElem(idx, op, bail_lbl, next_live_r8_i32);
        },
        .set_elem, .set_elem_const, .new_array => {
            self.cached_obj_ptrs = .{ null, null };
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
            if (op.opcode == .new_object or op.opcode == .set_prop_transition) {
                self.cached_obj_ptrs = .{ null, null };
            }
            try self.emitSetObjectProp(ip, op, bail_lbl);
        },
        .get_prop, .load_global => {
            try self.emitGetPropOrGlobal(ip, op, bail_lbl, next_live_r8_i32);
        },
        .call, .call_global => {
            const is_intrinsic = (op.opcode == .call and ((op.c < self.block.call_target_cache.len and isMathIntrinsicCall(&self.block.call_target_cache[op.c])) or self.prepass.char_code_at_str_reg[idx] != null)) or self.prepass.inlined_calls[idx];
            if (!is_intrinsic) {
                self.cached_obj_ptrs = .{ null, null };
            }
            try self.emitCallOp(idx, op, bail_lbl, next_live_r8_i32);
        },
        .throw_value => {
            try self.a.jmp(bail_lbl);
        },
        else => {
            self.cached_obj_ptrs = .{ null, null };
            if (!(try emitSharedOp(self.a, self.block, op, true, bail_lbl))) unreachable;
        },
    }
}

pub noinline fn emitExitsAndEpilogue(self: *OsrCompiler) !void {
    const a = self.a;
    const cached_regs = &self.analysis.cached_regs;
    const cached_count = self.analysis.cached_count;
    const promoted = &self.analysis.promoted;
    const has_preheader_bailout = (self.has_flush or self.analysis.hoisted_arrs.count > 0 or self.math_sqrt_guard_bits != null or self.has_char_code_at_guard);

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
