const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    var edge: IR.Graph.EdgeView = undefined;
    _ = edge.tailPort() catch {};
}
