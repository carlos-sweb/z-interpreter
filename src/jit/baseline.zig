const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const codeblock = @import("../bytecode/codeblock.zig");
const x64_asm = @import("x64_asm.zig");
const Assembler = x64_asm.Assembler;
const Label = x64_asm.Label;

pub const JitFn = codeblock.JitFn;
pub const HOT_THRESHOLD: u32 = 32;

pub fn canCompile(block: *const codeblock.CodeBlock) bool {
    if (!comptime x64_asm.is_supported_host) return false;
    if (block.exception_table.len > 0 or block.flags.has_try) return false;
    if (block.flags.is_generator or block.flags.is_async or block.flags.needs_arguments) return false;
    if (block.register_count == 0 or block.register_count > 32) return false;
    if (block.param_count > block.register_count or block.local_count > block.register_count) return false;
    if (block.ops.len == 0) return false;

    for (block.ops, 0..) |op, ip| {
        switch (op.opcode) {
            .nop, .return_undefined => {},
            .load_undefined => {
                if (op.a >= block.register_count) return false;
            },
            .load_const => {
                if (op.a >= block.register_count or op.b >= block.constants.len) return false;
                if (block.constants[op.b] != .number) return false;
            },
            .move, .load_local, .store_local => {
                if (op.a >= block.register_count or op.b >= block.register_count) return false;
            },
            .add, .add_num, .sub_num, .mul_num => {
                if (op.a >= block.register_count or op.b >= block.register_count or op.c >= block.register_count) return false;
            },
            .add_local_const, .sub_local_const => {
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
            .jump => {
                const target = (@as(usize, op.b) << 8) | op.c;
                if (target >= block.ops.len) return false;
            },
            .call_global => {
                if (op.a >= block.register_count) return false;
                const bname = block.name orelse return false;
                if (op.c >= block.call_target_cache.len) return false;
                const cs = &block.call_target_cache[op.c];
                if (cs.this_reg != null or cs.arg_count != block.param_count) return false;
                const gname = cs.global_name orelse return false;
                if (!std.mem.eql(u8, gname, bname)) return false;
                if ((@as(usize, op.b) + 1 + cs.arg_count) > block.register_count) return false;
            },
            .return_value => {
                if (op.a >= block.register_count) return false;
            },
            else => return false,
        }
    }
    return true;
}

pub fn compile(allocator: Allocator, block: *codeblock.CodeBlock) bool {
    if (block.jit_fn != null) return true;
    if (block.jit_failed) return false;
    if (!canCompile(block)) {
        block.jit_failed = true;
        return false;
    }

    const exec = compileImpl(allocator, block) catch {
        block.jit_failed = true;
        return false;
    };
    block.jit_code = exec;
    block.jit_fn = @ptrCast(exec.ptr);
    return true;
}

fn compileImpl(allocator: Allocator, block: *const codeblock.CodeBlock) ![]align(std.heap.page_size_min) u8 {
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

    // External entry: fn(regs: [*]JSValue, out: *JSValue, regs_limit: [*]JSValue) callconv(.c) u8
    // %rdi = regs, %rsi = out, %rdx = regs_limit
    try a.movRegImm64(.r8, JSValue.BASE_TAG);
    try a.movRegImm64(.r9, JSValue.CANONICAL_NAN);
    try a.movRegReg(.r11, .rsi);
    try a.callLabel(internal_entry);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, ext_done);
    try a.movMemReg(.r11, 0, .rcx);
    a.bindLabel(ext_done);
    try a.ret();

    // Internal entry (also target of direct self-recursive calls)
    a.bindLabel(internal_entry);
    const frame_bytes: i32 = @intCast(@as(usize, block.register_count) * 8);
    try a.lea(.rax, .rdi, frame_bytes);
    try a.cmpRegReg(.rax, .rdx);
    try a.jcc(.a, bailout_label);

    if (block.local_count > block.param_count) {
        var slot: usize = block.param_count;
        while (slot < block.local_count) : (slot += 1) {
            try a.movMemReg(.rdi, @intCast(slot * 8), .r8);
        }
    }

    for (block.ops, 0..) |op, ip| {
        a.bindLabel(op_labels[ip]);
        switch (op.opcode) {
            .nop => {},
            .load_undefined => {
                try a.movMemReg(.rdi, @intCast(@as(usize, op.a) * 8), .r8);
            },
            .load_const => {
                const bits = JSValue.fromNumber(block.constants[op.b].number).bits;
                try a.movRegImm64(.rax, bits);
                try a.movMemReg(.rdi, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .move, .load_local, .store_local => {
                try a.movRegMem(.rax, .rdi, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r8);
                try a.jcc(.ae, bailout_label);
                try a.movMemReg(.rdi, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .add, .add_num, .sub_num, .mul_num => {
                try a.movRegMem(.rax, .rdi, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r8);
                try a.jcc(.ae, bailout_label);
                try a.movRegMem(.rcx, .rdi, @intCast(@as(usize, op.c) * 8));
                try a.cmpRegReg(.rcx, .r8);
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
                try a.cmovpRegReg(.rax, .r9);
                try a.movMemReg(.rdi, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .add_local_const, .sub_local_const => {
                const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
                try a.movRegMem(.rax, .rdi, @intCast(@as(usize, op.b) * 8));
                try a.cmpRegReg(.rax, .r8);
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
                try a.cmovpRegReg(.rax, .r9);
                try a.movMemReg(.rdi, @intCast(@as(usize, op.a) * 8), .rax);
            },
            .jeq_local_const_false,
            .jlt_local_const_false,
            .jle_local_const_false,
            .jgt_local_const_false,
            .jge_local_const_false,
            => {
                const c_bits = JSValue.fromNumber(block.constants[op.b].number).bits;
                const target_lbl = op_labels[ip + @as(usize, op.c)];
                try a.movRegMem(.rax, .rdi, @intCast(@as(usize, op.a) * 8));
                try a.cmpRegReg(.rax, .r8);
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
                    try a.movRegMem(.rax, .rdi, @intCast((arg_start + i) * 8));
                    try a.movMemReg(.rdi, @intCast((@as(usize, block.register_count) + i) * 8), .rax);
                }
                try a.addRegImm32(.rdi, frame_bytes);
                try a.callLabel(internal_entry);
                try a.subRegImm32(.rdi, frame_bytes);
                try a.testRegReg(.rax, .rax);
                try a.jcc(.ne, bailout_label);
                try a.movMemReg(.rdi, @intCast(@as(usize, op.a) * 8), .rcx);
            },
            .return_value => {
                try a.movRegMem(.rcx, .rdi, @intCast(@as(usize, op.a) * 8));
                try a.cmpRegReg(.rcx, .r8);
                try a.jcc(.ae, bailout_label);
                try a.xorRegReg(.rax, .rax);
                try a.ret();
            },
            .return_undefined => {
                try a.movRegReg(.rcx, .r8);
                try a.xorRegReg(.rax, .rax);
                try a.ret();
            },
            else => unreachable,
        }
    }

    a.bindLabel(bailout_label);
    try a.movRegImm32(.rax, 1);
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
        // fib(20) = 6765; orig(5) calls fib(4)=100 + fib(3)=100 => 200
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

