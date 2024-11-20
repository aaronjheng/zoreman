const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cova = b.dependency("cova", .{});
    const dotenv = b.dependency("dotenv", .{});

    const exe = b.addExecutable(.{
        .name = "zoreman",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Dependencies
    exe.root_module.addImport("cova", cova.module("cova"));
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
