//! Explicit reusable nesting frames. Parser scratch is not retained output.
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
pub const Stack = @import("parser_support").stack.Stack(Frame, u32);
