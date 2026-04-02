const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const benchmark_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "slung",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/slung.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
        .use_llvm = true,
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

    const codspeed = b.dependency("codspeed", .{
        .target = target,
        .optimize = benchmark_optimize,
    });

    const nats = b.dependency("nats", .{
        .target = target,
        .optimize = optimize,
    });

    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zio", zio.module("zio"));
    exe.root_module.addImport("dusty", dusty.module("dusty"));
    exe.root_module.addImport("zware", zware.module("zware"));
    exe.root_module.addImport("nats", nats.module("nats"));
    exe.root_module.addImport("toml", toml.module("toml"));
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

    const benches_exe = b.addExecutable(.{
        .name = "benches",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benches.zig"),
            .target = target,
            .optimize = benchmark_optimize,
            .imports = &.{},
        }),
    });
    benches_exe.root_module.addImport("codspeed", codspeed.module("codspeed"));

    b.installArtifact(benches_exe);

    const benches_run_step = b.step("benches", "Run the benches benchmark");

    const benches_run_cmd = b.addRunArtifact(benches_exe);
    benches_run_step.dependOn(&benches_run_cmd.step);
}
