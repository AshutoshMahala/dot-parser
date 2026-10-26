const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(view: *const IR.Graph.NodeView, memory: *const IR.AttributeScratch) void {
    _ = IR.attributesSessionIn(view.*, memory.*, .{ .attributes = false }) catch {};
}
