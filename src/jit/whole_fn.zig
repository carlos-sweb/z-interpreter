//! Whole-function JIT tier: canCompile, compileImpl, compileFastSelfRec.

const std = @import("jit_common.zig").std;
const Allocator = @import("jit_common.zig").Allocator;
const JSValue = @import("jit_common.zig").JSValue;
const environment_mod = @import("jit_common.zig").environment_mod;
const codeblock = @import("jit_common.zig").codeblock;
const vm = @import("jit_common.zig").vm;
const string_builtins = @import("jit_common.zig").string_builtins;
const x64_asm = @import("jit_common.zig").x64_asm;
const Assembler = @import("jit_common.zig").Assembler;
const Label = @import("jit_common.zig").Label;
const Xmm = @import("jit_common.zig").Xmm;
const JitGlobalSlot = @import("jit_common.zig").JitGlobalSlot;
const constantName = @import("jit_common.zig").constantName;
const emitGlobalSlotLookup = @import("jit_common.zig").emitGlobalSlotLookup;
const emitCondJump = @import("jit_common.zig").emitCondJump;
const emitSharedOp = @import("jit_common.zig").emitSharedOp;
const isKnownNum = @import("jit_common.zig").isKnownNum;
const isKnownNonHeap = @import("jit_common.zig").isKnownNonHeap;
const markNum = @import("jit_common.zig").markNum;
const clearReg = @import("jit_common.zig").clearReg;
const emitStringLengthToXmm0 = @import("jit_common.zig").emitStringLengthToXmm0;
const emitStringCharCodeAtFromXmm0 = @import("jit_common.zig").emitStringCharCodeAtFromXmm0;
const canCompileFastIntAscii = @import("fast_int_ascii.zig").canCompileFastIntAscii;
const emitFastIntAsciiTier = @import("fast_int_ascii.zig").emitFastIntAsciiTier;
const regBit64 = @import("osr_analysis.zig").regBit64;
const opUseDefMasks = @import("osr_analysis.zig").opUseDefMasks;

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

pub const MAX_WHOLE_FN_STRING_OPS = 256;

pub const WholeFnStringAnalysis = struct {
    param_mask: u32 = 0,
    has_char_code_at: bool = false,
    elided: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false),
    char_code_at_str: [MAX_WHOLE_FN_STRING_OPS]?u8 = @splat(null),
    get_prop_len_str: [MAX_WHOLE_FN_STRING_OPS]?u8 = @splat(null),
};

pub const CharCodeAtSpan = struct {
    gp_ip: usize,
    ld_ip: ?usize,
    str_reg: u8,
};

pub noinline fn findCharCodeAtGetProp(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    call_ip: usize,
) ?CharCodeAtSpan {
    const call_op = block.ops[call_ip];
    if (call_op.opcode != .call or call_op.c >= block.call_target_cache.len) return null;
    const cs = &block.call_target_cache[call_op.c];
    if (cs.arg_count != 1) return null;
    const this_r = cs.this_reg orelse return null;
    if (cs.callee) |cal| {
        if (!cal.isFunction() or cal.asFunction().value.call != string_builtins.stringCharCodeAt) return null;
    }

    var found_gp: ?usize = null;
    var k = call_ip;
    while (k > start_ip) {
        k -= 1;
        const cand = block.ops[k];
        if (cand.opcode == .get_prop and cand.a == call_op.b and cand.b == this_r) {
            const prop_name = constantName(block, cand.c) orelse break;
            if (std.mem.eql(u8, prop_name, "charCodeAt")) {
                found_gp = k;
            }
            break;
        }
        const is_pure_arg_op = switch (cand.opcode) {
            .nop => true,
            .move,
            .load_local,
            .load_const,
            .load_true,
            .load_false,
            .neg,
            .not_bits,
            .add_local_const,
            .sub_local_const,
            .lt_local_const,
            .gt_local_const,
            .le_local_const,
            .ge_local_const,
            .eq_local_const,
            .get_prop,
            .get_elem_const,
            => cand.a != this_r and cand.a != call_op.b and cand.b != call_op.b,
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
            => cand.a != this_r and cand.a != call_op.b and cand.b != call_op.b and cand.c != call_op.b,
            else => false,
        };
        if (!is_pure_arg_op) break;
    }

    const gp_ip = found_gp orelse return null;
    var ld_ip: ?usize = null;
    var str_reg: u8 = this_r;
    if (gp_ip > start_ip and this_r >= block.local_count) {
        const prev = block.ops[gp_ip - 1];
        if ((prev.opcode == .load_local or prev.opcode == .move) and prev.a == this_r and prev.b != this_r) {
            var used_in_span = false;
            for (gp_ip + 1 .. call_ip) |m_ip| {
                const m_op = block.ops[m_ip];
                const ud = opUseDefMasks(block, m_op);
                if ((ud.use & regBit64(this_r)) != 0 or (ud.def & regBit64(prev.b)) != 0) {
                    used_in_span = true;
                    break;
                }
            }
            if (!used_in_span) {
                ld_ip = gp_ip - 1;
                str_reg = prev.b;
            }
        }
    }

    const span_first = ld_ip orelse gp_ip;
    for (start_ip..end_ip + 1) |j_ip| {
        const j_op = block.ops[j_ip];
        const maybe_tgt: ?usize = switch (j_op.opcode) {
            .jump, .jump_if_false, .jump_if_true, .jump_if_not_nullish, .setup_catch => (@as(usize, j_op.b) << 8) | j_op.c,
            .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => j_ip + @as(usize, j_op.c),
            else => null,
        };
        if (maybe_tgt) |tgt| {
            if (tgt > span_first and tgt <= call_ip) return null;
        }
    }

    return .{
        .gp_ip = gp_ip,
        .ld_ip = ld_ip,
        .str_reg = str_reg,
    };
}

