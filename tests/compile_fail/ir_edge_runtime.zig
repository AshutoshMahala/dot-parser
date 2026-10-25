const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(graph: *const IR.Graph) void {
    _ = IR.edgeSession(graph, .{ .policy = .{} }) catch {};
}
