//! Borrowed, index-based syntax document and its builder (milestone 1, step 6).
//!
//! The document is the retained, source-shaped representation: statements in
//! source order, ranges borrowing the caller's source bytes. It stores what
//! was written and nothing else — no implicit nodes synthesized from edges,
//! no deduplication, no symbol table (those are semantic resolution, a later
//! and separate pass).
//!
//! ## Storage layout (R-MEM-006, R-MEM-008)
//!
//! Decomposed pools rather than one array of tagged unions:
//!
//! - `nodes` and `edges` are dense per-kind pools in source order, so
//!   per-kind passes (validation iterates only edges) are branch-free and
//!   touch no unrelated memory,
//! - `order` records source order as compact typed indices,
//! - statement indices are `Index` (u32) with checked overflow; the width is
//!   a single declaration so a future embedded profile can shrink it,
//! - retained positions are compact 8-byte `location.Range`s — offset and
//!   length only. Line/column are derived on demand (`location.locate`,
//!   `Range.toSpan`) by whoever emits a diagnostic; the retained document never
//!   pays for positions it may never need (R-MEM-008). The document therefore
//!   has its own statement types rather than aliasing the event protocol's
//!   span-carrying ones.
//!
//! ## Memory model (R-MEM-001/002/005)
//!
//! Explicit allocator, no hidden allocation. The document is mid-term data:
//! build it with an arena or fixed buffer and release it in bulk — `deinit`
//! is three frees, never a per-node walk; arena users may skip `deinit` and
//! reset the arena. The source bytes are caller-owned and must outlive the
//! document (borrowed ranges, R-MEM-004).
//!
//! `Builder.initCapacity` preallocates the pools once; with sufficient
//! capacities the build performs no further allocation and `toDocument` is
//! copy-free — the intended mode for `FixedBufferAllocator` users, whose
//! allocator cannot grow interleaved allocations in place.

const std = @import("std");
const location = @import("location.zig");
const syntax_event = @import("syntax_event.zig");
const identifier = @import("identifier.zig");

pub const GraphKind = syntax_event.GraphKind;
pub const EdgeOperator = syntax_event.EdgeOperator;

/// Statement index width. One declaration so profiles can shrink it for
/// small targets (R-MEM-006); overflow is checked in the builder.
pub const Index = u32;

/// A statement's identity: which pool, and where in it. Publicly
/// constructible, so `Document.statement` bounds-checks rather than trusting it.
pub const StatementId = union(enum) {
    node: Index,
    edge: Index,
};

pub const NodeStatement = struct {
    identifier: location.Range,
};

pub const EdgeStatement = struct {
    left: location.Range,
    operator: EdgeOperator,
    operator_range: location.Range,
    right: location.Range,
};

/// A by-value view of one statement, for order-preserving traversal.
pub const Statement = union(enum) {
    node: NodeStatement,
    edge: EdgeStatement,
};

pub const StatementIterator = struct {
    document: *const Document,
    index: usize = 0,

    pub fn next(self: *StatementIterator) ?Statement {
        const statement = self.document.statementAt(self.index) orelse return null;
        self.index += 1;
        return statement;
    }
};

