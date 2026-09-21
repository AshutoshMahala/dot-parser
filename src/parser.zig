//! Parser state machine (milestone 1, step 5).
//!
//! Current grammar (subgraph endpoints, attributes, ports and mixed chains):
//!
//! ```text
//! document  := "strict"? ("graph" | "digraph") identifier? "{" statement* "}" EOF
//! statement := (node_ref attributes? | endpoint (edgeop endpoint)+ attributes?
//!            | identifier "=" identifier | ("graph" | "node" | "edge") attributes
//!            | subgraph) ";"?
//! subgraph  := ("subgraph" identifier?)? "{" statement* "}"
//! endpoint  := node_ref | subgraph
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
//! the syntax operator is preserved in the emitted event. Accepted malformed
//! spellings are normalized under syntax policy; their original spans remain.
//! Whether an
//! operator is legal for the document's kind is validation policy (step 7),
//! never a parse error.
//!
//! ## Reporting surface
//!
//! Every phase of this library reports problems the same way: diagnostics
//! are emitted into a caller-owned `diagnostic.Sink` (usually backed by a
//! `FixedBag`), and the function returns only a small control-flow result
//! (R-DIAG-003). The parser's default policy is fail-fast (R-FUNC-007), so
//! it attempts at most one failure diagnostic unless recovery is selected.
//! Lexical warnings and recovery use that same reporting surface.
//!
//! Guarantees:
//! - Instance-owned state, no mutable globals (R-ROB-003).
//! - Fail fast on the first structural failure by default; the sink
//!   lifecycle from `syntax_event.zig` is honored: no events before a
//!   supported header, abort after begin when the document cannot commit —
//!   including the documented cleanup abort after an attempted
//!   `beginDocument` that itself failed.
//! - With `Policy.recovery = .statements`, a syntax error inside the body
//!   aborts the sink once, then parsing continues for diagnostics only:
//!   tokens are skipped to the next `;` or `}` at the same brace depth
//!   (a skipped `{` is matched by counting), the next statement parses
//!   normally, and every further syntax error is reported the same way.
//!   The outcome is still `invalid_syntax`, no document is ever published,
//!   and the sink sees exactly one terminal event. Lexical errors resume
//!   through `Scanner.resumeAfterFailure`; end of input, header errors,
//!   trailing tokens, limits and deferred features still stop the parse.
//! - Iterative state-machine parsing has no recursion, so input size and shape
//!   cannot exhaust the call stack (R-PERF-002).
//! - Work is a single linear scan of the input (R-PERF-001, R-SEC-003);
//!   `Policy.limits.max_statements` additionally bounds statements processed.
//! - HTML identifiers remain deferred. Attributes are parsed and retained
//!   without default resolution, key deduplication or value interpretation.
//!   Malformed supported attribute syntax is invalid, not unsupported.
//!   Unsupported boundaries still make no claim about validity beyond the
//!   detected construct.
//!
//! One policy-specialized machine serves one-shot parsing and sessions through
//! parse_engine.zig. The metered specialization retains lexical, grammar,
//! and pending-dispatch state. Each private `advance` credit buys one source
//! examination, grammar transition, or normal callback attempt (R-MOD-010).
//! The ordinary specialization shares the grammar with immediate callbacks;
//! pending work and progress counters compile out. Fixed-storage sessions and
//! optional cancellation are exposed through root.zig.

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const lex = @import("lexer/lexer.zig");
// Tests pin each backend explicitly; production selects through Policy.scanner.
const scalar_lex = @import("lexer/scalar.zig");
const block_lex = @import("lexer/block.zig");
const execution = @import("execution.zig");
const syntax_event = @import("syntax_event.zig");
const scratch_impl = @import("scratch.zig");
const policy = @import("policy.zig");

