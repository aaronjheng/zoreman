const std = @import("std");
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;

const proto = @import("rpc_proto.zig");
const supervisor_mod = @import("supervisor.zig");

const logger = log.scoped(.zoreman);

/// RPC server runs on a dedicated thread. Accepts connections, dispatches one
/// JSON request per connection, replies with one JSON response, then closes.
///
/// The server holds a pointer to the live `Supervisor`; all state changes are
/// performed via supervisor methods that take the supervisor mutex.
pub const Server = struct {
    allocator: Allocator,
    io: Io,
    supervisor: *supervisor_mod.Supervisor,
    server: Io.net.Server,
    thread: ?Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: Allocator,
        io: Io,
        supervisor: *supervisor_mod.Supervisor,
        host: []const u8,
        port: u16,
    ) !Server {
        var addr = try Io.net.IpAddress.parse(host, port);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .io = io,
            .supervisor = supervisor,
            .server = server,
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop_flag.store(true, .seq_cst);
        // Close socket so accept unblocks.
        self.server.deinit(self.io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn start(self: *Server) !void {
        self.thread = try Thread.spawn(.{}, runLoop, .{self});
    }

    fn runLoop(self: *Server) void {
        while (!self.stop_flag.load(.seq_cst)) {
            const stream = self.server.accept(self.io) catch return;
            self.handleConn(stream) catch |err| {
                logger.err("rpc handle: {}", .{err});
            };
        }
    }

    fn handleConn(self: *Server, stream: Io.net.Stream) !void {
        defer stream.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        var w = stream.writer(self.io, &wbuf);

        const line_opt = r.interface.takeDelimiter('\n') catch return;
        const line = line_opt orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aalloc = arena.allocator();

        const req = proto.parseRequest(aalloc, line) catch {
            try proto.writeResponse(&w.interface, .{ .ok = false, .err = "bad request" });
            return;
        };

        const resp = self.dispatch(aalloc, req) catch |err| blk: {
            const msg = std.fmt.allocPrint(aalloc, "{}", .{err}) catch "internal error";
            break :blk proto.Response{ .ok = false, .err = msg };
        };
        try proto.writeResponse(&w.interface, resp);
    }

    fn dispatch(self: *Server, alloc: Allocator, req: proto.Request) !proto.Response {
        const sup = self.supervisor;
        if (mem.eql(u8, req.cmd, "list")) {
            const out = try sup.rpcList(alloc);
            return .{ .ok = true, .out = out };
        }
        if (mem.eql(u8, req.cmd, "status")) {
            const out = try sup.rpcStatus(alloc);
            return .{ .ok = true, .out = out };
        }
        if (mem.eql(u8, req.cmd, "stop")) {
            for (req.args) |name| try sup.rpcStop(name);
            return .{ .ok = true };
        }
        if (mem.eql(u8, req.cmd, "stop-all")) {
            try sup.rpcStopAll();
            return .{ .ok = true };
        }
        if (mem.eql(u8, req.cmd, "start")) {
            for (req.args) |name| try sup.rpcStart(name);
            return .{ .ok = true };
        }
        if (mem.eql(u8, req.cmd, "restart")) {
            for (req.args) |name| try sup.rpcRestart(name);
            return .{ .ok = true };
        }
        if (mem.eql(u8, req.cmd, "restart-all")) {
            try sup.rpcRestartAll();
            return .{ .ok = true };
        }
        return .{ .ok = false, .err = "unknown command" };
    }
};
