const dot = @import("dot_parser");
export fn rejected() void {
    _ = dot.ir.Lowering(.{}).loweringBounds(.{}, .{ .limits = .{ .max_byte = 0 } }) catch unreachable;
}
