const dot = @import("dot_parser");
const Full = dot.ir.Lowering(.{});
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() u32 {
    var graph: IR.Graph = undefined;
    // A helper from another profile must check the input graph's capability.
    return Full.attributeScratchBounds(&graph).winners;
}
