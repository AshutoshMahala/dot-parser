const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(doc: *const dot.Document, bytes: [*]u8, len: usize) void {
    const memory: IR.LoweringMemory = .{
        .graph = .{ .bytes = bytes[0..len], .capacities = .{} },
        .scratch = .{ .bytes = &.{}, .graph_capacities = .{}, .capacities = .{} },
    };
    _ = IR.loweringSessionIn(doc, memory, .{
        .interpretation = dot.Profile(.{}).interpretation(doc, .{}),
        .cancellation = @as(?dot.ir.Cancellation, null),
    });
}
