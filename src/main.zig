const std = @import("std");
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const Allocator = mem.Allocator;
const Io = std.Io;

const dotenv = @import("dotenv");
const build_options = @import("build_options");

const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const procfile_mod = @import("procfile.zig");
const supervisor_mod = @import("supervisor.zig");
const export_mod = @import("export.zig");
const rpc_proto = @import("rpc_proto.zig");
const rpc_server_mod = @import("rpc_server.zig");
const rpc_client_mod = @import("rpc_client.zig");

const logger = log.scoped(.zoreman);

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .cova, .level = .info },
    },
};

/// Portable `chdir` wrapper. `std.posix.chdir` does not exist in Zig 0.16,
/// and `std.c.chdir` requires libc linkage which we don't force on Linux.
/// Dispatch by OS so the binary works on macOS and Linux without linking
/// libc on Linux. Returns 0 on success, non-zero on failure.
fn chdir(path: [*:0]const u8) c_int {
    return switch (@import("builtin").os.tag) {
        .linux => if (std.os.linux.chdir(path) == 0) 0 else -1,
        else => std.c.chdir(path),
    };
}

/// Globals only for signal handler. Set by `cmdStart` before installing
/// handlers; cleared after `run()` returns.
var g_supervisor: ?*supervisor_mod.Supervisor = null;

fn signalHandler(_: posix.SIG) callconv(.c) void {
    if (g_supervisor) |s| s.requestStop();
}

pub fn main(init: process.Init) !u8 {
    const io = init.io;
    const arena = init.arena;
    const gpa = init.gpa;

    // Stderr writer for help/error output.
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = Io.File.writer(Io.File.stderr(), io, &stderr_buf);
    const stderr = &stderr_w.interface;

    // CLI parse.
    const argv_slice = try init.minimal.args.toSlice(arena.allocator());

    var parsed = cli.parse(gpa, argv_slice, stderr) catch |err| {
        try stderr.print("zoreman: {s}\n", .{cliErrorMsg(err)});
        try stderr.flush();
        return 1;
    };
    defer parsed.deinit();

    // Informational commands (help, version) need neither a working basedir
    // nor a Procfile; serve them before any project-file access so a missing
    // basedir cannot break --help or version output.
    switch (parsed.intent) {
        .help => return 0,
        .version => return try cmdVersion(io),
        else => {},
    }

    // Apply env-driven defaults, gated by parsed.set_flags so they never
    // clobber an explicit CLI value.
    config_mod.applyEnv(&parsed.config, &parsed.set_flags, init.environ_map);

    // basedir: chdir before any file access.
    if (parsed.config.basedir) |dir| {
        const dir_z = try arena.allocator().dupeZ(u8, dir);
        if (chdir(dir_z) != 0) {
            try stderr.print("zoreman: chdir {s} failed\n", .{dir});
            try stderr.flush();
            return 1;
        }
    }

    return switch (parsed.intent) {
        .help => unreachable, // handled above
        .version => unreachable, // handled above
        .check => try cmdCheck(gpa, io, &parsed, stderr),
        .start => |procs| try cmdStart(gpa, io, init.environ_map, &parsed, procs, stderr),
        .run => |r| try cmdRun(gpa, io, init.environ_map, &parsed, r.command, r.args, stderr),
        .@"export" => |e| try cmdExport(gpa, io, &parsed, e.format, e.location, stderr),
    };
}

fn cliErrorMsg(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingRunCommand => "run requires a command",
        error.MissingExportFormat => "export requires a format",
        error.MissingExportLocation => "export requires a location",
        else => @errorName(err),
    };
}

fn cmdVersion(io: Io) !u8 {
    var buf: [128]u8 = undefined;
    var w = Io.File.writer(Io.File.stdout(), io, &buf);
    try w.interface.print("{s}\n", .{build_options.version});
    try w.interface.flush();
    return 0;
}

fn cmdCheck(gpa: Allocator, io: Io, parsed: *cli.ParseResult, stderr: *Io.Writer) !u8 {
    var pf = procfile_mod.parseFile(gpa, io, parsed.config.procfile) catch |err| {
        try printFileError(stderr, parsed.config.procfile, err);
        return 1;
    };
    defer pf.deinit();

    const names = try pf.sortedNames(gpa);
    defer gpa.free(names);

    var buf: [4096]u8 = undefined;
    var w = Io.File.writer(Io.File.stdout(), io, &buf);
    const out = &w.interface;
    try out.writeAll("valid procfile detected (");
    for (names, 0..) |n, i| {
        if (i != 0) try out.writeAll(", ");
        try out.writeAll(n);
    }
    try out.writeAll(")\n");
    try out.flush();
    return 0;
}