/// The parse outcome category. The diagnostics explaining a failure travel
/// through the caller's diagnostic sink, never through this value.
pub const Outcome = union(enum) {
    scratch_failure: scratch_impl.Stack.Error,
    /// The document parsed completely and the event sink committed.
    success,
    /// Explicit cancellation or an observed caller request; no diagnostic.
    cancelled,
    /// The input is not accepted by the selected syntax policy.
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
    accepted_deviations: u32 = 0,
    warnings: u32 = 0,
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

/// Fixed policies capture limits/recovery in code; only scratch is retained as
/// a resource. Runtime policies retain the resolved parse-stage settings once.
pub fn Machine(comptime EventsPtr: type, comptime metered: bool, comptime audited: bool, comptime cancellable: bool, comptime ScannerOf: fn (comptime bool, comptime bool, comptime ?bool) type, comptime fixed: ?policy.ParseSettings) type {
    comptime {
        const info = @typeInfo(EventsPtr);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("events must be a single-item pointer to a syntax sink, e.g. `&my_sink`");
        }
        syntax_event.assertSyntaxSink(info.pointer.child);
    }
    const recovery_enabled = if (fixed) |value| value.recovery == .statements else true;
    const deviations_enabled = if (fixed) |value| value.syntax.acceptsDeviations() else true;
    const operators_enabled = if (fixed) |value| value.syntax.acceptsOperators() else true;
    return struct {
        const Self = @This();

        const Action = enum { begin, begin_subgraph, end_subgraph, subgraph_statement, node, edge, edge_chain, edge_link, ported_reference, attribute_statement, assignment, attribute, commit };
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

        tokens: ScannerOf(metered, audited, if (fixed) |value| value.ambiguous_numeral != .off else null),
        work: if (metered or cancellable) Work else void = if (metered or cancellable) .{} else {},
        cancellation: if (cancellable) ?execution.Cancellation else void = if (cancellable) null else {},
        audit: if (audited) Audit else void = if (audited) .{} else {},
        events: EventsPtr,
        diagnostics: diagnostic.Sink,
        settings: if (fixed == null) policy.ParseSettings else void = if (fixed == null) .{} else {},
        /// Borrowed temporary storage; the machine never owns an allocator.
        scratch: ?*scratch_impl.Stack = null,
        statements: usize = 0,
        attributes: usize = 0,
        attribute_key: location.Span = undefined,
        attribute_target: syntax_event.AttributeTarget = .graph,
        open_bracket_span: ?location.Span = null,
        pending: enum { node, edge, edge_chain, attributes } = .node,
        delivery: DiagnosticDelivery = .complete,
        /// At most one acceptance per consumed nonempty span in a u32 source.
        deviations: if (deviations_enabled) u32 else void = if (deviations_enabled) 0 else {},
        warnings: u32 = 0,
        /// Span of the innermost scope's `{`, once consumed — the related location
        /// reported when the input ends inside the body.
        open_brace_span: ?location.Span = null,
        /// The first `}` that closed a scope while sitting at a smaller
        /// indentation than the line that opened it. Brace matching alone
        /// cannot tell which brace is missing when the input ends inside a
        /// scope; this heuristic usually can, and is reported as the
        /// `.misindented_close` suspect on the end-of-input diagnostic.
        suspect_close: ?location.Span = null,
        /// True once `beginDocument` has been issued; from then on every
        /// exit path must emit a terminal event.
        begun: bool = false,
        /// True once the sink received its terminal abort. Recovery keeps
        /// the grammar running for diagnostics after that point, with no
        /// further events and an `invalid_syntax` outcome.
        aborted: bool = false,
        /// Braces skipped (and not yet matched) while resynchronizing.
        skip_depth: if (recovery_enabled) usize else void = if (recovery_enabled) 0 else {},
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

        left_scope: ?u32 = null,
        right_scope: ?u32 = null,
        subgraph_role: syntax_event.ScopeRole = .left,
        completed_scope: u32 = 0,
        left_port: ?u32 = null,
        right_port: ?u32 = null,
        link_port: ?u32 = null,
        link_right: location.Span = undefined,
        port_first: location.Span = undefined,
        port_second: ?location.Span = null,
        port_colon: location.Span = undefined,
        port_target: enum { left, right, link } = .left,
        port_resume: State = .after_identifier,

        subgraph_start: location.Span = undefined,
        subgraph_name: ?location.Span = null,

        const State = enum {
            subgraph_name,
            subgraph_open,
            after_subgraph,
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
            /// Skipping to the next statement boundary after a syntax error.
            recovering,
        };

        fn limit(self: *const Self, comptime name: []const u8) usize {
            return if (fixed) |value| @field(value.limits, name) else @field(self.settings.limits, name);
        }

        fn recovery(self: *const Self) policy.Recovery {
            return if (fixed) |value| value.recovery else self.settings.recovery;
        }

        fn syntax(self: *const Self) policy.SyntaxSettings {
            return if (fixed) |value| value.syntax else self.settings.syntax;
        }

        pub fn acceptedDeviations(self: *const Self) u32 {
            return if (deviations_enabled) self.deviations else 0;
        }

        fn warn(self: *Self, d: diagnostic.Diagnostic) void {
            self.warnings += 1;
            self.diagnostics.emit(d) catch {
                self.delivery = .failed;
            };
        }

        fn acceptDeviation(self: *Self, acceptance: policy.Acceptance, d: diagnostic.Diagnostic) void {
            if (!deviations_enabled) unreachable;
            std.debug.assert(acceptance != .reject);
            self.deviations += 1;
            if (acceptance == .warn) self.warn(d);
        }

        /// Reuse scanners' exact malformed-operator recognition on the cold
        /// failure path. No scanner flags, new token tags, source rescans or
        /// extra per-byte branches. A candidate is consumed/diagnosed only by
        /// its grammar transition, including after a port/link lookahead replay.
        fn operatorCandidate(self: *Self, d: diagnostic.Diagnostic) ?lex.Token {
            if (!operators_enabled) return null;
            if (d.details != .invalid_operator) return null;
            switch (self.state) {
                .after_identifier, .after_subgraph, .edge_terminate, .chain_after_identifier, .port_after_first, .port_after_second => {},
                else => return null,
            }
            const tag: lex.Token.Tag = switch (d.details.invalid_operator.shape) {
                .spaced => return null,
                .long => blk: {
                    if (self.syntax().long_operator == .reject) return null;
                    break :blk if (d.details.invalid_operator.found == '>') .edge_directed else .edge_undirected;
                },
                .lone => blk: {
                    if (self.syntax().bare_dash.acceptance == .reject) return null;
                    break :blk switch (self.syntax().bare_dash.interpretation) {
                        .from_keyword => if (self.kind == .digraph) .edge_directed else .edge_undirected,
                    };
                },
            };
            self.tokens.resumeAfterFailure();
            return .{ .tag = tag, .span = d.span };
        }

        fn readOperator(self: *Self, token: lex.Token) syntax_event.EdgeOperator {
            const operator: syntax_event.EdgeOperator = if (token.tag == .edge_undirected) .undirected else .directed;
            if (operators_enabled and token.span.len != 2) {
                const bare = token.span.len == 1;
                self.acceptDeviation(if (bare) self.syntax().bare_dash.acceptance else self.syntax().long_operator, .{
                    .code = .syntax_operator_accepted,
                    .span = token.span,
                    .details = .{ .accepted_operator = .{
                        .operator = if (operator == .directed) .directed else .undirected,
                        .reason = if (bare) .from_keyword else .long_shape,
                    } },
                    .fix = .{
                        .span = token.span,
                        .edit = .{ .replace = if (operator == .directed) .directed_operator else .undirected_operator },
                        .applicability = .machine_applicable,
                    },
                });
            }
            return operator;
        }

        pub fn runToCompletion(self: *Self) Result {
            self.tokens.setNumeralCheck(self.numeralSeverity() != .off);
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
                .failure => blk: {
                    const d = self.tokens.failureDiagnostic();
                    break :blk self.operatorCandidate(d) orelse return self.fail(d);
                },
            };
            if (self.forwardWarning()) return self.terminal;
            return self.transition(token);
        }

        fn numeralSeverity(self: *const Self) policy.RuleSeverity {
            return if (fixed) |value| value.ambiguous_numeral else self.settings.ambiguous_numeral;
        }

        /// True when the token was rejected. Error policy participates in the
        /// ordinary failure/recovery lifecycle, not just presentation severity.
        fn forwardWarning(self: *Self) bool {
            if (self.tokens.takeWarning()) |finding| {
                switch (self.numeralSeverity()) {
                    .warning => self.warn(finding),
                    .off => unreachable, // scanner did not run this check
                    .err => {
                        var failure = finding;
                        failure.code = .syntax_ambiguous_numeral_rejected;
                        _ = self.fail(failure);
                        return true;
                    },
                }
            }
            return false;
        }

        /// Private bounded driver. A credit buys a lexical examination, one
        /// grammar transition, or one normal event attempt; never two classes.
        pub fn advance(self: *Self, budget: usize) Progress {
            if (!metered) @compileError("advance requires metering; use runToCompletion");
            return self.progress(self.drive(true, budget));
        }

        fn drive(self: *Self, comptime bounded: bool, budget: usize) usize {
            if (self.terminal != null) return 0;
            self.tokens.setNumeralCheck(self.numeralSeverity() != .off);
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
                            self.tokens.drive(true, 1)
                        else
                            self.tokens.nextBounded(remaining);
                        if (bounded) remaining -= scanned.work_used;
                        if (scanned.result) |result| switch (result) {
                            .token => |token| {
                                if (self.forwardWarning()) {
                                    if (self.terminal != null) break;
                                    continue;
                                }
                                self.work.token = token;
                                self.work.phase = .grammar;
                            },
                            .failure => {
                                const d = self.tokens.failureDiagnostic();
                                if (self.operatorCandidate(d)) |token| {
                                    self.work.token = token;
                                    self.work.phase = .grammar;
                                } else _ = self.fail(d);
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
            // Syntax errors already reported during recovery are the
            // truthful outcome; cancellation only ends the search for more.
            const outcome: Outcome = if (self.recovered()) .invalid_syntax else .cancelled;
            self.abortEvents(.cancelled);
            return self.finish(outcome);
        }

        /// The sink's one terminal abort, if it has begun and not yet
        /// received one.
        fn abortEvents(self: *Self, reason: syntax_event.AbortReason) void {
            if (self.begun and !self.aborted) self.events.abortDocument(reason);
            self.aborted = self.aborted or self.begun;
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
                    .subgraph_name => switch (token.tag) {
                        .identifier => {
                            self.subgraph_name = token.span;
                            self.state = .subgraph_open;
                        },
                        .left_brace => return self.beginSubgraphBody(token),
                        else => return self.unexpected(.{ .identifier = true, .left_brace = true }, .subgraph_header, token),
                    },
                    .subgraph_open => {
                        if (token.tag != .left_brace) return self.unexpected(.{ .left_brace = true }, .subgraph_header, token);
                        return self.beginSubgraphBody(token);
                    },
                    .after_subgraph => {
                        if (token.tag == .edge_directed or token.tag == .edge_undirected) {
                            self.operator = self.readOperator(token);
                            self.operator_span = token.span;
                            self.state = .edge_right;
                        } else if (token.tag == .colon or token.tag == .left_bracket) {
                            // `{ a }:n` / `{ a } [x=1]`: a rule violation the
                            // renderer can state, not merely an expected set.
                            var expected = statementEndExpected(false);
                            expected.undirected_operator = true;
                            expected.directed_operator = true;
                            return self.unexpected(expected, .subgraph_suffix, token);
                        } else {
                            self.state = .completed;
                            if (self.dispatchThenReplay(.subgraph_statement, token)) |result| return result;
                            if (!metered and !cancellable) return self.continueAfterStatement(token);
                            return null;
                        }
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
                            self.operator = self.readOperator(token);
                            self.operator_span = token.span;
                            self.state = .edge_right;
                        },
                        else => return self.finishPending(token, nodeEndExpected(self.left_port == null), .statement),
                    },
                    .edge_right => switch (token.tag) {
                        .identifier => {
                            self.right = token.span;
                            self.right_port = null;
                            self.right_scope = null;
                            self.pending = .edge;
                            self.state = .edge_terminate;
                        },
                        .left_brace, .keyword_subgraph => return self.startSubgraph(token, .right),
                        else => return self.unexpected(.{ .identifier = true, .left_brace = true, .subgraph_keyword = true }, .edge_endpoint, token),
                    },
                    .edge_terminate => switch (token.tag) {
                        .colon => {
                            if (self.pending != .edge or self.right_port != null or self.right_scope != null)
                                return self.unexpected(edgeEndExpected(false), .statement_terminator, token);
                            self.startPort(.right, .edge_terminate, token.span);
                        },
                        .left_bracket => self.openAttributes(token),
                        .edge_undirected, .edge_directed => {
                            self.link_operator = self.readOperator(token);
                            self.link_operator_span = token.span;
                            self.state = .chain_right;
                        },
                        else => {
                            return self.finishPending(token, edgeEndExpected(self.pending == .edge and self.right_port == null and self.right_scope == null), .statement_terminator);
                        },
                    },
                    .chain_right => switch (token.tag) {
                        .identifier => {
                            self.pending = .edge_chain;
                            self.link_right = token.span;
                            self.link_port = null;
                            self.state = .chain_after_identifier;
                        },
                        .left_brace, .keyword_subgraph => return self.startSubgraph(token, .link),
                        else => return self.unexpected(.{ .identifier = true, .left_brace = true, .subgraph_keyword = true }, .edge_endpoint, token),
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
                    .recovering => return self.recover(token),
                }
                return null;
            }
        }

        /// One token of resynchronization: a `;` at the current depth or a
        /// `}` ends the skip; a skipped `{` is matched by counting so the
        /// scope stack stays honest. Reaching end of input ends the parse.
        fn recover(self: *Self, token: lex.Token) ?Result {
            if (!recovery_enabled) unreachable;
            switch (token.tag) {
                .semicolon => if (self.skip_depth == 0) {
                    self.state = .statement;
                },
                .left_brace => self.skip_depth += 1,
                .right_brace => {
                    if (self.skip_depth > 0) {
                        self.skip_depth -= 1;
                    } else if (self.nestingDepth() == 0) {
                        self.state = .epilogue;
                    } else {
                        const stack = self.scratch.?;
                        self.leaveScope(stack.pop());
                        self.state = .statement;
                    }
                },
                .eof => return self.finish(.invalid_syntax),
                else => {},
            }
            return null;
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
            if (self.statements == self.limit("max_statements")) {
                return self.fail(.{
                    .code = .resource_capacity_exhausted,
                    .span = token.span,
                    .details = .{ .capacity = .{
                        .resource = .statements,
                        .limit = self.limit("max_statements"),
                    } },
                });
            }
            self.statements += 1;
            self.left = token.span;
            self.left_port = null;
            self.left_scope = null;
            self.right_scope = null;
            self.pending = .node;
            self.state = .after_identifier;
            return null;
        }

        fn beginNext(self: *Self, token: lex.Token) ?Result {
            if (deviations_enabled and token.tag == .semicolon and self.syntax().empty_statement != .reject) {
                self.acceptDeviation(self.syntax().empty_statement, .{
                    .code = .syntax_empty_statement,
                    .span = token.span,
                    .fix = .{ .span = token.span, .edit = .delete, .applicability = .machine_applicable },
                });
                self.state = .statement;
                return null;
            }
            switch (token.tag) {
                .identifier => return self.beginStatement(token),
                .right_brace => {
                    if (self.nestingDepth() == 0) {
                        self.state = .epilogue;
                    } else {
                        self.state = .after_subgraph;
                        return self.schedule(.end_subgraph, token);
                    }
                },
                .left_brace, .keyword_subgraph => {
                    if (self.beginStatement(token)) |result| return result;
                    return self.startSubgraph(token, .left);
                },
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

        fn nestingDepth(self: *const Self) usize {
            return if (self.scratch) |scratch| scratch.len else 0;
        }

        fn firstEdge(self: *const Self) syntax_event.EdgeStatement {
            return .{ .left = self.left, .left_port = self.left_port, .left_scope = self.left_scope, .operator = self.operator, .operator_span = self.operator_span, .right = self.right, .right_port = self.right_port, .right_scope = self.right_scope };
        }

        fn startSubgraph(self: *Self, token: lex.Token, role: syntax_event.ScopeRole) ?Result {
            self.subgraph_role = role;
            self.subgraph_start = token.span;
            self.subgraph_name = null;
            if (token.tag == .left_brace) return self.beginSubgraphBody(token);
            self.state = .subgraph_name;
            return null;
        }

        fn beginSubgraphBody(self: *Self, token: lex.Token) ?Result {
            if (self.nestingDepth() == self.limit("max_nesting")) return self.fail(.{
                .code = .resource_capacity_exhausted,
                .span = token.span,
                .details = .{ .capacity = .{ .resource = .nesting_depth, .limit = self.limit("max_nesting") } },
            });
            const scratch = self.scratch orelse return self.scratchFailure(error.NestingStorageExhausted, token.span);
            scratch.push(.{
                .parent_open = self.open_brace_span.?,
                .start = self.subgraph_start,
                .role = self.subgraph_role,
                .edge = if (self.subgraph_role == .left) null else if (self.subgraph_role == .link) self.firstEdge() else .{
                    .left = self.left,
                    .left_port = self.left_port,
                    .left_scope = self.left_scope,
                    .operator = self.operator,
                    .operator_span = self.operator_span,
                    .right = self.left,
                },
                .link_operator = if (self.subgraph_role == .link) self.link_operator else null,
                .link_operator_span = if (self.subgraph_role == .link) self.link_operator_span else null,
            }) catch |err| return self.scratchFailure(err, token.span);
            self.open_brace_span = token.span;
            self.state = .statement;
            return self.schedule(.begin_subgraph, token);
        }

        fn scratchFailure(self: *Self, err: scratch_impl.Stack.Error, span: location.Span) Result {
            self.diagnostics.emit(.{
                .code = if (err == error.OutOfMemory) .resource_memory_exhausted else .resource_capacity_exhausted,
                .span = span,
                .details = if (err == error.OutOfMemory) .none else .{ .capacity = .{ .resource = .nesting_frames, .limit = if (self.scratch) |scratch| scratch.frames.len else 0 } },
            }) catch {
                self.delivery = .failed;
            };
            self.abortEvents(.scratch_failure);
            return self.finish(.{ .scratch_failure = err });
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
            if (self.attributes == self.limit("max_attributes")) return self.fail(.{
                .code = .resource_capacity_exhausted,
                .span = at,
                .details = .{ .capacity = .{ .resource = .attributes, .limit = self.limit("max_attributes") } },
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
            if (self.aborted) {
                // Recovery: the sink is terminal, so no event is attempted;
                // only the grammar's own scope and port bookkeeping continues.
                switch (action) {
                    .end_subgraph => {
                        const stack = self.scratch.?;
                        self.leaveScope(stack.pop());
                    },
                    .ported_reference => switch (self.port_target) {
                        .left => self.left_port = 0,
                        .right => self.right_port = 0,
                        .link => self.link_port = 0,
                    },
                    .commit => return self.finish(.invalid_syntax),
                    else => {},
                }
                return null;
            }
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
                .begin_subgraph => {
                    const stack = self.scratch.?;
                    const frame = &stack.frames[stack.len - 1];
                    frame.entry = self.events.beginSubgraph(.{
                        .start = frame.start,
                        .name = self.subgraph_name,
                        .role = frame.role,
                        .edge = frame.edge,
                        .link_operator = frame.link_operator,
                        .link_operator_span = frame.link_operator_span,
                    }) catch |err| return self.sinkFailure(err);
                },
                .end_subgraph => {
                    const stack = self.scratch.?;
                    const frame = stack.frames[stack.len - 1];
                    self.events.endSubgraph(.{ .close = token.span, .entry = frame.entry }) catch |err| return self.sinkFailure(err);
                    _ = stack.pop();
                    if (self.suspect_close == null) {
                        if (leadingIndent(self.tokens.source, token.span)) |close_indent| {
                            if (lineIndent(self.tokens.source, self.open_brace_span.?)) |open_indent| {
                                if (close_indent < open_indent) self.suspect_close = token.span;
                            }
                        }
                    }
                    self.completed_scope = frame.entry.id;
                    self.leaveScope(frame);
                },
                .subgraph_statement => self.events.subgraphStatement(self.completed_scope) catch |err| return self.sinkFailure(err),
                .node => self.events.nodeStatement(.{ .identifier = self.left, .port = self.left_port }) catch |err| return self.sinkFailure(err),
                .edge => self.events.edgeStatement(.{
                    .left = self.left,
                    .left_port = self.left_port,
                    .left_scope = self.left_scope,
                    .right_scope = self.right_scope,
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
                    .left_scope = self.left_scope,
                    .right_scope = self.right_scope,
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
                .node, .edge, .edge_chain, .attribute_statement, .subgraph_statement => self.work.completed_statements += 1,
                .assignment => {
                    self.work.completed_statements += 1;
                    self.work.completed_pairs += 1;
                },
                .attribute => self.work.completed_pairs += 1,
                .begin, .begin_subgraph, .end_subgraph, .commit, .edge_link, .ported_reference => {},
            };
            return null;
        }

        /// Restore the grammar state suspended when `frame`'s scope opened.
        /// Shared by the normal exit and the recovering (event-less) exit;
        /// `frame.entry` is only meaningful before the abort, so the scope
        /// id lives on `completed_scope`, set by the caller.
        fn leaveScope(self: *Self, frame: scratch_impl.Frame) void {
            self.open_brace_span = frame.parent_open;
            if (frame.role == .left) {
                self.left = frame.start;
                self.left_scope = if (self.aborted) 0 else frame.entry.id;
                self.left_port = null;
                self.pending = .node;
                self.state = .after_subgraph;
            } else {
                const edge = frame.edge.?;
                self.left = edge.left;
                self.left_port = edge.left_port;
                self.left_scope = edge.left_scope;
                self.right = edge.right;
                self.right_port = edge.right_port;
                self.right_scope = edge.right_scope;
                self.operator = edge.operator;
                self.operator_span = edge.operator_span;
                if (frame.role == .right) {
                    self.right = frame.start;
                    self.right_port = null;
                    self.right_scope = if (self.aborted) 0 else frame.entry.id;
                }
                self.pending = if (frame.role == .right) .edge else .edge_chain;
                self.state = .edge_terminate;
            }
        }

        fn finish(self: *Self, outcome: Outcome) Result {
            if (self.scratch) |scratch| scratch.len = 0;
            const result: Result = .{
                .outcome = outcome,
                .diagnostic_delivery = self.delivery,
                .accepted_deviations = self.acceptedDeviations(),
                .warnings = self.warnings,
            };
            self.terminal = result;
            if (metered or cancellable) self.work.phase = .terminal;
            return result;
        }

        /// Report a failure diagnostic through the caller's sink, honoring
        /// the event lifecycle: abort follows begin; nothing is emitted
        /// before a supported header. Returns null when the parse continues
        /// in recovery (the caller resynchronizes), else the terminal result.
        fn fail(self: *Self, failure: diagnostic.Diagnostic) ?Result {
            var d = failure;
            if (d.fix == null) d.fix = self.lexicalFix(d);
            // A failing diagnostic sink must not mask the parse outcome;
            // the loss is surfaced via `Result.diagnostic_delivery`.
            self.diagnostics.emit(d) catch {
                self.delivery = .failed;
            };
            const reason: syntax_event.AbortReason = switch (failure.code) {
                .profile_unsupported_feature => .unsupported_feature,
                .resource_capacity_exhausted => .resource_exhausted,
                else => .invalid_syntax,
            };
            if (recovery_enabled and reason == .invalid_syntax and self.canRecover(failure)) {
                self.abortEvents(.invalid_syntax);
                if (self.tokens.terminal != .none) self.tokens.resumeAfterFailure();
                self.state = .recovering;
                self.skip_depth = 0;
                return null;
            }
            // A limit or deferred feature met while recovering does not
            // change what the document is: still invalid syntax.
            const outcome: Outcome = if (self.recovered()) .invalid_syntax else switch (reason) {
                .invalid_syntax => .invalid_syntax,
                .unsupported_feature => .unsupported_feature,
                .resource_exhausted => .resource_exhausted,
                // `fail` only handles diagnostic-classified failures; event
                // sink failures route through `sinkFailure` exclusively.
                .sink_failure, .scratch_failure, .cancelled => unreachable,
            };
            self.abortEvents(reason);
            return self.finish(outcome);
        }

        /// Repairs for scanner failures that need what only the parser
        /// knows: the document kind and the surrounding text.
        fn lexicalFix(self: *const Self, d: diagnostic.Diagnostic) ?diagnostic.Fix {
            switch (d.details) {
                .invalid_operator => |operator| {
                    // A lone '-' becomes the operator the document kind
                    // needs; the scanner already repaired the other shapes.
                    if (operator.shape != .lone or !self.kindKnown()) return null;
                    return .{ .span = d.span, .edit = .{ .replace = self.kindOperator() }, .applicability = .machine_applicable };
                },
                .invalid_byte => |byte| {
                    // `=>`: an arrow spelled with '='. The parser has just
                    // taken the '=' as an assignment, so the two bytes are
                    // adjacent on one line.
                    const offset = d.span.start;
                    if (byte != '>' or offset == 0 or self.tokens.source[offset - 1] != '=' or !self.kindKnown()) return null;
                    var span = d.span;
                    span.start -= 1;
                    span.len = 2;
                    return .{ .span = span, .edit = .{ .replace = self.kindOperator() }, .applicability = .maybe };
                },
                .unterminated => |construct| {
                    // Closing at end of input; the intended position is
                    // unknown, so it is only an offer.
                    const end: location.Span = .{ .start = @intCast(self.tokens.source.len), .len = 0 };
                    return .{
                        .span = end,
                        .edit = .{ .insert_before = switch (construct) {
                            .quoted_identifier => .double_quote,
                            .block_comment => .comment_close,
                        } },
                        .applicability = .maybe,
                    };
                },
                else => return null,
            }
        }

        /// True once the header has said which kind the document is.
        fn kindKnown(self: *const Self) bool {
            return self.state != .prologue and self.state != .kind_keyword;
        }

        fn kindOperator(self: *const Self) diagnostic.Replacement {
            return if (self.kind == .digraph) .directed_operator else .undirected_operator;
        }

        /// True once a syntax error has been recovered from: the sink was
        /// aborted while the grammar kept running.
        fn recovered(self: *const Self) bool {
            return self.aborted and self.terminal == null and self.begun;
        }

        /// Recovery is a body-only policy: a header has no statement
        /// boundary to return to, trailing tokens have nothing left to
        /// parse, and end of input is already the end.
        fn canRecover(self: *const Self, failure: diagnostic.Diagnostic) bool {
            if (self.recovery() != .statements or !self.begun) return false;
            if (self.state == .epilogue) return false;
            if (failure.details == .unexpected and failure.details.unexpected.found == .end_of_input) return false;
            if (self.tokens.terminal != .none) return switch (self.tokens.terminal) {
                .html, .oversize, .none, .eof => false,
                else => true,
            };
            return true;
        }

        fn sinkFailure(self: *Self, err: anyerror) Result {
            // The event sink failed mid-lifecycle; abort so it can release
            // staged state. `abortDocument` is infallible by contract.
            self.abortEvents(.sink_failure);
            return self.finish(.{ .sink_failure = err });
        }

        fn unexpected(
            self: *Self,
            expected: std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false),
            context: diagnostic.ParseContext,
            token: lex.Token,
        ) ?Result {
            if (self.fail(self.unexpectedDiagnostic(expected, context, token))) |result| return result;
            // Recovering: the offending token itself may be the boundary.
            return self.recover(token);
        }

        fn unexpectedDiagnostic(
            self: *Self,
            expected: std.enums.EnumFieldStruct(diagnostic.SyntaxItem, bool, false),
            context: diagnostic.ParseContext,
            token: lex.Token,
        ) diagnostic.Diagnostic {
            const found = tokenItem(token.tag);
            const expected_set = diagnostic.ExpectedSet.init(expected);
            // A keyword where a name was needed is its own condition: the
            // word is legal DOT, just reserved, and the fix is to quote it.
            // Positions that legitimately accept a keyword list it in
            // `expected`, so this never fires for them.
            if (keywordOf(found)) |keyword| {
                // `digraph strict {` is a misplaced modifier, not a name.
                const misplaced_strict = context == .document_header and found == .strict_keyword;
                if (expected_set.contains(.identifier) and !expected_set.contains(found) and !misplaced_strict) {
                    return .{
                        .code = .syntax_reserved_keyword,
                        .span = token.span,
                        .details = .{ .reserved_keyword = .{ .keyword = keyword, .context = context } },
                        .fix = .{ .span = token.span, .edit = .wrap_in_quotes, .applicability = .machine_applicable },
                    };
                }
            }
            // `node;`, `edge = red`: an attribute keyword without its list.
            // The keyword is the likely mistake (a node named `node`), so
            // the diagnostic marks it rather than the token after it.
            if (self.state == .attribute_open) {
                return .{
                    .code = .syntax_reserved_keyword,
                    .span = self.left,
                    .details = .{ .reserved_keyword = .{
                        .keyword = switch (self.attribute_target) {
                            .graph => .graph,
                            .node => .node,
                            .edge => .edge,
                        },
                        .context = .attribute_list,
                    } },
                };
            }
            const at_end = found == .end_of_input;
            const missing_port = self.state == .port_first or self.state == .port_second;
            // The delimiter this failure traces back to (typed relation;
            // renderers word it). An open `[` list is worth showing when
            // the token found cannot belong to a list — `a [color=red; }`
            // fails on the `}` one token after the omission — but not for
            // a mistake inside a list. A scope's `{` is only informative
            // at end of input.
            const related: ?diagnostic.Related = if (at_end and missing_port)
                .{ .span = self.port_colon, .role = .suffix_started_here }
            else if (self.open_bracket_span != null and (at_end or !listToken(found)))
                .{ .span = self.open_bracket_span.?, .role = .opened_here }
            else if (at_end)
                (if (self.open_brace_span) |span| .{ .span = span, .role = .opened_here } else null)
            else
                null;
            const suspect: ?diagnostic.Related = if (at_end and !missing_port and self.open_bracket_span == null)
                (if (self.suspect_close) |span| .{ .span = span, .role = .misindented_close } else null)
            else
                null;
            return .{
                .code = if (at_end) .syntax_unexpected_end else .syntax_unexpected_token,
                .span = token.span,
                .details = .{ .unexpected = .{
                    .expected = expected_set,
                    .found = found,
                    .context = context,
                    .related = related,
                    .suspect = suspect,
                } },
                .fix = self.unexpectedFix(context, found, expected_set, token, related, suspect),
            };
        }

        /// The repair for an unexpected token, when one is known. Machine-
        /// applicable only where the edit is the single reading of the
        /// mistake; a plausible repair among several is `maybe`.
        fn unexpectedFix(
            self: *const Self,
            context: diagnostic.ParseContext,
            found: diagnostic.SyntaxItem,
            expected: diagnostic.ExpectedSet,
            token: lex.Token,
            related: ?diagnostic.Related,
            suspect: ?diagnostic.Related,
        ) ?diagnostic.Fix {
            const here = token.span;
            const machine: diagnostic.Applicability = .machine_applicable;
            const maybe: diagnostic.Applicability = .maybe;
            if (found == .end_of_input) {
                // Close what is open. A missing ']' has one place to go;
                // a missing '}' too, unless a misindented brace suggests
                // the omission is somewhere above.
                const opener = related orelse return null;
                if (opener.role != .opened_here) return null;
                if (self.open_bracket_span != null) {
                    return .{ .span = here, .edit = .{ .insert_before = .right_bracket }, .applicability = machine };
                }
                return .{ .span = here, .edit = .{ .insert_before = .right_brace }, .applicability = if (suspect == null) machine else maybe };
            }
            return switch (context) {
                .document_body => switch (found) {
                    .semicolon => .{ .span = here, .edit = .delete, .applicability = machine },
                    else => null,
                },
                .document_epilogue => switch (found) {
                    .right_brace => .{ .span = here, .edit = .delete, .applicability = machine },
                    else => null,
                },
                .statement => switch (found) {
                    .comma => .{ .span = here, .edit = .{ .replace = .semicolon }, .applicability = maybe },
                    else => null,
                },
                .edge_endpoint => switch (found) {
                    .undirected_operator, .directed_operator => .{ .span = here, .edit = .delete, .applicability = machine },
                    else => null,
                },
                .attribute_key => switch (found) {
                    .comma, .semicolon => .{ .span = here, .edit = .delete, .applicability = machine },
                    .identifier => .{ .span = self.attribute_key, .edit = .{ .insert_after = .equals }, .applicability = maybe },
                    else => if (listToken(found)) null else .{ .span = here, .edit = .{ .insert_before = .right_bracket }, .applicability = maybe },
                },
                .attribute_list => if (listToken(found)) null else .{ .span = here, .edit = .{ .insert_before = .right_bracket }, .applicability = maybe },
                .port_component => switch (found) {
                    .colon => .{ .span = here, .edit = .delete, .applicability = maybe },
                    else => null,
                },
                .document_header => switch (found) {
                    .identifier => if (expected.contains(.digraph_keyword))
                        (if (headerKeywordSuggestion(here.slice(self.tokens.source))) |keyword|
                            diagnostic.Fix{ .span = here, .edit = .{ .replace = keyword }, .applicability = maybe }
                        else
                            null)
                    else if (expected.contains(.left_brace) and !expected.contains(.identifier))
                        .{ .span = here, .edit = .{ .insert_before = .left_brace }, .applicability = maybe }
                    else
                        null,
                    else => null,
                },
                else => null,
            };
        }

        fn unsupportedAt(self: *Self, span: location.Span, feature: diagnostic.Feature) ?Result {
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

/// A header keyword within edit distance two of `text`, for the "did you
/// mean" repair. Conservative on purpose: short or very different text
/// gets no guess, and only the keywords legal in a header are candidates.
fn headerKeywordSuggestion(text: []const u8) ?diagnostic.Replacement {
    if (text.len < 3 or text.len > 12) return null;
    var lowered: [12]u8 = undefined;
    for (text, 0..) |byte, i| lowered[i] = std.ascii.toLower(byte);
    const candidate = lowered[0..text.len];
    var best: ?diagnostic.Replacement = null;
    var best_distance: usize = 3;
    for ([_]diagnostic.Replacement{ .graph_keyword, .digraph_keyword, .strict_keyword }) |keyword| {
        const distance = editDistance(candidate, keyword.text());
        if (distance < best_distance) {
            best_distance = distance;
            best = keyword;
        }
    }
    return best;
}

/// Levenshtein distance over two short ASCII strings (both at most 12 bytes).
fn editDistance(a: []const u8, b: []const u8) usize {
    var previous: [13]usize = undefined;
    var current: [13]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |byte_a, i| {
        current[0] = i + 1;
        for (b, 0..) |byte_b, j| {
            const substitution = previous[j] + @intFromBool(byte_a != byte_b);
            current[j + 1] = @min(@min(previous[j + 1] + 1, current[j] + 1), substitution);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// Tokens that can appear inside an attribute list.
fn listToken(item: diagnostic.SyntaxItem) bool {
    return switch (item) {
        .identifier, .comma, .semicolon, .equals, .right_bracket => true,
        else => false,
    };
}

fn keywordOf(item: diagnostic.SyntaxItem) ?diagnostic.Keyword {
    return switch (item) {
        .graph_keyword => .graph,
        .digraph_keyword => .digraph,
        .strict_keyword => .strict,
        .subgraph_keyword => .subgraph,
        .node_keyword => .node,
        .edge_keyword => .edge,
        else => null,
    };
}

/// Longest line prefix the indentation heuristic will inspect. A `}` (or an
/// opener) further into its line than this is not "indented", and bounding
/// the scan keeps every scope exit a constant-cost step (R-PERF-001).
const max_indent_scan = 128;

/// The indentation of `span`'s line when `span` is the first non-blank
/// text on it: the number of leading spaces and tabs. Null otherwise.
fn leadingIndent(source: []const u8, span: location.Span) ?usize {
    // Walk back from the span: the first non-blank byte settles it at once,
    // so a brace deep inside a dense line costs one byte read, and only a
    // genuinely indented one pays for its indentation (bounded).
    var start: usize = span.start;
    while (start > 0) {
        const byte = source[start - 1];
        if (byte == '\n' or byte == '\r') break;
        if (byte != ' ' and byte != '\t') return null;
        if (span.start - start >= max_indent_scan) return null;
        start -= 1;
    }
    return span.start - start;
}

/// The offset where `offset`'s line begins, or null when that is more than
/// `max_indent_scan` bytes back. Same terminators as `location`: LF, CR.
fn lineStart(source: []const u8, offset: usize) ?usize {
    var start = offset;
    while (start > 0 and source[start - 1] != '\n' and source[start - 1] != '\r') {
        if (offset - start >= max_indent_scan) return null;
        start -= 1;
    }
    return start;
}

/// The indentation of `span`'s line (its first non-blank column), whatever
/// precedes `span` on that line. Null when the prefix exceeds the bound.
fn lineIndent(source: []const u8, span: location.Span) ?usize {
    const line_start = lineStart(source, span.start) orelse return null;
    var indent: usize = 0;
    for (source[line_start..span.start]) |byte| {
        if (byte != ' ' and byte != '\t') break;
        indent += 1;
    }
    return indent;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Shared unit-test driver for event-sink assertions, using the current machine
/// and resolved policy schema. It is not present in consumer builds.
pub const testing = if (@import("builtin").is_test) struct {
    pub fn run(source: []const u8, events: anytype, diagnostics: diagnostic.Sink, settings: policy.ParseSettings, scratch: ?*scratch_impl.Stack) Result {
        var machine: Machine(@TypeOf(events), false, false, false, scalar_lex.Scanner, null) = .{
            .tokens = scalar_lex.Scanner(false, false, null).init(source),
            .events = events,
            .diagnostics = diagnostics,
            .settings = settings,
            .scratch = scratch,
        };
        return machine.runToCompletion();
    }
} else struct {};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Recording = syntax_event.RecordingSink(16);
const Bag = diagnostic.FixedBag(4);

test "chain dispatch failures preserve budget accounting and terminal cleanup" {
    const source = "digraph {a->b->c->d[x=1] z->q->r}";
    const total = try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, .{}, null, false);
    try expectEqual(total, try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 3, 17 }, .{}, null, false));
    // begin, two links, attribute, owner, link, owner, commit.
    for (0..8) |at| _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 1, 5 }, .{}, at, false);
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
        var machine: Machine(*BudgetSink, true, true, true, scalar_lex.Scanner, null) = .{
            .tokens = scalar_lex.Scanner(true, true, null).init(source),
            .events = &events,
            .diagnostics = diags.sink(),

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
    const Scanner = scalar_lex.Scanner(true, true, null);
    const State = @FieldType(Scanner, "state");
    var states = std.EnumSet(State).initEmpty();
    var phases = std.EnumSet(Phase).initEmpty();
    const sources = [_][]const u8{
        " \r\n#x\r//y\n/*z**/graph {a;}",
        "graph {a\xff;}",
        "graph {-1.2 -.5 .1 1->2 3--4 5-->6}",
        "graph {7 - > 8}",
        "graph {\"a\\\"b\" /*glue*/ + \"c\" [x=y] }",
    };
    for (sources) |source| for (0..source.len * 4 + 16) |budget| {
        var request: CancellationProbe = .{};
        var events: BudgetSink = .{};
        var machine: Machine(*BudgetSink, true, true, true, scalar_lex.Scanner, null) = .{
            .tokens = Scanner.init(source),
            .events = &events,
            .diagnostics = diagnostic.discard,

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
    var machine: Machine(*BudgetSink, true, true, true, scalar_lex.Scanner, null) = .{
        .tokens = scalar_lex.Scanner(true, true, null).init("graph {a[x=]}"),
        .events = &events,
        .diagnostics = .{ .context = &reporter, .emit_fn = Reporter.emit },

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
    pub fn beginSubgraph(self: *@This(), event: syntax_event.BeginSubgraph) !syntax_event.ScopeEntry {
        try self.record(.{ .begin_subgraph = event });
        return .{ .id = @intCast(self.len) };
    }
    pub fn subgraphStatement(self: *@This(), id: u32) !void {
        try self.record(.{ .subgraph_statement = id });
        self.statements += 1;
    }
    pub fn endSubgraph(self: *@This(), event: syntax_event.EndSubgraph) !void {
        try self.record(.{ .end_subgraph = event });
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
    /// Warnings ride along with tokens mid-parse; failures are terminal.
    warnings: usize = 0,
    reject: bool = false,
    fn sink(self: *@This()) diagnostic.Sink {
        return .{ .context = self, .emit_fn = emit };
    }
    fn failures(self: *const @This()) usize {
        return self.attempts - self.warnings;
    }
    fn emit(context: ?*anyopaque, item: diagnostic.Diagnostic) diagnostic.SinkError!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.attempts += 1;
        if (item.code.severity() == .warning) self.warnings += 1;
        if (self.reject) return error.DiagnosticSinkFailure;
        try self.bag.sink().emit(item);
    }
};

fn checkBudgetPartition(comptime ScannerOf: fn (comptime bool, comptime bool, comptime ?bool) type, source: []const u8, budgets: []const usize, settings: policy.ParseSettings, fail_at: ?usize, reject: bool) !usize {
    var reference_frames: scratch_impl.Fixed(.{ .nesting = 32 }) = .{};
    var frames: scratch_impl.Fixed(.{ .nesting = 32 }) = .{};
    var reference_stack: scratch_impl.Stack = .{ .frames = reference_frames.storage().frames };
    var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };
    var reference: BudgetSink = .{ .fail_at = fail_at };
    var reference_diags: BudgetDiagnostics = .{ .reject = reject };
    const expected = testing.run(source, &reference, reference_diags.sink(), settings, &reference_stack);
    var events: BudgetSink = .{ .fail_at = fail_at };
    var diags: BudgetDiagnostics = .{ .reject = reject };
    var machine: Machine(*BudgetSink, true, true, false, ScannerOf, null) = .{
        .tokens = ScannerOf(true, true, null).init(source),
        .events = &events,
        .diagnostics = diags.sink(),
        .settings = settings,
        .scratch = &stack,
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
        const diagnostics = diags.failures();
        const before = machine.progress(0);
        const progress = machine.advance(budget);
        const examined = machine.tokens.examinations - reads;
        try expectEqual(progress.work_used, examined + (machine.audit.grammar - grammar) + (machine.audit.dispatch - dispatch));
        // After a recovered failure, dispatches keep the grammar's own
        // bookkeeping without attempting events, and several failures can
        // fall inside one budget; the end-state comparisons below still hold.
        const recovering = settings.recovery == .statements;
        if (!recovering) try expectEqual(machine.audit.dispatch - dispatch, events.attempts - attempts);
        try expect(progress.work_used <= budget);
        try expect(examined <= progress.work_used);
        try expect(progress.source_frontier >= frontier);
        try expect(progress.source_frontier <= source.len);
        try expectEqual(events.statements, progress.completed_statements);
        try expectEqual(events.pairs, progress.completed_pairs);
        if (budget == 0) try std.testing.expectEqualDeep(before, progress);
        if (progress.result == null) {
            if (!recovering) try expectEqual(aborts, events.aborts);
            if (!recovering) try expectEqual(diagnostics, diags.failures());
            if (budget != 0) try expect(progress.work_used != 0);
        } else {
            try expect(events.aborts - aborts <= 1);
            if (!recovering) try expect(diags.failures() - diagnostics <= 1);
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

test "numeral policy is partition invariant including failure and recovery" {
    inline for (.{ scalar_lex.Scanner, block_lex.Scanner }) |ScannerOf| {
        for ([_]policy.RuleSeverity{ .err, .warning, .off }) |severity| {
            for ([_]policy.Recovery{ .fail_fast, .statements }) |recovery_mode| {
                const settings: policy.ParseSettings = .{ .ambiguous_numeral = severity, .recovery = recovery_mode };
                const source = "graph { 1e3; { 1.2.3; a } 2z; }";
                const total = try checkBudgetPartition(ScannerOf, source, &.{1}, settings, null, false);
                try expectEqual(total, try checkBudgetPartition(ScannerOf, source, &.{ 0, 3, 17 }, settings, null, false));
                _ = try checkBudgetPartition(ScannerOf, source, &.{ 0, 1, 5 }, settings, null, true);
                for (0..source.len + 1) |end| _ = try checkBudgetPartition(ScannerOf, source[0..end], &.{ 0, 1, 3 }, settings, null, false);
                for (0..4) |at| _ = try checkBudgetPartition(ScannerOf, source, &.{ 0, 1, 5 }, settings, at, false);
            }
        }
    }
}

test "lenient syntax partitions preserve events counters diagnostics and charged work" {
    const settings = policy.resolve(policy.defaults, policy.presets.lenient).parsing;
    const source = "graph { ; { ; a:p:e --- b:q - c:r } - { d } --- e -- f; ; }";
    inline for (.{ scalar_lex.Scanner, block_lex.Scanner }) |ScannerOf| {
        const total = try checkBudgetPartition(ScannerOf, source, &.{1}, settings, null, false);
        try expectEqual(total, try checkBudgetPartition(ScannerOf, source, &.{ 0, 3, 17 }, settings, null, false));
        _ = try checkBudgetPartition(ScannerOf, source, &.{ 0, 1, 5 }, settings, null, true);
        // Every prefix terminates identically, including incomplete operators,
        // ports, subgraphs, and right endpoints after an accepted deviation.
        for (0..source.len + 1) |end|
            _ = try checkBudgetPartition(ScannerOf, source[0..end], &.{ 0, 1, 3 }, settings, null, false);
        var events: BudgetSink = .{};
        var frames: scratch_impl.Fixed(.{ .nesting = 32 }) = .{};
        var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };
        try expect(testing.run(source, &events, diagnostic.discard, settings, &stack).outcome == .success);
        for (0..events.attempts) |index|
            _ = try checkBudgetPartition(ScannerOf, source, &.{ 0, 1, 5 }, settings, index, false);
        var recovering = settings;
        recovering.recovery = .statements;
        _ = try checkBudgetPartition(ScannerOf, "graph { ; a[x=]; ; b --- c; d - > e; ; }", &.{ 0, 1, 5 }, recovering, null, false);
    }
}

test "fixed standard syntax excludes acceptance storage and keeps scanner layout" {
    const Standard = Machine(*BudgetSink, false, false, false, scalar_lex.Scanner, policy.defaults.parsing);
    const Lenient = Machine(*BudgetSink, false, false, false, scalar_lex.Scanner, policy.resolve(policy.defaults, policy.presets.lenient).parsing);
    try expect(@FieldType(Standard, "deviations") == void);
    try expect(@FieldType(Lenient, "deviations") == u32);
    try expect(@FieldType(Standard, "tokens") == @FieldType(Lenient, "tokens"));
    try expect(@FieldType(Standard, "settings") == void);
    try expect(@FieldType(Lenient, "settings") == void);
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
        const total = try checkBudgetPartition(scalar_lex.Scanner, source, &.{std.math.maxInt(usize)}, .{}, null, false);
        try expectEqual(total, try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, .{}, null, false));
        try expectEqual(total, try checkBudgetPartition(scalar_lex.Scanner, source, &.{2}, .{}, null, false));
        try expectEqual(total, try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 1, 3, 0, 7, 2 }, .{}, null, false));
    }
}

test "metered parser every prefix and callback failure preserve lifecycle" {
    const source = "strict digraph \"g\" { a[x=1][y=2] node[] z=3 a->b[w=\"v\"+\"x\"] }";
    for (0..source.len + 1) |end| {
        _ = try checkBudgetPartition(scalar_lex.Scanner, source[0..end], &.{ 0, 1, 2 }, .{}, null, false);
    }
    // Includes failed begin, all payload variants, and failed commit.
    for (0..9) |index| {
        _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, .{}, index, false);
        _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 3, 7 }, .{}, index, false);
    }
    _ = try checkBudgetPartition(scalar_lex.Scanner, "graph {a[x=]}", &.{1}, .{}, null, true);
    _ = try checkBudgetPartition(scalar_lex.Scanner, "@", &.{1}, .{}, null, true);
}

test "ported reference callback failures preserve lifecycle and accounting" {
    const source = "digraph {a:p:e[x=1] a:q->b:r->c:s:w[k=v]}";
    var events: BudgetSink = .{};
    try expect(testing.run(source, &events, diagnostic.discard, .{}, null).outcome == .success);
    for (0..events.attempts) |index| {
        _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, .{}, index, false);
        _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 3, 7 }, .{}, index, false);
    }
}

