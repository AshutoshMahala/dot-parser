const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(graph: *const IR.Graph) void {
    const node = graph.nodeView(@fromBackingInt(0)) catch return;
    _ = IR.attributesSession(node, .{ .attributes = false }) catch {};
}
