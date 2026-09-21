const dot = @import("dot_parser");
export fn check() void {
    var storage: dot.FixedDocumentStorage(.{}) = .{};
    var session = dot.Profile(.{}).Session.init("graph {}", .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
    _ = session.advance(1);
}
