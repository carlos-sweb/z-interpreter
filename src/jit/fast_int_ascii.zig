//! FastIntAscii tier (int32 + ASCII string ops) for whole-function JIT.

const Allocator = @import("jit_common.zig").Allocator;
const JSValue = @import("jit_common.zig").JSValue;
const codeblock = @import("jit_common.zig").codeblock;
const vm = @import("jit_common.zig").vm;
const x64_asm = @import("jit_common.zig").x64_asm;
const Assembler = @import("jit_common.zig").Assembler;
const Label = @import("jit_common.zig").Label;
const HEADER_STRING = @import("jit_common.zig").HEADER_STRING;
const str_data_ptr_off = @import("jit_common.zig").str_data_ptr_off;
const str_data_len_off = @import("jit_common.zig").str_data_len_off;
const zobj_shape_id_offset = @import("jit_common.zig").zobj_shape_id_offset;
const zobj_cached_len_offset = @import("jit_common.zig").zobj_cached_len_offset;
const zobj_entries_bytes_offset = @import("jit_common.zig").zobj_entries_bytes_offset;
const prop_val_offset = @import("jit_common.zig").prop_val_offset;
const prop_desc_offset = @import("jit_common.zig").prop_desc_offset;
const MAX_WHOLE_FN_STRING_OPS = @import("whole_fn.zig").MAX_WHOLE_FN_STRING_OPS;
const WholeFnStringAnalysis = @import("whole_fn.zig").WholeFnStringAnalysis;
const opUseDefMasks = @import("osr_analysis.zig").opUseDefMasks;
const computeBlockLiveOut = @import("osr_analysis.zig").computeBlockLiveOut;
const asExactInt32 = @import("osr_emit.zig").asExactInt32;

pub const fast_int_gprs = [10]x64_asm.Reg{
    .rcx, .rdi, .r10, .r11, .rbx, .rbp, .r12, .r13, .r14, .r15,
};

