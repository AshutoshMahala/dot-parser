//! Parser state machine (milestone 1, step 5).
//!
//! Current grammar (milestone 1 + slice 2):
//!
//! ```text
//! document  := "strict"? ("graph" | "digraph") identifier? "{" statement* "}" EOF
//! statement := identifier ";"?
//!            | identifier edgeop identifier ";"?
//! edgeop    := "--" | "->"
//! ```
//!
//! Statement terminators are optional, per DOT. The document header is
//! complete at `{`; `beginDocument` fires there carrying kind, strict, and
//! the optional name. Unquoted keywords are not valid names (`graph graph`
//! is a syntax error, matching Graphviz; a keyword name requires quoting,
//! which is a deferred feature).
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
//! - Recognized-but-deferred constructs (subgraphs, edge chains, attribute
//!   statements and lists, quoted/numeral/HTML/non-ASCII identifiers,
//!   comments, ports, …) stop the parse as unsupported features, not as
//!   malformed input (R-MOD-006) — but only where the construct is legal
//!   DOT: a deferred keyword in an illegal grammar position (`subgraph` as
//!   the document root, `graph node {}`) is plain invalid syntax. The
//!   parse makes no validity claim beyond an unsupported boundary. In
//!   statement position the stop happens at the introducer keyword without
//!   lookahead: DOT keywords are reserved words everywhere (they cannot be
//!   unquoted identifiers — verified against Graphviz 15.1.0, which
//!   rejects `graph { node; }` and `graph { edge -- x; }`), so the keyword
//!   can only be introducing its deferred construct and no valid input is
//!   over-rejected. When the attribute slice lands, malformed continuations
//!   simply become syntax errors after the keyword.
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

        // Header state, accumulated until `{` completes the header.
        kind: syntax_event.GraphKind = .undigraph,
        strict: bool = false,
        keyword_span: location.Span = undefined,
        name_span: ?location.Span = null,

        // Continuation state. Everything a suspended parse needs lives in
        // the machine itself — never in `runToCompletion` locals — so
        // `next`/`pump` drivers can be layered on `step` without touching
        // the grammar (R-MOD-010 groundwork).
        state: State = .prologue,
        /// First identifier of the statement being parsed.
        left: location.Span = undefined,
        /// Operator of the edge statement being parsed.
        operator: syntax_event.EdgeOperator = undefined,
        operator_span: location.Span = undefined,
        /// Right endpoint of the edge statement being parsed.
        right: location.Span = undefined,

        const State = enum {
            /// Expect `strict` or the kind keyword.
            prologue,
            /// After `strict`: expect the kind keyword.
            kind_keyword,
            /// After the kind keyword: expect an optional name or `{`.
            header_name,
            /// After the name: expect `{`.
            header_open,
            /// Expect a statement's first identifier or the closing `}`.
            statement,
            /// After a statement's first identifier.
            after_identifier,
            /// After an edge operator: the right endpoint identifier.
            edge_right,
            /// After a complete edge: `;`, or whatever starts next.
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
                .prologue => switch (token.tag) {
                    .keyword_strict => {
                        self.strict = true;
                        self.state = .kind_keyword;
                    },
                    .keyword_graph => self.acceptKind(.undigraph, token),
                    .keyword_digraph => self.acceptKind(.digraph, token),
                    else => return self.unexpected(.{
                        .strict_keyword = true,
                        .graph_keyword = true,
                        .digraph_keyword = true,
                    }, .document_header, token),
                },
                .kind_keyword => switch (token.tag) {
                    .keyword_graph => self.acceptKind(.undigraph, token),
                    .keyword_digraph => self.acceptKind(.digraph, token),
                    else => return self.unexpected(.{
                        .graph_keyword = true,
                        .digraph_keyword = true,
                    }, .document_header, token),
                },
                .header_name => switch (token.tag) {
                    .identifier => {
                        self.name_span = token.span;
                        self.state = .header_open;
                    },
                    .left_brace => return self.beginBody(token),
                    // Unquoted keywords are not valid names (Graphviz
                    // rejects `graph graph`); a keyword name needs quoting,
                    // which is a deferred feature.
                    else => return self.unexpected(.{
                        .identifier = true,
                        .left_brace = true,
                    }, .document_header, token),
                },
                .header_open => switch (token.tag) {
                    .left_brace => return self.beginBody(token),
                    else => return self.unexpected(.{ .left_brace = true }, .document_header, token),
                },
                .statement => switch (token.tag) {
                    .identifier => if (self.beginStatement(token)) |result| return result,
                    .right_brace => self.state = .epilogue,
                    // `{ … }` here is a valid-DOT anonymous subgraph.
                    .left_brace => return self.unsupportedAt(token.span, .subgraph),
                    // Statement position is where these keywords legally
                    // introduce deferred constructs (`subgraph s { … }`,
                    // `node [ … ]`, …); anywhere else they are plain
                    // syntax errors.
                    .keyword_graph,
                    .keyword_subgraph,
                    .keyword_node,
                    .keyword_edge,
                    => return self.unsupportedAt(token.span, statementKeywordFeature(token.tag).?),
                    else => return self.unexpected(.{
                        .identifier = true,
                        .right_brace = true,
                    }, .document_body, token),
                },
                .after_identifier => switch (token.tag) {
                    .semicolon => {
                        if (self.emitNode()) |result| return result;
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
                    // Terminators are optional: the node statement ended,
                    // and this token starts the next construct.
                    .identifier => {
                        if (self.emitNode()) |result| return result;
                        if (self.beginStatement(token)) |result| return result;
                    },
                    .right_brace => {
                        if (self.emitNode()) |result| return result;
                        self.state = .epilogue;
                    },
                    .left_brace => {
                        if (self.emitNode()) |result| return result;
                        return self.unsupportedAt(token.span, .subgraph);
                    },
                    .keyword_graph, .keyword_subgraph, .keyword_node, .keyword_edge => {
                        if (self.emitNode()) |result| return result;
                        return self.unsupportedAt(token.span, statementKeywordFeature(token.tag).?);
                    },
                    else => return self.unexpected(.{
                        .semicolon = true,
                        .undirected_operator = true,
                        .directed_operator = true,
                        .identifier = true,
                        .right_brace = true,
                    }, .statement, token),
                },
                .edge_right => switch (token.tag) {
                    .identifier => {
                        self.right = token.span;
                        self.state = .edge_terminate;
                    },
                    // `a -- { … }` and `a -- subgraph s { … }` are
                    // valid-DOT subgraph endpoints.
                    .left_brace,
                    .keyword_subgraph,
                    => return self.unsupportedAt(token.span, .subgraph),
                    else => return self.unexpected(.{ .identifier = true }, .edge_endpoint, token),
                },
                .edge_terminate => switch (token.tag) {
                    .semicolon => {
                        if (self.emitEdge()) |result| return result;
                        self.state = .statement;
                    },
                    // `a -- b -- c` is a valid-DOT edge chain; deferred.
                    .edge_undirected, .edge_directed => {
                        return self.unsupportedAt(token.span, .edge_chain);
                    },
                    // Terminators are optional: the edge ended, and this
                    // token starts the next construct.
                    .identifier => {
                        if (self.emitEdge()) |result| return result;
                        if (self.beginStatement(token)) |result| return result;
                    },
                    .right_brace => {
                        if (self.emitEdge()) |result| return result;
                        self.state = .epilogue;
                    },
                    .left_brace => {
                        if (self.emitEdge()) |result| return result;
                        return self.unsupportedAt(token.span, .subgraph);
                    },
                    .keyword_graph, .keyword_subgraph, .keyword_node, .keyword_edge => {
                        if (self.emitEdge()) |result| return result;
                        return self.unsupportedAt(token.span, statementKeywordFeature(token.tag).?);
                    },
                    else => return self.unexpected(.{
                        .semicolon = true,
                        .identifier = true,
                        .right_brace = true,
                    }, .statement_terminator, token),
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

        fn acceptKind(self: *Self, kind: syntax_event.GraphKind, token: lex.Token) void {
            self.kind = kind;
            self.keyword_span = token.span;
            self.state = .header_name;
        }

        /// `{` completes the document header: emit `beginDocument` with the
        /// accumulated kind, strict marker, and optional name.
        fn beginBody(self: *Self, token: lex.Token) ?Result {
            self.begun = true;
            self.open_brace_span = token.span;
            self.events.beginDocument(.{
                .kind = self.kind,
                .strict = self.strict,
                .keyword_span = self.keyword_span,
                .name_span = self.name_span,
            }) catch |err| return self.sinkFailure(err);
            self.state = .statement;
            return null;
        }

        /// Start a statement at its first identifier: the one place the
        /// caller-visible statement limit is enforced.
        fn beginStatement(self: *Self, token: lex.Token) ?Result {
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
            return null;
        }

        fn emitNode(self: *Self) ?Result {
            self.events.nodeStatement(.{
                .identifier = self.left,
            }) catch |err| return self.sinkFailure(err);
            return null;
        }

        fn emitEdge(self: *Self) ?Result {
            self.events.edgeStatement(.{
                .left = self.left,
                .operator = self.operator,
                .operator_span = self.operator_span,
                .right = self.right,
            }) catch |err| return self.sinkFailure(err);
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
                // `fail` only handles diagnostic-classified failures; event
                // sink failures route through `sinkFailure` exclusively.
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

/// The deferred construct a keyword legally introduces in statement
/// position (`graph [ … ]`, `subgraph s { … }`, `node [ … ]`,
/// `edge [ … ]`). Positions where these keywords are not legal DOT report
/// plain unexpected-token syntax errors instead — the classification is a
/// grammar decision, which is why it lives here and not in the lexer.
fn statementKeywordFeature(tag: lex.Token.Tag) ?diagnostic.Feature {
    return switch (tag) {
        .keyword_graph => .graph_attribute_statement,
        .keyword_subgraph => .subgraph,
        .keyword_node => .node_attribute_statement,
        .keyword_edge => .edge_attribute_statement,
        else => null,
    };
}

/// Map lexer token tags into the stable diagnostic vocabulary; diagnostics
/// must not depend on lexer types (dependency direction).
fn tokenItem(tag: lex.Token.Tag) diagnostic.SyntaxItem {
    return switch (tag) {
        .keyword_graph => .graph_keyword,
        .keyword_digraph => .digraph_keyword,
        .keyword_strict => .strict_keyword,
        .keyword_subgraph => .subgraph_keyword,
        .keyword_node => .node_keyword,
        .keyword_edge => .edge_keyword,
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
    const result = parse("graph { @ }", &events, bag.sink(), .{});
    try expect(result.outcome == .invalid_syntax);

    try expectEqual(@as(usize, 1), bag.items().len);
    try expectEqual(diagnostic.Code.lexer_invalid_byte, bag.items()[0].code);

    try expectAborted("graph { @ }", .invalid_syntax);
}

test "missing opening brace reports the typed expected set and context" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("graph ; }", &events, bag.sink(), .{}).outcome == .invalid_syntax);

    const unexpected = bag.items()[0].details.unexpected;
    try expect(unexpected.expected.contains(.left_brace));
    try expect(unexpected.expected.contains(.identifier));
    try expectEqual(@as(usize, 2), unexpected.expected.count());
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

test "document headers: kind, strict, and name reach the begin event" {
    const source = "strict digraph Routes { a -> b; }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{}).outcome == .success);
    try expectEqual(@as(usize, 0), bag.items().len);

    const begin = events.recorded()[0].begin_document;
    try expectEqual(syntax_event.GraphKind.digraph, begin.kind);
    try expect(begin.strict);
    try expectEqualStrings("digraph", begin.keyword_span.slice(source));
    try expectEqualStrings("Routes", begin.name_span.?.slice(source));
}

test "plain headers default to non-strict and unnamed" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("graph { }", &events, bag.sink(), .{}).outcome == .success);
    const begin = events.recorded()[0].begin_document;
    try expectEqual(syntax_event.GraphKind.undigraph, begin.kind);
    try expect(!begin.strict);
    try expect(begin.name_span == null);
}

test "an unquoted keyword is not a valid graph name (matches Graphviz)" {
    // Graphviz rejects `graph graph {}`; a keyword name requires quoting,
    // which is a deferred feature. This reverses an earlier classification
    // that assumed keywords were valid unquoted names.
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = parse("graph graph { }", &events, bag.sink(), .{});
    try expect(result.outcome == .invalid_syntax);

    const unexpected = bag.items()[0].details.unexpected;
    try expect(unexpected.expected.contains(.identifier));
    try expect(unexpected.expected.contains(.left_brace));
    try expectEqual(diagnostic.SyntaxItem.graph_keyword, unexpected.found);
    try expectEqual(@as(usize, 0), events.recorded().len);
}

test "strict must be followed by a kind keyword" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("strict { }", &events, bag.sink(), .{}).outcome == .invalid_syntax);

    const unexpected = bag.items()[0].details.unexpected;
    try expect(unexpected.expected.contains(.graph_keyword));
    try expect(unexpected.expected.contains(.digraph_keyword));
    try expectEqual(@as(usize, 0), events.recorded().len);
}

