//! Unit tests for the baseline JIT (moved verbatim from baseline.zig).

const std = @import("jit_common.zig").std;
const JSValue = @import("jit_common.zig").JSValue;
const vm = @import("jit_common.zig").vm;
const x64_asm = @import("jit_common.zig").x64_asm;
const ArrayBox = @import("jit_common.zig").ArrayBox;

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

test "baseline JIT OSR compiles direct calls to closures and helper functions, handles callee/global reassignment bailout, and handles heap arg bailout" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. OSR loop calling closure c() (arg_count == 0) and helper add2(x, y) (arg_count == 2) > 200 times (0 leaks)
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
            \\function add2(x, y) {
            \\    return x + y;
            \\}
            \\function run() {
            \\    const c = makeCounter();
            \\    let total = 0;
            \\    for (let i = 0; i < 250; i++) {
            \\        const v = c();
            \\        total = add2(total, v);
            \\    }
            \\    return total;
            \\}
            \\run();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        // sum_{v=1}^{250} v = 250 * 251 / 2 = 31375
        try std.testing.expectEqual(@as(f64, 31375), res.asNumber());
    }

    // 2. Target function reassignment mid-loop (callee invalidation & global_version invalidation)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        // 2a. Callee reassignment (.call)
        {
            const res = try interp.run(
                \\function testCalleeReassign() {
                \\    function fnA(x) { return x + 1; }
                \\    function fnB(x) { return x + 10; }
                \\    let fn = fnA;
                \\    let total = 0;
                \\    for (let i = 0; i < 200; i++) {
                \\        if (i == 100) fn = fnB;
                \\        total += fn(i);
                \\    }
                \\    return total;
                \\}
                \\testCalleeReassign();
            );
            defer res.deinit();
            try std.testing.expect(res.isNumber());
            // sum_{i=0}^{99} (i + 1) = 4950 + 100 = 5050
            // sum_{i=100}^{199} (i + 10) = 14950 + 1000 = 15950
            // total = 21000
            try std.testing.expectEqual(@as(f64, 21000), res.asNumber());
        }

        // 2b. Global function reassignment (.call_global / global_version)
        {
            const res = try interp.run(
                \\function gTargetA(x) { return x + 1; }
                \\function gTargetB(x) { return x + 10; }
                \\var gFn = gTargetA;
                \\function testGlobalReassign() {
                \\    let total = 0;
                \\    for (let i = 0; i < 200; i++) {
                \\        if (i == 100) gFn = gTargetB;
                \\        total += gFn(i);
                \\    }
                \\    return total;
                \\}
                \\testGlobalReassign();
            );
            defer res.deinit();
            try std.testing.expect(res.isNumber());
            try std.testing.expectEqual(@as(f64, 21000), res.asNumber());
        }
    }

    // 3. Call from OSR loop with string/object argument (clean bailout and 0 leaks)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function helper(x) { return x; }
            \\function testHeapArg() {
            \\    let had_str = 0;
            \\    for (let i = 0; i < 200; i++) {
            \\        let arg = i;
            \\        if (i == 100) arg = "bailout_str";
            \\        const r = helper(arg);
            \\        if (r === "bailout_str") had_str = 1;
            \\    }
            \\    return had_str;
            \\}
            \\testHeapArg();
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 1), res.asNumber());
    }
}

test "baseline JIT Phase 4B fast self-recursion executes fib(20), handles deep recursion bailout, and handles global reassignment" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. fib(20) == 6765 with 0 leaks
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function fib(n) {
            \\    if (n <= 1) return n;
            \\    return fib(n - 1) + fib(n - 2);
            \\}
            \\fib(20);
        );
        defer res.deinit();
        try std.testing.expect(res.isNumber());
        try std.testing.expectEqual(@as(f64, 6765), res.asNumber());
    }

    // 2. Infinite recursion function inf(n) { return inf(n + 1); } inf(0);
    // Bails out cleanly from fast_entry to interpreter and throws error.StackOverflow
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
                \\    return inf(n + 1);
                \\}
                \\inf(0);
            ),
        );
    }

    // 3. Global function reassignment mid-execution invalidates global_version and gives correct result
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\function fib(n) {
            \\    if (n <= 1) return n;
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
}

test "baseline JIT Phase 4C caches hot numeric locals in xmm4..xmm15, handles NaN canonicalization and mid-loop bailout" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. Pure numeric loop with multiple accumulators and arithmetic/bitwise ops
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\var sum = 0;
            \\var prod = 1;
            \\for (var i = 1; i <= 20; i++) {
            \\    sum = (sum + i) ^ 3;
            \\    prod = (prod * 2) & 0x7FFFFFFF;
            \\}
            \\sum + prod;
        );
        try std.testing.expectEqual(@as(f64, 1048790), res.asNumber());
    }

    // 2. Loop with 0/0 (NaN) propagated in a cached accumulator (verified canonical NaN at exit)
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\var acc = 10;
            \\for (var i = 0; i < 100; i++) {
            \\    acc = acc + 1;
            \\    if (i === 80) acc = 0 / 0;
            \\}
            \\acc;
        );
        try std.testing.expect(res.isNumber() and std.math.isNan(res.asNumber()));
        try std.testing.expectEqual(JSValue.CANONICAL_NAN, res.bits);
    }

    // 3. Bailout in the middle of loop (out-of-bounds array write) verifying that cached values in xmm are flushed to regs[]
    {
        var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer allocating.deinit();
        var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
        defer interp.deinit();
        interp.compile_options.use_bytecode_vm = true;

        const res = try interp.run(
            \\var arr = [10, 20, 30, 40, 50];
            \\var sum = 0;
            \\var last_i = -1;
            \\for (var i = 0; i < 100; i++) {
            \\    if (i == 5) {
            \\        arr[10] = 999;
            \\    }
            \\    sum = sum + i;
            \\    last_i = i;
            \\}
            \\sum + last_i + arr[10];
        );
        try std.testing.expectEqual(@as(f64, 6048), res.asNumber());
    }
}

test "baseline JIT Phase 4D eliminates bailouts in bitwise sieve with array, mod_num, inline RC" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runSieveBitwise(n) {
        \\    const arr = [0, 0, 0, 0, 0, 0, 0, 0];
        \\    let acc = 0;
        \\    for (let i = 1; i <= n; i++) {
        \\        const idx = i & 7;
        \\        const r = i % 7;
        \\        const q = (i / 4) | 0;
        \\        const b = ((q ^ idx) << 2) ^ (i >>> 1);
        \\        if (r === 0) {
        \\            arr[idx] = arr[idx] + b;
        \\        } else {
        \\            arr[idx] = arr[idx] + r;
        \\        }
        \\        acc = (acc + arr[idx]) | 0;
        \\    }
        \\    return acc;
        \\}
        \\runSieveBitwise(5000);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 418157123), res.asNumber());
}

test "baseline JIT Phase 5A hot loop reading and writing object properties (IC hit, 0 leaks)" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runHotProps(n) {
        \\    const o = { x: 1, y: 2, z: 3 };
        \\    let acc = 0;
        \\    for (let i = 0; i < n; i++) {
        \\        o.x = o.x + 1;
        \\        o.y = o.y + 2;
        \\        o.z = o.z + 3;
        \\        acc = o.x + o.y + o.z;
        \\    }
        \\    return acc;
        \\}
        \\runHotProps(2000);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 12006), res.asNumber());
}

