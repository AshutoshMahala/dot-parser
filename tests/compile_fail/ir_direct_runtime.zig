const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
export fn rejected(doc: *const dot.Document) void {
    _ = IR.lowerComplete(@import("std").heap.page_allocator, doc, .{
        .interpretation = dot.Profile(.{}).interpretation(doc, .{}),
        .policy = .{},
    }) catch {};
}
