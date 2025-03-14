const std = @import("std");
const fs = std.fs;
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const Allocator = mem.Allocator;

const Proc = @import("proc.zig").Proc;
const Procfile = @import("procfile.zig").Procfile;
const ProcLogger = @import("log.zig").ProcLogger;

const logger = log.scoped(.zoreman);

pub const ProcLoggerWrapper = struct {
    pub fn write(p: *ProcLogger, src: fs.File, name: []const u8, max_proc_name_length: usize) !void {
        try p.write(src, name, max_proc_name_length);
    }
};

pub const Supervisor = struct {
    const Self = @This();

    procfile: Procfile,
    proc_logger: ProcLogger,
    allocator: Allocator,

    procs: std.ArrayList(*Proc),
    proc_set: std.StringHashMap(*Proc),

    pub fn init(allocator: Allocator, procfile: Procfile) !Supervisor {
        return .{
            .allocator = allocator,
            .proc_logger = .{},
            .procfile = procfile,
            .procs = std.ArrayList(*Proc).init(allocator),
            .proc_set = std.StringHashMap(*Proc).init(allocator),
        };
    }

    pub fn start(self: *Self, processes: ?[][]const u8) !void {
        if (processes) |ps| {
            for (ps) |p| {
                if (self.procfile.proc_set.get(p)) |proc| {
                    try self.procs.append(proc);
                    try self.proc_set.put(proc.name, proc);
                } else {
                    logger.err("Process not found: {s}", .{p});
                    return error.ProcessNotFound;
                }
            }
        } else {
            for (self.procfile.procs.items) |proc| {
                try self.procs.append(proc);
                try self.proc_set.put(proc.name, proc);
            }
        }

        var max_proc_name_length: usize = 10;
        for (self.procs.items) |proc| {
            const proc_name_length = proc.name.len;
            if (proc_name_length > max_proc_name_length) max_proc_name_length = proc_name_length;
        }

        for (self.procs.items) |proc| {
            var child = process.Child.init(&.{ "/bin/sh", "-c", proc.command }, self.allocator);
            child.stderr_behavior = .Pipe;
            child.stdout_behavior = .Pipe;
            if (@hasField(process.Child, "pgid")) {
                child.pgid = 0;
            }

            logger.info("Starting {s}", .{proc.name});
            _ = try child.spawn();
            logger.info("{s} started: {d}", .{ proc.name, child.id });

            var t1 = try std.Thread.spawn(
                .{ .allocator = self.allocator },
                ProcLoggerWrapper.write,
                .{ &self.proc_logger, child.stdout.?, proc.name, max_proc_name_length },
            );
            var t2 = try std.Thread.spawn(
                .{ .allocator = self.allocator },
                ProcLoggerWrapper.write,
                .{ &self.proc_logger, child.stderr.?, proc.name, max_proc_name_length },
            );

            t1.detach();
            t2.detach();

            proc.process = child;
        }

        for (self.procs.items) |proc| {
            _ = proc.process.?.wait() catch |err| {
                logger.info("Wait Process {d} failed {}", .{ proc.*.process.?.id, err });
            };
        }

        logger.info("Supervisor stopped", .{});
    }

    pub fn stop(self: *Self) !void {
        for (self.procs.items) |proc| {
            const pid = proc.process.?.id;
            logger.info("Terminating {s} {d}\n", .{ proc.name, pid });
            try posix.kill(pid, posix.SIG.INT);
        }
    }

    pub fn deinit(self: *Self) void {
        self.procs.deinit();
        self.proc_set.deinit();
    }
};
