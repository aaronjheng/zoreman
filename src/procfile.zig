const std = @import("std");
const Allocator = std.mem.Allocator;

const Proc = @import("proc.zig").Proc;

pub const Procfile = struct {
    const Self = @This();

    allocator: Allocator,
    procs: std.ArrayList(*Proc),
    proc_set: std.StringHashMap(*Proc),

    pub fn init(allocator: Allocator, filepath: []const u8) !Procfile {
        const cwd = std.fs.cwd();

        var file = try cwd.openFile(filepath, .{});
        defer file.close();

        var procs = std.ArrayList(*Proc).init(allocator);
        var proc_set = std.StringHashMap(*Proc).init(allocator);

        var buffered = std.io.bufferedReader(file.reader());
        var r = buffered.reader();
        var buf: [1024]u8 = undefined;
        while (try r.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const parts = try splitN(u8, allocator, line, ':', 2);
            defer allocator.free(parts);

            if (parts.len != 2) {
                continue;
            }

            const name = std.mem.trim(u8, parts[0], " ");
            const command = std.mem.trim(u8, parts[1], " ");

            const proc = try allocator.create(Proc);
            proc.* = try Proc.init(allocator, name, command);

            const new_name = try allocator.dupe(u8, name);
            try procs.append(proc);
            try proc_set.put(new_name, proc);
        }

        return .{
            .allocator = allocator,
            .procs = procs,
            .proc_set = proc_set,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.procs.items) |proc| {
            proc.deinit();
            self.allocator.destroy(proc);
        }

        var iter = self.proc_set.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }

        self.procs.deinit();
        self.proc_set.deinit();
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
