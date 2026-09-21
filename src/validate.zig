//! Policy-selected validation over committed syntax data.
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
//! ## Default rule
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
const diagnostic = @import("diagnostic.zig");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const checks = @import("validation_checks.zig");
pub const Scratch = checks.Scratch;
pub const AttributeKeyScratch = checks.AttributeKeyScratch;

/// How the pass ended. An incomplete-but-valid pass is unrepresentable.
/// Scratch preflight is implemented; bounded/cancellable validation is not.
pub const Outcome = union(enum) {
    /// The pass examined every statement (R-FUNC-008). Any number of
    /// violations may have been found — completion is not validity.
    completed: Completed,
    /// No checks ran and scratch is unchanged. Supply at least the required
    /// number of entries and rerun; the parsed document remains available.
    insufficient_scratch: struct {
        required_attribute_keys: u32,
        provided_attribute_keys: usize,
    },

    pub const Completed = struct {
        /// No error-severity violations were found.
        document_valid: bool,
        /// Error findings. Independent rules can overlap on the same source byte,
        /// so totals need u64 rather than source-width u32, including on 32-bit
        /// targets. A fixed bag may retain fewer; its `omitted`
        /// counter accounts for the difference (bounded-bag policy: first
        /// diagnostics retained, the rest counted).
        violations: u64,
        /// Warning findings, independent of sink retention/delivery.
        /// `violations` counts errors; warnings do not invalidate a document.
        warnings: u64 = 0,
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
            .insufficient_scratch => false,
        };
    }

    pub fn warningCount(self: Result) u64 {
        return switch (self.outcome) {
            .completed => |completed| completed.warnings,
            .insufficient_scratch => 0,
        };
    }
};

/// One validator, specialized for a fixed policy or supplied one resolved
/// runtime policy. Disabled fixed checks have neither stream state nor code.
pub fn validate(
    comptime fixed: ?policy.ValidationSettings,
    document: *const syntax.Document,
    diagnostics: diagnostic.Sink,
    runtime: if (fixed == null) policy.ValidationSettings else void,
    scratch: Scratch,
) Result {
    const settings = if (fixed) |value| value else runtime;
    // Preflight before running any check or touching scratch. Exhaustion must
    // never masquerade as a completed, valid pass, even with a discard sink.
    if (settings.repeated_attribute != .off and scratch.attribute_keys.len < document.attributes.len) {
        var delivery: diagnostic.Delivery = .complete;
        diagnostics.emit(.{
            .code = .resource_capacity_exhausted,
            .span = document.keyword,
            .details = .{ .capacity = .{ .resource = .validation_attribute_keys, .limit = scratch.attribute_keys.len } },
        }) catch {
            delivery = .failed;
        };
        return .{
            .outcome = .{ .insufficient_scratch = .{
                .required_attribute_keys = @intCast(document.attributes.len),
                .provided_attribute_keys = scratch.attribute_keys.len,
            } },
            .diagnostic_delivery = delivery,
        };
    }

    const Cursors = cursorTypes(fixed);
    const fields = @typeInfo(Cursors).@"struct".fields;
    var cursors: Cursors = undefined;
    var pending: [fields.len]?diagnostic.Diagnostic = undefined;
    inline for (fields, 0..) |field, index| {
        @field(cursors, field.name) = field.type.init(document, settings, scratch);
        pending[index] = @field(cursors, field.name).next();
    }
    var errors: u64 = 0;
    var warnings: u64 = 0;
    var delivery: diagnostic.Delivery = .complete;
    while (fields.len != 0) {
        var selected: ?usize = null;
        for (pending, 0..) |finding, index| {
            if (finding) |d| {
                if (selected == null or d.span.start < pending[selected.?].?.span.start) selected = index;
            }
        }
        const index = selected orelse break;
        const d = pending[index].?;
        if (d.code.severity() == .err) errors += 1 else warnings += 1;
        diagnostics.emit(d) catch {
            delivery = .failed;
        };
        inline for (fields, 0..) |field, at| {
            if (index == at) pending[at] = @field(cursors, field.name).next();
        }
    }
    return .{
        .outcome = .{ .completed = .{ .document_valid = errors == 0, .violations = errors, .warnings = warnings } },
        .diagnostic_delivery = delivery,
    };
}

/// Ties use this fixed rule order: kind, operator, encoding, repeated key,
/// port, subgraph. Filtering a stream never changes the remaining order.
fn cursorTypes(comptime fixed: ?policy.ValidationSettings) type {
    const enabled: [6]bool = if (fixed) |s| .{
        s.restrictions.graph_kinds.undigraph != .off or s.restrictions.graph_kinds.digraph != .off or s.restrictions.graph_kinds.generic != .off,
        s.digraph.operator_mismatch != .off or
            ((s.graph.treated_as != .auto and s.graph.treated_as != .generic) and s.graph.operators.operator_mismatch != .off),
        s.invalid_utf8 != .off,
        s.repeated_attribute != .off,
        s.restrictions.ports != .off,
        s.restrictions.subgraphs != .off,
    } else .{true} ** 6;
    const all = .{ checks.GraphKinds, checks.Operators, checks.Encoding, checks.RepeatedAttributes, checks.Ports, checks.Subgraphs };
    comptime var types: [all.len]type = undefined;
    comptime var count: usize = 0;
    inline for (all, enabled) |T, include| {
        if (include) {
            types[count] = T;
            count += 1;
        }
    }
    return std.meta.Tuple(types[0..count]);
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
    const result = parser.testing.run(source, &builder, bag.sink(), .{}, null);
    if (result.outcome != .success) return error.ParseFailed;
    return builder.toDocument();
}

test "the milestone acceptance case: two mismatches, both reported" {
    const source = "graph {\n  a -> b;\n  c -> d;\n}";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(8) = .{};
    const result = validate(policy.defaults.validation, &document, bag.sink(), {}, .{});

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
    const result = validate(policy.defaults.validation, &document, bag.sink(), {}, .{});

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
    const result = validate(policy.defaults.validation, &document, bag.sink(), {}, .{});
    try expect(result.outcome == .completed);
    try expect(result.documentValid());
}

test "validation continues past valid edges between violations" {
    const source = "graph { a -> b; c -- d; e -> f; }";
    var document = try buildDocument(source);
    defer syntax.deinitOwnedDocument(&document, std.testing.allocator);

    var bag: diagnostic.FixedBag(8) = .{};
    const result = validate(policy.defaults.validation, &document, bag.sink(), {}, .{});

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
    const result = validate(policy.defaults.validation, &document, bag.sink(), {}, .{});

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
    const result = validate(policy.defaults.validation, &document, bag.sink(), {}, .{});

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
    const result = validate(policy.defaults.validation, &document, sink, {}, .{});

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
    const result = validate(policy.defaults.validation, &document, sink, {}, .{});

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
    const first = validate(policy.defaults.validation, &document, first_bag.sink(), {}, .{});
    const second = validate(policy.defaults.validation, &document, second_bag.sink(), {}, .{});

    try expectEqual(first, second);
    try expectEqual(first_bag.items().len, second_bag.items().len);
    for (first_bag.items(), second_bag.items()) |a, b| {
        try expectEqual(a.span.start, b.span.start);
        try expectEqual(a.code, b.code);
    }
}
