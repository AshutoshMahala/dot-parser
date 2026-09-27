//! Reusable nesting storage, independent of frame payload and parser grammar.
//! The owner supplies fixed memory or an allocator, and enforces the Index
//! domain before pushing. Growth is unbudgeted and only for allocator-backed use.
const std = @import("std");

pub fn Stack(comptime Frame: type, comptime Index: type) type {
    return struct {
        const Self = @This();
        frames: []Frame = &.{},
        len: Index = 0,
        allocator: ?std.mem.Allocator = null,

        pub const Error = error{ OutOfMemory, NestingStorageExhausted };

        pub fn push(self: *Self, frame: Frame) Error!void {
            if (self.len == self.frames.len) {
                const allocator = self.allocator orelse return error.NestingStorageExhausted;
                const capacity = std.math.add(usize, self.frames.len, @max(self.frames.len, 1)) catch return error.OutOfMemory;
                const grown = try allocator.alloc(Frame, capacity);
                @memcpy(grown[0..self.len], self.frames[0..self.len]);
                allocator.free(self.frames);
                self.frames = grown;
            }
            self.frames[self.len] = frame;
            self.len += 1;
        }

        pub fn top(self: *Self) *Frame {
            std.debug.assert(self.len != 0);
            return &self.frames[self.len - 1];
        }

        pub fn pop(self: *Self) Frame {
            std.debug.assert(self.len != 0);
            self.len -= 1;
            return self.frames[self.len];
        }

        pub fn deinit(self: *Self) void {
            if (self.allocator) |allocator| allocator.free(self.frames);
            self.* = .{};
        }
    };
}

test "fixed stacks preserve index widths, exhaust without allocation and reuse frames" {
    inline for (.{ u32, usize }) |Index| {
        const S = Stack(u64, Index);
        try std.testing.expect(@FieldType(S, "len") == Index);
        var frames: [2]u64 = undefined;
        var stack: S = .{ .frames = &frames };
        defer stack.deinit();
        for (0..3) |_| {
            try stack.push(10);
            try stack.push(20);
            try std.testing.expectError(error.NestingStorageExhausted, stack.push(30));
            stack.top().* = 21;
            try std.testing.expectEqual(@as(u64, 21), stack.pop());
            try std.testing.expectEqual(@as(u64, 10), stack.pop());
        }
    }
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var stack: Stack(u64, u32) = .{ .allocator = allocator };
    defer stack.deinit();
    for (0..17) |i| try stack.push(i);
    const capacity = stack.frames.len;
    for (0..17) |i| try std.testing.expectEqual(@as(u64, 16 - i), stack.pop());
    for (0..17) |i| try stack.push(i);
    try std.testing.expectEqual(capacity, stack.frames.len);
}

test "growing stack preserves frames and releases every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