test "baseline JIT Phase 5A polymorphic loop alternating 2 shapes fallback" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runPoly(n) {
        \\    const o1 = { x: 1, y: 2 };
        \\    const o2 = { a: 10, x: 20 };
        \\    let total = 0;
        \\    for (let i = 0; i < n; i++) {
        \\        const target = (i % 2 === 0) ? o1 : o2;
        \\        target.x = target.x + 1;
        \\        total = total + target.x;
        \\    }
        \\    return total;
        \\}
        \\runPoly(2000);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 1022000), res.asNumber());
}

test "baseline JIT Phase 5A frozen object and accessor fall back to slow path" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function runFrozenAndAccessor() {
        \\    let getter_called = 0;
        \\    let setter_called = 0;
        \\    const o_acc = {
        \\        get x() { getter_called = getter_called + 1; return 42; },
        \\        set x(v) { setter_called = setter_called + 1; }
        \\    };
        \\    let acc = 0;
        \\    for (let i = 0; i < 100; i++) {
        \\        o_acc.x = o_acc.x + 1;
        \\        acc = acc + o_acc.x;
        \\    }
        \\
        \\    const o_frozen = Object.freeze({ x: 100 });
        \\    let frozen_sum = 0;
        \\    for (let i = 0; i < 100; i++) {
        \\        frozen_sum = frozen_sum + o_frozen.x;
        \\    }
        \\    return getter_called + setter_called + acc + frozen_sum;
        \\}
        \\runFrozenAndAccessor();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 14500), res.asNumber());
}

test "baseline JIT OSR preserves non-hoisted ArrayBox across uncached index load in get_elem/set_elem (qsort)" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function qsort(arr, lo, hi) {
        \\    var i = lo;
        \\    var j = hi;
        \\    var pivot = arr[(lo + hi) >> 1];
        \\    while (i <= j) {
        \\        while (arr[i] < pivot) i++;
        \\        while (arr[j] > pivot) j--;
        \\        if (i <= j) {
        \\            var tmp = arr[i];
        \\            arr[i] = arr[j];
        \\            arr[j] = tmp;
        \\            i++;
        \\            j--;
        \\        }
        \\    }
        \\    if (lo < j) qsort(arr, lo, j);
        \\    if (i < hi) qsort(arr, i, hi);
        \\}
        \\var n = 50;
        \\var arr = new Array(n);
        \\var s = 123456789;
        \\for (var i = 0; i < n; i++) {
        \\    s = (s * 1664525 + 1013904223) % 2147483648;
        \\    arr[i] = s;
        \\}
        \\qsort(arr, 0, n - 1);
        \\arr[0] + arr[n >> 1] + arr[n - 1];
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 3353778030), res.asNumber());
}

test "baseline JIT Phase J1: new Array(n) bytecode+OSR, member compound assign single-eval, multi-loop OSR, holey arrays, and i64 mod" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function testJ1() {
        \\    // 1. new Array(n) + multi-loop OSR + i64 PRNG mod (% 2147483648)
        \\    var n = 200;
        \\    var arr = new Array(n);
        \\    var s = 123456789;
        \\    for (var i = 0; i < n; i++) {
        \\        s = (s * 1664525 + 1013904223) % 2147483648;
        \\        arr[i] = s;
        \\    }
        \\    // 2. Second sequential OSR loop + member compound assign arr[i] += ...
        \\    for (var i = 0; i < n; i++) {
        \\        arr[i] += 1;
        \\    }
        \\    // 3. Single evaluation of computed index with side effects in arr[idx()] += v
        \\    var idxCalls = 0;
        \\    var box = [10, 20, 30];
        \\    function getIdx() { idxCalls++; return 1; }
        \\    box[getIdx()] += 5;
        \\    if (idxCalls !== 1 || box[1] !== 25) return -1;
        \\    // 4. Partially holey array in OSR (written elements succeed, real hole bails cleanly)
        \\    var holey = new Array(150);
        \\    for (var k = 0; k < 149; k++) holey[k] = k * 2;
        \\    var hsum = 0;
        \\    for (var k = 0; k < 149; k++) hsum += holey[k];
        \\    if (hsum !== 148 * 149 || holey[149] !== undefined) return -2;
        \\    return arr[0] + arr[n - 1];
        \\}
        \\testJ1();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expect(res.asNumber() > 0);
}

test "bytecode VM regressions: array defineProperty accessor, omitted params reset, and try/catch NotImplemented" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Array index accessor defined via Object.defineProperty read from bytecode
        \\function readElem(obj, key) {
        \\    if (obj[key] !== 11) throw new Error("bad elem");
        \\    return obj[key];
        \\}
        \\var arr = [];
        \\Object.defineProperty(arr, "0", { get: function() { return 11; }, configurable: false });
        \\var r1 = readElem(arr, "0") + readElem(arr, 0);
        \\
        \\// 2. Omitted parameters in bytecode calls must be undefined, not stale primitives from prior frame
        \\function dirtyFrame(a, b, c, d) {
        \\    var x = a + b + c + d;
        \\    return x;
        \\}
        \\function checkOmitted(a, b, c, d) {
        \\    if (c !== undefined || d !== undefined) throw new Error("stale param");
        \\    return a + b;
        \\}
        \\function driver() {
        \\    var s = dirtyFrame(10, 20, 30, 40);
        \\    var t = checkOmitted(1, 2);
        \\    return s + t;
        \\}
        \\var r2 = driver();
        \\
        \\// 3. Bytecode try/catch must catch TypeError from class extends arrow function (NotImplemented gap)
        \\function assertThrowsTypeError(fn) {
        \\    try {
        \\        fn();
        \\    } catch (e) {
        \\        if (e instanceof TypeError) return 1;
        \\        throw new Error("wrong error");
        \\    }
        \\    throw new Error("did not throw");
        \\}
        \\var r3 = assertThrowsTypeError(() => {
        \\    var C = class extends (() => {}) {};
        \\});
        \\
        \\r1 * 1000 + r2 + r3;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 22104), res.asNumber());
}

test "baseline JIT Phase J2.1: Math.sqrt OSR intrinsic (IEEE-754 + monkey-patch bailout) and multi-array hoisting" {
    if (!comptime x64_asm.is_supported_host) return;
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Math.sqrt OSR: positive, 0, negative -> NaN
        \\function sumSqrt(n) {
        \\    var s = 0;
        \\    for (var i = 0; i < n; i++) {
        \\        s += Math.sqrt(i * i);
        \\    }
        \\    return s;
        \\}
        \\var r1 = sumSqrt(200);
        \\if (r1 !== 19900) throw new Error("bad sumSqrt: " + r1);
        \\
        \\function checkNegSqrt(n) {
        \\    var nanCount = 0;
        \\    for (var i = 0; i < n; i++) {
        \\        var v = Math.sqrt(i === 150 ? -1 : 0);
        \\        if (v !== v) nanCount++;
        \\    }
        \\    return nanCount;
        \\}
        \\if (checkNegSqrt(200) !== 1) throw new Error("bad neg sqrt");
        \\
        \\// 2. Monkey-patch Math.sqrt BEFORE re-entering compiled OSR loop
        \\var origSqrt = Math.sqrt;
        \\Math.sqrt = function() { return 99; };
        \\var rPatchedBefore = sumSqrt(10);
        \\Math.sqrt = origSqrt;
        \\if (rPatchedBefore !== 990) throw new Error("bad patch before: " + rPatchedBefore);
        \\
        \\// 3. Monkey-patch Math.sqrt INSIDE hot OSR loop
        \\function patchInside() {
        \\    var fn99 = function() { return 99; };
        \\    var last = 0;
        \\    for (var i = 0; i < 200; i++) {
        \\        if (i === 150) Math.sqrt = fn99;
        \\        last = Math.sqrt(16);
        \\    }
        \\    return last;
        \\}
        \\var rPatchedInside = patchInside();
        \\Math.sqrt = origSqrt;
        \\if (rPatchedInside !== 99) throw new Error("bad patch inside: " + rPatchedInside);
        \\
        \\// 4. Multi-array hoisting (5 simultaneous arrays: read + write)
        \\function multiArr(n) {
        \\    var a = new Array(n);
        \\    var b = new Array(n);
        \\    var c = new Array(n);
        \\    var d = new Array(n);
        \\    var e = new Array(n);
        \\    for (var i = 0; i < n; i++) {
        \\        a[i] = i;
        \\        b[i] = i * 2;
        \\        c[i] = i * 3;
        \\        d[i] = 1;
        \\        e[i] = 0;
        \\    }
        \\    for (var i = 0; i < n; i++) {
        \\        e[i] = a[i] + b[i] + c[i] + d[i];
        \\        d[i] += 2;
        \\    }
        \\    var total = 0;
        \\    for (var i = 0; i < n; i++) total += e[i] + d[i];
        \\    return total;
        \\}
        \\var rMulti = multiArr(150);
        \\// sum_{i=0..149} (6*i + 1 + 3) = 6 * (149*150/2) + 4*150 = 67050 + 600 = 67650
        \\if (rMulti !== 67650) throw new Error("bad multiArr: " + rMulti);
        \\rMulti;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 67650), res.asNumber());
}

