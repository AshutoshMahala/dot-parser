const dot = @import("dot_parser");
export fn rejected(session: *dot.ir.Lowering(.{}).FixedAttributesSession) void {
    _ = session.advance(1);
}
