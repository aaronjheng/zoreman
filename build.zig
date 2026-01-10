const std = @import("std");

// Version - keep in sync with build.zig.zon
const VERSION = "0.1.0";

pub fn build(b: *std.Build) void {
    // Dependencies
    const cova = b.dependency("cova", .{});
    const dotenv = b.dependency("dotenv", .{});

    const exe = b.addExecutable(.{
        .name = "zoreman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });

    // Build-time option: can override version via command line
    // Example: zig build -Dversion=0.2.0
    const build_version = b.option([]const u8, "version", "Version of zoreman") orelse VERSION;

    // Pass version to code via build options
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", build_version);
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
}
