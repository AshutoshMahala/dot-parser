const s = @import("string_processor");
const P = s.Profile(.{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } });
export fn probe() void {
    _ = P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{});
}