/// The frozen, borrowed syntax document of one committed document. Immutable
/// after `Builder.toDocument`; safe to read concurrently while its memory and
/// the borrowed source stay alive (R-CON-003).
pub const Document = struct {
    /// The borrowed source this document was parsed from; every range below
    /// indexes it. Caller-owned and must outlive the document (R-MEM-004).
    /// Storing it here makes document/source pairings unforgeable for consumers
    /// such as validation.
    source: []const u8,
    kind: GraphKind,
    /// True when the document carries the `strict` modifier (retained as
    /// written; its duplicate-edge semantics are semantic resolution).
    strict: bool,
    /// Range of the document keyword that declared the kind.
    keyword: location.Range,
    /// The document's name, when one was written.
    name: ?location.Range,
    /// Statement identities in source order.
    order: []const StatementId,
    /// Node-statement pool, in source order.
    nodes: []const NodeStatement,
    /// Edge-statement pool, in source order.
    edges: []const EdgeStatement,

    pub fn statementCount(self: *const Document) usize {
        return self.order.len;
    }

    /// Bounds-checked lookup: null for an id that does not name a statement
    /// of this document (ids are publicly constructible).
    pub fn statement(self: *const Document, id: StatementId) ?Statement {
        return switch (id) {
            .node => |index| if (index < self.nodes.len)
                Statement{ .node = self.nodes[index] }
            else
                null,
            .edge => |index| if (index < self.edges.len)
                Statement{ .edge = self.edges[index] }
            else
                null,
        };
    }

    /// The statement at a position in source order, or null past the end.
    pub fn statementAt(self: *const Document, order_index: usize) ?Statement {
        if (order_index >= self.order.len) return null;
        return self.statement(self.order[order_index]);
    }

    /// Iterate statements in source order.
    pub fn statements(self: *const Document) StatementIterator {
        return .{ .document = self };
    }

    /// Exact source spelling, not a decoded identifier value. Quoted
    /// concatenations include quotes, '+' and intervening trivia.
    pub fn text(self: *const Document, range: location.Range) []const u8 {
        return range.slice(self.source);
    }

    /// Decode an identifier range into caller-owned memory. Output is unchanged
    /// on error. Range must lie within this document; non-identifier spelling
    /// is rejected. No caching, normalization, or numeric conversion occurs.
    pub fn decodeIdentifier(self: *const Document, range: location.Range, output: []u8) identifier.DecodeError![]const u8 {
        return identifier.decodeInto(self.text(range), output);
    }

    /// Stream a decoded identifier. A writer failure may leave partial output.
    pub fn writeIdentifier(self: *const Document, range: location.Range, writer: anytype) !void {
        try identifier.writeDecoded(self.text(range), writer);
    }
};

/// Free an allocator-owned document produced by `Builder.toDocument`
/// (bulk release, R-MEM-005: three frees, no per-node walk).
///
/// Package-internal on purpose: `Document` itself is a non-owning view, so
/// a fixed-storage document — whose pools belong to the caller — can never
/// meet a free operation. Public ownership lives on the façade result types.
pub fn deinitOwnedDocument(document: *Document, allocator: std.mem.Allocator) void {
    allocator.free(document.order);
    allocator.free(document.nodes);
    allocator.free(document.edges);
    document.* = undefined;
}