test "metered parser capacities remain output limits not work budgets" {
    inline for (.{ 0, 1, 2 }) |limit| {
        _ = try checkBudgetPartition(scalar_lex.Scanner, "graph { a[x=1] b[y=2] c=z }", &.{1}, .{ .limits = .{ .max_statements = limit } }, null, false);
        _ = try checkBudgetPartition(scalar_lex.Scanner, "graph { a[x=1] b[y=2] c=z }", &.{ 0, 2, 9 }, .{ .limits = .{ .max_attributes = limit } }, null, false);
    }
}

test "metered parser yields before begin pair owner and commit dispatch" {
    var events: BudgetSink = .{};
    var machine: Machine(*BudgetSink, true, true, false, scalar_lex.Scanner, null) = .{
        .tokens = scalar_lex.Scanner(true, true, null).init("graph {a[x=1]}"),
        .events = &events,
        .diagnostics = diagnostic.discard,
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
        _ = try checkBudgetPartition(scalar_lex.Scanner, source[0 .. parts[0].len + n + parts[1].len], &.{1}, .{}, null, false);
    }
}

test "ordinary parser compiles out pending work and audit storage" {
    const Ordinary = Machine(*BudgetSink, false, false, false, scalar_lex.Scanner, null);
    try expect(@FieldType(Ordinary, "work") == void);
    try expect(@FieldType(Ordinary, "audit") == void);
    try expect(@FieldType(scalar_lex.Scanner(false, false, null), "source_frontier") == void);
    try expect(@sizeOf(Machine(*BudgetSink, false, false, false, scalar_lex.Scanner, null)) <= 512);
    try expect(@sizeOf(Machine(*BudgetSink, false, false, false, block_lex.Scanner, null)) <= 640);
}

