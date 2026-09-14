//! Parser state machine (milestone 1, step 5).
//!
//! Current grammar (attributes, ports and node-reference chains included):
//!
//! ```text
//! document  := "strict"? ("graph" | "digraph") identifier? "{" statement* "}" EOF
//! statement := (node_ref attributes? | node_ref (edgeop node_ref)+ attributes?
//!            | identifier "=" identifier | ("graph" | "node" | "edge") attributes) ";"?
//! node_ref  := identifier (":" identifier (":" identifier)?)?
//! attributes := ("[" (identifier "=" identifier (";" | ",")?)* "]")+
//! edgeop    := "--" | "->"
//! ```
//!
//! Statement terminators are optional, per DOT. The document header is
//! complete at `{`; `beginDocument` fires there carrying kind, strict, and
//! the optional name. Unquoted keywords are not valid names (`graph graph`
//! is a syntax error, matching Graphviz; a keyword name requires quoting,
//! which is supported as an identifier).
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
//! - Iterative state-machine parsing has no recursion, so input size and shape
//!   cannot exhaust the call stack (R-PERF-002).
//! - Work is a single linear scan of the input (R-PERF-001, R-SEC-003);
//!   `Options.max_statements` additionally bounds the statements processed.
//! - Subgraphs and HTML/non-ASCII bare identifiers remain
//!   deferred. Attributes are parsed and retained without default resolution,
//!   key deduplication or value interpretation. Malformed supported attribute
//!   syntax is invalid, not unsupported. Unsupported boundaries still make
//!   no claim about validity beyond the detected construct.
//!
//! Only a run-to-completion `parse` is exposed for now, but the machine is
//! internally resumable: the metered specialization retains lexical, grammar,
//! and pending-dispatch state. Each private `advance` credit buys one source
//! examination, grammar transition, or normal callback attempt (R-MOD-010).
//! The ordinary specialization shares the grammar with immediate callbacks;
//! pending work and progress counters compile out. Fixed-storage sessions and
//! optional cancellation are exposed through root.zig.

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const lex = @import("lexer.zig");
const execution = @import("execution.zig");
const syntax_event = @import("syntax_event.zig");

pub const Options = struct {
    /// Maximum number of statements the parser will process before stopping
    /// with a `resource_exhausted` outcome. This is a statement/output
    /// capacity bound (R-ROB-002), **not** a total-work budget: the parser
    /// always performs one linear scan, so total work is bounded by input
    /// length — a whitespace-heavy body or a long identifier is still
    /// scanned once in full. The private metered driver does not change this
    /// public run-to-completion API; cancellation is selected by session features.
    max_statements: usize = std.math.maxInt(usize),
    /// Total key/value pairs, including standalone assignments. Not a scan budget.
    max_attributes: usize = std.math.maxInt(usize),
};