/// The first consumer of the private syntax-event contract: builds a `Document`
/// from parser events using explicit caller memory.
///
/// ## Lifecycle
///
/// ```text
/// idle --beginDocument--> building --endDocument--> committed
///                            │                          │
///                            │ abortDocument            │ toDocument (ok or error)
///                            ▼                          ▼
///                         terminal <────────────────────┘
///                            │ reset(source)
///                            ▼
///                          idle
/// ```
///
/// - A builder is bound to one source buffer; `reset(source)` rebinds it
///   for the next document (and is required between documents).
/// - `abortDocument` releases staged storage and is terminal.
/// - `toDocument` consumes the committed document **even on error**: a failed
///   transfer releases everything; a retry can never observe a partial
///   document.
/// - Contract-order violations are programmer errors and assert in safe
///   builds.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    /// The source the parsed document borrows from; embedded into the document.
    source: []const u8,
    kind: GraphKind = .undigraph,
    strict: bool = false,
    keyword: location.Range = .{ .start = 0, .len = 0 },
    name: ?location.Range = null,
    order: std.ArrayList(StatementId) = .empty,
    nodes: std.ArrayList(NodeStatement) = .empty,
    edges: std.ArrayList(EdgeStatement) = .empty,
    phase: Phase = .idle,
    /// Set when a sink method fails; read by the façade to emit a precise
    /// storage diagnostic.
    failure_info: ?StorageFailureInfo = null,

    pub const Error = error{
        OutOfMemory,
        /// More statements of one kind than `Index` can address.
        StatementIndexOverflow,
        /// A source position beyond the 4 GiB retained-range limit.
        SourceOffsetOverflow,
    };

    const Phase = enum { idle, building, committed, terminal };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Builder {
        return .{ .allocator = allocator, .source = source };
    }

    /// Preallocate the pools once. With capacities that cover the document,
    /// the build performs no further allocation and `toDocument` is copy-free —
    /// the intended mode for fixed-buffer users, who typically derive the
    /// numbers from the same budget as `parser.Options.max_statements`.
    pub fn initCapacity(
        allocator: std.mem.Allocator,
        source: []const u8,
        capacities: Capacities,
    ) Error!Builder {
        var builder = init(allocator, source);
        errdefer builder.deinit();
        try builder.order.ensureTotalCapacityPrecise(allocator, capacities.statements);
        try builder.nodes.ensureTotalCapacityPrecise(allocator, capacities.nodes);
        try builder.edges.ensureTotalCapacityPrecise(allocator, capacities.edges);
        return builder;
    }

    /// Safe to call in every phase; releases whatever the builder holds.
    pub fn deinit(self: *Builder) void {
        self.order.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.* = undefined;
    }

    /// Rebind the builder to `source` and return it to `.idle` for the next
    /// document, clearing staged statements but keeping allocated capacity
    /// (aborts have already released storage). Required between documents.
    pub fn reset(self: *Builder, source: []const u8) void {
        self.source = source;
        self.failure_info = null;
        self.order.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
        self.phase = .idle;
    }

    /// Take ownership of the finished document. Valid once per committed
    /// document; the builder is terminal afterwards (on success *and* on
    /// error — a failed transfer releases everything and never leaves a
    /// partially consumed committed builder). `reset` restores reuse.
    pub fn toDocument(self: *Builder) Error!Document {
        std.debug.assert(self.phase == .committed);
        errdefer {
            self.order.clearAndFree(self.allocator);
            self.nodes.clearAndFree(self.allocator);
            self.edges.clearAndFree(self.allocator);
            self.phase = .terminal;
        }
        const order = try self.order.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(order);
        const nodes = try self.nodes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(nodes);
        const edges = try self.edges.toOwnedSlice(self.allocator);
        self.phase = .terminal;
        return .{
            .source = self.source,
            .kind = self.kind,
            .strict = self.strict,
            .keyword = self.keyword,
            .name = self.name,
            .order = order,
            .nodes = nodes,
            .edges = edges,
        };
    }

    // --- syntax-event sink contract -------------------------------------

    pub fn beginDocument(self: *Builder, event: syntax_event.BeginDocument) Error!void {
        std.debug.assert(self.phase == .idle);
        self.phase = .building;
        self.kind = event.kind;
        self.strict = event.strict;
        self.keyword = try self.range(event.keyword_span);
        self.name = if (event.name_span) |name_span| try self.range(name_span) else null;
    }

    pub fn nodeStatement(self: *Builder, statement_event: syntax_event.NodeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const at = statement_event.identifier;
        const node: NodeStatement = .{
            .identifier = try self.range(statement_event.identifier),
        };
        const index = try self.statementIndex(self.nodes.items.len, at);
        // Reserve both slots first so the two appends cannot desynchronize.
        try self.reserve(&self.nodes, at);
        try self.reserve(&self.order, at);
        self.nodes.appendAssumeCapacity(node);
        self.order.appendAssumeCapacity(.{ .node = index });
    }

    pub fn edgeStatement(self: *Builder, statement_event: syntax_event.EdgeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const at = statement_event.left;
        const edge: EdgeStatement = .{
            .left = try self.range(statement_event.left),
            .operator = statement_event.operator,
            .operator_range = try self.range(statement_event.operator_span),
            .right = try self.range(statement_event.right),
        };
        const index = try self.statementIndex(self.edges.items.len, at);
        try self.reserve(&self.edges, at);
        try self.reserve(&self.order, at);
        self.edges.appendAssumeCapacity(edge);
        self.order.appendAssumeCapacity(.{ .edge = index });
    }

    fn range(self: *Builder, span: location.Span) Error!location.Range {
        return toRange(span) catch |err| {
            self.failure_info = .{ .span = span, .capacity = .{
                .resource = .source_range,
                .limit = std.math.maxInt(u32),
            } };
            return err;
        };
    }

    fn statementIndex(self: *Builder, length: usize, at: location.Span) Error!Index {
        return checkedIndex(length) catch |err| {
            self.failure_info = .{ .span = at, .capacity = .{
                .resource = .statement_index,
                .limit = std.math.maxInt(Index),
            } };
            return err;
        };
    }

    fn reserve(self: *Builder, list: anytype, at: location.Span) Error!void {
        list.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.failure_info = .{ .span = at, .capacity = null };
            return err;
        };
    }

    pub fn endDocument(self: *Builder) Error!void {
        std.debug.assert(self.phase == .building);
        self.phase = .committed;
    }

    pub fn abortDocument(self: *Builder, reason: syntax_event.AbortReason) void {
        _ = reason;
        // Release staged state (the event contract's abort semantics).
        // Terminal until `reset`; the lists stay valid so `deinit` is safe.
        self.order.clearAndFree(self.allocator);
        self.nodes.clearAndFree(self.allocator);
        self.edges.clearAndFree(self.allocator);
        self.phase = .terminal;
    }
};