test "unaudited metered driver charges empty document exactly and runs to completion" {
    var events: BudgetSink = .{};
    var machine: Machine(*BudgetSink, true, false, false, scalar_lex.Scanner, null) = .{
        .tokens = scalar_lex.Scanner(true, false, null).init("graph{}"),
        .events = &events,
        .diagnostics = diagnostic.discard,
    };
    // Nine examinations (including keyword lookahead and EOF), four grammar
    // transitions, begin and commit. Finishing syntax does not commit for free.
    const before_commit = machine.advance(14);
    try expect(before_commit.result == null);
    try expectEqual(Phase.dispatch, before_commit.phase);
    try expectEqual(@as(usize, 1), events.attempts);
    try expect(machine.runToCompletion().outcome == .success);
    try expectEqual(@as(usize, 2), events.attempts);
    try expectEqual(@as(usize, 15), try checkBudgetPartition(scalar_lex.Scanner, "graph{}", &.{1}, .{}, null, false));
}

test "metered parser deterministic arbitrary-byte inputs match immediate grammar" {
    var random = std.Random.DefaultPrng.init(0x627564676574);
    var bytes: [96]u8 = undefined;
    for (0..400) |_| {
        random.random().bytes(&bytes);
        const len = random.random().uintLessThan(usize, bytes.len + 1);
        _ = try checkBudgetPartition(scalar_lex.Scanner, bytes[0..len], &.{ 0, 1, 5 }, .{}, null, false);
        // A supported header also exercises arbitrary bytes inside the body.
        @memcpy(bytes[0..7], "graph {");
        _ = try checkBudgetPartition(scalar_lex.Scanner, bytes[0..@max(7, len)], &.{ 1, 2, 11 }, .{}, null, false);
    }
}

