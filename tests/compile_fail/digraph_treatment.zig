const dot = @import("dot_parser");
comptime {
    _ = dot.Policy{ .validation = .{ .digraph = .{ .treated_as = .auto } } };
}
