const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(graph: *const IR.Graph) void {
    _ = IR.containsSession(graph, @fromBackingInt(0), @fromBackingInt(0), .{ .policy = .{} }) catch {};
}
