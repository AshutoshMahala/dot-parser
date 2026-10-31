const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    var graph: IR.Graph = undefined;
    _ = (graph.nodeView(@fromBackingInt(0)) catch unreachable).attribute("color");
}