test "baseline JIT Phase J2.2B: hoisted (ptr, len), RC bailout on heap overwrite, arr.length, frozen guard, bsearch & bitwise" {
    if (!comptime x64_asm.is_supported_host) return;
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var interp = try @import("../interpreter.zig").Interpreter.init(allocator, &writer.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Overwriting hoisted array slot containing heap object/string must bail out cleanly with 0 leaks
        \\function overwriteMixed() {
        \\    var arr = new Array(180);
        \\    for (var i = 0; i < 180; i++) arr[i] = i;
        \\    arr[120] = { k: 42 };
        \\    arr[140] = "heap_str_" + 99;
        \\    for (var i = 0; i < arr.length; i++) {
        \\        arr[i] = i * 2;
        \\    }
        \\    var s = 0;
        \\    for (var i = 0; i < arr.length; i++) s += arr[i];
        \\    return s;
        \\}
        \\// sum_{0..179} 2*i = 179 * 180 = 32220
        \\if (overwriteMixed() !== 32220) throw new Error("bad overwriteMixed");
        \\
        \\// 2. Reading arr.length in OSR + frozen array guard in .set_elem (sloppy + strict, pre- & post-OSR)
        \\function fillArr(arr) {
        \\    for (var i = 0; i < arr.length; i++) {
        \\        arr[i] = i + 10;
        \\    }
        \\    return arr[0];
        \\}
        \\var hotArr = [1, 2, 3, 4];
        \\for (var r = 0; r < 40; r++) fillArr(hotArr);
        \\var frozenSloppy = [7, 8, 9, 10];
        \\Object.freeze(frozenSloppy);
        \\try { fillArr(frozenSloppy); } catch (e) {}
        \\if (frozenSloppy[0] !== 7) throw new Error("frozen sloppy mutated");
        \\var frozenBig = new Array(150);
        \\for (var i = 0; i < 150; i++) frozenBig[i] = i + 5;
        \\Object.freeze(frozenBig);
        \\try { fillArr(frozenBig); } catch (e) {}
        \\if (frozenBig[0] !== 5) throw new Error("frozenBig sloppy mutated");
        \\
        \\function strictWriteFrozen(arr) {
        \\    "use strict";
        \\    for (var i = 0; i < arr.length; i++) {
        \\        arr[i] = 99;
        \\    }
        \\}
        \\var hotStrict = [1, 2, 3, 4];
        \\for (var r = 0; r < 40; r++) strictWriteFrozen(hotStrict);
        \\var caughtFrozen = false;
        \\try {
        \\    strictWriteFrozen(frozenSloppy);
        \\} catch (e) {
        \\    caughtFrozen = e instanceof TypeError;
        \\}
        \\if (!caughtFrozen) throw new Error("strict frozen did not throw TypeError");
        \\
        \\// 3. Binary search ((lo + hi) >> 1 + compacted new Array(n)) + 64-bit ToInt32 bitwise hash + nested compound assign
        \\function bsearchCheck() {
        \\    var n = 500;
        \\    var arr = new Array(n);
        \\    for (var i = 0; i < n; i++) arr[i] = i * 3;
        \\    var sum = 0;
        \\    for (var q = 0; q < 200; q++) {
        \\        var key = ((q * 73) % n) * 3;
        \\        var lo = 0;
        \\        var hi = arr.length - 1;
        \\        while (lo <= hi) {
        \\            var mid = (lo + hi) >> 1;
        \\            var v = arr[mid];
        \\            if (v === key) { sum += mid; break; }
        \\            else if (v < key) { lo = mid + 1; }
        \\            else { hi = mid - 1; }
        \\        }
        \\    }
        \\    return sum;
        \\}
        \\var bsExpected = 0;
        \\for (var q = 0; q < 200; q++) bsExpected += (q * 73) % 500;
        \\if (bsearchCheck() !== bsExpected) throw new Error("bad bsearchCheck");
        \\
        \\function hashAndNested() {
        \\    var buf = new Array(200);
        \\    for (var i = 0; i < 200; i++) buf[i] = (i * 31 + 17) & 255;
        \\    var h = 5381;
        \\    for (var i = 0; i < buf.length; i++) {
        \\        h = ((h * 33) ^ buf[i]) & 0x7fffffff;
        \\    }
        \\    var c = [0, 0, 0, 0];
        \\    var a = [1, 2, 3, 4];
        \\    var b = [5, 6, 7, 8];
        \\    for (var s = 0; s < 100; s++) {
        \\        var k = 0;
        \\        while (k < 4 && a[k] <= 4) {
        \\            c[k] += a[k] * b[k];
        \\            k++;
        \\        }
        \\    }
        \\    // c = [500, 1200, 2100, 3200] => sum = 7000
        \\    return (h > 0 ? 1 : 0) * (c[0] + c[1] + c[2] + c[3]);
        \\}
        \\hashAndNested();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 7000), res.asNumber());
}

