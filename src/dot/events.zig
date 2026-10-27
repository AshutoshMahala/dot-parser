//! Compile-time-bound DOT output. Event payloads borrow original source bytes;
//! no document pools, source copies, runtime registry or event queue is required.
//!
//! Implement onEvent(*Self, Event) E!Action and onAbort(*Self, Abort) void.
//! Ignore unwanted event cases. Abort is infallible cleanup, never a diagnostic
//! or an automatic rollback of consumer side effects. Stage atomic output until
//! the matching commit_* event (or end_document for whole-document atomicity).
const std = @import("std");
const location = @import("parser_support").location;
const diagnostic = @import("diagnostic.zig");
pub const Name = @import("name.zig").Name;
const recognized = @import("name.zig").recognized;

/// Compile-time selection on a sink: `pub const observations =
/// dot.events.Observations.all;`. Preview retirement is inseparable from
/// preview delivery. Unselected kinds add no callbacks or dispatch credits.
pub const Observations = struct {
    identifier: bool = false,
    statement_head: bool = false,
    document_name: bool = false,
    subgraph_name: bool = false,
    token_preview: bool = false,

    pub const none: Observations = .{};
    pub const early: Observations = .{ .identifier = true, .statement_head = true, .document_name = true, .subgraph_name = true };
    pub const previews: Observations = .{ .token_preview = true };
    pub const all: Observations = .{ .identifier = true, .statement_head = true, .document_name = true, .subgraph_name = true, .token_preview = true };

    pub fn enabled(self: Observations) bool {
        return self.identifier or self.statement_head or self.document_name or self.subgraph_name or self.token_preview;
    }
};

