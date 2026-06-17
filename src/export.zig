const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const procfile_mod = @import("procfile.zig");

pub const Error = error{UnknownFormat} || Allocator.Error;

/// Generate one upstart conf per Procfile entry into `out_dir_path`. Mirrors
/// goreman's `exportUpstart`. `procfile_path` is used to resolve the `.env`
/// adjacent to the Procfile and to compute `chdir` for each conf.
pub fn upstart(
    allocator: Allocator,
    io: Io,
    pf: *const procfile_mod.Procfile,
    procfile_path: []const u8,
    baseport: u16,
    out_dir_path: []const u8,
) !void {
    // Resolve absolute Procfile path so chdir paths in the conf are stable
    // regardless of where init reads them from.
    const abs_procfile = if (std.fs.path.isAbsolute(procfile_path))
        try allocator.dupe(u8, procfile_path)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, procfile_path });
    };
    defer allocator.free(abs_procfile);
    const procfile_dir = std.fs.path.dirname(abs_procfile) orelse ".";

    const env_path = try std.fs.path.join(allocator, &.{ procfile_dir, ".env" });
    defer allocator.free(env_path);
    const env_pairs = readEnvFile(allocator, io, env_path) catch null;
    defer if (env_pairs) |pairs| {
        for (pairs) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(pairs);
    };

    Io.Dir.cwd().createDirPath(io, out_dir_path) catch |err| switch (err) {
        else => return err,
    };
    var dir = try Io.Dir.cwd().openDir(io, out_dir_path, .{});
    defer dir.close(io);

    for (pf.entries, 0..) |entry, i| {
        const filename = try std.fmt.allocPrint(allocator, "app-{s}.conf", .{entry.name});
        defer allocator.free(filename);

        var file = try dir.createFile(io, filename, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var w = file.writerStreaming(io, &buf);
        const out = &w.interface;

        try out.print("start on starting app-{s}\n", .{entry.name});
        try out.print("stop on stopping app-{s}\n", .{entry.name});
        try out.writeAll("respawn\n\n");

        // Match the runtime port assignment: baseport + index*100, so the
        // exported configs run each entry on the same port the supervisor
        // would have used.
        const port: u32 = baseport + @as(u32, @intCast(i)) * 100;
        try out.print("env PORT={d}\n", .{port});
        if (env_pairs) |pairs| {
            for (pairs) |kv| {
                const escaped = try escapeSingleQuotes(allocator, kv.value);
                defer allocator.free(escaped);
                try out.print("env {s}='{s}'\n", .{ kv.key, escaped });
            }
        }

        try out.writeAll("\nsetuid app\n\n");
        try out.print("chdir {s}\n\n", .{procfile_dir});
        try out.print("exec {s}\n", .{entry.command});
        try out.flush();
    }
}

const KV = struct { key: []u8, value: []u8 };

fn readEnvFile(allocator: Allocator, io: Io, path: []const u8) ![]KV {
    const cwd = Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);

    var buf: [4096]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    const contents = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(contents);

    var list: std.ArrayList(KV) = .empty;
    errdefer {
        for (list.items) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        list.deinit(allocator);
    }

    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        var key = line[0..eq];
        var value = line[eq + 1 ..];
        if (mem.startsWith(u8, key, "export ")) key = key[7..];
        key = mem.trim(u8, key, " \t");
        value = mem.trim(u8, value, " \t");
        if (key.len == 0) continue;
        try list.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn escapeSingleQuotes(allocator: Allocator, s: []const u8) ![]u8 {
    var n_quotes: usize = 0;
    for (s) |c| if (c == '\'') {
        n_quotes += 1;
    };
    if (n_quotes == 0) return allocator.dupe(u8, s);

    const out = try allocator.alloc(u8, s.len + n_quotes);
    var oi: usize = 0;
    for (s) |c| {
        if (c == '\'') {
            out[oi] = '\\';
            oi += 1;
        }
        out[oi] = c;
        oi += 1;
    }
    return out;
}
