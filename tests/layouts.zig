//! Keep the target/build-mode-qualified layout table in docs/PERFORMANCE.md and
//! the scanner guidance in docs/EXECUTION.md / src/dot/lexer/lexer.zig honest.
//! These are development layout guards, not portable ABI or memory-budget values.
const std = @import("std");
const builtin = @import("builtin");
const dot = @import("dot_parser");

test "documented current DOT layouts match native aarch64 macOS and build mode" {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return error.SkipZigTest;
    const Controlled = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    // Scalar scanner state, and therefore sessions containing it, have different
    // layouts with runtime safety enabled. Pin both sets instead of weakening
    // the guard to a ceiling or assuming a build-mode-independent ABI.
    const expected: struct { session: usize, controlled: usize, scalar: usize } = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ .session = 1120, .controlled = 1184, .scalar = 64 },
        .ReleaseFast, .ReleaseSmall => .{ .session = 1112, .controlled = 1176, .scalar = 56 },
    };
    try std.testing.expectEqual(expected.session, @sizeOf(dot.Profile(.{}).Session));
    try std.testing.expectEqual(expected.controlled, @sizeOf(Controlled.Session));
    try std.testing.expectEqual(expected.scalar, @sizeOf(dot.lexer.For(.scalar)));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(dot.lexer.For(.block)));
}