/// What a storage failure was about, recorded by the builders so the
/// façade can emit a precise WDP diagnostic (which pool, what limit, where).
pub const StorageFailureInfo = struct {
    /// Source position of the event that could not be stored.
    span: location.Span,
    /// The exhausted capacity, when the failure is a limit rather than
    /// allocator memory.
    capacity: ?diagnostic.Capacity,
};

fn toRange(span: location.Span) error{SourceOffsetOverflow}!location.Range {
    return location.Range.fromSpan(span) orelse error.SourceOffsetOverflow;
}

fn checkedIndex(length: usize) error{StatementIndexOverflow}!Index {
    if (length > std.math.maxInt(Index)) return error.StatementIndexOverflow;
    return @intCast(length);
}

pub const Capacities = struct {
    statements: usize = 0,
    nodes: usize = 0,
    edges: usize = 0,
};

/// Caller-provided pools for allocation-free document building
/// (R-MEM-003). Any memory works: static arrays, stack buffers, or a
/// carved-up region — capacity is visible at the declaration site, nothing
/// grows, and failure is deterministic.
pub const DocumentStorage = struct {
    statement_ids: []StatementId,
    nodes: []NodeStatement,
    edges: []EdgeStatement,
};

/// Comptime sugar over `DocumentStorage`: a struct that owns the pools.
///
/// The capacity is committed eagerly: the pools are inline arrays, so the
/// declared variable occupies the full capacity wherever it lives (stack,
/// static, or heap via `allocator.create`). Budget with `byte_size`.
pub fn FixedDocumentStorage(comptime capacities: Capacities) type {
    comptime {
        for ([_]usize{ capacities.statements, capacities.nodes, capacities.edges }) |capacity| {
            if (capacity > std.math.maxInt(Index)) {
                @compileError("FixedDocumentStorage: capacity exceeds the statement index width (" ++
                    @typeName(Index) ++ ")");
            }
        }
    }
    return struct {
        /// Total bytes this storage occupies — for comptime RAM budgeting,
        /// e.g. `comptime assert(Storage.byte_size <= ram_budget)`.
        pub const byte_size = @sizeOf(@This());

        statement_ids: [capacities.statements]StatementId = undefined,
        nodes: [capacities.nodes]NodeStatement = undefined,
        edges: [capacities.edges]EdgeStatement = undefined,

        pub fn storage(self: *@This()) DocumentStorage {
            return .{
                .statement_ids = &self.statement_ids,
                .nodes = &self.nodes,
                .edges = &self.edges,
            };
        }
    };
}

