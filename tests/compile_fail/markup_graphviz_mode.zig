const markup = @import("markup_parser");
comptime {
    _ = markup.Profile(.{ .policy = .{ .mode = .graphviz } });
}
