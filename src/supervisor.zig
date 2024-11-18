const std = @import("std");
const process = std.process;
const Allocator = std.mem.Allocator;

const Procfile = @import("procfile.zig").Procfile;

pub const Supervisor = struct {
    const Self = @This();

    procfile: Procfile,
    allocator: Allocator,

    procs: std.ArrayList(std.process.Child),

    pub fn init(allocator: Allocator, procfile: Procfile) !Supervisor {
        return .{
            .allocator = allocator,
            .procfile = procfile,
            .procs = std.ArrayList(std.process.Child).init(allocator),
        };
    }

    pub fn start(self: *Self) !void {
        const logFn = struct {
            pub fn write(src: std.fs.File) !void {
                var reader = src.reader();
                var writer = std.io.getStdErr().writer();
                var buf: [2048]u8 = undefined;

                while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
                    _ = try writer.write(line);
                    try writer.writeByte('\n');
                }
            }
        }.write;

        for (self.procfile.procs) |proc| {
            var child = process.Child.init(&.{ "/bin/sh", "-c", proc.command }, self.allocator);
            child.stderr_behavior = .Pipe;
            child.stdout_behavior = .Pipe;

            _ = try child.spawn();

            var t1 = try std.Thread.spawn(.{ .allocator = self.allocator }, logFn, .{child.stdout.?});
            var t2 = try std.Thread.spawn(.{ .allocator = self.allocator }, logFn, .{child.stderr.?});

            t1.detach();
            t2.detach();

            try self.procs.append(child);
        }

        for (self.procs.items) |*proc| {
            _ = try proc.*.wait();
        }
    }

    pub fn stop(self: *Self) !void {
        for (self.procs.items) |*proc| {
            std.debug.print("stop", .{});
            _ = try proc.*.kill();
        }
    }

    pub fn deinit(self: Self) void {
        self.procs.deinit();
    }
};
