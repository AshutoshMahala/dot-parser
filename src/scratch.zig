//! Explicit temporary nesting storage. No recursive call-stack frames.
const std = @import("std");
const location = @import("location.zig");

const event = @import("syntax_event.zig");

/// Internal continuation payload; consumers normally use FixedParseScratch.
pub const Frame = struct {
    parent_open: location.Span,
    start: location.Span = undefined,
    role: event.ScopeRole = .left,
    entry: event.ScopeEntry = undefined,
    edge: ?event.EdgeStatement = null,
    link_operator: ?event.EdgeOperator = null,
    link_operator_span: ?location.Span = null,
};

pub const Storage = struct { frames: []Frame = &.{} };

pub fn Fixed(comptime capacities: struct { nesting: usize }) type {
    return struct {
        frames: [capacities.nesting]Frame = undefined,
        pub const byte_size = @sizeOf(@This());
        pub fn storage(self: *@This()) Storage {
            return .{ .frames = &self.frames };
        }
    };
}

/// Owned by the facade. Allocator-backed stacks start empty and grow only when
/// nesting requires it; fixed stacks never allocate. Pop reuses peak capacity.
pub const Stack = struct {
    frames: []Frame = &.{},
    len: usize = 0,
    allocator: ?std.mem.Allocator = null,

    pub const Error = error{ OutOfMemory, NestingStorageExhausted };

    pub fn push(self: *Stack, frame: Frame) Error!void {
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

    pub fn pop(self: *Stack) Frame {
        std.debug.assert(self.len != 0);
        self.len -= 1;
        return self.frames[self.len];
    }

    pub fn deinit(self: *Stack) void {
        if (self.allocator) |allocator| allocator.free(self.frames);
        self.* = .{};
    }
};

test "fixed nesting frames are reused by siblings" {
    var fixed: Fixed(.{ .nesting = 1 }) = .{};
    var stack: Stack = .{ .frames = fixed.storage().frames };
    const span: location.Span = .{ .start = .start, .byte_len = 1 };
    for (0..1000) |_| {
        try stack.push(.{ .parent_open = span });
        try std.testing.expectError(error.NestingStorageExhausted, stack.push(.{ .parent_open = span }));
        try std.testing.expectEqualDeep(span, stack.pop().parent_open);
    }
    try std.testing.expect(@sizeOf(Frame) > @sizeOf(location.Span));
}
