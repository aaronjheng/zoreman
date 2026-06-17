const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const cova = @import("cova");
const config_mod = @import("config.zig");

/// Internal CLI intent: the result of translating cova's parse tree into a
/// flat enum + arguments. Business code only depends on this, not on cova.
pub const Intent = union(enum) {
    /// User asked for help; print usage and exit 0.
    help,
    /// `zoreman version`.
    version,
    /// `zoreman check`.
    check,
    /// `zoreman start [PROC...]`.
    start: []const []const u8,
    /// `zoreman run COMMAND [PROC...]`.
    run: struct { command: []const u8, args: []const []const u8 },
    /// `zoreman export FORMAT LOCATION`.
    @"export": struct { format: []const u8, location: []const u8 },
};

/// Result of parsing argv: an intent + config overrides + which flags were
/// explicitly set on the CLI (so .goreman doesn't get overwritten by defaults).
pub const ParseResult = struct {
    intent: Intent,
    config: config_mod.Config,
    set_flags: config_mod.SetFlags,
    /// Owns slices for positional args and any duped strings.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
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
const ValueT = CommandT.ValueT;

/// Parse a boolean from a value-bearing option (e.g. `--set-ports=false`).
/// cova would otherwise reject `=value` for bool options because it treats
/// them as pure toggles. Using a custom `parse_fn` opts into argument-bearing
/// boolean parsing.
fn parseBoolValue(arg: []const u8, _: std.mem.Allocator) anyerror!bool {
    var lower_buf: [16]u8 = undefined;
    if (arg.len >= lower_buf.len) return error.BadBool;
    var i: usize = 0;
    while (i < arg.len) : (i += 1) lower_buf[i] = std.ascii.toLower(arg[i]);
    const s = lower_buf[0..arg.len];
    if (mem.eql(u8, s, "true") or mem.eql(u8, s, "t") or mem.eql(u8, s, "yes") or mem.eql(u8, s, "y") or mem.eql(u8, s, "1")) return true;
    if (mem.eql(u8, s, "false") or mem.eql(u8, s, "f") or mem.eql(u8, s, "no") or mem.eql(u8, s, "n") or mem.eql(u8, s, "0")) return false;
    return error.BadBool;
}

const BoolFlagVal: ValueT = ValueT.ofType(bool, .{
    .name = "BOOL",
    .description = "",
    .parse_fn = parseBoolValue,
});

const RootCmd: CommandT = .{
    .name = "zoreman",
    .description = "Manage Procfile-based applications",
    .opts = &.{
        .{
            .name = "procfile",
            .description = "Procfile path (default: Procfile)",
            .short_name = 'f',
            .long_name = "procfile",
            .val = ValueT.ofType([]const u8, .{ .name = "PATH", .description = "" }),
        },
        .{
            .name = "dotenv",
            .description = ".env file path (default: .env)",
            .short_name = 'e',
            .long_name = "env",
            .val = ValueT.ofType([]const u8, .{ .name = "PATH", .description = "" }),
        },
        .{
            .name = "port",
            .description = "RPC server port (default: 8555)",
            .short_name = 'p',
            .long_name = "port",
            .val = ValueT.ofType(u16, .{ .name = "PORT", .description = "" }),
        },
        .{
            .name = "baseport",
            .description = "Base port for processes (default: 5000)",
            .short_name = 'b',
            .long_name = "baseport",
            .val = ValueT.ofType(u16, .{ .name = "PORT", .description = "" }),
        },
        .{
            .name = "basedir",
            .description = "Change to this directory before starting",
            .long_name = "basedir",
            .val = ValueT.ofType([]const u8, .{ .name = "DIR", .description = "" }),
        },
        .{
            .name = "set_ports",
            .description = "Inject PORT into each child env (default: true)",
            .long_name = "set-ports",
            .val = BoolFlagVal,
        },
        .{
            .name = "exit_on_error",
            .description = "Exit if a child quits with a nonzero status",
            .long_name = "exit-on-error",
            .val = BoolFlagVal,
        },
        .{
            .name = "exit_on_stop",
            .description = "Exit when all children stop (default: true)",
            .long_name = "exit-on-stop",
            .val = BoolFlagVal,
        },
        .{
            .name = "logtime",
            .description = "Show timestamp in logs (default: true)",
            .long_name = "logtime",
            .val = BoolFlagVal,
        },
        .{
            .name = "rpc_server",
            .description = "Start RPC server on `start` (default: true)",
            .long_name = "rpc-server",
            .val = BoolFlagVal,
        },
    },
    .sub_cmds = &.{
        .{ .name = "check", .description = "Validate Procfile format" },
        .{
            .name = "start",
            .description = "Start applications",
            .vals = &.{
                ValueT.ofType([]const u8, .{
                    .name = "PROCESS",
                    .description = "Process(es) to start",
                    .set_behavior = .Multi,
                    .max_entries = 127,
                }),
            },
        },
        .{
            .name = "run",
            .description = "Send a command to a running supervisor",
            .vals = &.{
                ValueT.ofType([]const u8, .{
                    .name = "COMMAND",
                    .description = "start/stop/stop-all/restart/restart-all/list/status",
                }),
                ValueT.ofType([]const u8, .{
                    .name = "PROCESS",
                    .description = "Target process(es)",
                    .set_behavior = .Multi,
                    .max_entries = 127,
                }),
            },
        },
        .{
            .name = "export",
            .description = "Export Procfile to another format",
            .vals = &.{
                ValueT.ofType([]const u8, .{ .name = "FORMAT", .description = "upstart" }),
                ValueT.ofType([]const u8, .{ .name = "LOCATION", .description = "Output directory" }),
            },
        },
        .{ .name = "version", .description = "Print zoreman version" },
    },
};

/// Parse argv into an `Intent` plus `Config` overrides. Returned struct must
/// be `deinit`ed by the caller.
///
/// Errors and help: writes diagnostics to `stderr_writer` and returns
/// `error.HelpRequested` for the `--help`/`help` flow (caller exits 0). For
/// genuine parse errors, returns the underlying error so callers can render
/// "zoreman: ..." prefix and exit nonzero.
pub fn parse(
    parent_alloc: Allocator,
    argv: []const [:0]const u8,
    stderr: *std.Io.Writer,
) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var root_cmd = try RootCmd.init(alloc, .{
        .help_config = .{ .add_help_cmds = true, .add_help_opts = true },
    });

    const raw_iter = cova.RawArgIterator{ .args = argv };
    var args_iter = cova.ArgIteratorGeneric.from(raw_iter);
    defer args_iter.deinit();

    cova.parseArgs(&args_iter, CommandT, root_cmd, stderr, .{}) catch |err| switch (err) {
        error.UsageHelpCalled => {
            return .{
                .intent = .help,
                .config = .{},
                .set_flags = .{},
                .arena = arena,
            };
        },
        else => return err,
    };

    var cfg: config_mod.Config = .{};
    var set: config_mod.SetFlags = .{};

    const opts = try root_cmd.getOpts(.{});
    if (opts.get("procfile")) |o| if (o.val.isSet()) {
        cfg.procfile = try o.val.getAs([]const u8);
        set.procfile = true;
    };
    if (opts.get("dotenv")) |o| if (o.val.isSet()) {
        cfg.env_file = try o.val.getAs([]const u8);
        set.env_file = true;
    };
    if (opts.get("port")) |o| if (o.val.isSet()) {
        cfg.port = try o.val.getAs(u16);
        set.port = true;
    };
    if (opts.get("baseport")) |o| if (o.val.isSet()) {
        cfg.baseport = try o.val.getAs(u16);
        set.baseport = true;
    };
    if (opts.get("basedir")) |o| if (o.val.isSet()) {
        cfg.basedir = try o.val.getAs([]const u8);
        set.basedir = true;
    };
    if (opts.get("set_ports")) |o| if (o.val.isSet()) {
        cfg.set_ports = try o.val.getAs(bool);
        set.set_ports = true;
    };
    if (opts.get("exit_on_error")) |o| if (o.val.isSet()) {
        cfg.exit_on_error = try o.val.getAs(bool);
        set.exit_on_error = true;
    };
    if (opts.get("exit_on_stop")) |o| if (o.val.isSet()) {
        cfg.exit_on_stop = try o.val.getAs(bool);
        set.exit_on_stop = true;
    };
    if (opts.get("logtime")) |o| if (o.val.isSet()) {
        cfg.logtime = try o.val.getAs(bool);
        set.logtime = true;
    };
    if (opts.get("rpc_server")) |o| if (o.val.isSet()) {
        cfg.rpc_server = try o.val.getAs(bool);
        set.rpc_server = true;
    };

    // Subcommand dispatch. cova auto-adds `help`/`usage`; treat them as help.
    const intent: Intent = blk: {
        if (root_cmd.matchSubCmd("check") != null) break :blk .check;
        if (root_cmd.matchSubCmd("version") != null) break :blk .version;
        if (root_cmd.matchSubCmd("help") != null) break :blk .help;
        if (root_cmd.matchSubCmd("usage") != null) break :blk .help;
        if (root_cmd.matchSubCmd("start")) |sub| {
            const procs = try multiVal(alloc, sub, "PROCESS");
            break :blk .{ .start = procs };
        }
        if (root_cmd.matchSubCmd("run")) |sub| {
            const command = singleVal(sub, "COMMAND") orelse return error.MissingRunCommand;
            const args = try multiVal(alloc, sub, "PROCESS");
            break :blk .{ .run = .{ .command = command, .args = args } };
        }
        if (root_cmd.matchSubCmd("export")) |sub| {
            const format = singleVal(sub, "FORMAT") orelse return error.MissingExportFormat;
            const location = singleVal(sub, "LOCATION") orelse return error.MissingExportLocation;
            break :blk .{ .@"export" = .{ .format = format, .location = location } };
        }
        // No subcommand given: render the root help ourselves (cova only
        // prints help via `--help`/`help`/`usage`, not on bare invocation)
        // so the user sees usage instead of a silent success.
        try root_cmd.help(stderr);
        try stderr.flush();
        break :blk .help;
    };

    return .{
        .intent = intent,
        .config = cfg,
        .set_flags = set,
        .arena = arena,
    };
}

fn singleVal(cmd: *const CommandT, name: []const u8) ?[]const u8 {
    const vals = cmd.getVals(.{}) catch return null;
    const v = vals.get(name) orelse return null;
    if (!v.isSet()) return null;
    return v.getAs([]const u8) catch null;
}

fn multiVal(alloc: Allocator, cmd: *const CommandT, name: []const u8) ![]const []const u8 {
    const vals = try cmd.getVals(.{});
    const v = vals.get(name) orelse return &.{};
    if (!v.isSet()) return &.{};
    const all = try v.getAllAs([]const u8);
    // Re-allocate with our arena so lifetime aligns with ParseResult.arena.
    const out = try alloc.alloc([]const u8, all.len);
    for (all, 0..) |s, i| out[i] = s;
    return out;
}
