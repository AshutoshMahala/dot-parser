//! Private syntax-event contract (milestone 1, step 4).
//!
//! This is the provisional seam between the parser (producer) and syntax
//! consumers such as the borrowed-tree builder. It is NOT public API: it is
//! not exported from `root.zig`, and it may change freely until at least two
//! vertical slices have exercised it (plan change discipline). No general
//! engine target and no runtime-erased sink are published here.
//!
//! ## Event vocabulary and ordering
//!
//! The sink lifecycle begins only once the parser has recognized a complete
//! supported document header — `[strict] (graph|digraph) [name] {` — so
//! `beginDocument` carries the whole header (kind, strict, name). A parse
//! therefore emits either
//!
//! - **no events at all** — the input failed before the header completed
//!   (invalid leading bytes, a malformed header, or a deferred construct
//!   such as an HTML-like document name). The failure is reported through the
//!   parse result and diagnostics, never through this contract — or
//! - exactly this sequence:
//!
//! ```text
//! beginDocument
//! ((portedReference* attribute* (nodeStatement | edgeStatement)) |
//!  (portedReference* (portedReference? edgeLink)+ attribute* edgeChainStatement) |
//!  (attribute* attributeStatement) | assignment |
//!  (beginSubgraph ...nested body events... endSubgraph))*
//! endDocument | abortDocument        // exactly one terminal event
//! ```
//!
//! - `beginDocument` is the first event whenever any event is emitted, with
//!   one cleanup exception below.
//! - Each edgeLink streams one continuation after the first edge. The final
//!   edgeChainStatement carries the first edge and consumes all pending links
//!   and attributes. Abort discards both pools; no temporary chain list exists.
//! - Scope entry reserves an owner before body events and returns its ID plus
//!   opaque saved builder state. Endpoint scopes are not standalone statements.
//!   The parser returns that state on exit, restoring the suspended outer edge.
//!   A left-position scope emits subgraphStatement only if lookahead finds no
//!   edge operator. Right/link entries stage the operator before nested body events.
//!   Node-only prefixes are retained by range, never copied on promotion.
//!   Abort discards the tree without synthesizing per-scope close events.
//! - `portedReference` stages one completed qualified occurrence, in source
//!   order, and returns an opaque document-local `u32` handle. The following
//!   node/edge/link event uses that handle alongside the base identifier span.
//!   Bare references emit no such event. Chain middles are staged once and
//!   reused by the pairwise view. Handles expire on abort or storage reuse;
//!   they do not identify interned nodes, unique ports or declarations.
//! - Each `attribute` carries one completed pair for the immediately following
//!   node, edge, or attribute statement. Adjacent bracket groups are flattened;
//!   empty groups produce no pair event. Pairs never attach to an assignment.
//! - Pair events stream before their owning statement, so a malformed suffix
//!   may abort after some pairs with no final statement event. Consumers stage
//!   these pairs in their destination pool and discard them on document abort;
//!   no temporary per-statement list is required in the parser.
//! - The final statement consumes all pending pairs. There can be no pending
//!   pairs at `endDocument`. This seam remains private, not a stable sink API.
//! - `endDocument` commits: the document parsed completely.
//! - `abortDocument` ends the document without commit (R-MOD-011). The
//!   parser cannot roll back work a sink already performed; sinks needing
//!   atomic output must stage internally and discard on abort.
//! - No event follows the terminal event.
//! - **Cleanup exception:** if `beginDocument` itself fails, the parser
//!   still calls `abortDocument(.sink_failure)` so the sink can release
//!   partially initialized state. Such a sink observes a lone abort with no
//!   preceding begin — the only sequence in which begin is not first.
//!
//! ## Failure propagation
//!
//! `beginDocument`, `nodeStatement`, `edgeStatement`, `attribute`, `assignment`,
//! `edgeLink`, `edgeChainStatement`, `attributeStatement`, `subgraphStatement`,
//! `endSubgraph`, and `endDocument`
//! return `E!void` for an error set `E` the sink chooses (allocation
//! failure, capacity, …); a sink that cannot fail declares `error{}!void`.
//! `portedReference` returns `E!u32`; `beginSubgraph` returns `E!ScopeEntry`.
//! Both share the normal failure/abort rules and cost one dispatch work unit.
//! When one fails, the parser stops and calls `abortDocument` — which is
//! infallible and must always succeed — so the sink can release staged
//! state. The parse outcome then reports a sink failure, distinct from
//! invalid syntax (R-DIAG-003).
//!
//! Parser-owned nesting storage failure aborts with `.scratch_failure`; the
//! facade maps it to a public storage outcome. Enter/exit each cost one normal
//! dispatch credit. Standalone completion is a separate subgraphStatement event;
//! an endpoint scope does not increment statement progress.
//!
//! ## Span lifetime
//!
//! Event spans index the caller-owned source buffer (R-MEM-004 borrowed
//! input). They are plain offsets — a sink MAY retain them without copying
//! the source, and they stay meaningful for as long as the caller keeps the
//! source bytes alive and unchanged.