/// Event-sink twin of `Builder` that writes into caller-provided fixed
/// pools: no allocator interface, nothing grows, and the handoff is
/// infallible. Same parser, same event contract — only the storage policy
/// differs (R-ARCH-001: one engine).
///
/// Lifecycle mirrors `Builder`: terminal after abort or `toDocument`,
/// `reset(source)` rebinds for the next document reusing the same pools.
pub const FixedBuilder = struct {
    source: []const u8,
    storage: DocumentStorage,
    kind: GraphKind = .undigraph,
    strict: bool = false,
    keyword: location.Range = .{ .start = 0, .len = 0 },
    name: ?location.Range = null,
    order_len: usize = 0,
    nodes_len: usize = 0,
    edges_len: usize = 0,
    phase: Phase = .idle,
    /// Set when a sink method fails; read by the façade to emit a precise
    /// storage diagnostic naming the exhausted pool.
    failure_info: ?StorageFailureInfo = null,

    pub const Error = error{
        /// A caller-provided pool filled up.
        PoolExhausted,
        /// A source position beyond the 4 GiB retained-range limit.
        SourceOffsetOverflow,
        /// More statements of one kind than `Index` can address.
        StatementIndexOverflow,
    };

    const Phase = enum { idle, building, committed, terminal };

    pub fn init(source: []const u8, storage: DocumentStorage) FixedBuilder {
        return .{ .source = source, .storage = storage };
    }

    /// Rebind for the next document; the pools are reused in place.
    pub fn reset(self: *FixedBuilder, source: []const u8) void {
        self.source = source;
        self.failure_info = null;
        self.order_len = 0;
        self.nodes_len = 0;
        self.edges_len = 0;
        self.phase = .idle;
    }

    /// Infallible handoff: the document views the filled prefixes of the
    /// caller's pools. Terminal until `reset`. Do NOT call
    /// `Document.deinit` on the result — the memory belongs to the caller;
    /// release it by reusing or discarding the storage.
    pub fn toDocument(self: *FixedBuilder) Document {
        std.debug.assert(self.phase == .committed);
        self.phase = .terminal;
        return .{
            .source = self.source,
            .kind = self.kind,
            .strict = self.strict,
            .keyword = self.keyword,
            .name = self.name,
            .order = self.storage.statement_ids[0..self.order_len],
            .nodes = self.storage.nodes[0..self.nodes_len],
            .edges = self.storage.edges[0..self.edges_len],
        };
    }

    // --- syntax-event sink contract -------------------------------------

    pub fn beginDocument(self: *FixedBuilder, event: syntax_event.BeginDocument) Error!void {
        std.debug.assert(self.phase == .idle);
        self.phase = .building;
        self.kind = event.kind;
        self.strict = event.strict;
        self.keyword = try self.range(event.keyword_span);
        self.name = if (event.name_span) |name_span| try self.range(name_span) else null;
    }

    fn range(self: *FixedBuilder, span: location.Span) Error!location.Range {
        return toRange(span) catch |err| {
            self.failure_info = .{ .span = span, .capacity = .{
                .resource = .source_range,
                .limit = std.math.maxInt(u32),
            } };
            return err;
        };
    }

    fn statementIndex(self: *FixedBuilder, length: usize, at: location.Span) Error!Index {
        return checkedIndex(length) catch |err| {
            self.failure_info = .{ .span = at, .capacity = .{
                .resource = .statement_index,
                .limit = std.math.maxInt(Index),
            } };
            return err;
        };
    }

    fn checkPool(
        self: *FixedBuilder,
        length: usize,
        pool_capacity: usize,
        resource: diagnostic.Capacity.Resource,
        at: location.Span,
    ) Error!void {
        if (length >= pool_capacity) {
            self.failure_info = .{ .span = at, .capacity = .{
                .resource = resource,
                .limit = pool_capacity,
            } };
            return error.PoolExhausted;
        }
    }

    pub fn nodeStatement(self: *FixedBuilder, statement_event: syntax_event.NodeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const at = statement_event.identifier;
        const node: NodeStatement = .{
            .identifier = try self.range(statement_event.identifier),
        };
        try self.checkPool(self.nodes_len, self.storage.nodes.len, .node_pool, at);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, at);
        const index = try self.statementIndex(self.nodes_len, at);
        self.storage.nodes[self.nodes_len] = node;
        self.nodes_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .node = index };
        self.order_len += 1;
    }

    pub fn edgeStatement(self: *FixedBuilder, statement_event: syntax_event.EdgeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const at = statement_event.left;
        const edge: EdgeStatement = .{
            .left = try self.range(statement_event.left),
            .operator = statement_event.operator,
            .operator_range = try self.range(statement_event.operator_span),
            .right = try self.range(statement_event.right),
        };
        try self.checkPool(self.edges_len, self.storage.edges.len, .edge_pool, at);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, at);
        const index = try self.statementIndex(self.edges_len, at);
        self.storage.edges[self.edges_len] = edge;
        self.edges_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .edge = index };
        self.order_len += 1;
    }

    pub fn endDocument(self: *FixedBuilder) Error!void {
        std.debug.assert(self.phase == .building);
        self.phase = .committed;
    }

    pub fn abortDocument(self: *FixedBuilder, reason: syntax_event.AbortReason) void {
        _ = reason;
        // Nothing to free — the pools are the caller's. Lengths reset so no
        // stale view escapes; terminal until `reset`.
        self.order_len = 0;
        self.nodes_len = 0;
        self.edges_len = 0;
        self.phase = .terminal;
    }
};

comptime {
    syntax_event.assertSyntaxSink(Builder);
    syntax_event.assertSyntaxSink(FixedBuilder);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// Test-only import: unit tests below drive the builder directly through the
// event contract; the end-to-end tests drive it through the parser exactly
// like the future façade will.
const parser = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");

fn parseIntoDocument(allocator: std.mem.Allocator, source: []const u8) !Document {
    var builder = Builder.init(allocator, source);
    defer builder.deinit();
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});
    if (result.outcome != .success) return error.ParseFailed;
    return builder.toDocument();
}

