//! Validation over syntax data (milestone 1, step 7).
//!
//! Validation is an analysis pass, not fail-fast control flow (R-FUNC-008):
//! it examines the whole document, continues after every independent violation,
//! and reports each one through the caller's diagnostic sink in
//! deterministic source order (R-PORT-005). Completing the pass and the
//! document being valid are separate facts — `Result` reports both.
//!
//! The document is never modified. Profiles select rule severity and graph
//! interpretation. Sink filtering is presentation only and never changes validity.
//!
//! ## Milestone rule
//!
//! An undigraph edge must be written `--`; a digraph edge must be written
//! `->`. The parser is kind-agnostic by design — this pass is exactly where
//! that legality policy lives. Each mismatch carries the operator's full
//! position and the document's kind declaration as a typed relation.
//!
//! Positions are derived, not stored: the document keeps compact ranges and
//! the diagnostics carry those same ranges; whoever shows a position derives
//! its line and column (R-MEM-008).

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");

/// The default facade has fixed strict policy. Configurable validation is
/// available through Profile; it does not add overrides to the default facade.
pub const Options = struct {};

/// How the pass ended. Tagged, so meaningless combinations (such as an
/// incomplete-but-valid pass) are unrepresentable. Only implemented outcomes
/// are exposed; bounded and cancellable validation remain future work.
pub const Outcome = union(enum) {
    /// The pass examined every statement (R-FUNC-008). Any number of
    /// violations may have been found — completion is not validity.
    completed: Completed,

    pub const Completed = struct {
        /// No error-severity violations were found.
        document_valid: bool,
        /// Violations reported. A fixed bag may retain fewer; its `omitted`
        /// counter accounts for the difference (bounded-bag policy: first
        /// diagnostics retained, the rest counted).
        violations: usize,
        /// Warning-severity mismatches, independent of sink retention/delivery.
        /// `violations` counts errors; warnings do not invalidate a document.
        warnings: usize = 0,
    };
};

pub const Result = struct {
    outcome: Outcome,
    /// Whether every emitted diagnostic reached the sink. A failing sink
    /// does not stop the analysis; the loss is reported here, on its own
    /// axis.
    diagnostic_delivery: diagnostic.Delivery,

    /// True only for a completed pass that found no violations.
    pub fn documentValid(self: *const Result) bool {
        return switch (self.outcome) {
            .completed => |completed| completed.document_valid,
        };
    }
};

/// Validate `document` against the milestone rules, emitting diagnostics into
/// `diagnostics`. Positions are derived from the source the document itself
/// borrows — there is no separate source parameter to mismatch.
pub fn validate(
    document: *const syntax.Document,
    diagnostics: diagnostic.Sink,
    options: Options,
) Result {
    _ = options;
    return validateWith(policy.defaults, document, diagnostics, {});
}

/// One validator, specialized for a fixed policy or supplied one resolved
/// runtime policy. The fixed instantiation has no runtime settings parameter.
pub fn validateWith(
    comptime fixed: ?policy.Effective,
    document: *const syntax.Document,
    diagnostics: diagnostic.Sink,
    runtime: if (fixed == null) policy.Effective else void,
) Result {
    const settings = if (fixed) |value| value else runtime;
    const operators = if (document.kind == .digraph) settings.digraph else settings.graph.operators;
    if (operators.operator_mismatch == .off or
        (document.kind == .undigraph and
            (settings.graph.treated_as == .generic or settings.graph.treated_as == .auto)))
    {
        return .{
            .outcome = .{ .completed = .{ .document_valid = true, .violations = 0 } },
            .diagnostic_delivery = .complete,
        };
    }

    const code: diagnostic.Code = switch (operators.operator_mismatch) {
        .err => .validation_operator_mismatch,
        .warning => .validation_operator_tolerated,
        .off => unreachable,
    };
    const reading: diagnostic.OperatorMismatch.Reading = switch (operators.operator_reading) {
        .as_written => .as_written,
        .conform_to_kind => .conform_to_kind,
    };

    const expected: syntax.EdgeOperator = switch (document.kind) {
        .undigraph => if (settings.graph.treated_as == .digraph) .directed else .undirected,
        .digraph => .directed,
    };

    var declaration: ?location.Span = null;
    var emitted: usize = 0;
    var delivery: diagnostic.Delivery = .complete;

    // Ordinary edges and chain links merge in source order; the iterator
    // allocates nothing.
    var edges = document.edgeIterator();
    while (edges.next()) |edge| {
        if (edge.operator == expected) continue;

        if (declaration == null) declaration = document.keyword;
        const operator_span = edge.operator_range;

        emitted += 1;
        diagnostics.emit(.{
            .code = code,
            .span = operator_span,
            .details = .{ .operator_mismatch = .{
                .expected = operatorDetail(expected),
                .found = operatorDetail(edge.operator),
                .declaration = declaration.?,
                .reading = reading,
                .kind_overridden = document.kind == .undigraph and settings.graph.treated_as == .digraph,
                .suggest_header_change = settings.graph.treated_as != .digraph,
            } },
            // Conformance explicitly selects this operator reading. Otherwise
            // replacement is only one possible repair. Never apply it here.
            .fix = .{
                .span = operator_span,
                .edit = .{ .replace = switch (expected) {
                    .directed => .directed_operator,
                    .undirected => .undirected_operator,
                } },
                .applicability = if (operators.operator_reading == .conform_to_kind) .machine_applicable else .maybe,
            },
        }) catch {
            delivery = .failed;
        };
    }

    return .{
        .outcome = .{ .completed = .{
            .document_valid = operators.operator_mismatch != .err or emitted == 0,
            .violations = if (operators.operator_mismatch == .err) emitted else 0,
            .warnings = if (operators.operator_mismatch == .warning) emitted else 0,
        } },
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

fn buildDocument(source: []const u8) !syntax.Document {
    var builder = syntax.Builder.init(std.testing.allocator, source);
    defer builder.deinit();
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});
    if (result.outcome != .success) return error.ParseFailed;
    return builder.toDocument();
}

