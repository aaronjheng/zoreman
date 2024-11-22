const std = @import("std");
const heap = std.heap;
const io = std.io;
const log = std.log;
const mem = std.mem;
const os = std.os;
const posix = std.posix;

const cova = @import("cova");
const dotenv = @import("dotenv");

const Procfile = @import("procfile.zig").Procfile;
const Supervisor = @import("supervisor.zig").Supervisor;

const logger = log.scoped(.zoreman);

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{
            .scope = .cova,
            .level = .info,
        },
    },
};

const CommandT = cova.Command.Custom(.{
    .global_vals_mandatory = false,
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
    .vals_help_title_fmt = "{s}Values:\n",
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
const OptionT = CommandT.OptionT;
const ValueT = CommandT.ValueT;
const RootCmd = CommandT{
    .name = "zoreman",
    .description = "Manage Procfile-based applications",
    .opts = &.{
        .{
            .name = "dotenv",
            .description = ".env file path",
            .short_name = 'e',
            .long_name = "env",
            .val = ValueT.ofType(
                []const u8,
                .{
                    .name = "dotenv",
                    .description = ".env path value",
                    .default_val = ".env",
                },
            ),
        },
        .{
            .name = "procfile",
            .description = "Procfile file path",
            .short_name = 'f',
            .long_name = "procfile",
            .val = ValueT.ofType(
                []const u8,
                .{
                    .name = "procfile",
                    .description = "Procfile path value",
                    .default_val = "Procfile",
                },
            ),
        },
    },
    .sub_cmds = &.{
        .{
            .name = "check",
            .description = "Validate Procfile format",
        },
        .{
            .name = "start",
            .description = "Start Applications",
            .vals = &.{
                ValueT.ofType(
                    []const u8,
                    .{
                        .name = "process",
                        .description = "Process(es) to start",
                        .set_behavior = .Multi,
                        .max_entries = 3,
                    },
                ),
            },
        },
        .{
            .name = "version",
            .description = "Print zoreman version",
        },
    },
};

var supervisor: Supervisor = undefined;

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();

        if (check == .leak) {
            logger.warn("Memory Leaked", .{});
        }
    }

    const allocator = gpa.allocator();

    var root_cmd = try RootCmd.init(allocator, .{
        .help_config = .{
            .add_help_cmds = false,
        },
    });
    defer root_cmd.deinit();

    var args_iter = try cova.ArgIteratorGeneric.init(allocator);
    defer args_iter.deinit();

    cova.parseArgs(&args_iter, CommandT, root_cmd, io.getStdErr().writer(), .{}) catch |err| switch (err) {
        error.UsageHelpCalled => {
            return;
        },
        else => return err,
    };

    const procfile_path = try (try root_cmd.getOpts(.{})).get("procfile").?.val.getAs([]const u8);
    const dotenv_path = try (try root_cmd.getOpts(.{})).get("dotenv").?.val.getAs([]const u8);

    try dotenv.loadFrom(allocator, dotenv_path, .{});

    if (root_cmd.matchSubCmd("check")) |_| {
        var procfile = try Procfile.init(allocator, procfile_path);
        defer procfile.deinit();

        var keys = std.ArrayList([]const u8).init(allocator);
        defer keys.deinit();

        for (procfile.procs.items) |proc| {
            try keys.append(proc.name);
        }

        const key_slice = try keys.toOwnedSlice();
        defer allocator.free(key_slice);

        const keys_str = try mem.join(allocator, ", ", key_slice);
        defer allocator.free(keys_str);

        logger.info("Valid Procfile detected: {s}, keys: {s}", .{ procfile_path, keys_str });

        return;
    } else if (root_cmd.matchSubCmd("start")) |start_cmd| {
        const val = (try start_cmd.getVals(.{})).get("process").?;

        var processes: ?[][]const u8 = null;
        if (val.isSet()) {
            processes = try val.getAllAs([]const u8);
        }

        var procfile = try Procfile.init(allocator, procfile_path);
        defer procfile.deinit();

        supervisor = try Supervisor.init(allocator, procfile);
        defer supervisor.deinit();

        const terminate = posix.Sigaction{
            .handler = .{
                .handler = struct {
                    fn handle(_: c_int) callconv(.C) void {
                        supervisor.stop() catch |err| {
                            logger.err("Stop supervisor failed: {}", .{err});
                        };
                    }
                }.handle,
            },
            .mask = posix.empty_sigset,
            .flags = 0,
        };

        try posix.sigaction(posix.SIG.INT, &terminate, null);
        try posix.sigaction(posix.SIG.TERM, &terminate, null);

        supervisor.start(processes) catch |err| {
            logger.err("Start supervisor failed: {}", .{err});
        };

        return;
    } else if (root_cmd.matchSubCmd("version")) |_| {
        try io.getStdOut().writer().print("{s}\n", .{"0.1.0-dev"});
    } else {
        try root_cmd.help(io.getStdErr().writer());
    }
}
