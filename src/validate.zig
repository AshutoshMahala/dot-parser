//! Validation over syntax data (milestone 1, step 7).
//!
//! Validation is an analysis pass, not fail-fast control flow (R-FUNC-008):
//! it examines the whole tree, continues after every independent violation,
//! and reports each one through the caller's diagnostic sink in
//! deterministic source order (R-PORT-005). Completing the pass and the
//! document being valid are separate facts — `Result` reports both.
//!
//! The tree is never modified; consumers that want to tolerate or downgrade
//! specific rules filter at their sink (the uniform reporting surface) and
//! keep working with the same tree. Sink filtering is presentation policy —
//! it does not change `document_valid`; rule-level policy that decides
//! whether a rule contributes to validity belongs to future `Options`.
//!
//! ## Milestone rule
//!
//! An undigraph edge must be written `--`; a digraph edge must be written
//! `->`. The parser is kind-agnostic by design — this pass is exactly where
//! that legality policy lives. Each mismatch carries the operator's full
//! position and the document's kind declaration as a typed relation.
//!
//! Positions are derived, not stored: the tree keeps compact ranges, and a
//! `location.PositionCursor` rehydrates line/column with one shared O(source)
//! scan across all diagnostics (R-MEM-008).

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const syntax = @import("syntax.zig");

/// Policy knobs arrive with later slices; the struct exists so signatures
/// stay stable.
pub const Options = struct {};

pub const Result = struct {
    /// The pass examined every statement. Distinct from validity: a
    /// completed pass may have found any number of violations (R-FUNC-008).
    completed: bool,
    /// No rule violations were found. Meaningful only when `completed`.
    document_valid: bool,
    /// How many diagnostics the pass emitted. A fixed bag may retain fewer;
    /// its `omitted` counter accounts for the difference (bounded-bag
    /// policy: first diagnostics retained, the rest counted).
    diagnostics_emitted: usize,
    /// Whether every emitted diagnostic reached the sink. A failing sink
    /// does not stop the analysis; the loss is reported here.
    diagnostic_delivery: diagnostic.Delivery,
};

/// Validate `tree` against the milestone rules, emitting diagnostics into
/// `diagnostics`. Positions are derived from the source the tree itself
/// borrows — there is no separate source parameter to mismatch.
pub fn validate(
    tree: *const syntax.Tree,
    diagnostics: diagnostic.Sink,
    options: Options,
) Result {
    _ = options;
    const source = tree.source;

    const expected: syntax.EdgeOperator = switch (tree.kind) {
        .undigraph => .undirected,
        .digraph => .directed,
    };

    var cursor: location.PositionCursor = .{};
    var declaration: ?location.Span = null;
    var emitted: usize = 0;
    var delivery: diagnostic.Delivery = .complete;

    // The edge pool is in source order, so diagnostics come out in source
    // order and the position cursor advances monotonically (one shared scan).
    for (tree.edges) |edge| {
        if (edge.operator == expected) continue;

        if (declaration == null) {
            // The kind declaration precedes every edge; derive it on the
            // first violation, before the cursor moves past it.
            declaration = cursor.spanFor(source, tree.keyword);
        }
        const operator_span = cursor.spanFor(source, edge.operator_range);

        emitted += 1;
        diagnostics.emit(.{
            .code = .validation_operator_mismatch,
            .span = operator_span,
            .details = .{ .operator_mismatch = .{
                .expected = operatorDetail(expected),
                .found = operatorDetail(edge.operator),
                .declaration = declaration.?,
            } },
        }) catch {
            delivery = .failed;
        };
    }

    return .{
        .completed = true,
        .document_valid = emitted == 0,
        .diagnostics_emitted = emitted,
        .diagnostic_delivery = delivery,
    };
}

