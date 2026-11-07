const dot = @import("dot_parser");
const E = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } }).FromEvents(dot.Profile(.{}));
export fn rejected(session: *E.Session) void {
    _ = session.advance(1);
}