const std = @import("std");
const location = @import("location.zig");

/// The kind of graph a document declares. `graph` in identifiers and prose
/// means "either kind"; the DOT source keyword `graph` maps to `.undigraph`
/// at reading time, `digraph` to `.digraph`.
pub const GraphKind = enum {
    undigraph,
    digraph,
};

/// The edge operator as written in the source. The parser is kind-agnostic:
/// both operators always parse, and whether an operator is legal for the
/// document's kind is validation policy, not a parse error.
pub const EdgeOperator = enum {
    /// `--`
    undirected,
    /// `->`
    directed,

    pub fn lexeme(self: EdgeOperator) []const u8 {
        return switch (self) {
            .undirected => "--",
            .directed => "->",
        };
    }
};

pub const BeginDocument = struct {
    kind: GraphKind,
    /// True when the document carries the `strict` modifier. Retained as
    /// written; strict's duplicate-edge semantics are semantic resolution,
    /// not parsing (R-FUNC-003).
    strict: bool = false,
    /// Span of the kind keyword as written (`graph` or `digraph`).
    keyword_span: location.Span,
    /// The document's name, when one was written.
    name_span: ?location.Span = null,
};

pub const Attribute = struct {
    key: location.Span,
    value: location.Span,
};

pub const AttributeTarget = enum { graph, node, edge };

pub const AttributeStatement = struct {
    target: AttributeTarget,
    keyword_span: location.Span,
};

pub const ScopeRole = enum { left, right, link };
pub const ScopeState = struct { reserved_order: ?u32 = null, scoped_owner: ?u32 = null };
pub const ScopeEntry = struct { id: u32, state: ScopeState = .{} };
pub const BeginSubgraph = struct {
    /// The keyword or anonymous opening brace; the name uses its full raw span.
    start: location.Span,
    name: ?location.Span,
    role: ScopeRole = .left,
    edge: ?EdgeStatement = null,
    link_operator: ?EdgeOperator = null,
    link_operator_span: ?location.Span = null,
};
pub const EndSubgraph = struct { close: location.Span, entry: ScopeEntry };

pub const NodeStatement = struct {
    identifier: location.Span,
    port: ?u32 = null,
};

pub const EdgeLink = struct {
    operator: EdgeOperator,
    operator_span: location.Span,
    right: location.Span,
    right_port: ?u32 = null,
};

pub const EdgeStatement = struct {
    left_scope: ?u32 = null,
    right_scope: ?u32 = null,
    left: location.Span,
    left_port: ?u32 = null,
    operator: EdgeOperator,
    operator_span: location.Span,
    right: location.Span,
    right_port: ?u32 = null,
};

/// A completed suffix occurrence. The sink returns a document-local pool handle.
pub const PortedReference = struct {
    identifier: location.Span,
    first: location.Span,
    second: ?location.Span = null,
};

/// Why a document ended without commit. Coarse control-flow information
/// only; the corresponding diagnostic travels through the diagnostic sink,
/// never through this enum (R-DIAG-003). Grows in later slices
/// (cancellation, configured limits, …).
pub const AbortReason = enum {
    scratch_failure,
    cancelled,
    invalid_syntax,
    unsupported_feature,
    resource_exhausted,
    sink_failure,
};