/// The parse outcome category. The diagnostics explaining a failure travel
/// through the caller's diagnostic sink, never through this value.
pub const Outcome = union(enum) {
    /// The document parsed completely and the event sink committed.
    success,
    /// Explicit cancellation or an observed caller request; no diagnostic.
    cancelled,
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

// Internal execution vocabulary, not re-exported from root.zig.
pub const Phase = enum { scan, grammar, dispatch, terminal };
const Progress = struct {
    result: ?Result,
    work_used: usize,
    source_frontier: usize,
    phase: Phase,
    completed_statements: usize,
    completed_pairs: usize,
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
    var machine: Machine(EventsPtr, false, false, false) = .{
        .tokens = lex.Lexer.init(source),
        .events = events,
        .diagnostics = diagnostics,
        .options = options,
    };
    return machine.runToCompletion();
}

pub fn Machine(comptime EventsPtr: type, comptime metered: bool, comptime audited: bool, comptime cancellable: bool) type {
    return struct {
        const Self = @This();

        const Action = enum { begin, node, edge, edge_chain, edge_link, ported_reference, attribute_statement, assignment, attribute, commit };
        const Work = struct {
            token: lex.Token = undefined,
            action: Action = undefined,
            phase: Phase = .scan,
            replay: bool = false,
            completed_statements: if (metered) usize else void = if (metered) 0 else {},
            completed_pairs: if (metered) usize else void = if (metered) 0 else {},
        };
        const Audit = struct {
            grammar: usize = 0,
            dispatch: usize = 0,
        };

        tokens: lex.Scanner(metered, audited),
        work: if (metered or cancellable) Work else void = if (metered or cancellable) .{} else {},
        cancellation: if (cancellable) ?execution.Cancellation else void = if (cancellable) null else {},
        audit: if (audited) Audit else void = if (audited) .{} else {},
        events: EventsPtr,
        diagnostics: diagnostic.Sink,
        options: Options,
        statements: usize = 0,
        attributes: usize = 0,
        attribute_key: location.Span = undefined,
        attribute_target: syntax_event.AttributeTarget = .graph,
        open_bracket_span: ?location.Span = null,
        pending: enum { node, edge, edge_chain, attributes } = .node,
        delivery: DiagnosticDelivery = .complete,
        /// Span of the document's `{`, once consumed — the related location
        /// reported when the input ends inside the body.
        open_brace_span: ?location.Span = null,
        /// True once `beginDocument` has been issued; from then on every
        /// exit path must emit a terminal event.
        begun: bool = false,
        /// Latched once a terminal result is produced. Further driver calls
        /// return it unchanged — no re-emitted events or diagnostics. Metered
        /// calls report zero work used.
        terminal: ?Result = null,

        // Header state, accumulated until `{` completes the header.
        kind: syntax_event.GraphKind = .undigraph,
        strict: bool = false,
        keyword_span: location.Span = undefined,
        name_span: ?location.Span = null,

        // Continuation state. Everything a suspended parse needs lives in
        // the machine itself — never in `runToCompletion` locals. Metered
        // execution also retains one lookahead token and its pending action.
        state: State = .prologue,
        /// First identifier of the statement being parsed.
        left: location.Span = undefined,
        /// Operator of the edge statement being parsed.
        operator: syntax_event.EdgeOperator = undefined,
        operator_span: location.Span = undefined,
        /// Right endpoint of the edge statement being parsed.
        right: location.Span = undefined,

        link_operator: syntax_event.EdgeOperator = undefined,
        link_operator_span: location.Span = undefined,

        left_port: ?u32 = null,
        right_port: ?u32 = null,
        link_port: ?u32 = null,
        link_right: location.Span = undefined,
        port_first: location.Span = undefined,
        port_second: ?location.Span = null,
        port_colon: location.Span = undefined,
        port_target: enum { left, right, link } = .left,
        port_resume: State = .after_identifier,

        const State = enum {
            port_first,
            port_after_first,
            port_second,
            port_after_second,
            chain_after_identifier,
            chain_right,
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
            assignment_value,
            completed,
            attribute_open,
            attribute_key_or_close,
            attribute_equals,
            attribute_value,
            attribute_after_value,
            after_attributes,
        };

        pub fn runToCompletion(self: *Self) Result {
            if (metered) {
                while (true) {
                    if (self.advance(std.math.maxInt(usize)).result) |result| return result;
                }
            } else if (cancellable) {
                _ = self.drive(false, 0);
                return self.terminal.?;
            } else {
                while (true) {
                    if (self.step()) |result| return result;
                }
            }
        }

        /// Ordinary immediate driver: one token, shared grammar, direct events.
        /// It has no pending-token storage, work counter or progress counters.
        fn step(self: *Self) ?Result {
            if (metered or cancellable) @compileError("controlled machines use drive");
            if (self.terminal) |result| return result;
            const token = switch (self.tokens.next()) {
                .token => |token| token,
                .failure => |failure| return self.fail(failure),
            };
            return self.transition(token);
        }

        /// Private bounded driver. A credit buys a lexical examination, one
        /// grammar transition, or one normal event attempt; never two classes.
        pub fn advance(self: *Self, budget: usize) Progress {
            if (!metered) @compileError("advance requires metering; use runToCompletion");
            return self.progress(self.drive(true, budget));
        }

        fn drive(self: *Self, comptime bounded: bool, budget: usize) usize {
            if (self.terminal != null) return 0;
            var remaining = if (bounded) budget else {};
            while (true) {
                // The entry check also covers zero-budget calls. A normal
                // callback's next boundary is polled, but a concrete failure
                // or successful commit is latched before another poll.
                if (cancellable) {
                    if (self.cancellation) |hook| if (hook.requested()) {
                        _ = self.cancel();
                        break;
                    };
                }
                if (bounded and remaining == 0) break;
                switch (self.work.phase) {
                    .scan => {
                        const scanned = if (cancellable)
                            lex.advanceOne(metered, audited, &self.tokens)
                        else
                            lex.advanceBounded(audited, &self.tokens, remaining);
                        if (bounded) remaining -= scanned.work_used;
                        if (scanned.result) |result| switch (result) {
                            .token => |token| {
                                self.work.token = token;
                                self.work.phase = .grammar;
                            },
                            .failure => |failure| {
                                _ = self.fail(failure);
                            },
                        };
                    },
                    .grammar => {
                        if (bounded) remaining -= 1;
                        self.work.phase = .scan;
                        self.work.replay = false;
                        _ = self.transition(self.work.token);
                    },
                    .dispatch => {
                        if (bounded) remaining -= 1;
                        _ = self.dispatch(self.work.action, self.work.token);
                        if (self.terminal == null)
                            self.work.phase = if (self.work.replay) .grammar else .scan;
                    },
                    .terminal => unreachable,
                }
                if (self.terminal != null) break;
            }
            return if (bounded) budget - remaining else 0;
        }

        /// Explicit cleanup works even without a polling hook or positive budget.
        pub fn cancel(self: *Self) Result {
            if (self.terminal) |result| return result;
            if (self.begun) self.events.abortDocument(.cancelled);
            return self.finish(.cancelled);
        }

        fn progress(self: *const Self, used: usize) Progress {
            return .{
                .result = self.terminal,
                .work_used = used,
                .source_frontier = self.tokens.source_frontier,
                .phase = self.work.phase,
                .completed_statements = self.work.completed_statements,
                .completed_pairs = self.work.completed_pairs,
            };
        }

        fn transition(self: *Self, token: lex.Token) ?Result {
            if (audited) self.audit.grammar += 1;
            // Ordinary parsing replays only a finished suffix/link lookahead.
            // Controlled parsing returns after one transition and charges the
            // replay separately through Work; no recursion or hot-path flag.
            while (true) {
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
                        // rejects `graph graph`); a keyword name needs quoting.
                        else => return self.unexpected(.{
                            .identifier = true,
                            .left_brace = true,
                        }, .document_header, token),
                    },
                    .header_open => switch (token.tag) {
                        .left_brace => return self.beginBody(token),
                        else => return self.unexpected(.{ .left_brace = true }, .document_header, token),
                    },
                    .statement => return self.beginNext(token),
                    .after_identifier => switch (token.tag) {
                        .colon => {
                            if (self.left_port != null) return self.unexpected(nodeEndExpected(false), .statement, token);
                            self.startPort(.left, .after_identifier, token.span);
                        },
                        .equals => {
                            if (self.left_port != null) return self.unexpected(nodeEndExpected(false), .statement, token);
                            if (self.countAttribute(self.left)) |result| return result;
                            self.state = .assignment_value;
                        },
                        .left_bracket => self.openAttributes(token),
                        .edge_undirected, .edge_directed => {
                            self.operator = if (token.tag == .edge_undirected) .undirected else .directed;
                            self.operator_span = token.span;
                            self.state = .edge_right;
                        },
                        else => return self.finishPending(token, nodeEndExpected(self.left_port == null), .statement),
                    },
                    .edge_right => switch (token.tag) {
                        .identifier => {
                            self.right = token.span;
                            self.right_port = null;
                            self.pending = .edge;
                            self.state = .edge_terminate;
                        },
                        .left_brace, .keyword_subgraph => return self.unsupportedAt(token.span, .subgraph),
                        else => return self.unexpected(.{ .identifier = true }, .edge_endpoint, token),
                    },
                    .edge_terminate => switch (token.tag) {
                        .colon => {
                            if (self.pending != .edge or self.right_port != null)
                                return self.unexpected(edgeEndExpected(false), .statement_terminator, token);
                            self.startPort(.right, .edge_terminate, token.span);
                        },
                        .left_bracket => self.openAttributes(token),
                        .edge_undirected, .edge_directed => {
                            self.link_operator = if (token.tag == .edge_undirected) .undirected else .directed;
                            self.link_operator_span = token.span;
                            self.state = .chain_right;
                        },
                        else => {
                            return self.finishPending(token, edgeEndExpected(self.pending == .edge and self.right_port == null), .statement_terminator);
                        },
                    },
                    .chain_right => switch (token.tag) {
                        .identifier => {
                            self.pending = .edge_chain;
                            self.link_right = token.span;
                            self.link_port = null;
                            self.state = .chain_after_identifier;
                        },
                        .left_brace, .keyword_subgraph => return self.unsupportedAt(token.span, .subgraph),
                        else => return self.unexpected(.{ .identifier = true }, .edge_endpoint, token),
                    },
                    .chain_after_identifier => {
                        if (token.tag == .colon) {
                            if (self.link_port != null) return self.unexpected(edgeEndExpected(false), .statement_terminator, token);
                            self.startPort(.link, .chain_after_identifier, token.span);
                        } else {
                            self.state = .edge_terminate;
                            if (self.dispatchThenReplay(.edge_link, token)) |result| return result;
                            if (!metered and !cancellable) continue;
                        }
                    },
                    .port_first => {
                        if (token.tag != .identifier) return self.unexpected(.{ .identifier = true }, .port_component, token);
                        self.port_first = token.span;
                        self.state = .port_after_first;
                    },
                    .port_after_first => {
                        if (token.tag == .colon) {
                            self.port_colon = token.span;
                            self.state = .port_second;
                        } else {
                            if (self.finishPort(token)) |result| return result;
                            if (!metered and !cancellable) continue;
                        }
                    },
                    .port_second => {
                        if (token.tag != .identifier) return self.unexpected(.{ .identifier = true }, .port_component, token);
                        self.port_second = token.span;
                        self.state = .port_after_second;
                    },
                    .port_after_second => {
                        if (self.finishPort(token)) |result| return result;
                        if (!metered and !cancellable) continue;
                    },
                    .assignment_value => {
                        if (token.tag != .identifier)
                            return self.unexpected(.{ .identifier = true }, .assignment_value, token);
                        self.state = .completed;
                        return self.schedule(.assignment, token);
                    },
                    .completed => return self.continueAfterStatement(token),
                    .attribute_open => {
                        if (token.tag != .left_bracket)
                            return self.unexpected(.{ .left_bracket = true }, .attribute_list, token);
                        self.openAttributes(token);
                    },
                    .attribute_key_or_close => switch (token.tag) {
                        .right_bracket => self.closeAttributes(),
                        .identifier => return self.beginAttribute(token),
                        else => return self.unexpected(.{ .identifier = true, .right_bracket = true }, .attribute_key, token),
                    },
                    .attribute_equals => {
                        if (token.tag != .equals)
                            return self.unexpected(.{ .equals = true }, .attribute_key, token);
                        self.state = .attribute_value;
                    },
                    .attribute_value => {
                        if (token.tag != .identifier)
                            return self.unexpected(.{ .identifier = true }, .attribute_value, token);
                        self.state = .attribute_after_value;
                        return self.schedule(.attribute, token);
                    },
                    .attribute_after_value => switch (token.tag) {
                        .right_bracket => self.closeAttributes(),
                        .comma, .semicolon => self.state = .attribute_key_or_close,
                        .identifier => return self.beginAttribute(token),
                        else => return self.unexpected(.{
                            .identifier = true,
                            .right_bracket = true,
                            .comma = true,
                            .semicolon = true,
                        }, .attribute_list, token),
                    },
                    .after_attributes => {
                        if (token.tag == .left_bracket) {
                            self.openAttributes(token);
                        } else return self.finishPending(token, statementEndExpected(true), .statement_terminator);
                    },
                    .epilogue => switch (token.tag) {
                        .eof => return self.schedule(.commit, token),
                        else => return self.unexpected(.{ .end_of_input = true }, .document_epilogue, token),
                    },
                }
                return null;
            }
        }

        fn acceptKind(self: *Self, kind: syntax_event.GraphKind, token: lex.Token) void {
            self.kind = kind;
            self.keyword_span = token.span;
            self.state = .header_name;
        }

        /// Recognize the header, then schedule its separate begin event.
        /// begun becomes true only when the callback is actually attempted.
        fn beginBody(self: *Self, token: lex.Token) ?Result {
            self.open_brace_span = token.span;
            self.state = .statement;
            return self.schedule(.begin, token);
        }

        /// Start a statement at its identifier or attribute keyword: the place the
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
            self.left_port = null;
            self.pending = .node;
            self.state = .after_identifier;
            return null;
        }

        fn beginNext(self: *Self, token: lex.Token) ?Result {
            switch (token.tag) {
                .identifier => return self.beginStatement(token),
                .right_brace => self.state = .epilogue,
                .left_brace, .keyword_subgraph => return self.unsupportedAt(token.span, .subgraph),
                .keyword_graph, .keyword_node, .keyword_edge => {
                    if (self.beginStatement(token)) |result| return result;
                    self.pending = .attributes;
                    self.attribute_target = switch (token.tag) {
                        .keyword_graph => .graph,
                        .keyword_node => .node,
                        else => .edge,
                    };
                    self.state = .attribute_open;
                },
                else => return self.unexpected(.{
                    .identifier = true,
                    .right_brace = true,
                    .left_brace = true,
                    .graph_keyword = true,
                    .node_keyword = true,
                    .edge_keyword = true,
                    .subgraph_keyword = true,
                }, .document_body, token),
            }
            return null;
        }

        fn startPort(self: *Self, target: @FieldType(Self, "port_target"), resume_state: State, colon: location.Span) void {
            self.port_target = target;
            self.port_resume = resume_state;
            self.port_colon = colon;
            self.port_second = null;
            self.state = .port_first;
        }

        fn finishPort(self: *Self, token: lex.Token) ?Result {
            self.state = self.port_resume;
            return self.dispatchThenReplay(.ported_reference, token);
        }

        fn dispatchThenReplay(self: *Self, action: Action, token: lex.Token) ?Result {
            if (metered or cancellable) {
                self.work.replay = true;
                return self.schedule(action, token);
            }
            return self.schedule(action, token);
        }

        fn finishPending(self: *Self, token: lex.Token, expected: std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false), context: diagnostic.ParseContext) ?Result {
            switch (token.tag) {
                .semicolon, .identifier, .right_brace, .left_brace, .keyword_graph, .keyword_node, .keyword_edge, .keyword_subgraph => {},
                else => return self.unexpected(expected, context, token),
            }
            const action: Action = switch (self.pending) {
                .node => .node,
                .edge => .edge,
                .edge_chain => .edge_chain,
                .attributes => .attribute_statement,
            };
            self.state = .completed;
            if (metered or cancellable) {
                // Retain this lookahead until the owning statement is emitted.
                // A separate grammar credit then processes it in .completed.
                self.work.replay = true;
                return self.schedule(action, token);
            }
            if (self.schedule(action, token)) |result| return result;
            return self.continueAfterStatement(token);
        }

        fn continueAfterStatement(self: *Self, token: lex.Token) ?Result {
            if (token.tag == .semicolon) {
                self.state = .statement;
                return null;
            }
            return self.beginNext(token);
        }

        fn openAttributes(self: *Self, token: lex.Token) void {
            self.open_bracket_span = token.span;
            self.state = .attribute_key_or_close;
        }

        fn closeAttributes(self: *Self) void {
            self.open_bracket_span = null;
            self.state = .after_attributes;
        }

        fn countAttribute(self: *Self, at: location.Span) ?Result {
            if (self.attributes == self.options.max_attributes) return self.fail(.{
                .code = .resource_capacity_exhausted,
                .span = at,
                .details = .{ .capacity = .{ .resource = .attributes, .limit = self.options.max_attributes } },
            });
            self.attributes += 1;
            return null;
        }

        fn beginAttribute(self: *Self, token: lex.Token) ?Result {
            if (self.countAttribute(token.span)) |result| return result;
            self.attribute_key = token.span;
            self.state = .attribute_equals;
            return null;
        }

        fn schedule(self: *Self, action: Action, token: lex.Token) ?Result {
            if (metered or cancellable) {
                self.work.action = action;
                self.work.phase = .dispatch;
                return null;
            }
            return self.dispatch(action, token);
        }

        /// One charged normal callback in the bounded driver. Payloads reuse
        /// saved spans and the cached token; there is no event queue or copying
        /// of a source-sized collection. Callback execution is a callout.
        fn dispatch(self: *Self, action: Action, token: lex.Token) ?Result {
            if (audited) self.audit.dispatch += 1;
            switch (action) {
                .begin => {
                    self.begun = true;
                    self.events.beginDocument(.{
                        .kind = self.kind,
                        .strict = self.strict,
                        .keyword_span = self.keyword_span,
                        .name_span = self.name_span,
                    }) catch |err| return self.sinkFailure(err);
                },
                .node => self.events.nodeStatement(.{ .identifier = self.left, .port = self.left_port }) catch |err| return self.sinkFailure(err),
                .edge => self.events.edgeStatement(.{
                    .left = self.left,
                    .left_port = self.left_port,
                    .operator = self.operator,
                    .operator_span = self.operator_span,
                    .right = self.right,
                    .right_port = self.right_port,
                }) catch |err| return self.sinkFailure(err),
                .ported_reference => {
                    const identifier_span = switch (self.port_target) {
                        .left => self.left,
                        .right => self.right,
                        .link => self.link_right,
                    };
                    const index = self.events.portedReference(.{
                        .identifier = identifier_span,
                        .first = self.port_first,
                        .second = self.port_second,
                    }) catch |err| return self.sinkFailure(err);
                    switch (self.port_target) {
                        .left => self.left_port = index,
                        .right => self.right_port = index,
                        .link => self.link_port = index,
                    }
                },
                .edge_link => self.events.edgeLink(.{
                    .operator = self.link_operator,
                    .operator_span = self.link_operator_span,
                    .right = self.link_right,
                    .right_port = self.link_port,
                }) catch |err| return self.sinkFailure(err),
                .edge_chain => self.events.edgeChainStatement(.{
                    .left = self.left,
                    .left_port = self.left_port,
                    .operator = self.operator,
                    .operator_span = self.operator_span,
                    .right = self.right,
                    .right_port = self.right_port,
                }) catch |err| return self.sinkFailure(err),
                .attribute_statement => self.events.attributeStatement(.{
                    .target = self.attribute_target,
                    .keyword_span = self.left,
                }) catch |err| return self.sinkFailure(err),
                .assignment => self.events.assignment(.{ .key = self.left, .value = token.span }) catch |err| return self.sinkFailure(err),
                .attribute => self.events.attribute(.{ .key = self.attribute_key, .value = token.span }) catch |err| return self.sinkFailure(err),
                .commit => {
                    self.events.endDocument() catch |err| return self.sinkFailure(err);
                    return self.finish(.success);
                },
            }
            if (metered) switch (action) {
                .node, .edge, .edge_chain, .attribute_statement => self.work.completed_statements += 1,
                .assignment => {
                    self.work.completed_statements += 1;
                    self.work.completed_pairs += 1;
                },
                .attribute => self.work.completed_pairs += 1,
                .begin, .commit, .edge_link, .ported_reference => {},
            };
            return null;
        }

        fn finish(self: *Self, outcome: Outcome) Result {
            const result: Result = .{ .outcome = outcome, .diagnostic_delivery = self.delivery };
            self.terminal = result;
            if (metered or cancellable) self.work.phase = .terminal;
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
                .sink_failure, .cancelled => unreachable,
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
            // EOF traces back to the pending suffix colon, otherwise the
            // innermost still-open delimiter (typed relation; renderers word it).
            const missing_port = self.state == .port_first or self.state == .port_second;
            const origin: ?location.Span = if (missing_port) self.port_colon else self.open_bracket_span orelse self.open_brace_span;
            const related: ?diagnostic.Related = if (found == .end_of_input)
                (if (origin) |span|
                    .{ .span = span, .role = if (missing_port) .suffix_started_here else .opened_here }
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

fn nodeEndExpected(unqualified: bool) std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false) {
    var expected = edgeEndExpected(unqualified);
    expected.equals = unqualified;
    return expected;
}

fn edgeEndExpected(port_allowed: bool) std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false) {
    var expected = statementEndExpected(true);
    expected.undirected_operator = true;
    expected.directed_operator = true;
    expected.colon = port_allowed;
    return expected;
}

