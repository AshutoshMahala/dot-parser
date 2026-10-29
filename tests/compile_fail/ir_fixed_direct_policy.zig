const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(doc: *const dot.Document, memory: *const IR.LoweringMemory) void {
    _ = IR.lowerCompleteIn(doc, memory.*, .{
        .interpretation = dot.Profile(.{}).interpretation(doc, .{}),
        .policy = .{},
    });
}
