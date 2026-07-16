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
//! The sink lifecycle begins only once the parser has recognized a supported
//! document header. A parse therefore emits either
//!
//! - **no events at all** — the input failed before a supported header was
//!   recognized (invalid leading bytes, or a recognized-but-deferred header
//!   such as `digraph` or `strict`). The failure is reported through the
//!   parse result and diagnostics, never through this contract — or
//! - exactly this sequence:
//!
//! ```text
//! beginDocument
//! (nodeStatement | edgeStatement)*   // in source order
//! endDocument | abortDocument        // exactly one terminal event
//! ```
//!
//! - `beginDocument` is the first event whenever any event is emitted, with
//!   one cleanup exception below.
//! - Statement events arrive in the order they appear in the source.
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
//! `beginDocument`, `nodeStatement`, `edgeStatement`, and `endDocument`
//! return `E!void` for an error set `E` the sink chooses (allocation
//! failure, capacity, …); a sink that cannot fail declares `error{}!void`.
//! When one fails, the parser stops and calls `abortDocument` — which is
//! infallible and must always succeed — so the sink can release staged
//! state. The parse outcome then reports a sink failure, distinct from
//! invalid syntax (R-DIAG-003).
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
    /// Span of the document keyword as written (`graph`; later `digraph`).
    keyword_span: location.Span,
};

pub const NodeStatement = struct {
    identifier: location.Span,
};

pub const EdgeStatement = struct {
    left: location.Span,
    operator: EdgeOperator,
    operator_span: location.Span,
    right: location.Span,
};

/// Why a document ended without commit. Coarse control-flow information
/// only; the corresponding diagnostic travels through the diagnostic sink,
/// never through this enum (R-DIAG-003). Grows in later slices
/// (cancellation, configured limits, …).
pub const AbortReason = enum {
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
    node_statement: NodeStatement,
    edge_statement: EdgeStatement,
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
        assertMethod(T, "nodeStatement", &.{NodeStatement}, .fallible);
        assertMethod(T, "edgeStatement", &.{EdgeStatement}, .fallible);
        assertMethod(T, "endDocument", &.{}, .fallible);
        assertMethod(T, "abortDocument", &.{AbortReason}, .infallible);
    }
}

fn assertMethod(
    comptime T: type,
    comptime name: []const u8,
    comptime arg_types: []const type,
    comptime failability: enum { fallible, infallible },
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
        .fallible => {
            const return_info = @typeInfo(return_type);
            if (return_info != .error_union or return_info.error_union.payload != void) {
                @compileError(prefix ++ " must return `E!void` for an error set `E` of the sink's choice");
            }
        },
    }
}

/// A fixed-capacity sink that records every event it observes, in order.
/// Reference implementation of the contract and the test double for the
/// parser and builder (R-ARCH-005: drive the parser with a recording sink).
/// Performs no allocation.
///
/// `capacity` bounds the fallible events (begin + statements). One extra
/// slot is reserved for the terminal event so that recording an abort can
/// never fail — capacity exhaustion is exactly when aborts happen, and the
/// contract requires `abortDocument` to be infallible.
pub fn RecordingSink(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Error = error{EventCapacityExceeded};

        events: [capacity + 1]Event = undefined,
        len: usize = 0,

        pub fn beginDocument(self: *Self, event: BeginDocument) Error!void {
            try self.record(.{ .begin_document = event });
        }

        pub fn nodeStatement(self: *Self, statement: NodeStatement) Error!void {
            try self.record(.{ .node_statement = statement });
        }

        pub fn edgeStatement(self: *Self, statement: EdgeStatement) Error!void {
            try self.record(.{ .edge_statement = statement });
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
        fn at(offset: usize, len: usize) location.Span {
            return .{
                .start = .{ .byte_offset = offset, .line = 1, .byte_column = offset + 1 },
                .byte_len = len,
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
        .keyword_span = .{ .start = .start, .byte_len = 5 },
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
        .keyword_span = .{ .start = .start, .byte_len = 5 },
    });
    // Capacity exhausted: the next fallible event reports the sink's error.
    const result = sink.nodeStatement(.{
        .identifier = .{ .start = .start, .byte_len = 1 },
    });
    try std.testing.expectError(error.EventCapacityExceeded, result);
}

test "abort is always recorded, even when event capacity is exhausted" {
    var sink: RecordingSink(1) = .{};
    try sink.beginDocument(.{
        .kind = .undigraph,
        .keyword_span = .{ .start = .start, .byte_len = 5 },
    });
    try std.testing.expectError(error.EventCapacityExceeded, sink.nodeStatement(.{
        .identifier = .{ .start = .start, .byte_len = 1 },
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
        .keyword_span = .{ .start = .start, .byte_len = 5 },
    }));
    sink.abortDocument(.sink_failure);
    try expectEqual(@as(usize, 1), sink.recorded().len);
}

test "edge operator lexemes match the written source forms" {
    try expectEqualStrings("--", EdgeOperator.undirected.lexeme());
    try expectEqualStrings("->", EdgeOperator.directed.lexeme());
}
