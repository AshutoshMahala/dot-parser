const dot = @import("dot_parser");
export fn rejected(graph: *const dot.ir.Lowering(.{}).Graph) void {
    var result = graph.materializationSession(.{ .limits = .{ .max_pair = 10 } }) catch return;
    result.deinit();
}
