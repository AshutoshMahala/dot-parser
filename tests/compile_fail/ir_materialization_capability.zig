const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn invalid() usize {
    return @sizeOf(IR.FixedMaterializedStorage(.{}, .{ .attributes = true }));
}
