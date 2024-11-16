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
        for (self.procfile.procs) |proc| {
            var child = process.Child.init(&.{ "/bin/sh", "-c", proc.command }, self.allocator);
            _ = try child.spawn();

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
