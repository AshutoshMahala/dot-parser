const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() usize {
    return @sizeOf(IR.Graph.Materialized);
}
