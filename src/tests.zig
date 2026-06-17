//! Aggregate unit-test entry point. Add `test` blocks here or `pub` decls
//! that pull in tests from other modules.

const std = @import("std");
const testing = std.testing;

const procfile = @import("procfile.zig");
const config = @import("config.zig");
const exporter = @import("export.zig");
const cli = @import("cli.zig");
const log_mod = @import("log.zig");
const supervisor = @import("supervisor.zig");
const rpc_proto = @import("rpc_proto.zig");

// -----------------------------------------------------------------------
// Procfile parser
// -----------------------------------------------------------------------

test "procfile: empty file -> NoValidEntry" {
    const result = procfile.parse(testing.allocator, "");
    try testing.expectError(error.NoValidEntry, result);
}

test "procfile: only comments and blank lines -> NoValidEntry" {
    const result = procfile.parse(testing.allocator,
        \\# comment
        \\
        \\   # another
        \\
    );
    try testing.expectError(error.NoValidEntry, result);
}

test "procfile: skips no-colon and empty-name lines" {
    var pf = try procfile.parse(testing.allocator,
        \\nocolon
        \\: empty name
        \\web: echo ok
    );
    defer pf.deinit();
    try testing.expectEqual(@as(usize, 1), pf.entries.len);
    try testing.expectEqualStrings("web", pf.entries[0].name);
    try testing.expectEqualStrings("echo ok", pf.entries[0].command);
}

test "procfile: empty command -> EmptyCommand" {
    const result = procfile.parse(testing.allocator, "web: \n");
    try testing.expectError(error.EmptyCommand, result);
}

test "procfile: command with extra colons preserved" {
    var pf = try procfile.parse(testing.allocator, "web: echo a:b:c\n");
    defer pf.deinit();
    try testing.expectEqualStrings("echo a:b:c", pf.entries[0].command);
}

test "procfile: duplicate name -> DuplicateProcName" {
    const result = procfile.parse(testing.allocator,
        \\web: echo a
        \\web: echo b
    );
    try testing.expectError(error.DuplicateProcName, result);
}

test "procfile: sortedNames returns alphabetical names" {
    var pf = try procfile.parse(testing.allocator,
        \\worker: a
        \\api: b
        \\web: c
    );
    defer pf.deinit();
    const names = try pf.sortedNames(testing.allocator);
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("api", names[0]);
    try testing.expectEqualStrings("web", names[1]);
    try testing.expectEqualStrings("worker", names[2]);
}

test "procfile: preserves source order in entries" {
    var pf = try procfile.parse(testing.allocator,
        \\worker: a
        \\api: b
        \\web: c
    );
    defer pf.deinit();
    try testing.expectEqualStrings("worker", pf.entries[0].name);
    try testing.expectEqualStrings("api", pf.entries[1].name);
    try testing.expectEqualStrings("web", pf.entries[2].name);
}

// -----------------------------------------------------------------------
// Config (.goreman + env)
// -----------------------------------------------------------------------

test "config: defaults" {
    const c: config.Config = .{};
    try testing.expectEqualStrings("Procfile", c.procfile);
    try testing.expectEqualStrings(".env", c.env_file);
    try testing.expectEqual(@as(u16, 8555), c.port);
    try testing.expectEqual(@as(u16, 5000), c.baseport);
    try testing.expectEqual(true, c.set_ports);
    try testing.expectEqual(false, c.exit_on_error);
    try testing.expectEqual(true, c.exit_on_stop);
    try testing.expectEqual(true, c.logtime);
    try testing.expectEqual(true, c.rpc_server);
}

test "config: applyEnv reads GOREMAN_RPC_PORT" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GOREMAN_RPC_PORT", "9999");

    var c: config.Config = .{};
    const set: config.SetFlags = .{};
    config.applyEnv(&c, &set, &env);
    try testing.expectEqual(@as(u16, 9999), c.port);
}

test "config: applyEnv respects explicit CLI port" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GOREMAN_RPC_PORT", "9999");

    var c: config.Config = .{ .port = 4242 };
    const set: config.SetFlags = .{ .port = true };
    config.applyEnv(&c, &set, &env);
    try testing.expectEqual(@as(u16, 4242), c.port);
}

test "config: rpcServerAddress fallback" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const a = try config.rpcServerAddress(testing.allocator, &env, 1234);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("127.0.0.1:1234", a);
}

test "config: rpcServerAddress override" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("GOREMAN_RPC_SERVER", "10.0.0.1:5678");
    const a = try config.rpcServerAddress(testing.allocator, &env, 1234);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("10.0.0.1:5678", a);
}

// -----------------------------------------------------------------------
// RPC protocol
// -----------------------------------------------------------------------

test "rpc_proto: round-trip request" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try rpc_proto.writeRequest(&aw.writer, .{ .cmd = "stop", .args = &.{ "web", "worker" } });
    const wire = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, wire, "\"cmd\":\"stop\"") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"web\"") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"worker\"") != null);
}

test "rpc_proto: parseResponse" {
    const line = "{\"ok\":true,\"out\":\"web\\n\",\"err\":\"\"}";
    var parsed = try rpc_proto.parseResponse(testing.allocator, line);
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.ok);
    try testing.expectEqualStrings("web\n", parsed.value.out);
}
