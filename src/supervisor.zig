const std = @import("std");
const posix = std.posix;
const process = std.process;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;

const Procfile = @import("procfile.zig").Procfile;
const ProcLogger = @import("log.zig").ProcLogger;

const logger = log.scoped(.zoreman);

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
        const logFn = ProcLogger.write;

        var max_proc_name_length: usize = 0;
        for (self.procfile.procs) |proc| {
            const proc_name_length = proc.name.len;
            if (proc_name_length > max_proc_name_length) max_proc_name_length = proc_name_length;
        }

        for (self.procfile.procs) |proc| {
            var child = process.Child.init(&.{ "/bin/sh", "-c", proc.command }, self.allocator);
            child.stderr_behavior = .Pipe;
            child.stdout_behavior = .Pipe;
            child.pgid = 0;

            logger.info("Starting {s}", .{proc.name});
            _ = try child.spawn();
            logger.info("{s} started: {d}", .{ proc.name, child.id });

            var t1 = try std.Thread.spawn(.{ .allocator = self.allocator }, logFn, .{ child.stdout.?, proc.name, max_proc_name_length });
            var t2 = try std.Thread.spawn(.{ .allocator = self.allocator }, logFn, .{ child.stderr.?, proc.name, max_proc_name_length });

            t1.detach();
            t2.detach();

            try self.procs.append(child);
        }

        for (self.procs.items) |*proc| {
            _ = proc.*.wait() catch |err| {
                logger.info("Wait Process {d} failed {}", .{ proc.id, err });
            };
        }

        logger.info("Supervisor stopped", .{});
    }

    pub fn stop(self: *Self) !void {
        for (self.procs.items) |*proc| {
            logger.info("Terminating {d}\n", .{proc.id});
            try posix.kill(proc.id, posix.SIG.INT);
        }
    }

    pub fn deinit(self: Self) void {
        self.procs.deinit();
    }
};
