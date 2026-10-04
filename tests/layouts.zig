//! Keep the target-qualified current-layout table in docs/PERFORMANCE.md and
//! the scanner guidance in docs/EXECUTION.md / src/dot/lexer/lexer.zig honest.
//! These are development layout guards, not portable ABI or memory-budget values.
const std = @import("std");
const builtin = @import("builtin");
const dot = @import("dot_parser");

test "documented current DOT layouts match native aarch64 macOS" {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return error.SkipZigTest;
    const Controlled = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    try std.testing.expectEqual(@as(usize, 1088), @sizeOf(dot.Profile(.{}).Session));
    try std.testing.expectEqual(@as(usize, 1152), @sizeOf(Controlled.Session));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(dot.lexer.For(.scalar)));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(dot.lexer.For(.block)));
}
