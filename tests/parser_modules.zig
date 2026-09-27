const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");

test "independent parsers coexist and share primitives, not grammars or payloads" {
    try std.testing.expect(dot.location.Span == markup.location.Span);
    try std.testing.expect(dot.reporting.Severity == markup.reporting.Severity);
    try std.testing.expect(dot.reporting.Delivery == markup.reporting.Delivery);
    try std.testing.expect(dot.Cancellation == markup.Cancellation);
    try std.testing.expect(dot.Diagnostic != markup.Diagnostic);
    var graph = dot.parseBorrowed(std.testing.allocator, "graph { a; }", dot.diagnostic.discard, .{});
    defer graph.deinit(std.testing.allocator);
    var fragment = markup.parseBorrowed(std.testing.allocator, "<a/>", markup.diagnostic.discard, .{});
    defer fragment.deinit();
    try std.testing.expect(graph.outcome == .success and fragment.outcome == .success);
}
