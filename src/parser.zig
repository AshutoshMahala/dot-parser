//! Parser state machine (milestone 1, step 5).
//!
//! Milestone grammar:
//!
//! ```text
//! document  := "graph" "{" statement* "}" EOF
//! statement := identifier ";"
//!            | identifier edgeop identifier ";"
//! edgeop    := "--" | "->"
//! ```
//!
//! The parser is kind-agnostic: both edge operators parse structurally and
//! the written operator is preserved in the emitted event. Whether an
//! operator is legal for the document's kind is validation policy (step 7),
//! never a parse error.
//!
//! ## Reporting surface
//!
//! Every phase of this library reports problems the same way: diagnostics
//! are emitted into a caller-owned `diagnostic.Sink` (usually backed by a
//! `FixedBag`), and the function returns only a small control-flow result
//! (R-DIAG-003). The parser's default policy is fail-fast (R-FUNC-007), so
//! its bag contains at most one diagnostic today; when the optional recovery
//! policy lands, the surface stays identical and the bag simply gains
//! entries. Validation (step 7) already reports many.
//!
//! Guarantees:
//! - Instance-owned state, no mutable globals (R-ROB-003).
//! - Fail fast on the first structural failure; the sink lifecycle from
//!   `syntax_event.zig` is honored: no events before a supported header,
//!   abort after begin when the document cannot commit — including the
//!   documented cleanup abort after an attempted `beginDocument` that
//!   itself failed.
//! - Iterative state machine — no recursion at all, so input size and shape
//!   cannot exhaust the call stack (R-PERF-002).
//! - Work is a single linear scan of the input (R-PERF-001, R-SEC-003);
//!   `Options.max_statements` additionally bounds the statements processed.
//! - Recognized-but-deferred constructs (graph names, edge chains, optional
//!   semicolons, anonymous subgraphs, …) stop the parse as unsupported
//!   features, not as malformed input (R-MOD-006). The parse makes no
//!   validity claim beyond that boundary.
//!
//! Only a run-to-completion `parse` is exposed for now, but the machine is
//! genuinely resumable: all continuation state (grammar state and the spans
//! of the statement in flight) lives in the machine struct, and progress is
//! made one `step` (one token) at a time — `next`/`pump`/cancellation
//! drivers are wrappers over `step`, not a parser rewrite (R-MOD-010).

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const lex = @import("lexer.zig");
const syntax_event = @import("syntax_event.zig");

pub const Options = struct {
    /// Maximum number of statements the parser will process before stopping
    /// with a `resource_exhausted` outcome. This is a statement/output
    /// capacity bound (R-ROB-002), **not** a total-work budget: the parser
    /// always performs one linear scan, so total work is bounded by input
    /// length — a whitespace-heavy body or a long identifier is still
    /// scanned once in full. Byte/token budgets and cooperative
    /// cancellation arrive with the bounded drivers (R-MOD-010).
    max_statements: usize = std.math.maxInt(usize),
};

/// The parse outcome category. The diagnostics explaining a failure travel
/// through the caller's diagnostic sink, never through this value.
pub const Outcome = union(enum) {
    /// The document parsed completely and the event sink committed.
    success,
    /// The input is malformed in any DOT dialect.
    invalid_syntax,
    /// Parsing reached a recognized DOT construct that this profile cannot
    /// process (a deferred feature) and stopped at that boundary. Neither
    /// the construct itself nor anything beyond it has been checked, so
    /// this outcome makes no claim that the whole input is valid DOT.
    unsupported_feature,
    /// A caller-configured limit was reached; the input may still be valid.
    resource_exhausted,
    /// The event sink refused an event. The sink owns the underlying cause,
    /// so no diagnostic is emitted for it.
    sink_failure: anyerror,
};

/// Whether every diagnostic emitted during a parse actually reached the
/// caller's diagnostic sink.
pub const DiagnosticDelivery = diagnostic.Delivery;

pub const Result = struct {
    outcome: Outcome,
    diagnostic_delivery: DiagnosticDelivery = .complete,
};

