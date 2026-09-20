const dot = @import("dot_parser");
comptime {
    _ = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{
        .treated_as = .auto,
        .operator_mismatch = .err,
    } } } });
}