pub noinline fn canCompileFastIntAscii(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    str_analysis: *const WholeFnStringAnalysis,
) bool {
    if (block.param_count != 1 or str_analysis.param_mask != 1) return false;
    if (block.register_count < 2 or block.register_count > 11) return false;
    if (block.local_count > block.register_count) return false;
    if (block.ops.len == 0 or block.ops.len > MAX_WHOLE_FN_STRING_OPS) return false;

    for (block.ops, 0..) |op, ip| {
        if (str_analysis.elided[ip]) continue;
        switch (op.opcode) {
            .nop, .return_undefined => {},
            .load_const => {
                if (op.a == 0 or op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
                if (asExactInt32(block.constants[op.b].number) == null) return false;
            },
            .get_prop => {
                if (op.a == 0 or op.a >= block.register_count) return false;
                if (str_analysis.get_prop_len_str[ip] == null or str_analysis.get_prop_len_str[ip].? != 0) return false;
            },
            .call => {
                if (op.a == 0 or op.a >= block.register_count) return false;
                if (str_analysis.char_code_at_str[ip] == null or str_analysis.char_code_at_str[ip].? != 0) return false;
                const arg_r = @as(usize, op.b) + 1;
                if (arg_r == 0 or arg_r >= block.register_count) return false;
            },
            .move, .load_local, .store_local => {
                if (op.a == 0 or op.b == 0 or op.a >= block.register_count or op.b >= block.register_count) return false;
            },
            .add, .add_num, .sub_num, .mul_num, .mod_num => {
                if (op.a == 0 or op.b == 0 or op.c == 0) return false;
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
            },
            .add_local_const, .sub_local_const => {
                if (op.a == 0 or op.b == 0 or op.a >= block.register_count or op.b >= block.register_count) return false;
                if (op.c >= block.constants.len or block.constants[op.c] != .number) return false;
                if (asExactInt32(block.constants[op.c].number) == null) return false;
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                if (op.a == 0 or op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
                if (asExactInt32(block.constants[op.b].number) == null) return false;
                if (ip + @as(usize, op.c) >= block.ops.len) return false;
            },
            .jump => {
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
            },
            .return_value => {
                if (op.a == 0 or op.a >= block.register_count) return false;
            },
            else => return false,
        }
    }

    const live_out = computeBlockLiveOut(allocator, block) catch return false;
    defer allocator.free(live_out);
    const ud0 = opUseDefMasks(block, block.ops[0]);
    const live_in_0 = ud0.use | (live_out[0] & ~ud0.def);
    var init_allowed_mask: u64 = 1;
    var scan_ip: usize = 0;
    while (scan_ip < block.ops.len) : (scan_ip += 1) {
        if (str_analysis.elided[scan_ip]) continue;
        const sop = block.ops[scan_ip];
        switch (sop.opcode) {
            .nop => {},
            .load_const => {
                if (sop.a < 64) init_allowed_mask |= (@as(u64, 1) << @intCast(sop.a));
            },
            .get_prop => {
                if (sop.a < 64) init_allowed_mask |= (@as(u64, 1) << @intCast(sop.a));
            },
            .move, .load_local, .store_local => {
                if (sop.b < 64 and (init_allowed_mask & (@as(u64, 1) << @intCast(sop.b))) != 0) {
                    if (sop.a < 64) init_allowed_mask |= (@as(u64, 1) << @intCast(sop.a));
                } else break;
            },
            .add_local_const, .sub_local_const => {
                if (sop.b < 64 and (init_allowed_mask & (@as(u64, 1) << @intCast(sop.b))) != 0) {
                    if (sop.a < 64) init_allowed_mask |= (@as(u64, 1) << @intCast(sop.a));
                } else break;
            },
            else => break,
        }
    }
    if ((live_in_0 & ~init_allowed_mask) != 0) return false;

    return true;
}

pub noinline fn emitInlineCharCodeAtGuard(
    a: *Assembler,
    guard: *const vm.StringCharCodeAtGuard,
    slow_lbl: Label,
) !void {
    try a.movRegImm64(.rax, guard.sproto_box_addr);
    try a.movReg32Mem(.r10, .rax, zobj_shape_id_offset);
    try a.cmpReg32Imm32(.r10, @bitCast(guard.expected_shape_id));
    try a.jcc(.ne, slow_lbl);

    try a.movzxReg64Mem16(.r10, .rax, zobj_cached_len_offset);
    try a.testRegReg(.r10, .r10);
    try a.jcc(.ne, slow_lbl);

    try a.movRegMem(.r10, .rax, zobj_entries_bytes_offset);
    try a.movRegImm64(.r11, guard.expected_bytes_addr);
    try a.cmpRegReg(.r10, .r11);
    try a.jcc(.ne, slow_lbl);

    try a.movRegImm64(.rax, guard.rec_addr);
    try a.testMem32Imm32(.rax, prop_desc_offset, 8);
    try a.jcc(.ne, slow_lbl);

    try a.movRegMem(.r10, .rax, prop_val_offset);
    try a.movRegImm64(.r11, guard.expected_val_bits);
    try a.cmpRegReg(.r10, .r11);
    try a.jcc(.ne, slow_lbl);
}

pub noinline fn emitFastIntAsciiTier(
    allocator: Allocator,
    a: *Assembler,
    block: *const codeblock.CodeBlock,
    str_analysis: *const WholeFnStringAnalysis,
    guard_opt: ?vm.StringCharCodeAtGuard,
    general_entry_lbl: Label,
) !void {
    var fast_op_labels = try allocator.alloc(Label, block.ops.len);
    defer allocator.free(fast_op_labels);
    for (0..block.ops.len) |i| {
        fast_op_labels[i] = try a.createLabel();
    }

    const fast_bailout = try a.createLabel();
    const ascii_check_general = try a.createLabel();
    const ascii_byte_loop = try a.createLabel();
    const ascii_ok = try a.createLabel();
    const restore_and_general_entry = try a.createLabel();

    const frame_bytes: i32 = @intCast(@as(usize, block.register_count) * 8);
    try a.lea(.rax, .rdi, frame_bytes);
    try a.cmpRegReg(.rax, .rdx);
    try a.jcc(.a, fast_bailout);

    if (str_analysis.has_char_code_at) {
        if (guard_opt) |g| {
            try emitInlineCharCodeAtGuard(a, &g, general_entry_lbl);
        } else {
            try a.jmp(general_entry_lbl);
        }
    }

    try a.movRegMem(.rax, .rdi, 0);
    try a.movRegReg(.r10, .rax);
    try a.shrRegImm8(.r10, 47);
    try a.cmpRegImm32(.r10, HEADER_STRING);
    try a.jcc(.ne, fast_bailout);

    try a.movRegImm64(.r10, JSValue.PTR_MASK);
    try a.andRegReg(.rax, .r10);
    try a.movRegMem(.r8, .rax, str_data_ptr_off);
    try a.movRegMem(.r9, .rax, str_data_len_off);
    try a.cmpRegImm32(.r9, 64);
    try a.jcc(.a, general_entry_lbl);

    try a.cmpRegImm32(.r9, 8);
    try a.jcc(.ne, ascii_check_general);
    try a.movRegMem(.rax, .r8, 0);
    try a.movRegImm64(.r11, 0x8080_8080_8080_8080);
    try a.testRegReg(.rax, .r11);
    try a.jcc(.ne, general_entry_lbl);
    try a.jmp(ascii_ok);

    a.bindLabel(ascii_check_general);
    try a.xorReg32Reg32(.rax, .rax);
    a.bindLabel(ascii_byte_loop);
    try a.cmpRegReg(.rax, .r9);
    try a.jcc(.ae, ascii_ok);
    try a.movzxReg32Mem8Indexed1(.r10, .r8, .rax, 0);
    try a.cmpReg32Imm32(.r10, 0x80);
    try a.jcc(.ae, general_entry_lbl);
    try a.addRegImm32(.rax, 1);
    try a.jmp(ascii_byte_loop);

    a.bindLabel(ascii_ok);
    try a.movqXmmReg(.xmm1, .rdi);
    try a.movqXmmReg(.xmm2, .rdx);
    try a.movqXmmReg(.xmm3, .rcx);

    const num_int_regs: usize = @as(usize, block.register_count) - 1;
    const callee_saved_used: usize = if (num_int_regs > 4) num_int_regs - 4 else 0;
    for (0..callee_saved_used) |cs_i| {
        try a.pushReg(fast_int_gprs[4 + cs_i]);
    }

    var ip: usize = 0;
    while (ip < block.ops.len) : (ip += 1) {
        a.bindLabel(fast_op_labels[ip]);
        if (str_analysis.elided[ip]) continue;
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop => {},
            .load_const => {
                const imm = asExactInt32(block.constants[op.b].number).?;
                const ra = fast_int_gprs[op.a - 1];
                if (imm == 0) {
                    try a.xorReg32Reg32(ra, ra);
                } else {
                    try a.movRegImm32(ra, @bitCast(imm));
                }
            },
            .get_prop => {
                const ra = fast_int_gprs[op.a - 1];
                try a.movReg32Reg32(ra, .r9);
            },
            .call => {
                const arg_r: u8 = op.b + 1;
                const r_idx = fast_int_gprs[arg_r - 1];
                const ra = fast_int_gprs[op.a - 1];
                try a.cmpReg32Reg32(r_idx, .r9);
                try a.jcc(.ae, restore_and_general_entry);
                try a.movReg32Reg32(.rax, r_idx);
                try a.movzxReg32Mem8Indexed1(ra, .r8, .rax, 0);
            },
            .move, .load_local, .store_local => {
                const ra = fast_int_gprs[op.a - 1];
                const rb = fast_int_gprs[op.b - 1];
                if (ra != rb) {
                    try a.movReg32Reg32(ra, rb);
                }
            },
            .add, .add_num, .sub_num, .mul_num => {
                const ra = fast_int_gprs[op.a - 1];
                const rb = fast_int_gprs[op.b - 1];
                const rc = fast_int_gprs[op.c - 1];
                try a.movReg32Reg32(.rax, rb);
                switch (op.opcode) {
                    .add, .add_num => {
                        try a.addReg32Reg32(.rax, rc);
                        try a.jcc(.o, restore_and_general_entry);
                    },
                    .sub_num => {
                        try a.subReg32Reg32(.rax, rc);
                        try a.jcc(.o, restore_and_general_entry);
                    },
                    .mul_num => {
                        try a.imulReg32Reg32(.rax, rc);
                        try a.jcc(.o, restore_and_general_entry);
                        const mul_nz_lbl = try a.createLabel();
                        try a.testReg32Reg32(.rax, .rax);
                        try a.jcc(.ne, mul_nz_lbl);
                        try a.movReg32Reg32(.rdx, rb);
                        try a.orReg32Reg32(.rdx, rc);
                        try a.testReg32Reg32(.rdx, .rdx);
                        try a.jcc(.s, restore_and_general_entry);
                        a.bindLabel(mul_nz_lbl);
                    },
                    else => unreachable,
                }
                try a.movReg32Reg32(ra, .rax);
            },
            .add_local_const, .sub_local_const => {
                const imm = asExactInt32(block.constants[op.c].number).?;
                const ra = fast_int_gprs[op.a - 1];
                const rb = fast_int_gprs[op.b - 1];
                if (ra != rb) {
                    try a.movReg32Reg32(ra, rb);
                }
                if (op.opcode == .add_local_const) {
                    try a.addReg32Imm32(ra, imm);
                } else {
                    try a.subReg32Imm32(ra, imm);
                }
                try a.jcc(.o, restore_and_general_entry);
            },
            .mod_num => {
                const ra = fast_int_gprs[op.a - 1];
                const rb = fast_int_gprs[op.b - 1];
                const rc = fast_int_gprs[op.c - 1];
                try a.movReg32Reg32(.rax, rb);
                try a.testReg32Reg32(.rax, .rax);
                try a.jcc(.s, restore_and_general_entry);
                try a.cmpReg32Imm32(rc, 0);
                try a.jcc(.le, restore_and_general_entry);
                try a.xorReg32Reg32(.rdx, .rdx);
                try a.divReg32(rc);
                try a.movReg32Reg32(ra, .rdx);
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const imm = asExactInt32(block.constants[op.b].number).?;
                const ra = fast_int_gprs[op.a - 1];
                const target_lbl = fast_op_labels[ip + @as(usize, op.c)];
                try a.cmpReg32Imm32(ra, imm);
                switch (op.opcode) {
                    .jeq_local_const_false => try a.jcc(.ne, target_lbl),
                    .jlt_local_const_false => try a.jcc(.ge, target_lbl),
                    .jle_local_const_false => try a.jcc(.g, target_lbl),
                    .jgt_local_const_false => try a.jcc(.le, target_lbl),
                    .jge_local_const_false => try a.jcc(.l, target_lbl),
                    else => unreachable,
                }
            },
            .jump => {
                const target_pc = (@as(usize, op.b) << 8) | op.c;
                try a.jmp(fast_op_labels[target_pc]);
            },
            .return_value => {
                const ra = fast_int_gprs[op.a - 1];
                try a.cvtsi2sdXmmReg32(.xmm0, ra);
                try a.movsdMemXmm(.rsi, 0, .xmm0);
                var rev_i: usize = callee_saved_used;
                while (rev_i > 0) {
                    rev_i -= 1;
                    try a.popReg(fast_int_gprs[4 + rev_i]);
                }
                try a.xorReg32Reg32(.rax, .rax);
                try a.ret();
            },
            .return_undefined => {
                try a.movRegImm64(.rax, JSValue.UNDEFINED.bits);
                try a.movMemReg(.rsi, 0, .rax);
                try a.movqXmmReg(.xmm0, .rax);
                var rev_i: usize = callee_saved_used;
                while (rev_i > 0) {
                    rev_i -= 1;
                    try a.popReg(fast_int_gprs[4 + rev_i]);
                }
                try a.xorReg32Reg32(.rax, .rax);
                try a.ret();
            },
            else => unreachable,
        }
    }

    a.bindLabel(restore_and_general_entry);
    var rev_i: usize = callee_saved_used;
    while (rev_i > 0) {
        rev_i -= 1;
        try a.popReg(fast_int_gprs[4 + rev_i]);
    }
    try a.movqRegXmm(.rdi, .xmm1);
    try a.movqRegXmm(.rdx, .xmm2);
    try a.movqRegXmm(.rcx, .xmm3);
    try a.jmp(general_entry_lbl);

    a.bindLabel(fast_bailout);
    try a.movRegImm32(.rax, 1);
    try a.ret();
}
