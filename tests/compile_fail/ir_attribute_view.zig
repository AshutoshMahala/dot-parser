const dot = @import("dot_parser");
export fn rejected() void {
    _ = dot.ir.Lowering(.{}).attributeSession(@as(u32, 0), "color", .{}) catch {};
}