/// Parse `source` to completion, emitting syntax events into `events` and
/// failure diagnostics into `diagnostics`.
///
/// `events` must be a single-item pointer to a type satisfying the private
/// syntax-sink contract (`syntax_event.assertSyntaxSink`). The source bytes
/// are borrowed: every span in every event and diagnostic indexes `source`.
pub fn parse(
    source: []const u8,
    events: anytype,
    diagnostics: diagnostic.Sink,
    options: Options,
) Result {
    const EventsPtr = @TypeOf(events);
    comptime {
        const info = @typeInfo(EventsPtr);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("events must be a single-item pointer to a syntax sink, e.g. `&my_sink`");
        }
        syntax_event.assertSyntaxSink(info.pointer.child);
    }
    var machine: Machine(EventsPtr) = .{
        .tokens = lex.Lexer.init(source),
        .events = events,
        .diagnostics = diagnostics,
        .options = options,
    };
    return machine.runToCompletion();
}

fn Machine(comptime EventsPtr: type) type {
    return struct {
        const Self = @This();

        tokens: lex.Lexer,
        events: EventsPtr,
        diagnostics: diagnostic.Sink,
        options: Options,
        statements: usize = 0,
        delivery: DiagnosticDelivery = .complete,
        /// Span of the document's `{`, once consumed — the related location
        /// reported when the input ends inside the body.
        open_brace_span: ?location.Span = null,
        /// True once `beginDocument` has been issued; from then on every
        /// exit path must emit a terminal event.
        begun: bool = false,
        /// Latched once a terminal result is produced. Further `step` calls
        /// return it unchanged — no re-emitted events or diagnostics — so
        /// bounded drivers can safely over-call `step`.
        terminal: ?Result = null,

        // Continuation state. Everything a suspended parse needs lives in
        // the machine itself — never in `runToCompletion` locals — so
        // `next`/`pump` drivers can be layered on `step` without touching
        // the grammar (R-MOD-010 groundwork).
        state: State = .keyword,
        /// First identifier of the statement being parsed.
        left: location.Span = undefined,
        /// Operator of the edge statement being parsed.
        operator: syntax_event.EdgeOperator = undefined,
        operator_span: location.Span = undefined,
        /// Right endpoint of the edge statement being parsed.
        right: location.Span = undefined,

        const State = enum {
            /// Expect the document keyword.
            keyword,
            /// Expect `{`.
            open,
            /// Expect a statement's first identifier or the closing `}`.
            statement,
            /// After a statement's first identifier: `;`, `--`, or `->`.
            after_identifier,
            /// After an edge operator: the right endpoint identifier.
            edge_right,
            /// After a complete edge: the terminating `;`.
            edge_terminate,
            /// After the closing `}`: end of input.
            epilogue,
        };

        fn runToCompletion(self: *Self) Result {
            while (true) {
                if (self.step()) |result| return result;
            }
        }

        /// Consume one token and advance the grammar by one transition.
        /// Returns null while the parse can continue, or the terminal
        /// result. This is the unit a bounded `pump` driver will meter.
        /// Terminal-idempotent: once a terminal result exists, it is
        /// returned unchanged without consuming input or emitting anything.
        fn step(self: *Self) ?Result {
            if (self.terminal) |result| return result;
            const token = switch (self.tokens.next()) {
                .token => |token| token,
                .failure => |failure| return self.fail(failure),
            };

            switch (self.state) {
                .keyword => switch (token.tag) {
                    .keyword_graph => {
                        // The source keyword `graph` maps to the
                        // `undigraph` kind at reading time.
                        self.begun = true;
                        self.events.beginDocument(.{
                            .kind = .undigraph,
                            .keyword_span = token.span,
                        }) catch |err| return self.sinkFailure(err);
                        self.state = .open;
                    },
                    else => return self.unexpected(.{ .graph_keyword = true }, .document_header, token),
                },
                .open => switch (token.tag) {
                    .left_brace => {
                        self.open_brace_span = token.span;
                        self.state = .statement;
                    },
                    // `graph G {` is valid DOT with a graph name;
                    // deferred to slice 2.
                    .identifier => return self.unsupportedAt(token.span, .graph_name),
                    else => return self.unexpected(.{ .left_brace = true }, .document_header, token),
                },
                .statement => switch (token.tag) {
                    .identifier => {
                        if (self.statements == self.options.max_statements) {
                            return self.fail(.{
                                .code = .resource_capacity_exhausted,
                                .span = token.span,
                                .details = .{ .capacity = .{
                                    .resource = .statements,
                                    .limit = self.options.max_statements,
                                } },
                            });
                        }
                        self.statements += 1;
                        self.left = token.span;
                        self.state = .after_identifier;
                    },
                    .right_brace => self.state = .epilogue,
                    // `{ … }` here is a valid-DOT anonymous subgraph.
                    .left_brace => return self.unsupportedAt(token.span, .subgraph),
                    else => return self.unexpected(.{ .identifier = true, .right_brace = true }, .document_body, token),
                },
                .after_identifier => switch (token.tag) {
                    .semicolon => {
                        self.events.nodeStatement(.{
                            .identifier = self.left,
                        }) catch |err| return self.sinkFailure(err);
                        self.state = .statement;
                    },
                    .edge_undirected, .edge_directed => {
                        self.operator = switch (token.tag) {
                            .edge_undirected => .undirected,
                            else => .directed,
                        };
                        self.operator_span = token.span;
                        self.state = .edge_right;
                    },
                    // A statement boundary without `;` is valid DOT
                    // (semicolons are optional there); deferred.
                    .identifier, .right_brace, .left_brace => {
                        return self.unsupportedAt(token.span, .optional_semicolons);
                    },
                    else => return self.unexpected(.{ .semicolon = true, .undirected_operator = true, .directed_operator = true }, .statement, token),
                },
                .edge_right => switch (token.tag) {
                    .identifier => {
                        self.right = token.span;
                        self.state = .edge_terminate;
                    },
                    // `a -- { … }` is a valid-DOT subgraph endpoint.
                    .left_brace => return self.unsupportedAt(token.span, .subgraph),
                    else => return self.unexpected(.{ .identifier = true }, .edge_endpoint, token),
                },
                .edge_terminate => switch (token.tag) {
                    .semicolon => {
                        self.events.edgeStatement(.{
                            .left = self.left,
                            .operator = self.operator,
                            .operator_span = self.operator_span,
                            .right = self.right,
                        }) catch |err| return self.sinkFailure(err);
                        self.state = .statement;
                    },
                    // `a -- b -- c` is a valid-DOT edge chain; deferred.
                    .edge_undirected, .edge_directed => {
                        return self.unsupportedAt(token.span, .edge_chain);
                    },
                    .identifier, .right_brace, .left_brace => {
                        return self.unsupportedAt(token.span, .optional_semicolons);
                    },
                    else => return self.unexpected(.{ .semicolon = true }, .statement_terminator, token),
                },
                .epilogue => switch (token.tag) {
                    .eof => {
                        self.events.endDocument() catch |err| return self.sinkFailure(err);
                        return self.finish(.success);
                    },
                    else => return self.unexpected(.{ .end_of_input = true }, .document_epilogue, token),
                },
            }
            return null;
        }

        fn finish(self: *Self, outcome: Outcome) Result {
            const result: Result = .{ .outcome = outcome, .diagnostic_delivery = self.delivery };
            self.terminal = result;
            return result;
        }

        /// Report a failure diagnostic through the caller's sink, honoring
        /// the event lifecycle: abort follows begin; nothing is emitted
        /// before a supported header.
        fn fail(self: *Self, failure: diagnostic.Diagnostic) Result {
            // A failing diagnostic sink must not mask the parse outcome;
            // the loss is surfaced via `Result.diagnostic_delivery`.
            self.diagnostics.emit(failure) catch {
                self.delivery = .failed;
            };
            const reason: syntax_event.AbortReason = switch (failure.code) {
                .profile_unsupported_feature => .unsupported_feature,
                .resource_capacity_exhausted => .resource_exhausted,
                else => .invalid_syntax,
            };
            if (self.begun) self.events.abortDocument(reason);
            return self.finish(switch (reason) {
                .invalid_syntax => .invalid_syntax,
                .unsupported_feature => .unsupported_feature,
                .resource_exhausted => .resource_exhausted,
                .sink_failure => unreachable,
            });
        }

        fn sinkFailure(self: *Self, err: anyerror) Result {
            // The event sink failed mid-lifecycle; abort so it can release
            // staged state. `abortDocument` is infallible by contract.
            self.events.abortDocument(.sink_failure);
            return self.finish(.{ .sink_failure = err });
        }

        fn unexpected(
            self: *Self,
            expected: std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false),
            context: diagnostic.ParseContext,
            token: lex.Token,
        ) Result {
            const found = tokenItem(token.tag);
            // The end of input inside the body traces back to the `{` that
            // is still open (typed relation; renderers word it).
            const related: ?diagnostic.Related = if (found == .end_of_input)
                (if (self.open_brace_span) |span|
                    .{ .span = span, .role = .opened_here }
                else
                    null)
            else
                null;
            return self.fail(.{
                .code = if (found == .end_of_input) .parser_unexpected_end else .parser_unexpected_token,
                .span = token.span,
                .details = .{ .unexpected = .{
                    .expected = diagnostic.ExpectedSet.init(expected),
                    .found = found,
                    .context = context,
                    .related = related,
                } },
            });
        }

        fn unsupportedAt(self: *Self, span: location.Span, feature: diagnostic.Feature) Result {
            return self.fail(.{
                .code = .profile_unsupported_feature,
                .span = span,
                .details = .{ .unsupported_feature = feature },
            });
        }
    };
}