fn cmdStart(
    gpa: Allocator,
    io: Io,
    parent_env: *std.process.Environ.Map,
    parsed: *cli.ParseResult,
    procs: []const []const u8,
    stderr: *Io.Writer,
) !u8 {
    var pf = procfile_mod.parseFile(gpa, io, parsed.config.procfile) catch |err| {
        try printFileError(stderr, parsed.config.procfile, err);
        return 1;
    };
    defer pf.deinit();

    // Validate target processes; fail loud before spawning any.
    if (procs.len > 0) {
        for (procs) |p| {
            if (pf.find(p) == null) {
                try stderr.print("zoreman: unknown proc: {s}\n", .{p});
                try stderr.flush();
                return 1;
            }
        }
    }

    // Load .env (optional). Stays in scope for the supervisor.
    var env_override = std.process.Environ.Map.init(gpa);
    defer env_override.deinit();
    dotenv.loadFrom(gpa, io, &env_override, parsed.config.env_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            try stderr.print("zoreman: parse {s}: {}\n", .{ parsed.config.env_file, err });
            try stderr.flush();
            return 1;
        },
    };

    var sup = supervisor_mod.Supervisor.init(gpa, io, &pf, if (procs.len == 0) null else procs, .{
        .set_ports = parsed.config.set_ports,
        .baseport = parsed.config.baseport,
        .exit_on_error = parsed.config.exit_on_error,
        .exit_on_stop = parsed.config.exit_on_stop,
        .logtime = parsed.config.logtime,
        .env_override = &env_override,
        .parent_env = parent_env,
    }) catch |err| {
        switch (err) {
            error.PortOutOfRange => try stderr.writeAll("zoreman: port out of range (baseport + offset > 65535)\n"),
            else => try stderr.print("zoreman: {}\n", .{err}),
        }
        try stderr.flush();
        return 1;
    };
    defer sup.deinit();

    g_supervisor = &sup;
    defer g_supervisor = null;

    const sa = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        // `posix.Sigaction.mask` is a `sigset_t`, whose layout differs
        // between platforms (a u32 on Darwin, an array on Linux). Use
        // `sigemptyset()` so the literal works portably.
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.HUP, &sa, null);

    // Optional RPC server.
    var rpc_server: ?rpc_server_mod.Server = null;
    defer if (rpc_server) |*s| s.deinit();
    if (parsed.config.rpc_server) {
        const host = config_mod.rpcListenHost(parent_env);
        rpc_server = rpc_server_mod.Server.init(gpa, io, &sup, host, parsed.config.port) catch |err| blk: {
            logger.err("rpc listen {s}:{d}: {}", .{ host, parsed.config.port, err });
            break :blk null;
        };
        if (rpc_server) |*s| {
            s.start() catch |err| logger.err("rpc start: {}", .{err});
        }
    }

    sup.run() catch |err| switch (err) {
        error.ChildFailed => return 1,
        else => return err,
    };
    return 0;
}

fn cmdRun(
    gpa: Allocator,
    io: Io,
    parent_env: *std.process.Environ.Map,
    parsed: *cli.ParseResult,
    command: []const u8,
    args: []const []const u8,
    stderr: *Io.Writer,
) !u8 {
    const known = [_][]const u8{ "start", "stop", "stop-all", "restart", "restart-all", "list", "status" };
    var ok = false;
    for (known) |k| if (mem.eql(u8, k, command)) {
        ok = true;
        break;
    };
    if (!ok) {
        try stderr.writeAll("zoreman: unknown command\n");
        try stderr.flush();
        return 1;
    }

    const server_addr = try config_mod.rpcServerAddress(gpa, parent_env, parsed.config.port);
    defer gpa.free(server_addr);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = Io.File.writer(Io.File.stdout(), io, &stdout_buf);

    rpc_client_mod.run(gpa, io, &stdout_w.interface, server_addr, command, args) catch |err| {
        try stderr.print("zoreman: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return 1;
    };
    return 0;
}

fn cmdExport(
    gpa: Allocator,
    io: Io,
    parsed: *cli.ParseResult,
    format: []const u8,
    location: []const u8,
    stderr: *Io.Writer,
) !u8 {
    if (!mem.eql(u8, format, "upstart")) {
        try stderr.print("zoreman: unknown export format: {s}\n", .{format});
        try stderr.flush();
        return 1;
    }
    var pf = procfile_mod.parseFile(gpa, io, parsed.config.procfile) catch |err| {
        try printFileError(stderr, parsed.config.procfile, err);
        return 1;
    };
    defer pf.deinit();

    export_mod.upstart(gpa, io, &pf, parsed.config.procfile, parsed.config.baseport, location) catch |err| {
        try stderr.print("zoreman: export upstart: {}\n", .{err});
        try stderr.flush();
        return 1;
    };
    return 0;
}

fn printFileError(stderr: *Io.Writer, path: []const u8, err: anyerror) !void {
    switch (err) {
        error.FileNotFound => try stderr.print("zoreman: open {s}: file not found\n", .{path}),
        error.NoValidEntry => try stderr.writeAll("zoreman: no valid entry\n"),
        error.DuplicateProcName => try stderr.writeAll("zoreman: duplicate proc name\n"),
        error.EmptyCommand => try stderr.writeAll("zoreman: empty command in Procfile\n"),
        else => try stderr.print("zoreman: {s}: {}\n", .{ path, err }),
    }
    try stderr.flush();
}
