const s = @import("string_processor");
const Bad = struct {
    pub const Settings = void;
    pub const defaults = {};
    pub const uses_comparison = false;
    pub fn State(comptime _: type) type {
        return struct {};
    }
    pub fn step(_: anytype, _: anytype, _: void, _: anytype) s.Step {
        return .pending;
    }
    pub fn batch(_: anytype, _: anytype, _: void, context: anytype, _: u32) u32 {
        if (comptime !@hasDecl(@TypeOf(context.*), "report")) @compileError("batch context excludes diagnostic reporting");
        _ = context.report(.{});
        return 0;
    }
};
export fn rejected() void {
    const P = s.Profile(.{ .custom = Bad, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    var session = P.Session.init(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{}) catch unreachable;
    _ = session.advance(64);
}
