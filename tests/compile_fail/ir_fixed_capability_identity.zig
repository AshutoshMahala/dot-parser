const dot = @import("dot_parser");
const Full = dot.ir.Lowering(.{});
const Topology = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
export fn rejected() void {
    _ = Topology.FixedLoweringScratch(Full.FixedGraphStorage(.{}), .{});
}