fn statementEndExpected(brackets: bool) std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false) {
    return .{
        .semicolon = true,
        .identifier = true,
        .right_brace = true,
        .left_bracket = brackets,
        .left_brace = true,
        .graph_keyword = true,
        .node_keyword = true,
        .edge_keyword = true,
        .subgraph_keyword = true,
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
        .colon => .colon,
        .eof => .end_of_input,
        .left_bracket => .left_bracket,
        .right_bracket => .right_bracket,
        .equals => .equals,
        .comma => .comma,
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

test "chain dispatch failures preserve budget accounting and terminal cleanup" {
    const source = "digraph {a->b->c->d[x=1] z->q->r}";
    const total = try checkBudgetPartition(source, &.{1}, .{}, null, false);
    try expectEqual(total, try checkBudgetPartition(source, &.{ 0, 3, 17 }, .{}, null, false));
    // begin, two links, attribute, owner, link, owner, commit.
    for (0..8) |at| _ = try checkBudgetPartition(source, &.{ 0, 1, 5 }, .{}, at, false);
}

const CancellationProbe = struct {
    flag: bool = false,
    polls: usize = 0,
    fn hook(self: *@This()) execution.Cancellation {
        return .{ .context = self, .is_requested = poll };
    }
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.flag;
    }
};

test "cancellation during successful and failed events preserves terminal precedence" {
    const source = "graph {a[x=1][y=2] node[] z=3 a--b[w=4]}";
    inline for (.{ false, true }) |fails| for (0..9) |at| {
        var request: CancellationProbe = .{};
        var events: BudgetSink = .{ .cancel_flag = &request.flag, .cancel_at = at, .fail_at = if (fails) at else null };
        var diags: BudgetDiagnostics = .{};
        var machine: Machine(*BudgetSink, true, true, true) = .{
            .tokens = lex.Scanner(true, true).init(source),
            .events = &events,
            .diagnostics = diags.sink(),
            .options = .{},
            .cancellation = request.hook(),
        };
        const progress = machine.advance(std.math.maxInt(usize));
        const outcome = progress.result.?.outcome;
        if (fails) {
            try expect(outcome == .sink_failure);
        } else if (at == 8) {
            try expect(outcome == .success); // Commit wins immediately.
        } else {
            try expect(outcome == .cancelled);
        }
        try expectEqual(at + 1, events.attempts);
        try expectEqual(@as(usize, if (!fails and at == 8) 0 else 1), events.aborts);
        try expectEqual(@as(usize, 0), diags.attempts);
        try expectEqual(progress.work_used, machine.tokens.examinations + machine.audit.grammar + machine.audit.dispatch);
        try expect(request.polls <= progress.work_used + 1);
        const polls = request.polls;
        _ = machine.advance(0);
        _ = machine.cancel();
        try expectEqual(polls, request.polls);
    };
}

test "cancellation can stop every lexical continuation and execution phase" {
    const Scanner = lex.Scanner(true, true);
    const State = @FieldType(Scanner, "state");
    var states = std.EnumSet(State).initEmpty();
    var phases = std.EnumSet(Phase).initEmpty();
    const sources = [_][]const u8{
        " \r\n#x\r//y\n/*z**/graph {a;}",
        "graph {a\xff;}",
        "graph {-1.2 -.5 .1 1->2 3--4}",
        "graph {\"a\\\"b\" /*glue*/ + \"c\" [x=y] }",
    };
    for (sources) |source| for (0..source.len * 4 + 16) |budget| {
        var request: CancellationProbe = .{};
        var events: BudgetSink = .{};
        var machine: Machine(*BudgetSink, true, true, true) = .{
            .tokens = Scanner.init(source),
            .events = &events,
            .diagnostics = diagnostic.discard,
            .options = .{},
            .cancellation = request.hook(),
        };
        const before = machine.advance(budget);
        if (before.result != null) continue;
        states.insert(machine.tokens.state);
        phases.insert(before.phase);
        const begun = machine.begun;
        const attempts = events.attempts;
        const reads = machine.tokens.examinations;
        request.flag = true;
        const cancelled = machine.advance(0);
        try expect(cancelled.result.?.outcome == .cancelled);
        try expectEqual(@as(usize, 0), cancelled.work_used);
        try expectEqual(attempts, events.attempts);
        try expectEqual(reads, machine.tokens.examinations);
        try expectEqual(@as(usize, if (begun) 1 else 0), events.aborts);
    };
    var expected_states = std.EnumSet(State).initFull();
    expected_states.remove(.ready);
    try expectEqual(expected_states, states);
    var expected_phases = std.EnumSet(Phase).initFull();
    expected_phases.remove(.terminal);
    try expectEqual(expected_phases, phases);
}

test "late cancellation from a rejected syntax diagnostic does not mask failure" {
    const Reporter = struct {
        request: *CancellationProbe,
        emits: usize = 0,
        fn emit(context: ?*anyopaque, _: diagnostic.Diagnostic) diagnostic.SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.emits += 1;
            self.request.flag = true;
            return error.DiagnosticSinkFailure;
        }
    };
    var request: CancellationProbe = .{};
    var reporter: Reporter = .{ .request = &request };
    var events: BudgetSink = .{};
    var machine: Machine(*BudgetSink, true, true, true) = .{
        .tokens = lex.Scanner(true, true).init("graph {a[x=]}"),
        .events = &events,
        .diagnostics = .{ .context = &reporter, .emit_fn = Reporter.emit },
        .options = .{},
        .cancellation = request.hook(),
    };
    while (machine.advance(1).result == null) {}
    try expect(machine.terminal.?.outcome == .invalid_syntax);
    try expectEqual(DiagnosticDelivery.failed, machine.terminal.?.diagnostic_delivery);
    try expectEqual(@as(usize, 1), events.aborts);
    try expectEqual(@as(usize, 1), reporter.emits);
    try expect(machine.cancel().outcome == .invalid_syntax);
}