test "document preserves statement order, kinds, and borrowed ranges" {
    const source = "graph { a; a -- b; b; c -> d; }";
    var document = try parseIntoDocument(std.testing.allocator, source);
    defer deinitOwnedDocument(&document, std.testing.allocator);

    try expectEqual(GraphKind.undigraph, document.kind);
    try expectEqualStrings("graph", document.keyword.slice(source));
    try expectEqual(@as(usize, 4), document.statementCount());
    try expectEqual(@as(usize, 2), document.nodes.len);
    try expectEqual(@as(usize, 2), document.edges.len);

    // Source order is preserved across the pools.
    try expect(document.order[0] == .node);
    try expect(document.order[1] == .edge);
    try expect(document.order[2] == .node);
    try expect(document.order[3] == .edge);

    const first = document.statementAt(0).?.node;
    try expectEqualStrings("a", first.identifier.slice(source));
    try expectEqualStrings("a", document.text(first.identifier));
    try expectEqualStrings(source, document.source);

    const edge = document.statementAt(1).?.edge;
    try expectEqual(EdgeOperator.undirected, edge.operator);
    try expectEqualStrings("a", edge.left.slice(source));
    try expectEqualStrings("--", edge.operator_range.slice(source));
    try expectEqualStrings("b", edge.right.slice(source));

    // The written `->` is preserved for validation to inspect.
    const directed = document.statementAt(3).?.edge;
    try expectEqual(EdgeOperator.directed, directed.operator);

    // Ranges borrow the original buffer — no copies (R-MEM-004).
    try expect(first.identifier.slice(source).ptr == source.ptr + 8);

    // Positions are derived on demand, not stored (R-MEM-008).
    const operator_span = edge.operator_range.toSpan(source);
    try expectEqual(@as(usize, 1), operator_span.start.line);
    try expectEqual(@as(usize, 14), operator_span.start.byte_column);
}

test "statement lookups are bounds-checked against foreign ids" {
    var document = try parseIntoDocument(std.testing.allocator, "graph { a; }");
    defer deinitOwnedDocument(&document, std.testing.allocator);

    try expect(document.statement(.{ .node = 0 }) != null);
    try expectEqual(@as(?Statement, null), document.statement(.{ .node = 1 }));
    try expectEqual(@as(?Statement, null), document.statement(.{ .edge = 0 }));
    try expectEqual(
        @as(?Statement, null),
        document.statement(.{ .node = std.math.maxInt(Index) }),
    );
    try expect(document.statementAt(0) != null);
    try expectEqual(@as(?Statement, null), document.statementAt(1));
}

test "empty document builds an empty document" {
    var document = try parseIntoDocument(std.testing.allocator, "graph { }");
    defer deinitOwnedDocument(&document, std.testing.allocator);
    try expectEqual(@as(usize, 0), document.statementCount());
    try expectEqual(@as(usize, 0), document.nodes.len);
    try expectEqual(@as(usize, 0), document.edges.len);
}

test "document outlives the builder and the parser state" {
    const source = "graph { x; }";
    var document = blk: {
        // Builder and parser state die inside this block.
        var builder = Builder.init(std.testing.allocator, source);
        defer builder.deinit();
        var bag: diagnostic.FixedBag(4) = .{};
        const result = parser.parse(source, &builder, bag.sink(), .{});
        try expect(result.outcome == .success);
        break :blk try builder.toDocument();
    };
    defer deinitOwnedDocument(&document, std.testing.allocator);

    try expectEqualStrings("x", document.statementAt(0).?.node.identifier.slice(source));
}

test "fixed buffer with exact capacities allocates nothing after init" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const source = "graph { a; a -- b; b; }";
    var builder = try Builder.initCapacity(fba.allocator(), source, .{
        .statements = 3,
        .nodes = 2,
        .edges = 1,
    });
    defer builder.deinit();
    const high_water = fba.end_index;

    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});
    try expect(result.outcome == .success);

    var document = try builder.toDocument();
    try expectEqual(@as(usize, 3), document.statementCount());
    try expectEqual(@as(usize, 2), document.nodes.len);

    // Proof, not demonstration: parsing and handoff allocated zero bytes
    // beyond the preallocated pools.
    try expectEqual(high_water, fba.end_index);

    // Bulk release for fixed buffers: reset the whole allocator (R-MEM-005).
    fba.reset();
}

test "undersized fixed buffer aborts the parse with a sink failure" {
    var buffer: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const source = "graph { a; b; c; d; e; f; g; h; i; j; k; }";
    var builder = Builder.init(fba.allocator(), source);
    defer builder.deinit();
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});

    try expect(result.outcome == .sink_failure);
    try expectEqual(anyerror.OutOfMemory, result.outcome.sink_failure);
    // The abort released staged storage; the builder is terminal until reset.
    try expectEqual(@as(usize, 0), builder.order.items.len);
    try expect(builder.phase == .terminal);
}

