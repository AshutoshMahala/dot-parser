const dot = @import("dot_parser");
export fn rejected() void {
    _ = dot.ir.Lowering(.{}).loweringBounds(.{}, .{ .policy = .{} }) catch unreachable;
}
