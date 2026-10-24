const dot = @import("dot_parser");
export fn rejected(graph: *const dot.ir.Lowering(.{}).Graph) void {
    var result = graph.materialize(.{ .limits = .{ .max_pair = 1 } }) catch return;
    result.deinit();
}
