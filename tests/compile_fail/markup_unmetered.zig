const markup = @import("markup_parser");
export fn rejected() void {
    var session = markup.Profile(.{}).Session.init("", .{}, markup.diagnostic.discard, .{});
    _ = session.advance(1);
}