pub noinline fn isTempDeadOutsideSpan(
    block: *const codeblock.CodeBlock,
    span_start: usize,
    span_end: usize,
    temp_reg: u8,
) bool {
    if (temp_reg < block.local_count or temp_reg >= 64) return false;
    const len = block.ops.len;
    if (len == 0 or len > MAX_WHOLE_FN_STRING_OPS) return false;
    const t_bit = regBit64(temp_reg);

    var use_t: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false);
    var def_t: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false);
    for (block.ops, 0..) |op, ip| {
        if (ip >= span_start and ip <= span_end) {
            if (ip == span_end) {
                def_t[ip] = (op.opcode == .call and op.a == temp_reg) or (op.opcode == .get_prop and op.a == temp_reg);
            }
            continue;
        }
        const ud = opUseDefMasks(block, op);
        use_t[ip] = (ud.use & t_bit) != 0;
        def_t[ip] = (ud.def & t_bit) != 0;
    }

    var live_in: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false);
    var live_out: [MAX_WHOLE_FN_STRING_OPS]bool = @splat(false);
    var changed = true;
    while (changed) {
        changed = false;
        var pc = len;
        while (pc > 0) {
            pc -= 1;
            const op = block.ops[pc];
            const out: bool = switch (op.opcode) {
                .return_value, .return_undefined, .throw_value => false,
                .jump => blk: {
                    const t = (@as(usize, op.b) << 8) | op.c;
                    break :blk if (t < len) live_in[t] else false;
                },
                .jump_if_false, .jump_if_true, .jump_if_not_nullish, .setup_catch => blk: {
                    const t = (@as(usize, op.b) << 8) | op.c;
                    const fall = if (pc + 1 < len) live_in[pc + 1] else false;
                    const br = if (t < len) live_in[t] else false;
                    break :blk fall or br;
                },
                .jeq_local_const_false,
                .jlt_local_const_false,
                .jle_local_const_false,
                .jgt_local_const_false,
                .jge_local_const_false,
                => blk: {
                    const t = pc + @as(usize, op.c);
                    const fall = if (pc + 1 < len) live_in[pc + 1] else false;
                    const br = if (t < len) live_in[t] else false;
                    break :blk fall or br;
                },
                else => if (pc + 1 < len) live_in[pc + 1] else false,
            };
            const inp = use_t[pc] or (out and !def_t[pc]);
            if (out != live_out[pc] or inp != live_in[pc]) {
                live_out[pc] = out;
                live_in[pc] = inp;
                changed = true;
            }
        }
    }

    if (live_in[0] or live_in[span_start]) return false;
    if (!def_t[span_end] and live_out[span_end]) return false;
    return true;
}

