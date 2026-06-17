const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

/// A static Procfile entry: name + command line. Reflects exactly one Procfile
/// line, as parsed from disk. Runtime state for a running process lives in
/// `supervisor.zig`.
pub const Entry = struct {
    name: []const u8,
    command: []const u8,
};

pub const ParseError = error{
    NoValidEntry,
    DuplicateProcName,
    EmptyCommand,
} || Allocator.Error;

pub const ReadError = ParseError || error{
    OpenFileFailed,
    ReadFailed,
    StreamTooLong,
};

/// Owns parsed Procfile data. `entries` preserves source order; `set` provides
/// O(1) name lookup. Both reference strings owned by `arena`.
pub const Procfile = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    set: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Procfile) void {
        self.arena.deinit();
    }

    /// Lookup an entry by name. Returns null if not found.
    pub fn find(self: *const Procfile, name: []const u8) ?*const Entry {
        const idx = self.set.get(name) orelse return null;
        return &self.entries[idx];
    }

    /// Order-preserving sorted copy of entry names. Caller frees.
    pub fn sortedNames(self: *const Procfile, allocator: Allocator) ![][]const u8 {
        const names = try allocator.alloc([]const u8, self.entries.len);
        for (self.entries, 0..) |e, i| names[i] = e.name;
        std.mem.sort([]const u8, names, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return names;
    }
};

/// Parse a Procfile from raw bytes following goreman semantics:
/// - skip blank lines
/// - skip lines whose first non-space char is `#`
/// - split on the first `:`; lines without `:` are skipped
/// - trim name and command of surrounding whitespace
/// - lines with empty name are skipped
/// - lines with empty command are an error (zoreman tightening over goreman)
/// - duplicate names are an error
/// - returns NoValidEntry if no entries result
pub fn parse(parent_allocator: Allocator, source: []const u8) ParseError!Procfile {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    var set: std.StringHashMapUnmanaged(usize) = .empty;

    var lines = mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const name_raw = line[0..colon];
        const command_raw = line[colon + 1 ..];
        const name = mem.trim(u8, name_raw, " \t");
        const command = mem.trim(u8, command_raw, " \t");
        if (name.len == 0) continue;
        if (command.len == 0) return error.EmptyCommand;

        if (set.contains(name)) return error.DuplicateProcName;

        const name_dup = try allocator.dupe(u8, name);
        const command_dup = try allocator.dupe(u8, command);

        try entries.append(allocator, .{ .name = name_dup, .command = command_dup });
        try set.put(allocator, name_dup, entries.items.len - 1);
    }

    if (entries.items.len == 0) return error.NoValidEntry;

    return .{
        .arena = arena,
        .entries = try entries.toOwnedSlice(allocator),
        .set = set,
    };
}

/// Read and parse a Procfile from disk.
pub fn parseFile(allocator: Allocator, io: Io, path: []const u8) !Procfile {
    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const contents = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(contents);

    return parse(allocator, contents);
}
