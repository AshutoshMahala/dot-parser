const dot = @import("dot_parser");
comptime {
    _ = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } });
}
