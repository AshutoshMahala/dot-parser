const s = @import("string_processor");
const Custom = struct {
    pub const Settings = void;
    pub const defaults = {};
    pub const uses_comparison = false;
    pub fn check(value: anytype, _: void, ctx: anytype) s.Outcome {
        return if (ctx.equals(value, "x") orelse return .stopped) .passed else .failed;
    }
};
const P = s.Profile(.{ .custom = Custom, .policy = .{ .validation = .{ .custom = .err } } });
export fn entry() void {
    _ = P.parseAndValidate(.{ .bytes = "", .origin = 0 }, P.Sink.discard, .{}) catch {};
}