/// Map lexer token tags into the stable diagnostic vocabulary; diagnostics
/// must not depend on lexer types (dependency direction).
fn tokenItem(tag: lex.Token.Tag) diagnostic.SyntaxItem {
    return switch (tag) {
        .keyword_graph => .graph_keyword,
        .identifier => .identifier,
        .edge_undirected => .undirected_operator,
        .edge_directed => .directed_operator,
        .left_brace => .left_brace,
        .right_brace => .right_brace,
        .semicolon => .semicolon,
        .eof => .end_of_input,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Recording = syntax_event.RecordingSink(16);
const Bag = diagnostic.FixedBag(4);

test "empty graph commits with begin and end only, empty bag" {
    inline for (.{ "graph { }", "graph{}", "GRAPH {\r\n}\n" }) |source| {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = parse(source, &events, bag.sink(), .{});
        try expect(result.outcome == .success);
        try expectEqual(DiagnosticDelivery.complete, result.diagnostic_delivery);
        try expectEqual(@as(usize, 0), bag.items().len);

        const recorded = events.recorded();
        try expectEqual(@as(usize, 2), recorded.len);
        try expect(recorded[0] == .begin_document);
        try expectEqual(syntax_event.GraphKind.undigraph, recorded[0].begin_document.kind);
        try expect(recorded[1] == .end_document);
    }
}

test "node statements are emitted in source order with borrowed spans" {
    const source = "graph { a; b; long_name3; }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{}).outcome == .success);

    const recorded = events.recorded();
    try expectEqual(@as(usize, 5), recorded.len);
    try expectEqualStrings("a", recorded[1].node_statement.identifier.slice(source));
    try expectEqualStrings("b", recorded[2].node_statement.identifier.slice(source));
    try expectEqualStrings("long_name3", recorded[3].node_statement.identifier.slice(source));
    try expect(recorded[4] == .end_document);
}

test "edge statements preserve both written operators (kind-agnostic)" {
    // `->` in an undigraph parses structurally with an empty bag;
    // validation (step 7) is where the mismatch is reported.
    const source = "graph { a -- b; c -> d; }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{}).outcome == .success);
    try expectEqual(@as(usize, 0), bag.items().len);

    const recorded = events.recorded();
    try expectEqual(@as(usize, 4), recorded.len);

    const undirected = recorded[1].edge_statement;
    try expectEqual(syntax_event.EdgeOperator.undirected, undirected.operator);
    try expectEqualStrings("a", undirected.left.slice(source));
    try expectEqualStrings("--", undirected.operator_span.slice(source));
    try expectEqualStrings("b", undirected.right.slice(source));

    const directed = recorded[2].edge_statement;
    try expectEqual(syntax_event.EdgeOperator.directed, directed.operator);
    try expectEqualStrings("->", directed.operator_span.slice(source));
    try expectEqualStrings("d", directed.right.slice(source));
}

test "mixed node and edge statements keep source order" {
    const source = "graph { a; a -- b; b; }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{}).outcome == .success);

    const recorded = events.recorded();
    try expectEqual(@as(usize, 5), recorded.len);
    try expect(recorded[1] == .node_statement);
    try expect(recorded[2] == .edge_statement);
    try expect(recorded[3] == .node_statement);
    try expect(recorded[4] == .end_document);
}

fn expectAborted(source: []const u8, expected_reason: syntax_event.AbortReason) !void {
    var events: Recording = .{};
    var bag: Bag = .{};
    _ = parse(source, &events, bag.sink(), .{});
    const recorded = events.recorded();
    try expect(recorded.len >= 2);
    try expect(recorded[0] == .begin_document);
    try expect(recorded[recorded.len - 1] == .abort_document);
    try expectEqual(expected_reason, recorded[recorded.len - 1].abort_document);
}

test "fail-fast means the bag contains exactly one diagnostic" {
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = parse("graph @ }", &events, bag.sink(), .{});
    try expect(result.outcome == .invalid_syntax);

    try expectEqual(@as(usize, 1), bag.items().len);
    try expectEqual(diagnostic.Code.lexer_invalid_byte, bag.items()[0].code);

    try expectAborted("graph @ }", .invalid_syntax);
}

test "missing opening brace reports the typed expected set and context" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("graph ; }", &events, bag.sink(), .{}).outcome == .invalid_syntax);

    const unexpected = bag.items()[0].details.unexpected;
    try expect(unexpected.expected.contains(.left_brace));
    try expectEqual(@as(usize, 1), unexpected.expected.count());
    try expectEqual(diagnostic.SyntaxItem.semicolon, unexpected.found);
    try expectEqual(diagnostic.ParseContext.document_header, unexpected.context);
    try expect(unexpected.related == null);
}

