const std = @import("std");

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
