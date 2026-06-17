const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;

/// Runtime configuration. All fields default-initialized; override via env
/// or CLI flags in that order. Strings (when present) reference memory owned
/// by callers (e.g. argv arena).
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

/// Tracks whether each field was explicitly set by the user via CLI.
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
/// Per the documented precedence (defaults → env → CLI), env values must not
/// clobber an explicit CLI flag. `set` reports which fields were set on the
/// command line; matching fields are skipped here.
pub fn applyEnv(cfg: *Config, set: *const SetFlags, env: *const std.process.Environ.Map) void {
    if (!set.port) {
        if (env.get("GOREMAN_RPC_PORT")) |s| {
            if (fmt.parseInt(u16, s, 10)) |v| cfg.port = v else |_| {}
        }
    }
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
