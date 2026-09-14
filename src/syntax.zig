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
//! - `nodes`, `edges`, `assignments`, and `attribute_statements` are dense
//!   per-kind pools in source order, with a shared ordered `attributes` pool, so
//!   per-kind consumers can touch only their relevant records,
//! - chains have separate owner/link pools; ordinary edges retain their size,
//! - node references inline bare ranges or index the qualified-occurrence pool,
//! - scope records retain parent IDs and body intervals, never copied descendants,
//! - `order` records all statements in source preorder as compact typed indices,
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
//! is twelve pool releases, never a per-node walk; arena users may skip `deinit` and
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
    subgraph: Index,
    edge: Index,
    edge_chain: Index,
    scoped_edge: Index,
    assignment: Index,
    attribute_statement: Index,
};

pub const AttributeTarget = syntax_event.AttributeTarget;

/// Ordered key/value spelling. No defaults, deduplication, or interpretation.
pub const Attribute = struct {
    key: location.Range,
    value: location.Range,
};
pub const Assignment = Attribute;

/// Compact slice of Document.attributes (element indices, not source bytes).
pub const AttributeRange = struct {
    start: Index = 0,
    len: Index = 0,
};

pub const AttributeStatement = struct {
    target: AttributeTarget,
    keyword: location.Range,
    attributes: AttributeRange = .{},
};

/// Compact inline identifier range or index into Document.ported_references.
/// Treat the encoding as opaque. Zero raw_len marks a pooled occurrence; even
/// an empty quoted identifier has a nonzero raw spelling length.
pub const NodeReference = struct {
    index_or_start: Index,
    raw_len: u32,

    pub fn fromRange(range: location.Range) ?NodeReference {
        if (range.len == 0) return null;
        return .{ .index_or_start = range.start, .raw_len = range.len };
    }

    fn pooled(index: Index) NodeReference {
        return .{ .index_or_start = index, .raw_len = 0 };
    }
};

/// Raw suffix components, not resolved ports or compass directions.
pub const PortSyntax = struct {
    first: location.Range,
    second: ?location.Range = null,
};

/// One written qualified occurrence, not an interned node or port declaration.
pub const PortedReference = struct {
    identifier: location.Range,
    port: PortSyntax,
};

pub const NodeReferenceView = struct {
    identifier: location.Range,
    port: ?PortSyntax = null,
};

pub const NodeStatement = struct {
    reference: NodeReference,
    attributes: AttributeRange = .{},
};

pub const EdgeStatement = struct {
    left: NodeReference,
    operator: EdgeOperator,
    operator_range: location.Range,
    right: NodeReference,
    attributes: AttributeRange = .{},
};

/// A continuation after the first edge; its left endpoint is the preceding right.
pub const EdgeLink = struct {
    operator: EdgeOperator,
    operator_range: location.Range,
    right: NodeReference,
};

pub const EdgeLinkRange = struct { start: Index = 0, len: Index = 0 };

/// One source statement, never an eagerly expanded list of edge statements.
/// Attributes on first apply to the entire chain. links excludes the first edge.
pub const EdgeChainStatement = struct {
    first: EdgeStatement,
    links: EdgeLinkRange,
};

/// Uniform syntax endpoint. A subgraph is a scope occurrence, not a node set.
pub const Endpoint = union(enum) { node: NodeReference, subgraph: ScopeId };
pub const EdgeView = struct {
    left: Endpoint,
    operator: EdgeOperator,
    operator_range: location.Range,
    right: Endpoint,
    attributes: AttributeRange = .{},
    fn fromNode(edge: EdgeStatement) EdgeView {
        return .{ .left = .{ .node = edge.left }, .right = .{ .node = edge.right }, .operator = edge.operator, .operator_range = edge.operator_range, .attributes = edge.attributes };
    }
};
pub const EdgeLinkSource = union(enum) { nodes: EdgeLinkRange, scoped: Index };
pub const EdgeChainView = struct { first: EdgeView, links: EdgeLinkSource };
const no_link = std.math.maxInt(Index);
/// Only statements involving a subgraph pay for generalized storage.
/// A node-only prefix remains in its original pool; promotion never copies it.
pub const ScopedEdgeStatement = struct {
    first: EdgeView,
    prefix: EdgeLinkRange = .{},
    first_link: Index = no_link,
    last_link: Index = no_link,
    link_count: Index = 0,
};
pub const ScopedEdgeLink = struct {
    left: Endpoint,
    right: Endpoint,
    operator: EdgeOperator,
    operator_range: location.Range,
    owner: Index,
    next: Index = no_link,
};

/// A by-value view of one statement, for order-preserving traversal.
pub const Statement = union(enum) {
    node: NodeStatement,
    subgraph: ScopeId,
    edge: EdgeView,
    edge_chain: EdgeChainView,
    assignment: Assignment,
    attribute_statement: AttributeStatement,
};

pub const ScopeId = enum(Index) { root = 0, _ };
pub const Traversal = enum { direct, recursive };
pub const StatementRange = struct { start: Index, len: Index };

/// One written subgraph. IDs are document-local occurrences, never name hashes.
pub const Subgraph = struct {
    parent: ScopeId,
    name: ?location.Range,
    body: StatementRange,
    source: location.Range,
    subtree_end: Index = 0,
};

/// A borrowed view, not an independently owned graph or resolved membership set.
pub const ScopeView = struct {
    document: *const Document,
    id: ScopeId,

    pub fn parent(self: ScopeView) ?ScopeId {
        return if (self.id == .root) null else self.record().parent;
    }
    pub fn name(self: ScopeView) ?location.Range {
        return if (self.id == .root) self.document.name else self.record().name;
    }
    pub fn sourceRange(self: ScopeView) ?location.Range {
        return if (self.id == .root) location.Range.fromSpan(.{ .start = .start, .byte_len = self.document.source.len }) else self.record().source;
    }
    fn record(self: ScopeView) Subgraph {
        return self.document.subgraph_records[@intFromEnum(self.id) - 1];
    }
    pub fn statements(self: ScopeView, traversal: Traversal) ScopedStatementIterator {
        const body = if (self.id == .root) StatementRange{ .start = 0, .len = @intCast(self.document.order.len) } else self.record().body;
        return .{ .document = self.document, .index = body.start, .end = @as(usize, body.start) + body.len, .traversal = traversal, .scope_cursor = @intFromEnum(self.id), .scope_end = if (self.id == .root) self.document.subgraph_records.len else self.record().subtree_end };
    }
    pub fn subgraphs(self: ScopeView, traversal: Traversal) ChildScopeIterator {
        return .{ .document = self.document, .index = @intFromEnum(self.id), .end = if (self.id == .root) self.document.subgraph_records.len else self.record().subtree_end, .traversal = traversal };
    }
    pub fn edges(self: ScopeView, traversal: Traversal) ScopedEdgeIterator {
        const start = if (self.id == .root) 0 else self.record().source.start;
        const end = if (self.id == .root) self.document.source.len else @as(usize, self.record().source.start) + self.record().source.len;
        var edges_it = self.document.edgeIterator();
        edges_it.seek(start);
        return .{ .edges = edges_it, .scope_id = self.id, .current_scope = self.id, .scope_cursor = @intFromEnum(self.id), .end = end, .traversal = traversal };
    }
    /// Written references, including edge-only nodes. Duplicates remain; a chain
    /// middle is visited once. This is not resolved node membership.
    pub fn nodeReferences(self: ScopeView, traversal: Traversal) NodeReferenceIterator {
        return .{ .statements = self.statements(traversal) };
    }
};

pub const SubgraphIterator = struct {
    document: *const Document,
    index: usize = 0,
    pub fn next(self: *SubgraphIterator) ?ScopeView {
        if (self.index == self.document.subgraph_records.len) return null;
        self.index += 1;
        return .{ .document = self.document, .id = @enumFromInt(self.index) };
    }
};

pub const ScopedStatementIterator = struct {
    document: *const Document,
    index: usize,
    end: usize,
    traversal: Traversal,
    scope_cursor: usize,
    scope_end: usize,
    pub fn next(self: *ScopedStatementIterator) ?Statement {
        if (self.traversal == .direct) {
            while (self.scope_cursor < self.scope_end) {
                const child = self.document.subgraph_records[self.scope_cursor];
                if (child.body.start > self.index) break;
                self.index = @max(self.index, @as(usize, child.body.start) + child.body.len);
                self.scope_cursor = child.subtree_end;
            }
        }
        if (self.index >= self.end) return null;
        const id = self.document.order[self.index];
        self.index += 1;
        return self.document.statement(id);
    }
};

