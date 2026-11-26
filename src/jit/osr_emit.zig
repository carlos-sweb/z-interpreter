//! OSR code generation: OsrCompiler and shared OSR emit helpers.

const std = @import("jit_common.zig").std;
const Allocator = @import("jit_common.zig").Allocator;
const JSValue = @import("jit_common.zig").JSValue;
const codeblock = @import("jit_common.zig").codeblock;
const vm = @import("jit_common.zig").vm;
const x64_asm = @import("jit_common.zig").x64_asm;
const Assembler = @import("jit_common.zig").Assembler;
const Label = @import("jit_common.zig").Label;
const Xmm = @import("jit_common.zig").Xmm;
const OsrFn = @import("jit_common.zig").OsrFn;
const HEADER_FUNCTION = @import("jit_common.zig").HEADER_FUNCTION;
const HEADER_ARRAY = @import("jit_common.zig").HEADER_ARRAY;
const HEADER_OBJECT = @import("jit_common.zig").HEADER_OBJECT;
const HEADER_STRING = @import("jit_common.zig").HEADER_STRING;
const HEADER_TYPED_ARRAY_BITS = @import("jit_common.zig").HEADER_TYPED_ARRAY_BITS;
const PropIC = @import("jit_common.zig").PropIC;
const value_byte_offset_multiplier = @import("jit_common.zig").value_byte_offset_multiplier;
const zobj_shape_id_offset = @import("jit_common.zig").zobj_shape_id_offset;
const zobj_cached_len_offset = @import("jit_common.zig").zobj_cached_len_offset;
const zobj_is_frozen_offset = @import("jit_common.zig").zobj_is_frozen_offset;
const zobj_entries_bytes_offset = @import("jit_common.zig").zobj_entries_bytes_offset;
const zobj_entries_len_offset = @import("jit_common.zig").zobj_entries_len_offset;
const zobj_entries_cap_offset = @import("jit_common.zig").zobj_entries_cap_offset;
const prop_val_offset = @import("jit_common.zig").prop_val_offset;
const prop_desc_offset = @import("jit_common.zig").prop_desc_offset;
const prop_size = @import("jit_common.zig").prop_size;
const ctx_global_obj_offset = @import("jit_common.zig").ctx_global_obj_offset;
const ArrayBox = @import("jit_common.zig").ArrayBox;
const arr_items_ptr_off = @import("jit_common.zig").arr_items_ptr_off;
const arr_items_len_off = @import("jit_common.zig").arr_items_len_off;
const constantName = @import("jit_common.zig").constantName;
const jitCheckMathIntrinsic = @import("jit_common.zig").jitCheckMathIntrinsic;
const isMathSqrtCall = @import("osr_analysis.zig").isMathSqrtCall;
const isMathImulCall = @import("osr_analysis.zig").isMathImulCall;
const isMathIntrinsicCall = @import("osr_analysis.zig").isMathIntrinsicCall;
const classifyMathIntrinsicCall = @import("osr_analysis.zig").classifyMathIntrinsicCall;
const PromotedPropsAnalysis = @import("osr_analysis.zig").PromotedPropsAnalysis;
const MAX_HOISTED_ARRAYS = @import("osr_analysis.zig").MAX_HOISTED_ARRAYS;
const HoistedElemKind = @import("osr_analysis.zig").HoistedElemKind;
const HoistedArrays = @import("osr_analysis.zig").HoistedArrays;
const OsrPrePass = @import("osr_analysis.zig").OsrPrePass;
const OsrCachedAnalysis = @import("osr_analysis.zig").OsrCachedAnalysis;

