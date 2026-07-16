//! Borrowed, index-based syntax tree and its builder (milestone 1, step 6).
//!
//! The tree is the retained, source-shaped representation: statements in
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
//!   `Range.toSpan`) by whoever emits a diagnostic; the retained tree never
//!   pays for positions it may never need (R-MEM-008). The tree therefore
//!   has its own statement types rather than aliasing the event protocol's
//!   span-carrying ones.
//!
//! ## Memory model (R-MEM-001/002/005)
//!
//! Explicit allocator, no hidden allocation. The tree is mid-term data:
//! build it with an arena or fixed buffer and release it in bulk — `deinit`
//! is three frees, never a per-node walk; arena users may skip `deinit` and
//! reset the arena. The source bytes are caller-owned and must outlive the
//! tree (borrowed ranges, R-MEM-004).
//!
//! `Builder.initCapacity` preallocates the pools once; with sufficient
//! capacities the build performs no further allocation and `toTree` is
//! copy-free — the intended mode for `FixedBufferAllocator` users, whose
//! allocator cannot grow interleaved allocations in place.

const std = @import("std");
const location = @import("location.zig");
const syntax_event = @import("syntax_event.zig");

pub const GraphKind = syntax_event.GraphKind;
pub const EdgeOperator = syntax_event.EdgeOperator;

/// Statement index width. One declaration so profiles can shrink it for
/// small targets (R-MEM-006); overflow is checked in the builder.
pub const Index = u32;

/// A statement's identity: which pool, and where in it. Publicly
/// constructible, so `Tree.statement` bounds-checks rather than trusting it.
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

/// The frozen, borrowed syntax tree of one committed document. Immutable
/// after `Builder.toTree`; safe to read concurrently while its memory and
/// the borrowed source stay alive (R-CON-003).
pub const Tree = struct {
    /// The borrowed source this tree was parsed from; every range below
    /// indexes it. Caller-owned and must outlive the tree (R-MEM-004).
    /// Storing it here makes tree/source pairings unforgeable for consumers
    /// such as validation.
    source: []const u8,
    kind: GraphKind,
    /// Range of the document keyword that declared the kind.
    keyword: location.Range,
    /// Statement identities in source order.
    order: []const StatementId,
    /// Node-statement pool, in source order.
    nodes: []const NodeStatement,
    /// Edge-statement pool, in source order.
    edges: []const EdgeStatement,

    pub fn statementCount(self: *const Tree) usize {
        return self.order.len;
    }

    /// Bounds-checked lookup: null for an id that does not name a statement
    /// of this tree (ids are publicly constructible).
    pub fn statement(self: *const Tree, id: StatementId) ?Statement {
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
    pub fn statementAt(self: *const Tree, order_index: usize) ?Statement {
        if (order_index >= self.order.len) return null;
        return self.statement(self.order[order_index]);
    }

    /// The source text a range of this tree covers.
    pub fn text(self: *const Tree, range: location.Range) []const u8 {
        return range.slice(self.source);
    }

    /// Bulk release (R-MEM-005): three frees, no per-node walk. Pass the
    /// allocator the builder used. Arena and fixed-buffer users may skip
    /// this and reset their arena/buffer instead.
    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        allocator.free(self.order);
        allocator.free(self.nodes);
        allocator.free(self.edges);
        self.* = undefined;
    }
};

