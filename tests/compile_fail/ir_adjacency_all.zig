const dot = @import("dot_parser");
const Graph = dot.ir.Lowering(.{}).Graph.MaterializedFor(.{ .adjacency = .backward });
export fn invalid(graph: *const Graph) void {
    var nodes = graph.nodeIterator();
    if (nodes.next()) |node| _ = node.edges(.{});
}
