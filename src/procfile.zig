const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProcInfo = struct {
    const Self = @This();

    allocator: Allocator,

    name: []const u8,
    command: []const u8,
    proc: ?std.process.Child = null,

    pub fn init(allocator: Allocator, name: []const u8, command: []const u8) !ProcInfo {
        return ProcInfo{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .command = try allocator.dupe(u8, command),
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.name);
        self.allocator.free(self.command);
    }
};

pub const Procfile = struct {
    const Self = @This();

    allocator: Allocator,
    procs: []*ProcInfo,

    pub fn init(allocator: Allocator, filepath: []const u8) !Procfile {
        const cwd = std.fs.cwd();

        var file = try cwd.openFile(filepath, .{});
        defer file.close();

        var procs = std.ArrayList(*ProcInfo).init(allocator);
        errdefer procs.deinit();

        var buffered = std.io.bufferedReader(file.reader());
        var r = buffered.reader();
        var buf: [1024]u8 = undefined;
        while (try r.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const parts = try splitN(u8, allocator, line, ':', 2);
            defer allocator.free(parts);

            if (parts.len != 2) {
                continue;
            }

            const proc = try allocator.create(ProcInfo);
            proc.* = try ProcInfo.init(allocator, std.mem.trim(u8, parts[0], " "), std.mem.trim(u8, parts[1], " "));

            try procs.append(proc);
        }

        return .{
            .allocator = allocator,
            .procs = try procs.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.procs) |proc| {
            proc.deinit();
            self.allocator.destroy(proc);
        }

        self.allocator.free(self.procs);
    }
};

fn splitN(comptime T: type, allocator: Allocator, s: []const T, delimiter: T, n: usize) ![][]const T {
    var parts = std.ArrayList([]const T).init(allocator);
    errdefer parts.deinit();

    var iterator = std.mem.splitScalar(T, s, delimiter);

    var cnt = @as(usize, 0);
    while (iterator.next()) |part| {
        try parts.append(part);

        cnt += 1;

        if (cnt == n - 1) {
            const rest = iterator.rest();
            try parts.append(rest);

            break;
        }
    }

    return parts.toOwnedSlice();
}
