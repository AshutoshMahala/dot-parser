const std = @import("std");
test {
    _ = @import("composed_partial.zig");
    _ = @import("composed_delayed.zig");
}
test {
    _ = @import("during_dot.zig");
    _ = @import("markup_workspace.zig");
}
const dot = @import("dot_parser");
const markup = @import("markup_parser");
test {
    _ = @import("markup_integration.zig");
    _ = @import("error_policy.zig");
}

test "both parsers separate a later resource stop from established syntax rejection" {
    const D = dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 1 } } });
    const M = markup.Profile(.{ .policy = .{ .limits = .{ .max_nodes = 2 } } });
    const d = D.measureIn("graph { a -- ; b; c; d; }", .{}, dot.diagnostic.discard, .{});
    const m = M.measure(std.testing.allocator, "</x><a/><b/><c/>", markup.diagnostic.discard, .{});
    try std.testing.expect(d.outcome == .resource_exhausted and m.outcome == .resource_limit);
    try std.testing.expectEqual(@as(u32, 1), d.syntax_errors);
    try std.testing.expectEqual(d.syntax_errors, m.syntax_errors);
    try std.testing.expect(d.completion == .incomplete and m.completion == .incomplete);
}

test "independent parsers coexist and share primitives, not grammars or payloads" {
    try std.testing.expect(dot.location.Span == markup.location.Span);
    try std.testing.expect(dot.reporting.Severity == markup.reporting.Severity);
    try std.testing.expect(dot.reporting.Delivery == markup.reporting.Delivery);
    try std.testing.expect(dot.Cancellation == markup.Cancellation);
    try std.testing.expect(dot.Diagnostic != markup.Diagnostic);
    try std.testing.expect(dot.console.RenderOptions == markup.console.RenderOptions);
    try std.testing.expect(dot.presentation == markup.presentation);
    try std.testing.expect(dot.wdp == markup.wdp);
    try std.testing.expect(dot.diagnostic.SequenceDefinition == markup.diagnostic.SequenceDefinition);
    try std.testing.expect(dot.diagnostic.Applicability == markup.diagnostic.Applicability);
    try std.testing.expect(dot.diagnostic.Fix == dot.reporting.Fix(dot.diagnostic.Replacement));
    try std.testing.expect(markup.diagnostic.Fix == dot.reporting.Fix(markup.diagnostic.Replacement));
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