test "empty graph commits with begin and end only, empty bag" {
    inline for (.{ "graph { }", "graph{}", "GRAPH {\r\n}\n" }) |source| {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = testing.run(source, &events, bag.sink(), .{}, null);
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
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .success);

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
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .success);
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
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .success);

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
    _ = testing.run(source, &events, bag.sink(), .{}, null);
    const recorded = events.recorded();
    try expect(recorded.len >= 2);
    try expect(recorded[0] == .begin_document);
    try expect(recorded[recorded.len - 1] == .abort_document);
    try expectEqual(expected_reason, recorded[recorded.len - 1].abort_document);
}

const recovery_settings: policy.ParseSettings = .{ .recovery = .statements };

fn countCode(bag: anytype, code: diagnostic.Code) usize {
    var count: usize = 0;
    for (bag.items()) |d| {
        if (d.code == code) count += 1;
    }
    return count;
}

test "statement recovery reports every syntax error and aborts the sink once" {
    const source = "digraph { a -> ; b -> ; c [x=1 =]; e -- }";
    var events: Recording = .{};
    var bag: diagnostic.FixedBag(8) = .{};
    const result = testing.run(source, &events, bag.sink(), recovery_settings, null);
    try expect(result.outcome == .invalid_syntax);
    // `a -> ;`, `b -> ;`, the `=` after `x=1`, `e -- }`.
    try expectEqual(@as(usize, 4), bag.items().len);
    try expectEqualStrings(";", bag.items()[0].span.slice(source));
    try expectEqualStrings(";", bag.items()[1].span.slice(source));
    try expectEqualStrings("=", bag.items()[2].span.slice(source));
    try expectEqualStrings("}", bag.items()[3].span.slice(source));
    // One begin, one abort, nothing after the abort.
    const recorded = events.recorded();
    try expect(recorded[0] == .begin_document);
    try expect(recorded[recorded.len - 1] == .abort_document);
    var aborts: usize = 0;
    for (recorded) |event| {
        if (event == .abort_document) aborts += 1;
    }
    try expectEqual(@as(usize, 1), aborts);
    try expectEqual(@as(usize, 0), bag.omitted);
}

