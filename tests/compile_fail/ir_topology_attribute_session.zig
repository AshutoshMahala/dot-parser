const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    const node: IR.Graph.NodeView = undefined;
    _ = IR.attributeSession(node, "color", .{}) catch {};
}
