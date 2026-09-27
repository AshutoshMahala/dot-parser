const markup = @import("markup_parser");
export fn rejected() void {
    _ = markup.parseBorrowedIn("", .{}, markup.diagnostic.discard, .{ .policy = .{} });
}
