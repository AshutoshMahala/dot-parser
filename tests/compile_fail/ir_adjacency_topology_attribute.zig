const dot = @import("dot_parser");
const Graph = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } }).Graph.MaterializedFor(.{ .adjacency = .all });
export fn invalid(graph: *const Graph) void {
    var edges = graph.edgeIterator();
    if (edges.next()) |edge| _ = edge.attribute("color") catch unreachable;
}