test "unexpected end of input points back to the unclosed brace" {
    const source = "graph { a";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{}).outcome == .invalid_syntax);

    const unexpected = bag.items()[0].details.unexpected;
    try expectEqual(diagnostic.SyntaxItem.end_of_input, unexpected.found);
    const related = unexpected.related.?;
    try expectEqual(diagnostic.Related.Role.opened_here, related.role);
    try expectEqualStrings("{", related.span.slice(source));
}

test "named graph is the deferred graph-name feature, not malformed" {
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = parse("graph G { }", &events, bag.sink(), .{});
    try expect(result.outcome == .unsupported_feature);

    const failure = bag.items()[0];
    try expectEqual(diagnostic.Code.profile_unsupported_feature, failure.code);
    try expectEqual(diagnostic.Feature.graph_name, failure.details.unsupported_feature);
    try expectEqualStrings("G", failure.span.slice("graph G { }"));

    try expectAborted("graph G { }", .unsupported_feature);
}

test "missing edge endpoint is invalid syntax at the terminator" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("graph { a -- ; }", &events, bag.sink(), .{}).outcome == .invalid_syntax);

    const failure = bag.items()[0];
    try expectEqual(diagnostic.Code.parser_unexpected_token, failure.code);
    try expect(failure.details.unexpected.expected.contains(.identifier));
    try expectEqual(diagnostic.SyntaxItem.semicolon, failure.details.unexpected.found);
    try expectEqual(diagnostic.ParseContext.edge_endpoint, failure.details.unexpected.context);
}

