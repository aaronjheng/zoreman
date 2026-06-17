const std = @import("std");
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const time = std.time;
const Allocator = mem.Allocator;
const Io = std.Io;
const Thread = std.Thread;

const procfile_mod = @import("procfile.zig");
const log_mod = @import("log.zig");

const logger = log.scoped(.zoreman);

/// Runtime state for one managed process. Decoupled from the static Procfile
/// entry: name/command are borrowed slices owned by the Procfile.
pub const RuntimeProc = struct {
    name: []const u8,
    command: []const u8,
    port: ?u16 = null,
    /// Set when the proc is currently running. Must be guarded by
    /// `Supervisor.mutex`.
    child: ?process.Child = null,
    /// True if a recent stop was supervisor-initiated, so a non-zero exit is
    /// not treated as an error trigger for `exit-on-error`.
    stopped_by_supervisor: bool = false,
    /// Threads servicing this child. None outlive the child.
    stdout_thread: ?Thread = null,
    stderr_thread: ?Thread = null,
    wait_thread: ?Thread = null,
    /// Per-thread reader buffers; allocated in `spawnLocked` and freed when
    /// the wait_thread observes child exit.
    stdout_buffer: []u8 = &.{},
    stderr_buffer: []u8 = &.{},
};

pub const SupervisorOptions = struct {
    set_ports: bool = true,
    baseport: u16 = 5000,
    exit_on_error: bool = false,
    exit_on_stop: bool = true,
    logtime: bool = true,
    /// Optional environment overrides (e.g. from .env). Merged on top of
    /// `parent_env` when constructing each child env.
    env_override: ?*const std.process.Environ.Map = null,
    parent_env: *const std.process.Environ.Map,
};