test "optional semicolons: adjacent statements split correctly" {
    const source = "graph { a b c -- d e }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(parse(source, &events, bag.sink(), .{}).outcome == .success);

    // a(node) b(node) c--d(edge) e(node), all without terminators.
    const recorded = events.recorded();
    try expectEqual(@as(usize, 6), recorded.len);
    try expectEqualStrings("a", recorded[1].node_statement.identifier.slice(source));
    try expectEqualStrings("b", recorded[2].node_statement.identifier.slice(source));
    const edge = recorded[3].edge_statement;
    try expectEqualStrings("c", edge.left.slice(source));
    try expectEqualStrings("d", edge.right.slice(source));
    try expectEqualStrings("e", recorded[4].node_statement.identifier.slice(source));
    try expect(recorded[5] == .end_document);
}

test "mixed terminated and unterminated statements agree" {
    var with: Recording = .{};
    var without: Recording = .{};
    var bag: Bag = .{};
    try expect(parse("digraph { a -> b; c; }", &with, bag.sink(), .{}).outcome == .success);
    try expect(parse("digraph { a -> b c }", &without, bag.sink(), .{}).outcome == .success);
    try expectEqual(with.recorded().len, without.recorded().len);
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
    // Deferred lexical construct: unsupported feature, empty event sink.
    var quoted_events: Recording = .{};
    var quoted_bag: Bag = .{};
    const quoted_result = parse("\"g\" { a; }", &quoted_events, quoted_bag.sink(), .{});
    try expect(quoted_result.outcome == .unsupported_feature);
    try expectEqual(
        diagnostic.Feature.quoted_identifier,
        quoted_bag.items()[0].details.unsupported_feature,
    );
    try expectEqual(@as(usize, 0), quoted_events.recorded().len);

    // An incomplete header (begin fires only at `{`): no events either.
    var named_events: Recording = .{};
    var named_bag: Bag = .{};
    try expect(parse("strict digraph G", &named_events, named_bag.sink(), .{}).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 0), named_events.recorded().len);

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
    // but the parse stopped at `subgraph`: validity beyond the boundary is
    // unknown by design, and the outcome must not promise otherwise.
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = parse("graph { subgraph @", &events, bag.sink(), .{});
    try expect(result.outcome == .unsupported_feature);
    try expectEqual(diagnostic.Feature.subgraph, bag.items()[0].details.unsupported_feature);
}