pub noinline fn analyzeWholeFnStrings(block: *const codeblock.CodeBlock) ?WholeFnStringAnalysis {
    var has_str_op = false;
    for (block.ops) |op| {
        if (op.opcode == .get_prop or op.opcode == .call) {
            has_str_op = true;
            break;
        }
    }
    var res = WholeFnStringAnalysis{};
    if (!has_str_op) return res;
    if (block.param_count == 0 or block.ops.len == 0 or block.ops.len > MAX_WHOLE_FN_STRING_OPS) return null;

    for (block.ops, 0..) |op, ip| {
        if (op.opcode == .call) {
            const span = findCharCodeAtGetProp(block, 0, block.ops.len - 1, ip) orelse return null;
            if (span.str_reg >= block.param_count or span.str_reg >= 32) return null;
            const gp_op = block.ops[span.gp_ip];
            if (gp_op.a < block.local_count) return null;
            if (span.ld_ip) |ld| {
                if (!isTempDeadOutsideSpan(block, ld, ip, gp_op.b)) return null;
                res.elided[ld] = true;
            }
            if (!isTempDeadOutsideSpan(block, span.gp_ip, ip, gp_op.a)) return null;
            res.elided[span.gp_ip] = true;
            res.char_code_at_str[ip] = span.str_reg;
            res.has_char_code_at = true;
            res.param_mask |= (@as(u32, 1) << @intCast(span.str_reg));
        }
    }

    for (block.ops, 0..) |op, ip| {
        if (op.opcode == .get_prop and !res.elided[ip]) {
            const kname = constantName(block, op.c) orelse return null;
            if (!std.mem.eql(u8, kname, "length")) return null;
            var s_reg: u8 = op.b;
            if (s_reg >= block.param_count) {
                if (ip > 0 and !res.elided[ip - 1] and s_reg >= block.local_count) {
                    const prev = block.ops[ip - 1];
                    if ((prev.opcode == .load_local or prev.opcode == .move) and prev.a == s_reg and prev.b < block.param_count) {
                        var is_tgt = false;
                        for (block.ops, 0..) |jop, j_ip| {
                            const maybe_t: ?usize = switch (jop.opcode) {
                                .jump, .jump_if_false, .jump_if_true, .jump_if_not_nullish, .setup_catch => (@as(usize, jop.b) << 8) | jop.c,
                                .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => j_ip + @as(usize, jop.c),
                                else => null,
                            };
                            if (maybe_t != null and maybe_t.? == ip) {
                                is_tgt = true;
                                break;
                            }
                        }
                        if (!is_tgt and isTempDeadOutsideSpan(block, ip - 1, ip, s_reg)) {
                            res.elided[ip - 1] = true;
                            s_reg = prev.b;
                        }
                    }
                }
            }
            if (s_reg >= block.param_count or s_reg >= 32 or op.a == s_reg) return null;
            res.get_prop_len_str[ip] = s_reg;
            res.param_mask |= (@as(u32, 1) << @intCast(s_reg));
        }
    }

    if (res.param_mask == 0) return null;

    for (block.ops, 0..) |op, ip| {
        if (res.elided[ip]) continue;
        if (op.opcode == .store_global or op.opcode == .call_global) return null;
        if (res.get_prop_len_str[ip] != null) {
            if (op.a < 32 and (res.param_mask & (@as(u32, 1) << @intCast(op.a))) != 0) return null;
            continue;
        }
        if (res.char_code_at_str[ip] != null) {
            const arg_r = @as(usize, op.b) + 1;
            if (arg_r >= block.register_count) return null;
            if (op.a < 32 and (res.param_mask & (@as(u32, 1) << @intCast(op.a))) != 0) return null;
            if (arg_r < 32 and (res.param_mask & (@as(u32, 1) << @intCast(arg_r))) != 0) return null;
            continue;
        }
        const ud = opUseDefMasks(block, op);
        if (((ud.use | ud.def) & @as(u64, res.param_mask)) != 0) return null;
    }

    return res;
}