test "the milestone acceptance case: two mismatches, both reported" {
    const source = "graph {\n  a -> b;\n  c -> d;\n}";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(8) = .{};
    const result = validate(&document, bag.sink(), .{});

    try expect(result.outcome == .completed);
    try expect(!result.documentValid());
    try expectEqual(@as(usize, 2), result.outcome.completed.violations);
    try expectEqual(diagnostic.Delivery.complete, result.diagnostic_delivery);
    try expectEqual(@as(usize, 2), bag.items().len);

    // Deterministic source order with full derived positions.
    const first = bag.items()[0];
    try expectEqual(diagnostic.Code.validation_operator_mismatch, first.code);
    try expectEqualStrings("->", first.span.slice(source));
    try expectEqual(@as(usize, 2), first.span.locate(source).line);
    try expectEqual(@as(usize, 5), first.span.locate(source).byte_column);

    const second = bag.items()[1];
    try expectEqual(@as(usize, 3), second.span.locate(source).line);
    try expectEqual(@as(usize, 5), second.span.locate(source).byte_column);
    try expect(first.span.start < second.span.start);

    // Typed details point back at the kind declaration.
    const details = first.details.operator_mismatch;
    try expectEqual(diagnostic.OperatorMismatch.Operator.undirected, details.expected);
    try expectEqual(diagnostic.OperatorMismatch.Operator.directed, details.found);
    try expectEqualStrings("graph", details.declaration.slice(source));
    try expectEqual(@as(usize, 1), details.declaration.locate(source).line);
}

test "a valid undigraph completes with an empty bag" {
    const source = "graph { a -- b; b -- c; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(4) = .{};
    const result = validate(&document, bag.sink(), .{});

    try expect(result.outcome == .completed);
    try expect(result.documentValid());
    try expectEqual(@as(usize, 0), result.outcome.completed.violations);
    try expectEqual(@as(usize, 0), bag.items().len);
}

test "an empty document is valid" {
    const source = "graph { }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(4) = .{};
    const result = validate(&document, bag.sink(), .{});
    try expect(result.outcome == .completed);
    try expect(result.documentValid());
}

test "validation continues past valid edges between violations" {
    const source = "graph { a -> b; c -- d; e -> f; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(8) = .{};
    const result = validate(&document, bag.sink(), .{});

    try expectEqual(@as(usize, 2), result.outcome.completed.violations);
    try expectEqual(@as(usize, 2), bag.items().len);
    // The two violations are the first and third edges.
    try expect(bag.items()[0].span.start < bag.items()[1].span.start);
}

test "the rule is kind-agnostic: a digraph flags '--'" {
    // Since slice 2, this runs end-to-end from source text.
    const source = "digraph { a -- b; c -> d; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(4) = .{};
    const result = validate(&document, bag.sink(), .{});

    try expect(!result.documentValid());
    try expectEqual(@as(usize, 1), result.outcome.completed.violations);
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
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(1) = .{};
    const result = validate(&document, bag.sink(), .{});

    // The pass still examined everything and counted every violation …
    try expect(result.outcome == .completed);
    try expectEqual(@as(usize, 3), result.outcome.completed.violations);
    // … while the bag retained the first and counted the overflow.
    try expectEqual(@as(usize, 1), bag.items().len);
    try expectEqual(@as(usize, 2), bag.omitted);
}

test "a failing sink is reported without stopping the analysis" {
    const source = "graph { a -> b; c -> d; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    const Rejecting = struct {
        fn emit(context: ?*anyopaque, d: diagnostic.Diagnostic) diagnostic.SinkError!void {
            _ = context;
            _ = d;
            return error.DiagnosticSinkFailure;
        }
    };
    const sink: diagnostic.Sink = .{ .context = null, .emit_fn = Rejecting.emit };
    const result = validate(&document, sink, .{});

    try expect(result.outcome == .completed);
    try expect(!result.documentValid());
    try expectEqual(@as(usize, 2), result.outcome.completed.violations);
    try expectEqual(diagnostic.Delivery.failed, result.diagnostic_delivery);
}

test "policy filtering happens at the sink without touching the document" {
    const source = "graph { a -> b; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

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
    const result = validate(&document, sink, .{});

    // The pass still reports the document as invalid under default rules;
    // what the consumer surfaces is their policy. The document is untouched.
    try expect(!result.documentValid());
    try expectEqual(@as(usize, 0), filter.kept);
    try expectEqual(@as(usize, 1), document.edges.len);
}

test "repeated validation is deterministic" {
    const source = "graph { a -> b; c -- d; e -> f; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var first_bag: diagnostic.FixedBag(8) = .{};
    var second_bag: diagnostic.FixedBag(8) = .{};
    const first = validate(&document, first_bag.sink(), .{});
    const second = validate(&document, second_bag.sink(), .{});

    try expectEqual(first, second);
    try expectEqual(first_bag.items().len, second_bag.items().len);
    for (first_bag.items(), second_bag.items()) |a, b| {
        try expectEqual(a.span.start, b.span.start);
        try expectEqual(a.code, b.code);
    }
}
