const dot = @import("dot_parser");
export fn rejected(graph: *const dot.ir.Lowering(.{}).Graph, attributes: bool) void {
    var result = graph.materializationSession(.{ .attributes = attributes }) catch return;
    result.deinit();
}
