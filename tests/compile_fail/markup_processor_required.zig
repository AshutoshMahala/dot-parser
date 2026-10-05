const dot = @import("dot_parser");
comptime {
    _ = dot.Profile(.{ .policy = .{ .markup = .process } });
}
