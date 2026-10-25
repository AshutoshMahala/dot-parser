const dot = @import("dot_parser");
export fn rejected() void {
    dot.ir.Lowering(.{}).validatePolicy(.{}) catch {};
}
