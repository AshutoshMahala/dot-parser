//! Explicit reusable nesting frames. Parser scratch is not retained output.
const std = @import("std");
const Span = @import("parser_support").location.Span;
pub const Frame = struct { name: Span, handle: u32 = 0 };
pub const Storage = struct { frames: []Frame = &.{} };
pub fn Fixed(comptime nesting: u32) type {
    return struct {
        frames: [nesting]Frame = undefined,
        pub const byte_size = @sizeOf(@This());
        pub fn storage(self: *@This()) Storage {
            return .{ .frames = &self.frames };
        }
    };
}
pub const Stack = struct {
    frames: []Frame = &.{},
    len: u32 = 0,
    allocator: ?std.mem.Allocator = null,
    pub fn push(self: *Stack, frame: Frame) error{ OutOfMemory, NestingStorageExhausted }!void {
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
    pub fn top(self: *Stack) *Frame {
        return &self.frames[self.len - 1];
    }
    pub fn deinit(self: *Stack) void {
        if (self.allocator) |a| a.free(self.frames);
        self.* = .{};
    }
};
