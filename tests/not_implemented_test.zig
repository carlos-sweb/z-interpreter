const std = @import("std");
const helpers = @import("helpers.zig");

test "explicitly deferred constructs raise error.NotImplemented, not a crash" {
    try helpers.expectNotImplemented("switch (1) { case 1: 1; }");
    try helpers.expectNotImplemented("try { 1; } catch (e) { 2; }");
    try helpers.expectNotImplemented("throw 1;");
    try helpers.expectNotImplemented("with ({}) { 1; }");
    try helpers.expectNotImplemented("for (const x in {a:1}) { x; }");
    try helpers.expectNotImplemented("for (const x of [1,2]) { x; }");
    try helpers.expectNotImplemented("new Foo();");
    try helpers.expectNotImplemented("let Foo = 1; 1 instanceof Foo;");
    try helpers.expectNotImplemented("'a' in {};");
}