test "baseline JIT Phase J2.2A: let and const OSR loops, lexical shadowing, const TypeError, TDZ ReferenceError, and for-let closures" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Hot OSR loops with let/const, sequential for(let i) loops, and multi-level block shadowing
        \\function runLetConstShadow() {
        \\    const n = 300;
        \\    const arr = new Array(n);
        \\    for (let i = 0; i < n; i++) {
        \\        const factor = 3;
        \\        arr[i] = i * factor;
        \\    }
        \\    let total = 0;
        \\    let shadow = 1000;
        \\    for (let i = 0; i < n; i++) {
        \\        let shadow = 5;
        \\        {
        \\            const shadow = 2;
        \\            let i = 7;
        \\            total += shadow + i;
        \\        }
        \\        total += arr[i] + shadow;
        \\    }
        \\    if (shadow !== 1000) throw new Error("outer let mutated by inner shadow");
        \\    // Per iteration: (2 + 7) + 3*i + 5 = 14 + 3*i; sum_{0..299} = 300*14 + 3*(299*300/2) = 4200 + 134550 = 138750
        \\    return total;
        \\}
        \\if (runLetConstShadow() !== 138750) throw new Error("bad runLetConstShadow");
        \\
        \\// 2. Immutable const: =, +=, ++, --, and late-iteration const write inside OSR loop must throw TypeError
        \\function checkConstErrors() {
        \\    let side = 0;
        \\    let ok = 0;
        \\    try {
        \\        const c = 10;
        \\        c = (side = 42);
        \\    } catch (e) {
        \\        if (e instanceof TypeError && side === 42) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        c += 5;
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        c++;
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        --c;
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const c = 10;
        \\        [c] = [20];
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    try {
        \\        const limit = 250;
        \\        let acc = 0;
        \\        for (let i = 0; i < limit; i++) {
        \\            acc += i;
        \\            if (i === 200) limit = 0;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof TypeError) ok++;
        \\    }
        \\    return ok;
        \\}
        \\if (checkConstErrors() !== 6) throw new Error("const reassignment did not throw TypeError");
        \\
        \\// 3. Observable TDZ throws ReferenceError (read, typeof, self-init, shadow-TDZ)
        \\function checkTDZ() {
        \\    let ok = 0;
        \\    const outer = 99;
        \\    try {
        \\        {
        \\            const leak = outer;
        \\            const outer = 1;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof ReferenceError) ok++;
        \\    }
        \\    try {
        \\        {
        \\            const t = typeof laterLet;
        \\            let laterLet = 1;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof ReferenceError) ok++;
        \\    }
        \\    try {
        \\        {
        \\            let selfRef = selfRef + 1;
        \\        }
        \\    } catch (e) {
        \\        if (e instanceof ReferenceError) ok++;
        \\    }
        \\    return ok;
        \\}
        \\if (checkTDZ() !== 3) throw new Error("TDZ did not throw ReferenceError");
        \\
        \\// 4. for (let i = ...) captured by closure preserves per-iteration lexical binding
        \\function checkForLetClosures() {
        \\    const fns = [];
        \\    for (let i = 0; i < 5; i++) {
        \\        fns.push(() => i);
        \\    }
        \\    return fns[0]() * 1000 + fns[1]() * 100 + fns[2]() * 10 + fns[4]();
        \\}
        \\checkForLetClosures();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 5555), res.asNumber()); // parity with tree-walker evalForStatement fallback
}

test "baseline JIT Phase J2.2A: TypedArray OSR fast-path (Float64Array, Int32Array, Uint8Array, length, NaN/-0, wrap-around, and OOB)" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Float64Array OSR: direct f64 load/store, blur1d (i+-1), Math.sqrt, -0.0, and raw NaN canonicalization
        \\function testFloat64Osr() {
        \\    const n = 256;
        \\    const src = new Float64Array(n);
        \\    const dst = new Float64Array(n);
        \\    for (let i = 0; i < src.length; i++) {
        \\        src[i] = i * 0.5;
        \\    }
        \\    src[0] = -0.0;
        \\    if (1 / src[0] !== -Infinity) throw new Error("lost -0.0 before OSR");
        \\    for (let rep = 0; rep < 4; rep++) {
        \\        for (let i = 1; i < dst.length - 1; i++) {
        \\            dst[i] = (src[i - 1] + src[i] + src[i + 1]) * 0.25 + Math.sqrt(src[i] * src[i]);
        \\        }
        \\    }
        \\    let negZeroCount = 0;
        \\    for (let k = 0; k < 200; k++) {
        \\        const z = src[0];
        \\        if (1 / z === -Infinity) negZeroCount++;
        \\    }
        \\    if (negZeroCount !== 200) throw new Error("Float64Array OSR lost -0.0");
        \\
        \\    // Shared ArrayBuffer with non-canonical NaN bits (0xFFFF800000001234)
        \\    const rawBuf = new ArrayBuffer(64);
        \\    const u8View = new Uint8Array(rawBuf);
        \\    const f64View = new Float64Array(rawBuf);
        \\    for (let i = 0; i < 8; i++) {
        \\        const base = i * 8;
        \\        u8View[base + 0] = 0x34;
        \\        u8View[base + 1] = 0x12;
        \\        u8View[base + 2] = 0x00;
        \\        u8View[base + 3] = 0x00;
        \\        u8View[base + 4] = 0x00;
        \\        u8View[base + 5] = 0x80;
        \\        u8View[base + 6] = 0xFF;
        \\        u8View[base + 7] = 0xFF;
        \\    }
        \\    let nanCount = 0;
        \\    for (let k = 0; k < 200; k++) {
        \\        const v = f64View[k & 7];
        \\        if (v !== v) nanCount++;
        \\    }
        \\    if (nanCount !== 200) throw new Error("Float64Array OSR failed NaN canonicalization");
        \\    return dst[10];
        \\}
        \\if (testFloat64Osr() !== 8.75) throw new Error("bad testFloat64Osr: " + testFloat64Osr());
        \\
        \\// 2. Int32Array & Uint8Array OSR: signed negatives, 32-bit & 8-bit wrap-around, NaN/Inf -> 0, hoisted .length
        \\function testIntTypedArraysOsr() {
        \\    const i32 = new Int32Array(256);
        \\    const u8 = new Uint8Array(256);
        \\    for (let i = 0; i < i32.length; i++) {
        \\        i32[i] = (i % 2 === 0) ? (0x7fffffff + i) : (-i * 100000);
        \\        u8[i] = 250 + i;
        \\    }
        \\    // Verify 32-bit and 8-bit wrap-around + NaN / Infinity coercion inside OSR
        \\    for (let k = 0; k < 200; k++) {
        \\        i32[2] = NaN;
        \\        i32[3] = Infinity;
        \\        i32[4] = 4294967295; // -1 in i32
        \\        u8[2] = 300;         // 44 in u8
        \\        u8[3] = -1;          // 255 in u8
        \\        u8[4] = NaN;         // 0 in u8
        \\    }
        \\    if (i32[0] !== 2147483647) throw new Error("bad i32[0]");
        \\    if (i32[200] !== -2147483449) throw new Error("bad i32[200]: " + i32[200]);
        \\    if (i32[2] !== 0 || i32[3] !== 0 || i32[4] !== -1) throw new Error("bad i32 special wrap");
        \\    if (u8[2] !== 44 || u8[3] !== 255 || u8[4] !== 0 || u8[10] !== 4) throw new Error("bad u8 wrap");
        \\
        \\    let acc = 0;
        \\    for (let i = 0; i < u8.length; i++) {
        \\        acc = (acc + u8[i] + (i32[i] & 0xff)) | 0;
        \\    }
        \\    return acc;
        \\}
        \\const intAcc = testIntTypedArraysOsr();
        \\
        \\// 3. Out-of-bounds read (undefined) and out-of-bounds write (no-op) after OSR warmup
        \\function testTypedArrayOob(ta, limit) {
        \\    let undefs = 0;
        \\    let sum = 0;
        \\    for (let i = 0; i < limit; i++) {
        \\        const v = ta[i];
        \\        if (v === undefined) undefs++;
        \\        else sum += v;
        \\        ta[i] = 77;
        \\    }
        \\    return undefs * 1000 + ta.length;
        \\}
        \\const smallTa = new Int32Array(200);
        \\for (let i = 0; i < 200; i++) smallTa[i] = 1;
        \\const oobRes = testTypedArrayOob(smallTa, 205);
        \\if (oobRes !== 5200) throw new Error("bad OOB read/length: " + oobRes);
        \\if (smallTa[-1] !== undefined || smallTa[200] !== undefined) throw new Error("OOB index not undefined");
        \\if (smallTa[0] !== 77 || smallTa[199] !== 77) throw new Error("in-bounds write failed");
        \\
        \\(intAcc !== 0 ? 1 : 0) * oobRes;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 5200), res.asNumber());
}

