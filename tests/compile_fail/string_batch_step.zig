const s = @import("string_processor");
const Bad = struct {
    pub const Settings = void;
    pub const defaults = {};
    pub const uses_comparison = true;
    pub fn State(comptime C: type) type {
        return struct { comparison: C.ComparisonState = .{} };
    }
    pub fn step(state: anytype, value: anytype, _: void, context: anytype) s.Step {
        if (comptime !@hasDecl(@TypeOf(context.*), "equalsBatch")) @compileError("single-step context excludes batch operations");
        _ = context.equalsBatch(&state.comparison, value, "x", 16);
        return .pending;
    }
};
export fn rejected() void {
    const P = s.Profile(.{ .custom = Bad, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    var session = P.Session.init(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{}) catch unreachable;
    _ = session.advance(1);
}
