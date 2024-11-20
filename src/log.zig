const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;

pub const ProcLogger = struct {
    const Self = @This();

    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    fs: fs.File = io.getStdOut(),

    pub fn write(self: *Self, src: fs.File, name: []const u8, max_proc_name_length: usize) !void {
        var reader = src.reader();
        var buf: [2048]u8 = undefined;

        _ = max_proc_name_length;

        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            self.mutex.lock();
            defer self.mutex.unlock();

            const writer = self.fs.writer();
            _ = try writer.print("{s} | {s}", .{ name, line });
            try writer.writeByte('\n');
        }
    }
};
