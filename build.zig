const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const benchmark_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const skip_dusty = b.option(bool, "skip_dusty", "Skip dusty dependency (for benches)") orelse false;

    const mod = b.addModule("slung", .{ .root_source_file = b.path("src/slung.zig"), .target = target });
    const mod_opts = b.addOptions();
    mod_opts.addOption(bool, "enable_connectors", !skip_dusty);
    mod.addOptions("build_options", mod_opts);

    const exe_opts = b.addOptions();
    exe_opts.addOption(bool, "enable_connectors", true);

    const exe = b.addExecutable(.{
        .name = "slung",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bin/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "slung", .module = mod }},
        }),
    });
    exe.root_module.addOptions("build_options", exe_opts);

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const codspeed = b.dependency("codspeed", .{
        .target = target,
        .optimize = benchmark_optimize,
    });

    const zwasm = b.dependency("zwasm", .{
        .target = target,
        .optimize = optimize,
    });

    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const sqlite_flags: []const []const u8 = &.{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=2",
        "-fno-sanitize=undefined",
        "-fno-sanitize=thread",
        "-fno-omit-frame-pointer",
    };

    // dusty internally imports `zio`, so ensure the module has it in scope.
    dusty.module("dusty").addImport("zio", zio.module("zio"));

    exe.root_module.addImport("zio", zio.module("zio"));
    exe.root_module.addImport("zwasm", zwasm.module("zwasm"));
    exe.root_module.addImport("toml", toml.module("toml"));
    exe.root_module.addImport("dusty", dusty.module("dusty"));

    mod.addImport("zio", zio.module("zio"));
    mod.addImport("zwasm", zwasm.module("zwasm"));
    mod.addImport("toml", toml.module("toml"));
    mod.addImport("dusty", dusty.module("dusty"));
    mod.addIncludePath(b.path("lib/sqlite"));
    mod.addCSourceFile(.{
        .file = b.path("lib/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = .{
        .path = b.path("test_runner.zig"),
        .mode = .simple,
    } });
    mod_tests.root_module.addOptions("build_options", mod_opts);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const benches_opts = b.addOptions();
    benches_opts.addOption(bool, "enable_connectors", !skip_dusty);

    const benches_exe = b.addExecutable(.{
        .name = "benches",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benches.zig"),
            .target = target,
            .optimize = benchmark_optimize,
            .imports = &.{},
        }),
    });
    benches_exe.root_module.addOptions("build_options", benches_opts);
    benches_exe.root_module.addImport("codspeed", codspeed.module("codspeed"));
    benches_exe.root_module.addImport("zio", zio.module("zio"));
    benches_exe.root_module.addImport("zwasm", zwasm.module("zwasm"));
    if (!skip_dusty) {
        benches_exe.root_module.addImport("dusty", dusty.module("dusty"));
        dusty.module("dusty").addImport("zio", zio.module("zio"));
    }

    const benches_run_step = b.step("benches", "Run the benches benchmark");

    const benches_run_cmd = b.addRunArtifact(benches_exe);
    benches_run_step.dependOn(&benches_run_cmd.step);

    if (b.args) |args| {
        benches_run_cmd.addArgs(args);
    }
}
