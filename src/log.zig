const std = @import("std");
const fs = std.fs;
const io = std.io;

pub const ProcLogger = struct {
    pub fn write(src: fs.File, name: []const u8, max_proc_name_length: usize) !void {
        var reader = src.reader();
        var writer = io.getStdErr().writer();
        var buf: [2048]u8 = undefined;

        _ = max_proc_name_length;

        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            _ = try writer.print("{s} | {s}", .{ name, line });
            try writer.writeByte('\n');
        }
    }
};
