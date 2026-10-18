const markup = @import("markup_parser");
comptime {
    _ = markup.Profile(.{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } });
}
