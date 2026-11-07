const dot = @import("dot_parser");
const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }));
export fn rejected(session: *E.Session) void {
    _ = session.advance(1);
}
