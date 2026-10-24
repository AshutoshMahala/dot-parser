const dot = @import("dot_parser");
export fn rejected(graph: *const dot.ir.Lowering(.{}).Graph) void {
    var result = graph.materializationSession(.{ .attributtes = true }) catch return;
    result.deinit();
}