test "deferred keywords in illegal positions are syntax errors, not unsupported" {
    // A subgraph cannot be the document root, and no keyword is a valid
    // unquoted graph name or edge endpoint (Graphviz rejects all of
    // these). Reporting them as unsupported features would claim the input
    // uses a deferred construct when it is simply malformed.
    inline for (.{
        .{ "subgraph s { a; }", diagnostic.SyntaxItem.subgraph_keyword },
        .{ "strict subgraph { }", diagnostic.SyntaxItem.subgraph_keyword },
        .{ "graph subgraph { }", diagnostic.SyntaxItem.subgraph_keyword },
        .{ "graph node { }", diagnostic.SyntaxItem.node_keyword },
        .{ "node { }", diagnostic.SyntaxItem.node_keyword },
        .{ "graph { a -- node; }", diagnostic.SyntaxItem.node_keyword },
        .{ "graph { a -- edge; }", diagnostic.SyntaxItem.edge_keyword },
        .{ "graph { a; } subgraph", diagnostic.SyntaxItem.subgraph_keyword },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = parse(case[0], &events, bag.sink(), .{});
        try expect(result.outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.parser_unexpected_token, bag.items()[0].code);
        try expectEqual(case[1], bag.items()[0].details.unexpected.found);
    }
}

test "recognized-but-deferred constructs mid-document abort as unsupported" {
    inline for (.{
        .{ "graph { a -- b -- c; }", diagnostic.Feature.edge_chain },
        .{ "graph { a -- { b }; }", diagnostic.Feature.subgraph },
        .{ "graph { a -- subgraph s; }", diagnostic.Feature.subgraph },
        .{ "graph { { a } }", diagnostic.Feature.subgraph },
        .{ "graph { a { } }", diagnostic.Feature.subgraph },
        .{ "graph { subgraph s { b } }", diagnostic.Feature.subgraph },
        .{ "graph { a -- b subgraph s }", diagnostic.Feature.subgraph },
        .{ "digraph { graph }", diagnostic.Feature.graph_attribute_statement },
        .{ "digraph { node [shape=box]; }", diagnostic.Feature.node_attribute_statement },
        .{ "graph { a node }", diagnostic.Feature.node_attribute_statement },
        .{ "graph { edge [] }", diagnostic.Feature.edge_attribute_statement },
        .{ "graph { a -> b [color=red]; }", diagnostic.Feature.attribute_list },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(parse(case[0], &events, bag.sink(), .{}).outcome == .unsupported_feature);
        try expectEqual(case[1], bag.items()[0].details.unsupported_feature);
        try expectAborted(case[0], .unsupported_feature);
    }
}

test "statement-position reserved words stop at the introducer, without lookahead" {
    // DOT keywords are reserved words in every position — an unquoted
    // keyword is never an identifier. Graphviz 15.1.0 rejects each input
    // below (`syntax error near ';'`/`'--'`), so stopping at the keyword
    // over-rejects no valid DOT; what follows the introducer is unchecked
    // boundary, exactly as documented for the unsupported outcome. Once
    // the attribute slice consumes these keywords itself, the malformed
    // continuations here become syntax errors after the keyword — the
    // classification tightens without an API change.
    inline for (.{
        .{ "graph { graph; }", diagnostic.Feature.graph_attribute_statement },
        .{ "graph { subgraph; }", diagnostic.Feature.subgraph },
        .{ "graph { node; }", diagnostic.Feature.node_attribute_statement },
        .{ "graph { edge -- x; }", diagnostic.Feature.edge_attribute_statement },
        .{ "graph { node -- x; }", diagnostic.Feature.node_attribute_statement },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(parse(case[0], &events, bag.sink(), .{}).outcome == .unsupported_feature);
        try expectEqual(case[1], bag.items()[0].details.unsupported_feature);
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

test "parser state stays small (R-PERF-005 parser-state-size regression guard)" {
    // The whole machine — lexer, continuation state, options, bookkeeping —
    // must remain a small constant, independent of input size. 320 B is the
    // current measured value plus headroom (see docs/BASELINES.md), not an
    // architectural budget: if a slice legitimately grows the state, measure,
    // update the baseline doc, and raise this bound in the same commit.
    try expect(@sizeOf(Machine(*Recording)) <= 320);
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
