//! Baseline x86-64 JIT: public facade. Shared types/constants live in
//! jit_common.zig; tiers and OSR are split into sibling modules.

const std = @import("jit_common.zig").std;
const Allocator = @import("jit_common.zig").Allocator;
const JSValue = @import("jit_common.zig").JSValue;
const codeblock = @import("jit_common.zig").codeblock;
const x64_asm = @import("jit_common.zig").x64_asm;
const Assembler = @import("jit_common.zig").Assembler;
const Label = @import("jit_common.zig").Label;
pub const JitFn = @import("jit_common.zig").JitFn;
pub const OsrFn = @import("jit_common.zig").OsrFn;
pub const JitGlobalSlot = @import("jit_common.zig").JitGlobalSlot;
pub const HOT_THRESHOLD = @import("jit_common.zig").HOT_THRESHOLD;
pub const OSR_THRESHOLD = @import("jit_common.zig").OSR_THRESHOLD;
const PropIC = @import("jit_common.zig").PropIC;
const prop_size = @import("jit_common.zig").prop_size;
const constantName = @import("jit_common.zig").constantName;
pub const jitResolveGlobalSlot = @import("jit_common.zig").jitResolveGlobalSlot;
pub const canUseFastSelfRec = @import("whole_fn.zig").canUseFastSelfRec;
const findCharCodeAtGetProp = @import("whole_fn.zig").findCharCodeAtGetProp;
const analyzeWholeFnStrings = @import("whole_fn.zig").analyzeWholeFnStrings;
pub const canCompile = @import("whole_fn.zig").canCompile;
const compileFastSelfRec = @import("whole_fn.zig").compileFastSelfRec;
const compileImpl = @import("whole_fn.zig").compileImpl;
const canCompileFastIntAscii = @import("fast_int_ascii.zig").canCompileFastIntAscii;
const isMathSqrtCall = @import("osr_analysis.zig").isMathSqrtCall;
const isMathImulCall = @import("osr_analysis.zig").isMathImulCall;
const isMathIntrinsicCall = @import("osr_analysis.zig").isMathIntrinsicCall;
const canInlineCalleeInOsr = @import("osr_analysis.zig").canInlineCalleeInOsr;
const MAX_INLINED_CALLEE_OPS = @import("osr_analysis.zig").MAX_INLINED_CALLEE_OPS;
const OsrPrePass = @import("osr_analysis.zig").OsrPrePass;
const analyzeOsrLoop = @import("osr_analysis.zig").analyzeOsrLoop;
const OsrCompiler = @import("osr_emit.zig").OsrCompiler;

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

    const str_analysis = analyzeWholeFnStrings(block) orelse {
        block.jit_failed = true;
        return false;
    };

    const exec = compileImpl(allocator, block, slots) catch {
        if (slots) |s| allocator.free(s);
        block.jit_failed = true;
        return false;
    };
    block.jit_pure_leaf = (slots == null and canCompileFastIntAscii(allocator, block, &str_analysis));
    block.jit_string_param_mask = str_analysis.param_mask;
    block.jit_global_slots = slots;
    block.jit_code = exec;
    block.jit_fn = @ptrCast(exec.ptr);
    return true;
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
                if (!isMathIntrinsicCall(cs) and !canInlineCalleeInOsr(cs) and findCharCodeAtGetProp(block, start_ip, end_ip, ip) == null) {
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
                if ((@as(usize, op.b) + 1 + cs.arg_count) > block.register_count) return false;
                if (!canInlineCalleeInOsr(cs)) {
                    if (cs.this_reg != null) return false;
                    const tb = cs.target_block orelse return false;
                    if (tb.param_count != cs.arg_count) return false;
                    if (tb.jit_fn == null and !canCompile(tb)) return false;
                }
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
            if (!canInlineCalleeInOsr(cs)) {
                if (cs.target_block) |tb| {
                    if (tb.jit_fn == null) {
                        _ = compile(allocator, @constCast(tb));
                    }
                }
            }
        }
    }

    var osr_prop_ics: ?[]codeblock.OsrPropIC = null;
    var osr_global_slots: ?[]JitGlobalSlot = null;
    const exec = compileOsrImpl(allocator, block, start_ip, end_ip, prop_ic_ptr, frame_regs_opt, &osr_prop_ics, &osr_global_slots) catch {
        if (osr_prop_ics) |pics| allocator.free(pics);
        if (osr_global_slots) |gslots| allocator.free(gslots);
        entry.failed = true;
        return false;
    };
    entry.header_ip = @intCast(start_ip);
    entry.end_ip = @intCast(end_ip);
    entry.code = exec;
    entry.fn_ptr = @ptrCast(exec.ptr);
    entry.prop_ics = osr_prop_ics;
    entry.global_slots = osr_global_slots;
    return true;
}