// Independent probes count attempted callouts, not just accepted records.
const BudgetSink = struct {
    records: [128]syntax_event.Event = undefined,
    len: usize = 0,
    attempts: usize = 0,
    aborts: usize = 0,
    statements: usize = 0,
    pairs: usize = 0,
    fail_at: ?usize = null,
    cancel_flag: ?*bool = null,
    cancel_at: ?usize = null,

    fn record(self: *@This(), event: syntax_event.Event) !void {
        const attempt = self.attempts;
        self.attempts += 1;
        if (self.cancel_at == attempt) self.cancel_flag.?.* = true;
        if (self.fail_at == attempt) return error.Refused;
        self.records[self.len] = event;
        self.len += 1;
        switch (event) {
            .node_statement, .edge_statement, .edge_chain_statement, .attribute_statement => self.statements += 1,
            .assignment => {
                self.statements += 1;
                self.pairs += 1;
            },
            .attribute => self.pairs += 1,
            else => {},
        }
    }
    pub fn beginDocument(self: *@This(), event: syntax_event.BeginDocument) !void {
        try self.record(.{ .begin_document = event });
    }
    pub fn nodeStatement(self: *@This(), event: syntax_event.NodeStatement) !void {
        try self.record(.{ .node_statement = event });
    }
    pub fn edgeStatement(self: *@This(), event: syntax_event.EdgeStatement) !void {
        try self.record(.{ .edge_statement = event });
    }
    pub fn portedReference(self: *@This(), event: syntax_event.PortedReference) !u32 {
        try self.record(.{ .ported_reference = event });
        // Recorded event indices are valid opaque handles for this test sink.
        return @intCast(self.len - 1);
    }
    pub fn edgeLink(self: *@This(), event: syntax_event.EdgeLink) !void {
        try self.record(.{ .edge_link = event });
    }
    pub fn edgeChainStatement(self: *@This(), event: syntax_event.EdgeStatement) !void {
        try self.record(.{ .edge_chain_statement = event });
    }
    pub fn attributeStatement(self: *@This(), event: syntax_event.AttributeStatement) !void {
        try self.record(.{ .attribute_statement = event });
    }
    pub fn assignment(self: *@This(), event: syntax_event.Attribute) !void {
        try self.record(.{ .assignment = event });
    }
    pub fn attribute(self: *@This(), event: syntax_event.Attribute) !void {
        try self.record(.{ .attribute = event });
    }
    pub fn endDocument(self: *@This()) !void {
        try self.record(.end_document);
    }
    pub fn abortDocument(self: *@This(), reason: syntax_event.AbortReason) void {
        self.aborts += 1;
        self.records[self.len] = .{ .abort_document = reason };
        self.len += 1;
    }
};

