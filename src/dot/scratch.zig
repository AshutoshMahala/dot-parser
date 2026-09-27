//! Explicit temporary nesting storage. No recursive call-stack frames.
const std = @import("std");
const location = @import("parser_support").location;

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
pub const Stack = @import("parser_support").stack.Stack(Frame, usize);

test "fixed nesting frames are reused by siblings" {
    var fixed: Fixed(.{ .nesting = 1 }) = .{};
    var stack: Stack = .{ .frames = fixed.storage().frames };
    const span: location.Span = .{ .start = 0, .len = 1 };
    for (0..1000) |_| {
        try stack.push(.{ .parent_open = span });
        try std.testing.expectError(error.NestingStorageExhausted, stack.push(.{ .parent_open = span }));
        try std.testing.expectEqualDeep(span, stack.pop().parent_open);
    }
    try std.testing.expect(@sizeOf(Frame) > @sizeOf(location.Span));
}
