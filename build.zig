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

    const zmath_dep = b.dependency("zmath", .{ .target = target, .optimize = optimize });
    const zmath_module = zmath_dep.module("zmath");

    const zjson_dep = b.dependency("zjson", .{ .target = target, .optimize = optimize });
    const zjson_module = zjson_dep.module("zjson");

    const zstring_dep = b.dependency("zstring", .{ .target = target, .optimize = optimize });
    const zstring_module = zstring_dep.module("zstring");

    const zdate_dep = b.dependency("zdate", .{ .target = target, .optimize = optimize });
    const zdate_module = zdate_dep.module("zdate");

    const zregex_dep = b.dependency("zregex", .{ .target = target, .optimize = optimize });
    const zregex_module = zregex_dep.module("zregex");

    const zinterpreter_module = b.addModule("zinterpreter", .{
        .root_source_file = b.path("src/zinterpreter.zig"),
    });
    zinterpreter_module.addImport("zparser", zparser_module);
    zinterpreter_module.addImport("zstatements", zstatements_module);
    zinterpreter_module.addImport("zfunctions", zfunctions_module);
    zinterpreter_module.addImport("zvalue", zvalue_module);
    zinterpreter_module.addImport("znumber", znumber_module);
    zinterpreter_module.addImport("zmath", zmath_module);
    zinterpreter_module.addImport("zjson", zjson_module);
    zinterpreter_module.addImport("zstring", zstring_module);
    zinterpreter_module.addImport("zdate", zdate_module);
    zinterpreter_module.addImport("zregex", zregex_module);

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
        "tests/iteration_test.zig",
        "tests/builtins_test.zig",
        "tests/date_test.zig",
        "tests/eval_test.zig",
        "tests/prototypes_test.zig",
        "tests/robustness_test.zig",
        "tests/destructuring_test.zig",
        "tests/methods_test.zig",
        "tests/classes_test.zig",
        "tests/private_test.zig",
        "tests/hoisting_test.zig",
        "tests/promise_test.zig",
        "tests/generator_test.zig",
        "tests/async_test.zig",
        "tests/async_generator_test.zig",
        "tests/module_test.zig",
        "tests/function_methods_test.zig",
        "tests/stack_guard_test.zig",
        "tests/descriptors_test.zig",
        "tests/constructors_test.zig",
        "tests/arguments_test.zig",
        "tests/symbol_test.zig",
        "tests/array_methods_full_test.zig",
        "tests/string_methods_full_test.zig",
        "tests/map_set_test.zig",
        "tests/regex_test.zig",
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
        unit_tests.root_module.addImport("zmath", zmath_module);
        unit_tests.root_module.addImport("zjson", zjson_module);
        unit_tests.root_module.addImport("zstring", zstring_module);
        unit_tests.root_module.addImport("zdate", zdate_module);
        unit_tests.root_module.addImport("zregex", zregex_module);

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
    src_tests.root_module.addImport("zmath", zmath_module);
    src_tests.root_module.addImport("zjson", zjson_module);
    src_tests.root_module.addImport("zstring", zstring_module);
    src_tests.root_module.addImport("zdate", zdate_module);
    src_tests.root_module.addImport("zregex", zregex_module);
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