const BudgetDiagnostics = struct {
    bag: Bag = .{},
    attempts: usize = 0,
    reject: bool = false,
    fn sink(self: *@This()) diagnostic.Sink {
        return .{ .context = self, .emit_fn = emit };
    }
    fn emit(context: ?*anyopaque, item: diagnostic.Diagnostic) diagnostic.SinkError!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.attempts += 1;
        if (self.reject) return error.DiagnosticSinkFailure;
        try self.bag.sink().emit(item);
    }
};

fn checkBudgetPartition(source: []const u8, budgets: []const usize, options: Options, fail_at: ?usize, reject: bool) !usize {
    var reference: BudgetSink = .{ .fail_at = fail_at };
    var reference_diags: BudgetDiagnostics = .{ .reject = reject };
    const expected = parse(source, &reference, reference_diags.sink(), options);
    var events: BudgetSink = .{ .fail_at = fail_at };
    var diags: BudgetDiagnostics = .{ .reject = reject };
    var machine: Machine(*BudgetSink, true, true, false) = .{
        .tokens = lex.Scanner(true, true).init(source),
        .events = &events,
        .diagnostics = diags.sink(),
        .options = options,
    };
    var calls: usize = 0;
    var total: usize = 0;
    var frontier: usize = 0;
    while (true) : (calls += 1) {
        try expect(calls <= 16 * source.len + 128);
        const budget = budgets[calls % budgets.len];
        const reads = machine.tokens.examinations;
        const grammar = machine.audit.grammar;
        const dispatch = machine.audit.dispatch;
        const attempts = events.attempts;
        const aborts = events.aborts;
        const diagnostics = diags.attempts;
        const before = machine.progress(0);
        const progress = machine.advance(budget);
        const examined = machine.tokens.examinations - reads;
        try expectEqual(progress.work_used, examined + (machine.audit.grammar - grammar) + (machine.audit.dispatch - dispatch));
        try expectEqual(machine.audit.dispatch - dispatch, events.attempts - attempts);
        try expect(progress.work_used <= budget);
        try expect(examined <= progress.work_used);
        try expect(progress.source_frontier >= frontier);
        try expect(progress.source_frontier <= source.len);
        try expectEqual(events.statements, progress.completed_statements);
        try expectEqual(events.pairs, progress.completed_pairs);
        if (budget == 0) try std.testing.expectEqualDeep(before, progress);
        if (progress.result == null) {
            try expectEqual(aborts, events.aborts);
            try expectEqual(diagnostics, diags.attempts);
            if (budget != 0) try expect(progress.work_used != 0);
        } else {
            try expect(events.aborts - aborts <= 1);
            try expect(diags.attempts - diagnostics <= 1);
        }
        total += progress.work_used;
        frontier = progress.source_frontier;
        if (progress.result) |result| {
            try std.testing.expectEqualDeep(expected, result);
            try expectEqual(Phase.terminal, progress.phase);
            break;
        }
    }
    try std.testing.expectEqualDeep(reference.records[0..reference.len], events.records[0..events.len]);
    try std.testing.expectEqualDeep(reference_diags.bag.items(), diags.bag.items());
    try expectEqual(reference.attempts, events.attempts);
    try expectEqual(reference.aborts, events.aborts);
    try expectEqual(reference_diags.attempts, diags.attempts);
    const stopped = machine.progress(0);
    const stopped_reads = machine.tokens.examinations;
    const stopped_audit = machine.audit;
    inline for (.{ 0, 1, std.math.maxInt(usize) }) |budget| {
        try std.testing.expectEqualDeep(stopped, machine.advance(budget));
        try expectEqual(stopped_reads, machine.tokens.examinations);
        try std.testing.expectEqualDeep(stopped_audit, machine.audit);
        try expectEqual(reference.attempts, events.attempts);
        try expectEqual(reference.aborts, events.aborts);
        try expectEqual(reference_diags.attempts, diags.attempts);
    }
    return total;
}

