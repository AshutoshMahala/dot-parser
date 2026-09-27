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

test "DOT and infallible markup policies use one binding without composing execution" {
    const Fixed = markup.Profile(.{});
    const Runtime = markup.Profile(.{ .runtime_policy = true });
    try std.testing.expect(Fixed.Policies.State == void);
    try std.testing.expect(Runtime.Policies.Error == error{});
    try std.testing.expectEqual(markup.PolicyValidation.valid, Runtime.validatePolicy(.{ .limits = .{ .max_nodes = 0 } }));
    const AllFixed = dot.processor.PolicySet(.{ .outer = dot.Profile(.{}), .inner = Fixed });
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(AllFixed.State));
    _ = try AllFixed.prepare(.{});
    const Mixed = dot.processor.PolicySet(.{ .outer = dot.Profile(.{ .runtime_policy = true }), .inner = Runtime });
    const state = try Mixed.prepare(.{ .inner = .{ .policy = .{ .limits = .{ .max_nodes = 7 } } } });
    try std.testing.expectEqual(@as(u32, 7), state.inner.limits.max_nodes);
    try std.testing.expectError(error.GraphOperatorMismatchNotApplicable, Mixed.prepare(.{
        .outer = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic, .operator_mismatch = .err } } } },
    }));
}