pub const Action = enum { proceed, stop };
/// Local to this parse/source. Statement IDs are opening byte offsets; scopes
/// are one-based opening-order occurrences and qualified references are
/// zero-based encounter-order occurrences. Never interned semantic identities.
pub const StatementId = enum(u32) { _ };
pub const ScopeId = enum(u32) { root = 0, _ };
pub const ReferenceId = enum(u32) { _ };
pub const GraphKind = enum { undigraph, digraph };
pub const EdgeOperator = enum {
    undirected,
    directed,
    pub fn lexeme(self: EdgeOperator) []const u8 {
        return if (self == .directed) "->" else "--";
    }
};
pub const ScopeRole = enum { left, right, link };
pub const AbortReason = enum {
    processor_stopped,
    diagnostic_stopped,
    scratch_failure,
    cancelled,
    invalid_syntax,
    unsupported_feature,
    resource_exhausted,
    sink_failure,
    sink_stopped,
};
pub const Attribute = struct { key: Name, value: Name };
pub const PortedReference = struct { identifier: Name, first: Name, second: ?Name = null };
pub const Node = struct { identifier: Name, port: ?u32 = null };
pub const Edge = struct {
    left_scope: ?u32 = null,
    right_scope: ?u32 = null,
    /// Complete identifier only when left_scope is null; otherwise the written
    /// scope introducer (`subgraph` or `{`), not a trusted name.
    left: location.Span,
    left_port: ?u32 = null,
    operator: EdgeOperator,
    operator_span: location.Span,
    /// As for left: right_scope distinguishes a name from a scope introducer.
    right: location.Span,
    right_port: ?u32 = null,
    pub fn leftName(self: Edge) ?Name {
        return if (self.left_scope == null) recognized(self.left) else null;
    }
    pub fn rightName(self: Edge) ?Name {
        return if (self.right_scope == null) recognized(self.right) else null;
    }
};
pub const Link = struct { operator: EdgeOperator, operator_span: location.Span, right: Name, right_port: ?u32 = null };
pub const AttributeTarget = enum { graph, node, edge };
pub const AttributeStatement = struct { target: AttributeTarget, keyword_span: location.Span };
pub const Owner = struct { statement: StatementId, scope: ScopeId };
pub fn Committed(comptime Value: type) type {
    return struct { owner: Owner, value: Value };
}
pub const Skipped = struct { span: location.Span, scope: ScopeId };
pub const BeginDocument = struct {
    kind: GraphKind,
    strict: bool = false,
    keyword_span: location.Span,
    name_span: ?Name = null,
    retain_comments: bool = false,
    source_info: @import("parser_support").encoding.Info = .{},
};
pub const BeginScope = struct {
    id: ScopeId,
    parent: ScopeId,
    statement: StatementId,
    start: location.Span,
    name: ?Name = null,
    role: ScopeRole = .left,
    /// The suspended edge prefix, if this is a right/link endpoint. It is
    /// syntax, not a storage reservation; the owning commit still follows.
    edge: ?Edge = null,
    link_operator: ?EdgeOperator = null,
    link_operator_span: ?location.Span = null,
};
pub const EndScope = struct { id: ScopeId, close: location.Span };
/// Early observations describe recognized syntax, not accepted statements.
/// A statement-leading identifier can still become an assignment key; its role
/// is refined by statement_head. Neither endpoint role includes its port suffix.
pub const IdentifierRole = enum { statement_start, edge_right, edge_link };
pub const StatementKind = enum { node, edge, assignment, graph_attributes, node_attributes, edge_attributes, subgraph };
pub const StatementHead = struct { owner: Owner, kind: StatementKind, start: location.Span };
pub const Identifier = struct { owner: Owner, name: Name, role: IdentifierRole };
pub const DocumentName = struct {
    kind: GraphKind,
    strict: bool,
    keyword_span: location.Span,
    name: Name,
    source_info: @import("parser_support").encoding.Info,
};
pub const SubgraphName = struct { owner: Owner, keyword_span: location.Span, name: Name, role: ScopeRole };
/// Raw lexical observations, never trusted identifiers. `word` may become a
/// keyword. Prefixes may end within a Unicode scalar or escape sequence.
pub const PreviewKind = @import("lexer/preview.zig").Kind;
pub const PreviewContext = enum { unknown, document_name, subgraph_name, statement_start, edge_right, edge_link, attribute_key, attribute_value, assignment_value, port };
pub const TokenPreview = struct {
    span: location.Span,
    kind: PreviewKind,
    reason: enum { pause, eof },
    context: PreviewContext,
    scope: ScopeId,
    /// Absent until this prefix's statement occurrence has actually begun;
    /// separator-free lookahead never inherits the preceding statement's owner.
    owner: ?Owner,
    source_info: @import("parser_support").encoding.Info,
};
pub const TokenPreviewEnd = struct {
    /// Identifies the previously delivered prefix, not a new statement.
    start: u32,
    /// Lexical completion does not imply grammar acceptance.
    reason: enum { token, rejected },
};
pub const Event = union(enum) {
    begin_document: BeginDocument,
    begin_statement: struct { owner: Owner, start: location.Span },
    begin_scope: BeginScope,
    end_scope: EndScope,
    attribute: struct { owner: Owner, pair: Attribute },
    edge_link: struct { owner: Owner, link: Link },
    ported_reference: struct { owner: Owner, id: ReferenceId, reference: PortedReference },
    /// Only this statement's envelope is committed. Scoped endpoints may
    /// contain independently aborted/skipped children; this is not validation.
    commit_node: Committed(Node),
    commit_edge: Committed(Edge),
    commit_edge_chain: Committed(Edge),
    commit_subgraph: Committed(ScopeId),
    commit_assignment: Committed(Attribute),
    commit_attribute_statement: Committed(AttributeStatement),
    skipped: Skipped,
    comment: @import("comment.zig").Comment,
    end_document,
    /// Opt-in with Sink.observations. Names are complete lexical
    /// expressions, never unfinished-token previews. No scope/body is opened.
    identifier: Identifier,
    statement_head: StatementHead,
    document_name: DocumentName,
    subgraph_name: SubgraphName,
    /// Opt-in with observations.token_preview. Updates replace
    /// the preview with the same start. Token completion/rejection retires it;
    /// a document abort retires every remaining preview.
    token_preview: TokenPreview,
    token_preview_end: TokenPreviewEnd,
};