/// The first consumer of the private syntax-event contract: builds a `Tree`
/// from parser events using explicit caller memory.
///
/// ## Lifecycle
///
/// ```text
/// idle --beginDocument--> building --endDocument--> committed
///                            │                          │
///                            │ abortDocument            │ toTree (ok or error)
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
/// - `toTree` consumes the committed document **even on error**: a failed
///   transfer releases everything; a retry can never observe a partial
///   tree.
/// - Contract-order violations are programmer errors and assert in safe
///   builds.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    /// The source the parsed document borrows from; embedded into the tree.
    source: []const u8,
    kind: GraphKind = .undigraph,
    keyword: location.Range = .{ .start = 0, .len = 0 },
    order: std.ArrayList(StatementId) = .empty,
    nodes: std.ArrayList(NodeStatement) = .empty,
    edges: std.ArrayList(EdgeStatement) = .empty,
    phase: Phase = .idle,

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

    pub const Capacities = struct {
        statements: usize = 0,
        nodes: usize = 0,
        edges: usize = 0,
    };

    /// Preallocate the pools once. With capacities that cover the document,
    /// the build performs no further allocation and `toTree` is copy-free —
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
        self.order.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
        self.phase = .idle;
    }

    /// Take ownership of the finished tree. Valid once per committed
    /// document; the builder is terminal afterwards (on success *and* on
    /// error — a failed transfer releases everything and never leaves a
    /// partially consumed committed builder). `reset` restores reuse.
    pub fn toTree(self: *Builder) Error!Tree {
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
            .keyword = self.keyword,
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
        self.keyword = try toRange(event.keyword_span);
    }

    pub fn nodeStatement(self: *Builder, statement_event: syntax_event.NodeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const node: NodeStatement = .{
            .identifier = try toRange(statement_event.identifier),
        };
        const index = try checkedIndex(self.nodes.items.len);
        // Reserve both slots first so the two appends cannot desynchronize.
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.order.ensureUnusedCapacity(self.allocator, 1);
        self.nodes.appendAssumeCapacity(node);
        self.order.appendAssumeCapacity(.{ .node = index });
    }

    pub fn edgeStatement(self: *Builder, statement_event: syntax_event.EdgeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const edge: EdgeStatement = .{
            .left = try toRange(statement_event.left),
            .operator = statement_event.operator,
            .operator_range = try toRange(statement_event.operator_span),
            .right = try toRange(statement_event.right),
        };
        const index = try checkedIndex(self.edges.items.len);
        try self.edges.ensureUnusedCapacity(self.allocator, 1);
        try self.order.ensureUnusedCapacity(self.allocator, 1);
        self.edges.appendAssumeCapacity(edge);
        self.order.appendAssumeCapacity(.{ .edge = index });
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

    fn toRange(span: location.Span) Error!location.Range {
        return location.Range.fromSpan(span) orelse error.SourceOffsetOverflow;
    }

    fn checkedIndex(length: usize) Error!Index {
        if (length > std.math.maxInt(Index)) return error.StatementIndexOverflow;
        return @intCast(length);
    }
};

comptime {
    syntax_event.assertSyntaxSink(Builder);
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

fn parseIntoTree(allocator: std.mem.Allocator, source: []const u8) !Tree {
    var builder = Builder.init(allocator, source);
    defer builder.deinit();
    var bag: diagnostic.FixedBag(4) = .{};
    const result = parser.parse(source, &builder, bag.sink(), .{});
    if (result.outcome != .success) return error.ParseFailed;
    return builder.toTree();
}

test "tree preserves statement order, kinds, and borrowed ranges" {
    const source = "graph { a; a -- b; b; c -> d; }";
    var tree = try parseIntoTree(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    try expectEqual(GraphKind.undigraph, tree.kind);
    try expectEqualStrings("graph", tree.keyword.slice(source));
    try expectEqual(@as(usize, 4), tree.statementCount());
    try expectEqual(@as(usize, 2), tree.nodes.len);
    try expectEqual(@as(usize, 2), tree.edges.len);

    // Source order is preserved across the pools.
    try expect(tree.order[0] == .node);
    try expect(tree.order[1] == .edge);
    try expect(tree.order[2] == .node);
    try expect(tree.order[3] == .edge);

    const first = tree.statementAt(0).?.node;
    try expectEqualStrings("a", first.identifier.slice(source));
    try expectEqualStrings("a", tree.text(first.identifier));
    try expectEqualStrings(source, tree.source);

    const edge = tree.statementAt(1).?.edge;
    try expectEqual(EdgeOperator.undirected, edge.operator);
    try expectEqualStrings("a", edge.left.slice(source));
    try expectEqualStrings("--", edge.operator_range.slice(source));
    try expectEqualStrings("b", edge.right.slice(source));

    // The written `->` is preserved for validation to inspect.
    const directed = tree.statementAt(3).?.edge;
    try expectEqual(EdgeOperator.directed, directed.operator);

    // Ranges borrow the original buffer — no copies (R-MEM-004).
    try expect(first.identifier.slice(source).ptr == source.ptr + 8);

    // Positions are derived on demand, not stored (R-MEM-008).
    const operator_span = edge.operator_range.toSpan(source);
    try expectEqual(@as(usize, 1), operator_span.start.line);
    try expectEqual(@as(usize, 14), operator_span.start.byte_column);
}

test "statement lookups are bounds-checked against foreign ids" {
    var tree = try parseIntoTree(std.testing.allocator, "graph { a; }");
    defer tree.deinit(std.testing.allocator);

    try expect(tree.statement(.{ .node = 0 }) != null);
    try expectEqual(@as(?Statement, null), tree.statement(.{ .node = 1 }));
    try expectEqual(@as(?Statement, null), tree.statement(.{ .edge = 0 }));
    try expectEqual(
        @as(?Statement, null),
        tree.statement(.{ .node = std.math.maxInt(Index) }),
    );
    try expect(tree.statementAt(0) != null);
    try expectEqual(@as(?Statement, null), tree.statementAt(1));
}

test "empty document builds an empty tree" {
    var tree = try parseIntoTree(std.testing.allocator, "graph { }");
    defer tree.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 0), tree.statementCount());
    try expectEqual(@as(usize, 0), tree.nodes.len);
    try expectEqual(@as(usize, 0), tree.edges.len);
}