test "allocation failure at every point aborts cleanly without leaks" {
    const source = "graph \"G\"+\"raph\" { \"a\"; \"a\" -- 1; 1; \"c\" -> \"d\"; }";
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var builder = Builder.init(failing.allocator(), source);
        defer builder.deinit();
        var bag: diagnostic.FixedBag(4) = .{};
        const result = parser.parse(source, &builder, bag.sink(), .{});

        if (result.outcome == .success) {
            // toDocument may itself hit the failure injection; both paths are fine.
            if (builder.toDocument()) |document| {
                var owned = document;
                defer deinitOwnedDocument(&owned, failing.allocator());
                try expectEqual(@as(usize, 4), owned.statementCount());
                return; // full success reached; earlier indices covered failures
            } else |err| {
                try expectEqual(Builder.Error.OutOfMemory, err);
                try expect(builder.phase == .terminal);
                try expectEqual(@as(usize, 0), builder.order.items.len);
            }
        } else {
            try expect(result.outcome == .sink_failure);
            try expect(builder.phase == .terminal);
        }
        // std.testing.allocator fails the test on any leak.
    }
    return error.TestUnexpectedResult; // never reached full success
}

test "toDocument failure is terminal, complete, and recoverable via reset" {
    const source = "graph { a; a -- b; }";
    var fail_index: usize = 0;
    var observed_transfer_failure = false;
    while (fail_index < 64) : (fail_index += 1) {
        // All in-place resizes fail, so every toOwnedSlice must take the
        // allocate-and-copy path — sweeping fail_index therefore fails each
        // of the three transfers in turn, including mid-handoff (the P0
        // partial-transfer scenario).
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index, .resize_fail_index = 0 },
        );
        var builder = Builder.init(failing.allocator(), source);
        defer builder.deinit();
        var bag: diagnostic.FixedBag(4) = .{};
        const result = parser.parse(source, &builder, bag.sink(), .{});
        if (result.outcome != .success) continue;

        if (builder.toDocument()) |document| {
            var owned = document;
            deinitOwnedDocument(&owned, failing.allocator());
        } else |_| {
            observed_transfer_failure = true;
            // Never a half-consumed committed builder.
            try expect(builder.phase == .terminal);
            try expectEqual(@as(usize, 0), builder.order.items.len);
            try expectEqual(@as(usize, 0), builder.nodes.items.len);
            try expectEqual(@as(usize, 0), builder.edges.items.len);

            // Reset restores a genuinely reusable builder.
            builder.reset(source);
            try expect(builder.phase == .idle);
        }
    }
    try expect(observed_transfer_failure);
}

test "aborted builder is reusable after reset" {
    const bad_source = "graph { a; b; @ }";
    var builder = Builder.init(std.testing.allocator, bad_source);
    defer builder.deinit();
    var bag: diagnostic.FixedBag(4) = .{};

    // Invalid document: statements staged, then aborted (terminal).
    const failed = parser.parse(bad_source, &builder, bag.sink(), .{});
    try expect(failed.outcome == .invalid_syntax);
    try expect(builder.phase == .terminal);
    try expectEqual(@as(usize, 0), builder.order.items.len);

    // Rebind to a second document with the same builder.
    const source = "graph { ok; }";
    builder.reset(source);
    bag.reset();
    const succeeded = parser.parse(source, &builder, bag.sink(), .{});
    try expect(succeeded.outcome == .success);

    var document = try builder.toDocument();
    defer deinitOwnedDocument(&document, std.testing.allocator);
    try expectEqualStrings("ok", document.statementAt(0).?.node.identifier.slice(source));
}

test "builder is reusable after toDocument via reset" {
    const first_source = "graph { a; }";
    var builder = Builder.init(std.testing.allocator, first_source);
    defer builder.deinit();

    var bag: diagnostic.FixedBag(4) = .{};
    try expect(parser.parse(first_source, &builder, bag.sink(), .{}).outcome == .success);
    var first = try builder.toDocument();
    defer deinitOwnedDocument(&first, std.testing.allocator);

    const second_source = "graph { b; c; }";
    builder.reset(second_source);
    try expect(parser.parse(second_source, &builder, bag.sink(), .{}).outcome == .success);
    var second = try builder.toDocument();
    defer deinitOwnedDocument(&second, std.testing.allocator);

    try expectEqual(@as(usize, 1), first.statementCount());
    try expectEqual(@as(usize, 2), second.statementCount());
    try expectEqualStrings("a", first.statementAt(0).?.node.identifier.slice(first_source));
    try expectEqualStrings("c", second.statementAt(1).?.node.identifier.slice(second_source));
}

