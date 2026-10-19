const s = @import("string_processor");
const P = s.Profile(.{
    .runtime_policy = true,
    .source_encodings = &.{ .utf8, .utf16, .utf32 },
    .unicode_case_folding = true,
    .custom = s.validators.Equals,
    .policy = .{
        .execution = .{ .metering = true, .cancellation = true },
        .comparison = .case_insensitive,
        .custom = "Seattle",
        .validation = .{ .custom = .err },
    },
});

export fn check_in_steps(source: [*]const u8, length: u32, encoding: u8, budget: u32, cancel: bool) u32 {
    const actual: s.ActualEncoding = switch (encoding) {
        0 => .utf8,
        1 => .utf16le,
        2 => .utf16be,
        3 => .utf32le,
        4 => .utf32be,
        else => return 3,
    };
    var session = P.Session.init(.{ .bytes = source[0..length], .origin = 0 }, P.Sink.discard, .{ .encoding = actual }) catch return 3;
    defer session.deinit();
    if (cancel) return if (session.cancel().completion == .cancelled) 2 else 3;
    while (true) {
        const progress = session.advance(if (budget == 0) 1 else budget) catch return 3;
        if (progress.outcome != null) break;
    }
    return if (session.result().?.valid()) 0 else 1;
}
