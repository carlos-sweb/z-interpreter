//! OsrCompiler methods: element access, arithmetic and bitwise emitters.

const std = @import("jit_common.zig").std;
const JSValue = @import("jit_common.zig").JSValue;
const codeblock = @import("jit_common.zig").codeblock;
const vm = @import("jit_common.zig").vm;
const x64_asm = @import("jit_common.zig").x64_asm;
const Label = @import("jit_common.zig").Label;
const HEADER_ARRAY = @import("jit_common.zig").HEADER_ARRAY;
const ArrayBox = @import("jit_common.zig").ArrayBox;
const ZArr = @import("jit_common.zig").ZArr;
const arr_rc_off = @import("jit_common.zig").arr_rc_off;
const arr_val_off = @import("jit_common.zig").arr_val_off;
const arr_holey_off = @import("jit_common.zig").arr_holey_off;
const arr_items_ptr_off = @import("jit_common.zig").arr_items_ptr_off;
const arr_items_len_off = @import("jit_common.zig").arr_items_len_off;
const arr_items_cap_off = @import("jit_common.zig").arr_items_cap_off;
const h_mask_ptr_off = @import("jit_common.zig").h_mask_ptr_off;
const h_mask_len_off = @import("jit_common.zig").h_mask_len_off;
const h_is_holey_off = @import("jit_common.zig").h_is_holey_off;
const emitFlushPromoted = @import("osr_emit.zig").emitFlushPromoted;
const emitReloadPromoted = @import("osr_emit.zig").emitReloadPromoted;
const asExactInt32 = @import("osr_emit.zig").asExactInt32;
const asExactPosUint53 = @import("osr_emit.zig").asExactPosUint53;
const asPowerOfTwoReciprocal = @import("osr_emit.zig").asPowerOfTwoReciprocal;
const emitFlushCached = @import("osr_emit.zig").emitFlushCached;
const emitReloadCached = @import("osr_emit.zig").emitReloadCached;
const emitReleaseHeapIfRefGt1 = @import("osr_emit.zig").emitReleaseHeapIfRefGt1;
const emitStoreBoxedValToUncached = @import("osr_emit.zig").emitStoreBoxedValToUncached;
const emitLoadNumToXmm = @import("osr_emit.zig").emitLoadNumToXmm;
const emitStoreXmmToNum = @import("osr_emit.zig").emitStoreXmmToNum;
const emitRefreshDenseHoisted = @import("osr_emit.zig").emitRefreshDenseHoisted;
const OsrCompiler = @import("osr_emit.zig").OsrCompiler;