pub const ChildScopeIterator = struct {
    document: *const Document,
    index: usize,
    end: usize,
    traversal: Traversal,
    pub fn next(self: *ChildScopeIterator) ?ScopeView {
        if (self.index >= self.end) return null;
        const id: ScopeId = @enumFromInt(self.index + 1);
        self.index = if (self.traversal == .direct) self.document.subgraph_records[self.index].subtree_end else self.index + 1;
        return self.document.scope(id);
    }
};

/// Continuations of one statement, in chain order (not descendant-body order).
pub const EdgeLinkIterator = struct {
    document: *const Document,
    nodes: []const EdgeLink = &.{},
    next_link: Index = no_link,
    left: Endpoint = undefined,
    attributes: AttributeRange = .{},
    pub fn next(self: *EdgeLinkIterator) ?EdgeView {
        if (self.nodes.len != 0) {
            const link = self.nodes[0];
            self.nodes = self.nodes[1..];
            const edge: EdgeView = .{ .left = self.left, .right = .{ .node = link.right }, .operator = link.operator, .operator_range = link.operator_range, .attributes = self.attributes };
            self.left = edge.right;
            return edge;
        }
        if (self.next_link == no_link) return null;
        const link = self.document.scoped_edge_links[self.next_link];
        self.next_link = link.next;
        return .{ .left = link.left, .right = link.right, .operator = link.operator, .operator_range = link.operator_range, .attributes = self.attributes };
    }
};

pub const ScopedEdgeIterator = struct {
    edges: EdgeIterator,
    scope_id: ScopeId,
    current_scope: ScopeId,
    scope_cursor: usize,
    end: usize,
    traversal: Traversal,
    done: bool = false,
    pub fn next(self: *ScopedEdgeIterator) ?EdgeView {
        if (self.done) return null;
        const records = self.edges.document.subgraph_records;
        while (self.edges.next()) |edge| {
            const offset = edge.operator_range.start;
            if (offset >= self.end) break;
            if (self.traversal == .recursive) return edge;
            while (self.current_scope != self.scope_id) {
                const record = records[@intFromEnum(self.current_scope) - 1];
                if (offset < @as(usize, record.source.start) + record.source.len) break;
                self.current_scope = record.parent;
            }
            while (self.scope_cursor < records.len) {
                const record = records[self.scope_cursor];
                if (record.source.start > offset) break;
                self.scope_cursor += 1;
                if (offset < @as(usize, record.source.start) + record.source.len)
                    self.current_scope = @enumFromInt(self.scope_cursor);
            }
            if (self.current_scope == self.scope_id) return edge;
        }
        self.done = true;
        return null;
    }
};

