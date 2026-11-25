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

const RegBounds = struct {
    min: i64 = -2147483648,
    max: i64 = 2147483647,

    inline fn isNonNeg(self: RegBounds) bool {
        return self.min >= 0;
    }

    inline fn isAsciiSubSafe(self: RegBounds, imm: i32) bool {
        return self.min >= 0 and self.max <= 127 and imm >= 0 and imm <= 127;
    }
};

const TernaryCmov = struct {
    cond_reg: u8,
    cmp_imm: i32,
    dst_reg: u8,
    final_reg: u8,
    true_imm: i32,
    false_src_reg: u8,
    false_add_imm: i32,
    end_ip: usize,
};

const FastIntOptAnalysis = struct {
    is_jump_target: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false),
    elide_char_bounds: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false),
    elide_sub_jo: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false),
    elide_mul_neg_zero: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false),
    mod_const_pos_divisor: [MAX_WHOLE_FN_STRING_OPS]i32 = @splat(0),
    mod_dividend_non_neg: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false),
    ternary_at: [MAX_WHOLE_FN_STRING_OPS]?TernaryCmov = @splat(null),
};

noinline fn analyzeFastIntOpts(
    block: *const codeblock.CodeBlock,
    str_analysis: *const WholeFnStringAnalysis,
) FastIntOptAnalysis {
    var out = FastIntOptAnalysis{};
    const n = block.ops.len;
    if (n == 0 or n > MAX_WHOLE_FN_STRING_OPS) return out;

    for (block.ops, 0..) |op, ip| {
        if (str_analysis.elided[ip]) continue;
        switch (op.opcode) {
            .jump => {
                const t = (@as(usize, op.b) << 8) | op.c;
                if (t < n) out.is_jump_target[t] = true;
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const t = ip + @as(usize, op.c);
                if (t < n) out.is_jump_target[t] = true;
            },
            else => {},
        }
    }

    // 1. Detect safe reverse string index loop:
    //    pre-loop: r_len = s.length; r_i = r_len - 1
    //    loop header at H: jge_local_const_false r_i, 0 -> exit E (whereops[E-1] is jump -> H)
    //    inside [H..E-1]: r_i is only written once by `sub_local_const r_i, r_i, 1` at the latch (E-2)
    //    and no interior jump enters after the header or skips the guard.
    var len_regs: u64 = 0;
    var len_minus_one_regs: u64 = 0;
    var header_ip: ?usize = null;
    for (block.ops, 0..) |op, ip| {
        if (str_analysis.elided[ip]) continue;
        if (out.is_jump_target[ip]) {
            header_ip = ip;
            break;
        }
        switch (op.opcode) {
            .get_prop => {
                if (str_analysis.get_prop_len_str[ip] != null and op.a < 64) {
                    len_regs |= (@as(u64, 1) << @intCast(op.a));
                    len_minus_one_regs &= ~(@as(u64, 1) << @intCast(op.a));
                }
            },
            .move, .load_local, .store_local => {
                if (op.a < 64 and op.b < 64) {
                    const b_bit = @as(u64, 1) << @intCast(op.b);
                    const a_bit = @as(u64, 1) << @intCast(op.a);
                    if ((len_regs & b_bit) != 0) len_regs |= a_bit else len_regs &= ~a_bit;
                    if ((len_minus_one_regs & b_bit) != 0) len_minus_one_regs |= a_bit else len_minus_one_regs &= ~a_bit;
                }
            },
            .sub_local_const => {
                if (op.a < 64 and op.b < 64) {
                    const imm = asExactInt32(block.constants[op.c].number).?;
                    const b_bit = @as(u64, 1) << @intCast(op.b);
                    const a_bit = @as(u64, 1) << @intCast(op.a);
                    if (imm == 1 and (len_regs & b_bit) != 0) {
                        len_minus_one_regs |= a_bit;
                    } else {
                        len_minus_one_regs &= ~a_bit;
                    }
                    len_regs &= ~a_bit;
                }
            },
            else => {
                const ud = opUseDefMasks(block, op);
                len_regs &= ~ud.def;
                len_minus_one_regs &= ~ud.def;
            },
        }
    }

    if (header_ip) |h_ip| {
        const hop = block.ops[h_ip];
        if (hop.opcode == .jge_local_const_false and hop.a < 64) {
            const guard_imm = asExactInt32(block.constants[hop.b].number).?;
            const exit_ip = h_ip + @as(usize, hop.c);
            const idx_reg = hop.a;
            const idx_bit = @as(u64, 1) << @intCast(idx_reg);
            if (guard_imm == 0 and (len_minus_one_regs & idx_bit) != 0 and exit_ip > h_ip + 2 and exit_ip <= n) {
                const back_ip = exit_ip - 1;
                const back_op = block.ops[back_ip];
                if (back_op.opcode == .jump and (((@as(usize, back_op.b) << 8) | back_op.c) == h_ip)) {
                    var idx_defs_in_loop: usize = 0;
                    var valid_latch_dec = false;
                    var has_outside_entry_into_body = false;
                    for (0..n) |j_ip| {
                        if (str_analysis.elided[j_ip]) continue;
                        const jop = block.ops[j_ip];
                        const tgt_opt: ?usize = switch (jop.opcode) {
                            .jump => (@as(usize, jop.b) << 8) | jop.c,
                            .jeq_local_const_false,
                            .jlt_local_const_false,
                            .jle_local_const_false,
                            .jgt_local_const_false,
                            .jge_local_const_false,
                            => j_ip + @as(usize, jop.c),
                            else => null,
                        };
                        if (tgt_opt) |t| {
                            if ((j_ip < h_ip or j_ip >= exit_ip) and (t > h_ip and t < exit_ip)) {
                                has_outside_entry_into_body = true;
                            }
                        }
                    }
                    for (h_ip + 1..back_ip) |b_ip| {
                        if (str_analysis.elided[b_ip]) continue;
                        const bop = block.ops[b_ip];
                        const ud = opUseDefMasks(block, bop);
                        if ((ud.def & idx_bit) != 0) {
                            idx_defs_in_loop += 1;
                            if (bop.opcode == .sub_local_const and bop.a == idx_reg and bop.b == idx_reg) {
                                const dec_imm = asExactInt32(block.constants[bop.c].number).?;
                                if (dec_imm == 1) valid_latch_dec = true;
                            }
                        }
                    }
                    if (!has_outside_entry_into_body and idx_defs_in_loop == 1 and valid_latch_dec) {
                        var seen_dec = false;
                        for (h_ip + 1..back_ip) |b_ip| {
                            if (str_analysis.elided[b_ip]) continue;
                            const bop = block.ops[b_ip];
                            if (bop.opcode == .sub_local_const and bop.a == idx_reg) {
                                seen_dec = true;
                            }
                            if (!seen_dec and bop.opcode == .call and str_analysis.char_code_at_str[b_ip] != null) {
                                const arg_r: u8 = bop.b + 1;
                                if (arg_r == idx_reg) {
                                    out.elide_char_bounds[b_ip] = true;
                                } else if (b_ip > h_ip + 1) {
                                    const prev = block.ops[b_ip - 1];
                                    if (!out.is_jump_target[b_ip] and (prev.opcode == .load_local or prev.opcode == .move) and prev.a == arg_r and prev.b == idx_reg) {
                                        out.elide_char_bounds[b_ip] = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. Detect simple ternary pattern:
    //    ip:   jeq_local_const_false r_cond, cmp_imm -> false_ip (ip + 3)
    //    ip+1: load_const r_tmp, true_imm
    //    ip+2: jump -> end_ip (ip + 4)
    //    ip+3: add_local_const r_tmp, r_src, add_imm  (or load_const r_tmp, false_imm)
    //    ip+4: (optional store_local / move r_dst, r_tmp when r_tmp is dead or overwritten)
    var t_ip: usize = 0;
    while (t_ip + 3 < n) : (t_ip += 1) {
        if (str_analysis.elided[t_ip]) continue;
        const op0 = block.ops[t_ip];
        if (op0.opcode != .jeq_local_const_false) continue;
        const false_ip = t_ip + @as(usize, op0.c);
        if (false_ip != t_ip + 3 or false_ip >= n) continue;
        if (out.is_jump_target[t_ip + 1] or out.is_jump_target[t_ip + 2]) continue;
        if (str_analysis.elided[t_ip + 1] or str_analysis.elided[t_ip + 2] or str_analysis.elided[t_ip + 3]) continue;
        const op1 = block.ops[t_ip + 1];
        const op2 = block.ops[t_ip + 2];
        const op3 = block.ops[t_ip + 3];
        if (op1.opcode != .load_const or op2.opcode != .jump) continue;
        const join_ip = (@as(usize, op2.b) << 8) | op2.c;
        if (join_ip != t_ip + 4 or join_ip >= n) continue;
        if (op3.opcode != .add_local_const or op3.a != op1.a) continue;
        const cmp_imm = asExactInt32(block.constants[op0.b].number).?;
        const true_imm = asExactInt32(block.constants[op1.b].number).?;
        const add_imm = asExactInt32(block.constants[op3.c].number).?;
        var final_reg = op1.a;
        var end_ip = t_ip + 3;
        if (t_ip + 4 < n and !out.is_jump_target[t_ip + 4] and !str_analysis.elided[t_ip + 4]) {
            const op4 = block.ops[t_ip + 4];
            if ((op4.opcode == .store_local or op4.opcode == .move or op4.opcode == .load_local) and op4.b == op1.a and op4.a == op0.a) {
                final_reg = op4.a;
                end_ip = t_ip + 4;
            }
        }
        out.ternary_at[t_ip] = .{
            .cond_reg = op0.a,
            .cmp_imm = cmp_imm,
            .dst_reg = op1.a,
            .final_reg = final_reg,
            .true_imm = true_imm,
            .false_src_reg = op3.b,
            .false_add_imm = add_imm,
            .end_ip = end_ip,
        };
    }

    // 3. Forward abstract range analysis for:
    //    - ASCII subtraction without overflow (`(s.charCodeAt(i) - 48)`)
    //    - non-negative multiplication without -0 check (`imul`)
    //    - constant positive divisor & non-negative dividend for magic `% k`
    var bounds: [16]RegBounds = @splat(.{});
    var exact_const: [16]?i32 = @splat(null);
    // Narrow loop-invariant non-negative registers (e.g. `m` initialized to 2 and updated via ternary 2..7 or `t` initialized to 0 and accumulated with >= 0)
    var possibly_negative_mask: u64 = 0;
    for (block.ops, 0..) |op, ip| {
        if (str_analysis.elided[ip]) continue;
        switch (op.opcode) {
            .load_const => {
                const imm = asExactInt32(block.constants[op.b].number).?;
                if (imm < 0 and op.a < 64) possibly_negative_mask |= (@as(u64, 1) << @intCast(op.a));
            },
            .sub_num, .sub_local_const => {
                if (op.a < 64) possibly_negative_mask |= (@as(u64, 1) << @intCast(op.a));
            },
            .add_local_const => {
                const imm = asExactInt32(block.constants[op.c].number).?;
                if (imm < 0 and op.a < 64) possibly_negative_mask |= (@as(u64, 1) << @intCast(op.a));
            },
            .move, .load_local, .store_local => {
                if (op.a < 64 and op.b < 64) {
                    if ((possibly_negative_mask & (@as(u64, 1) << @intCast(op.b))) != 0) {
                        possibly_negative_mask |= (@as(u64, 1) << @intCast(op.a));
                    }
                }
            },
            .add, .add_num, .mul_num, .mod_num => {
                if (op.a < 64 and op.b < 64 and op.c < 64) {
                    const b_neg = (possibly_negative_mask & (@as(u64, 1) << @intCast(op.b))) != 0;
                    const c_neg = (possibly_negative_mask & (@as(u64, 1) << @intCast(op.c))) != 0;
                    if (b_neg or c_neg) possibly_negative_mask |= (@as(u64, 1) << @intCast(op.a));
                }
            },
            else => {},
        }
    }

    for (block.ops, 0..) |op, ip| {
        if (str_analysis.elided[ip]) continue;
        if (out.is_jump_target[ip]) {
            for (1..16) |r| {
                exact_const[r] = null;
                if ((possibly_negative_mask & (@as(u64, 1) << @intCast(r))) == 0) {
                    bounds[r] = .{ .min = 0, .max = 2147483647 };
                } else {
                    bounds[r] = .{};
                }
            }
        }
        switch (op.opcode) {
            .load_const => {
                const imm = asExactInt32(block.constants[op.b].number).?;
                if (op.a < 16) {
                    bounds[op.a] = .{ .min = imm, .max = imm };
                    exact_const[op.a] = imm;
                }
            },
            .get_prop => {
                if (op.a < 16) {
                    bounds[op.a] = .{ .min = 0, .max = 64 };
                    exact_const[op.a] = null;
                }
            },
            .call => {
                if (op.a < 16) {
                    bounds[op.a] = .{ .min = 0, .max = 127 };
                    exact_const[op.a] = null;
                }
            },
            .move, .load_local, .store_local => {
                if (op.a < 16 and op.b < 16) {
                    bounds[op.a] = bounds[op.b];
                    exact_const[op.a] = exact_const[op.b];
                }
            },
            .sub_local_const => {
                const imm = asExactInt32(block.constants[op.c].number).?;
                if (op.a < 16 and op.b < 16) {
                    if (bounds[op.b].isAsciiSubSafe(imm)) {
                        out.elide_sub_jo[ip] = true;
                        bounds[op.a] = .{
                            .min = bounds[op.b].min - imm,
                            .max = bounds[op.b].max - imm,
                        };
                    } else {
                        bounds[op.a] = .{};
                    }
                    exact_const[op.a] = null;
                }
            },
            .add_local_const => {
                const imm = asExactInt32(block.constants[op.c].number).?;
                if (op.a < 16 and op.b < 16) {
                    if (bounds[op.b].min >= 0 and imm >= 0) {
                        bounds[op.a] = .{ .min = 0, .max = 2147483647 };
                    } else {
                        bounds[op.a] = .{};
                    }
                    exact_const[op.a] = null;
                }
            },
            .mul_num => {
                if (op.a < 16 and op.b < 16 and op.c < 16) {
                    const b_pos_strict = bounds[op.b].min > 0;
                    const c_pos_strict = bounds[op.c].min > 0;
                    const both_non_neg = bounds[op.b].isNonNeg() and bounds[op.c].isNonNeg();
                    if (both_non_neg or b_pos_strict or c_pos_strict) {
                        out.elide_mul_neg_zero[ip] = true;
                    }
                    if (both_non_neg) {
                        bounds[op.a] = .{ .min = 0, .max = 2147483647 };
                    } else {
                        bounds[op.a] = .{};
                    }
                    exact_const[op.a] = null;
                }
            },
            .add, .add_num => {
                if (op.a < 16 and op.b < 16 and op.c < 16) {
                    if (bounds[op.b].isNonNeg() and bounds[op.c].isNonNeg()) {
                        bounds[op.a] = .{ .min = 0, .max = 2147483647 };
                    } else {
                        bounds[op.a] = .{};
                    }
                    exact_const[op.a] = null;
                }
            },
            .sub_num => {
                if (op.a < 16) {
                    bounds[op.a] = .{};
                    exact_const[op.a] = null;
                }
            },
            .mod_num => {
                if (op.a < 16 and op.b < 16 and op.c < 16) {
                    if (exact_const[op.c]) |div_k| {
                        if (div_k > 1 and div_k <= 1024) {
                            out.mod_const_pos_divisor[ip] = div_k;
                        }
                    }
                    if (bounds[op.b].isNonNeg()) {
                        out.mod_dividend_non_neg[ip] = true;
                    }
                    bounds[op.a] = .{ .min = 0, .max = 2147483647 };
                    exact_const[op.a] = null;
                }
            },
            else => {},
        }
    }

    return out;
}

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

    const opts = analyzeFastIntOpts(block, str_analysis);

    var ip: usize = 0;
    while (ip < block.ops.len) : (ip += 1) {
        a.bindLabel(fast_op_labels[ip]);
        if (str_analysis.elided[ip]) continue;
        if (opts.ternary_at[ip]) |tern| {
            const r_cond = fast_int_gprs[tern.cond_reg - 1];
            const r_dst = fast_int_gprs[tern.dst_reg - 1];
            const r_final = fast_int_gprs[tern.final_reg - 1];
            const r_fsrc = fast_int_gprs[tern.false_src_reg - 1];
            try a.movReg32Reg32(.rax, r_fsrc);
            try a.addReg32Imm32(.rax, tern.false_add_imm);
            try a.jcc(.o, restore_and_general_entry);
            try a.movRegImm32(.rdx, @bitCast(tern.true_imm));
            try a.cmpReg32Imm32(r_cond, tern.cmp_imm);
            try a.cmovccReg32Reg32(.e, .rax, .rdx);
            try a.movReg32Reg32(r_dst, .rax);
            if (r_final != r_dst) {
                try a.movReg32Reg32(r_final, .rax);
            }
            ip = tern.end_ip;
            continue;
        }
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
                if (!opts.elide_char_bounds[ip]) {
                    try a.cmpReg32Reg32(r_idx, .r9);
                    try a.jcc(.ae, restore_and_general_entry);
                }
                try a.movzxReg32Mem8Indexed1(ra, .r8, r_idx, 0);
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
                        if (!opts.elide_mul_neg_zero[ip]) {
                            const mul_nz_lbl = try a.createLabel();
                            try a.testReg32Reg32(.rax, .rax);
                            try a.jcc(.ne, mul_nz_lbl);
                            try a.movReg32Reg32(.rdx, rb);
                            try a.orReg32Reg32(.rdx, rc);
                            try a.testReg32Reg32(.rdx, .rdx);
                            try a.jcc(.s, restore_and_general_entry);
                            a.bindLabel(mul_nz_lbl);
                        }
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
                if (!(op.opcode == .sub_local_const and opts.elide_sub_jo[ip])) {
                    try a.jcc(.o, restore_and_general_entry);
                }
            },
            .mod_num => {
                const ra = fast_int_gprs[op.a - 1];
                const rb = fast_int_gprs[op.b - 1];
                const rc = fast_int_gprs[op.c - 1];
                const const_div = opts.mod_const_pos_divisor[ip];
                if (const_div > 1) {
                    const div_u: u64 = @intCast(const_div);
                    const magic: i32 = @intCast(((@as(u64, 1) << 32) + div_u - 1) / div_u);
                    try a.movReg32Reg32(.rax, rb);
                    if (!opts.mod_dividend_non_neg[ip]) {
                        try a.testReg32Reg32(.rax, .rax);
                        try a.jcc(.s, restore_and_general_entry);
                    }
                    try a.imulRegRegImm32(.rdx, .rax, magic);
                    try a.shrRegImm8(.rdx, 32);
                    try a.imulRegRegImm32(.rdx, .rdx, const_div);
                    try a.subReg32Reg32(.rax, .rdx);
                    try a.movReg32Reg32(ra, .rax);
                } else {
                    try a.movReg32Reg32(.rax, rb);
                    if (!opts.mod_dividend_non_neg[ip]) {
                        try a.testReg32Reg32(.rax, .rax);
                        try a.jcc(.s, restore_and_general_entry);
                    }
                    try a.cmpReg32Imm32(rc, 0);
                    try a.jcc(.le, restore_and_general_entry);
                    try a.xorReg32Reg32(.rdx, .rdx);
                    try a.divReg32(rc);
                    try a.movReg32Reg32(ra, .rdx);
                }
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