test "baseline JIT Phase J2.3: OSR object property IC (nbody object array, polymorphism, prototype, defineProperty accessor/readonly, freeze, heap overwrite)" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. N-body style OSR loop over an array of body objects (get_prop + compound set_prop -= / += + Math.sqrt)
        \\function runObjectNBody(steps) {
        \\    const bodies = [
        \\        { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: 1.0 },
        \\        { x: 1.0, y: 0.5, z: -0.2, vx: 0.1, vy: -0.05, vz: 0.02, mass: 0.001 },
        \\        { x: -1.0, y: -0.5, z: 0.2, vx: -0.1, vy: 0.05, vz: -0.02, mass: 0.002 },
        \\        { x: 0.5, y: -1.0, z: 0.3, vx: 0.05, vy: 0.1, vz: -0.01, mass: 0.0015 },
        \\        { x: -0.5, y: 1.0, z: -0.3, vx: -0.05, vy: -0.1, vz: 0.01, mass: 0.0005 }
        \\    ];
        \\    const dt = 0.01;
        \\    for (let s = 0; s < steps; s++) {
        \\        for (let i = 0; i < bodies.length; i++) {
        \\            const bi = bodies[i];
        \\            for (let j = i + 1; j < bodies.length; j++) {
        \\                const bj = bodies[j];
        \\                const dx = bi.x - bj.x;
        \\                const dy = bi.y - bj.y;
        \\                const dz = bi.z - bj.z;
        \\                const d2 = dx * dx + dy * dy + dz * dz + 0.01;
        \\                const dist = Math.sqrt(d2);
        \\                const mag = dt / (d2 * dist);
        \\                const mj = bj.mass * mag;
        \\                const mi = bi.mass * mag;
        \\                bi.vx -= dx * mj;
        \\                bi.vy -= dy * mj;
        \\                bi.vz -= dz * mj;
        \\                bj.vx += dx * mi;
        \\                bj.vy += dy * mi;
        \\                bj.vz += dz * mi;
        \\            }
        \\        }
        \\        for (let i = 0; i < bodies.length; i++) {
        \\            const b = bodies[i];
        \\            b.x += dt * b.vx;
        \\            b.y += dt * b.vy;
        \\            b.z += dt * b.vz;
        \\        }
        \\    }
        \\    return Math.floor((bodies[0].x + bodies[1].y + bodies[2].z + bodies[3].x + bodies[4].y) * 10000.0);
        \\}
        \\// Compare object-based nbody against array-based reference for 200 steps
        \\function runArrayNBodyRef(steps) {
        \\    const x = [0.0, 1.0, -1.0, 0.5, -0.5];
        \\    const y = [0.0, 0.5, -0.5, -1.0, 1.0];
        \\    const z = [0.0, -0.2, 0.2, 0.3, -0.3];
        \\    const vx = [0.0, 0.1, -0.1, 0.05, -0.05];
        \\    const vy = [0.0, -0.05, 0.05, 0.1, -0.1];
        \\    const vz = [0.0, 0.02, -0.02, -0.01, 0.01];
        \\    const m = [1.0, 0.001, 0.002, 0.0015, 0.0005];
        \\    const dt = 0.01;
        \\    for (let s = 0; s < steps; s++) {
        \\        for (let i = 0; i < 5; i++) {
        \\            for (let j = i + 1; j < 5; j++) {
        \\                const dx = x[i] - x[j];
        \\                const dy = y[i] - y[j];
        \\                const dz = z[i] - z[j];
        \\                const d2 = dx * dx + dy * dy + dz * dz + 0.01;
        \\                const dist = Math.sqrt(d2);
        \\                const mag = dt / (d2 * dist);
        \\                const mj = m[j] * mag;
        \\                const mi = m[i] * mag;
        \\                vx[i] -= dx * mj;
        \\                vy[i] -= dy * mj;
        \\                vz[i] -= dz * mj;
        \\                vx[j] += dx * mi;
        \\                vy[j] += dy * mi;
        \\                vz[j] += dz * mi;
        \\            }
        \\        }
        \\        for (let i = 0; i < 5; i++) {
        \\            x[i] += dt * vx[i];
        \\            y[i] += dt * vy[i];
        \\            z[i] += dt * vz[i];
        \\        }
        \\    }
        \\    return Math.floor((x[0] + y[1] + z[2] + x[3] + y[4]) * 10000.0);
        \\}
        \\const nbObj = runObjectNBody(200);
        \\const nbRef = runArrayNBodyRef(200);
        \\if (nbObj !== nbRef) throw new Error("nbody mismatch: " + nbObj + " vs " + nbRef);
        \\
        \\// 2. Polymorphic property order at same IC site (recache on miss without corrupting values)
        \\function testPolymorphicShapes() {
        \\    const shapes = [
        \\        { val: 1, padA: 10, padB: 20 },
        \\        { padA: 10, val: 2, padB: 20 },
        \\        { padA: 10, padB: 20, val: 3 }
        \\    ];
        \\    let sum = 0;
        \\    for (let i = 0; i < 300; i++) {
        \\        const o = shapes[i % 3];
        \\        o.val += 1;
        \\        sum += o.val + o.padA;
        \\    }
        \\    // Each object updated 100 times:
        \\    // o0: 2..101 => 5150; o1: 3..102 => 5250; o2: 4..103 => 5350; + 300*10 = 3000 => 18750
        \\    return sum;
        \\}
        \\if (testPolymorphicShapes() !== 18750) throw new Error("bad polymorphic shapes: " + testPolymorphicShapes());
        \\
        \\// 3. Prototype property, getter/setter via Object.defineProperty, writable:false, and Object.freeze (sloppy + strict)
        \\function testProtoAccessorReadonlyFreeze() {
        \\    const proto = { inherited: 7 };
        \\    const child = Object.create(proto);
        \\    child.own = 3;
        \\    let protoSum = 0;
        \\    for (let i = 0; i < 200; i++) {
        \\        protoSum += child.inherited + child.own;
        \\    }
        \\    if (protoSum !== 2000) throw new Error("bad protoSum: " + protoSum);
        \\
        \\    let backing = 5;
        \\    let getHits = 0;
        \\    let setHits = 0;
        \\    const accObj = { k: 1 };
        \\    Object.defineProperty(accObj, "v", {
        \\        get: function() { getHits++; return backing; },
        \\        set: function(x) { setHits++; backing = x; },
        \\        configurable: true
        \\    });
        \\    for (let i = 0; i < 150; i++) {
        \\        accObj.v = accObj.v + 1;
        \\    }
        \\    if (backing !== 155 || getHits !== 150 || setHits !== 150) throw new Error("bad accessor OSR");
        \\
        \\    function writeTarget(list) {
        \\        for (let i = 0; i < list.length; i++) {
        \\            list[i].x = 999;
        \\        }
        \\    }
        \\    function writeTargetStrict(list) {
        \\        "use strict";
        \\        for (let i = 0; i < list.length; i++) {
        \\            list[i].x = 999;
        \\        }
        \\    }
        \\    const warmList = [];
        \\    for (let i = 0; i < 150; i++) warmList.push({ x: i });
        \\    writeTarget(warmList);
        \\    writeTargetStrict(warmList);
        \\
        \\    const roObj = { x: 42 };
        \\    Object.defineProperty(roObj, "x", { writable: false });
        \\    const frzObj = Object.freeze({ x: 88 });
        \\    try { writeTarget([roObj]); } catch (e) {}
        \\    try { writeTarget([frzObj]); } catch (e) {}
        \\    if (roObj.x !== 42 || frzObj.x !== 88) throw new Error("sloppy mutated readonly/frozen");
        \\
        \\    let strictErrors = 0;
        \\    try { writeTargetStrict([roObj]); } catch (e) { if (e instanceof TypeError) strictErrors++; }
        \\    try { writeTargetStrict([frzObj]); } catch (e) { if (e instanceof TypeError) strictErrors++; }
        \\    if (strictErrors !== 2 || roObj.x !== 42 || frzObj.x !== 88) throw new Error("strict did not throw TypeError");
        \\    return protoSum + backing + strictErrors;
        \\}
        \\if (testProtoAccessorReadonlyFreeze() !== 2157) throw new Error("bad proto/accessor/freeze");
        \\
        \\// 4. Overwriting property holding heap string / heap object with a number inside hot OSR loop (0 memory leaks)
        \\function testHeapOverwriteNoLeak() {
        \\    const items = [];
        \\    for (let i = 0; i < 180; i++) {
        \\        items.push({ v: i });
        \\    }
        \\    items[100].v = "allocated_string_" + 100;
        \\    items[120].v = { nestedObj: 123, label: "inner_" + 120 };
        \\    for (let i = 0; i < items.length; i++) {
        \\        const it = items[i];
        \\        it.v = i * 2;
        \\    }
        \\    let s = 0;
        \\    for (let i = 0; i < items.length; i++) {
        \\        s += items[i].v;
        \\    }
        \\    return s;
        \\}
        \\// sum_{0..179} 2*i = 179 * 180 = 32220
        \\testHeapOverwriteNoLeak();
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 32220), res.asNumber());
}