test "metered parser partitions preserve events diagnostics and independent work accounting" {
    const sources = [_][]const u8{
        "graph{}",                                                         "strict digraph named { a b; c->d; e--f }",
        "graph { a[x=1][y=2] node[] z=3 a--b[w=4] graph[k=v] edge[k=v] }", "#line\n/* pre */graph { \"a\" + /* gap */ \"b\"[x=\"v\\\"q\" y=-.5] // tail\r\n }",
        "",                                                                "graph {",
        "graph {a[x=]}",                                                   "graph {a[x=1 y=]}",
        "graph {a[x=1] @}",                                                "graph {a--b--c}",
        "graph {subgraph {}}",                                             "graph { a:port }",
        "digraph {a:p:e->b:q->c:0[x=1]}",                                  "graph {a:p:}",
        "graph {a:p:q:r}",                                                 "graph {<html>}",
        "graph {/*",                                                       "graph {\"unterminated",
        "graph{} /*",                                                      "digraph { a-> }",
    };
    for (sources) |source| {
        const total = try checkBudgetPartition(source, &.{std.math.maxInt(usize)}, .{}, null, false);
        try expectEqual(total, try checkBudgetPartition(source, &.{1}, .{}, null, false));
        try expectEqual(total, try checkBudgetPartition(source, &.{2}, .{}, null, false));
        try expectEqual(total, try checkBudgetPartition(source, &.{ 0, 1, 3, 0, 7, 2 }, .{}, null, false));
    }
}

