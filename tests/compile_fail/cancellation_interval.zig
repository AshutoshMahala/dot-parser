const dot = @import("dot_parser");
comptime {
    _ = dot.Profile(.{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } });
}
