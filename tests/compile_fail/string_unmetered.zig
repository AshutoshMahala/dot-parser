const s = @import("string_processor");
export fn probe() void {
    var session = s.Session.init(.{ .bytes = "x", .origin = 0 }, s.Sink.discard, .{}) catch unreachable;
    _ = session.advance(1);
}