test "metered parser every prefix and callback failure preserve lifecycle" {
    const source = "strict digraph \"g\" { a[x=1][y=2] node[] z=3 a->b[w=\"v\"+\"x\"] }";
    for (0..source.len + 1) |end| {
        _ = try checkBudgetPartition(source[0..end], &.{ 0, 1, 2 }, .{}, null, false);
    }
    // Includes failed begin, all payload variants, and failed commit.
    for (0..9) |index| {
        _ = try checkBudgetPartition(source, &.{1}, .{}, index, false);
        _ = try checkBudgetPartition(source, &.{ 0, 3, 7 }, .{}, index, false);
    }
    _ = try checkBudgetPartition("graph {a[x=]}", &.{1}, .{}, null, true);
    _ = try checkBudgetPartition("@", &.{1}, .{}, null, true);
}

test "ported reference callback failures preserve lifecycle and accounting" {
    const source = "digraph {a:p:e[x=1] a:q->b:r->c:s:w[k=v]}";
    var events: BudgetSink = .{};
    try expect(parse(source, &events, diagnostic.discard, .{}).outcome == .success);
    for (0..events.attempts) |index| {
        _ = try checkBudgetPartition(source, &.{1}, .{}, index, false);
        _ = try checkBudgetPartition(source, &.{ 0, 3, 7 }, .{}, index, false);
    }
}

test "metered parser capacities remain output limits not work budgets" {
    inline for (.{ 0, 1, 2 }) |limit| {
        _ = try checkBudgetPartition("graph { a[x=1] b[y=2] c=z }", &.{1}, .{ .max_statements = limit }, null, false);
        _ = try checkBudgetPartition("graph { a[x=1] b[y=2] c=z }", &.{ 0, 2, 9 }, .{ .max_attributes = limit }, null, false);
    }
}

test "metered parser yields before begin pair owner and commit dispatch" {
    var events: BudgetSink = .{};
    var machine: Machine(*BudgetSink, true, true, false) = .{
        .tokens = lex.Scanner(true, true).init("graph {a[x=1]}"),
        .events = &events,
        .diagnostics = diagnostic.discard,
        .options = .{},
    };
    var dispatches: usize = 0;
    while (machine.terminal == null) {
        if (machine.work.phase == .dispatch) {
            const before = events.attempts;
            const pending = machine.work.action;
            if (pending == .begin) try expect(!machine.begun);
            if (pending == .node) {
                try expectEqual(@as(usize, 1), machine.work.completed_pairs);
                try expectEqual(@as(usize, 0), machine.work.completed_statements);
            }
            try expectEqual(@as(usize, 0), machine.advance(0).work_used);
            try expectEqual(before, events.attempts);
            const result = machine.advance(1);
            try expectEqual(before + 1, events.attempts);
            if (pending == .commit) try expect(result.result.?.outcome == .success);
            dispatches += 1;
        } else _ = machine.advance(1);
    }
    try expectEqual(@as(usize, 4), dispatches);
}

test "metered parser yields inside megabyte trivia and attribute values" {
    const n = 1024 * 1024;
    const source = try std.testing.allocator.alloc(u8, n + 32);
    defer std.testing.allocator.free(source);
    const cases = .{
        .{ "graph {/*", "*/}", 'a' },
        .{ "graph {a[x=\"", "\"]}", 'a' },
        .{ "graph {", "}", ' ' },
        .{ "graph {a:\"", "\":e->b:p}", 'a' },
    };
    inline for (cases) |parts| {
        @memcpy(source[0..parts[0].len], parts[0]);
        @memset(source[parts[0].len..][0..n], parts[2]);
        @memcpy(source[parts[0].len + n ..][0..parts[1].len], parts[1]);
        _ = try checkBudgetPartition(source[0 .. parts[0].len + n + parts[1].len], &.{1}, .{}, null, false);
    }
}

