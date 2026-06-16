const std = @import("std");
const Io = std.Io;

pub const ProcLogger = struct {
    const Self = @This();

    mutex: Io.Mutex = Io.Mutex.init,
    io: Io,
    buffer: [1024]u8 = undefined,
    reader_buffer: [1024]u8 = undefined,

    pub fn write(self: *Self, src: Io.File, name: []const u8, max_proc_name_length: usize) !void {
        var reader = Io.File.reader(src, self.io, &self.reader_buffer);

        _ = max_proc_name_length;

        while (reader.interface.takeDelimiterExclusive('\n')) |line| {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            var writer = Io.File.writer(Io.File.stdout(), self.io, &self.buffer);
            _ = try writer.interface.print("{s} | {s}", .{ name, line });
            try writer.interface.writeByte('\n');
        } else |err| {
            if (err != error.EndOfStream) {
                return err;
            }
        }
    }
};