/// Map the syntax-layer operator into the diagnostic-layer vocabulary
/// (diagnostics never import syntax types; dependency direction).
fn operatorDetail(operator: syntax.EdgeOperator) diagnostic.OperatorMismatch.Operator {
    return switch (operator) {
        .undirected => .undirected,
        .directed => .directed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const parser = @import("parser.zig");
const syntax_event = @import("syntax_event.zig");

fn buildTree(source: []const u8) !syntax.Tree {
    var builder = syntax.Builder.init(std.testing.allocator, source);
    defer builder.deinit();
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});
    if (result.outcome != .success) return error.ParseFailed;
    return builder.toTree();
}

test "the milestone acceptance case: two mismatches, both reported" {
    const source = "graph {\n  a -> b;\n  c -> d;\n}";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    var bag: diagnostic.FixedBag(8) = .{};
    const result = validate(&tree, bag.sink(), .{});

    try expect(result.completed);
    try expect(!result.document_valid);
    try expectEqual(@as(usize, 2), result.diagnostics_emitted);
    try expectEqual(diagnostic.Delivery.complete, result.diagnostic_delivery);
    try expectEqual(@as(usize, 2), bag.items().len);

    // Deterministic source order with full derived positions.
    const first = bag.items()[0];
    try expectEqual(diagnostic.Code.validation_operator_mismatch, first.code);
    try expectEqualStrings("->", first.span.slice(source));
    try expectEqual(@as(usize, 2), first.span.start.line);
    try expectEqual(@as(usize, 5), first.span.start.byte_column);

    const second = bag.items()[1];
    try expectEqual(@as(usize, 3), second.span.start.line);
    try expectEqual(@as(usize, 5), second.span.start.byte_column);
    try expect(first.span.start.byte_offset < second.span.start.byte_offset);

    // Typed details point back at the kind declaration.
    const details = first.details.operator_mismatch;
    try expectEqual(diagnostic.OperatorMismatch.Operator.undirected, details.expected);
    try expectEqual(diagnostic.OperatorMismatch.Operator.directed, details.found);
    try expectEqualStrings("graph", details.declaration.slice(source));
    try expectEqual(@as(usize, 1), details.declaration.start.line);
}

test "a valid undigraph completes with an empty bag" {
    const source = "graph { a -- b; b -- c; }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    var bag: diagnostic.FixedBag(4) = .{};
    const result = validate(&tree, bag.sink(), .{});

    try expect(result.completed);
    try expect(result.document_valid);
    try expectEqual(@as(usize, 0), result.diagnostics_emitted);
    try expectEqual(@as(usize, 0), bag.items().len);
}

test "an empty document is valid" {
    const source = "graph { }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    var bag: diagnostic.FixedBag(4) = .{};
    const result = validate(&tree, bag.sink(), .{});
    try expect(result.completed);
    try expect(result.document_valid);
}

test "validation continues past valid edges between violations" {
    const source = "graph { a -> b; c -- d; e -> f; }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    var bag: diagnostic.FixedBag(8) = .{};
    const result = validate(&tree, bag.sink(), .{});

    try expectEqual(@as(usize, 2), result.diagnostics_emitted);
    try expectEqual(@as(usize, 2), bag.items().len);
    // The two violations are the first and third edges.
    try expect(bag.items()[0].span.start.byte_offset < bag.items()[1].span.start.byte_offset);
}

