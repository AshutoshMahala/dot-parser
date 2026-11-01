const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn invalid(graph: *const IR.Graph, memory: *IR.MaterializationMemory(.{ .adjacency = .all })) void {
    _ = graph.materializeIn(memory.*, .{ .adjacency = .forward });
}
