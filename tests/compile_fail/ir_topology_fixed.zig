const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    _ = IR.FixedGraphStorage(.{ .attributes = 1 });
}