/// All output consumers implement this same contract, including the library's
/// builders and sizing sink. A private scope continuation is optional: it is
/// stored in typed nesting scratch, never in Event or Abort payloads.
pub fn assertSink(comptime Sink: type) void {
    comptime {
        checkMethod(Sink, "onEvent", Event, Action, true);
        checkMethod(Sink, "onAbort", Abort, void, false);
        for (.{ "wants_begin_statement", "recover_statements" }) |name| {
            if (@hasDecl(Sink, name) and @TypeOf(@field(Sink, name)) != bool)
                @compileError(name ++ " must be a comptime bool");
        }
        if (@hasDecl(Sink, "observations") and @TypeOf(Sink.observations) != Observations)
            @compileError("observations must be dot.events.Observations");
        if (@hasDecl(Sink, "ScopeContext")) {
            if (@TypeOf(Sink.ScopeContext) != type) @compileError("ScopeContext must be a type");
            if (!@hasDecl(Sink, "suspendScope") or !@hasDecl(Sink, "restoreScope"))
                @compileError("ScopeContext requires suspendScope and restoreScope");
            const save = @typeInfo(@TypeOf(Sink.suspendScope)).@"fn";
            const restore = @typeInfo(@TypeOf(Sink.restoreScope)).@"fn";
            if (save.param_types.len != 1 or save.param_types[0] != *Sink or save.return_type != Sink.ScopeContext or
                restore.param_types.len != 2 or restore.param_types[0] != *Sink or restore.param_types[1] != Sink.ScopeContext or restore.return_type != void)
                @compileError("scope continuation requires suspendScope(*Self) ScopeContext and restoreScope(*Self, ScopeContext) void");
        }
    }
}

fn checkMethod(comptime Sink: type, comptime name: []const u8, comptime Argument: type, comptime Payload: type, comptime fallible: bool) void {
    if (!@hasDecl(Sink, name)) @compileError(@typeName(Sink) ++ " is missing " ++ name);
    const method = @typeInfo(@TypeOf(@field(Sink, name)));
    if (method != .@"fn") @compileError(name ++ " must be a function");
    const f = method.@"fn";
    if (f.param_types.len != 2 or f.param_types[0] != *Sink or f.param_types[1] != Argument)
        @compileError(name ++ " must take (*Self, " ++ @typeName(Argument) ++ ")");
    const Return = f.return_type orelse @compileError(name ++ " must have a return type");
    if (fallible) {
        if (@typeInfo(Return) != .error_union or @typeInfo(Return).error_union.payload != Payload)
            @compileError(name ++ " must return an error union with payload " ++ @typeName(Payload));
    } else if (Return != Payload) @compileError(name ++ " must be infallible and return void");
}

pub fn Context(comptime Sink: type) type {
    return if (@hasDecl(Sink, "ScopeContext")) Sink.ScopeContext else void;
}

pub const Kind = std.meta.Tag(Event);

pub const Abort = union(enum) {
    statement: struct { owner: Owner, span: location.Span, reason: AbortReason },
    /// Also abandons all still-open statements/scopes, without inventing
    /// closing events. Earlier statement commits remain useful local facts.
    document: AbortReason,
};

pub const Outcome = union(enum) {
    success,
    invalid_syntax,
    unsupported_feature,
    resource_exhausted,
    cancelled,
    diagnostic_stopped: diagnostic.StopReason,
    event_stopped,
    event_failure: anyerror,
    /// Nesting scratch only: event-only parsing allocates no document pools.
    storage_failure: enum { out_of_memory, pool_exhausted },
};
pub const Result = struct {
    outcome: Outcome,
    source_info: @import("parser_support").encoding.Info = .{},
    completion: @import("parser.zig").Completion = .incomplete,
    syntax_errors: u32 = 0,
    accepted_deviations: u32 = 0,
    warnings: u32 = 0,
    diagnostic_delivery: diagnostic.Delivery = .complete,
    diagnostic_stop: ?diagnostic.StopReason = null,
};
pub const Progress = struct {
    phase: @import("parser.zig").Phase,
    work_used: usize,
    source_frontier: usize,
    completed_statements: usize,
    completed_pairs: usize,
    result: ?Result,
};

test "edge operator lexemes match written source forms" {
    try std.testing.expectEqualStrings("--", EdgeOperator.undirected.lexeme());
    try std.testing.expectEqualStrings("->", EdgeOperator.directed.lexeme());
}