test "trailing tokens after the document are invalid" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("graph { a; } b", &events, bag.sink(), .{}).outcome == .invalid_syntax);
    const failure = bag.items()[0];
    try expect(failure.details.unexpected.expected.contains(.end_of_input));
    try expectEqual(diagnostic.SyntaxItem.identifier, failure.details.unexpected.found);
    try expectEqual(diagnostic.ParseContext.document_epilogue, failure.details.unexpected.context);

    // The document must not commit: the terminal event is an abort.
    const recorded = events.recorded();
    try expect(recorded[recorded.len - 1] == .abort_document);
}

test "truncation at token boundaries reports unexpected end of input" {
    inline for (.{ "graph {", "graph { a", "graph { a --", "graph { a -- b;" }) |source| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(parse(source, &events, bag.sink(), .{}).outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.parser_unexpected_end, bag.items()[0].code);
    }
}

test "input truncated at every byte boundary fails safely" {
    const source = "graph { a; a -- b; }";
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = parse(source[0..i], &events, bag.sink(), .{});
        try expect(result.outcome != .success);

        // Uniform surface: every parse failure is exactly one bag entry.
        try expectEqual(@as(usize, 1), bag.items().len);

        // Lifecycle invariant: either no events at all, or begin first and
        // a terminal abort last.
        const recorded = events.recorded();
        if (recorded.len > 0) {
            try expect(recorded[0] == .begin_document);
            try expect(recorded[recorded.len - 1] == .abort_document);
        }
    }
}

