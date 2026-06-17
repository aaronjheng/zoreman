const std = @import("std");
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const proto = @import("rpc_proto.zig");

const logger = log.scoped(.zoreman);

pub const ClientError = error{
    ConnectFailed,
    InvalidServerAddress,
    RpcError,
} || Allocator.Error;

/// Run one of the goreman `run` subcommands by issuing a single RPC request.
/// `server_addr` is in `host:port` form. `cmd` is the verb to send. Outputs
/// any server-provided text to stdout (for `list`/`status`).
pub fn run(
    allocator: Allocator,
    io: Io,
    stdout: *Io.Writer,
    server_addr: []const u8,
    cmd: []const u8,
    args: []const []const u8,
) !void {
    const colon = mem.lastIndexOfScalar(u8, server_addr, ':') orelse return error.InvalidServerAddress;
    const host = server_addr[0..colon];
    const port = std.fmt.parseInt(u16, server_addr[colon + 1 ..], 10) catch return error.InvalidServerAddress;

    var addr = Io.net.IpAddress.parse(host, port) catch return error.InvalidServerAddress;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return error.ConnectFailed;
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var rbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var r = stream.reader(io, &rbuf);

    try proto.writeRequest(&w.interface, .{ .cmd = cmd, .args = args });

    const line_opt = r.interface.takeDelimiter('\n') catch return error.RpcError;
    const line = line_opt orelse return error.RpcError;

    var parsed = proto.parseResponse(allocator, line) catch return error.RpcError;
    defer parsed.deinit();
    const resp = parsed.value;

    if (resp.out.len > 0) {
        try stdout.writeAll(resp.out);
        try stdout.flush();
    }
    if (!resp.ok) {
        try writeErr(io, "zoreman: {s}\n", .{resp.err});
        return error.RpcError;
    }
}

fn writeErr(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.writer(Io.File.stderr(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
