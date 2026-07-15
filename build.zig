const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zparser_dep = b.dependency("zparser", .{ .target = target, .optimize = optimize });
    const zparser_module = zparser_dep.module("zparser");

    const zstatements_dep = b.dependency("zstatements", .{ .target = target, .optimize = optimize });
    const zstatements_module = zstatements_dep.module("zstatements");

    const zfunctions_dep = b.dependency("zfunctions", .{ .target = target, .optimize = optimize });
    const zfunctions_module = zfunctions_dep.module("zfunctions");

    const zvalue_dep = b.dependency("zvalue", .{ .target = target, .optimize = optimize });
    const zvalue_module = zvalue_dep.module("zvalue");

    const znumber_dep = b.dependency("znumber", .{ .target = target, .optimize = optimize });
    const znumber_module = znumber_dep.module("znumber");

    const zinterpreter_module = b.addModule("zinterpreter", .{
        .root_source_file = b.path("src/zinterpreter.zig"),
    });
    zinterpreter_module.addImport("zparser", zparser_module);
    zinterpreter_module.addImport("zstatements", zstatements_module);
    zinterpreter_module.addImport("zfunctions", zfunctions_module);
    zinterpreter_module.addImport("zvalue", zvalue_module);
    zinterpreter_module.addImport("znumber", znumber_module);

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/literals_test.zig",
        "tests/operators_test.zig",
        "tests/control_flow_test.zig",
        "tests/functions_test.zig",
        "tests/closures_test.zig",
        "tests/console_test.zig",
        "tests/not_implemented_test.zig",
        "tests/integration_test.zig",
        "tests/exceptions_test.zig",
        "tests/switch_test.zig",
        "tests/labels_test.zig",
        "tests/bitwise_test.zig",
        "tests/new_prototype_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });

        unit_tests.root_module.addImport("zinterpreter", zinterpreter_module);
        unit_tests.root_module.addImport("zparser", zparser_module);
        unit_tests.root_module.addImport("zstatements", zstatements_module);
        unit_tests.root_module.addImport("zfunctions", zfunctions_module);
        unit_tests.root_module.addImport("zvalue", zvalue_module);
        unit_tests.root_module.addImport("znumber", znumber_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zinterpreter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addImport("zparser", zparser_module);
    src_tests.root_module.addImport("zstatements", zstatements_module);
    src_tests.root_module.addImport("zfunctions", zfunctions_module);
    src_tests.root_module.addImport("zvalue", zvalue_module);
    src_tests.root_module.addImport("znumber", znumber_module);
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
