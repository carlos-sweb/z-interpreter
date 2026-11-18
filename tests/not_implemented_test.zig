const std = @import("std");
const helpers = @import("helpers.zig");

test "with is a SyntaxError (this engine is always strict)" {
    try helpers.expectUncaught("with ({}) { 1; }", .syntax_error, "Strict mode code may not include a with statement");
}

test "a feature gap is a catchable TypeError, not an abort" {
    try helpers.expectStdout(
        \\try { ({ ...[1, 2] }); } catch (e) { console.log(e.name, e.message); }
        \\try { (1).x = 1; } catch (e) { console.log(e.name); }
        \\console.log('still running');
    , "TypeError Spreading a array into an object literal is not supported yet\nTypeError\nstill running\n");
}

test "an uncaught feature gap ends the script as an uncaught TypeError" {
    try helpers.expectUncaught("({ ...[1, 2] });", .type_error, "Spreading a array into an object literal is not supported yet");
}

test "a feature gap inside an async function rejects its promise" {
    try helpers.expectStdout(
        \\(async () => { ({ ...[1, 2] }); })().catch(e => console.log('rejected', e.name));
    , "rejected TypeError\n");
}
