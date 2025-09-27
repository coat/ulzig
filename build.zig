const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coverage = b.option(bool, "coverage", "Generate a coverage report with kcov") orelse false;

    const mod = b.addModule("ulzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const flags_mod = b.dependency("flags", .{
        .target = target,
    }).module("flags");

    const exe_mod = b.addModule("exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ulz", .module = mod },
            .{ .name = "flags", .module = flags_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "ulz",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run ulz");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod, .use_llvm = true });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    if (coverage) {
        const kcov_bin = b.findProgram(&.{"kcov"}, &.{}) catch "kcov";

        const coverage_step = std.Build.Step.Run.create(b, "run coverage");
        coverage_step.addArg(kcov_bin);
        coverage_step.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));

        const coverage_output = coverage_step.addOutputFileArg(".");

        coverage_step.addDirectoryArg(run_mod_tests.producer.?.getEmittedBin());

        const install_coverage = b.addInstallDirectory(.{
            .source_dir = coverage_output,
            .install_dir = .{ .custom = "coverage" },
            .install_subdir = "",
        });
        test_step.dependOn(&install_coverage.step);
    }
}
