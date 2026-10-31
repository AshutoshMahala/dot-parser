const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    const edge: IR.PartialGraph.EdgeView = undefined;
    _ = edge.attributes(.{}) catch {};
}
