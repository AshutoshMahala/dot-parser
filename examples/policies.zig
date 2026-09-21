//! Fixed baselines, overrides, source-preserving views and policy-bound sessions.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main() !void {
    // Named presets are ordinary Policy values. Select the whole baseline, or
    // copy just .syntax to preserve unrelated custom settings.
    const Lenient = dot.Profile(.{ .policy = dot.presets.lenient });
    var accepted = Lenient.parseAndValidate(std.heap.page_allocator, "digraph { ; a --> b - c; ; }", dot.diagnostic.discard, .{});
    defer accepted.deinit(std.heap.page_allocator);
    if (!accepted.documentValid() or accepted.accepted_deviations != 4 or accepted.warnings != 4)
        return error.LenientParseFailed;
    std.debug.print("lenient preset: {d} deviations, {d} warnings (discarded, still counted)\n", .{ accepted.accepted_deviations, accepted.warnings });

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
    var dynamic_syntax = try Runtime.parseBorrowed(std.heap.page_allocator, "graph { a --- b }", dot.diagnostic.discard, .{
        .policy = .{ .syntax = dot.presets.lenient.syntax },
    });
    defer dynamic_syntax.deinit(std.heap.page_allocator);
    if (dynamic_syntax.outcome != .success or dynamic_syntax.accepted_deviations != 1)
        return error.LenientParseFailed;
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

    // Limits/scanner/execution share the same policy as validation. Storage and
    // work credits remain explicit resources, not hidden policy allocations.
    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 2 }) = .{};
    const Bounded = dot.Profile(.{
        .runtime_policy = true,
        .policy = .{ .execution = .{ .metering = true }, .limits = .{ .max_statements = 1 } },
    });
    var session = try Bounded.Session.init(source, .{ .document = storage.storage() }, dot.diagnostic.discard, .{
        .policy = .{ .scanner = .block, .validation = patch.validation },
    });
    defer session.deinit();
    while ((try session.advance(16)).outcome == null) {}
    const parsed = session.result().?;
    if (parsed.outcome != .success) return error.ParseFailed;
    if (!session.validate(dot.diagnostic.discard).?.documentValid()) return error.InvalidDocument;
    std.debug.print("policy session: {s}, {d} statement\n", .{
        @tagName(parsed.document.?.effectiveKind(session.interpretation().?)),
        parsed.document.?.statementCount(),
    });
}