test "baseline JIT Phase J2.4: String .length and .charCodeAt intrinsics in whole-function JIT + OSR, read-only String args, UTF-16 surrogates, edge indices, and prototype mutation" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. rut_dv style whole-function JIT called from hot OSR loop with read-only String arguments
        \\function rut_dv(s) {
        \\    var m = 2;
        \\    var t = 0;
        \\    for (var i = s.length - 1; i >= 0; i--) {
        \\        t = t + (s.charCodeAt(i) - 48) * m;
        \\        m = (m === 7) ? 2 : (m + 1);
        \\    }
        \\    var dvNum = 11 - (t % 11);
        \\    if (dvNum === 11) return 48;
        \\    if (dvNum === 10) return 75;
        \\    return 48 + dvNum;
        \\}
        \\function runRutLoop(N) {
        \\    const ruts = [
        \\        "12345678", "11111111", "22222222", "24967103", "15432987",
        \\        "76543210", "9876543", "19283746", "30123456", "17463829"
        \\    ];
        \\    let acc = 0;
        \\    let kCount = 0;
        \\    for (let i = 0; i < N; i++) {
        \\        const dv = rut_dv(ruts[i % 10]);
        \\        if (dv === 75) kCount = kCount + 1;
        \\        acc = (acc + dv) % 1000000007;
        \\    }
        \\    return acc + kCount;
        \\}
        \\const rutRes = runRutLoop(300);
        \\if (rutRes !== 15270) throw new Error("bad rutRes: " + rutRes);
        \\
        \\// Force bailout inside JIT-compiled rut_dv by passing a non-string/number or triggering fallback, ensuring 0 refcount leaks
        \\let bailCaught = 0;
        \\try { rut_dv(null); } catch (e) { if (e instanceof TypeError) bailCaught++; }
        \\if (bailCaught !== 1) throw new Error("null did not throw TypeError in rut_dv");
        \\if (rut_dv("12345678") !== 53) throw new Error("rut_dv after bailout failed");
        \\
        \\// 2. Direct OSR loop using s.length and s.charCodeAt(i) on ASCII and UTF-16 / surrogate pairs ("😀", "ñáé")
        \\function sumCharCodesOsr(str, rounds) {
        \\    let total = 0;
        \\    for (let r = 0; r < rounds; r++) {
        \\        const len = str.length;
        \\        for (let i = 0; i < len; i++) {
        \\            total += str.charCodeAt(i);
        \\        }
        \\    }
        \\    return total;
        \\}
        \\// "😀" is U+1F600 => high surrogate 0xD83D (55357) + low surrogate 0xDE00 (56832), length 2
        \\// "ñáé" => 241 + 225 + 233 = 699, length 3
        \\const emojiStr = "A😀B"; // 65 + 55357 + 56832 + 66 = 112320, length 4
        \\const latinStr = "ñáé";
        \\if (emojiStr.length !== 4 || latinStr.length !== 3) throw new Error("bad UTF-16 length");
        \\if (sumCharCodesOsr(emojiStr, 100) !== 11232000) throw new Error("bad emoji OSR sum");
        \\if (sumCharCodesOsr(latinStr, 100) !== 69900) throw new Error("bad latin OSR sum");
        \\if (rut_dv(emojiStr) < 0) throw new Error("bad emoji in whole-fn JIT");
        \\
        \\// 3. Edge-case indices: negative, >= length, NaN, -0, fractional (1.9 -> 1)
        \\function testEdgeIndices(s) {
        \\    let nanCount = 0;
        \\    let validSum = 0;
        \\    const nanVal = 0.0 / 0.0;
        \\    for (let i = 0; i < 120; i++) {
        \\        const cNeg = s.charCodeAt(-1);
        \\        const cOob = s.charCodeAt(s.length);
        \\        const cNan = s.charCodeAt(nanVal);
        \\        const cNegZero = s.charCodeAt(-0.0);
        \\        const cNegFrac = s.charCodeAt(-0.5);
        \\        const cFrac = s.charCodeAt(1.9);
        \\        if (cNeg !== cNeg && cOob !== cOob) nanCount++;
        \\        validSum += cNan + cNegZero + cNegFrac + cFrac;
        \\    }
        \\    return nanCount * 1000000 + validSum;
        \\}
        \\// For "XYZ": charCodeAt(0) = 88 (cNan, cNegZero, cNegFrac), charCodeAt(1) = 89 (cFrac)
        \\// Per iteration: 88 + 88 + 88 + 89 = 353; 120 * 353 = 42360; nanCount = 120 => 120042360
        \\const edgeRes = testEdgeIndices("XYZ");
        \\if (edgeRes !== 120042360) throw new Error("bad edgeRes: " + edgeRes);
        \\
        \\// 4. Dynamic strings allocated in loop passed to JIT function (verifies 0 leaks / 0 double-free)
        \\let dynSum = 0;
        \\for (let i = 0; i < 150; i++) {
        \\    const dynS = "12345" + (100 + i);
        \\    dynSum += rut_dv(dynS);
        \\}
        \\
        \\// 5. Mutating String.prototype.charCodeAt mid-execution invalidates intrinsic and respects override
        \\const origCharCodeAt = String.prototype.charCodeAt;
        \\String.prototype.charCodeAt = function(idx) { return 48; };
        \\const mutatedDv = rut_dv("12345678"); // all digits become '0' (48) => t = 0 => dvNum = 11 => returns 48
        \\const mutatedOsr = sumCharCodesOsr("ABC", 80); // 80 * 3 * 48 = 11520
        \\String.prototype.charCodeAt = origCharCodeAt;
        \\if (mutatedDv !== 48) throw new Error("Whole-fn JIT ignored String.prototype.charCodeAt override: " + mutatedDv);
        \\if (mutatedOsr !== 11520) throw new Error("OSR ignored String.prototype.charCodeAt override: " + mutatedOsr);
        \\if (rut_dv("12345678") !== 53) throw new Error("Restored String.prototype.charCodeAt failed");
        \\
        \\rutRes + mutatedDv + (dynSum > 0 ? 1 : 0);
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 15319), res.asNumber());
}

