const std = @import("std");
const dot = @import("dot_parser");
export fn rejected() void {
    const allocator: std.mem.Allocator = undefined;
    const hook: dot.ir.Cancellation = undefined;
    _ = dot.ir.Lowering(.{}).parse(allocator, "digraph{}", .{ .lowering = .{ .cancellation = hook } }) catch {};
}