test "tree outlives the builder and the parser state" {
    const source = "graph { x; }";
    var tree = blk: {
        // Builder and parser state die inside this block.
        var builder = Builder.init(std.testing.allocator, source);
        defer builder.deinit();
        var bag: diagnostic.FixedBag(4) = .{};
        const result = parser.parse(source, &builder, bag.sink(), .{});
        try expect(result.outcome == .success);
        break :blk try builder.toTree();
    };
    defer tree.deinit(std.testing.allocator);

    try expectEqualStrings("x", tree.statementAt(0).?.node.identifier.slice(source));
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

    var tree = try builder.toTree();
    try expectEqual(@as(usize, 3), tree.statementCount());
    try expectEqual(@as(usize, 2), tree.nodes.len);

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
    const source = "graph { a; a -- b; b; c -> d; }";
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
            // toTree may itself hit the failure injection; both paths are fine.
            if (builder.toTree()) |tree| {
                var owned = tree;
                defer owned.deinit(failing.allocator());
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

test "toTree failure is terminal, complete, and recoverable via reset" {
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

        if (builder.toTree()) |tree| {
            var owned = tree;
            owned.deinit(failing.allocator());
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

    var tree = try builder.toTree();
    defer tree.deinit(std.testing.allocator);
    try expectEqualStrings("ok", tree.statementAt(0).?.node.identifier.slice(source));
}

test "builder is reusable after toTree via reset" {
    const first_source = "graph { a; }";
    var builder = Builder.init(std.testing.allocator, first_source);
    defer builder.deinit();

    var bag: diagnostic.FixedBag(4) = .{};
    try expect(parser.parse(first_source, &builder, bag.sink(), .{}).outcome == .success);
    var first = try builder.toTree();
    defer first.deinit(std.testing.allocator);

    const second_source = "graph { b; c; }";
    builder.reset(second_source);
    try expect(parser.parse(second_source, &builder, bag.sink(), .{}).outcome == .success);
    var second = try builder.toTree();
    defer second.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 1), first.statementCount());
    try expectEqual(@as(usize, 2), second.statementCount());
    try expectEqualStrings("a", first.statementAt(0).?.node.identifier.slice(first_source));
    try expectEqualStrings("c", second.statementAt(1).?.node.identifier.slice(second_source));
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

    var tree = try builder.toTree();
    defer tree.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 1), tree.statementCount());
    try expectEqualStrings("n", tree.statementAt(0).?.node.identifier.slice(source));
}
