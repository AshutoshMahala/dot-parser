const dot = @import("dot_parser");
export fn rejected(session: *dot.ir.Lowering(.{}).FixedLoweringSession) void {
    _ = session.advance(1);
}
