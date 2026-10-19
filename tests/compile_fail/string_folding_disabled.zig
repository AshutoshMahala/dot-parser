const s = @import("string_processor");
const P = s.Profile(.{ .policy = .{ .comparison = .case_insensitive } });
export fn entry() void {
    _ = P.parseAndValidate(.{ .bytes = "", .origin = 0 }, P.Sink.discard, .{}) catch {};
}
