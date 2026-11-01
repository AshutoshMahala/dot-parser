const dot = @import("dot_parser");
const Graph = dot.ir.Lowering(.{}).Graph.MaterializedFor(.{ .attributes = false, .adjacency = .forward });
export fn invalid(graph: *const Graph) void {
    var nodes = graph.nodeIterator();
    if (nodes.next()) |node| _ = node.edges(.{ .direction = .incoming });
}