pub noinline fn emitFlushPromoted(a: *Assembler, promoted: *const PromotedPropsAnalysis) !void {
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

pub noinline fn emitReloadPromoted(a: *Assembler, promoted: *const PromotedPropsAnalysis) !void {
    for (0..promoted.count) |p| {
        const slot_byte_off: i32 = @intCast(@as(usize, promoted.slots[p]) * @as(usize, @intCast(prop_size)));
        const xmm_p = promoted.xmms[p];
        try a.movsdXmmMem(xmm_p, .rbx, slot_byte_off + prop_val_offset);
    }
}

pub fn asExactInt32(val: f64) ?i32 {
    if (!std.math.isFinite(val)) return null;
    if (val < @as(f64, std.math.minInt(i32)) or val > @as(f64, std.math.maxInt(i32))) return null;
    const i: i32 = @intFromFloat(val);
    if (@as(f64, @floatFromInt(i)) != val) return null;
    if (i == 0 and (@as(u64, @bitCast(val)) >> 63) != 0) return null;
    return i;
}

pub fn asExactPosUint53(val: f64) ?u64 {
    if (!std.math.isFinite(val) or val < 1.0 or val > 9007199254740991.0) return null;
    const u: u64 = @intFromFloat(val);
    if (@as(f64, @floatFromInt(u)) != val) return null;
    return u;
}

pub fn asPowerOfTwoReciprocal(val: f64) ?u64 {
    if (!std.math.isFinite(val) or val == 0.0) return null;
    const bits: u64 = @bitCast(val);
    const mantissa = bits & 0x000F_FFFF_FFFF_FFFF;
    const exp: i32 = @as(i32, @intCast((bits >> 52) & 0x7FF)) - 1023;
    if (mantissa != 0) return null;
    if (exp < -500 or exp > 500) return null;
    const recip: f64 = 1.0 / val;
    return @bitCast(recip);
}

pub noinline fn canElideLoadConst(
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

pub noinline fn emitFlushCached(a: *Assembler, cached_regs: *const [12]u8, cached_count: usize) !void {
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

pub noinline fn emitReloadCached(a: *Assembler, cached_regs: *const [12]u8, cached_count: usize) !void {
    for (0..cached_count) |k| {
        const r = cached_regs[k];
        const xmm_k = @as(Xmm, @enumFromInt(4 + k));
        try a.movsdXmmMem(xmm_k, .r12, @intCast(@as(usize, r) * 8));
    }
}

pub noinline fn emitReleaseHeapIfRefGt1(
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
    try a.cmpRegImm32(.rcx, HEADER_STRING);
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

pub noinline fn emitStoreBoxedValToUncached(
    a: *Assembler,
    dst_reg: u8,
    bail_lbl: Label,
) !void {
    const heap_val_lbl = try a.createLabel();
    const retain_val_lbl = try a.createLabel();
    const done_val_lbl = try a.createLabel();

    try a.movRegReg(.r10, .rax);
    try a.cmpRegReg(.r10, .r14); // %r14 = HEAP_BASE
    try a.jcc(.ae, heap_val_lbl);

    try emitReleaseHeapIfRefGt1(a, dst_reg, bail_lbl);
    try a.movMemReg(.r12, @intCast(@as(usize, dst_reg) * 8), .r10);
    try a.jmp(done_val_lbl);

    a.bindLabel(heap_val_lbl);
    try a.movRegReg(.rcx, .r10);
    try a.shrRegImm8(.rcx, 47);
    try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
    try a.jcc(.e, retain_val_lbl);
    try a.cmpRegImm32(.rcx, HEADER_ARRAY);
    try a.jcc(.e, retain_val_lbl);
    try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
    try a.jcc(.e, retain_val_lbl);
    try a.cmpRegImm32(.rcx, HEADER_STRING);
    try a.jcc(.e, retain_val_lbl);
    try a.movRegReg(.rdx, .r10);
    try a.movRegImm64(.rcx, JSValue.TAG15_MASK);
    try a.andRegReg(.rdx, .rcx);
    try a.movRegImm64(.rcx, HEADER_TYPED_ARRAY_BITS);
    try a.cmpRegReg(.rdx, .rcx);
    try a.jcc(.ne, bail_lbl);

    a.bindLabel(retain_val_lbl);
    try emitReleaseHeapIfRefGt1(a, dst_reg, bail_lbl);
    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
    try a.andRegReg(.rcx, .r10);
    try a.incMem64(.rcx, 0);
    try a.movMemReg(.r12, @intCast(@as(usize, dst_reg) * 8), .r10);

    a.bindLabel(done_val_lbl);
}

pub noinline fn emitStoreSlotValOrSlow(
    a: *Assembler,
    slot_base: x64_asm.Reg,
    slot_disp: i32,
    new_val_reg: x64_asm.Reg,
    slow_lbl: Label,
) !void {
    const old_is_rc_lbl = try a.createLabel();
    const old_ok_lbl = try a.createLabel();
    const new_is_rc_lbl = try a.createLabel();
    const new_ok_lbl = try a.createLabel();
    const write_slot_lbl = try a.createLabel();
    const done_lbl = try a.createLabel();

    if (new_val_reg != .rsi) {
        try a.movRegReg(.rsi, new_val_reg);
    }
    try a.movRegMem(.rax, slot_base, slot_disp);
    try a.cmpRegReg(.rsi, .rax);
    try a.jcc(.e, done_lbl);

    try a.xorReg32Reg32(.rdi, .rdi);
    try a.cmpRegReg(.rax, .r14); // %r14 = HEAP_BASE
    try a.jcc(.b, old_ok_lbl);

    try a.movRegReg(.rcx, .rax);
    try a.shrRegImm8(.rcx, 47);
    try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
    try a.jcc(.e, old_is_rc_lbl);
    try a.cmpRegImm32(.rcx, HEADER_ARRAY);
    try a.jcc(.e, old_is_rc_lbl);
    try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
    try a.jcc(.e, old_is_rc_lbl);
    try a.cmpRegImm32(.rcx, HEADER_STRING);
    try a.jcc(.e, old_is_rc_lbl);
    try a.movRegImm64(.rcx, JSValue.TAG15_MASK);
    try a.andRegReg(.rcx, .rax);
    try a.movRegImm64(.rdi, HEADER_TYPED_ARRAY_BITS);
    try a.cmpRegReg(.rcx, .rdi);
    try a.jcc(.ne, slow_lbl);

    a.bindLabel(old_is_rc_lbl);
    try a.movRegImm64(.rdi, JSValue.PTR_MASK);
    try a.andRegReg(.rdi, .rax);
    try a.movRegMem(.rcx, .rdi, 0);
    try a.cmpRegImm32(.rcx, 1);
    try a.jcc(.be, slow_lbl);

    a.bindLabel(old_ok_lbl);
    try a.cmpRegReg(.rsi, .r14); // %r14 = HEAP_BASE
    try a.jcc(.b, new_ok_lbl);

    try a.movRegReg(.rcx, .rsi);
    try a.shrRegImm8(.rcx, 47);
    try a.cmpRegImm32(.rcx, @intCast(HEADER_OBJECT));
    try a.jcc(.e, new_is_rc_lbl);
    try a.cmpRegImm32(.rcx, HEADER_ARRAY);
    try a.jcc(.e, new_is_rc_lbl);
    try a.cmpRegImm32(.rcx, HEADER_FUNCTION);
    try a.jcc(.e, new_is_rc_lbl);
    try a.cmpRegImm32(.rcx, HEADER_STRING);
    try a.jcc(.e, new_is_rc_lbl);
    try a.movRegImm64(.rcx, JSValue.TAG15_MASK);
    try a.andRegReg(.rcx, .rsi);
    try a.movRegImm64(.rax, HEADER_TYPED_ARRAY_BITS);
    try a.cmpRegReg(.rcx, .rax);
    try a.jcc(.ne, slow_lbl);

    a.bindLabel(new_is_rc_lbl);
    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
    try a.andRegReg(.rcx, .rsi);
    try a.incMem64(.rcx, 0);

    a.bindLabel(new_ok_lbl);
    try a.testRegReg(.rdi, .rdi);
    try a.jcc(.e, write_slot_lbl);
    try a.movRegMem(.rcx, .rdi, 0);
    try a.decReg64(.rcx);
    try a.movMemReg(.rdi, 0, .rcx);

    a.bindLabel(write_slot_lbl);
    try a.movMemReg(slot_base, slot_disp, .rsi);

    a.bindLabel(done_lbl);
}

pub fn isNextOpNumericConsumer(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    ip: usize,
    end_ip: usize,
    is_jump_target: []const bool,
    reg_to_xmm: *const [64]?Xmm,
    reg: u8,
) bool {
    if (reg < block.local_count or reg >= 64 or ip >= end_ip) return false;
    const max_lookahead: usize = @min(end_ip - ip, 4);
    var step: usize = 1;
    while (step <= max_lookahead) : (step += 1) {
        const scan_ip = ip + step;
        const scan_idx = scan_ip - start_ip;
        if (is_jump_target[scan_idx]) return false;
        const scan_op = block.ops[scan_ip];
        switch (scan_op.opcode) {
            .add, .add_num, .sub_num, .mul_num, .div_num, .mod_num, .lt_num, .gt_num, .le_num, .ge_num => {
                if (scan_op.b == reg or scan_op.c == reg) return true;
                if (scan_op.a == reg or scan_op.a >= 64 or reg_to_xmm[scan_op.a] == null) return false;
            },
            .neg, .add_local_const, .sub_local_const, .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const => {
                if (scan_op.b == reg) return true;
                if (scan_op.a == reg or scan_op.a >= 64 or reg_to_xmm[scan_op.a] == null) return false;
            },
            .get_prop, .load_const, .load_global => {
                if (scan_op.a == reg or scan_op.a >= 64 or reg_to_xmm[scan_op.a] == null) return false;
            },
            else => return false,
        }
    }
    return false;
}

pub noinline fn emitLoadNumToXmm(
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

pub noinline fn emitStoreXmmToNum(
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

pub noinline fn emitFusedCmpBranch(
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

pub noinline fn emitRefreshDenseHoisted(
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

pub const OsrCompiler = struct {
    pub const ElidedConst = struct { reg: u8, bits: u64 };
    pub const ExitStub = struct { label: Label, target_ip: u32 };
    pub const ElemStorePair = struct { idx_reg: u8, val_reg: u8 };
    pub const CachedObjPropPtr = struct {
        obj_reg: u8,
        shape_id: u32,
        max_slot: u32,
        unfrozen: bool,
    };

    allocator: Allocator,
    a: *Assembler,
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    loop_len: usize,
    prop_ic: ?*const [256]PropIC,
    prop_ic_addrs: []const u64,
    prop_ics_init: []const codeblock.OsrPropIC,
    global_slot_addrs: []const u64,
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
    has_char_code_at_guard: bool = false,
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
    live_xmm3_reg: ?u8 = null,
    next_live_xmm3: ?u8 = null,
    cached_obj_ptrs: [2]?CachedObjPropPtr = .{ null, null },
    incoming_elem_store: []?ElemStorePair,
    skip_ops_remaining: u8 = 0,

    pub noinline fn findCachedObjPtr(
        self: *const OsrCompiler,
        eff_obj: u8,
        shape_id: u32,
        slot_idx: u32,
        need_unfrozen: bool,
    ) ?x64_asm.Reg {
        if (shape_id == 0 or (shape_id & 0x8000_0000) != 0) return null;
        for (self.cached_obj_ptrs, 0..) |maybe_c, s_idx| {
            if (maybe_c) |c| {
                if (c.obj_reg == eff_obj and c.shape_id == shape_id and slot_idx <= c.max_slot and (!need_unfrozen or c.unfrozen)) {
                    return if (s_idx == 0) .r10 else .r11;
                }
            }
        }
        return null;
    }

    pub noinline fn trySetupCachedObjPtr(
        self: *OsrCompiler,
        idx: usize,
        eff_obj: u8,
        shape_id: u32,
        slot_idx: u32,
        is_write: bool,
    ) ?struct { reg: x64_asm.Reg, max_slot: u32, any_written: bool } {
        if (shape_id == 0 or (shape_id & 0x8000_0000) != 0) return null;
        for (self.cached_obj_ptrs) |maybe_c| {
            if (maybe_c) |c| {
                if (c.obj_reg == eff_obj) return null;
            }
        }
        const free_slot: usize = if (self.cached_obj_ptrs[0] == null)
            0
        else if (self.cached_obj_ptrs[1] == null)
            1
        else
            return null;

        var same_hits: usize = 0;
        var max_slot: u32 = slot_idx;
        var any_written: bool = is_write;
        var scan_copy_src = self.cur_copy_src;

        var k = idx + 1;
        while (k < self.loop_len) : (k += 1) {
            if (self.prepass.is_jump_target[k]) break;
            if (self.elided_op[k]) continue;
            const ck = self.block.ops[self.start_ip + k];
            switch (ck.opcode) {
                .get_prop => {
                    const k_obj = self.prepass.compound_arr_override[k] orelse (if (ck.b < 64) (scan_copy_src[ck.b] orelse ck.b) else ck.b);
                    if (k_obj == eff_obj) {
                        const k_ic = self.prop_ics_init[k];
                        if (k_ic.shape_id == shape_id and k_ic.next_shape == 0) {
                            same_hits += 1;
                            if (k_ic.slot_idx > max_slot) max_slot = k_ic.slot_idx;
                        } else {
                            break;
                        }
                    }
                    if (ck.a == eff_obj) break;
                    if (ck.a < 64) {
                        scan_copy_src[ck.a] = null;
                        for (0..64) |m| {
                            if (scan_copy_src[m] == ck.a) scan_copy_src[m] = null;
                        }
                    }
                },
                .set_prop => {
                    const k_obj = self.prepass.compound_arr_override[k] orelse (if (ck.a < 64) (scan_copy_src[ck.a] orelse ck.a) else ck.a);
                    const k_ic = self.prop_ics_init[k];
                    if (k_ic.shape_id == 0 or (k_ic.shape_id & 0x8000_0000) != 0 or k_ic.next_shape != 0) break;
                    if (k_obj == eff_obj) {
                        if (k_ic.shape_id == shape_id) {
                            same_hits += 1;
                            any_written = true;
                            if (k_ic.slot_idx > max_slot) max_slot = k_ic.slot_idx;
                        } else {
                            break;
                        }
                    }
                },
                .move, .load_local, .store_local => {
                    if (ck.a == eff_obj) break;
                    const res_src: ?u8 = if (ck.b < 64) (scan_copy_src[ck.b] orelse ck.b) else null;
                    if (ck.a < 64) {
                        for (0..64) |m| {
                            if (scan_copy_src[m] == ck.a) scan_copy_src[m] = null;
                        }
                        scan_copy_src[ck.a] = if (res_src != null and res_src.? != ck.a) res_src else null;
                    }
                },
                .nop, .to_prop_key => {
                    if (ck.a == eff_obj) break;
                },
                .load_const,
                .load_undefined,
                .add,
                .add_num,
                .sub_num,
                .mul_num,
                .div_num,
                .mod_num,
                .neg,
                .add_local_const,
                .sub_local_const,
                .not_bits,
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
                .lt_local_const,
                .gt_local_const,
                .le_local_const,
                .ge_local_const,
                .eq_local_const,
                => {
                    if (ck.a == eff_obj) break;
                    if (ck.a < 64) {
                        scan_copy_src[ck.a] = null;
                        for (0..64) |m| {
                            if (scan_copy_src[m] == ck.a) scan_copy_src[m] = null;
                        }
                    }
                },
                .call => {
                    if ((ck.c < self.block.call_target_cache.len and isMathIntrinsicCall(&self.block.call_target_cache[ck.c])) or self.prepass.char_code_at_str_reg[k] != null) {
                        if (ck.a == eff_obj) break;
                        if (ck.a < 64) {
                            scan_copy_src[ck.a] = null;
                            for (0..64) |m| {
                                if (scan_copy_src[m] == ck.a) scan_copy_src[m] = null;
                            }
                        }
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }

        if (same_hits == 0) return null;
        self.cached_obj_ptrs[free_slot] = .{
            .obj_reg = eff_obj,
            .shape_id = shape_id,
            .max_slot = max_slot,
            .unfrozen = any_written,
        };
        return .{
            .reg = if (free_slot == 0) .r10 else .r11,
            .max_slot = max_slot,
            .any_written = any_written,
        };
    }

    pub noinline fn loadNumToXmm(self: *OsrCompiler, r: u8, target_xmm: Xmm, bail_lbl: Label) !void {
        if (self.live_xmm3_reg != null and self.live_xmm3_reg.? == r) {
            if (target_xmm != .xmm3) {
                try self.a.movsdXmmXmm(target_xmm, .xmm3);
            }
            return;
        }
        try emitLoadNumToXmm(self.a, &self.analysis.reg_to_xmm, r, target_xmm, bail_lbl);
    }

    pub noinline fn storeXmmToNum(self: *OsrCompiler, r: u8, src_xmm: Xmm, bail_lbl: Label) !void {
        try emitStoreXmmToNum(self.a, &self.analysis.reg_to_xmm, r, src_xmm, bail_lbl);
        if (r < 64 and self.analysis.reg_to_xmm[r] == null) {
            if (src_xmm != .xmm3) {
                try self.a.movsdXmmXmm(.xmm3, src_xmm);
            }
            self.next_live_xmm3 = r;
        } else if (self.live_xmm3_reg != null and self.live_xmm3_reg.? != r) {
            self.next_live_xmm3 = self.live_xmm3_reg;
        }
    }

    pub noinline fn emitPreheader(self: *OsrCompiler) !void {
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

        for (0..self.prepass.math_guard_count) |g_idx| {
            const g = self.prepass.math_guards[g_idx];
            if (std.mem.eql(u8, g.prop_name, "sqrt")) {
                try a.movRegReg(.rdi, .r13);
                try a.movRegImm64(.rsi, g.expected_bits);
                try a.movRegImm64(.rax, @intFromPtr(&vm.jitCheckMathSqrt));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, preheader_bailout);
            } else {
                try a.movRegReg(.rdi, .r13);
                try a.movRegImm64(.rsi, @intFromPtr(g.prop_name.ptr));
                try a.movRegImm64(.rdx, g.prop_name.len);
                try a.movRegImm64(.rcx, g.expected_bits);
                try a.movRegImm64(.rax, @intFromPtr(&jitCheckMathIntrinsic));
                try a.callReg(.rax);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, preheader_bailout);
            }
        }

        if (self.has_char_code_at_guard) {
            try a.movRegReg(.rdi, .r13);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitCheckStringCharCodeAt));
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

            try a.cmpRegMem(.rax, .r13, ctx_global_obj_offset);
            try a.jcc(.e, preheader_bailout);

            try a.movzxReg64Mem16(.rcx, .rax, zobj_cached_len_offset);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.ne, preheader_bailout);

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
                if (!self.analysis.read_before_written[r]) continue;
                const xmm_k = @as(Xmm, @enumFromInt(4 + k));
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, r) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, preheader_bailout);
                try a.movqXmmReg(xmm_k, .rax);
            }
            for (0..cached_count) |k| {
                const r = cached_regs[k];
                if (self.analysis.read_before_written[r]) continue;
                const xmm_k = @as(Xmm, @enumFromInt(4 + k));
                const skip_lbl = try a.createLabel();
                const done_lbl = try a.createLabel();
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, r) * 8));
                try a.cmpRegReg(.rax, .r15);
                try a.jcc(.ae, skip_lbl);
                try a.movqXmmReg(xmm_k, .rax);
                try a.jmp(done_lbl);
                a.bindLabel(skip_lbl);
                try emitReleaseHeapIfRefGt1(a, r, preheader_bailout);
                try a.movMemReg(.r12, @intCast(@as(usize, r) * 8), .r15);
                try a.xorpd(xmm_k, xmm_k);
                a.bindLabel(done_lbl);
            }
            for (0..cached_count) |k| {
                const r = cached_regs[k];
                if (r < 64 and (self.prepass.loop_safe_i32_mask & (@as(u64, 1) << @intCast(r))) != 0) {
                    const xmm_k = @as(Xmm, @enumFromInt(4 + k));
                    try a.cvttsd2siReg32Xmm(.rcx, xmm_k);
                    try a.cvtsi2sdXmmReg32(.xmm1, .rcx);
                    try a.ucomisd(xmm_k, .xmm1);
                    try a.jcc(.p, preheader_bailout);
                    try a.jcc(.ne, preheader_bailout);
                    if ((self.prepass.loop_safe_u31_mask & (@as(u64, 1) << @intCast(r))) != 0) {
                        try a.testReg32Reg32(.rcx, .rcx);
                        try a.jcc(.s, preheader_bailout);
                    }
                }
            }
        }
    }

    pub noinline fn mergeIncomingState(self: *OsrCompiler, idx: usize) void {
        if (self.prepass.is_jump_target[idx]) {
            self.known_f64 = @splat(null);
            self.known_valid_elem_idx = null;
            self.known_dense_valid_idx = @splat(null);
            self.cur_copy_src = @splat(null);
            self.live_r8_i32 = null;
            self.live_xmm3_reg = null;
            self.cached_obj_ptrs = .{ null, null };
        }
        if (self.prepass.is_back_target[idx]) {
            for (0..64) |r_i| {
                const r_bit = @as(u64, 1) << @intCast(r_i);
                const is_cached = (self.analysis.reg_to_xmm[r_i] != null);
                const safe_i32 = is_cached and ((self.prepass.loop_safe_i32_mask & r_bit) != 0);
                const safe_u31 = safe_i32 and ((self.prepass.loop_safe_u31_mask & r_bit) != 0);
                self.reg_is_int32[r_i] = safe_i32;
                self.reg_is_uint31[r_i] = safe_u31;
                self.reg_is_exact_idx[r_i] = safe_i32;
            }
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

    pub noinline fn recordForwardEdge(self: *OsrCompiler, ip: usize, t: usize) void {
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

    pub noinline fn invalidateKilledReg(self: *OsrCompiler, reg: u8) void {
        if (self.last_elem_store) |les| {
            if (reg == les.idx_reg or reg == les.val_reg) self.last_elem_store = null;
        }
        if (self.known_valid_elem_idx) |kvi| {
            if (reg == kvi) self.known_valid_elem_idx = null;
        }
        for (&self.known_dense_valid_idx) |*kd| {
            if (kd.* == reg) kd.* = null;
        }
        for (&self.cached_obj_ptrs) |*cop| {
            if (cop.*) |c| {
                if (c.obj_reg == reg) cop.* = null;
            }
        }
        if (reg < 64) {
            self.cur_copy_src[reg] = null;
            for (0..64) |m| {
                if (self.cur_copy_src[m] == reg) self.cur_copy_src[m] = null;
            }
        }
    }

    pub noinline fn updateTrackingAfterOp(self: *OsrCompiler, idx: usize, ip: usize, op: codeblock.Op, next_live_r8_i32: ?u8) void {
        const block = self.block;
        const hoisted_arrs = &self.analysis.hoisted_arrs;

        self.live_r8_i32 = next_live_r8_i32;
        self.live_xmm3_reg = self.next_live_xmm3;
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
                    const a_bit = @as(u64, 1) << @intCast(op.a);
                    const safe_i32 = (self.analysis.reg_to_xmm[op.a] != null) and ((self.prepass.loop_safe_i32_mask & a_bit) != 0);
                    const safe_u31 = safe_i32 and ((self.prepass.loop_safe_u31_mask & a_bit) != 0);
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = safe_i32;
                    self.reg_is_uint31[op.a] = safe_u31;
                    self.reg_is_exact_idx[op.a] = (base_i32 and small_c) or safe_i32;
                }
            },
            .add, .add_num, .sub_num, .mul_num => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const is_exact_mul = (op.opcode == .mul_num and self.prepass.exact_int_mul_at[idx] and next_live_r8_i32 == op.a);
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = is_exact_mul;
                    self.reg_is_uint31[op.a] = false;
                    self.reg_is_exact_idx[op.a] = is_exact_mul;
                }
            },
            .call => {
                self.invalidateKilledReg(op.a);
                if (op.a < 64) {
                    const mk_opt = if (op.c < block.call_target_cache.len) classifyMathIntrinsicCall(&block.call_target_cache[op.c]) else null;
                    const arg0_r: u8 = op.b + 1;
                    const arg1_r: u8 = op.b + 2;
                    const a0_i32 = (arg0_r < 64 and self.reg_is_int32[arg0_r]);
                    const a0_u31 = (arg0_r < 64 and self.reg_is_uint31[arg0_r]);
                    const a1_i32 = (arg1_r < 64 and self.reg_is_int32[arg1_r]);
                    const a1_u31 = (arg1_r < 64 and self.reg_is_uint31[arg1_r]);
                    const res_i32 = if (mk_opt) |mk| switch (mk) {
                        .imul => true,
                        .abs => a0_u31,
                        .floor, .ceil, .trunc => a0_i32,
                        .min2, .max2 => a0_i32 and a1_i32,
                        .sqrt => false,
                    } else false;
                    const res_u31 = if (mk_opt) |mk| switch (mk) {
                        .abs, .floor, .ceil, .trunc => a0_u31,
                        .min2, .max2 => a0_u31 and a1_u31,
                        .imul, .sqrt => false,
                    } else false;
                    self.known_f64[op.a] = null;
                    self.reg_is_int32[op.a] = res_i32;
                    self.reg_is_uint31[op.a] = res_u31;
                    self.reg_is_exact_idx[op.a] = res_i32;
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
                for (&self.cached_obj_ptrs) |*cop| {
                    if (cop.*) |c| {
                        if (c.obj_reg == op.a) cop.* = null;
                    }
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

    pub noinline fn resolveJumpTarget(self: *OsrCompiler, target_pc: usize) !Label {
        if (target_pc >= self.start_ip and target_pc <= self.end_ip) {
            return self.op_labels[target_pc - self.start_ip];
        }
        const el = try self.a.createLabel();
        try self.exit_stubs.append(self.allocator, .{ .label = el, .target_ip = @intCast(target_pc) });
        return el;
    }

    pub noinline fn emitMoveOrConst(
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
                    } else if (self.prepass.borrowed_str_arg_call[idx]) {
                        try emitReleaseHeapIfRefGt1(a, op.a, bail_lbl);
                        try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .r15);
                        try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
                        const callee_regs_off: i32 = @intCast(@as(usize, self.block.register_count) * 8);
                        try a.movMemReg(.r12, callee_regs_off, .rax);
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
                        try a.cmpRegImm32(.rcx, HEADER_STRING);
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

    pub noinline fn emitTypedArrayLoadAtRcx(
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

    pub noinline fn emitTypedArrayGetElem(
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

    pub noinline fn emitTypedArraySetElem(
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


    pub const emitGetElem = @import("osr_emit_elem.zig").emitGetElem;
    pub const emitSetElem = @import("osr_emit_elem.zig").emitSetElem;
    pub const emitFusedIdxDeltaGetElem = @import("osr_emit_elem.zig").emitFusedIdxDeltaGetElem;
    pub const emitArithAndMod = @import("osr_emit_elem.zig").emitArithAndMod;
    pub const emitBitwiseOp = @import("osr_emit_elem.zig").emitBitwiseOp;
    pub const emitComparisonOrBranch = @import("osr_emit_ops.zig").emitComparisonOrBranch;
    pub const emitSetObjectProp = @import("osr_emit_ops.zig").emitSetObjectProp;
    pub const emitGetPropOrGlobal = @import("osr_emit_ops.zig").emitGetPropOrGlobal;
    pub const emitOsrStringCharCodeAt = @import("osr_emit_ops.zig").emitOsrStringCharCodeAt;
    pub const emitCallOp = @import("osr_emit_ops.zig").emitCallOp;
    pub const emitLoopOp = @import("osr_emit_ops.zig").emitLoopOp;
    pub const emitExitsAndEpilogue = @import("osr_emit_ops.zig").emitExitsAndEpilogue;
};