test "statement recovery resumes after lexical errors and through scopes" {
    var frames: scratch_impl.Fixed(.{ .nesting = 4 }) = .{};
    var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };

    const source = "digraph { a - b; c => d; subgraph s { e -> ; f } g -> ; h [k=v]; i -> { j -> ; k } }";
    var events: Recording = .{};
    var bag: diagnostic.FixedBag(8) = .{};
    try expect(testing.run(source, &events, bag.sink(), recovery_settings, &stack).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 1), countCode(&bag, .syntax_invalid_operator));
    try expectEqual(@as(usize, 1), countCode(&bag, .syntax_invalid_byte));
    try expectEqual(@as(usize, 3), countCode(&bag, .syntax_unexpected_token));
    try expectEqual(@as(usize, 5), bag.items().len);
    // Every scope was left again: no frames remain.
    try expectEqual(@as(usize, 0), stack.len);
    // The unterminated cases cannot resume: the rest of the input is the body.
    for ([_][]const u8{ "digraph { a -> ; b -> \"x; c -> d }", "digraph { a -> ; b /* c -> ; d }" }) |truncated| {
        var truncated_events: Recording = .{};
        var truncated_bag: Bag = .{};
        try expect(testing.run(truncated, &truncated_events, truncated_bag.sink(), recovery_settings, null).outcome == .invalid_syntax);
        try expectEqual(@as(usize, 2), truncated_bag.items().len);
        try expectEqual(diagnostic.Code.syntax_unterminated_construct, truncated_bag.items()[1].code);
    }
}

test "statement recovery stops where there is no boundary to return to" {
    // Header errors, end of input, trailing tokens, limits and deferred
    // features end the parse exactly as they do without recovery.
    inline for (.{
        .{ "graph graph { a -> ; b }", 1, Outcome.invalid_syntax },
        .{ "digraph { a -> ; subgraph { b", 2, Outcome.invalid_syntax },
        .{ "digraph { a -> ; } b c", 2, Outcome.invalid_syntax },
        .{ "digraph { a -> ; b [label=<x>]; c -> ; }", 2, Outcome.invalid_syntax },
    }) |case| {
        var frames: scratch_impl.Fixed(.{ .nesting = 4 }) = .{};
        var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };

        var events: Recording = .{};
        var bag: Bag = .{};
        try expectEqual(case[2], testing.run(case[0], &events, bag.sink(), recovery_settings, &stack).outcome);
        try expectEqual(@as(usize, case[1]), bag.items().len);
    }
    // A limit reached after a recovered error keeps the truthful outcome
    // but still reports the limit.
    var events: Recording = .{};
    var bag: Bag = .{};
    var limited = recovery_settings;
    limited.limits.max_statements = 2;
    try expect(testing.run("digraph { a -> ; b; c; d; }", &events, bag.sink(), limited, null).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 2), bag.items().len);
    try expectEqual(diagnostic.Code.resource_capacity_exhausted, bag.items()[1].code);
    // A full bag counts what it could not keep.
    var small: diagnostic.FixedBag(2) = .{};
    try expect(testing.run("digraph { a -> ; b -> ; c -> ; d -> ; }", &events, small.sink(), recovery_settings, null).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 2), small.items().len);
    try expectEqual(@as(usize, 2), small.omitted);
}

test "metered and cancellable drivers recover identically to the immediate one" {
    const source = "digraph { a - b; subgraph s { c -> ; d } e [x=1 f; g -> h -> ; i:p:q:r; j }";
    const total = try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, recovery_settings, null, false);
    try expectEqual(total, try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 3, 17 }, recovery_settings, null, false));
    _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 1, 5 }, recovery_settings, null, true);
    // Cancellation after a recovered error reports the errors, not a cancel.
    var request: CancellationProbe = .{};
    var events: BudgetSink = .{};
    var bag: Bag = .{};
    var frames: scratch_impl.Fixed(.{ .nesting = 4 }) = .{};
    var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };

    var machine: Machine(*BudgetSink, true, true, true, scalar_lex.Scanner, null) = .{
        .tokens = scalar_lex.Scanner(true, true, null).init(source),
        .events = &events,
        .diagnostics = bag.sink(),
        .settings = recovery_settings,
        .scratch = &stack,
        .cancellation = request.hook(),
    };
    while (bag.items().len == 0) _ = machine.advance(1);
    request.flag = true;
    const progress = machine.advance(1);
    try expect(progress.result.?.outcome == .invalid_syntax);
    try expectEqual(@as(usize, 1), events.aborts);
}

test "both scanner backends drive the grammar to identical events and diagnostics" {
    const sources = [_][]const u8{
        "graph { a -- b; }",
        "strict digraph named { a b; c->d; e--f }",
        "graph { a[x=1][y=2] node[] z=3 a--b[w=4] graph[k=v] edge[k=v] }",
        "#line\n/* pre */graph { \"a\" + /* gap */ \"b\"[x=\"v\\\"q\" y=-.5] // tail\r\n }",
        "digraph { a -> ; b - c; e --> f; 1e3; }",
        "digraph { a [color=red; }",
        "graph { a -- \"unterminated",
        "digraph { a:p:n -> b:q; c => d }",
    };
    inline for (.{ .fail_fast, .statements }) |recovery| {
        for (sources) |source| {
            errdefer std.debug.print("source: {s}\n", .{source});
            var scalar_events: Recording = .{};
            var scalar_bag: diagnostic.FixedBag(8) = .{};
            var scalar_machine: Machine(*Recording, false, false, false, scalar_lex.Scanner, null) = .{
                .tokens = scalar_lex.Scanner(false, false, null).init(source),
                .events = &scalar_events,
                .diagnostics = scalar_bag.sink(),
                .settings = .{ .recovery = recovery },
            };
            var block_events: Recording = .{};
            var block_bag: diagnostic.FixedBag(8) = .{};
            var block_machine: Machine(*Recording, false, false, false, block_lex.Scanner, null) = .{
                .tokens = block_lex.Scanner(false, false, null).init(source),
                .events = &block_events,
                .diagnostics = block_bag.sink(),
                .settings = .{ .recovery = recovery },
            };
            try std.testing.expectEqualDeep(scalar_machine.runToCompletion(), block_machine.runToCompletion());
            try std.testing.expectEqualDeep(scalar_events.recorded(), block_events.recorded());
            try std.testing.expectEqualDeep(scalar_bag.items(), block_bag.items());
        }
    }
}

test "fail-fast means the bag contains exactly one diagnostic" {
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = testing.run("graph { @ }", &events, bag.sink(), .{}, null);
    try expect(result.outcome == .invalid_syntax);

    try expectEqual(@as(usize, 1), bag.items().len);
    try expectEqual(diagnostic.Code.syntax_invalid_byte, bag.items()[0].code);

    try expectAborted("graph { @ }", .invalid_syntax);
}

test "missing opening brace reports the typed expected set and context" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run("graph ; }", &events, bag.sink(), .{}, null).outcome == .invalid_syntax);

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
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .invalid_syntax);

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
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .success);
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
    try expect(testing.run("graph { }", &events, bag.sink(), .{}, null).outcome == .success);
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
    const result = testing.run("graph graph { }", &events, bag.sink(), .{}, null);
    try expect(result.outcome == .invalid_syntax);

    // Reported as the condition it is — a reserved word where a name was
    // needed — rather than as an expected-token set.
    try expectEqual(diagnostic.Code.syntax_reserved_keyword, bag.items()[0].code);
    const reserved = bag.items()[0].details.reserved_keyword;
    try expectEqual(diagnostic.Keyword.graph, reserved.keyword);
    try expectEqual(diagnostic.ParseContext.document_header, reserved.context);
    try expectEqualStrings("graph", bag.items()[0].span.slice("graph graph { }"));
    try expectEqual(@as(usize, 0), events.recorded().len);
}

