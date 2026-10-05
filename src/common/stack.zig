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
                // Try allocator remapping before a copying fallback. On failure
                // realloc preserves the old allocation and all active frames.
                self.frames = try allocator.realloc(self.frames, capacity);
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

test "stack growth remaps in place without a second allocation" {
    inline for (.{ u32, usize }) |Index| {
        var buffer: [512]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        var tracked = std.testing.FailingAllocator.init(fixed.allocator(), .{ .fail_index = 1 });
        var stack: Stack(u64, Index) = .{ .allocator = tracked.allocator() };
        try stack.push(0);
        const address = stack.frames.ptr;
        for (1..17) |i| try stack.push(i);
        try std.testing.expectEqual(address, stack.frames.ptr);
        try std.testing.expectEqual(@as(usize, 32), stack.frames.len);
        try std.testing.expectEqual(@as(usize, 1), tracked.allocations);
        try std.testing.expectEqual(@as(usize, 5), tracked.resize_index);
        try std.testing.expect(!tracked.has_induced_failure);
        for (0..17) |i| try std.testing.expectEqual(@as(u64, 16 - i), stack.pop());
        stack.deinit();
        try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    }
}

test "stack failed remap and allocation retain frames before a copying retry" {
    inline for (.{ u32, usize }) |Index| {
        var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
        var stack: Stack(u64, Index) = .{ .allocator = tracked.allocator() };
        try stack.push(41);
        const address = stack.frames.ptr;
        try std.testing.expectError(error.OutOfMemory, stack.push(42));
        try std.testing.expectEqual(address, stack.frames.ptr);
        try std.testing.expectEqual(@as(Index, 1), stack.len);
        try std.testing.expectEqual(@as(u64, 41), stack.top().*);
        tracked.fail_index = 2;
        try stack.push(42);
        try std.testing.expect(stack.frames.ptr != address);
        try std.testing.expectEqual(@as(usize, 2), stack.frames.len);
        try std.testing.expectEqual(@as(u64, 42), stack.pop());
        try std.testing.expectEqual(@as(u64, 41), stack.pop());
        stack.deinit();
        try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    }
}
