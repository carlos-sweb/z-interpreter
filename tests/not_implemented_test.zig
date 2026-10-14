const std = @import("std");
const helpers = @import("helpers.zig");

test "with is a SyntaxError (this engine is always strict)" {
    try helpers.expectUncaught("with ({}) { 1; }", .syntax_error, "Strict mode code may not include a with statement");
}

test "a feature gap is a catchable TypeError, not an abort" {
    try helpers.expectStdout(
        \\try { new Map().x = 1; } catch (e) { console.log(e.name, e.message); }
        \\try { ({ ...[1, 2] }); } catch (e) { console.log(e.name); }
        \\try { 'x' in new Set(); } catch (e) { console.log(e.name); }
        \\console.log('still running');
    , "TypeError Cannot add property x to a map: not supported yet\nTypeError\nTypeError\nstill running\n");
}

test "an uncaught feature gap ends the script as an uncaught TypeError" {
    try helpers.expectUncaught("new Date(0).x = 1;", .type_error, "Cannot add property x to a date: not supported yet");
}

test "a feature gap inside an async function rejects its promise" {
    try helpers.expectStdout(
        \\(async () => { new Map().x = 1; })().catch(e => console.log('rejected', e.name));
    , "rejected TypeError\n");
}
