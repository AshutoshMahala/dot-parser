const s = @import("string_processor");
const Check = s.validators.Predicate(void, {}, struct {
    fn check(_: anytype, _: void) bool {
        return true;
    }
}.check);
const P = s.Profile(.{ .custom = Check, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
export fn probe() void {
    _ = P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{});
}