/// The complete event vocabulary as data — used by recording sinks and
/// tests. Producers call sink methods directly; they do not construct this
/// union on the hot path.
pub const Event = union(enum) {
    begin_document: BeginDocument,
    begin_subgraph: BeginSubgraph,
    end_subgraph: EndSubgraph,
    subgraph_statement: u32,
    node_statement: NodeStatement,
    edge_statement: EdgeStatement,
    edge_chain_statement: EdgeStatement,
    edge_link: EdgeLink,
    ported_reference: PortedReference,
    attribute: Attribute,
    assignment: Attribute,
    attribute_statement: AttributeStatement,
    end_document,
    abort_document: AbortReason,
};

/// Comptime check that `T` implements the syntax-sink contract: method
/// presence, parameter types, and return-type shape. Produces a readable
/// compile error naming the offending method (R-MOD-007 spirit: incoherent
/// compositions fail loudly at build time).
///
/// Required methods:
///
/// ```zig
/// pub fn beginDocument(self: *T, event: BeginDocument) E!void
/// pub fn nodeStatement(self: *T, statement: NodeStatement) E!void
/// pub fn edgeStatement(self: *T, statement: EdgeStatement) E!void
/// pub fn edgeChainStatement(self: *T, first: EdgeStatement) E!void
/// pub fn edgeLink(self: *T, link: EdgeLink) E!void
/// pub fn attribute(self: *T, pair: Attribute) E!void
/// pub fn assignment(self: *T, pair: Attribute) E!void
/// pub fn attributeStatement(self: *T, statement: AttributeStatement) E!void
/// pub fn endDocument(self: *T) E!void
/// pub fn abortDocument(self: *T, reason: AbortReason) void   // infallible
/// ```
///
/// where `E` is any error set the sink chooses (`error{}` if it cannot
/// fail — the fallible methods must be error unions so the parser can `try`
/// them uniformly).
pub fn assertSyntaxSink(comptime T: type) void {
    comptime {
        assertMethod(T, "beginDocument", &.{BeginDocument}, .fallible);
        assertMethod(T, "beginSubgraph", &.{BeginSubgraph}, .scope);
        assertMethod(T, "subgraphStatement", &.{u32}, .fallible);
        assertMethod(T, "endSubgraph", &.{EndSubgraph}, .fallible);
        assertMethod(T, "nodeStatement", &.{NodeStatement}, .fallible);
        assertMethod(T, "edgeStatement", &.{EdgeStatement}, .fallible);
        assertMethod(T, "edgeChainStatement", &.{EdgeStatement}, .fallible);
        assertMethod(T, "edgeLink", &.{EdgeLink}, .fallible);
        assertMethod(T, "portedReference", &.{PortedReference}, .reference);
        assertMethod(T, "attribute", &.{Attribute}, .fallible);
        assertMethod(T, "assignment", &.{Attribute}, .fallible);
        assertMethod(T, "attributeStatement", &.{AttributeStatement}, .fallible);
        assertMethod(T, "endDocument", &.{}, .fallible);
        assertMethod(T, "abortDocument", &.{AbortReason}, .infallible);
    }
}

fn assertMethod(
    comptime T: type,
    comptime name: []const u8,
    comptime arg_types: []const type,
    comptime failability: enum { fallible, infallible, reference, scope },
) void {
    const prefix = @typeName(T) ++ "." ++ name;
    if (!@hasDecl(T, name)) {
        @compileError(@typeName(T) ++ " does not implement the syntax-sink contract: missing `" ++ name ++ "`");
    }
    const info = @typeInfo(@TypeOf(@field(T, name)));
    if (info != .@"fn") {
        @compileError(prefix ++ " must be a function");
    }
    const params = info.@"fn".params;
    if (params.len != arg_types.len + 1) {
        @compileError(prefix ++ " must take `self` plus " ++
            std.fmt.comptimePrint("{d}", .{arg_types.len}) ++ " argument(s)");
    }
    if (params[0].type != *T) {
        @compileError(prefix ++ " must take `self: *" ++ @typeName(T) ++ "` as its first parameter");
    }
    for (arg_types, 0..) |Arg, i| {
        if (params[i + 1].type != Arg) {
            @compileError(prefix ++ ": parameter " ++
                std.fmt.comptimePrint("{d}", .{i + 2}) ++ " must be `" ++ @typeName(Arg) ++ "`");
        }
    }
    const return_type = info.@"fn".return_type orelse
        @compileError(prefix ++ " must have a concrete return type");
    switch (failability) {
        .infallible => if (return_type != void) {
            @compileError(prefix ++ " must return `void`: abort cannot fail by contract");
        },
        .fallible, .reference, .scope => {
            const Payload = if (failability == .reference) u32 else if (failability == .scope) ScopeEntry else void;
            const return_info = @typeInfo(return_type);
            if (return_info != .error_union or return_info.error_union.payload != Payload) {
                @compileError(prefix ++ " must return an error union with payload " ++ @typeName(Payload));
            }
        },
    }
}