pub const NodeReferenceIterator = struct {
    statements: ScopedStatementIterator,
    pending: ?NodeReference = null,
    links: ?EdgeLinkIterator = null,
    pub fn next(self: *NodeReferenceIterator) ?NodeReference {
        if (self.pending) |reference| {
            self.pending = null;
            return reference;
        }
        if (self.links) |*links| {
            while (links.next()) |edge| if (edge.right == .node) return edge.right.node;
        }
        while (self.statements.next()) |statement| {
            switch (statement) {
                .node => |node| return node.reference,
                .edge, .edge_chain => {
                    const edge = if (statement == .edge) statement.edge else statement.edge_chain.first;
                    if (statement == .edge_chain) self.links = self.statements.document.edgeLinks(statement.edge_chain);
                    if (edge.right == .node) self.pending = edge.right.node;
                    if (edge.left == .node) return edge.left.node;
                    if (self.pending) |reference| {
                        self.pending = null;
                        return reference;
                    }
                    if (self.links) |*links| {
                        while (links.next()) |link| if (link.right == .node) return link.right.node;
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

pub const ScopedStatement = struct { id: StatementId, scope: ScopeId, statement: Statement };

pub const StatementIterator = struct {
    document: *const Document,
    index: usize = 0,
    current_scope: ScopeId = .root,
    scope_cursor: usize = 0,

    /// Includes the containing scope without per-statement retained metadata.
    /// Full traversal is O(statements + subgraphs), with no recursion.
    pub fn nextScoped(self: *StatementIterator) ?ScopedStatement {
        if (self.index == self.document.order.len) return null;
        while (self.current_scope != .root) {
            const record = self.document.subgraph_records[@intFromEnum(self.current_scope) - 1];
            if (self.index < @as(usize, record.body.start) + record.body.len) break;
            self.current_scope = record.parent;
        }
        while (self.scope_cursor < self.document.subgraph_records.len) {
            const record = self.document.subgraph_records[self.scope_cursor];
            if (record.body.start > self.index) break;
            self.scope_cursor += 1;
            if (self.index < @as(usize, record.body.start) + record.body.len)
                self.current_scope = @enumFromInt(self.scope_cursor);
        }
        const id = self.document.order[self.index];
        const result: ScopedStatement = .{ .id = id, .scope = self.current_scope, .statement = self.document.statement(id).? };
        self.index += 1;
        return result;
    }

    pub fn next(self: *StatementIterator) ?Statement {
        return if (self.nextScoped()) |item| item.statement else null;
    }
};

/// Allocation-free pairwise view. This does not create nodes or rewrite storage.
/// Chain attributes are shared by every yielded edge; order is source order.
pub const EdgeIterator = struct {
    document: *const Document,
    edge_index: usize = 0,
    chain_index: usize = 0,
    scoped_index: usize = 0,
    link_index: usize = 0,
    prefix: ?EdgeLinkIterator = null,

    fn seek(self: *EdgeIterator, offset: u32) void {
        self.edge_index = lowerBound(self.document.edges, offset);
        self.chain_index = lowerBound(self.document.edge_chains, offset);
        self.scoped_index = lowerBound(self.document.scoped_edges, offset);
        self.link_index = lowerBound(self.document.scoped_edge_links, offset);
        self.prefix = null;
    }
    fn lowerBound(pool: anytype, offset: u32) usize {
        var lo: usize = 0;
        var hi = pool.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const item = pool[mid];
            const start = if (@hasField(@TypeOf(item), "first")) item.first.operator_range.start else item.operator_range.start;
            if (start < offset) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn next(self: *EdgeIterator) ?EdgeView {
        if (self.prefix) |*prefix| if (prefix.next()) |edge| return edge;
        const d = self.document;
        const starts = [_]u64{
            if (self.edge_index < d.edges.len) d.edges[self.edge_index].operator_range.start else std.math.maxInt(u64),
            if (self.chain_index < d.edge_chains.len) d.edge_chains[self.chain_index].first.operator_range.start else std.math.maxInt(u64),
            if (self.scoped_index < d.scoped_edges.len) d.scoped_edges[self.scoped_index].first.operator_range.start else std.math.maxInt(u64),
            if (self.link_index < d.scoped_edge_links.len) d.scoped_edge_links[self.link_index].operator_range.start else std.math.maxInt(u64),
        };
        var selected: usize = 0;
        for (starts, 0..) |value, i| if (value < starts[selected]) {
            selected = i;
        };
        if (starts[selected] == std.math.maxInt(u64)) return null;
        switch (selected) {
            0 => {
                const edge = d.edges[self.edge_index];
                self.edge_index += 1;
                return EdgeView.fromNode(edge);
            },
            1 => {
                const chain = d.edge_chains[self.chain_index];
                self.chain_index += 1;
                self.prefix = .{ .document = d, .nodes = d.edgeLinkSlice(chain.links).?, .left = .{ .node = chain.first.right }, .attributes = chain.first.attributes };
                return EdgeView.fromNode(chain.first);
            },
            2 => {
                const owner = d.scoped_edges[self.scoped_index];
                self.scoped_index += 1;
                self.prefix = .{ .document = d, .nodes = d.edgeLinkSlice(owner.prefix).?, .left = owner.first.right, .attributes = owner.first.attributes };
                return owner.first;
            },
            else => {
                const link = d.scoped_edge_links[self.link_index];
                self.link_index += 1;
                return .{ .left = link.left, .right = link.right, .operator = link.operator, .operator_range = link.operator_range, .attributes = d.scoped_edges[link.owner].first.attributes };
            },
        }
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
    /// Node-only single-edge storage; use edgeIterator() for all syntactic edges.
    edges: []const EdgeStatement,
    edge_chains: []const EdgeChainStatement = &.{},
    scoped_edges: []const ScopedEdgeStatement = &.{},
    scoped_edge_links: []const ScopedEdgeLink = &.{},
    edge_links: []const EdgeLink = &.{},
    ported_references: []const PortedReference = &.{},
    subgraph_records: []const Subgraph = &.{},
    attributes: []const Attribute = &.{},
    assignments: []const Assignment = &.{},
    attribute_statements: []const AttributeStatement = &.{},

    /// O(1) checked scope lookup. Root is zero; subgraph IDs are one-based
    /// occurrences in opening/source order, independent of names.
    pub fn scope(self: *const Document, id: ScopeId) ?ScopeView {
        if (@intFromEnum(id) > self.subgraph_records.len) return null;
        return .{ .document = self, .id = id };
    }
    pub fn subgraphs(self: *const Document) SubgraphIterator {
        return .{ .document = self };
    }

    /// Resolve a compact reference without scanning source or allocating.
    /// Null for an out-of-bounds inline range or pool handle.
    pub fn nodeReference(self: *const Document, reference: NodeReference) ?NodeReferenceView {
        if (reference.raw_len == 0) {
            if (reference.index_or_start >= self.ported_references.len) return null;
            const value = self.ported_references[reference.index_or_start];
            return .{ .identifier = value.identifier, .port = value.port };
        }
        const start: usize = reference.index_or_start;
        if (start > self.source.len or reference.raw_len > self.source.len - start) return null;
        return .{ .identifier = .{ .start = reference.index_or_start, .len = reference.raw_len } };
    }

    pub fn statementCount(self: *const Document) usize {
        return self.order.len;
    }

    /// Bounds-checked lookup: null for an id that does not name a statement
    /// of this document (ids are publicly constructible).
    pub fn statement(self: *const Document, id: StatementId) ?Statement {
        return switch (id) {
            .scoped_edge => |index| if (index < self.scoped_edges.len) blk: {
                const owner = self.scoped_edges[index];
                if (owner.prefix.len == 0 and owner.first_link == no_link) break :blk Statement{ .edge = owner.first };
                break :blk Statement{ .edge_chain = .{ .first = owner.first, .links = .{ .scoped = index } } };
            } else null,
            .subgraph => |index| if (index < self.subgraph_records.len)
                Statement{ .subgraph = @enumFromInt(index + 1) }
            else
                null,
            .node => |index| if (index < self.nodes.len)
                Statement{ .node = self.nodes[index] }
            else
                null,
            .assignment => |index| if (index < self.assignments.len)
                Statement{ .assignment = self.assignments[index] }
            else
                null,
            .attribute_statement => |index| if (index < self.attribute_statements.len)
                Statement{ .attribute_statement = self.attribute_statements[index] }
            else
                null,
            .edge_chain => |index| if (index < self.edge_chains.len)
                Statement{ .edge_chain = .{ .first = EdgeView.fromNode(self.edge_chains[index].first), .links = .{ .nodes = self.edge_chains[index].links } } }
            else
                null,
            .edge => |index| if (index < self.edges.len)
                Statement{ .edge = EdgeView.fromNode(self.edges[index]) }
            else
                null,
        };
    }

    /// chain must be a view obtained from this document and remain unmodified.
    pub fn edgeLinkCount(self: *const Document, chain: EdgeChainView) usize {
        return switch (chain.links) {
            .nodes => |range| range.len,
            .scoped => |index| @as(usize, self.scoped_edges[index].prefix.len) + self.scoped_edges[index].link_count,
        };
    }
    /// Walk continuations of an unmodified chain view obtained from this document.
    pub fn edgeLinks(self: *const Document, chain: EdgeChainView) EdgeLinkIterator {
        var result: EdgeLinkIterator = .{ .document = self, .left = chain.first.right, .attributes = chain.first.attributes };
        switch (chain.links) {
            .nodes => |range| result.nodes = self.edgeLinkSlice(range).?,
            .scoped => |index| {
                const owner = self.scoped_edges[index];
                result.nodes = self.edgeLinkSlice(owner.prefix).?;
                result.next_link = owner.first_link;
            },
        }
        return result;
    }

    /// Checked continuation-pool lookup; links are in written order.
    pub fn edgeLinkSlice(self: *const Document, range: EdgeLinkRange) ?[]const EdgeLink {
        const start: usize = range.start;
        if (start > self.edge_links.len or range.len > self.edge_links.len - start) return null;
        return self.edge_links[start..][0..range.len];
    }

    /// Bounds-checked attribute-pool lookup. Preserve duplicates and order;
    /// callers choose any effective-value/default resolution policy.
    pub fn attributeSlice(self: *const Document, range: AttributeRange) ?[]const Attribute {
        const start: usize = range.start;
        if (start > self.attributes.len or range.len > self.attributes.len - start) return null;
        return self.attributes[start..][0..range.len];
    }

    /// The statement at a position in source order, or null past the end.
    pub fn statementAt(self: *const Document, order_index: usize) ?Statement {
        if (order_index >= self.order.len) return null;
        return self.statement(self.order[order_index]);
    }

    /// Walk ordinary edges and chain links in source order, without allocation.
    pub fn edgeIterator(self: *const Document) EdgeIterator {
        return .{ .document = self };
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
/// (bulk release, R-MEM-005: twelve pool releases, no per-node walk).
///
/// Package-internal on purpose: `Document` itself is a non-owning view, so
/// a fixed-storage document — whose pools belong to the caller — can never
/// meet a free operation. Public ownership lives on the façade result types.
pub fn deinitOwnedDocument(document: *Document, allocator: std.mem.Allocator) void {
    allocator.free(document.order);
    allocator.free(document.nodes);
    allocator.free(document.edge_chains);
    allocator.free(document.scoped_edges);
    allocator.free(document.scoped_edge_links);
    allocator.free(document.edge_links);
    allocator.free(document.ported_references);
    allocator.free(document.subgraph_records);
    allocator.free(document.edges);
    allocator.free(document.attributes);
    allocator.free(document.assignments);
    allocator.free(document.attribute_statements);
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
    edge_chains: std.ArrayList(EdgeChainStatement) = .empty,
    scoped_edges: std.ArrayList(ScopedEdgeStatement) = .empty,
    scoped_edge_links: std.ArrayList(ScopedEdgeLink) = .empty,
    edge_links: std.ArrayList(EdgeLink) = .empty,
    ported_references: std.ArrayList(PortedReference) = .empty,
    subgraphs: std.ArrayList(Subgraph) = .empty,
    current_scope: ScopeId = .root,
    edges: std.ArrayList(EdgeStatement) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    assignments: std.ArrayList(Assignment) = .empty,
    attribute_statements: std.ArrayList(AttributeStatement) = .empty,
    scope_state: syntax_event.ScopeState = .{},
    pending_links: usize = 0,
    pending_attributes: usize = 0,
    phase: Phase = .idle,
    /// Set when a sink method fails; read by the façade to emit a precise
    /// storage diagnostic.
    failure_info: ?StorageFailureInfo = null,

    pub const Error = error{
        OutOfMemory,
        /// A per-kind pool or global order exceeds the compact count/index domain.
        StatementIndexOverflow,
        AttributeIndexOverflow,
        EdgeLinkIndexOverflow,
        PortedReferenceIndexOverflow,
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
        try builder.edge_chains.ensureTotalCapacityPrecise(allocator, capacities.edge_chains);
        try builder.scoped_edges.ensureTotalCapacityPrecise(allocator, capacities.scoped_edges);
        try builder.scoped_edge_links.ensureTotalCapacityPrecise(allocator, capacities.scoped_edge_links);
        try builder.edge_links.ensureTotalCapacityPrecise(allocator, capacities.edge_links);
        try builder.ported_references.ensureTotalCapacityPrecise(allocator, capacities.ported_references);
        try builder.subgraphs.ensureTotalCapacityPrecise(allocator, capacities.subgraphs);
        try builder.edges.ensureTotalCapacityPrecise(allocator, capacities.edges);
        try builder.attributes.ensureTotalCapacityPrecise(allocator, capacities.attributes);
        try builder.assignments.ensureTotalCapacityPrecise(allocator, capacities.assignments);
        try builder.attribute_statements.ensureTotalCapacityPrecise(allocator, capacities.attribute_statements);
        return builder;
    }

    /// Safe to call in every phase; releases whatever the builder holds.
    pub fn deinit(self: *Builder) void {
        self.order.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.edge_chains.deinit(self.allocator);
        self.scoped_edges.deinit(self.allocator);
        self.scoped_edge_links.deinit(self.allocator);
        self.edge_links.deinit(self.allocator);
        self.ported_references.deinit(self.allocator);
        self.subgraphs.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
        self.assignments.deinit(self.allocator);
        self.attribute_statements.deinit(self.allocator);
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
        self.edge_chains.clearRetainingCapacity();
        self.scoped_edges.clearRetainingCapacity();
        self.scoped_edge_links.clearRetainingCapacity();
        self.edge_links.clearRetainingCapacity();
        self.ported_references.clearRetainingCapacity();
        self.subgraphs.clearRetainingCapacity();
        self.current_scope = .root;
        self.edges.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        self.assignments.clearRetainingCapacity();
        self.attribute_statements.clearRetainingCapacity();
        self.pending_links = 0;
        self.scope_state = .{};
        self.pending_attributes = 0;
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
            self.edge_chains.clearAndFree(self.allocator);
            self.scoped_edges.clearAndFree(self.allocator);
            self.scoped_edge_links.clearAndFree(self.allocator);
            self.edge_links.clearAndFree(self.allocator);
            self.ported_references.clearAndFree(self.allocator);
            self.subgraphs.clearAndFree(self.allocator);
            self.current_scope = .root;
            self.edges.clearAndFree(self.allocator);
            self.attributes.clearAndFree(self.allocator);
            self.assignments.clearAndFree(self.allocator);
            self.attribute_statements.clearAndFree(self.allocator);
            self.pending_links = 0;
            self.scope_state = .{};
            self.pending_attributes = 0;
            self.phase = .terminal;
        }
        const order = try self.order.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(order);
        const nodes = try self.nodes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(nodes);
        const edge_chains = try self.edge_chains.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(edge_chains);
        const subgraphs = try self.subgraphs.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(subgraphs);
        const ported_references = try self.ported_references.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(ported_references);
        const scoped_edges = try self.scoped_edges.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(scoped_edges);
        const scoped_edge_links = try self.scoped_edge_links.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(scoped_edge_links);
        const edge_links = try self.edge_links.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(edge_links);
        const edges = try self.edges.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(edges);
        const attributes = try self.attributes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(attributes);
        const assignments = try self.assignments.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(assignments);
        const attribute_statements = try self.attribute_statements.toOwnedSlice(self.allocator);
        self.phase = .terminal;
        return .{
            .source = self.source,
            .kind = self.kind,
            .strict = self.strict,
            .keyword = self.keyword,
            .name = self.name,
            .order = order,
            .nodes = nodes,
            .edge_chains = edge_chains,
            .scoped_edges = scoped_edges,
            .scoped_edge_links = scoped_edge_links,
            .edge_links = edge_links,
            .ported_references = ported_references,
            .subgraph_records = subgraphs,
            .edges = edges,
            .attributes = attributes,
            .assignments = assignments,
            .attribute_statements = attribute_statements,
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
            .reference = try self.reference(statement_event.identifier, statement_event.port),
            .attributes = self.pendingRange(),
        };
        const index = try self.statementIndex(self.nodes.items.len, at);
        // Reserve both slots first so the two appends cannot desynchronize.
        try self.reserve(&self.nodes, at);
        try self.reserve(&self.order, at);
        self.nodes.appendAssumeCapacity(node);
        self.order.appendAssumeCapacity(.{ .node = index });
        self.pending_attributes = self.attributes.items.len;
    }

    pub fn edgeStatement(self: *Builder, statement_event: syntax_event.EdgeStatement) Error!void {
        if (self.scope_state.scoped_owner != null or statement_event.left_scope != null or statement_event.right_scope != null)
            return finishScopedEdge(self, statement_event);
        std.debug.assert(self.phase == .building);
        const at = statement_event.left;
        const edge: EdgeStatement = .{
            .left = try self.reference(statement_event.left, statement_event.left_port),
            .operator = statement_event.operator,
            .operator_range = try self.range(statement_event.operator_span),
            .right = try self.reference(statement_event.right, statement_event.right_port),
            .attributes = self.pendingRange(),
        };
        const index = try self.statementIndex(self.edges.items.len, at);
        try self.reserve(&self.edges, at);
        try self.reserve(&self.order, at);
        self.edges.appendAssumeCapacity(edge);
        self.order.appendAssumeCapacity(.{ .edge = index });
        self.pending_attributes = self.attributes.items.len;
    }

    pub fn edgeLink(self: *Builder, event: syntax_event.EdgeLink) Error!void {
        if (self.scope_state.scoped_owner != null) {
            try appendScopedLink(self, .{ .node = try self.reference(event.right, event.right_port) }, event.operator, event.operator_span);
            return;
        }
        std.debug.assert(self.phase == .building);
        const value: EdgeLink = .{ .operator = event.operator, .operator_range = try self.range(event.operator_span), .right = try self.reference(event.right, event.right_port) };
        if (self.edge_links.items.len >= std.math.maxInt(Index)) {
            self.failure_info = .{ .span = event.operator_span, .capacity = .{ .resource = .edge_link_index, .limit = std.math.maxInt(Index) } };
            return error.EdgeLinkIndexOverflow;
        }
        try self.reserve(&self.edge_links, event.operator_span);
        self.edge_links.appendAssumeCapacity(value);
    }

    pub fn edgeChainStatement(self: *Builder, event: syntax_event.EdgeStatement) Error!void {
        if (self.scope_state.scoped_owner != null or event.left_scope != null or event.right_scope != null)
            return finishScopedEdge(self, event);
        std.debug.assert(self.phase == .building and self.edge_links.items.len > self.pending_links);
        const value: EdgeChainStatement = .{
            .first = .{ .left = try self.reference(event.left, event.left_port), .operator = event.operator, .operator_range = try self.range(event.operator_span), .right = try self.reference(event.right, event.right_port), .attributes = self.pendingRange() },
            .links = .{ .start = @intCast(self.pending_links), .len = @intCast(self.edge_links.items.len - self.pending_links) },
        };
        const index = try self.statementIndex(self.edge_chains.items.len, event.left);
        try self.reserve(&self.edge_chains, event.left);
        try self.reserve(&self.order, event.left);
        self.edge_chains.appendAssumeCapacity(value);
        self.order.appendAssumeCapacity(.{ .edge_chain = index });
        self.pending_links = self.edge_links.items.len;
        self.pending_attributes = self.attributes.items.len;
    }

    pub fn beginSubgraph(self: *Builder, event: syntax_event.BeginSubgraph) Error!syntax_event.ScopeEntry {
        return beginScope(self, event);
    }
    pub fn endSubgraph(self: *Builder, event: syntax_event.EndSubgraph) Error!void {
        return endScope(self, event);
    }
    pub fn subgraphStatement(self: *Builder, id: u32) Error!void {
        std.debug.assert(self.phase == .building and self.scope_state.scoped_owner == null);
        const owner = poolItems(self, .order)[self.scope_state.reserved_order.?];
        std.debug.assert(owner == .subgraph and owner.subgraph + 1 == id);
        self.scope_state = .{};
    }

    pub fn portedReference(self: *Builder, event: syntax_event.PortedReference) Error!u32 {
        std.debug.assert(self.phase == .building);
        const value: PortedReference = .{
            .identifier = try self.range(event.identifier),
            .port = .{ .first = try self.range(event.first), .second = if (event.second) |span| try self.range(span) else null },
        };
        if (self.ported_references.items.len >= std.math.maxInt(Index)) {
            self.failure_info = .{ .span = event.first, .capacity = .{ .resource = .ported_reference_index, .limit = std.math.maxInt(Index) } };
            return error.PortedReferenceIndexOverflow;
        }
        const index: Index = @intCast(self.ported_references.items.len);
        try self.reserve(&self.ported_references, event.first);
        self.ported_references.appendAssumeCapacity(value);
        return index;
    }

    fn reference(self: *Builder, span: location.Span, port: ?u32) Error!NodeReference {
        if (port) |index| {
            std.debug.assert(index < self.ported_references.items.len);
            return NodeReference.pooled(index);
        }
        return NodeReference.fromRange(try self.range(span)).?;
    }

    fn pendingRange(self: *const Builder) AttributeRange {
        return .{ .start = @intCast(self.pending_attributes), .len = @intCast(self.attributes.items.len - self.pending_attributes) };
    }

    pub fn attribute(self: *Builder, event: syntax_event.Attribute) Error!void {
        std.debug.assert(self.phase == .building);
        const value: Attribute = .{ .key = try self.range(event.key), .value = try self.range(event.value) };
        if (self.attributes.items.len >= std.math.maxInt(Index)) {
            self.failure_info = .{ .span = event.key, .capacity = .{ .resource = .attribute_index, .limit = std.math.maxInt(Index) } };
            return error.AttributeIndexOverflow;
        }
        try self.reserve(&self.attributes, event.key);
        self.attributes.appendAssumeCapacity(value);
    }

    pub fn assignment(self: *Builder, event: syntax_event.Attribute) Error!void {
        std.debug.assert(self.phase == .building and self.pending_attributes == self.attributes.items.len);
        const value: Assignment = .{ .key = try self.range(event.key), .value = try self.range(event.value) };
        const index = try self.statementIndex(self.assignments.items.len, event.key);
        try self.reserve(&self.assignments, event.key);
        try self.reserve(&self.order, event.key);
        self.assignments.appendAssumeCapacity(value);
        self.order.appendAssumeCapacity(.{ .assignment = index });
    }

    pub fn attributeStatement(self: *Builder, event: syntax_event.AttributeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const value: AttributeStatement = .{
            .target = event.target,
            .keyword = try self.range(event.keyword_span),
            .attributes = self.pendingRange(),
        };
        const index = try self.statementIndex(self.attribute_statements.items.len, event.keyword_span);
        try self.reserve(&self.attribute_statements, event.keyword_span);
        try self.reserve(&self.order, event.keyword_span);
        self.attribute_statements.appendAssumeCapacity(value);
        self.order.appendAssumeCapacity(.{ .attribute_statement = index });
        self.pending_attributes = self.attributes.items.len;
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
        return checkedIndex(length, self.order.items.len) catch |err| {
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
        std.debug.assert(self.phase == .building and self.current_scope == .root);
        std.debug.assert(self.pendingRange().len == 0);
        std.debug.assert(self.pending_links == self.edge_links.items.len);
        self.phase = .committed;
    }

    pub fn abortDocument(self: *Builder, reason: syntax_event.AbortReason) void {
        _ = reason;
        // Release staged state (the event contract's abort semantics).
        // Terminal until `reset`; the lists stay valid so `deinit` is safe.
        self.order.clearAndFree(self.allocator);
        self.nodes.clearAndFree(self.allocator);
        self.edge_chains.clearAndFree(self.allocator);
        self.scoped_edges.clearAndFree(self.allocator);
        self.scoped_edge_links.clearAndFree(self.allocator);
        self.edge_links.clearAndFree(self.allocator);
        self.ported_references.clearAndFree(self.allocator);
        self.subgraphs.clearAndFree(self.allocator);
        self.current_scope = .root;
        self.edges.clearAndFree(self.allocator);
        self.attributes.clearAndFree(self.allocator);
        self.assignments.clearAndFree(self.allocator);
        self.attribute_statements.clearAndFree(self.allocator);
        self.pending_links = 0;
        self.scope_state = .{};
        self.pending_attributes = 0;
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

fn checkedIndex(length: usize, total: usize) error{StatementIndexOverflow}!Index {
    // Scope intervals and the root statement count share the compact domain.
    if (@max(length, total) >= std.math.maxInt(Index)) return error.StatementIndexOverflow;
    return @intCast(length);
}

/// Pool element counts: hard limits for fixed storage, initial reservations
/// for allocator-backed storage. Zero means no initial space in that pool.
pub const Capacities = struct {
    /// Source statements, including standalone scopes but not endpoint scopes.
    statements: usize = 0,
    nodes: usize = 0,
    /// Owners with two or more written edge operators.
    edge_chains: usize = 0,
    /// Continuations after each chain's first edge (N edges use N-1 links).
    /// Owners involving one or more subgraph endpoints.
    scoped_edges: usize = 0,
    /// Continuations after promotion to a subgraph-containing owner.
    scoped_edge_links: usize = 0,
    edge_links: usize = 0,
    /// Qualified node-reference occurrences; duplicates are not interned.
    ported_references: usize = 0,
    /// Total retained subgraph occurrences, not maximum nesting depth.
    subgraphs: usize = 0,
    edges: usize = 0,
    /// Pairs in bracket lists; standalone assignments use their own pool.
    attributes: usize = 0,
    assignments: usize = 0,
    attribute_statements: usize = 0,
};

/// Caller-provided pools for allocation-free document building
/// (R-MEM-003). Any memory works: static arrays, stack buffers, or a
/// carved-up region — capacity is visible at the declaration site, nothing
/// grows, and failure is deterministic.
pub const DocumentStorage = struct {
    statement_ids: []StatementId,
    nodes: []NodeStatement,
    edge_chains: []EdgeChainStatement = &.{},
    scoped_edges: []ScopedEdgeStatement = &.{},
    scoped_edge_links: []ScopedEdgeLink = &.{},
    edge_links: []EdgeLink = &.{},
    ported_references: []PortedReference = &.{},
    subgraphs: []Subgraph = &.{},
    edges: []EdgeStatement,
    attributes: []Attribute = &.{},
    assignments: []Assignment = &.{},
    attribute_statements: []AttributeStatement = &.{},
};

/// Comptime sugar over `DocumentStorage`: a struct that owns the pools.
///
/// The capacity is committed eagerly: the pools are inline arrays, so the
/// declared variable occupies the full capacity wherever it lives (stack,
/// static, or heap via `allocator.create`). Budget with `byte_size`.
pub fn FixedDocumentStorage(comptime capacities: Capacities) type {
    comptime {
        for ([_]usize{ capacities.statements, capacities.nodes, capacities.edges, capacities.scoped_edges, capacities.scoped_edge_links, capacities.edge_links, capacities.edge_chains, capacities.ported_references, capacities.subgraphs, capacities.attributes, capacities.assignments, capacities.attribute_statements }) |capacity| {
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
        edge_chains: [capacities.edge_chains]EdgeChainStatement = undefined,
        scoped_edges: [capacities.scoped_edges]ScopedEdgeStatement = undefined,
        scoped_edge_links: [capacities.scoped_edge_links]ScopedEdgeLink = undefined,
        edge_links: [capacities.edge_links]EdgeLink = undefined,
        ported_references: [capacities.ported_references]PortedReference = undefined,
        subgraphs: [capacities.subgraphs]Subgraph = undefined,
        edges: [capacities.edges]EdgeStatement = undefined,
        attributes: [capacities.attributes]Attribute = undefined,
        assignments: [capacities.assignments]Assignment = undefined,
        attribute_statements: [capacities.attribute_statements]AttributeStatement = undefined,

        pub fn storage(self: *@This()) DocumentStorage {
            return .{
                .statement_ids = &self.statement_ids,
                .nodes = &self.nodes,
                .edge_chains = &self.edge_chains,
                .scoped_edges = &self.scoped_edges,
                .scoped_edge_links = &self.scoped_edge_links,
                .edge_links = &self.edge_links,
                .ported_references = &self.ported_references,
                .subgraphs = &self.subgraphs,
                .edges = &self.edges,
                .attributes = &self.attributes,
                .assignments = &self.assignments,
                .attribute_statements = &self.attribute_statements,
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
    edge_chains_len: usize = 0,
    scoped_edges_len: usize = 0,
    scoped_edge_links_len: usize = 0,
    edge_links_len: usize = 0,
    ported_references_len: usize = 0,
    subgraphs_len: usize = 0,
    current_scope: ScopeId = .root,
    edges_len: usize = 0,
    attributes_len: usize = 0,
    assignments_len: usize = 0,
    attribute_statements_len: usize = 0,
    scope_state: syntax_event.ScopeState = .{},
    pending_links: usize = 0,
    pending_attributes: usize = 0,
    phase: Phase = .idle,
    /// Set when a sink method fails; read by the façade to emit a precise
    /// storage diagnostic naming the exhausted pool.
    failure_info: ?StorageFailureInfo = null,

    pub const Error = error{
        /// A caller-provided pool filled up.
        PoolExhausted,
        /// A source position beyond the 4 GiB retained-range limit.
        SourceOffsetOverflow,
        /// A per-kind pool or global order exceeds the compact count/index domain.
        StatementIndexOverflow,
        AttributeIndexOverflow,
        EdgeLinkIndexOverflow,
        PortedReferenceIndexOverflow,
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
        self.edge_chains_len = 0;
        self.scoped_edges_len = 0;
        self.scoped_edge_links_len = 0;
        self.edge_links_len = 0;
        self.ported_references_len = 0;
        self.subgraphs_len = 0;
        self.current_scope = .root;
        self.edges_len = 0;
        self.attributes_len = 0;
        self.assignments_len = 0;
        self.attribute_statements_len = 0;
        self.pending_links = 0;
        self.scope_state = .{};
        self.pending_attributes = 0;
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
            .edge_chains = self.storage.edge_chains[0..self.edge_chains_len],
            .scoped_edges = self.storage.scoped_edges[0..self.scoped_edges_len],
            .scoped_edge_links = self.storage.scoped_edge_links[0..self.scoped_edge_links_len],
            .edge_links = self.storage.edge_links[0..self.edge_links_len],
            .ported_references = self.storage.ported_references[0..self.ported_references_len],
            .subgraph_records = self.storage.subgraphs[0..self.subgraphs_len],
            .edges = self.storage.edges[0..self.edges_len],
            .attributes = self.storage.attributes[0..self.attributes_len],
            .assignments = self.storage.assignments[0..self.assignments_len],
            .attribute_statements = self.storage.attribute_statements[0..self.attribute_statements_len],
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

    pub fn edgeLink(self: *FixedBuilder, event: syntax_event.EdgeLink) Error!void {
        if (self.scope_state.scoped_owner != null) {
            try appendScopedLink(self, .{ .node = try self.reference(event.right, event.right_port) }, event.operator, event.operator_span);
            return;
        }
        std.debug.assert(self.phase == .building);
        const value: EdgeLink = .{ .operator = event.operator, .operator_range = try self.range(event.operator_span), .right = try self.reference(event.right, event.right_port) };
        if (self.edge_links_len >= std.math.maxInt(Index)) {
            self.failure_info = .{ .span = event.operator_span, .capacity = .{ .resource = .edge_link_index, .limit = std.math.maxInt(Index) } };
            return error.EdgeLinkIndexOverflow;
        }
        try self.checkPool(self.edge_links_len, self.storage.edge_links.len, .edge_link_pool, event.operator_span);
        self.storage.edge_links[self.edge_links_len] = value;
        self.edge_links_len += 1;
    }

    pub fn edgeChainStatement(self: *FixedBuilder, event: syntax_event.EdgeStatement) Error!void {
        if (self.scope_state.scoped_owner != null or event.left_scope != null or event.right_scope != null)
            return finishScopedEdge(self, event);
        std.debug.assert(self.phase == .building and self.edge_links_len > self.pending_links);
        const value: EdgeChainStatement = .{
            .first = .{ .left = try self.reference(event.left, event.left_port), .operator = event.operator, .operator_range = try self.range(event.operator_span), .right = try self.reference(event.right, event.right_port), .attributes = self.pendingRange() },
            .links = .{ .start = @intCast(self.pending_links), .len = @intCast(self.edge_links_len - self.pending_links) },
        };
        const index = try self.statementIndex(self.edge_chains_len, event.left);
        try self.checkPool(self.edge_chains_len, self.storage.edge_chains.len, .edge_chain_pool, event.left);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, event.left);
        self.storage.edge_chains[self.edge_chains_len] = value;
        self.edge_chains_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .edge_chain = index };
        self.order_len += 1;
        self.pending_links = self.edge_links_len;
        self.pending_attributes = self.attributes_len;
    }

    pub fn beginSubgraph(self: *FixedBuilder, event: syntax_event.BeginSubgraph) Error!syntax_event.ScopeEntry {
        return beginScope(self, event);
    }
    pub fn endSubgraph(self: *FixedBuilder, event: syntax_event.EndSubgraph) Error!void {
        return endScope(self, event);
    }
    pub fn subgraphStatement(self: *FixedBuilder, id: u32) Error!void {
        std.debug.assert(self.phase == .building and self.scope_state.scoped_owner == null);
        const owner = poolItems(self, .order)[self.scope_state.reserved_order.?];
        std.debug.assert(owner == .subgraph and owner.subgraph + 1 == id);
        self.scope_state = .{};
    }

    pub fn portedReference(self: *FixedBuilder, event: syntax_event.PortedReference) Error!u32 {
        std.debug.assert(self.phase == .building);
        const value: PortedReference = .{
            .identifier = try self.range(event.identifier),
            .port = .{ .first = try self.range(event.first), .second = if (event.second) |span| try self.range(span) else null },
        };
        if (self.ported_references_len >= std.math.maxInt(Index)) {
            self.failure_info = .{ .span = event.first, .capacity = .{ .resource = .ported_reference_index, .limit = std.math.maxInt(Index) } };
            return error.PortedReferenceIndexOverflow;
        }
        const index: Index = @intCast(self.ported_references_len);
        try self.checkPool(self.ported_references_len, self.storage.ported_references.len, .ported_reference_pool, event.first);
        self.storage.ported_references[self.ported_references_len] = value;
        self.ported_references_len += 1;
        return index;
    }

    fn reference(self: *FixedBuilder, span: location.Span, port: ?u32) Error!NodeReference {
        if (port) |index| {
            std.debug.assert(index < self.ported_references_len);
            return NodeReference.pooled(index);
        }
        return NodeReference.fromRange(try self.range(span)).?;
    }

    fn pendingRange(self: *const FixedBuilder) AttributeRange {
        return .{ .start = @intCast(self.pending_attributes), .len = @intCast(self.attributes_len - self.pending_attributes) };
    }

    pub fn attribute(self: *FixedBuilder, event: syntax_event.Attribute) Error!void {
        std.debug.assert(self.phase == .building);
        const value: Attribute = .{ .key = try self.range(event.key), .value = try self.range(event.value) };
        if (self.attributes_len >= std.math.maxInt(Index)) {
            self.failure_info = .{ .span = event.key, .capacity = .{ .resource = .attribute_index, .limit = std.math.maxInt(Index) } };
            return error.AttributeIndexOverflow;
        }
        try self.checkPool(self.attributes_len, self.storage.attributes.len, .attribute_pool, event.key);
        self.storage.attributes[self.attributes_len] = value;
        self.attributes_len += 1;
    }

    pub fn assignment(self: *FixedBuilder, event: syntax_event.Attribute) Error!void {
        std.debug.assert(self.phase == .building and self.pending_attributes == self.attributes_len);
        const value: Assignment = .{ .key = try self.range(event.key), .value = try self.range(event.value) };
        const index = try self.statementIndex(self.assignments_len, event.key);
        try self.checkPool(self.assignments_len, self.storage.assignments.len, .assignment_pool, event.key);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, event.key);
        self.storage.assignments[self.assignments_len] = value;
        self.assignments_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .assignment = index };
        self.order_len += 1;
    }

    pub fn attributeStatement(self: *FixedBuilder, event: syntax_event.AttributeStatement) Error!void {
        std.debug.assert(self.phase == .building);
        const value: AttributeStatement = .{
            .target = event.target,
            .keyword = try self.range(event.keyword_span),
            .attributes = self.pendingRange(),
        };
        const index = try self.statementIndex(self.attribute_statements_len, event.keyword_span);
        try self.checkPool(self.attribute_statements_len, self.storage.attribute_statements.len, .attribute_statement_pool, event.keyword_span);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, event.keyword_span);
        self.storage.attribute_statements[self.attribute_statements_len] = value;
        self.attribute_statements_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .attribute_statement = index };
        self.order_len += 1;
        self.pending_attributes = self.attributes_len;
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
        return checkedIndex(length, self.order_len) catch |err| {
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
            .reference = try self.reference(statement_event.identifier, statement_event.port),
            .attributes = self.pendingRange(),
        };
        try self.checkPool(self.nodes_len, self.storage.nodes.len, .node_pool, at);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, at);
        const index = try self.statementIndex(self.nodes_len, at);
        self.storage.nodes[self.nodes_len] = node;
        self.nodes_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .node = index };
        self.order_len += 1;
        self.pending_attributes = self.attributes_len;
    }

    pub fn edgeStatement(self: *FixedBuilder, statement_event: syntax_event.EdgeStatement) Error!void {
        if (self.scope_state.scoped_owner != null or statement_event.left_scope != null or statement_event.right_scope != null)
            return finishScopedEdge(self, statement_event);
        std.debug.assert(self.phase == .building);
        const at = statement_event.left;
        const edge: EdgeStatement = .{
            .left = try self.reference(statement_event.left, statement_event.left_port),
            .operator = statement_event.operator,
            .operator_range = try self.range(statement_event.operator_span),
            .right = try self.reference(statement_event.right, statement_event.right_port),
            .attributes = self.pendingRange(),
        };
        try self.checkPool(self.edges_len, self.storage.edges.len, .edge_pool, at);
        try self.checkPool(self.order_len, self.storage.statement_ids.len, .statement_pool, at);
        const index = try self.statementIndex(self.edges_len, at);
        self.storage.edges[self.edges_len] = edge;
        self.edges_len += 1;
        self.storage.statement_ids[self.order_len] = .{ .edge = index };
        self.order_len += 1;
        self.pending_attributes = self.attributes_len;
    }

    pub fn endDocument(self: *FixedBuilder) Error!void {
        std.debug.assert(self.phase == .building and self.current_scope == .root);
        std.debug.assert(self.pendingRange().len == 0);
        std.debug.assert(self.pending_links == self.edge_links_len);
        self.phase = .committed;
    }

    pub fn abortDocument(self: *FixedBuilder, reason: syntax_event.AbortReason) void {
        _ = reason;
        // Nothing to free — the pools are the caller's. Lengths reset so no
        // stale view escapes; terminal until `reset`.
        self.order_len = 0;
        self.nodes_len = 0;
        self.edge_chains_len = 0;
        self.scoped_edges_len = 0;
        self.scoped_edge_links_len = 0;
        self.edge_links_len = 0;
        self.ported_references_len = 0;
        self.subgraphs_len = 0;
        self.current_scope = .root;
        self.edges_len = 0;
        self.attributes_len = 0;
        self.assignments_len = 0;
        self.attribute_statements_len = 0;
        self.pending_links = 0;
        self.scope_state = .{};
        self.pending_attributes = 0;
        self.phase = .terminal;
    }
};

// Shared generalized-edge algorithm; storage policy stays in the two builders.
const Pool = enum {
    order,
    subgraphs,
    scoped_edges,
    scoped_edge_links,
    edge_links,
    attributes,

    fn Element(comptime pool: Pool) type {
        return switch (pool) {
            .order => StatementId,
            .subgraphs => Subgraph,
            .scoped_edges => ScopedEdgeStatement,
            .scoped_edge_links => ScopedEdgeLink,
            .edge_links => EdgeLink,
            .attributes => Attribute,
        };
    }
    fn storageName(comptime pool: Pool) []const u8 {
        return if (pool == .order) "statement_ids" else @tagName(pool);
    }
    fn resource(comptime pool: Pool) diagnostic.Capacity.Resource {
        return switch (pool) {
            .order => .statement_pool,
            .subgraphs => .subgraph_pool,
            .scoped_edges => .scoped_edge_pool,
            .scoped_edge_links => .scoped_edge_link_pool,
            else => @compileError("this pool uses its specialized append path"),
        };
    }
};
fn poolLen(self: anytype, comptime pool: Pool) usize {
    return if (@TypeOf(self.*) == Builder) @field(self, @tagName(pool)).items.len else @field(self, @tagName(pool) ++ "_len");
}
fn poolItems(self: anytype, comptime pool: Pool) []pool.Element() {
    if (@TypeOf(self.*) == Builder) return @field(self, @tagName(pool)).items;
    return @field(self.storage, pool.storageName())[0..poolLen(self, pool)];
}
fn appendPool(self: anytype, comptime pool: Pool, value: pool.Element(), at: location.Span) @TypeOf(self.*).Error!Index {
    const length = poolLen(self, pool);
    const index = try self.statementIndex(length, at);
    if (@TypeOf(self.*) == Builder) {
        try self.reserve(&@field(self, @tagName(pool)), at);
        @field(self, @tagName(pool)).appendAssumeCapacity(value);
    } else {
        try self.checkPool(length, @field(self.storage, pool.storageName()).len, pool.resource(), at);
        @field(self.storage, pool.storageName())[length] = value;
        @field(self, @tagName(pool) ++ "_len") += 1;
    }
    return index;
}
fn endpoint(self: anytype, span: location.Span, port: ?u32, scope: ?u32) @TypeOf(self.*).Error!Endpoint {
    return if (scope) |id| .{ .subgraph = @enumFromInt(id) } else .{ .node = try self.reference(span, port) };
}
fn promoteEdge(self: anytype, event: syntax_event.EdgeStatement) @TypeOf(self.*).Error!void {
    if (self.scope_state.scoped_owner != null) return;
    const value: ScopedEdgeStatement = .{
        .first = .{ .left = try endpoint(self, event.left, event.left_port, event.left_scope), .right = try endpoint(self, event.right, event.right_port, event.right_scope), .operator = event.operator, .operator_range = try self.range(event.operator_span) },
        .prefix = .{ .start = @intCast(self.pending_links), .len = @intCast(poolLen(self, .edge_links) - self.pending_links) },
    };
    const index = try appendPool(self, .scoped_edges, value, event.operator_span);
    if (self.scope_state.reserved_order == null)
        self.scope_state.reserved_order = try appendPool(self, .order, .{ .scoped_edge = index }, event.left);
    self.scope_state.scoped_owner = index;
    poolItems(self, .order)[self.scope_state.reserved_order.?] = .{ .scoped_edge = index };
    self.pending_links = poolLen(self, .edge_links);
}
fn appendScopedLink(self: anytype, right: Endpoint, operator: EdgeOperator, at: location.Span) @TypeOf(self.*).Error!void {
    const owner_index = self.scope_state.scoped_owner.?;
    const owner = poolItems(self, .scoped_edges)[owner_index];
    const left = if (owner.last_link != no_link) poolItems(self, .scoped_edge_links)[owner.last_link].right else if (owner.prefix.len != 0) Endpoint{ .node = poolItems(self, .edge_links)[owner.prefix.start + owner.prefix.len - 1].right } else owner.first.right;
    const index = try appendPool(self, .scoped_edge_links, .{ .left = left, .right = right, .operator = operator, .operator_range = try self.range(at), .owner = owner_index }, at);
    const updated = &poolItems(self, .scoped_edges)[owner_index];
    if (owner.last_link == no_link) updated.first_link = index else poolItems(self, .scoped_edge_links)[owner.last_link].next = index;
    updated.last_link = index;
    updated.link_count += 1;
}
fn beginScope(self: anytype, event: syntax_event.BeginSubgraph) @TypeOf(self.*).Error!syntax_event.ScopeEntry {
    std.debug.assert(self.phase == .building and self.pendingRange().len == 0);
    const index = try self.statementIndex(poolLen(self, .subgraphs), event.start);
    const id = index + 1;
    if (event.role == .left) {
        self.scope_state.reserved_order = try appendPool(self, .order, .{ .subgraph = index }, event.start);
    } else {
        var edge = event.edge.?;
        if (event.role == .right) {
            edge.right_scope = id;
            edge.right = event.start;
            edge.right_port = null;
        }
        try promoteEdge(self, edge);
        if (event.role == .link)
            try appendScopedLink(self, .{ .subgraph = @enumFromInt(id) }, event.link_operator.?, event.link_operator_span.?);
    }
    const entry: syntax_event.ScopeEntry = .{ .id = id, .state = self.scope_state };
    _ = try appendPool(self, .subgraphs, .{
        .parent = self.current_scope,
        .name = if (event.name) |name| try self.range(name) else null,
        .source = try self.range(event.start),
        .body = .{ .start = @intCast(poolLen(self, .order)), .len = 0 },
    }, event.start);
    self.current_scope = @enumFromInt(id);
    self.scope_state = .{};
    self.pending_links = poolLen(self, .edge_links);
    self.pending_attributes = poolLen(self, .attributes);
    return entry;
}
fn endScope(self: anytype, event: syntax_event.EndSubgraph) @TypeOf(self.*).Error!void {
    std.debug.assert(self.phase == .building and @intFromEnum(self.current_scope) == event.entry.id);
    std.debug.assert(self.pendingRange().len == 0);
    const record = &poolItems(self, .subgraphs)[event.entry.id - 1];
    _ = try self.range(event.close);
    record.source.len = @intCast(event.close.endOffset() - record.source.start);
    record.body.len = @intCast(poolLen(self, .order) - record.body.start);
    record.subtree_end = @intCast(poolLen(self, .subgraphs));
    self.current_scope = record.parent;
    self.scope_state = event.entry.state;
    self.pending_links = poolLen(self, .edge_links);
    self.pending_attributes = poolLen(self, .attributes);
}
fn finishScopedEdge(self: anytype, event: syntax_event.EdgeStatement) @TypeOf(self.*).Error!void {
    std.debug.assert(self.phase == .building);
    try promoteEdge(self, event);
    poolItems(self, .scoped_edges)[self.scope_state.scoped_owner.?].first.attributes = self.pendingRange();
    self.scope_state = .{};
    self.pending_links = poolLen(self, .edge_links);
    self.pending_attributes = poolLen(self, .attributes);
}

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

test "ported index and source overflow fail before pool access and reset cleanly" {
    var pools: FixedDocumentStorage(.{}) = .{};
    var builder = FixedBuilder.init("graph{}", pools.storage());
    const at: location.Span = .{ .start = .start, .byte_len = 1 };
    try builder.beginDocument(.{ .kind = .undigraph, .keyword_span = at });
    builder.ported_references_len = std.math.maxInt(Index);
    try std.testing.expectError(error.PortedReferenceIndexOverflow, builder.portedReference(.{ .identifier = at, .first = at }));
    try expectEqual(diagnostic.Capacity.Resource.ported_reference_index, builder.failure_info.?.capacity.?.resource);
    builder.abortDocument(.sink_failure);
    try expectEqual(@as(usize, 0), builder.ported_references_len);
    var allocated = Builder.init(std.testing.allocator, "graph{}");
    defer allocated.deinit();
    try allocated.beginDocument(.{ .kind = .undigraph, .keyword_span = at });
    const huge: location.Span = .{ .start = .{ .byte_offset = std.math.maxInt(u32), .line = 1, .byte_column = 1 }, .byte_len = 1 };
    try std.testing.expectError(error.SourceOffsetOverflow, allocated.portedReference(.{ .identifier = at, .first = huge }));
    try expectEqual(@as(usize, 0), allocated.ported_references.items.len);
    allocated.abortDocument(.sink_failure);
}

test "link index overflow is reported before accessing a fixed pool" {
    var pools: FixedDocumentStorage(.{}) = .{};
    var builder = FixedBuilder.init("graph{}", pools.storage());
    const at: location.Span = .{ .start = .start, .byte_len = 1 };
    try builder.beginDocument(.{ .kind = .undigraph, .keyword_span = at });
    // Simulate the counter boundary, without allocating a huge pool.
    builder.edge_links_len = std.math.maxInt(Index);
    try std.testing.expectError(error.EdgeLinkIndexOverflow, builder.edgeLink(.{
        .operator = .undirected,
        .operator_span = at,
        .right = at,
    }));
    try expectEqual(diagnostic.Capacity.Resource.edge_link_index, builder.failure_info.?.capacity.?.resource);
    builder.abortDocument(.sink_failure);
    try expectEqual(@as(usize, 0), builder.edge_links_len);
    try expectEqual(@as(usize, 0), builder.pending_links);
}

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
    try expectEqualStrings("a", document.nodeReference(first.reference).?.identifier.slice(source));
    try expectEqualStrings("a", document.text(document.nodeReference(first.reference).?.identifier));
    try expectEqualStrings(source, document.source);

    const edge = document.statementAt(1).?.edge;
    try expectEqual(EdgeOperator.undirected, edge.operator);
    try expectEqualStrings("a", document.nodeReference(edge.left.node).?.identifier.slice(source));
    try expectEqualStrings("--", edge.operator_range.slice(source));
    try expectEqualStrings("b", document.nodeReference(edge.right.node).?.identifier.slice(source));

    // The written `->` is preserved for validation to inspect.
    const directed = document.statementAt(3).?.edge;
    try expectEqual(EdgeOperator.directed, directed.operator);

    // Ranges borrow the original buffer — no copies (R-MEM-004).
    try expect(document.nodeReference(first.reference).?.identifier.slice(source).ptr == source.ptr + 8);

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

    try expectEqualStrings("x", document.nodeReference(document.statementAt(0).?.node.reference).?.identifier.slice(source));
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
    const source = "graph \"G\"+\"raph\" { rankdir=LR; node [shape=box]; \"a\" [x=1][x=2]; \"a\" -- 1 [weight=.5]; }";
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
    const source = "graph { a [x=1]; a -- b [y=2]; rankdir=LR; node [shape=box]; }";
    var fail_index: usize = 0;
    var observed_transfer_failure = false;
    while (fail_index < 64) : (fail_index += 1) {
        // All in-place resizes fail, so every toOwnedSlice must take the
        // allocate-and-copy path — sweeping fail_index therefore fails each
        // of the six transfers in turn, including mid-handoff (the P0
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
    try expectEqualStrings("ok", document.nodeReference(document.statementAt(0).?.node.reference).?.identifier.slice(source));
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
    try expectEqualStrings("a", first.nodeReference(first.statementAt(0).?.node.reference).?.identifier.slice(first_source));
    try expectEqualStrings("c", second.nodeReference(second.statementAt(1).?.node.reference).?.identifier.slice(second_source));
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
    try expectEqualStrings("a", document.text(document.nodeReference(document.statementAt(0).?.node.reference).?.identifier));
    const edge = document.statementAt(1).?.edge;
    try expectEqual(EdgeOperator.undirected, edge.operator);
    try expectEqualStrings("b", document.text(document.nodeReference(edge.right.node).?.identifier));

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
    try expectEqualStrings("a", document.text(document.nodeReference(iterator.next().?.node.reference).?.identifier));
    try expect(iterator.next().? == .edge);
    try expectEqualStrings("b", document.text(document.nodeReference(iterator.next().?.node.reference).?.identifier));
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
    try expectEqualStrings("n", document.nodeReference(document.statementAt(0).?.node.reference).?.identifier.slice(source));
}

test "attribute index overflow is checked before fixed pool access" {
    var pools: FixedDocumentStorage(.{}) = .{};
    var builder = FixedBuilder.init("graph", pools.storage());
    try builder.beginDocument(.{ .kind = .undigraph, .keyword_span = .{ .start = .start, .byte_len = 5 } });
    builder.attributes_len = std.math.maxInt(Index);
    const at: location.Span = .{ .start = .start, .byte_len = 1 };
    try std.testing.expectError(error.AttributeIndexOverflow, builder.attribute(.{ .key = at, .value = at }));
    try expectEqual(diagnostic.Capacity.Resource.attribute_index, builder.failure_info.?.capacity.?.resource);
    builder.abortDocument(.sink_failure);
    try expectEqual(@as(usize, 0), builder.attributes_len);
}

test "new capacity hints reserve even when all original pool hints are zero" {
    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var builder = try Builder.initCapacity(fba.allocator(), "graph {}", .{
        .attributes = 2,
        .assignments = 2,
        .attribute_statements = 2,
    });
    defer builder.deinit();
    try expectEqual(@as(usize, 2), builder.attributes.capacity);
    try expectEqual(@as(usize, 2), builder.assignments.capacity);
    try expectEqual(@as(usize, 2), builder.attribute_statements.capacity);
}

test "scope order and ID overflow are typed before narrowing or pool access" {
    var pools: FixedDocumentStorage(.{ .statements = 1, .subgraphs = 1 }) = .{};
    const at: location.Span = .{ .start = .start, .byte_len = 1 };
    inline for (.{ "order_len", "subgraphs_len" }) |field| {
        var builder = FixedBuilder.init("graph{}", pools.storage());
        try builder.beginDocument(.{ .kind = .undigraph, .keyword_span = at });
        @field(builder, field) = std.math.maxInt(Index);
        try std.testing.expectError(error.StatementIndexOverflow, builder.beginSubgraph(.{ .start = at, .name = null }));
        try expectEqual(diagnostic.Capacity.Resource.statement_index, builder.failure_info.?.capacity.?.resource);
        builder.abortDocument(.sink_failure);
        try expectEqual(@as(usize, 0), builder.subgraphs_len);
    }
    var builder = FixedBuilder.init("graph{}", pools.storage());
    try builder.beginDocument(.{ .kind = .undigraph, .keyword_span = at });
    const entry = try builder.beginSubgraph(.{ .start = at, .name = null });
    const huge: location.Span = .{ .start = .{ .byte_offset = std.math.maxInt(u32), .line = 1, .byte_column = 1 }, .byte_len = 1 };
    try std.testing.expectError(error.SourceOffsetOverflow, builder.endSubgraph(.{ .close = huge, .entry = entry }));
    builder.abortDocument(.sink_failure);
    try expectEqual(ScopeId.root, builder.current_scope);
}
