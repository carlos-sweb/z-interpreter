//! OSR loop analysis: pre-pass, XMM promotion, elisions, hoisting.

const std = @import("jit_common.zig").std;
const Allocator = @import("jit_common.zig").Allocator;
const zvalue = @import("jit_common.zig").zvalue;
const JSValue = @import("jit_common.zig").JSValue;
const codeblock = @import("jit_common.zig").codeblock;
const vm = @import("jit_common.zig").vm;
const math_builtins = @import("jit_common.zig").math_builtins;
const Xmm = @import("jit_common.zig").Xmm;
const PropIC = @import("jit_common.zig").PropIC;
const constantName = @import("jit_common.zig").constantName;
const findCharCodeAtGetProp = @import("whole_fn.zig").findCharCodeAtGetProp;
const asExactInt32 = @import("osr_emit.zig").asExactInt32;

pub fn isMathSqrtCall(cs: *const codeblock.CallSiteCache) bool {
    if (cs.arg_count != 1) return false;
    const callee = cs.callee orelse return false;
    if (!callee.isFunction()) return false;
    return callee.asFunction().value.call == math_builtins.mathSqrt;
}

pub fn isMathImulCall(cs: *const codeblock.CallSiteCache) bool {
    if (cs.arg_count != 2) return false;
    const callee = cs.callee orelse return false;
    if (!callee.isFunction()) return false;
    return callee.asFunction().value.call == math_builtins.mathImul;
}

pub const PromotedPropsAnalysis = struct {
    count: usize = 0,
    obj_reg: u8 = 0,
    shape_id: u32 = 0,
    max_slot: u32 = 0,
    slots: [6]u32 = @splat(0),
    xmms: [6]Xmm = @splat(.xmm0),
    written: [6]bool = @splat(false),

    pub fn findSlot(self: *const PromotedPropsAnalysis, slot_idx: u32) ?usize {
        for (0..self.count) |i| {
            if (self.slots[i] == slot_idx) return i;
        }
        return null;
    }
};

