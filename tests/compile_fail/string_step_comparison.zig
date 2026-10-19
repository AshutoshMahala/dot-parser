const s = @import("string_processor");
const Custom = struct {
    pub const Settings = void;
    pub const defaults = {};
    pub const uses_comparison = true;
    pub fn State(comptime _: type) type {
        return struct {};
    }
    pub fn step(_: anytype, value: anytype, _: void, ctx: anytype) s.Step {
        _ = ctx.equals(value, "x");
        return .passed;
    }
};
const P = s.Profile(.{ .custom = Custom, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
export fn probe() void {
    _ = P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{});
}