test "fixed builder parses into caller pools with no allocator" {
    const source = "graph { a; a -- b; }";
    var ids: [2]StatementId = undefined;
    var nodes: [1]NodeStatement = undefined;
    var edges: [1]EdgeStatement = undefined;

    var builder = FixedBuilder.init(source, .{
        .statement_ids = &ids,
        .nodes = &nodes,
        .edges = &edges,
    });
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});
    try expect(result.outcome == .success);

    const document = builder.toDocument();
    try expectEqual(@as(usize, 2), document.statementCount());
    try expectEqualStrings("a", document.text(document.statementAt(0).?.node.identifier));
    const edge = document.statementAt(1).?.edge;
    try expectEqual(EdgeOperator.undirected, edge.operator);
    try expectEqualStrings("b", document.text(edge.right));

    // The document views the caller's pools directly — no copies.
    try expect(document.nodes.ptr == &nodes);
    try expect(document.edges.ptr == &edges);
}

test "fixed builder reports pool exhaustion deterministically" {
    const source = "graph { a; b; c; }";
    var ids: [2]StatementId = undefined;
    var nodes: [2]NodeStatement = undefined;
    var edges: [1]EdgeStatement = undefined;

    var builder = FixedBuilder.init(source, .{
        .statement_ids = &ids,
        .nodes = &nodes,
        .edges = &edges,
    });
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});

    try expect(result.outcome == .sink_failure);
    try expectEqual(anyerror.PoolExhausted, result.outcome.sink_failure);
    try expect(builder.phase == .terminal);

    // Reset reuses the same pools for a document that fits.
    const retry_source = "graph { x; y; }";
    builder.reset(retry_source);
    bag.reset();
    try expect(parser.parse(retry_source, &builder, bag.sink(), .{}).outcome == .success);
    const document = builder.toDocument();
    try expectEqual(@as(usize, 2), document.statementCount());
}

test "fixed document storage sugar owns the pools" {
    const source = "graph { a -- b; }";
    var storage: FixedDocumentStorage(.{ .statements = 4, .nodes = 4, .edges = 4 }) = .{};

    var builder = FixedBuilder.init(source, storage.storage());
    var bag: diagnostic.FixedBag(4) = .{};
    try expect(parser.parse(source, &builder, bag.sink(), .{}).outcome == .success);
    const document = builder.toDocument();
    try expectEqualStrings("--", document.text(document.statementAt(0).?.edge.operator_range));
}

test "fixed document storage exposes its comptime byte size" {
    const Storage = FixedDocumentStorage(.{ .statements = 32, .nodes = 32, .edges = 16 });
    try expectEqual(@sizeOf(Storage), Storage.byte_size);
    try expect(Storage.byte_size >= 32 * @sizeOf(StatementId) +
        32 * @sizeOf(NodeStatement) + 16 * @sizeOf(EdgeStatement));
}

test "statement iterator walks source order" {
    const source = "graph { a; a -- b; b; }";
    var document = try parseIntoDocument(std.testing.allocator, source);
    defer deinitOwnedDocument(&document, std.testing.allocator);

    var iterator = document.statements();
    try expectEqualStrings("a", document.text(iterator.next().?.node.identifier));
    try expect(iterator.next().? == .edge);
    try expectEqualStrings("b", document.text(iterator.next().?.node.identifier));
    try expectEqual(@as(?Statement, null), iterator.next());
}

test "builder driven directly through the event contract" {
    const source = "graph { n; }";
    var builder = Builder.init(std.testing.allocator, source);
    defer builder.deinit();

    try builder.beginDocument(.{
        .kind = .undigraph,
        .keyword_span = .{ .start = .start, .byte_len = 5 },
    });
    try builder.nodeStatement(.{ .identifier = .{
        .start = .{ .byte_offset = 8, .line = 1, .byte_column = 9 },
        .byte_len = 1,
    } });
    try builder.endDocument();

    var document = try builder.toDocument();
    defer deinitOwnedDocument(&document, std.testing.allocator);
    try expectEqual(@as(usize, 1), document.statementCount());
    try expectEqualStrings("n", document.statementAt(0).?.node.identifier.slice(source));
}