/// A fixed-capacity sink that records every event it observes, in order.
/// Reference implementation of the contract and the test double for the
/// parser and builder (R-ARCH-005: drive the parser with a recording sink).
/// Performs no allocation.
///
/// `capacity` bounds the fallible events (begin + statements + attribute pairs). One extra
/// slot is reserved for the terminal event so that recording an abort can
/// never fail — capacity exhaustion is exactly when aborts happen, and the
/// contract requires `abortDocument` to be infallible.
pub fn RecordingSink(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Error = error{EventCapacityExceeded};

        events: [capacity + 1]Event = undefined,
        len: usize = 0,
        port_count: u32 = 0,
        scope_count: u32 = 0,

        pub fn beginDocument(self: *Self, event: BeginDocument) Error!void {
            try self.record(.{ .begin_document = event });
        }

        pub fn nodeStatement(self: *Self, statement: NodeStatement) Error!void {
            try self.record(.{ .node_statement = statement });
        }

        pub fn edgeStatement(self: *Self, statement: EdgeStatement) Error!void {
            try self.record(.{ .edge_statement = statement });
        }

        pub fn beginSubgraph(self: *Self, event: BeginSubgraph) Error!ScopeEntry {
            try self.record(.{ .begin_subgraph = event });
            self.scope_count += 1;
            return .{ .id = self.scope_count };
        }
        pub fn subgraphStatement(self: *Self, id: u32) Error!void {
            try self.record(.{ .subgraph_statement = id });
        }
        pub fn endSubgraph(self: *Self, event: EndSubgraph) Error!void {
            try self.record(.{ .end_subgraph = event });
        }

        pub fn portedReference(self: *Self, event: PortedReference) Error!u32 {
            try self.record(.{ .ported_reference = event });
            const index = self.port_count;
            self.port_count += 1;
            return index;
        }

        pub fn edgeLink(self: *Self, event: EdgeLink) Error!void {
            try self.record(.{ .edge_link = event });
        }
        pub fn edgeChainStatement(self: *Self, event: EdgeStatement) Error!void {
            try self.record(.{ .edge_chain_statement = event });
        }

        pub fn attribute(self: *Self, event: Attribute) Error!void {
            try self.record(.{ .attribute = event });
        }
        pub fn assignment(self: *Self, event: Attribute) Error!void {
            try self.record(.{ .assignment = event });
        }
        pub fn attributeStatement(self: *Self, event: AttributeStatement) Error!void {
            try self.record(.{ .attribute_statement = event });
        }

        pub fn endDocument(self: *Self) Error!void {
            self.recordTerminal(.end_document);
        }

        pub fn abortDocument(self: *Self, reason: AbortReason) void {
            self.recordTerminal(.{ .abort_document = reason });
        }

        pub fn recorded(self: *const Self) []const Event {
            return self.events[0..self.len];
        }

        fn record(self: *Self, event: Event) Error!void {
            if (self.len >= capacity) return error.EventCapacityExceeded;
            self.events[self.len] = event;
            self.len += 1;
        }

        fn recordTerminal(self: *Self, event: Event) void {
            // At most `capacity` fallible events precede the single terminal
            // event, so the reserved slot is always free; a second terminal
            // event is a contract violation caught here in safe builds.
            std.debug.assert(self.len < self.events.len);
            self.events[self.len] = event;
            self.len += 1;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

comptime {
    assertSyntaxSink(RecordingSink(1));
}

test "recording sink preserves event order and borrowed spans" {
    // Hand-driven event sequence for `graph { a; a -- b; }` — the same
    // calls the parser will make in step 5.
    const source = "graph { a; a -- b; }";
    var sink: RecordingSink(8) = .{};

    const span = struct {
        fn at(offset: u32, len: u32) location.Span {
            return .{
                .start = offset,
                .len = len,
            };
        }
    }.at;

    try sink.beginDocument(.{ .kind = .undigraph, .keyword_span = span(0, 5) });
    try sink.nodeStatement(.{ .identifier = span(8, 1) });
    try sink.edgeStatement(.{
        .left = span(11, 1),
        .operator = .undirected,
        .operator_span = span(13, 2),
        .right = span(16, 1),
    });
    try sink.endDocument();

    const events = sink.recorded();
    try expectEqual(@as(usize, 4), events.len);

    try expect(events[0] == .begin_document);
    try expectEqual(GraphKind.undigraph, events[0].begin_document.kind);
    try expectEqualStrings("graph", events[0].begin_document.keyword_span.slice(source));

    try expect(events[1] == .node_statement);
    try expectEqualStrings("a", events[1].node_statement.identifier.slice(source));

    try expect(events[2] == .edge_statement);
    const edge = events[2].edge_statement;
    try expectEqual(EdgeOperator.undirected, edge.operator);
    try expectEqualStrings("a", edge.left.slice(source));
    try expectEqualStrings("--", edge.operator_span.slice(source));
    try expectEqualStrings("b", edge.right.slice(source));

    try expect(events[3] == .end_document);
}

test "abort after begin models a failed parse" {
    var sink: RecordingSink(4) = .{};
    try sink.beginDocument(.{
        .kind = .undigraph,
        .keyword_span = .{ .start = 0, .len = 5 },
    });
    sink.abortDocument(.invalid_syntax);

    const events = sink.recorded();
    try expectEqual(@as(usize, 2), events.len);
    try expect(events[1] == .abort_document);
    try expectEqual(AbortReason.invalid_syntax, events[1].abort_document);
}

test "sink failure propagates through the fallible methods" {
    var sink: RecordingSink(1) = .{};
    try sink.beginDocument(.{
        .kind = .undigraph,
        .keyword_span = .{ .start = 0, .len = 5 },
    });
    // Capacity exhausted: the next fallible event reports the sink's error.
    const result = sink.nodeStatement(.{
        .identifier = .{ .start = 0, .len = 1 },
    });
    try std.testing.expectError(error.EventCapacityExceeded, result);
}

test "abort is always recorded, even when event capacity is exhausted" {
    var sink: RecordingSink(1) = .{};
    try sink.beginDocument(.{
        .kind = .undigraph,
        .keyword_span = .{ .start = 0, .len = 5 },
    });
    try std.testing.expectError(error.EventCapacityExceeded, sink.nodeStatement(.{
        .identifier = .{ .start = 0, .len = 1 },
    }));

    // The parser reacts to a sink failure by aborting; the terminal event
    // must never be lost to the same capacity limit that caused it.
    sink.abortDocument(.sink_failure);

    const events = sink.recorded();
    try expectEqual(@as(usize, 2), events.len);
    try expect(events[0] == .begin_document);
    try expect(events[1] == .abort_document);
    try expectEqual(AbortReason.sink_failure, events[1].abort_document);
}

test "zero-capacity sink still records its terminal event" {
    var sink: RecordingSink(0) = .{};
    try std.testing.expectError(error.EventCapacityExceeded, sink.beginDocument(.{
        .kind = .undigraph,
        .keyword_span = .{ .start = 0, .len = 5 },
    }));
    sink.abortDocument(.sink_failure);
    try expectEqual(@as(usize, 1), sink.recorded().len);
}

test "edge operator lexemes match the written source forms" {
    try expectEqualStrings("--", EdgeOperator.undirected.lexeme());
    try expectEqualStrings("->", EdgeOperator.directed.lexeme());
}