test "failures before a supported header emit no events but do fill the bag" {
    // Deferred header keyword: unsupported feature, empty event sink.
    var digraph_events: Recording = .{};
    var digraph_bag: Bag = .{};
    const digraph_result = parse("digraph { a -> b; }", &digraph_events, digraph_bag.sink(), .{});
    try expect(digraph_result.outcome == .unsupported_feature);
    try expectEqual(
        diagnostic.Feature.digraph_document,
        digraph_bag.items()[0].details.unsupported_feature,
    );
    try expectEqual(@as(usize, 0), digraph_events.recorded().len);

    // Invalid leading byte: invalid syntax, empty event sink.
    var invalid_events: Recording = .{};
    var invalid_bag: Bag = .{};
    try expect(parse("@", &invalid_events, invalid_bag.sink(), .{}).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 1), invalid_bag.items().len);
    try expectEqual(@as(usize, 0), invalid_events.recorded().len);

    // Missing keyword entirely: empty event sink.
    var bare_events: Recording = .{};
    var bare_bag: Bag = .{};
    try expect(parse("{ a; }", &bare_events, bare_bag.sink(), .{}).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 0), bare_events.recorded().len);
}

test "unsupported outcome is a boundary, not a whole-input validity claim" {
    // The remainder after the unsupported introducer is malformed (`@`),
    // but the parse stopped at `digraph`: validity beyond the boundary is
    // unknown by design, and the outcome must not promise otherwise.
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = parse("digraph @", &events, bag.sink(), .{});
    try expect(result.outcome == .unsupported_feature);
    try expectEqual(diagnostic.Feature.digraph_document, bag.items()[0].details.unsupported_feature);
}

test "recognized-but-deferred constructs mid-document abort as unsupported" {
    inline for (.{
        .{ "graph { a -- b -- c; }", diagnostic.Feature.edge_chain },
        .{ "graph { a -- { b }; }", diagnostic.Feature.subgraph },
        .{ "graph { { a } }", diagnostic.Feature.subgraph },
        .{ "graph { a b; }", diagnostic.Feature.optional_semicolons },
        .{ "graph { a }", diagnostic.Feature.optional_semicolons },
        .{ "graph { a -- b }", diagnostic.Feature.optional_semicolons },
        .{ "graph { A -> B }", diagnostic.Feature.optional_semicolons },
        .{ "graph { a -> b [color=red]; }", diagnostic.Feature.attribute_list },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(parse(case[0], &events, bag.sink(), .{}).outcome == .unsupported_feature);
        try expectEqual(case[1], bag.items()[0].details.unsupported_feature);
        try expectAborted(case[0], .unsupported_feature);
    }
}

test "statement limit is a resource outcome, distinct from invalid syntax" {
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = parse("graph { a; b; }", &events, bag.sink(), .{ .max_statements = 1 });
    try expect(result.outcome == .resource_exhausted);

    const failure = bag.items()[0];
    try expectEqual(diagnostic.Code.resource_capacity_exhausted, failure.code);
    try expectEqual(diagnostic.Capacity.Resource.statements, failure.details.capacity.resource);
    try expectEqual(@as(usize, 1), failure.details.capacity.limit);

    const recorded = events.recorded();
    try expect(recorded[recorded.len - 1] == .abort_document);
    try expectEqual(
        syntax_event.AbortReason.resource_exhausted,
        recorded[recorded.len - 1].abort_document,
    );

    // The limit bounds statements, not documents: an empty graph passes.
    var empty_events: Recording = .{};
    var empty_bag: Bag = .{};
    try expect(parse("graph { }", &empty_events, empty_bag.sink(), .{ .max_statements = 0 }).outcome == .success);
}

test "zero statement limit still scans an arbitrarily large body" {
    // The statement limit is output capacity, not a work budget: the body
    // is whitespace-only, so the parser scans it linearly and succeeds.
    const source = "graph {" ++ (" " ** 4096) ++ "\n}";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{ .max_statements = 0 }).outcome == .success);
}

