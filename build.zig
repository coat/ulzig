const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ulzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const flags_mod = b.dependency("flags", .{
        .target = target,
        .optimize = optimize,
    }).module("flags");

    const exe_mod = b.addModule("exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
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

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