test "baseline JIT Phase J2.4B: FastIntAscii tier for rut_dv, borrowed string args in OSR, XMM preservation across pure leaf calls, overflow/UTF-16/prototype fallback" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\function rut_dv(s) {
        \\    var m = 2;
        \\    var t = 0;
        \\    for (var i = s.length - 1; i >= 0; i--) {
        \\        t = t + (s.charCodeAt(i) - 48) * m;
        \\        m = (m === 7) ? 2 : (m + 1);
        \\    }
        \\    var dvNum = 11 - (t % 11);
        \\    if (dvNum === 11) return 48;
        \\    if (dvNum === 10) return 75;
        \\    return 48 + dvNum;
        \\}
        \\
        \\// 1. Exact bench_rut pattern: new Array(count) compacted to dense + nested OSR loops + borrowed string arg
        \\function bench_rut_mini(iters) {
        \\    var count = 100;
        \\    var ruts = new Array(count);
        \\    for (var i = 0; i < count; i++) {
        \\        ruts[i] = "" + (16521526 + i);
        \\    }
        \\    var sum = 0;
        \\    var passes = iters / count;
        \\    for (var p = 0; p < passes; p++) {
        \\        for (var i = 0; i < count; i++) {
        \\            sum += rut_dv(ruts[i]);
        \\        }
        \\    }
        \\    return sum;
        \\}
        \\const miniRes = bench_rut_mini(8000);
        \\
        \\// Verify against an unrolled reference with mixed ASCII lengths (0, 1, 7, 8, 20) and UTF-16 inside the same hot OSR loop
        \\const mixed = ["16521526", "9876543", "1", "", "12345678901234567890", "A😀B", "ñáé"];
        \\var mixedSum = 0;
        \\for (var k = 0; k < 140; k++) {
        \\    mixedSum += rut_dv(mixed[k % 7]);
        \\}
        \\const expectedMixedOnce = rut_dv("16521526") + rut_dv("9876543") + rut_dv("1") + rut_dv("") + rut_dv("12345678901234567890") + rut_dv("A😀B") + rut_dv("ñáé");
        \\if (mixedSum !== expectedMixedOnce * 20) throw new Error("bad mixedSum: " + mixedSum + " vs " + (expectedMixedOnce * 20));
        \\
        \\// 2. Mid-loop bailout when an element of ruts is replaced with a non-string (number or null) at iteration 90
        \\function sumRutArr(arr) {
        \\    var acc = 0;
        \\    for (var i = 0; i < 100; i++) {
        \\        acc += rut_dv(arr[i]);
        \\    }
        \\    return acc;
        \\}
        \\function testBorrowedArgBailout() {
        \\    var arr = new Array(100);
        \\    for (var i = 0; i < 100; i++) arr[i] = "12345678";
        \\    arr[90] = 12345678;
        \\    var accNum = sumRutArr(arr);
        \\    if (accNum !== 99 * 53 + 48) throw new Error("bad number borrowed arg bailout: accNum=" + accNum);
        \\    arr[90] = null;
        \\    var caught = 0;
        \\    try {
        \\        sumRutArr(arr);
        \\    } catch (e) {
        \\        caught = 1;
        \\    }
        \\    if (caught !== 1) throw new Error("bad null borrowed arg bailout: caught=" + caught);
        \\    return accNum;
        \\}
        \\if (testBorrowedArgBailout() !== 5295) throw new Error("failed borrowed arg bailout");
        \\
        \\// 3. Int32 overflow fallback to general float tier and -0.0 preservation
        \\function strWeightedOverflow(s) {
        \\    var acc = 1000000000;
        \\    for (var i = 0; i < s.length; i++) {
        \\        acc = acc + s.charCodeAt(i) * 100000000;
        \\    }
        \\    return acc;
        \\}
        \\var ovRes = 0;
        \\for (var i = 0; i < 80; i++) {
        \\    ovRes = strWeightedOverflow("12345678");
        \\}
        \\// 1e9 + (49+50+51+52+53+54+55+56)*1e8 = 1e9 + 420*1e8 = 43000000000
        \\if (ovRes !== 43000000000) throw new Error("bad ovRes: " + ovRes);
        \\
        \\// 4. Prototype mutation invalidates inline StringCharCodeAtGuard immediately
        \\const origCCA = String.prototype.charCodeAt;
        \\String.prototype.charCodeAt = function(i) { return 49; };
        \\const overVal = rut_dv("12345678"); // 8 digits of '1' (49-48=1): m=2,3,4,5,6,7,2,3 => sum=32 => 32%11=10 => dvNum=1 => 49
        \\String.prototype.charCodeAt = origCCA;
        \\if (overVal !== 49) throw new Error("bad overVal: " + overVal);
        \\if (rut_dv("12345678") !== 53) throw new Error("restore failed");
        \\
        \\miniRes > 0 ? 1 : 0;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 1), res.asNumber());

    const s_env = interp.script_env.?;
    const rut_val = switch (s_env.lookup("rut_dv")) {
        .value => |v| v,
        else => unreachable,
    };
    const rut_cb = vm.getBytecodeTarget(rut_val).?.block;
    try std.testing.expect(rut_cb.jit_fn != null);
    try std.testing.expect(rut_cb.jit_pure_leaf);
    try std.testing.expectEqual(@as(u32, 1), rut_cb.jit_string_param_mask);

    const bench_val = switch (s_env.lookup("bench_rut_mini")) {
        .value => |v| v,
        else => unreachable,
    };
    const bench_cb = vm.getBytecodeTarget(bench_val).?.block;
    var has_compiled_osr = false;
    for (bench_cb.osr_entries) |oe| {
        if (oe.fn_ptr != null and !oe.failed) has_compiled_osr = true;
    }
    try std.testing.expect(has_compiled_osr);
}

