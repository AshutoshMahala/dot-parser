const dot = @import("dot_parser");
export fn rejected(session: *dot.ir.Lowering(.{}).HasEdgeSession) void {
    _ = session.advance(1);
}
