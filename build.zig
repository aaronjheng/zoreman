const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zoreman",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // cova
    const cova = b.dependency("cova", .{});
    exe.root_module.addImport("cova", cova.module("cova"));

    // dotenv
    const dotenv = b.dependency("dotenv", .{});
    exe.root_module.addImport("dotenv", dotenv.module("dotenv"));

    // Step install
    b.installArtifact(exe);

    // Step run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zoreman");
    run_step.dependOn(&run_cmd.step);
}
