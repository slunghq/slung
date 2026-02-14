const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "slung",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const zware = b.dependency("zware", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zio", zio.module("zio"));
    exe.root_module.addImport("dusty", dusty.module("dusty"));
    exe.root_module.addImport("zware", zware.module("zware"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const billions_exe = b.addExecutable(.{
        .name = "billions",
        .root_module = b.createModule(.{
            .root_source_file = b.path("billions.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    b.installArtifact(billions_exe);

    const billions_run_step = b.step("billions", "Run the billions benchmark");

    const billions_run_cmd = b.addRunArtifact(billions_exe);
    billions_run_step.dependOn(&billions_run_cmd.step);

    billions_run_cmd.step.dependOn(b.getInstallStep());
}
