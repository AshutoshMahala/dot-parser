const dot = @import("dot_parser");
export fn rejected(graph: *const dot.ir.Lowering(.{}).Graph) void {
    var result = graph.materialize(.{ .attributtes = false }) catch return;
    result.deinit();
}