pub noinline fn compileOsrImpl(
    allocator: Allocator,
    block: *const codeblock.CodeBlock,
    start_ip: usize,
    end_ip: usize,
    prop_ic_ptr: ?*const anyopaque,
    frame_regs_opt: ?[]const JSValue,
    out_osr_prop_ics: *?[]codeblock.OsrPropIC,
    out_osr_global_slots: *?[]JitGlobalSlot,
) ![]align(std.heap.page_size_min) u8 {
    const prop_ic: ?*const [256]PropIC = if (prop_ic_ptr) |p| @ptrCast(@alignCast(p)) else null;

    var prepass = try OsrPrePass.init(allocator, block, start_ip, end_ip);
    defer prepass.deinit(allocator);

    const analysis = analyzeOsrLoop(block, start_ip, end_ip, prop_ic, &prepass, frame_regs_opt);
    const hoisted_arrs = analysis.hoisted_arrs;
    const loop_len = end_ip - start_ip + 1;

    var prop_site_count: usize = 0;
    if (analysis.promoted.count == 0) {
        for (0..loop_len) |idx| {
            const op = block.ops[start_ip + idx];
            switch (op.opcode) {
                .get_prop, .set_prop, .set_prop_transition => prop_site_count += 1,
                .call, .call_global => {
                    if (prepass.inlined_calls[idx]) {
                        const tb = block.call_target_cache[op.c].target_block.?;
                        for (tb.ops) |c_op| {
                            if (c_op.opcode == .get_prop) prop_site_count += 1;
                        }
                    }
                },
                else => {},
            }
        }
    }
    const osr_ics: ?[]codeblock.OsrPropIC = if (prop_site_count > 0) blk: {
        const s = try allocator.alloc(codeblock.OsrPropIC, prop_site_count);
        @memset(s, .{});
        break :blk s;
    } else null;
    out_osr_prop_ics.* = osr_ics;

    var global_site_count: usize = 0;
    for (0..loop_len) |idx| {
        if (prepass.elided_compound_op[idx]) continue;
        if (block.ops[start_ip + idx].opcode == .load_global) {
            global_site_count += 1;
        }
    }
    const osr_gslots: ?[]JitGlobalSlot = if (global_site_count > 0) blk: {
        const gs = try allocator.alloc(JitGlobalSlot, global_site_count);
        @memset(gs, .{});
        break :blk gs;
    } else null;
    out_osr_global_slots.* = osr_gslots;

    const global_slot_addrs = try allocator.alloc(u64, loop_len);
    defer allocator.free(global_slot_addrs);
    @memset(global_slot_addrs, 0);
    if (osr_gslots) |gslots| {
        var g_k: usize = 0;
        for (0..loop_len) |idx| {
            if (prepass.elided_compound_op[idx]) continue;
            if (block.ops[start_ip + idx].opcode == .load_global) {
                global_slot_addrs[idx] = @intFromPtr(&gslots[g_k]);
                g_k += 1;
            }
        }
    }

    const prop_ic_addrs = try allocator.alloc(u64, loop_len);
    defer allocator.free(prop_ic_addrs);
    @memset(prop_ic_addrs, 0);

    const prop_ics_init = try allocator.alloc(codeblock.OsrPropIC, loop_len);
    defer allocator.free(prop_ics_init);
    @memset(prop_ics_init, .{});

    const inlined_prop_ic_addrs = try allocator.alloc([MAX_INLINED_CALLEE_OPS]u64, loop_len);
    defer allocator.free(inlined_prop_ic_addrs);
    @memset(inlined_prop_ic_addrs, @splat(0));

    const inlined_prop_ics_init = try allocator.alloc([MAX_INLINED_CALLEE_OPS]codeblock.OsrPropIC, loop_len);
    defer allocator.free(inlined_prop_ics_init);
    @memset(inlined_prop_ics_init, @splat(.{}));

    if (osr_ics) |pics| {
        var site_k: usize = 0;
        for (0..loop_len) |idx| {
            const ip = start_ip + idx;
            const op = block.ops[ip];
            switch (op.opcode) {
                .get_prop, .set_prop, .set_prop_transition => {
                    if (prop_ic) |table| {
                        const ic_idx: u8 = @intCast(((@intFromPtr(block) >> 4) +% ip) & 255);
                        const entry = table[ic_idx];
                        const key_c = if (op.opcode == .get_prop) op.c else op.b;
                        const k_opt = constantName(block, key_c);
                        if (k_opt != null and entry.block == block and entry.pc == ip and @intFromPtr(entry.key_ptr) == @intFromPtr(k_opt.?.ptr) and entry.shape_id != 0) {
                            pics[site_k] = .{
                                .shape_id = entry.shape_id,
                                .slot_idx = entry.slot_idx,
                                .slot_byte_off = @as(u64, entry.slot_idx) * @as(u64, @intCast(prop_size)),
                                .next_shape = entry.next_shape,
                                .cached_shape_id = entry.cached_shape_id,
                            };
                            prop_ics_init[idx] = pics[site_k];
                        }
                    }
                    prop_ic_addrs[idx] = @intFromPtr(&pics[site_k]);
                    site_k += 1;
                },
                .call, .call_global => {
                    if (prepass.inlined_calls[idx]) {
                        const tb = block.call_target_cache[op.c].target_block.?;
                        for (tb.ops, 0..) |c_op, c_ip| {
                            if (c_op.opcode == .get_prop) {
                                if (prop_ic) |table| {
                                    const c_ic_idx: u8 = @intCast(((@intFromPtr(tb) >> 4) +% c_ip) & 255);
                                    const entry = table[c_ic_idx];
                                    const k_opt = constantName(tb, c_op.c);
                                    if (k_opt != null and entry.block == tb and entry.pc == c_ip and @intFromPtr(entry.key_ptr) == @intFromPtr(k_opt.?.ptr) and entry.shape_id != 0) {
                                        pics[site_k] = .{
                                            .shape_id = entry.shape_id,
                                            .slot_idx = entry.slot_idx,
                                            .slot_byte_off = @as(u64, entry.slot_idx) * @as(u64, @intCast(prop_size)),
                                            .next_shape = entry.next_shape,
                                            .cached_shape_id = entry.cached_shape_id,
                                        };
                                        inlined_prop_ics_init[idx][c_ip] = pics[site_k];
                                    }
                                }
                                inlined_prop_ic_addrs[idx][c_ip] = @intFromPtr(&pics[site_k]);
                                site_k += 1;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

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
    @memcpy(elided_math_call, prepass.elided_math_call);

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
        .prop_ic_addrs = prop_ic_addrs,
        .prop_ics_init = prop_ics_init,
        .inlined_prop_ic_addrs = inlined_prop_ic_addrs,
        .inlined_prop_ics_init = inlined_prop_ics_init,
        .global_slot_addrs = global_slot_addrs,
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
        .math_sqrt_guard_bits = prepass.math_sqrt_guard_bits,
        .has_char_code_at_guard = prepass.has_char_code_at_guard,
        .incoming_has_edge = incoming_has_edge,
        .incoming_int32 = incoming_int32,
        .incoming_uint31 = incoming_uint31,
        .incoming_exact_idx = incoming_exact_idx,
        .incoming_elem_store = incoming_elem_store,
    };
    defer oc.exit_stubs.deinit(allocator);

    try oc.emitPreheader();

    for (0..loop_len) |idx| {
        const ip = start_ip + idx;
        const op = block.ops[ip];
        const bail_lbl = oc.bailout_labels[idx];
        a.bindLabel(oc.op_labels[idx]);
        oc.mergeIncomingState(idx);
        if (oc.skip_ops_remaining > 0) {
            oc.skip_ops_remaining -= 1;
            continue;
        }
        if (oc.elided_op[idx]) continue;
        var next_live_r8_i32: ?u8 = null;
        oc.next_live_xmm3 = null;
        try oc.emitLoopOp(idx, ip, op, bail_lbl, &next_live_r8_i32);
        oc.updateTrackingAfterOp(idx, ip, op, next_live_r8_i32);
    }

    try oc.emitExitsAndEpilogue();
    return a.finalizeExecutable();
}


test {
    _ = @import("baseline_test.zig");
}
