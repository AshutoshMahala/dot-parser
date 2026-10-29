const dot = @import("dot_parser");
export fn rejected() void {
    _ = dot.Profile(.{ .policy = .{ .attributes = .{ .label = false } } });
}