test "reserved keywords where a name was needed name the keyword and context" {
    inline for (.{
        .{ "graph { a -- node; }", diagnostic.Keyword.node, diagnostic.ParseContext.edge_endpoint, "node" },
        .{ "digraph { subgraph edge { } }", diagnostic.Keyword.edge, diagnostic.ParseContext.subgraph_header, "edge" },
        .{ "graph { a [node=1] }", diagnostic.Keyword.node, diagnostic.ParseContext.attribute_key, "node" },
        .{ "graph { a [x=graph] }", diagnostic.Keyword.graph, diagnostic.ParseContext.attribute_value, "graph" },
        .{ "graph { a:digraph }", diagnostic.Keyword.digraph, diagnostic.ParseContext.port_component, "digraph" },
        .{ "graph { x = strict }", diagnostic.Keyword.strict, diagnostic.ParseContext.assignment_value, "strict" },
        .{ "graph subgraph { }", diagnostic.Keyword.subgraph, diagnostic.ParseContext.document_header, "subgraph" },
        // An attribute keyword without its list marks the keyword itself.
        .{ "graph { node; }", diagnostic.Keyword.node, diagnostic.ParseContext.attribute_list, "node" },
        .{ "graph { edge = red; }", diagnostic.Keyword.edge, diagnostic.ParseContext.attribute_list, "edge" },
        .{ "digraph { graph }", diagnostic.Keyword.graph, diagnostic.ParseContext.attribute_list, "graph" },
        .{ "graph { node", diagnostic.Keyword.node, diagnostic.ParseContext.attribute_list, "node" },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(testing.run(case[0], &events, bag.sink(), .{}, null).outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.syntax_reserved_keyword, bag.items()[0].code);
        try expectEqual(case[1], bag.items()[0].details.reserved_keyword.keyword);
        try expectEqual(case[2], bag.items()[0].details.reserved_keyword.context);
        try expectEqualStrings(case[3], bag.items()[0].span.slice(case[0]));
    }
    // `digraph strict {` is a misplaced modifier, reported as a plain
    // unexpected token so the renderer can say where 'strict' goes.
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run("digraph strict { }", &events, bag.sink(), .{}, null).outcome == .invalid_syntax);
    try expectEqual(diagnostic.Code.syntax_unexpected_token, bag.items()[0].code);
    try expectEqual(diagnostic.SyntaxItem.strict_keyword, bag.items()[0].details.unexpected.found);
}

test "ports and attribute lists after a standalone subgraph get their own context" {
    inline for (.{ "graph { { a }:n -- b }", "graph { subgraph s { a } [x=1] }" }) |source| {
        var frames: scratch_impl.Fixed(.{ .nesting = 4 }) = .{};
        var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(testing.run(source, &events, bag.sink(), .{}, &stack).outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.syntax_unexpected_token, bag.items()[0].code);
        try expectEqual(diagnostic.ParseContext.subgraph_suffix, bag.items()[0].details.unexpected.context);
    }
}

test "an open attribute list is related even when the failure is not at end of input" {
    const source = "graph { a [color=red; }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .invalid_syntax);
    const unexpected = bag.items()[0].details.unexpected;
    try expectEqual(diagnostic.SyntaxItem.right_brace, unexpected.found);
    try expectEqualStrings("[", unexpected.related.?.span.slice(source));
    try expectEqual(diagnostic.Related.Role.opened_here, unexpected.related.?.role);
    // A scope's '{' is not dragged in for ordinary mid-body failures.
    var plain_events: Recording = .{};
    var plain_bag: Bag = .{};
    try expect(testing.run("graph { a -- ; }", &plain_events, plain_bag.sink(), .{}, null).outcome == .invalid_syntax);
    try expect(plain_bag.items()[0].details.unexpected.related == null);
}

test "a misindented closing brace is the suspect when the input ends inside a scope" {
    const source =
        \\digraph {
        \\  subgraph s {
        \\    a -> b;
        \\  b -> c;
        \\}
        \\
    ;
    var frames: scratch_impl.Fixed(.{ .nesting = 4 }) = .{};
    var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run(source, &events, bag.sink(), .{}, &stack).outcome == .invalid_syntax);
    try expectEqual(diagnostic.Code.syntax_unexpected_end, bag.items()[0].code);
    const unexpected = bag.items()[0].details.unexpected;
    // Brace matching still names the only open brace, the document's...
    try expectEqual(@as(usize, 1), unexpected.related.?.span.locate(source).line);
    // ...and the heuristic points at the '}' that closed the wrong scope.
    const suspect = unexpected.suspect.?;
    try expectEqual(diagnostic.Related.Role.misindented_close, suspect.role);
    try expectEqual(@as(usize, 5), suspect.span.locate(source).line);
    try expectEqualStrings("}", suspect.span.slice(source));

    // Consistent indentation raises no suspicion, even when a brace is missing.
    const tidy = "digraph {\n  subgraph s {\n    a -> b;\n  }\n  b -> c;\n";
    var tidy_stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };
    var tidy_events: Recording = .{};
    var tidy_bag: Bag = .{};
    try expect(testing.run(tidy, &tidy_events, tidy_bag.sink(), .{}, &tidy_stack).outcome == .invalid_syntax);
    try expect(tidy_bag.items()[0].details.unexpected.suspect == null);
}

test "diagnostics carry the one known repair, with honest applicability" {
    const Expect = struct {
        source: []const u8,
        text: []const u8,
        edit: std.meta.Tag(diagnostic.Edit),
        replacement: ?diagnostic.Replacement = null,
        applicability: diagnostic.Applicability = .machine_applicable,
    };
    inline for ([_]Expect{
        .{ .source = "digraph { a - b; }", .text = "-", .edit = .replace, .replacement = .directed_operator },
        .{ .source = "graph { a - b; }", .text = "-", .edit = .replace, .replacement = .undirected_operator },
        .{ .source = "graph { a - > b; }", .text = "- >", .edit = .replace, .replacement = .directed_operator },
        .{ .source = "digraph { a --> b; }", .text = "-->", .edit = .replace, .replacement = .directed_operator },
        .{ .source = "digraph { a => b; }", .text = "=>", .edit = .replace, .replacement = .directed_operator, .applicability = .maybe },
        .{ .source = "digraph { a -> node; }", .text = "node", .edit = .wrap_in_quotes },
        .{ .source = "digraph { ; }", .text = ";", .edit = .delete },
        .{ .source = "digraph { a; } }", .text = "}", .edit = .delete },
        .{ .source = "digraph { a, b; }", .text = ",", .edit = .replace, .replacement = .semicolon, .applicability = .maybe },
        .{ .source = "digraph { a -> -> b; }", .text = "->", .edit = .delete },
        .{ .source = "digraph { a [color=red,,x=1] }", .text = ",", .edit = .delete },
        .{ .source = "digraph { a [,color=red] }", .text = ",", .edit = .delete },
        .{ .source = "digraph { a [color red] }", .text = "color", .edit = .insert_after, .replacement = .equals, .applicability = .maybe },
        .{ .source = "digraph { a [color=red; }", .text = "}", .edit = .insert_before, .replacement = .right_bracket, .applicability = .maybe },
        .{ .source = "digraph { a [color=red", .text = "", .edit = .insert_before, .replacement = .right_bracket },
        .{ .source = "digraph { a -> b", .text = "", .edit = .insert_before, .replacement = .right_brace },
        .{ .source = "digrph { }", .text = "digrph", .edit = .replace, .replacement = .digraph_keyword, .applicability = .maybe },
        .{ .source = "digraph G\na -> b;\n}", .text = "a", .edit = .insert_before, .replacement = .left_brace, .applicability = .maybe },
        .{ .source = "digraph { a::n }", .text = ":", .edit = .delete, .applicability = .maybe },
        .{ .source = "digraph { \"abc", .text = "", .edit = .insert_before, .replacement = .double_quote, .applicability = .maybe },
        .{ .source = "digraph { /* x", .text = "", .edit = .insert_before, .replacement = .comment_close, .applicability = .maybe },
    }) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var events: Recording = .{};
        var bag: Bag = .{};
        _ = testing.run(case.source, &events, bag.sink(), .{}, null);
        const fix = bag.items()[0].fix orelse return error.MissingFix;
        try expectEqual(case.edit, std.meta.activeTag(fix.edit));
        try expectEqual(case.applicability, fix.applicability);
        try expectEqualStrings(case.text, fix.span.slice(case.source));
        if (case.replacement) |replacement| {
            const actual = switch (fix.edit) {
                .replace, .insert_before, .insert_after => |r| r,
                else => return error.WrongEdit,
            };
            try expectEqual(replacement, actual);
        }
    }
    // No single repair: attribute keyword without its list, a missing
    // endpoint, a second graph, or a misplaced `strict`.
    inline for (.{ "digraph { node; }", "digraph { a -> ; }", "digraph { a } digraph { b }", "digraph strict { }", "G { a; }" }) |source| {
        var events: Recording = .{};
        var bag: Bag = .{};
        _ = testing.run(source, &events, bag.sink(), .{}, null);
        try expect(bag.items()[0].fix == null);
    }
    // Before the kind keyword there is nothing to coerce a lone '-' to.
    var events: Recording = .{};
    var bag: Bag = .{};
    _ = testing.run("- graph { }", &events, bag.sink(), .{}, null);
    try expect(bag.items()[0].fix == null);
    // A misindented closing brace makes the end-of-input insertion a guess.
    const misindented = "digraph {\n  subgraph s {\n    a -> b;\n  b -> c;\n}\n";
    var frames: scratch_impl.Fixed(.{ .nesting = 4 }) = .{};
    var stack: scratch_impl.Stack = .{ .frames = frames.storage().frames };
    var nested_events: Recording = .{};
    var nested_bag: Bag = .{};
    _ = testing.run(misindented, &nested_events, nested_bag.sink(), .{}, &stack);
    try expectEqual(diagnostic.Applicability.maybe, nested_bag.items()[0].fix.?.applicability);
}

test "ambiguous numerals warn and the parse still succeeds" {
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = testing.run("graph { 1e3; 2.5.5 }", &events, bag.sink(), .{}, null);
    try expect(result.outcome == .success);
    try expectEqual(@as(usize, 2), bag.items().len);
    try expectEqual(diagnostic.Code.syntax_ambiguous_numeral, bag.items()[0].code);
    try expectEqual(diagnostic.Severity.warning, bag.items()[0].code.severity());
    try expectEqual(@as(u8, 'e'), bag.items()[0].details.ambiguous_numeral);
    try expectEqual(@as(u8, '.'), bag.items()[1].details.ambiguous_numeral);
    // Four node statements: 1, e3, 2.5, .5 — exactly Graphviz's split.
    var nodes: usize = 0;
    for (events.recorded()) |event| {
        if (event == .node_statement) nodes += 1;
    }
    try expectEqual(@as(usize, 4), nodes);
}

test "a leading byte order mark does not stop the parse" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run("\xEF\xBB\xBFdigraph { a -> b; }", &events, bag.sink(), .{}, null).outcome == .success);
    try expectEqual(@as(usize, 0), bag.items().len);
}

