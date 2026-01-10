const std = @import("std");
const fs = std.fs;

pub const ProcLogger = struct {
    const Self = @This();

    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    fs: fs.File = fs.File.stdout(),
    buffer: [1024]u8 = undefined,
    reader_buffer: [1024]u8 = undefined,

    pub fn write(self: *Self, src: fs.File, name: []const u8, max_proc_name_length: usize) !void {
        var reader = src.reader(&self.reader_buffer).interface;

        _ = max_proc_name_length;

        while (reader.takeDelimiterExclusive('\n')) |line| {
            self.mutex.lock();
            defer self.mutex.unlock();

            var writer = self.fs.writer(&self.buffer);
            _ = try writer.interface.print("{s} | {s}", .{ name, line });
            try writer.interface.writeByte('\n');
        } else |err| {
            if (err != error.EndOfStream) {
                return err;
            }
        }
    }
};