test "the rule is kind-agnostic: a digraph flags '--'" {
    // No digraph header parses yet, so drive the builder directly — the
    // validator only sees the tree, exactly as designed.
    const source = "digraph { a -- b; c -> d; }";
    var builder = syntax.Builder.init(std.testing.allocator, source);
    defer builder.deinit();

    const span = struct {
        fn at(offset: usize, len: usize) location.Span {
            return .{
                .start = .{ .byte_offset = offset, .line = 1, .byte_column = offset + 1 },
                .byte_len = len,
            };
        }
    }.at;

    try builder.beginDocument(.{ .kind = .digraph, .keyword_span = span(0, 7) });
    try builder.edgeStatement(.{
        .left = span(10, 1),
        .operator = .undirected,
        .operator_span = span(12, 2),
        .right = span(15, 1),
    });
    try builder.edgeStatement(.{
        .left = span(18, 1),
        .operator = .directed,
        .operator_span = span(20, 2),
        .right = span(23, 1),
    });
    try builder.endDocument();
    var tree = try builder.toTree();
    defer tree.deinit(std.testing.allocator);

    var bag: diagnostic.FixedBag(4) = .{};
    const result = validate(&tree, bag.sink(), .{});

    try expect(!result.document_valid);
    try expectEqual(@as(usize, 1), result.diagnostics_emitted);
    const failure = bag.items()[0];
    try expectEqualStrings("--", failure.span.slice(source));
    try expectEqual(
        diagnostic.OperatorMismatch.Operator.directed,
        failure.details.operator_mismatch.expected,
    );
    try expectEqualStrings("digraph", failure.details.operator_mismatch.declaration.slice(source));
}

test "a full bag bounds retention, not the analysis" {
    const source = "graph { a -> b; c -> d; e -> f; }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    var bag: diagnostic.FixedBag(1) = .{};
    const result = validate(&tree, bag.sink(), .{});

    // The pass still examined everything and counted every violation …
    try expect(result.completed);
    try expectEqual(@as(usize, 3), result.diagnostics_emitted);
    // … while the bag retained the first and counted the overflow.
    try expectEqual(@as(usize, 1), bag.items().len);
    try expectEqual(@as(usize, 2), bag.omitted);
}

test "a failing sink is reported without stopping the analysis" {
    const source = "graph { a -> b; c -> d; }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    const Rejecting = struct {
        fn emit(context: ?*anyopaque, d: diagnostic.Diagnostic) diagnostic.SinkError!void {
            _ = context;
            _ = d;
            return error.DiagnosticSinkFailure;
        }
    };
    const sink: diagnostic.Sink = .{ .context = null, .emit_fn = Rejecting.emit };
    const result = validate(&tree, sink, .{});

    try expect(result.completed);
    try expect(!result.document_valid);
    try expectEqual(@as(usize, 2), result.diagnostics_emitted);
    try expectEqual(diagnostic.Delivery.failed, result.diagnostic_delivery);
}

test "policy filtering happens at the sink without touching the tree" {
    const source = "graph { a -> b; }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    // A dialect-tolerant consumer: drops operator mismatches, keeps the rest.
    const Filtering = struct {
        kept: usize = 0,
        fn emit(context: ?*anyopaque, d: diagnostic.Diagnostic) diagnostic.SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (d.code != .validation_operator_mismatch) self.kept += 1;
        }
    };
    var filter: Filtering = .{};
    const sink: diagnostic.Sink = .{ .context = &filter, .emit_fn = Filtering.emit };
    const result = validate(&tree, sink, .{});

    // The pass still reports the document as invalid under default rules;
    // what the consumer surfaces is their policy. The tree is untouched.
    try expect(!result.document_valid);
    try expectEqual(@as(usize, 0), filter.kept);
    try expectEqual(@as(usize, 1), tree.edges.len);
}

test "repeated validation is deterministic" {
    const source = "graph { a -> b; c -- d; e -> f; }";
    var tree = try buildTree(source);
    defer tree.deinit(std.testing.allocator);

    var first_bag: diagnostic.FixedBag(8) = .{};
    var second_bag: diagnostic.FixedBag(8) = .{};
    const first = validate(&tree, first_bag.sink(), .{});
    const second = validate(&tree, second_bag.sink(), .{});

    try expectEqual(first, second);
    try expectEqual(first_bag.items().len, second_bag.items().len);
    for (first_bag.items(), second_bag.items()) |a, b| {
        try expectEqual(a.span.start, b.span.start);
        try expectEqual(a.code, b.code);
    }
}