test "strict must be followed by a kind keyword" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run("strict { }", &events, bag.sink(), .{}, null).outcome == .invalid_syntax);

    const unexpected = bag.items()[0].details.unexpected;
    try expect(unexpected.expected.contains(.graph_keyword));
    try expect(unexpected.expected.contains(.digraph_keyword));
    try expectEqual(@as(usize, 0), events.recorded().len);
}

test "optional semicolons: adjacent statements split correctly" {
    const source = "graph { a b c -- d e }";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .success);

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
    try expect(testing.run("digraph { a -> b; c; }", &with, bag.sink(), .{}, null).outcome == .success);
    try expect(testing.run("digraph { a -> b c }", &without, bag.sink(), .{}, null).outcome == .success);
    try expectEqual(with.recorded().len, without.recorded().len);
}

test "missing edge endpoint is invalid syntax at the terminator" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run("graph { a -- ; }", &events, bag.sink(), .{}, null).outcome == .invalid_syntax);

    const failure = bag.items()[0];
    try expectEqual(diagnostic.Code.syntax_unexpected_token, failure.code);
    try expect(failure.details.unexpected.expected.contains(.identifier));
    try expectEqual(diagnostic.SyntaxItem.semicolon, failure.details.unexpected.found);
    try expectEqual(diagnostic.ParseContext.edge_endpoint, failure.details.unexpected.context);
}

test "trailing tokens after the document are invalid" {
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run("graph { a; } b", &events, bag.sink(), .{}, null).outcome == .invalid_syntax);
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
        try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.syntax_unexpected_end, bag.items()[0].code);
    }
}

test "input truncated at every byte boundary fails safely" {
    const source = "graph { a; a -- b; }";
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = testing.run(source[0..i], &events, bag.sink(), .{}, null);
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
    const quoted_result = testing.run("\"g\" { a; }", &quoted_events, quoted_bag.sink(), .{}, null);
    try expect(quoted_result.outcome == .invalid_syntax);
    try expectEqual(
        diagnostic.Code.syntax_unexpected_token,
        quoted_bag.items()[0].code,
    );
    try expectEqual(@as(usize, 0), quoted_events.recorded().len);

    // An incomplete header (begin fires only at `{`): no events either.
    var named_events: Recording = .{};
    var named_bag: Bag = .{};
    try expect(testing.run("strict digraph G", &named_events, named_bag.sink(), .{}, null).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 0), named_events.recorded().len);

    // Invalid leading byte: invalid syntax, empty event sink.
    var invalid_events: Recording = .{};
    var invalid_bag: Bag = .{};
    try expect(testing.run("@", &invalid_events, invalid_bag.sink(), .{}, null).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 1), invalid_bag.items().len);
    try expectEqual(@as(usize, 0), invalid_events.recorded().len);

    // Missing keyword entirely: empty event sink.
    var bare_events: Recording = .{};
    var bare_bag: Bag = .{};
    try expect(testing.run("{ a; }", &bare_events, bare_bag.sink(), .{}, null).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 0), bare_events.recorded().len);
}

test "unsupported outcome is a boundary, not a whole-input validity claim" {
    // The remainder after the unsupported introducer is malformed (`@`),
    // but the parse stopped at `<`: validity beyond the boundary is
    // unknown by design, and the outcome must not promise otherwise.
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = testing.run("graph { a -- < @", &events, bag.sink(), .{}, null);
    try expect(result.outcome == .unsupported_feature);
    try expectEqual(diagnostic.Feature.html_identifier, bag.items()[0].details.unsupported_feature);
}

test "deferred keywords in illegal positions are syntax errors, not unsupported" {
    // A subgraph cannot be the document root, and no keyword is a valid
    // unquoted graph name or edge endpoint (Graphviz rejects all of
    // these). Reporting them as unsupported features would claim the input
    // uses a deferred construct when it is simply malformed.
    // Positions that never take a name report the keyword as an unexpected
    // token; positions that wanted a name report a reserved keyword.
    inline for (.{
        .{ "subgraph s { a; }", diagnostic.SyntaxItem.subgraph_keyword },
        .{ "strict subgraph { }", diagnostic.SyntaxItem.subgraph_keyword },
        .{ "node { }", diagnostic.SyntaxItem.node_keyword },
        .{ "graph { a; } subgraph", diagnostic.SyntaxItem.subgraph_keyword },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = testing.run(case[0], &events, bag.sink(), .{}, null);
        try expect(result.outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.syntax_unexpected_token, bag.items()[0].code);
        try expectEqual(case[1], bag.items()[0].details.unexpected.found);
    }
    inline for (.{
        .{ "graph subgraph { }", diagnostic.Keyword.subgraph },
        .{ "graph node { }", diagnostic.Keyword.node },
        .{ "graph { a -- node; }", diagnostic.Keyword.node },
        .{ "graph { a -- edge; }", diagnostic.Keyword.edge },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        const result = testing.run(case[0], &events, bag.sink(), .{}, null);
        try expect(result.outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.syntax_reserved_keyword, bag.items()[0].code);
        try expectEqual(case[1], bag.items()[0].details.reserved_keyword.keyword);
    }
}

test "recognized-but-deferred constructs mid-document abort as unsupported" {
    inline for (.{
        .{ "graph { a -- <b>; }", diagnostic.Feature.html_identifier },
        .{ "graph { <b> -- a; }", diagnostic.Feature.html_identifier },
    }) |case| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(testing.run(case[0], &events, bag.sink(), .{}, null).outcome == .unsupported_feature);
        try expectEqual(case[1], bag.items()[0].details.unsupported_feature);
        try expectAborted(case[0], .unsupported_feature);
    }
}

test "attribute keywords require a bracket list; malformed subgraph headers fail" {
    inline for (.{ "graph { graph; }", "graph { node; }", "graph { edge -- x; }", "graph { node -- x; }", "digraph { graph }", "graph { a node }" }) |source| {
        var events: Recording = .{};
        var bag: Bag = .{};
        try expect(testing.run(source, &events, bag.sink(), .{}, null).outcome == .invalid_syntax);
        try expectEqual(diagnostic.Code.syntax_reserved_keyword, bag.items()[0].code);
        try expectEqual(diagnostic.ParseContext.attribute_list, bag.items()[0].details.reserved_keyword.context);
    }
    try expectAborted("graph { subgraph; }", .invalid_syntax);
}

test "statement limit is a resource outcome, distinct from invalid syntax" {
    var events: Recording = .{};
    var bag: Bag = .{};
    const result = testing.run("graph { a; b; }", &events, bag.sink(), .{ .limits = .{ .max_statements = 1 } }, null);
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
    try expect(testing.run("graph { }", &empty_events, empty_bag.sink(), .{ .limits = .{ .max_statements = 0 } }, null).outcome == .success);
}

test "zero statement limit still scans an arbitrarily large body" {
    // The statement limit is output capacity, not a work budget: the body
    // is whitespace-only, so the parser scans it linearly and succeeds.
    const source = "graph {" ++ (" " ** 4096) ++ "\n}";
    var events: Recording = .{};
    var bag: Bag = .{};
    try expect(testing.run(source, &events, bag.sink(), .{ .limits = .{ .max_statements = 0 } }, null).outcome == .success);
}

test "event-sink failure aborts the document and surfaces the sink's error" {
    // Capacity 2 fits begin + one statement; the second statement fails.
    var events: syntax_event.RecordingSink(2) = .{};
    var bag: Bag = .{};
    const result = testing.run("graph { a; b; }", &events, bag.sink(), .{}, null);
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
    const result = testing.run("graph { }", &events, bag.sink(), .{}, null);
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
    // must remain a small constant, independent of input size. The bounds
    // are the measured values (368 B with the scalar scanner, 472 B with the
    // block scanner's saved masks) plus headroom, not architectural budgets:
    // if a slice legitimately grows the state, measure, update the baseline
    // doc, and raise the bound in the same commit.
    try expect(@sizeOf(Machine(*Recording, false, false, false, scalar_lex.Scanner, null)) <= 512);
    try expect(@sizeOf(Machine(*Recording, false, false, false, block_lex.Scanner, null)) <= 640);
}

test "step is terminal-idempotent after success and after failure" {
    var events: Recording = .{};
    var bag: Bag = .{};
    var machine: Machine(*Recording, false, false, false, scalar_lex.Scanner, null) = .{
        .tokens = scalar_lex.Scanner(false, false, null).init("graph { a; }"),
        .events = &events,
        .diagnostics = bag.sink(),
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
    var failed_machine: Machine(*Recording, false, false, false, scalar_lex.Scanner, null) = .{
        .tokens = scalar_lex.Scanner(false, false, null).init("graph {"),
        .events = &failed_events,
        .diagnostics = failed_bag.sink(),
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
    const result = testing.run("graph {", &events, sink, .{}, null);

    // The parse category stands; the lost diagnostic is visible separately.
    try expect(result.outcome == .invalid_syntax);
    try expectEqual(DiagnosticDelivery.failed, result.diagnostic_delivery);

    // A working sink reports complete delivery on the same input.
    var ok_events: Recording = .{};
    var bag: Bag = .{};
    const ok = testing.run("graph {", &ok_events, bag.sink(), .{}, null);
    try expectEqual(DiagnosticDelivery.complete, ok.diagnostic_delivery);
}

test "attribute pairs stream before owners and abort if any event is refused" {
    const source = "graph { a[x=1][y=2]; node[]; z=3; a--b[w=4] }";
    var complete: Recording = .{};
    try expect(testing.run(source, &complete, diagnostic.discard, .{}, null).outcome == .success);
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
        const result = testing.run(source, &events, diagnostic.discard, .{}, null);
        try expect(result.outcome == .sink_failure);
        try expectEqual(anyerror.EventCapacityExceeded, result.outcome.sink_failure);
        try expectEqual(@as(usize, capacity + 1), events.recorded().len);
        try expect(events.recorded()[capacity] == .abort_document);
    }
    var partial: Recording = .{};
    try expect(testing.run("graph { a[x=1 y=] }", &partial, diagnostic.discard, .{}, null).outcome == .invalid_syntax);
    try expectEqual(@as(usize, 3), partial.recorded().len);
    try expect(partial.recorded()[1] == .attribute);
    try expect(partial.recorded()[2] == .abort_document);
}

test "nested scope callbacks and all prefixes preserve budget partitioning" {
    const source = "digraph { a->subgraph s { a:p->b->{c}[x=1] {z=q} }->{} }";
    const total = try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, .{}, null, false);
    try expectEqual(total, try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 3, 17 }, .{}, null, false));
    for (0..source.len + 1) |end| _ = try checkBudgetPartition(scalar_lex.Scanner, source[0..end], &.{ 0, 1, 2 }, .{}, null, false);
    // Includes failures in begin/end scope, normal owner callbacks, and commit.
    for (0..16) |at| _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{ 0, 1, 5 }, .{}, at, false);
    for (0..3) |depth| _ = try checkBudgetPartition(scalar_lex.Scanner, source, &.{1}, .{ .limits = .{ .max_nesting = depth } }, null, false);
}
