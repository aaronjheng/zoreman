const std = @import("std");
const heap = std.heap;
const os = std.os;
const posix = std.posix;

const cova = @import("cova");
const CommandT = cova.Command.Custom(.{});
const dotenv = @import("dotenv");

const Procfile = @import("procfile.zig").Procfile;
const Supervisor = @import("supervisor.zig").Supervisor;

const RootCmd = CommandT{
    .name = "zoreman",
    .opts = &.{
        .{
            .name = "dotenv_opt",
            .description = ".env file path",
            .short_name = 'e',
            .long_name = "env",
            .val = ValueT.ofType(
                []const u8,
                .{
                    .name = "dotenv_val",
                    .description = ".env path value",
                    .default_val = ".env",
                },
            ),
        },
        .{
            .name = "procfile_opt",
            .description = "Procfile file path",
            .short_name = 'f',
            .long_name = "procfile",
            .val = ValueT.ofType(
                []const u8,
                .{
                    .name = "procfile_val",
                    .description = "Procfile path value",
                    .default_val = "Procfile",
                },
            ),
        },
    },
    .sub_cmds = &.{
        .{
            .name = "start",
        },
    },
};
const OptionT = CommandT.OptionT;
const ValueT = CommandT.ValueT;

pub const std_options = .{
    .log_scope_levels = &.{
        .{
            .scope = .cova,
            .level = .info,
        },
    },
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const allocator = gpa.allocator();

    var rootCmd = try RootCmd.init(allocator, .{});
    defer rootCmd.deinit();

    var argsIterator = try cova.ArgIteratorGeneric.init(allocator);
    defer argsIterator.deinit();

    const parseArgsResult = cova.parseArgs(&argsIterator, CommandT, rootCmd, std.io.getStdOut().writer(), .{});
    parseArgsResult catch |err| {
        switch (err) {
            error.ExpectedSubCommand, error.UsageHelpCalled => {},
            else => return err,
        }
    };

    const profilePath = try (try rootCmd.getOpts(.{})).get("procfile_opt").?.val.getAs([]const u8);
    const dotenvPath = try (try rootCmd.getOpts(.{})).get("dotenv_opt").?.val.getAs([]const u8);

    try dotenv.loadFrom(allocator, dotenvPath, .{});

    if (rootCmd.matchSubCmd("start")) |_| {
        var procfile = try Procfile.init(allocator, profilePath);
        defer procfile.deinit();

        var supervisor = try Supervisor.init(allocator, procfile);
        defer supervisor.deinit();

        supervisor.start() catch {};
        return;
    }
}
