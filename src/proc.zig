const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Proc = struct {
    const Self = @This();

    allocator: Allocator,

    name: []const u8,
    command: []const u8,
    process: ?std.process.Child = null,

    pub fn init(allocator: Allocator, name: []const u8, command: []const u8) !Proc {
        return Proc{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .command = try allocator.dupe(u8, command),
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.name);
        self.allocator.free(self.command);
    }
};
