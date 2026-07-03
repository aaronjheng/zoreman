const std = @import("std");
const mem = std.mem;
const net = std.net;
const Allocator = mem.Allocator;
const Io = std.Io;

const supervisor_mod = @import("supervisor.zig");

/// Wire protocol: one JSON object per line in each direction.
///
/// Request:  {"cmd":"start|stop|stop-all|restart|restart-all|list|status","args":["..."]}
/// Response: {"ok":true,"out":"...","err":"..."}
///
/// Connections close after a single request/response cycle, like Go net/rpc.
pub const Request = struct {
    cmd: []const u8,
    args: []const []const u8 = &.{},
};

pub const Response = struct {
    ok: bool,
    out: []const u8 = "",
    err: []const u8 = "",
};

/// Encode a Response to writer as a single JSON line.
pub fn writeResponse(out: *Io.Writer, resp: Response) !void {
    try out.writeAll("{\"ok\":");
    try out.writeAll(if (resp.ok) "true" else "false");
    try out.writeAll(",\"out\":");
    try writeJsonString(out, resp.out);
    try out.writeAll(",\"err\":");
    try writeJsonString(out, resp.err);
    try out.writeAll("}\n");
    try out.flush();
}

/// Decode one Request from a single JSON line. Returned slices are
/// allocated by `allocator`; use an arena for automatic cleanup.
pub fn parseRequest(allocator: Allocator, line: []const u8) !Request {
    const result = try std.json.parseFromSliceLeaky(struct {
        cmd: []const u8,
        args: []const []const u8 = &.{},
    }, allocator, line, .{ .allocate = .alloc_always });
    return .{ .cmd = result.cmd, .args = result.args };
}

/// Encode a Request to writer as a single JSON line.
pub fn writeRequest(out: *Io.Writer, req: Request) !void {
    try out.writeAll("{\"cmd\":");
    try writeJsonString(out, req.cmd);
    try out.writeAll(",\"args\":[");
    for (req.args, 0..) |a, i| {
        if (i != 0) try out.writeAll(",");
        try writeJsonString(out, a);
    }
    try out.writeAll("]}\n");
    try out.flush();
}

/// Parse a Response JSON line. Returned slices are owned by `parsed`'s arena;
/// caller must `deinit()` returned `Parsed`.
pub fn parseResponse(allocator: Allocator, line: []const u8) !std.json.Parsed(Response) {
    return std.json.parseFromSlice(Response, allocator, line, .{ .allocate = .alloc_always });
}

fn writeJsonString(out: *Io.Writer, s: []const u8) !void {
    try out.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try out.print("\\u{x:0>4}", .{c});
                } else {
                    try out.writeByte(c);
                }
            },
        }
    }
    try out.writeByte('"');
}