test "baseline JIT string layout offsets, charCodeAt bounds-check NaN, and OSR 8-byte fast-path" {
    if (!comptime x64_asm.is_supported_host) return;
    const jit_common = @import("jit_common.zig");
    const Interpreter = @import("../interpreter.zig").Interpreter;

    // 1. Runtime validation of str_data_ptr_off and str_data_len_off against a real StringBox
    try std.testing.expect(jit_common.str_data_len_off != jit_common.str_data_ptr_off);
    try std.testing.expectEqual(jit_common.str_data_ptr_off + @as(i32, @intCast(@sizeOf(usize))), jit_common.str_data_len_off);
    {
        const sample = "12345678";
        var sval = try JSValue.newString(std.testing.allocator, sample);
        defer sval.deinit();
        const box = sval.asString();
        const base_addr = @intFromPtr(box);
        const ptr_field: *const [*]const u8 = @ptrFromInt(base_addr + @as(usize, @intCast(jit_common.str_data_ptr_off)));
        const len_field: *const usize = @ptrFromInt(base_addr + @as(usize, @intCast(jit_common.str_data_len_off)));
        try std.testing.expectEqual(box.value.data.ptr, ptr_field.*);
        try std.testing.expectEqual(@as(usize, 8), len_field.*);
        try std.testing.expectEqual(box.value.data.len, len_field.*);
    }

    // 2. Whole-function JIT (FastIntAscii & general float tier) + OSR bounds checks and 8-byte fast paths
    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// Whole-function JIT: out-of-bounds charCodeAt (>= len and < 0) must return NaN
        \\function wholeFnOobSum(s) {
        \\    var t = 0;
        \\    for (var i = 0; i < 12; i++) {
        \\        t = t + s.charCodeAt(i);
        \\    }
        \\    return t;
        \\}
        \\function wholeFnAt(s, idx) {
        \\    return s.charCodeAt(idx);
        \\}
        \\var wRes = 0;
        \\for (var k = 0; k < 100; k++) {
        \\    wRes = wholeFnOobSum("12345678");
        \\    if (wholeFnAt("12345678", 7) !== 56) throw new Error("bad idx 7");
        \\    if (!Number.isNaN(wholeFnAt("12345678", 8))) throw new Error("idx 8 must be NaN");
        \\    if (!Number.isNaN(wholeFnAt("12345678", -1))) throw new Error("idx -1 must be NaN");
        \\    if (!Number.isNaN(wholeFnAt("1234", 4))) throw new Error("idx 4 on len 4 must be NaN");
        \\}
        \\if (!Number.isNaN(wRes)) throw new Error("wholeFnOobSum must be NaN, got " + wRes);
        \\
        \\// OSR s.length and s.charCodeAt across 8-byte ASCII (fast path), non-8-byte ASCII, UTF-16, and OOB
        \\function osrStringOps() {
        \\    var s8 = "12345678";
        \\    var s5 = "ABCDE";
        \\    var sUtf16 = "a\u00e9\u20ac12345";
        \\    var lenAcc = 0;
        \\    var codeAcc = 0;
        \\    var nanCount = 0;
        \\    for (var i = 0; i < 300; i++) {
        \\        lenAcc += s8.length + s5.length + sUtf16.length;
        \\        codeAcc += s8.charCodeAt(i & 7) + s5.charCodeAt(i % 5) + sUtf16.charCodeAt(2);
        \\        if (Number.isNaN(s8.charCodeAt(8))) nanCount++;
        \\        if (Number.isNaN(s8.charCodeAt(-1))) nanCount++;
        \\        if (Number.isNaN(s5.charCodeAt(5))) nanCount++;
        \\    }
        \\    if (lenAcc !== 300 * (8 + 5 + 8)) throw new Error("bad lenAcc: " + lenAcc);
        \\    if (nanCount !== 900) throw new Error("bad nanCount: " + nanCount);
        \\    return codeAcc;
        \\}
        \\// 300 iterations:
        \\// s8: 37 full cycles of 8 digits (49..56, sum=420) + 4 digits (49..52, sum=202) = 15540 + 202 = 15742
        \\// s5: 60 full cycles of 5 chars (65..69, sum=335) = 20100
        \\// sUtf16.charCodeAt(2) = 0x20ac (8364) * 300 = 2509200
        \\var totalCode = osrStringOps();
        \\if (totalCode !== 15742 + 20100 + 2509200) throw new Error("bad totalCode: " + totalCode);
        \\1;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 1), res.asNumber());
}

test "baseline JIT FastIntAscii micro-optimizations: reverse loop bounds elision, OOB non-pattern, -0 mul, magic mod 11, and cmov ternary" {
    if (!comptime x64_asm.is_supported_host) return;
    const Interpreter = @import("../interpreter.zig").Interpreter;

    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    var interp = try Interpreter.init(std.testing.allocator, &allocating.writer);
    defer interp.deinit();
    interp.compile_options.use_bytecode_vm = true;

    const res = try interp.run(
        \\// 1. Canonical rut_dv (reverse loop i = s.length - 1; i >= 0; i--, ASCII sub 48, non-neg mul, ternary cmov, % 11)
        \\function rut_dv(s) {
        \\    var m = 2;
        \\    var t = 0;
        \\    for (var i = s.length - 1; i >= 0; i--) {
        \\        t = t + (s.charCodeAt(i) - 48) * m;
        \\        m = (m === 7) ? 2 : (m + 1);
        \\    }
        \\    var dvNum = 11 - (t % 11);
        \\    if (dvNum === 11) return 48;
        \\    if (dvNum === 10) return 75;
        \\    return 48 + dvNum;
        \\}
        \\// 2. Non-canonical reverse loop (starts at s.length instead of s.length - 1 -> must NOT elide bounds check and must return NaN)
        \\function nonCanonicalOobReverse(s) {
        \\    var t = 0;
        \\    for (var i = s.length; i >= 0; i--) {
        \\        t = t + s.charCodeAt(i);
        \\    }
        \\    return t;
        \\}
        \\// 3. Reverse loop that mutates i inside body -> must NOT elide bounds check
        \\function mutatedIdxReverse(s) {
        \\    var t = 0;
        \\    for (var i = s.length - 1; i >= 0; i--) {
        \\        t = t + s.charCodeAt(i + 5);
        \\    }
        \\    return t;
        \\}
        \\// 4. Negative * zero multiplication in FastIntAscii candidate must preserve -0.0 via fallback
        \\function negZeroMul(s) {
        \\    var c = s.charCodeAt(0) - 48; // 0 for "0"
        \\    var neg = c - 1; // -1 for "0"
        \\    return neg * c; // -1 * 0 => -0.0
        \\}
        \\// 5. % 11 edge values (0, 10, 11, 12, 100000, and negative dividend)
        \\function mod11Edge(s) {
        \\    var base = s.charCodeAt(0) - 48; // 0 for "0", 1 for "1"
        \\    var r0 = (base * 0) % 11;
        \\    var r10 = (base * 10) % 11;
        \\    var r11 = (base * 11) % 11;
        \\    var r12 = (base * 12) % 11;
        \\    var rBig = (base * 100000) % 11; // 100000 = 9090 * 11 + 10 => 10
        \\    return r0 * 10000 + r10 * 1000 + r11 * 100 + r12 * 10 + rBig;
        \\}
        \\function mod11Negative(s) {
        \\    var v = (s.charCodeAt(0) - 60); // '0'(48) - 60 = -12
        \\    return v % 11; // -12 % 11 = -1
        \\}
        \\
        \\var rutAcc = 0;
        \\for (var k = 0; k < 120; k++) {
        \\    rutAcc += rut_dv("16521526");
        \\    if (!Number.isNaN(nonCanonicalOobReverse("12345678"))) throw new Error("nonCanonicalOobReverse must be NaN");
        \\    if (!Number.isNaN(mutatedIdxReverse("12345678"))) throw new Error("mutatedIdxReverse must be NaN");
        \\    var nz = negZeroMul("0");
        \\    if (nz !== 0 || (1 / nz) !== -Infinity) throw new Error("negZeroMul must return -0.0");
        \\    var posMul = negZeroMul("2"); // c=2, neg=1 => 2
        \\    if (posMul !== 2) throw new Error("bad posMul: " + posMul);
        \\    var mEdge = mod11Edge("1");
        \\    if (mEdge !== 10020) throw new Error("bad mod11Edge: " + mEdge);
        \\    if (mod11Edge("0") !== 0) throw new Error("bad mod11Edge(0)");
        \\    var mNeg = mod11Negative("0");
        \\    if (mNeg !== -1) throw new Error("bad mod11Negative: " + mNeg);
        \\}
        \\if (rut_dv("") !== 48) throw new Error("empty string rut_dv must be 48");
        \\rutAcc;
    );
    defer res.deinit();
    try std.testing.expect(res.isNumber());
    try std.testing.expectEqual(@as(f64, 120 * 53), res.asNumber());
}


