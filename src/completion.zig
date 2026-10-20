const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = mem.Allocator;
const Io = std.Io;

const procfile_mod = @import("procfile.zig");

/// Shells with a generated completion script.
pub const Shell = enum {
    bash,
    fish,
    zsh,

    /// Available shells, sorted. Also the candidates for `zoreman completion <TAB>`.
    pub const names = [_][]const u8{ "bash", "fish", "zsh" };

    pub fn fromString(s: []const u8) ?Shell {
        inline for (std.meta.fields(Shell)) |f| {
            if (mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    /// Embedded completion script for this shell. The scripts call back into
    /// `zoreman __complete`, which computes the candidates (see `complete`).
    pub fn script(self: Shell) []const u8 {
        return switch (self) {
            .bash => @embedFile("completions/zoreman.bash"),
            .fish => @embedFile("completions/zoreman.fish"),
            .zsh => @embedFile("completions/_zoreman"),
        };
    }
};

/// Subcommands offered at the root position, sorted. `help`/`usage` are the
/// ones cova auto-adds. The hidden `__complete` protocol command is
/// deliberately not offered.
const root_subcommands = [_][]const u8{ "check", "completion", "export", "help", "run", "start", "version" };
/// Commands accepted by `zoreman run COMMAND`. Sorted; keep in sync with the
/// known-command list in main.zig.
const run_commands = [_][]const u8{ "list", "restart", "restart-all", "start", "status", "stop", "stop-all" };
/// Long options of the root command. Sorted; keep in sync with cli.zig.
const long_options = [_][]const u8{
    "--baseport",
    "--basedir",
    "--env",
    "--exit-on-error",
    "--exit-on-stop",
    "--help",
    "--logtime",
    "--port",
    "--procfile",
    "--rpc-server",
    "--set-ports",
    "--usage",
};

/// Result of scanning the words that precede the cursor.
const Scan = struct {
    /// First positional word: the subcommand, if any.
    sub: ?[]const u8 = null,
    /// Positional words after the subcommand (options and consumed option
    /// values excluded).
    sub_args: []const []const u8 = &.{},
    /// Value of `-f/--procfile` seen before the cursor, if any.
    procfile: ?[]const u8 = null,
    /// Value of `--basedir` seen before the cursor, if any.
    basedir: ?[]const u8 = null,
    /// True when the cursor sits in an option-value position (e.g. right
    /// after `-f`, `--basedir` or `--procfile=`): no word candidates, the
    /// shells fall back to filename completion.
    pending_value: bool = false,
};

/// Compute completion candidates for a partially typed command line.
///
/// This implements the `zoreman __complete` protocol used by the generated
/// shell scripts: `words` holds every word of the line after the program
/// name, with the word under the cursor last (possibly empty); e.g. for
/// `zoreman run stop we<TAB>` the shell passes `{ "run", "stop", "we" }`.
///
/// Candidates are sorted; callers print one per line. All failures
/// (unreadable Procfile, unknown words) degrade to fewer or empty
/// candidates — completion must never surface errors.
///
/// `alloc` should be an arena: intermediate allocations are not freed
/// individually, only the returned slice matters to the caller.
pub fn complete(alloc: Allocator, io: Io, words: []const []const u8) Allocator.Error![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var names: ?[]const []const u8 = null;
    blk: {
        const scan = scanWords(a, beforeWords(words)) catch break :blk;
        names = loadProcNames(a, io, scan.procfile, scan.basedir) catch null;
    }

    const raw = try completeWithNames(a, words, names);
    // `raw` may reference `arena`-owned strings (parsed proc names); copy the
    // candidates into `alloc` so they outlive the scratch arena.
    const out = try alloc.alloc([]const u8, raw.len);
    for (raw, 0..) |c, i| out[i] = try alloc.dupe(u8, c);
    return out;
}

/// `complete` with the Procfile names injected, so the pure word-position
/// logic is testable without touching the filesystem. `names` must already be
/// sorted; pass null to simulate an unreadable Procfile.
pub fn completeWithNames(
    alloc: Allocator,
    words: []const []const u8,
    names: ?[]const []const u8,
) Allocator.Error![]const []const u8 {
    const partial = if (words.len > 0) words[words.len - 1] else "";
    const before = if (words.len > 0) words[0 .. words.len - 1] else &[_][]const u8{};
    // Scan into scratch memory: only the candidate slice below is returned.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const scan = try scanWords(scratch.allocator(), before);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    const starts_with_dash = mem.startsWith(u8, partial, "-");

    // Cursor in an option-value position (e.g. after `-f`, `--env` or
    // `--basedir`): offer nothing so the shells fall back to filenames.
    // A dash-partial means the user is completing an option name, not a value.
    if (scan.pending_value and !starts_with_dash) return out.toOwnedSlice(alloc);

    if (scan.sub == null) {
        if (starts_with_dash) {
            try filterAppend(alloc, &out, &long_options, partial);
        } else {
            try filterAppend(alloc, &out, &root_subcommands, partial);
        }
        return out.toOwnedSlice(alloc);
    }

    const sub = scan.sub.?;
    if (mem.eql(u8, sub, "start")) {
        // `start PROCESS...` takes proc names, minus the ones already typed.
        try appendProcNames(alloc, &out, names, partial, scan.sub_args);
    } else if (mem.eql(u8, sub, "run")) {
        if (scan.sub_args.len == 0) {
            // `run COMMAND`: complete the command name itself.
            if (!starts_with_dash) try filterAppend(alloc, &out, &run_commands, partial);
        } else if (runTakesProcs(scan.sub_args[0])) {
            // `run start|stop|restart PROCESS...`.
            try appendProcNames(alloc, &out, names, partial, scan.sub_args[1..]);
        }
        // list/status/stop-all/restart-all/unknown take no further args.
    } else if (mem.eql(u8, sub, "export")) {
        if (scan.sub_args.len == 0 and !starts_with_dash) {
            try filterAppend(alloc, &out, &.{"upstart"}, partial);
        }
        // LOCATION is a directory: no candidates (shells fall back to files).
    } else if (mem.eql(u8, sub, "completion")) {
        if (scan.sub_args.len == 0 and !starts_with_dash) {
            try filterAppend(alloc, &out, &Shell.names, partial);
        }
    } else if (mem.eql(u8, sub, "help")) {
        if (scan.sub_args.len == 0 and !starts_with_dash) {
            try filterAppend(alloc, &out, &root_subcommands, partial);
        }
    }
    // check/version/__complete take no args.
    return out.toOwnedSlice(alloc);
}

/// The words before the cursor: everything but the last entry, which is the
/// (possibly empty) partial word being completed.
fn beforeWords(words: []const []const u8) []const []const u8 {
    if (words.len == 0) return &.{};
    return words[0 .. words.len - 1];
}

/// Scan the words before the cursor for the subcommand, its positional
/// arguments, and the option values that affect which Procfile to read.
/// Mirrors cova's parsing rules: `-f PATH`, `-fPATH`, `-f=PATH`,
/// `--procfile PATH`, `--procfile=PATH`, and abbreviated long option names
/// (`--proc` matches `--procfile`).
fn scanWords(alloc: Allocator, words: []const []const u8) Allocator.Error!Scan {
    var sub: ?[]const u8 = null;
    var sub_args: std.ArrayList([]const u8) = .empty;
    var procfile: ?[]const u8 = null;
    var basedir: ?[]const u8 = null;
    var pending = false;

    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const w = words[i];

        // `--` terminates option parsing.
        if (mem.eql(u8, w, "--")) {
            i += 1;
            while (i < words.len) : (i += 1) {
                if (sub == null) sub = words[i] else try sub_args.append(alloc, words[i]);
            }
            break;
        }

        // Long options.
        if (mem.startsWith(u8, w, "--")) {
            const body = w[2..];
            const eq = mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            // Check in RootCmd declaration order so ambiguous abbreviations
            // resolve the same way cova resolves them (first match wins).
            if (matchesLong(name, "procfile")) {
                if (eq) |e| {
                    if (e + 1 < body.len) {
                        procfile = body[e + 1 ..];
                    } else if (i + 1 >= words.len) {
                        pending = true; // `--procfile=`: completing its value
                    }
                } else if (i + 1 < words.len) {
                    i += 1;
                    procfile = words[i];
                } else {
                    pending = true; // `--procfile` at the cursor
                }
            } else if (matchesLong(name, "basedir")) {
                if (eq) |e| {
                    if (e + 1 < body.len) {
                        basedir = body[e + 1 ..];
                    } else if (i + 1 >= words.len) {
                        pending = true;
                    }
                } else if (i + 1 < words.len) {
                    i += 1;
                    basedir = words[i];
                } else {
                    pending = true;
                }
            } else if (matchesLong(name, "env") or matchesLong(name, "port") or matchesLong(name, "baseport")) {
                // Value-taking option whose value we don't need: consume it
                // so it is not mistaken for a positional word.
                if (eq == null) {
                    if (i + 1 < words.len) {
                        i += 1;
                    } else {
                        pending = true;
                    }
                } else if (eq.? + 1 >= body.len and i + 1 >= words.len) {
                    pending = true;
                }
            }
            // Unknown long options (help, toggles, garbage) take no value.
            continue;
        }

        // Short options. -f/-e/-p/-b take a value, either attached
        // (`-fPATH`, `-f=PATH`, `-p8080`) or as the next word; the rest
        // (cova's -h/-u and unknown letters) are toggles.
        if (w.len >= 2 and w[0] == '-') {
            if (w.len > 2) {
                // Attached value form. Only -f matters for completion.
                if (w[1] == 'f') {
                    const v = if (w[2] == '=') w[3..] else w[2..];
                    if (v.len > 0) {
                        procfile = v;
                    } else if (i + 1 >= words.len) {
                        pending = true; // `-f=`: completing its value
                    }
                }
                continue;
            }
            switch (w[1]) {
                'f', 'e', 'p', 'b' => {
                    if (i + 1 < words.len) {
                        i += 1;
                        if (w[1] == 'f') procfile = words[i];
                    } else {
                        pending = true; // value is the word under the cursor
                    }
                },
                else => {}, // toggle or unknown short: consumes nothing
            }
            continue;
        }

        // Positional word.
        if (sub == null) sub = w else try sub_args.append(alloc, w);
    }

    return .{
        .sub = sub,
        .sub_args = try sub_args.toOwnedSlice(alloc),
        .procfile = procfile,
        .basedir = basedir,
        .pending_value = pending,
    };
}

/// cova-compatible long-option name matching: exact (case-insensitive), or
/// abbreviated — the given name appears as a substring of the full name and
/// shares its first character.
fn matchesLong(given: []const u8, name: []const u8) bool {
    if (given.len == 0) return false;
    if (ascii.eqlIgnoreCase(given, name)) return true;
    if (!ascii.eqlIgnoreCase(given[0..1], name[0..1])) return false;
    return ascii.indexOfIgnoreCase(name, given) != null;
}

fn runTakesProcs(cmd: []const u8) bool {
    const proc_cmds = [_][]const u8{ "restart", "start", "stop" };
    for (proc_cmds) |c| if (mem.eql(u8, cmd, c)) return true;
    return false;
}

fn appendProcNames(
    alloc: Allocator,
    out: *std.ArrayList([]const u8),
    names: ?[]const []const u8,
    partial: []const u8,
    exclude: []const []const u8,
) Allocator.Error!void {
    const list = names orelse return;
    for (list) |n| {
        if (containsWord(exclude, n)) continue;
        if (mem.startsWith(u8, n, partial)) try out.append(alloc, n);
    }
}

fn filterAppend(
    alloc: Allocator,
    out: *std.ArrayList([]const u8),
    choices: []const []const u8,
    partial: []const u8,
) Allocator.Error!void {
    for (choices) |c| {
        if (mem.startsWith(u8, c, partial)) try out.append(alloc, c);
    }
}

fn containsWord(list: []const []const u8, s: []const u8) bool {
    for (list) |w| if (mem.eql(u8, w, s)) return true;
    return false;
}

/// Parse the Procfile a completion request refers to and return its names
/// sorted alphabetically. Returns null (never an error) when the Procfile
/// cannot be read or parsed: completion must degrade silently.
fn loadProcNames(
    alloc: Allocator,
    io: Io,
    procfile_opt: ?[]const u8,
    basedir_opt: ?[]const u8,
) !?[]const []const u8 {
    var path = procfile_opt orelse "Procfile";
    if (basedir_opt) |dir| {
        if (!std.fs.path.isAbsolute(path)) {
            path = try std.fs.path.join(alloc, &.{ dir, path });
        }
    }

    var pf = procfile_mod.parseFile(alloc, io, path) catch return null;
    defer pf.deinit();

    const sorted = try pf.sortedNames(alloc);
    defer alloc.free(sorted);
    // The strings in `sorted` live in the Procfile arena, which dies with
    // `pf`; copy them into `alloc` first.
    const names = try alloc.alloc([]const u8, sorted.len);
    for (sorted, 0..) |n, i| names[i] = try alloc.dupe(u8, n);
    return names;
}
