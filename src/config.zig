const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const Io = std.Io;

/// Runtime configuration. All fields default-initialized; override via env,
/// `.goreman`, then CLI flags in that order. Strings (when present) reference
/// memory owned by callers (e.g. argv arena).
pub const Config = struct {
    procfile: []const u8 = "Procfile",
    env_file: []const u8 = ".env",
    port: u16 = 8555,
    basedir: ?[]const u8 = null,
    baseport: u16 = 5000,
    set_ports: bool = true,
    exit_on_error: bool = false,
    exit_on_stop: bool = true,
    logtime: bool = true,
    rpc_server: bool = true,
};

/// Tracks whether each field was explicitly set by the user via CLI. Used to
/// avoid letting defaults stomp values from `.goreman`.
pub const SetFlags = struct {
    procfile: bool = false,
    env_file: bool = false,
    port: bool = false,
    basedir: bool = false,
    baseport: bool = false,
    set_ports: bool = false,
    exit_on_error: bool = false,
    exit_on_stop: bool = false,
    logtime: bool = false,
    rpc_server: bool = false,
};

/// Parse environment-driven defaults: GOREMAN_RPC_PORT.
///
/// Per the documented precedence (defaults → env → `.goreman` → CLI), env
/// values must not clobber an explicit CLI flag. `set` reports which fields
/// were set on the command line; matching fields are skipped here.
pub fn applyEnv(cfg: *Config, set: *const SetFlags, env: *const std.process.Environ.Map) void {
    if (!set.port) {
        if (env.get("GOREMAN_RPC_PORT")) |s| {
            if (fmt.parseInt(u16, s, 10)) |v| cfg.port = v else |_| {}
        }
    }
}

/// Parse a minimal subset of `.goreman` YAML. Only top-level scalar key/value
/// pairs are supported. Unknown keys are ignored. Comments (`#`) and blank
/// lines are skipped. Values with surrounding quotes are unquoted.
///
/// `scratch` is used for the file contents and is freed before return.
/// `strings` owns string fields stored on `Config` (`procfile`, `basedir`);
/// pass an arena allocator whose lifetime covers all subsequent reads of
/// `cfg`. This avoids leaking duped strings on debug builds, since `Config`
/// itself has no `deinit`.
pub fn applyGoremanFile(
    cfg: *Config,
    set: *const SetFlags,
    scratch: Allocator,
    strings: Allocator,
    io: Io,
    path: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const contents = try reader.interface.allocRemaining(scratch, .unlimited);
    defer scratch.free(contents);

    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = mem.trim(u8, line[0..colon], " \t");
        var value = mem.trim(u8, line[colon + 1 ..], " \t");
        // strip trailing inline comment if not quoted
        if (value.len > 0 and value[0] != '"' and value[0] != '\'') {
            if (mem.indexOfScalar(u8, value, '#')) |hi| value = mem.trim(u8, value[0..hi], " \t");
        }
        // unquote
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }

        if (mem.eql(u8, key, "procfile")) {
            if (!set.procfile) cfg.procfile = try strings.dupe(u8, value);
        } else if (mem.eql(u8, key, "port")) {
            if (!set.port) {
                cfg.port = fmt.parseInt(u16, value, 10) catch cfg.port;
            }
        } else if (mem.eql(u8, key, "baseport")) {
            if (!set.baseport) {
                cfg.baseport = fmt.parseInt(u16, value, 10) catch cfg.baseport;
            }
        } else if (mem.eql(u8, key, "basedir")) {
            if (!set.basedir) cfg.basedir = try strings.dupe(u8, value);
        } else if (mem.eql(u8, key, "exit_on_error")) {
            if (!set.exit_on_error) cfg.exit_on_error = parseBool(value) orelse cfg.exit_on_error;
        }
    }
}

fn parseBool(s: []const u8) ?bool {
    if (mem.eql(u8, s, "true") or mem.eql(u8, s, "True") or mem.eql(u8, s, "TRUE") or mem.eql(u8, s, "1") or mem.eql(u8, s, "yes")) return true;
    if (mem.eql(u8, s, "false") or mem.eql(u8, s, "False") or mem.eql(u8, s, "FALSE") or mem.eql(u8, s, "0") or mem.eql(u8, s, "no")) return false;
    return null;
}

/// RPC connection target: GOREMAN_RPC_SERVER or 127.0.0.1:<port>.
pub fn rpcServerAddress(allocator: Allocator, env: *const std.process.Environ.Map, port: u16) ![]u8 {
    if (env.get("GOREMAN_RPC_SERVER")) |s| return allocator.dupe(u8, s);
    return std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
}

/// RPC listen address: GOREMAN_RPC_ADDR or 0.0.0.0.
pub fn rpcListenHost(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("GOREMAN_RPC_ADDR")) |s| return s;
    return "0.0.0.0";
}
