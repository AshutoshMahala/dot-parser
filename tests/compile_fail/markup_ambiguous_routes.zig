const markup = @import("markup_parser");
comptime {
    _ = markup.Profile(.{ .policy = .{ .attributes = .{
        .title = .{ .string = .none },
        .TITLE = .{ .string = .none },
    } } });
}