pub const Supervisor = struct {
    allocator: Allocator,
    io: Io,
    procs: std.ArrayList(RuntimeProc),
    sink: log_mod.LogSink,
    options: SupervisorOptions,

    mutex: Io.Mutex = .init,
    /// Signaled by wait_thread when a child exits, or by RPC after start.
    cond: Io.Condition = .init,
    /// Number of children currently running. Updated under mutex.
    running: usize = 0,
    /// Set true to request supervisor exit (e.g. SIGINT). Atomic so the
    /// signal handler can set it without taking the mutex.
    request_stop: std.atomic.Value(bool) = .init(false),
    /// Last non-zero, non-supervisor-stopped exit; used by exit_on_error.
    error_exit: bool = false,
    /// Number of in-flight RPC restart operations. While > 0, the main
    /// `run()` loop will not honor `exit_on_stop` even when `running` hits
    /// zero, so a restart of the last process can complete without the
    /// supervisor shutting down between stop and the replacement spawn.
    restarts_in_flight: usize = 0,

    pub fn init(
        allocator: Allocator,
        io: Io,
        pf: *const procfile_mod.Procfile,
        targets: ?[]const []const u8,
        options: SupervisorOptions,
    ) !Supervisor {
        var procs: std.ArrayList(RuntimeProc) = .empty;
        errdefer procs.deinit(allocator);

        if (targets) |names| {
            for (names) |n| {
                if (pf.find(n) == null) return error.UnknownProc;
            }
            for (names) |n| {
                const e = pf.find(n).?;
                try procs.append(allocator, .{ .name = e.name, .command = e.command });
            }
        } else {
            for (pf.entries) |e| {
                try procs.append(allocator, .{ .name = e.name, .command = e.command });
            }
        }

        var max_name: usize = 0;
        for (procs.items, 0..) |*rp, i| {
            if (rp.name.len > max_name) max_name = rp.name.len;
            if (options.set_ports) {
                // Compute in u32 so a large baseport or many entries can't
                // silently wrap; reject configurations that would overflow
                // u16 instead of `@intCast`-panicking later.
                const computed: u32 = @as(u32, options.baseport) + @as(u32, @intCast(i)) * 100;
                if (computed > std.math.maxInt(u16)) return error.PortOutOfRange;
                rp.port = @intCast(computed);
            }
        }

        return .{
            .allocator = allocator,
            .io = io,
            .procs = procs,
            .sink = log_mod.LogSink.init(io, max_name, options.logtime),
            .options = options,
        };
    }

    pub fn deinit(self: *Supervisor) void {
        // Caller is expected to call run() and wait for it to return cleanly,
        // then deinit. Joinable threads should already be done.
        for (self.procs.items) |*p| {
            if (p.stdout_buffer.len > 0) self.allocator.free(p.stdout_buffer);
            if (p.stderr_buffer.len > 0) self.allocator.free(p.stderr_buffer);
        }
        self.procs.deinit(self.allocator);
    }

    fn findIndexLocked(self: *Supervisor, name: []const u8) ?usize {
        for (self.procs.items, 0..) |p, i| {
            if (mem.eql(u8, p.name, name)) return i;
        }
        return null;
    }

    fn buildEnvForProc(self: *Supervisor, proc: *RuntimeProc) !std.process.Environ.Map {
        var env = std.process.Environ.Map.init(self.allocator);
        errdefer env.deinit();
        var it = self.options.parent_env.array_hash_map.iterator();
        while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
        if (self.options.env_override) |o| {
            var oit = o.array_hash_map.iterator();
            while (oit.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        // When set_ports is enabled (proc.port populated), unconditionally
        // override PORT so the per-process assignment is reliable. Users who
        // want their own PORT can disable injection with `--set-ports=false`,
        // which leaves proc.port null and skips this branch entirely.
        if (proc.port) |p| {
            var buf: [16]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{p});
            try env.put("PORT", s);
        }
        return env;
    }

    /// Caller must hold `self.mutex`.
    fn spawnLocked(self: *Supervisor, idx: usize) !void {
        const proc = &self.procs.items[idx];
        if (proc.child != null) return; // already running

        var env = try self.buildEnvForProc(proc);
        defer env.deinit();

        proc.stopped_by_supervisor = false;
        proc.child = try process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", proc.command },
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
            .environ_map = &env,
        });

        if (proc.stdout_buffer.len == 0) {
            proc.stdout_buffer = try self.allocator.alloc(u8, 4096);
        }
        if (proc.stderr_buffer.len == 0) {
            proc.stderr_buffer = try self.allocator.alloc(u8, 4096);
        }

        proc.stdout_thread = try Thread.spawn(.{}, log_mod.runReader, .{
            &self.sink, self.io, proc.child.?.stdout.?, proc.name, proc.stdout_buffer,
        });
        proc.stderr_thread = try Thread.spawn(.{}, log_mod.runReader, .{
            &self.sink, self.io, proc.child.?.stderr.?, proc.name, proc.stderr_buffer,
        });
        proc.wait_thread = try Thread.spawn(.{}, waitWorker, .{ self, idx });

        self.running += 1;
        if (proc.port) |port| {
            logger.info("Starting {s} on port {d}", .{ proc.name, port });
        } else {
            logger.info("Starting {s}", .{proc.name});
        }
    }

    /// Wait-thread body. Runs `wait()` on the child, then joins the log
    /// readers (the OS closes their pipes when the child dies, which makes
    /// the readers see EOF and return). Updates supervisor state and signals.
    fn waitWorker(self: *Supervisor, idx: usize) void {
        // Snapshot the child handle outside the lock so we can wait on it
        // without blocking RPC operations on the mutex.
        self.mutex.lockUncancelable(self.io);
        const proc_ptr = &self.procs.items[idx];
        var child_handle = proc_ptr.child.?;
        self.mutex.unlock(self.io);

        const term_or_err = child_handle.wait(self.io);
        const term = term_or_err catch null;

        // Rejoin readers (their pipes are closed by `wait` cleanup).
        self.mutex.lockUncancelable(self.io);
        const proc = &self.procs.items[idx];
        if (proc.stdout_thread) |t| {
            self.mutex.unlock(self.io);
            t.join();
            self.mutex.lockUncancelable(self.io);
            proc.stdout_thread = null;
        }
        if (proc.stderr_thread) |t| {
            self.mutex.unlock(self.io);
            t.join();
            self.mutex.lockUncancelable(self.io);
            proc.stderr_thread = null;
        }

        if (term) |t| {
            const abnormal = switch (t) {
                .exited => |code| code != 0,
                .signal => true,
                .stopped => false,
                .unknown => true,
            };
            if (abnormal and !proc.stopped_by_supervisor) {
                if (self.options.exit_on_error) self.error_exit = true;
            }
        }

        proc.child = null;
        self.running -= 1;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// Spawn every proc in `self.procs`, then block until all exit or
    /// `request_stop` is set.
    pub fn run(self: *Supervisor) !void {
        self.mutex.lockUncancelable(self.io);
        // Spawn all
        var i: usize = 0;
        while (i < self.procs.items.len) : (i += 1) {
            self.spawnLocked(i) catch |err| {
                logger.err("spawn {s} failed: {}", .{ self.procs.items[i].name, err });
            };
        }

        // Wait loop. Honor `exit_on_stop` only when no RPC restart is
        // currently bridging the gap between a stop and its replacement
        // spawn; otherwise a single-process Procfile would race shutdown
        // with the new child.
        while (true) {
            if (self.request_stop.load(.acquire)) break;
            if (self.options.exit_on_stop and self.running == 0 and self.restarts_in_flight == 0) break;
            if (self.error_exit) break;
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        // If we're exiting because of error or stop request, kill remaining.
        if (self.request_stop.load(.acquire) or self.error_exit) {
            self.stopAllLocked();
        }

        // Wait for all running children to exit.
        while (self.running > 0) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        // Join all wait_threads outside the lock.
        const indices_to_join = try self.allocator.alloc(usize, self.procs.items.len);
        defer self.allocator.free(indices_to_join);
        var n: usize = 0;
        for (self.procs.items, 0..) |*p, j| {
            if (p.wait_thread != null) {
                indices_to_join[n] = j;
                n += 1;
            }
        }
        self.mutex.unlock(self.io);

        for (indices_to_join[0..n]) |j| {
            const t = self.procs.items[j].wait_thread.?;
            t.join();
            self.procs.items[j].wait_thread = null;
        }

        logger.info("Supervisor stopped", .{});
        if (self.error_exit) return error.ChildFailed;
    }

    /// Caller must hold `self.mutex`.
    fn stopAllLocked(self: *Supervisor) void {
        for (self.procs.items) |*p| {
            self.stopOneLocked(p, posix.SIG.INT);
        }
    }

    /// Caller must hold `self.mutex`.
    fn stopOneLocked(_: *Supervisor, proc: *RuntimeProc, sig: posix.SIG) void {
        const child = &(proc.child orelse return);
        const pid = child.id orelse return;
        proc.stopped_by_supervisor = true;
        // pgid == pid because we spawned with pgid=0 (new pgrp).
        posix.kill(-pid, sig) catch |err| {
            logger.err("kill {s} ({d}): {}", .{ proc.name, pid, err });
        };
    }

    // -----------------------------------------------------------------
    // External API for signal handlers and RPC.
    // -----------------------------------------------------------------

    /// Request orderly shutdown. Async-signal-safe: does not take the
    /// mutex (which could deadlock if another thread holds it when the
    /// signal arrives). Instead it atomically sets the flag and wakes the
    /// condition variable via futex, which is signal-safe. Idempotent.
    pub fn requestStop(self: *Supervisor) void {
        if (self.request_stop.swap(true, .seq_cst)) return;
        self.cond.broadcast(self.io);
    }

    /// RPC: list proc names, one per line.
    pub fn rpcList(self: *Supervisor, alloc: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        for (self.procs.items) |p| {
            try buf.appendSlice(alloc, p.name);
            try buf.append(alloc, '\n');
        }
        return buf.toOwnedSlice(alloc);
    }

    /// RPC: status with `*name` for running, ` name` otherwise.
    pub fn rpcStatus(self: *Supervisor, alloc: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        for (self.procs.items) |p| {
            try buf.append(alloc, if (p.child != null) '*' else ' ');
            try buf.appendSlice(alloc, p.name);
            try buf.append(alloc, '\n');
        }
        return buf.toOwnedSlice(alloc);
    }

    /// RPC: stop a single proc by name. Returns error.UnknownProc if not in
    /// the proc list. Stopping a non-running proc is a no-op (mirrors
    /// goreman). The 10-second SIGKILL escalation is handled in a worker
    /// thread.
    pub fn rpcStop(self: *Supervisor, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idx = self.findIndexLocked(name) orelse return error.UnknownProc;
        const proc = &self.procs.items[idx];
        if (proc.child == null) return;
        // Capture the *current* pid before signaling, so the kill timer can
        // verify it's still acting on the same child later. Without this,
        // a fast restart that finishes within 10s would have the previous
        // timer SIGKILL the freshly-spawned replacement.
        const original_pid = proc.child.?.id orelse return;
        self.stopOneLocked(proc, posix.SIG.INT);
        const timer_args = TimerArgs{ .sup = self, .idx = idx, .pid = original_pid };
        const t = Thread.spawn(.{}, killTimerThread, .{timer_args}) catch |err| {
            logger.err("spawn kill-timer: {}", .{err});
            return;
        };
        t.detach();
    }

    /// RPC: stop all procs.
    pub fn rpcStopAll(self: *Supervisor) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopAllLocked();
    }

    /// RPC: start a single proc by name. Already-running procs are a no-op.
    pub fn rpcStart(self: *Supervisor, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idx = self.findIndexLocked(name) orelse return error.UnknownProc;
        const proc = &self.procs.items[idx];
        if (proc.child != null) return;
        try self.spawnLocked(idx);
    }

    /// RPC: restart a single proc. Brackets the operation with
    /// `restarts_in_flight` so the supervisor's `run()` loop will not honor
    /// `exit_on_stop` between the stop and the spawn even on a Procfile
    /// with a single entry.
    pub fn rpcRestart(self: *Supervisor, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        // Validate the name early; do not increment the counter on error.
        if (self.findIndexLocked(name) == null) {
            self.mutex.unlock(self.io);
            return error.UnknownProc;
        }
        self.restarts_in_flight += 1;
        self.mutex.unlock(self.io);

        defer {
            self.mutex.lockUncancelable(self.io);
            self.restarts_in_flight -= 1;
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);
        }

        try self.rpcStop(name);

        // Wait until the child has fully exited, then respawn.
        self.mutex.lockUncancelable(self.io);
        const idx = self.findIndexLocked(name) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownProc;
        };
        while (self.procs.items[idx].child != null) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        defer self.mutex.unlock(self.io);
        try self.spawnLocked(idx);
    }

    /// RPC: restart every proc.
    pub fn rpcRestartAll(self: *Supervisor) !void {
        // Snapshot names under lock.
        self.mutex.lockUncancelable(self.io);
        const names = try self.allocator.alloc([]const u8, self.procs.items.len);
        for (self.procs.items, 0..) |p, i| names[i] = p.name;
        self.mutex.unlock(self.io);
        defer self.allocator.free(names);

        for (names) |n| try self.rpcRestart(n);
    }
};

const TimerArgs = struct {
    sup: *Supervisor,
    idx: usize,
    /// Pid of the child this timer was created for. The timer must only
    /// escalate to SIGKILL if `proc.child` still has this exact pid: a
    /// successful restart between rpcStop and the 10s timeout will have
    /// replaced child with a new pid, and signaling that one would kill an
    /// innocent fresh process.
    pid: posix.pid_t,
};

fn killTimerThread(args: TimerArgs) void {
    Io.sleep(args.sup.io, Io.Duration.fromSeconds(10), .awake) catch return;
    args.sup.mutex.lockUncancelable(args.sup.io);
    defer args.sup.mutex.unlock(args.sup.io);
    if (args.idx >= args.sup.procs.items.len) return;
    const proc = &args.sup.procs.items[args.idx];
    const child = &(proc.child orelse return);
    const cur_pid = child.id orelse return;
    if (cur_pid != args.pid) return; // restart already replaced the process
    posix.kill(-args.pid, posix.SIG.KILL) catch {};
}