pub noinline fn emitGetElem(
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
                if (op.a < 64 and reg_to_xmm[op.a] != null) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bail_lbl);
                    try a.movqXmmReg(reg_to_xmm[op.a].?, .rax);
                } else if (self.prepass.borrowed_str_arg_call[idx]) {
                    try a.movRegReg(.r10, .rax);
                    try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                    try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
                    const callee_regs_off: i32 = @intCast(@as(usize, self.block.register_count) * 8);
                    try a.movMemReg(.r12, callee_regs_off, .r10);
                } else {
                    try emitStoreBoxedValToUncached(a, op.a, bail_lbl);
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
        const keep_prev_r8 = if (self.live_r8_i32) |prev_r8| blk: {
            if (prev_r8 != op.c and prev_r8 != op.a and idx + 1 < self.loop_len and !self.prepass.is_jump_target[idx + 1]) {
                const next_op = self.block.ops[self.start_ip + idx + 1];
                break :blk switch (next_op.opcode) {
                    .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr, .mul_num => (next_op.b == prev_r8 or next_op.c == prev_r8) and (next_op.b != op.c and next_op.c != op.c),
                    else => false,
                };
            }
            break :blk false;
        } else false;

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
            if (!keep_prev_r8) {
                try a.movReg32Reg32(.r8, .rcx);
            }
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

        if (op.a < 64 and reg_to_xmm[op.a] != null) {
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            const xmm_k = reg_to_xmm[op.a].?;
            try a.movqXmmReg(xmm_k, .rax);
        } else if (self.prepass.borrowed_str_arg_call[idx]) {
            try a.movRegReg(.r10, .rax);
            try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
            const callee_regs_off: i32 = @intCast(@as(usize, self.block.register_count) * 8);
            try a.movMemReg(.r12, callee_regs_off, .r10);
        } else {
            try emitStoreBoxedValToUncached(a, op.a, bail_lbl);
        }

        if (op.c < 64 and op.c != op.a) {
            self.reg_is_int32[op.c] = true;
            self.reg_is_uint31[op.c] = true;
            self.reg_is_exact_idx[op.c] = true;
            self.known_dense_valid_idx[h_slot] = op.c;
            next_live_r8_i32.* = if (keep_prev_r8) self.live_r8_i32 else op.c;
        } else if (keep_prev_r8) {
            next_live_r8_i32.* = self.live_r8_i32;
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

    // elem = box.items.ptr[idx]
    try a.movRegMem(.rax, box_reg, arr_items_ptr_off);
    try a.movRegMemIndexed8(.rax, .rax, .rcx, 0);

    if (op.a < 64 and reg_to_xmm[op.a] != null) {
        try a.cmpRegReg(.rax, .r15);
        try a.jcc(.ae, bail_lbl);
        const xmm_k = reg_to_xmm[op.a].?;
        try a.movqXmmReg(xmm_k, .rax);
    } else {
        try emitStoreBoxedValToUncached(a, op.a, bail_lbl);
    }
}

pub noinline fn emitSetElem(
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
        if (self.live_r8_i32 != null and self.live_r8_i32.? == op.b) {
            try a.movReg32Reg32(.rcx, .r8);
        } else {
            try emitLoadNumToXmm(a, reg_to_xmm, op.b, .xmm0, bail_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm0);
        }
        try a.movRegMem(.r11, .rbx, arr_items_ptr_off);
        try a.movRegMemIndexed8(.rdx, .r11, .rcx, 0);
        try a.cmpRegReg(.rdx, .r14);
        try a.jcc(.ae, bail_lbl);
        try a.movMemIndexed8Reg(.r11, .rcx, 0, .r10);
        if (op.b < 64) next_live_r8_i32.* = op.b;
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
pub noinline fn emitFusedIdxDeltaGetElem(
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

pub noinline fn emitArithAndMod(
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
            if (op.opcode == .mul_num and self.prepass.exact_int_mul_at[idx]) {
                const b_i32 = (op.b < 64 and self.reg_is_int32[op.b]);
                const c_i32 = (op.c < 64 and self.reg_is_int32[op.c]);
                if (b_i32 and c_i32) {
                    const lhs_in_r8 = (self.live_r8_i32 != null and self.live_r8_i32.? == op.b);
                    const rhs_in_r8 = (self.live_r8_i32 != null and self.live_r8_i32.? == op.c);
                    if (lhs_in_r8) {
                        try a.movReg32Reg32(.rax, .r8);
                    } else {
                        try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
                        try a.cvttsd2siReg32Xmm(.rax, .xmm0);
                    }
                    if (op.c < 64 and self.known_f64[op.c] != null and asExactInt32(self.known_f64[op.c].?) != null and asExactInt32(self.known_f64[op.c].?).? > 0) {
                        const c_imm = asExactInt32(self.known_f64[op.c].?).?;
                        try a.imulReg32Reg32Imm32(.rax, .rax, c_imm);
                    } else if (rhs_in_r8) {
                        try a.imulReg32Reg32(.rax, .r8);
                    } else {
                        try a.movReg32Reg32(.rcx, .rax);
                        try self.loadNumToXmm(op.c, .xmm1, bail_lbl);
                        try a.movReg32Reg32(.rax, .rcx);
                        try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
                        try a.imulReg32Reg32(.rax, .rcx);
                    }
                    try a.movReg32Reg32(.r8, .rax);
                    if (self.prepass.elided_mul_f64_store[idx]) {
                        if (op.a < 64) next_live_r8_i32.* = op.a;
                        return;
                    }
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
                    if (op.a < 64) next_live_r8_i32.* = op.a;
                    return;
                }
            }
            if (op.a < 64 and reg_to_xmm[op.a] != null and op.a == op.b) {
                const xmm_a = reg_to_xmm[op.a].?;
                try self.loadNumToXmm(op.c, .xmm1, bail_lbl);
                switch (op.opcode) {
                    .add, .add_num => try a.addsd(xmm_a, .xmm1),
                    .sub_num => try a.subsd(xmm_a, .xmm1),
                    .mul_num => try a.mulsd(xmm_a, .xmm1),
                    else => unreachable,
                }
                if (self.live_xmm3_reg != null and self.live_xmm3_reg.? != op.a) self.next_live_xmm3 = self.live_xmm3_reg;
            } else {
                try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
                try self.loadNumToXmm(op.c, .xmm1, bail_lbl);
                switch (op.opcode) {
                    .add, .add_num => try a.addsd(.xmm0, .xmm1),
                    .sub_num => try a.subsd(.xmm0, .xmm1),
                    .mul_num => try a.mulsd(.xmm0, .xmm1),
                    else => unreachable,
                }
                try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
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
                if (self.live_xmm3_reg != null and self.live_xmm3_reg.? != op.a) self.next_live_xmm3 = self.live_xmm3_reg;
            } else {
                try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
                try a.movRegImm64(.rcx, c_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                if (op.opcode == .add_local_const) {
                    try a.addsd(.xmm0, .xmm1);
                } else {
                    try a.subsd(.xmm0, .xmm1);
                }
                try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
            }
            if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
        },
        .div_num => {
            try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
            const maybe_recip: ?u64 = if (op.c < 64 and self.known_f64[op.c] != null)
                asPowerOfTwoReciprocal(self.known_f64[op.c].?)
            else
                null;
            if (maybe_recip) |recip_bits| {
                try a.movRegImm64(.rcx, recip_bits);
                try a.movqXmmReg(.xmm1, .rcx);
                try a.mulsd(.xmm0, .xmm1);
            } else {
                try self.loadNumToXmm(op.c, .xmm1, bail_lbl);
                try a.divsd(.xmm0, .xmm1);
            }
            try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
            if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
        },
        .mod_num => {
            try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
            const maybe_rhs_u53: ?u64 = if (op.c < 64 and self.known_f64[op.c] != null)
                asExactPosUint53(self.known_f64[op.c].?)
            else
                null;
            if (maybe_rhs_u53 == null) {
                try self.loadNumToXmm(op.c, .xmm1, bail_lbl);
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
                    try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
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
            try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
        },
        .neg => {
            try self.loadNumToXmm(op.b, .xmm0, bail_lbl);
            try a.movqRegXmm(.rax, .xmm0);
            try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
            try a.xorRegReg64(.rax, .rcx);
            try a.movqXmmReg(.xmm0, .rax);
            try self.storeXmmToNum(op.a, .xmm0, bail_lbl);
            if (self.live_r8_i32 != null and self.live_r8_i32.? != op.a) next_live_r8_i32.* = self.live_r8_i32;
        },
        else => unreachable,
    }
}

pub noinline fn emitBitwiseOp(
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
        if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
        if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
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
    if (self.cached_obj_ptrs[0] != null) try a.xorReg32Reg32(.r10, .r10);
    if (self.cached_obj_ptrs[1] != null) try a.xorReg32Reg32(.r11, .r11);
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