pub fn canCompile(block: *const codeblock.CodeBlock) bool {
    if (!comptime x64_asm.is_supported_host) return false;
    if (block.exception_table.len > 0 or block.flags.has_try) return false;
    if (block.flags.is_generator or block.flags.is_async or block.flags.needs_arguments) return false;
    if (block.register_count == 0 or block.register_count > 32) return false;
    if (block.param_count > block.register_count or block.local_count > block.register_count) return false;
    if (block.ops.len == 0) return false;

    const str_analysis = analyzeWholeFnStrings(block) orelse return false;

    var seen_store_global = false;
    var store_global_ip: usize = 0;
    var last_stored_global_name: ?[]const u8 = null;
    var num_validated_regs: u32 = 0;
    var max_jump_target: usize = 0;

    for (block.ops, 0..) |op, ip| {
        if (ip < MAX_WHOLE_FN_STRING_OPS and str_analysis.elided[ip]) continue;
        const reg_bit = if (op.a < 32) (@as(u32, 1) << @intCast(op.a)) else 0;
        switch (op.opcode) {
            .nop, .return_undefined => {},
            .get_prop => {
                if (seen_store_global or op.a >= block.register_count) return false;
                if (ip >= MAX_WHOLE_FN_STRING_OPS or str_analysis.get_prop_len_str[ip] == null) return false;
                num_validated_regs |= reg_bit;
            },
            .call => {
                if (seen_store_global or op.a >= block.register_count or op.b >= block.register_count) return false;
                if (ip >= MAX_WHOLE_FN_STRING_OPS or str_analysis.char_code_at_str[ip] == null) return false;
                num_validated_regs |= reg_bit;
            },
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

pub fn findPreloadXmm(val: f64, const_vals: []const f64) ?Xmm {
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

pub noinline fn compileFastSelfRec(
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

pub noinline fn compileImpl(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    slots_opt: ?[]JitGlobalSlot,
) ![]align(std.heap.page_size_min) u8 {
    const str_analysis = analyzeWholeFnStrings(block) orelse return error.CannotCompile;
    var a = Assembler.init(allocator);
    defer a.deinit();

    const use_fast_int_ascii = (slots_opt == null and canCompileFastIntAscii(allocator, block, &str_analysis));
    const general_entry_lbl = try a.createLabel();
    if (use_fast_int_ascii) {
        var guard_opt: ?vm.StringCharCodeAtGuard = null;
        if (str_analysis.has_char_code_at) {
            var g: vm.StringCharCodeAtGuard = .{};
            if (vm.jitGetStringCharCodeAtGuard(block, &g) == 0) {
                guard_opt = g;
            }
        }
        try emitFastIntAsciiTier(allocator, &a, block, &str_analysis, guard_opt, general_entry_lbl);
    }

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
    a.bindLabel(general_entry_lbl);
    try a.pushReg(.rbx);
    try a.pushReg(.r12);
    try a.pushReg(.r13);
    try a.pushReg(.r14);
    try a.pushReg(.r15);
    if (use_fast_int_ascii) {
        try a.subRegImm32(.rsp, 96);
        inline for (0..12) |xi| {
            const xmm_save: Xmm = @enumFromInt(4 + xi);
            try a.movsdMemXmm(.rsp, @intCast(xi * 8), xmm_save);
        }
    }
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
    if (use_fast_int_ascii) {
        try a.movqXmmReg(.xmm0, .rcx);
    }

    a.bindLabel(ext_done);
    if (use_fast_int_ascii) {
        inline for (0..12) |xi| {
            const xmm_save: Xmm = @enumFromInt(4 + xi);
            try a.movsdXmmMem(xmm_save, .rsp, @intCast(xi * 8));
        }
        try a.addRegImm32(.rsp, 96);
    }
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

    const single_str_param: ?u8 = if (@popCount(str_analysis.param_mask) == 1 and slots_opt == null)
        @intCast(@ctz(str_analysis.param_mask))
    else
        null;

    if (single_str_param) |sp| {
        try a.movRegImm64(.rdi, @intFromPtr(block));
        try a.movRegMem(.rsi, .r12, @intCast(@as(usize, sp) * 8));
        try a.movRegImm32(.rdx, @intFromBool(str_analysis.has_char_code_at));
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitPrepareWholeFnString));
        try a.movRegReg(.rbx, .rsp);
        try a.andRegImm8(.rsp, -16);
        try a.callReg(.rax);
        try a.movRegReg(.rsp, .rbx);
        try a.movRegReg(.r14, .rax);
        try a.shrRegImm8(.rax, 63);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bailout_label);
    } else if (str_analysis.has_char_code_at) {
        try a.movRegImm64(.rdi, @intFromPtr(block));
        try a.movRegImm64(.rax, @intFromPtr(&vm.jitCheckStringCharCodeAtBlock));
        try a.movRegReg(.rbx, .rsp);
        try a.andRegImm8(.rsp, -16);
        try a.callReg(.rax);
        try a.movRegReg(.rsp, .rbx);
        try a.testRegReg(.rax, .rax);
        try a.jcc(.ne, bailout_label);
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
        if (ip < MAX_WHOLE_FN_STRING_OPS and str_analysis.elided[ip]) continue;
        const op = block.ops[ip];
        switch (op.opcode) {
            .nop => {},
            .get_prop => {
                const s_reg = str_analysis.get_prop_len_str[ip].?;
                const use_r14 = (single_str_param != null and single_str_param.? == s_reg);
                try emitStringLengthToXmm0(&a, s_reg, use_r14, bailout_label);
                try a.movqRegXmm(.rax, .xmm0);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                markNum(op.a, &known_num, &known_non_heap);
            },
            .call => {
                const s_reg = str_analysis.char_code_at_str[ip].?;
                const use_r14 = (single_str_param != null and single_str_param.? == s_reg);
                const arg_r: u8 = op.b + 1;
                try a.movRegMem(.rax, .r12, @intCast(@as(usize, arg_r) * 8));
                if (!isKnownNum(known_num, arg_r)) {
                    try a.cmpRegReg(.rax, .r15);
                    try a.jcc(.ae, bailout_label);
                    markNum(arg_r, &known_num, &known_non_heap);
                }
                try a.movqXmmReg(.xmm0, .rax);
                try emitStringCharCodeAtFromXmm0(&a, s_reg, use_r14, false, bailout_label);
                try a.movqRegXmm(.rax, .xmm0);
                try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
                markNum(op.a, &known_num, &known_non_heap);
            },
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
