const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    var graph: IR.Graph = undefined;
    _ = graph.materialize(.{ .attributes = true }) catch {};
}
