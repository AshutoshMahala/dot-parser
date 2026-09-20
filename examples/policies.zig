//! Fixed baseline, per-operation overrides and a source-preserving view.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main() !void {
    const Fixed = dot.Profile(.{ .policy = .{ .validation = .{
        .graph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind },
        .digraph = .{ .operator_mismatch = .err },
    } } });
    const source = "graph { a -- b -> c }";
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var result = Fixed.parseAndValidate(std.heap.page_allocator, source, bag.sink(), .{});
    defer result.deinit(std.heap.page_allocator);
    if (!result.documentValid()) return error.InvalidDocument;
    const doc = &result.document.?;
    const fixed_view = Fixed.interpretation(doc, .{});
    std.debug.print("fixed kind: {s}, warnings: {d}\n", .{
        @tagName(doc.effectiveKind(fixed_view)), result.validation.?.outcome.completed.warnings,
    });

    const Runtime = dot.Profile(.{ .runtime_policy = true });
    const patch: dot.Policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } };
    // Optional preflight; every policy-aware operation also checks automatically.
    switch (Runtime.validatePolicy(patch)) {
        .valid => {},
        .invalid => |issue| return issue.asError(),
    }
    const options: Runtime.Options = .{ .policy = patch };
    const checked = try Runtime.validate(doc, dot.diagnostic.discard, options);
    if (!checked.documentValid()) return error.InvalidDocument;
    const view = try Runtime.interpretation(doc, options);
    std.debug.print("auto kind: {s}, written header kind: {s}\n", .{
        @tagName(doc.effectiveKind(view)), @tagName(doc.kind),
    });
    var edges = doc.edgeIterator();
    while (edges.next()) |edge| {
        std.debug.print("written {s}, effective {s}\n", .{
            @tagName(edge.operator), @tagName(edge.effectiveOperator(doc, view)),
        });
    }
}
