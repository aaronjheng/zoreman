const std = @import("std");
const time = std.time;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// ANSI foreground color codes cycled across processes, mirroring goreman's
/// palette so concurrent processes are visually distinguishable.
const colors = [_]u8{
    32, // green
    36, // cyan
    35, // magenta
    33, // yellow
    34, // blue
    31, // red
};

/// Resolve the ANSI color code for a process by its position in the proc list.
pub fn colorFor(index: usize) u8 {
    return colors[index % colors.len];
}

/// Thread-safe stdout-bound process log writer. Writes one line at a time,
/// guaranteeing that lines from concurrent producers do not interleave.
///
/// `LogSink.write` is intended to be called from a dedicated reader thread per
/// pipe. The sink does not own the file or its buffer; each reader thread
/// supplies its own reader buffer via `runReader`.
pub const LogSink = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    max_name_width: usize,
    show_time: bool,

    pub fn init(io: Io, max_name_width: usize, show_time: bool) LogSink {
        return .{ .io = io, .max_name_width = max_name_width, .show_time = show_time };
    }

    /// Print one line, with proc name prefix and (optional) timestamp.
    /// `line` should not contain a trailing newline. `color_index` selects
    /// the ANSI color used for the prefix (timestamp + name + separator),
    /// matching goreman's per-process coloring.
    pub fn writeLine(self: *LogSink, name: []const u8, line: []const u8, color_index: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: [4096]u8 = undefined;
        var w = Io.File.writer(Io.File.stdout(), self.io, &buf);
        const out = &w.interface;

        // Color the entire prefix (timestamp + name + " | ") so processes are
        // visually distinguishable; reset before the log content.
        const color = colorFor(color_index);
        try out.print("\x1b[{d}m", .{color});
        if (self.show_time) {
            const ts = Io.Timestamp.now(self.io, .real);
            const seconds_in_day: i64 = @mod(ts.toSeconds(), 86400);
            const total: u64 = @intCast(seconds_in_day);
            const hh = (total / 3600) % 24;
            const mm = (total / 60) % 60;
            const ss = total % 60;
            try out.print("{d:0>2}:{d:0>2}:{d:0>2} ", .{ hh, mm, ss });
        }
        // Right-align the proc name to max_name_width.
        var pad: usize = 0;
        if (name.len < self.max_name_width) pad = self.max_name_width - name.len;
        var i: usize = 0;
        while (i < pad) : (i += 1) try out.writeByte(' ');
        try out.print("{s} | ", .{name});
        try out.writeAll("\x1b[m");
        try out.print("{s}\n", .{line});
        try out.flush();
    }
};

/// Reader thread entry point: reads lines from `src`, dispatches to the sink.
/// On EOF or error, returns. Must be called with a unique `reader_buffer`.
///
/// `name` must outlive this call (caller owns). `color_index` is the
/// process's position in the proc list, used to pick a stable ANSI color.
pub fn runReader(
    sink: *LogSink,
    io: Io,
    src: Io.File,
    name: []const u8,
    color_index: usize,
    reader_buffer: []u8,
) void {
    var reader = Io.File.reader(src, io, reader_buffer);
    while (true) {
        const maybe_line = reader.interface.takeDelimiter('\n') catch return;
        const line = maybe_line orelse return; // null = EOF
        sink.writeLine(name, line, color_index) catch return;
    }
}
