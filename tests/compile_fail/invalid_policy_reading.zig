const dot = @import("dot_parser");
comptime {
    _ = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{
        .treated_as = .generic,
        .operator_reading = .as_written,
    } } } });
}