test "ordinary parser compiles out pending work and audit storage" {
    const Ordinary = Machine(*BudgetSink, false, false, false);
    try expect(@FieldType(Ordinary, "work") == void);
    try expect(@FieldType(Ordinary, "audit") == void);
    try expect(@FieldType(lex.Scanner(false, false), "source_frontier") == void);
    try expect(@sizeOf(Ordinary) <= 736);
}

test "unaudited metered driver charges empty document exactly and runs to completion" {
    var events: BudgetSink = .{};
    var machine: Machine(*BudgetSink, true, false, false) = .{
        .tokens = lex.Scanner(true, false).init("graph{}"),
        .events = &events,
        .diagnostics = diagnostic.discard,
        .options = .{},
    };
    // Nine examinations (including keyword lookahead and EOF), four grammar
    // transitions, begin and commit. Finishing syntax does not commit for free.
    const before_commit = machine.advance(14);
    try expect(before_commit.result == null);
    try expectEqual(Phase.dispatch, before_commit.phase);
    try expectEqual(@as(usize, 1), events.attempts);
    try expect(machine.runToCompletion().outcome == .success);
    try expectEqual(@as(usize, 2), events.attempts);
    try expectEqual(@as(usize, 15), try checkBudgetPartition("graph{}", &.{1}, .{}, null, false));
}

test "metered parser deterministic arbitrary-byte inputs match immediate grammar" {
    var random = std.Random.DefaultPrng.init(0x627564676574);
    var bytes: [96]u8 = undefined;
    for (0..400) |_| {
        random.random().bytes(&bytes);
        const len = random.random().uintLessThan(usize, bytes.len + 1);
        _ = try checkBudgetPartition(bytes[0..len], &.{ 0, 1, 5 }, .{}, null, false);
        // A supported header also exercises arbitrary bytes inside the body.
        @memcpy(bytes[0..7], "graph {");
        _ = try checkBudgetPartition(bytes[0..@max(7, len)], &.{ 1, 2, 11 }, .{}, null, false);
    }
}

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
    // Graphviz rejects `graph graph {}`; a keyword name requires quoting.
    // This reverses an earlier classification
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
    // A quoted ID is supported, but cannot replace the document-kind keyword.
    var quoted_events: Recording = .{};
    var quoted_bag: Bag = .{};
    const quoted_result = parse("\"g\" { a; }", &quoted_events, quoted_bag.sink(), .{});
    try expect(quoted_result.outcome == .invalid_syntax);
    try expectEqual(
        diagnostic.Code.parser_unexpected_token,
        quoted_bag.items()[0].code,
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
        .{ "graph { a -- { b }; }", diagnostic.Feature.subgraph },
        .{ "graph { a -- subgraph s; }", diagnostic.Feature.subgraph },
        .{ "graph { { a } }", diagnostic.Feature.subgraph },
        .{ "graph { a { } }", diagnostic.Feature.subgraph },
        .{ "graph { subgraph s { b } }", diagnostic.Feature.subgraph },
        .{ "graph { a -- b subgraph s }", diagnostic.Feature.subgraph },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(parse(case[0], &events, bag.sink(), .{}).outcome == .unsupported_feature);
        try expectEqual(case[1], bag.items()[0].details.unsupported_feature);
        try expectAborted(case[0], .unsupported_feature);
    }
}

test "attribute keywords require a bracket list; subgraphs remain deferred" {
    inline for (.{ "graph { graph; }", "graph { node; }", "graph { edge -- x; }", "graph { node -- x; }", "digraph { graph }", "graph { a node }" }) |source| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(parse(source, &events, bag.sink(), .{}).outcome == .invalid_syntax);
        try expect(bag.items()[0].details.unexpected.expected.contains(.left_bracket));
    }
    try expectAborted("graph { subgraph; }", .unsupported_feature);
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
    // must remain a small constant, independent of input size. 736 B is the
    // current measured value plus headroom (see docs/BASELINES.md), not an
    // architectural budget: if a slice legitimately grows the state, measure,
    // update the baseline doc, and raise this bound in the same commit.
    try expect(@sizeOf(Machine(*Recording, false, false, false)) <= 736);
}

test "step is terminal-idempotent after success and after failure" {
    var events: Recording = .{};
    var bag: Bag = .{};
    var machine: Machine(*Recording, false, false, false) = .{
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
    var failed_machine: Machine(*Recording, false, false, false) = .{
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

test "attribute pairs stream before owners and abort if any event is refused" {
    const source = "graph { a[x=1][y=2]; node[]; z=3; a--b[w=4] }";
    var complete: Recording = .{};
    try expect(parse(source, &complete, diagnostic.discard, .{}).outcome == .success);
    const recorded = complete.recorded();
    try expect(recorded[0] == .begin_document);
    try expect(recorded[1] == .attribute);
    try expect(recorded[2] == .attribute);
    try expect(recorded[3] == .node_statement);
    try expect(recorded[4] == .attribute_statement);
    try expect(recorded[5] == .assignment);
    try expect(recorded[6] == .attribute);
    try expect(recorded[7] == .edge_statement);
    try expect(recorded[8] == .end_document);
    inline for (0..8) |capacity| {
        var events: syntax_event.RecordingSink(capacity) = .{};
        const result = parse(source, &events, diagnostic.discard, .{});
        try expect(result.outcome == .sink_failure);
        try expectEqual(anyerror.EventCapacityExceeded, result.outcome.sink_failure);
        try expectEqual(@as(usize, capacity + 1), events.recorded().len);
        try expect(events.recorded()[capacity] == .abort_document);
    }
    var partial: Recording = .{};
    try expect(parse("graph { a[x=1 y=] }", &partial, diagnostic.discard, .{}).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 3), partial.recorded().len);
    try expect(partial.recorded()[1] == .attribute);
    try expect(partial.recorded()[2] == .abort_document);
}