test "event-sink failure aborts the document and surfaces the sink's error" {
    // Capacity 2 fits begin + one statement; the second statement fails.
    var events: syntax_event.RecordingSink(2) = .{};
    var bag: Bag = .{};
    const result = parse("graph { a; b; }", &events, bag.sink(), .{});
    try expect(result.outcome == .sink_failure);
    try expectEqual(anyerror.EventCapacityExceeded, result.outcome.sink_failure);

    // The event sink owns its own failure; the diagnostic bag stays empty.
    try expectEqual(@as(usize, 0), bag.items().len);

    const recorded = events.recorded();
    try expect(recorded[recorded.len - 1] == .abort_document);
    try expectEqual(
        syntax_event.AbortReason.sink_failure,
        recorded[recorded.len - 1].abort_document,
    );
}

test "failing beginDocument still receives the cleanup abort" {
    var events: syntax_event.RecordingSink(0) = .{};
    var bag: Bag = .{};
    const result = parse("graph { }", &events, bag.sink(), .{});
    try expect(result.outcome == .sink_failure);

    // The documented lifecycle exception: an attempted-but-failed begin is
    // followed by a lone cleanup abort.
    const recorded = events.recorded();
    try expectEqual(@as(usize, 1), recorded.len);
    try expectEqual(
        syntax_event.AbortReason.sink_failure,
        recorded[0].abort_document,
    );
}

test "step is terminal-idempotent after success and after failure" {
    var events: Recording = .{};
    var bag: Bag = .{};
    var machine: Machine(*Recording) = .{
        .tokens = lex.Lexer.init("graph { a; }"),
        .events = &events,
        .diagnostics = bag.sink(),
        .options = .{},
    };
    const result = machine.runToCompletion();
    try expect(result.outcome == .success);

    // Over-calling step re-returns the latched result without new events.
    const recorded_len = events.recorded().len;
    const again = machine.step().?;
    try expect(again.outcome == .success);
    try expectEqual(recorded_len, events.recorded().len);

    var failed_events: Recording = .{};
    var failed_bag: Bag = .{};
    var failed_machine: Machine(*Recording) = .{
        .tokens = lex.Lexer.init("graph {"),
        .events = &failed_events,
        .diagnostics = failed_bag.sink(),
        .options = .{},
    };
    try expect(failed_machine.runToCompletion().outcome == .invalid_syntax);
    const failed_len = failed_events.recorded().len;
    const bag_len = failed_bag.items().len;
    try expect(failed_machine.step().?.outcome == .invalid_syntax);
    try expectEqual(failed_len, failed_events.recorded().len);
    try expectEqual(bag_len, failed_bag.items().len);
}

test "a failing diagnostic sink is surfaced as delivery failure, not masked" {
    const Rejecting = struct {
        fn emit(context: ?*anyopaque, d: diagnostic.Diagnostic) diagnostic.SinkError!void {
            _ = context;
            _ = d;
            return error.DiagnosticSinkFailure;
        }
    };
    var events: Recording = .{};
    const sink: diagnostic.Sink = .{ .context = null, .emit_fn = Rejecting.emit };
    const result = parse("graph {", &events, sink, .{});

    // The parse category stands; the lost diagnostic is visible separately.
    try expect(result.outcome == .invalid_syntax);
    try expectEqual(DiagnosticDelivery.failed, result.diagnostic_delivery);

    // A working sink reports complete delivery on the same input.
    var ok_events: Recording = .{};
    var bag: Bag = .{};
    const ok = parse("graph {", &ok_events, bag.sink(), .{});
    try expectEqual(DiagnosticDelivery.complete, ok.diagnostic_delivery);
}
