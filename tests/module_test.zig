//! ES modules at runtime, driven by an in-memory mock loader. The
//! headline narrowing (documented): bindings snapshot at the end of the
//! source module's evaluation (no live bindings), so import cycles are a
//! catchable error instead of working like real ESM.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");

/// specifier -> source. Specifiers double as resolved paths (no
/// resolution logic in the mock).
const MockFs = std.StaticStringMap([]const u8);

fn mockLoad(ctx: *anyopaque, arena: std.mem.Allocator, specifier: []const u8, referrer: ?[]const u8) anyerror!?zinterpreter.LoadedModule {
    _ = referrer;
    const fs: *const MockFs = @ptrCast(@alignCast(ctx));
    const source = fs.get(specifier) orelse return null;
    return .{ .path = try arena.dupe(u8, specifier), .source = source };
}

const Run = struct {
    interp: zinterpreter.Interpreter,
    allocating: std.Io.Writer.Allocating,

    fn init(fs: *const MockFs) !*Run {
        const self = try testing.allocator.create(Run);
        self.allocating = std.Io.Writer.Allocating.init(testing.allocator);
        self.interp = try zinterpreter.Interpreter.init(testing.allocator, &self.allocating.writer);
        self.interp.setModuleLoader(.{ .ctx = @constCast(fs), .load = mockLoad });
        return self;
    }

    fn deinit(self: *Run) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

fn expectModuleStdout(fs: *const MockFs, entry: []const u8, expected: []const u8) !void {
    var r = try Run.init(fs);
    defer r.deinit();
    _ = try r.interp.runModule(entry);
    try testing.expectEqualStrings(expected, r.allocating.written());
}

test "named/renamed/default/namespace imports across a dependency chain" {
    const fs = MockFs.initComptime(.{
        .{ "util", "export function doblar(n) { return n * 2; } export const PI2 = 6.28;" },
        .{ "lib",
        \\import { doblar } from 'util';
        \\export function cuadruplicar(n) { return doblar(doblar(n)); }
        \\export { doblar as x2 } from 'util';
        \\export default 'soy lib';
        },
        .{ "main",
        \\import etiqueta, { cuadruplicar, x2 } from 'lib';
        \\import * as util from 'util';
        \\console.log(etiqueta);
        \\console.log(cuadruplicar(5), x2(3), util.PI2);
        },
    });
    try expectModuleStdout(&fs, "main", "soy lib\n20 6 6.28\n");
}

test "a module evaluates once even with two importers; deps run first (DFS)" {
    const fs = MockFs.initComptime(.{
        .{ "shared", "console.log('shared eval'); export const v = 1;" },
        .{ "a", "import { v } from 'shared'; console.log('a', v);" },
        .{ "b", "import { v } from 'shared'; console.log('b', v);" },
        .{ "main", "import 'a'; import 'b'; console.log('main');" },
    });
    try expectModuleStdout(&fs, "main", "shared eval\na 1\nb 1\nmain\n");
}

test "export { x } before its declaration; export let snapshots its final value" {
    const fs = MockFs.initComptime(.{
        .{ "m", "export { x }; let x = 1; x = 99;" },
        .{ "main", "import { x } from 'm'; console.log(x);" },
    });
    try expectModuleStdout(&fs, "main", "99\n");
}

test "export function hoists inside its module (call before declaration)" {
    const fs = MockFs.initComptime(.{
        .{ "m", "export const r = f(); export function f() { return 7; }" },
        .{ "main", "import { r } from 'm'; console.log(r);" },
    });
    try expectModuleStdout(&fs, "main", "7\n");
}

test "export * re-exports everything except default" {
    const fs = MockFs.initComptime(.{
        .{ "base", "export const a = 1; export const b = 2; export default 'D';" },
        .{ "hub", "export * from 'base';" },
        .{ "main",
        \\import * as hub from 'hub';
        \\console.log(hub.a, hub.b, hub.default);
        },
    });
    try expectModuleStdout(&fs, "main", "1 2 undefined\n");
}

test "missing module and missing export are catchable with Node-style messages" {
    const fs = MockFs.initComptime(.{
        .{ "main", "import { x } from 'nope';" },
        .{ "m2", "export const a = 1;" },
        .{ "main2", "import { zeta } from 'm2';" },
    });
    var r = try Run.init(&fs);
    defer r.deinit();
    try testing.expectError(error.UncaughtException, r.interp.runModule("main"));
    const ex = r.interp.pending_exception.?;
    try testing.expect(std.mem.startsWith(u8, ex.@"error".value.message, "Cannot find module 'nope'"));

    var r2 = try Run.init(&fs);
    defer r2.deinit();
    try testing.expectError(error.UncaughtException, r2.interp.runModule("main2"));
    const ex2 = r2.interp.pending_exception.?;
    try testing.expectEqualStrings("The requested module 'm2' does not provide an export named 'zeta'", ex2.@"error".value.message);
}

test "import cycles are the documented catchable error" {
    const fs = MockFs.initComptime(.{
        .{ "a", "import { b } from 'b'; export const a = 1;" },
        .{ "b", "import { a } from 'a'; export const b = 2;" },
    });
    var r = try Run.init(&fs);
    defer r.deinit();
    try testing.expectError(error.UncaughtException, r.interp.runModule("a"));
    const ex = r.interp.pending_exception.?;
    try testing.expect(std.mem.startsWith(u8, ex.@"error".value.message, "Circular dependency detected"));
}

test "async work inside modules drains through runModule's loop" {
    const fs = MockFs.initComptime(.{
        .{ "m",
        \\export async function tarde(v) { await new Promise(res => setTimeout(res, 3)); return v; }
        },
        .{ "main",
        \\import { tarde } from 'm';
        \\tarde('llego').then(v => console.log(v));
        \\console.log('sync');
        },
    });
    try expectModuleStdout(&fs, "main", "sync\nllego\n");
}

test "import in a classic run() without a loader is a catchable SyntaxError" {
    var allocating = std.Io.Writer.Allocating.init(testing.allocator);
    defer allocating.deinit();
    var interp = try zinterpreter.Interpreter.init(testing.allocator, &allocating.writer);
    defer interp.deinit();
    try testing.expectError(error.UncaughtException, interp.run("import { x } from 'm';"));
    try testing.expectEqualStrings("Cannot use import statement outside a module", interp.pending_exception.?.@"error".value.message);
}