pub noinline fn analyzePromotedProps(
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic: ?*const [256]PropIC,
    prepass: *const OsrPrePass,
) PromotedPropsAnalysis {
    const table = prop_ic orelse return .{};
    var res = PromotedPropsAnalysis{};
    var has_obj = false;
    var keys: [6][]const u8 = undefined;
    const loop_len = end_ip - start_ip + 1;

    for (0..loop_len) |l_idx| {
        if (prepass.elided_compound_op[l_idx]) continue;
        const ip = start_ip + l_idx;
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
                const raw_obj_r = if (is_set) op.a else op.b;
                const obj_r = prepass.compound_arr_override[l_idx] orelse raw_obj_r;
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

    for (0..loop_len) |l_idx| {
        if (prepass.elided_compound_op[l_idx]) continue;
        const ip = start_ip + l_idx;
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

pub const MAX_HOISTED_ARRAYS = 8;

pub const HoistedElemKind = enum(u8) {
    zarray_holey,
    zarray_dense,
    ta_f64,
    ta_i32,
    ta_u8,

    pub inline fn isPtrLen(self: HoistedElemKind) bool {
        return self != .zarray_holey;
    }

    pub inline fn isTypedArray(self: HoistedElemKind) bool {
        return switch (self) {
            .ta_f64, .ta_i32, .ta_u8 => true,
            else => false,
        };
    }

    pub inline fn expectedTypedKind(self: HoistedElemKind) u64 {
        return switch (self) {
            .ta_f64 => @intFromEnum(zvalue.TypedKind.f64),
            .ta_i32 => @intFromEnum(zvalue.TypedKind.i32),
            .ta_u8 => @intFromEnum(zvalue.TypedKind.u8),
            else => unreachable,
        };
    }
};

pub fn classifyTypedArrayForHoist(v: JSValue) ?HoistedElemKind {
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

pub const HoistedArrays = struct {
    regs: [MAX_HOISTED_ARRAYS]u8 = @splat(0),
    written: [MAX_HOISTED_ARRAYS]bool = @splat(false),
    dense: [MAX_HOISTED_ARRAYS]bool = @splat(false),
    kinds: [MAX_HOISTED_ARRAYS]HoistedElemKind = @splat(.zarray_holey),
    use_counts: [MAX_HOISTED_ARRAYS]u32 = @splat(0),
    count: usize = 0,
    primary_in_regs: bool = false,

    pub fn find(self: *const HoistedArrays, reg: u8) ?usize {
        for (0..self.count) |i| {
            if (self.regs[i] == reg) return i;
        }
        return null;
    }
};

pub const FusedCmp = struct {
    skip_ops: u8,
    target_pc: usize,
    jump_if_true: bool,
};

pub inline fn regBit64(r: u8) u64 {
    return if (r < 64) (@as(u64, 1) << @intCast(r)) else 0;
}

pub fn isFusableCmpOpcode(opcode: codeblock.Opcode) bool {
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

pub fn opUseDefMasks(block: *const codeblock.CodeBlock, op: codeblock.Op) struct { use: u64, def: u64 } {
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

pub noinline fn computeBlockLiveOut(allocator: Allocator, block: *const codeblock.CodeBlock) ![]u64 {
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

pub fn opMayMutateMathSqrt(block: *const codeblock.CodeBlock, start_ip: usize, end_ip: usize, ip: usize, op: codeblock.Op) bool {
    return switch (op.opcode) {
        .call_global => true,
        .call => (op.c >= block.call_target_cache.len or (!isMathSqrtCall(&block.call_target_cache[op.c]) and !isMathImulCall(&block.call_target_cache[op.c]) and findCharCodeAtGetProp(block, start_ip, end_ip, ip) == null)),
        .store_global => blk: {
            const k = constantName(block, op.b) orelse break :blk true;
            break :blk std.mem.eql(u8, k, "Math");
        },
        .set_prop, .set_prop_transition => blk: {
            const k = constantName(block, op.b) orelse break :blk true;
            break :blk (std.mem.eql(u8, k, "sqrt") or std.mem.eql(u8, k, "imul") or std.mem.eql(u8, k, "Math"));
        },
        else => false,
    };
}

pub fn opMayMutateStringCharCodeAt(block: *const codeblock.CodeBlock, start_ip: usize, end_ip: usize, ip: usize, op: codeblock.Op) bool {
    return switch (op.opcode) {
        .call_global => true,
        .call => (op.c >= block.call_target_cache.len or (!isMathSqrtCall(&block.call_target_cache[op.c]) and !isMathImulCall(&block.call_target_cache[op.c]) and findCharCodeAtGetProp(block, start_ip, end_ip, ip) == null)),
        .set_prop, .set_prop_transition => blk: {
            const k = constantName(block, op.b) orelse break :blk true;
            break :blk (std.mem.eql(u8, k, "charCodeAt") or std.mem.eql(u8, k, "prototype"));
        },
        else => false,
    };
}

pub const OsrPrePass = struct {
    live_out: []u64,
    fused_cmps: []?FusedCmp,
    is_jump_target: []bool,
    is_back_target: []bool,
    loop_weights: []u32,
    elided_compound_op: []bool,
    compound_arr_override: []?u8,
    compound_span_start: []?u32,
    fused_idx_delta: []?i32,
    elided_math_call: []bool,
    char_code_at_str_reg: []?u8,
    borrowed_str_arg_call: []bool,
    exact_int_mul_at: []bool,
    elided_mul_f64_store: []bool,
    loop_safe_i32_mask: u64 = 0,
    loop_safe_u31_mask: u64 = 0,
    math_sqrt_guard_bits: ?u64 = null,
    math_imul_guard_bits: ?u64 = null,
    has_char_code_at_guard: bool = false,

    pub noinline fn init(allocator: Allocator, block: *const codeblock.CodeBlock, start_ip: usize, end_ip: usize) !OsrPrePass {
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

        const elided_math_call = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(elided_math_call);
        @memset(elided_math_call, false);

        const char_code_at_str_reg = try allocator.alloc(?u8, loop_len);
        errdefer allocator.free(char_code_at_str_reg);
        @memset(char_code_at_str_reg, null);

        const borrowed_str_arg_call = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(borrowed_str_arg_call);
        @memset(borrowed_str_arg_call, false);

        const exact_int_mul_at = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(exact_int_mul_at);
        @memset(exact_int_mul_at, false);

        const elided_mul_f64_store = try allocator.alloc(bool, loop_len);
        errdefer allocator.free(elided_mul_f64_store);
        @memset(elided_mul_f64_store, false);

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
            .elided_math_call = elided_math_call,
            .char_code_at_str_reg = char_code_at_str_reg,
            .borrowed_str_arg_call = borrowed_str_arg_call,
            .exact_int_mul_at = exact_int_mul_at,
            .elided_mul_f64_store = elided_mul_f64_store,
        };
    }

    pub fn deinit(self: *OsrPrePass, allocator: Allocator) void {
        allocator.free(self.live_out);
        allocator.free(self.fused_cmps);
        allocator.free(self.is_jump_target);
        allocator.free(self.is_back_target);
        allocator.free(self.loop_weights);
        allocator.free(self.elided_compound_op);
        allocator.free(self.compound_arr_override);
        allocator.free(self.compound_span_start);
        allocator.free(self.fused_idx_delta);
        allocator.free(self.elided_math_call);
        allocator.free(self.char_code_at_str_reg);
        allocator.free(self.borrowed_str_arg_call);
        allocator.free(self.exact_int_mul_at);
        allocator.free(self.elided_mul_f64_store);
    }

    pub noinline fn populateArrayElisions(
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

    pub noinline fn populatePropElisions(
        self: *OsrPrePass,
        block: *const codeblock.CodeBlock,
        start_ip: usize,
        end_ip: usize,
    ) void {
        const loop_len = end_ip - start_ip + 1;

        // Compound object property assignment: load_local r_obj, @obj; get_prop r_cur, r_obj, #k; ...; set_prop r_obj, #k, r_res
        var idx0: usize = 0;
        while (idx0 + 2 < loop_len) : (idx0 += 1) {
            if (self.elided_compound_op[idx0] or self.fused_cmps[idx0] != null) continue;
            const op0 = block.ops[start_ip + idx0];
            if (op0.opcode != .load_local or op0.a < block.local_count or op0.a >= 64 or op0.b >= 64) continue;
            if (self.is_jump_target[idx0 + 1] or self.fused_cmps[idx0 + 1] != null) continue;
            const op1 = block.ops[start_ip + idx0 + 1];
            if (op1.opcode != .get_prop or op1.b != op0.a or op1.a < block.local_count or op1.a >= 64 or op1.a == op0.a) continue;

            const obj_tmp = op0.a;
            const obj_local = op0.b;
            const prop_key_c = op1.c;
            var written_temps: u64 = regBit64(op1.a);
            var read_before_write_temps: u64 = 0;

            var k = idx0 + 2;
            while (k < loop_len) : (k += 1) {
                if (self.is_jump_target[k] or self.fused_cmps[k] != null) break;
                const ck = block.ops[start_ip + k];
                if (ck.opcode == .set_prop and ck.a == obj_tmp) {
                    if (ck.b != prop_key_c or ck.c == obj_tmp) break;
                    if (ck.c >= block.local_count and (written_temps & regBit64(ck.c)) == 0) read_before_write_temps |= regBit64(ck.c);
                    if ((self.live_out[start_ip + k] & regBit64(obj_tmp)) != 0) break;
                    if ((written_temps & read_before_write_temps) != 0) break;

                    self.elided_compound_op[idx0] = true;
                    self.compound_arr_override[idx0 + 1] = obj_local;
                    self.compound_arr_override[k] = obj_local;
                    for (idx0 + 1 .. k + 1) |m| {
                        if (self.compound_span_start[m] == null) {
                            self.compound_span_start[m] = @intCast(start_ip + idx0);
                        }
                    }
                    idx0 = k;
                    break;
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
                    .get_prop,
                    .get_elem,
                    .get_elem_const,
                    => true,
                    else => false,
                };
                if (!allowed) break;
                if (ck.opcode != .nop) {
                    if (ck.a < block.local_count or ck.a >= 64 or ck.a == obj_tmp or ck.a == obj_local) break;
                }
                const ud = opUseDefMasks(block, ck);
                if ((ud.use & regBit64(obj_tmp)) != 0) break;
                const temp_reads = ud.use & ~((@as(u64, 1) << @intCast(@min(block.local_count, 64))) - 1);
                read_before_write_temps |= (temp_reads & ~written_temps);
                if (ck.opcode != .nop) {
                    written_temps |= regBit64(ck.a);
                }
            }
        }
    }

    pub noinline fn populateMathSqrtElisions(
        self: *OsrPrePass,
        block: *const codeblock.CodeBlock,
        start_ip: usize,
        end_ip: usize,
    ) void {
        for (start_ip..end_ip + 1) |scan_ip| {
            if (opMayMutateMathSqrt(block, start_ip, end_ip, scan_ip, block.ops[scan_ip])) return;
        }
        const loop_len = end_ip - start_ip + 1;
        for (0..loop_len) |call_idx| {
            const call_op = block.ops[start_ip + call_idx];
            if (call_op.opcode != .call) continue;
            const cs = &block.call_target_cache[call_op.c];
            const is_sqrt = isMathSqrtCall(cs);
            const is_imul = isMathImulCall(cs);
            if (!is_sqrt and !is_imul) continue;
            const expected_prop = if (is_sqrt) "sqrt" else "imul";
            const this_r = cs.this_reg orelse continue;
            const expected_bits = cs.callee.?.bits;
            if (is_sqrt) {
                if (self.math_sqrt_guard_bits != null and self.math_sqrt_guard_bits.? != expected_bits) continue;
            } else {
                if (self.math_imul_guard_bits != null and self.math_imul_guard_bits.? != expected_bits) continue;
            }

            var found_gp: ?usize = null;
            var k = call_idx;
            while (k > 0) {
                k -= 1;
                const cand = block.ops[start_ip + k];
                if (cand.opcode == .get_prop and cand.a == call_op.b and cand.b == this_r) {
                    const prop_name = constantName(block, cand.c) orelse break;
                    if (std.mem.eql(u8, prop_name, expected_prop)) {
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
                    .get_prop,
                    => cand.a != this_r and cand.a != call_op.b,
                    .jump, .jump_if_false, .jump_if_true, .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => true,
                    else => false,
                };
                if (!is_pure_arg_op) break;
            }
            if (found_gp) |gp_idx| {
                if (gp_idx > 0 and !self.is_jump_target[gp_idx]) {
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
                            if (is_sqrt) {
                                self.math_sqrt_guard_bits = expected_bits;
                                self.elided_compound_op[lg_idx] = true;
                                self.elided_compound_op[gp_idx] = true;
                                self.elided_math_call[call_idx] = true;
                                for (gp_idx + 1 .. call_idx + 1) |b_idx| {
                                    if (self.compound_span_start[b_idx] == null) {
                                        self.compound_span_start[b_idx] = @intCast(start_ip + lg_idx);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pub noinline fn populateCharCodeAtElisions(
        self: *OsrPrePass,
        block: *const codeblock.CodeBlock,
        start_ip: usize,
        end_ip: usize,
    ) void {
        for (start_ip..end_ip + 1) |scan_ip| {
            if (opMayMutateStringCharCodeAt(block, start_ip, end_ip, scan_ip, block.ops[scan_ip])) return;
        }
        const loop_len = end_ip - start_ip + 1;
        for (0..loop_len) |call_idx| {
            const call_ip = start_ip + call_idx;
            const call_op = block.ops[call_ip];
            if (call_op.opcode != .call) continue;
            const span = findCharCodeAtGetProp(block, start_ip, end_ip, call_ip) orelse continue;
            const gp_idx = span.gp_ip - start_ip;
            if (self.is_jump_target[gp_idx] or self.elided_compound_op[gp_idx]) continue;
            const gp_op = block.ops[span.gp_ip];
            if (call_op.a != gp_op.a and (self.live_out[call_ip] & regBit64(gp_op.a)) != 0) continue;

            var eff_str_reg: u8 = gp_op.b;
            var first_idx: usize = gp_idx;
            if (span.ld_ip) |ld_ip| {
                const ld_idx = ld_ip - start_ip;
                if (!self.is_jump_target[ld_idx] and !self.elided_compound_op[ld_idx] and
                    (self.live_out[call_ip] & regBit64(gp_op.b)) == 0)
                {
                    self.elided_compound_op[ld_idx] = true;
                    eff_str_reg = span.str_reg;
                    first_idx = ld_idx;
                }
            }
            self.has_char_code_at_guard = true;
            self.elided_compound_op[gp_idx] = true;
            self.char_code_at_str_reg[call_idx] = eff_str_reg;
            for (first_idx + 1 .. call_idx + 1) |b_idx| {
                if (self.compound_span_start[b_idx] == null) {
                    self.compound_span_start[b_idx] = @intCast(start_ip + first_idx);
                }
            }
        }
    }

    pub noinline fn populateBorrowedStrArgElisions(
        self: *OsrPrePass,
        block: *const codeblock.CodeBlock,
        start_ip: usize,
        end_ip: usize,
        hoisted_arrs: *const HoistedArrays,
    ) void {
        const loop_len = end_ip - start_ip + 1;
        var loop_def_mask: u64 = 0;
        for (start_ip..end_ip + 1) |scan_ip| {
            const ud = opUseDefMasks(block, block.ops[scan_ip]);
            loop_def_mask |= ud.def;
        }
        var idx: usize = 0;
        while (idx + 1 < loop_len) : (idx += 1) {
            if (self.elided_compound_op[idx] or self.elided_compound_op[idx + 1]) continue;
            if (self.is_jump_target[idx + 1]) continue;
            if (self.fused_cmps[idx] != null or self.fused_cmps[idx + 1] != null) continue;
            if (self.fused_idx_delta[idx] != null) continue;

            const prod_op = block.ops[start_ip + idx];
            const arg_reg = prod_op.a;
            if (arg_reg < block.local_count or arg_reg >= 64) continue;

            var valid_prod = false;
            if (prod_op.opcode == .get_elem or prod_op.opcode == .get_elem_const) {
                const eff_arr = self.compound_arr_override[idx] orelse prod_op.b;
                if (arg_reg != eff_arr and (prod_op.opcode != .get_elem or arg_reg != prod_op.c)) {
                    if (hoisted_arrs.find(eff_arr)) |h_slot| {
                        if (hoisted_arrs.dense[h_slot] and !hoisted_arrs.written[h_slot]) {
                            valid_prod = true;
                        }
                    }
                }
            } else if (prod_op.opcode == .load_local or prod_op.opcode == .move) {
                if (prod_op.b < 64 and prod_op.b != arg_reg and (loop_def_mask & regBit64(prod_op.b)) == 0) {
                    valid_prod = true;
                }
            }
            if (!valid_prod) continue;

            const call_op = block.ops[start_ip + idx + 1];
            if (call_op.opcode != .call_global and call_op.opcode != .call) continue;
            if (call_op.c >= block.call_target_cache.len) continue;
            const cs = &block.call_target_cache[call_op.c];
            if (cs.this_reg != null or cs.arg_count != 1) continue;
            if (@as(usize, call_op.b) + 1 != arg_reg) continue;
            if (call_op.opcode == .call and call_op.b == arg_reg) continue;
            const tb = cs.target_block orelse continue;
            if (!tb.jit_pure_leaf or tb.jit_string_param_mask != 1) continue;

            if ((self.live_out[start_ip + idx + 1] & regBit64(arg_reg)) != 0) continue;

            self.borrowed_str_arg_call[idx] = true;
            if (self.compound_span_start[idx + 1] == null) {
                self.compound_span_start[idx + 1] = @intCast(start_ip + idx);
            }
        }
    }

    pub noinline fn populateInt32AndMulAnalysis(
        self: *OsrPrePass,
        block: *const codeblock.CodeBlock,
        start_ip: usize,
        end_ip: usize,
        hoisted_arrs: *const HoistedArrays,
        frame_regs_opt: ?[]const JSValue,
    ) void {
        _ = hoisted_arrs;
        const loop_len = end_ip - start_ip + 1;

        // 1. Detect mul_num sites where both operands are exact i32 and the product fits in safe i32 (or is immediately consumed by a bitwise op and dead after)
        var const_i32: [64]?i32 = @splat(null);
        for (0..loop_len) |idx| {
            if (self.is_jump_target[idx]) {
                const_i32 = @splat(null);
            }
            if (self.elided_compound_op[idx]) continue;
            const ip = start_ip + idx;
            const op = block.ops[ip];
            switch (op.opcode) {
                .load_const => {
                    if (op.a < 64) {
                        const_i32[op.a] = if (block.constants[op.b] == .number) asExactInt32(block.constants[op.b].number) else null;
                    }
                },
                .move, .load_local, .store_local => {
                    if (op.a < 64) {
                        const_i32[op.a] = if (op.b < 64) const_i32[op.b] else null;
                    }
                },
                .mul_num => {
                    if (op.a < 64) const_i32[op.a] = null;
                    const rhs_c = if (op.c < 64) const_i32[op.c] else null;
                    const lhs_c = if (op.b < 64) const_i32[op.b] else null;
                    if ((rhs_c != null or lhs_c != null) and op.a >= block.local_count and op.a < 64 and idx + 1 < loop_len and !self.is_jump_target[idx + 1]) {
                        const c_val = rhs_c orelse lhs_c.?;
                        if (c_val > 0 and c_val <= 65536) {
                            // Check if op.a is consumed only by an immediate bitwise op (or load_elem + bitwise op) and dead after
                            var bit_consumer_idx: ?usize = null;
                            const next1 = block.ops[ip + 1];
                            switch (next1.opcode) {
                                .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                                    if (next1.b == op.a or next1.c == op.a) bit_consumer_idx = idx + 1;
                                },
                                .get_elem, .get_elem_const => {
                                    if (next1.a != op.a and next1.b != op.a and (next1.opcode != .get_elem or next1.c != op.a) and
                                        idx + 2 < loop_len and !self.is_jump_target[idx + 2])
                                    {
                                        const next2 = block.ops[ip + 2];
                                        switch (next2.opcode) {
                                            .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
                                                if (next2.b == op.a or next2.c == op.a) bit_consumer_idx = idx + 2;
                                            },
                                            else => {},
                                        }
                                    }
                                },
                                else => {},
                            }
                            if (bit_consumer_idx) |bc_idx| {
                                if ((self.live_out[start_ip + bc_idx] & regBit64(op.a)) == 0) {
                                    self.exact_int_mul_at[idx] = true;
                                }
                            }
                        }
                    }
                },
                else => {
                    const ud = opUseDefMasks(block, op);
                    if (ud.def != 0) {
                        for (0..64) |r| {
                            if ((ud.def & (@as(u64, 1) << @intCast(r))) != 0) const_i32[r] = null;
                        }
                    }
                },
            }
        }

        // 2. Compute loop-invariant exact i32 & u31 registers across back-edges:
        //    Only registers that are NEVER written inside the loop (`~written_in_loop`)
        //    AND are read before any write (`read_before_write_in_loop`) can be verified once in the preheader!
        const fregs = frame_regs_opt orelse return;
        var cand_i32: u64 = 0;
        var cand_u31: u64 = 0;
        const limit = @min(@min(block.register_count, 64), fregs.len);
        for (0..limit) |r| {
            if (fregs[r].isNumber()) {
                if (asExactInt32(fregs[r].asNumber())) |iv| {
                    if (iv >= -0x3FFF_FFFF and iv <= 0x3FFF_FFFF) {
                        cand_i32 |= (@as(u64, 1) << @intCast(r));
                        if (iv >= 0) cand_u31 |= (@as(u64, 1) << @intCast(r));
                    }
                }
            }
        }

        var written_in_loop: u64 = 0;
        for (0..loop_len) |idx| {
            if (self.elided_compound_op[idx]) continue;
            const ud = opUseDefMasks(block, block.ops[start_ip + idx]);
            written_in_loop |= ud.def;
        }
        cand_i32 &= ~written_in_loop;
        cand_u31 &= ~written_in_loop;

        // Also include registers whose ONLY writes inside the loop are i32-producing bitwise ops (.and_bits, .or_bits, .xor_bits, .shl, .shr)
        var non_bitwise_written: u64 = 0;
        var non_u31_bitwise_written: u64 = 0;
        for (0..loop_len) |idx| {
            if (self.elided_compound_op[idx]) continue;
            const ip = start_ip + idx;
            const op = block.ops[ip];
            const ud = opUseDefMasks(block, op);
            if (ud.def == 0) continue;
            switch (op.opcode) {
                .not_bits, .or_bits, .xor_bits, .shl, .shr => {
                    non_u31_bitwise_written |= ud.def;
                },
                .and_bits => {
                    const rhs_nonneg_const = op.c < 64 and idx > 0 and block.ops[ip - 1].opcode == .load_const and block.ops[ip - 1].a == op.c and block.constants[block.ops[ip - 1].b] == .number and (if (asExactInt32(block.constants[block.ops[ip - 1].b].number)) |v| v >= 0 else false);
                    if (!rhs_nonneg_const) {
                        non_u31_bitwise_written |= ud.def;
                    }
                },
                else => {
                    non_bitwise_written |= ud.def;
                    non_u31_bitwise_written |= ud.def;
                },
            }
        }
        for (0..limit) |r| {
            const r_bit = @as(u64, 1) << @intCast(r);
            if ((written_in_loop & r_bit) != 0 and (non_bitwise_written & r_bit) == 0) {
                if (fregs[r].isNumber()) {
                    if (asExactInt32(fregs[r].asNumber())) |iv| {
                        cand_i32 |= r_bit;
                        if (iv >= 0 and (non_u31_bitwise_written & r_bit) == 0) {
                            cand_u31 |= r_bit;
                        }
                    }
                }
            }
        }
        self.loop_safe_i32_mask = cand_i32;
        self.loop_safe_u31_mask = cand_u31;
    }
};

pub noinline fn analyzeHoistedArrays(
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
                if (op.c >= block.call_target_cache.len) return .{};
                const cs = &block.call_target_cache[op.c];
                const allowed = isMathSqrtCall(cs) or
                    isMathImulCall(cs) or
                    findCharCodeAtGetProp(block, start_ip, end_ip, ip) != null or
                    (cs.this_reg == null and cs.target_block != null);
                if (!allowed) return .{};
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
            .call_global => {
                if (op.c >= block.call_target_cache.len) return .{};
                const cs = &block.call_target_cache[op.c];
                if (cs.this_reg != null or cs.target_block == null) return .{};
                if (op.a < 64) {
                    cur_copy_src[op.a] = null;
                    for (0..64) |m| if (cur_copy_src[m] == op.a) {
                        cur_copy_src[m] = null;
                    };
                }
            },
            .new_array => return .{},
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

pub const OsrCachedAnalysis = struct {
    cached_regs: [12]u8 = @splat(0),
    cached_count: usize = 0,
    reg_to_xmm: [64]?Xmm = @splat(null),
    read_before_written: [64]bool = @splat(false),
    promoted: PromotedPropsAnalysis = .{},
    hoisted_arrs: HoistedArrays = .{},
};

pub noinline fn analyzeOsrLoop(
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
    var can_hoist_arrays = true;
    var loop_mutates_math_sqrt = false;
    for (start_ip..end_ip + 1) |ip| {
        const op = block.ops[ip];
        switch (op.opcode) {
            .call => {
                if (op.c >= block.call_target_cache.len) {
                    is_pure_loop = false;
                    can_hoist_arrays = false;
                    loop_mutates_math_sqrt = true;
                    break;
                }
                const cs = &block.call_target_cache[op.c];
                if (!isMathSqrtCall(cs) and !isMathImulCall(cs) and findCharCodeAtGetProp(block, start_ip, end_ip, ip) == null) {
                    const is_pure_leaf = (cs.this_reg == null and cs.target_block != null and cs.target_block.?.jit_pure_leaf);
                    if (!is_pure_leaf) {
                        is_pure_loop = false;
                        loop_mutates_math_sqrt = true;
                    }
                    if (cs.this_reg != null or cs.target_block == null) {
                        can_hoist_arrays = false;
                        break;
                    }
                }
            },
            .call_global => {
                if (op.c >= block.call_target_cache.len or block.call_target_cache[op.c].this_reg != null or block.call_target_cache[op.c].target_block == null) {
                    is_pure_loop = false;
                    loop_mutates_math_sqrt = true;
                    can_hoist_arrays = false;
                    break;
                }
                const cs = &block.call_target_cache[op.c];
                if (!cs.target_block.?.jit_pure_leaf) {
                    is_pure_loop = false;
                    loop_mutates_math_sqrt = true;
                }
            },
            else => {
                if (opMayMutateMathSqrt(block, start_ip, end_ip, ip, op)) loop_mutates_math_sqrt = true;
            },
        }
    }
    if (!is_pure_loop) {
        if (can_hoist_arrays) {
            const hoisted_arrs = analyzeHoistedArrays(block, start_ip, end_ip, 0, prepass, frame_regs_opt);
            prepass.populateArrayElisions(block, start_ip, end_ip, &hoisted_arrs);
            prepass.populateBorrowedStrArgElisions(block, start_ip, end_ip, &hoisted_arrs);
            result.hoisted_arrs = hoisted_arrs;
        }
        return result;
    }

    prepass.populatePropElisions(block, start_ip, end_ip);
    var promoted = analyzePromotedProps(block, start_ip, end_ip, prop_ic, prepass);
    const hoisted_arrs = analyzeHoistedArrays(block, start_ip, end_ip, promoted.count, prepass, frame_regs_opt);
    prepass.populateArrayElisions(block, start_ip, end_ip, &hoisted_arrs);
    prepass.populateMathSqrtElisions(block, start_ip, end_ip);
    prepass.populateCharCodeAtElisions(block, start_ip, end_ip);
    prepass.populateBorrowedStrArgElisions(block, start_ip, end_ip, &hoisted_arrs);
    prepass.populateInt32AndMulAnalysis(block, start_ip, end_ip, &hoisted_arrs, frame_regs_opt);

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
                    if (op.opcode == .mul_num and prepass.elided_mul_f64_store[idx]) {
                        invalid[op.a] = true;
                    } else {
                        use_count[op.a] +%= w;
                        written[op.a] = true;
                    }
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
                const eff_obj = prepass.compound_arr_override[idx] orelse op.b;
                if (eff_obj < 64) invalid[eff_obj] = true;
                if (op.a < 64) {
                    use_count[op.a] +%= w;
                    written[op.a] = true;
                }
            },
            .set_prop, .set_prop_transition => {
                const eff_obj = prepass.compound_arr_override[idx] orelse op.a;
                if (eff_obj < 64) invalid[eff_obj] = true;
                if (op.c < 64) {
                    if (!written[op.c]) read_before_written[op.c] = true;
                    use_count[op.c] +%= w;
                }
            },
            .load_global => {
                if (op.a < 64) invalid[op.a] = true;
            },
            .call => {
                const cs = &block.call_target_cache[op.c];
                if (prepass.char_code_at_str_reg[idx]) |s_reg| {
                    const arg_reg: usize = @as(usize, op.b) + 1;
                    if (arg_reg < 64) {
                        if (!written[arg_reg]) read_before_written[arg_reg] = true;
                        use_count[arg_reg] +%= w;
                    }
                    if (s_reg < 64) invalid[s_reg] = true;
                    if (op.a < 64) {
                        use_count[op.a] +%= w;
                        written[op.a] = true;
                    }
                } else if (isMathSqrtCall(cs)) {
                    const arg_reg: usize = @as(usize, op.b) + 1;
                    if (arg_reg < 64) {
                        if (!written[arg_reg]) read_before_written[arg_reg] = true;
                        use_count[arg_reg] +%= w;
                    }
                    if (prepass.elided_math_call[idx]) {
                        if (op.a < 64) {
                            use_count[op.a] +%= w;
                            written[op.a] = true;
                        }
                    } else if (loop_mutates_math_sqrt) {
                        if (op.a < 64) invalid[op.a] = true;
                        if (op.b < 64) invalid[op.b] = true;
                    } else {
                        if (op.a != op.b and op.b < 64) invalid[op.b] = true;
                        if (op.a < 64) {
                            use_count[op.a] +%= w;
                            written[op.a] = true;
                        }
                    }
                } else if (isMathImulCall(cs)) {
                    const arg0_reg: usize = @as(usize, op.b) + 1;
                    const arg1_reg: usize = @as(usize, op.b) + 2;
                    if (arg0_reg < 64) {
                        if (!written[arg0_reg]) read_before_written[arg0_reg] = true;
                        use_count[arg0_reg] +%= w;
                    }
                    if (arg1_reg < 64) {
                        if (!written[arg1_reg]) read_before_written[arg1_reg] = true;
                        use_count[arg1_reg] +%= w;
                    }
                    if (op.b < 64) invalid[op.b] = true;
                    if (op.a < 64) invalid[op.a] = true;
                } else {
                    if (op.b < 64) invalid[op.b] = true;
                    if (op.a < 64) invalid[op.a] = true;
                    const str_mask = if (cs.target_block) |tb| tb.jit_string_param_mask else 0;
                    for (0..cs.arg_count) |ai| {
                        const ar = @as(usize, op.b) + 1 + ai;
                        if (ar < 64) {
                            if (ai < 32 and (str_mask & (@as(u32, 1) << @intCast(ai))) != 0) {
                                invalid[ar] = true;
                            } else {
                                if (!written[ar]) read_before_written[ar] = true;
                                use_count[ar] +%= w;
                            }
                        }
                    }
                }
            },
            .call_global => {
                const cs = &block.call_target_cache[op.c];
                const str_mask = if (cs.target_block) |tb| tb.jit_string_param_mask else 0;
                for (0..cs.arg_count) |ai| {
                    const ar = @as(usize, op.b) + 1 + ai;
                    if (ar < 64) {
                        if (ai < 32 and (str_mask & (@as(u32, 1) << @intCast(ai))) != 0) {
                            invalid[ar] = true;
                        } else {
                            if (!written[ar]) read_before_written[ar] = true;
                            use_count[ar] +%= w;
                        }
                    }
                }
                if (cs.target_block != null and cs.target_block.?.jit_pure_leaf) {
                    if (op.a < 64) {
                        use_count[op.a] +%= w;
                        written[op.a] = true;
                    }
                } else {
                    if (op.a < 64) invalid[op.a] = true;
                    if (op.b < 64) invalid[op.b] = true;
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
