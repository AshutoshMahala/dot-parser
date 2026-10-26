const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(graph: *const IR.Graph, memory: *const IR.EdgeScratch) void {
    _ = IR.edgeSessionIn(graph, memory.*, .{ .policy = .{} }) catch {};
}
