const std = @import("std");

// Version - keep in sync with build.zig.zon
const VERSION = "1.0.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const cova = b.dependency("cova", .{});
    const dotenv = b.dependency("dotenv", .{});

    // Build-time option: can override version via command line
    // Example: zig build -Dversion=0.2.0
    const build_version = b.option([]const u8, "version", "Version of zoreman") orelse VERSION;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", build_version);

    const exe = b.addExecutable(.{
        .name = "zoreman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("cova", cova.module("cova"));
    exe.root_module.addImport("dotenv", dotenv.module("dotenv"));

    // Step install
    b.installArtifact(exe);

    // Step run
    const run_step = b.step("run", "Run zoreman");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Step test (unit tests)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", build_options);
    tests.root_module.addImport("cova", cova.module("cova"));
    tests.root_module.addImport("dotenv", dotenv.module("dotenv"));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
