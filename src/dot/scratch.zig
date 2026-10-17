//! Explicit temporary nesting storage. No recursive call-stack frames.
const std = @import("std");
const location = @import("parser_support").location;

const event = @import("events.zig");

/// Grammar continuations are shared; only the sink's private saved state varies.
/// No builder state is part of an event delivered to a consumer.
pub fn For(comptime Context: type) type {
    return struct {
        const Self = @This();
        pub const Frame = struct {
            parent_open: location.Span,
            start: location.Span = undefined,
            role: event.ScopeRole = .left,
            id: event.ScopeId = undefined,
            context: Context = undefined,
            edge: ?event.Edge = null,
            link_operator: ?event.EdgeOperator = null,
            link_operator_span: ?location.Span = null,
        };

        pub const Storage = struct { frames: []Self.Frame = &.{} };

        pub fn Fixed(comptime capacities: struct { nesting: usize }) type {
            return struct {
                frames: [capacities.nesting]Self.Frame = undefined,
                pub const byte_size = @sizeOf(@This());
                pub fn storage(self: *@This()) Self.Storage {
                    return .{ .frames = &self.frames };
                }
            };
        }

        /// Owned by the facade. Allocator-backed stacks start empty and grow only when
        /// nesting requires it; fixed stacks never allocate. Pop reuses peak capacity.
        /// Active depth is bounded by the u32 source domain; allocation sizes stay usize.
        pub const Stack = @import("parser_support").stack.Stack(Self.Frame, u32);
    };
}

test "fixed nesting frames are reused by siblings" {
    const S = For(void);
    const Stack = S.Stack;
    const Frame = S.Frame;
    try std.testing.expect(@FieldType(Stack, "len") == u32);
    var fixed: S.Fixed(.{ .nesting = 1 }) = .{};
    var stack: Stack = .{ .frames = fixed.storage().frames };
    const span: location.Span = .{ .start = 0, .len = 1 };
    for (0..1000) |_| {
        try stack.push(.{ .parent_open = span });
        try std.testing.expectError(error.NestingStorageExhausted, stack.push(.{ .parent_open = span }));
        try std.testing.expectEqualDeep(span, stack.pop().parent_open);
    }
    try std.testing.expect(@sizeOf(Frame) > @sizeOf(location.Span));
}
