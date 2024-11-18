const std = @import("std");
const heap = std.heap;
const log = std.log;
const mem = std.mem;
const os = std.os;
const posix = std.posix;

const cova = @import("cova");
const dotenv = @import("dotenv");

const logger = std.log.scoped(.zoreman);
const Procfile = @import("procfile.zig").Procfile;
const Supervisor = @import("supervisor.zig").Supervisor;

const CommandT = cova.Command.Custom(.{
    .global_sub_cmds_mandatory = false,
    .usage_header_fmt =
    \\Usage:
    \\{s}{s} 
    ,
    .help_header_fmt =
    \\Help:
    \\{s}{s}
    \\
    \\{s}{s}
    \\
    \\
    ,
    .subcmds_help_title_fmt = "{s}Commands:\n",
    .opts_help_title_fmt = "{s}Options:\n",
    .opt_config = .{
        .name_sep_fmt = ", ",
        .global_help_fn = struct {
            fn help(self: anytype, writer: anytype, _: ?mem.Allocator) !void {
                const indent_fmt = @TypeOf(self.*).indent_fmt;

                try self.usage(writer);
                try writer.print("{?s}{s}", .{ indent_fmt, self.description });
            }
        }.help,
    },
});
const RootCmd = CommandT{
    .name = "zoreman",
    .description = "Manage Procfile-based applications",
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
        .{ .name = "start", .description = "Start Applications" },
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
        const check = gpa.deinit();

        if (check == .leak) {
            logger.warn("Memory Leaked", .{});
        }
    }

    const allocator = gpa.allocator();

    var rootCmd = try RootCmd.init(allocator, .{
        .help_config = .{
            .add_help_cmds = false,
        },
    });
    defer rootCmd.deinit();

    var argsIterator = try cova.ArgIteratorGeneric.init(allocator);
    defer argsIterator.deinit();

    cova.parseArgs(&argsIterator, CommandT, rootCmd, std.io.getStdErr().writer(), .{}) catch |err| switch (err) {
        error.UsageHelpCalled => {
            return;
        },
        else => return err,
    };

    const profilePath = try (try rootCmd.getOpts(.{})).get("procfile_opt").?.val.getAs([]const u8);
    const dotenvPath = try (try rootCmd.getOpts(.{})).get("dotenv_opt").?.val.getAs([]const u8);

    try dotenv.loadFrom(allocator, dotenvPath, .{});

    if (rootCmd.matchSubCmd("start")) |_| {
        var procfile = try Procfile.init(allocator, profilePath);
        defer procfile.deinit();

        var supervisor = try Supervisor.init(allocator, procfile);
        defer supervisor.deinit();

        try supervisor.start();
    }

    try rootCmd.help(std.io.getStdErr().writer());
}
