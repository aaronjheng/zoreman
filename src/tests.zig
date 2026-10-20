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
const completion = @import("completion.zig");

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
// Config (env)
// -----------------------------------------------------------------------

test "config: defaults" {
    const c: config.Config = .{};
    try testing.expectEqualStrings("Procfile", c.procfile);
    try testing.expectEqual(@as(usize, 1), c.env_files.len);
    try testing.expectEqualStrings(".env", c.env_files[0]);
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
// Log coloring
// -----------------------------------------------------------------------

test "log: colorFor cycles through goreman palette" {
    try testing.expectEqual(@as(u8, 32), log_mod.colorFor(0));
    try testing.expectEqual(@as(u8, 36), log_mod.colorFor(1));
    try testing.expectEqual(@as(u8, 35), log_mod.colorFor(2));
    try testing.expectEqual(@as(u8, 33), log_mod.colorFor(3));
    try testing.expectEqual(@as(u8, 34), log_mod.colorFor(4));
    try testing.expectEqual(@as(u8, 31), log_mod.colorFor(5));
    // Wraps around for processes beyond the palette size.
    try testing.expectEqual(@as(u8, 32), log_mod.colorFor(6));
    try testing.expectEqual(@as(u8, 36), log_mod.colorFor(7));
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

// -----------------------------------------------------------------------
// Shell completion (word-position logic; names injected, no filesystem)
// -----------------------------------------------------------------------

const proc_names = [_][]const u8{ "db", "web", "worker" };

fn expectCandidates(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

fn completeWords(words: []const []const u8, names: ?[]const []const u8) ![]const []const u8 {
    return completion.completeWithNames(testing.allocator, words, names);
}

test "completion: empty line offers root subcommands" {
    const got = try completeWords(&.{}, null);
    defer testing.allocator.free(got);
    try expectCandidates(&.{ "check", "completion", "export", "help", "run", "start", "version" }, got);
}

test "completion: prefix filters subcommands" {
    const got = try completeWords(&.{"st"}, null);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"start"}, got);
}

test "completion: dash partial offers long options" {
    const got = try completeWords(&.{"--pro"}, null);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"--procfile"}, got);
}

test "completion: start position offers proc names" {
    const got = try completeWords(&.{ "start", "w" }, &proc_names);
    defer testing.allocator.free(got);
    try expectCandidates(&.{ "web", "worker" }, got);
}

test "completion: start excludes already-typed names" {
    const got = try completeWords(&.{ "start", "web", "w" }, &proc_names);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"worker"}, got);
}

test "completion: unreadable procfile offers no names" {
    const got = try completeWords(&.{ "start", "" }, null);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "completion: run command position offers run commands" {
    const got = try completeWords(&.{ "run", "" }, null);
    defer testing.allocator.free(got);
    try expectCandidates(
        &.{ "list", "restart", "restart-all", "start", "status", "stop", "stop-all" },
        got,
    );
}

test "completion: run proc commands offer proc names" {
    const got = try completeWords(&.{ "run", "stop", "we" }, &proc_names);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"web"}, got);

    const got2 = try completeWords(&.{ "run", "restart", "web", "w" }, &proc_names);
    defer testing.allocator.free(got2);
    try expectCandidates(&.{"worker"}, got2);
}

test "completion: run list takes no further args" {
    const got = try completeWords(&.{ "run", "list", "" }, null);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "completion: unknown run command offers nothing" {
    const got = try completeWords(&.{ "run", "bogus", "" }, &proc_names);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "completion: export completes format only" {
    const got = try completeWords(&.{ "export", "u" }, null);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"upstart"}, got);

    const got2 = try completeWords(&.{ "export", "upstart", "" }, null);
    defer testing.allocator.free(got2);
    try testing.expectEqual(@as(usize, 0), got2.len);
}

test "completion: completion offers shell names" {
    const got = try completeWords(&.{ "completion", "z" }, null);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"zsh"}, got);
}

test "completion: help completes subcommands" {
    const got = try completeWords(&.{ "help", "st" }, null);
    defer testing.allocator.free(got);
    try expectCandidates(&.{"start"}, got);
}

test "completion: option-value position offers nothing" {
    // Cursor right after -f/--env/--basedir/--procfile or a trailing `=`:
    // shells fall back to filename completion.
    for ([_][]const []const u8{
        &.{ "-f", "" },
        &.{ "--procfile", "" },
        &.{ "--procfile=", "" },
        &.{ "--basedir", "" },
        &.{ "-e", "" },
        &.{ "-p", "" },
    }) |words| {
        const got = try completeWords(words, &proc_names);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
}

test "completion: bool/unknown short opts consume no value" {
    // -h is a cova-added toggle: the next word is still the subcommand.
    const got = try completeWords(&.{ "-h", "start", "w" }, &proc_names);
    defer testing.allocator.free(got);
    try expectCandidates(&.{ "web", "worker" }, got);
}

test "completion: dash separator forces positionals" {
    const got = try completeWords(&.{ "--", "start", "w" }, &proc_names);
    defer testing.allocator.free(got);
    try expectCandidates(&.{ "web", "worker" }, got);
}

test "completion: abbreviated long option captures procfile" {
    // cova accepts `--proc PATH` as an abbreviation of `--procfile PATH`.
    // completeWithNames injects names, so assert indirectly: the value `x`
    // must be consumed as the option value, leaving `start` as the
    // subcommand (proc names offered) rather than becoming one itself.
    const got = try completeWords(&.{ "--proc", "x", "start", "" }, &proc_names);
    defer testing.allocator.free(got);
    try expectCandidates(&proc_names, got);
}
