//! Compact source-order forest. Trees are preorder intervals, not per-node
//! child arrays. No decoding, parent lookup table, normalization or validation.
const std = @import("std");
const Span = @import("parser_support").location.Span;
const Completeness = @import("parser_support").Completeness;
pub const NodeId = enum(u32) { _ };
pub const Kind = @import("kind.zig").Kind;
pub const Node = struct {
    span: Span,
    /// Element name span. For leaves, len is zero and start encodes Kind;
    /// it is then a discriminator, not a source span. Use kind()/NodeView.content().
    name: Span,
    /// First index after this node and all its descendants. In partial documents,
    /// zero marks an unfinished element. NodeView.record()/children() resolve
    /// that marker to the retained prefix boundary without repairing source.
    subtree_end: u32,
    pub fn kind(self: Node) Kind {
        if (self.name.len != 0) return .element;
        return switch (self.name.start) {
            @intFromEnum(Kind.text) => .text,
            @intFromEnum(Kind.comment) => .comment,
            @intFromEnum(Kind.cdata) => .cdata,
            else => unreachable, // Invalid trusted representation, not input syntax.
        };
    }
};
/// Sparse source-order pool: no attribute fields are added to every node.
pub const Attribute = struct {
    owner: NodeId,
    name: Span,
    /// Includes the two original quote delimiters; never decoded/normalized.
    value: Span,
};
pub const Storage = struct { nodes: []Node = &.{}, attributes: []Attribute = &.{} };
pub const Capacities = struct { nodes: u32 = 0, attributes: u32 = 0 };
pub fn Fixed(comptime capacity: Capacities) type {
    return struct {
        nodes: [capacity.nodes]Node = undefined,
        attributes: [capacity.attributes]Attribute = undefined,
        pub const byte_size = @sizeOf(@This());
        pub fn storage(self: *@This()) Storage {
            return .{ .nodes = &self.nodes, .attributes = &self.attributes };
        }
    };
}

/// Non-owning view. Source and backing records must remain alive and
/// unchanged. No deinit: disposal belongs to the owning result or caller storage.
/// This is a trusted parser representation, not an unchecked document builder.
/// Manually constructed views must uphold the same invariants: bounded source
/// spans, valid leaf kind encodings/delimiters and preorder subtree intervals,
/// and attributes in source order with
/// nondecreasing owners referring to elements. Each owner's attributes occupy
/// one contiguous range; names/quoted values refer into that owner's source span.
/// Partial-prefix records may use subtree_end == 0 for unfinished elements;
/// all their retained descendants extend to records.len. Their raw span covers
/// the recognized opening header; NodeView expands it to the observed prefix.
/// Validation checks policy findings, not general correctness of these pools.
pub const Document = struct {
    source: []const u8,
    records: []const Node,
    attributes: []const Attribute,
    state: Completeness = .complete,
    /// Exclusive retained prefix boundary when partial. Not a scanner cursor,
    /// first diagnostic position, or a promise that validation stopped here.
    retained_end: u32 = 0,
    pub fn scopeComplete(self: Document) bool {
        return self.state == .complete;
    }
    /// This standalone tree only. No claim about unrequested embedded parsers.
    pub fn subtreeComplete(self: Document) bool {
        return self.scopeComplete();
    }
    /// Unrepresented tail, possibly zero-length for a missing closer at EOF.
    pub fn unrepresented(self: Document) ?Span {
        if (self.state == .complete) return null;
        return .{ .start = self.retained_end, .len = @intCast(self.source.len - self.retained_end) };
    }
    pub fn nodeCount(self: Document) u32 {
        return @intCast(self.records.len);
    }
    pub fn node(self: Document, id: NodeId) ?NodeView {
        if (@intFromEnum(id) >= self.records.len) return null;
        return .{ .document = self, .id = id };
    }
    pub fn roots(self: Document) Iterator {
        return .{ .document = self, .next_index = 0, .end = self.nodeCount() };
    }
};
pub const NodeView = struct {
    document: Document,
    id: NodeId,
    pub fn record(self: NodeView) Node {
        var node = self.document.records[@intFromEnum(self.id)];
        if (node.subtree_end == 0) {
            std.debug.assert(self.document.state == .partial and node.name.len != 0);
            node.subtree_end = self.document.nodeCount();
            node.span.len = self.document.retained_end - node.span.start;
        }
        return node;
    }
    pub fn state(self: NodeView) Completeness {
        return if (self.document.records[@intFromEnum(self.id)].subtree_end == 0) .partial else .complete;
    }
    pub fn scopeComplete(self: NodeView) bool {
        return self.state() == .complete;
    }
    /// In a retained prefix, a closed element has no unfinished descendants.
    pub fn subtreeComplete(self: NodeView) bool {
        return self.scopeComplete();
    }
    /// Header completeness is independent of the element's missing closer.
    /// Leaves do not have an opening header.
    pub fn headerComplete(self: NodeView) ?bool {
        const node = self.document.records[@intFromEnum(self.id)];
        if (node.kind() != .element) return null;
        return node.subtree_end != 0 or node.span.slice(self.document.source)[node.span.len - 1] == '>';
    }
    pub fn kind(self: NodeView) Kind {
        return self.record().kind();
    }
    pub fn span(self: NodeView) Span {
        return self.record().span;
    }
    pub fn raw(self: NodeView) []const u8 {
        return self.span().slice(self.document.source);
    }
    /// Borrowed leaf body: text unchanged, comment/CDATA delimiters removed.
    /// Never decodes references; elements have no single leaf body.
    pub fn content(self: NodeView) ?[]const u8 {
        const bytes = self.raw();
        return switch (self.kind()) {
            .element => null,
            .text => bytes,
            .comment => bytes[4 .. bytes.len - 3],
            .cdata => bytes[9 .. bytes.len - 3],
        };
    }
    pub fn name(self: NodeView) ?[]const u8 {
        const r = self.record();
        return if (r.kind() == .element) r.name.slice(self.document.source) else null;
    }
    pub fn children(self: NodeView) Iterator {
        return .{ .document = self.document, .next_index = @intFromEnum(self.id) + 1, .end = self.record().subtree_end };
    }
    /// O(log A) lookup into the sparse pool, then O(1) per iterator step.
    /// Requires Document's globally owner-sorted attribute pool. This lookup
    /// deliberately does not rescan the pool to audit caller-built documents.
    pub fn attributes(self: NodeView) AttributeIterator {
        const pool = self.document.attributes;
        var lo: u32 = 0;
        var hi: u32 = @intCast(pool.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (@intFromEnum(pool[mid].owner) < @intFromEnum(self.id)) lo = mid + 1 else hi = mid;
        }
        return .{ .document = self.document, .owner = self.id, .index = lo };
    }
};

/// Local node metadata precondition, checked during content validation in safety
/// builds. O(1), without source-byte scans or scratch. Does not audit ancestor
/// containment or certify caller-built forests; Document's contract still applies.
pub fn nodeInvariant(document: *const Document, index: u32) bool {
    const raw = document.records[index];
    if (raw.subtree_end == 0 and (document.state != .partial or raw.name.len == 0 or
        document.retained_end > document.source.len or raw.span.endOffset() > document.retained_end)) return false;
    const node = (document.node(@enumFromInt(index)) orelse return false).record();
    if (node.span.len == 0 or node.span.endOffset() > document.source.len or
        node.subtree_end <= index or node.subtree_end > document.records.len) return false;
    if (index > 0 and document.records[index - 1].span.start >= node.span.start) return false;
    if (node.name.len != 0)
        return node.name.start >= node.span.start and node.name.endOffset() <= node.span.endOffset();
    if (node.subtree_end != index + 1) return false;
    // Inspect the discriminator before calling kind(); invalid metadata is a
    // precondition failure, never silently interpreted as a text leaf.
    return switch (node.name.start) {
        @intFromEnum(Kind.text) => true,
        @intFromEnum(Kind.comment) => node.span.len >= 7,
        @intFromEnum(Kind.cdata) => node.span.len >= 12,
        else => false,
    };
}

/// Local attribute metadata precondition, checked during validation/scratch sizing
/// in safety builds. O(1), without source-byte scans or scratch allocation.
/// Not a general syntax verifier or a public document-building API.
pub fn attributeInvariant(document: *const Document, index: u32) bool {
    const attribute = document.attributes[index];
    const owner = @intFromEnum(attribute.owner);
    if (owner >= document.records.len) return false;
    const raw = document.records[owner];
    if (raw.subtree_end == 0 and (document.state != .partial or raw.name.len == 0 or
        document.retained_end > document.source.len or raw.span.endOffset() > document.retained_end)) return false;
    const node = document.node(attribute.owner).?.record();
    if (node.name.len == 0 or node.span.endOffset() > document.source.len or
        node.name.start < node.span.start or node.name.endOffset() > node.span.endOffset() or
        attribute.name.len == 0 or attribute.name.start < node.name.endOffset() or
        attribute.name.endOffset() > attribute.value.start or attribute.value.len < 2 or
        attribute.value.endOffset() > node.span.endOffset()) return false;
    if (index > 0) {
        const previous = document.attributes[index - 1];
        if (@intFromEnum(previous.owner) > owner or previous.value.endOffset() > attribute.name.start) return false;
    }
    return true;
}
pub const AttributeView = struct {
    document: Document,
    index: u32,
    pub fn record(self: AttributeView) Attribute {
        return self.document.attributes[self.index];
    }
    pub fn span(self: AttributeView) Span {
        const r = self.record();
        return .{ .start = r.name.start, .len = r.value.start + r.value.len - r.name.start };
    }
    pub fn raw(self: AttributeView) []const u8 {
        return self.span().slice(self.document.source);
    }
    pub fn name(self: AttributeView) []const u8 {
        return self.record().name.slice(self.document.source);
    }
    pub fn rawValue(self: AttributeView) []const u8 {
        return self.record().value.slice(self.document.source);
    }
    /// Only removes delimiters. No entity decoding, unescaping or whitespace folding.
    pub fn value(self: AttributeView) []const u8 {
        const raw_value = self.rawValue();
        return raw_value[1 .. raw_value.len - 1];
    }
};
pub const AttributeIterator = struct {
    document: Document,
    owner: NodeId,
    index: u32,
    pub fn next(self: *AttributeIterator) ?AttributeView {
        if (self.index == self.document.attributes.len or self.document.attributes[self.index].owner != self.owner) return null;
        const view: AttributeView = .{ .document = self.document, .index = self.index };
        self.index += 1;
        return view;
    }
};
pub const Iterator = struct {
    document: Document,
    next_index: u32,
    end: u32,
    pub fn next(self: *Iterator) ?NodeView {
        std.debug.assert(self.next_index <= self.end and self.end <= self.document.records.len);
        if (self.next_index == self.end) return null;
        const id: NodeId = @enumFromInt(self.next_index);
        const subtree_end = self.document.node(id).?.record().subtree_end;
        // Fail at the corrupt interval, before leaving this iterator's boundary
        // or looping forever. These are preconditions, not a document audit.
        std.debug.assert(subtree_end > self.next_index and subtree_end <= self.end);
        self.next_index = subtree_end;
        return .{ .document = self.document, .id = id };
    }
};

/// Private syntax-event consumer. Both storage paths share these methods.
pub const Builder = struct {
    source: []const u8,
    list: std.ArrayList(Node) = .empty,
    attributes: std.ArrayList(Attribute) = .empty,
    allocator: ?std.mem.Allocator = null,
    publication: ?Completeness = null,
    retained_end: u32 = 0,
    pub const Error = error{ OutOfMemory, NodeStorageExhausted, AttributeStorageExhausted };

    pub fn fixed(source: []const u8, storage: Storage) Builder {
        return .{ .source = source, .list = .initBuffer(storage.nodes), .attributes = .initBuffer(storage.attributes) };
    }
    pub fn growing(source: []const u8, allocator: std.mem.Allocator) Builder {
        return .{ .source = source, .allocator = allocator };
    }
    pub fn begin(_: *Builder) Error!void {}
    fn append(self: *Builder, record: Node) Error!u32 {
        const index: u32 = @intCast(self.list.items.len);
        if (self.allocator) |a| try self.list.append(a, record) else {
            if (self.list.items.len == self.list.capacity) return error.NodeStorageExhausted;
            self.list.appendAssumeCapacity(record);
        }
        return index;
    }
    pub fn open(self: *Builder, span: Span, name: Span) Error!u32 {
        return self.append(.{ .span = span, .name = name, .subtree_end = @intCast(self.list.items.len + 1) });
    }
    pub fn leaf(self: *Builder, kind: Kind, span: Span) Error!void {
        std.debug.assert(kind != .element);
        _ = try self.append(.{ .span = span, .name = .{ .start = @intFromEnum(kind), .len = 0 }, .subtree_end = @intCast(self.list.items.len + 1) });
    }
    pub fn attribute(self: *Builder, owner: u32, name: Span, value: Span) Error!void {
        const record: Attribute = .{ .owner = @enumFromInt(owner), .name = name, .value = value };
        if (self.allocator) |a| try self.attributes.append(a, record) else {
            if (self.attributes.items.len == self.attributes.capacity) return error.AttributeStorageExhausted;
            self.attributes.appendAssumeCapacity(record);
        }
    }
    pub fn close(self: *Builder, handle: u32, end: u32) Error!void {
        const node = &self.list.items[handle];
        node.span.len = end - node.span.start;
        node.subtree_end = @intCast(self.list.items.len);
    }
    /// These hooks are called only by partial-retention specializations. No
    /// sidecar pool, source copy, or allocation is needed on the failure path.
    pub fn unfinished(self: *Builder, handle: u32) void {
        self.list.items[handle].subtree_end = 0;
    }
    pub fn header(self: *Builder, handle: u32, end: u32) void {
        const node = &self.list.items[handle];
        node.span.len = end - node.span.start;
    }
    pub fn retainThrough(self: *Builder, end: u32) void {
        self.retained_end = end;
    }
    pub fn freezePrefix(self: *Builder) void {
        self.publication = .partial;
    }
    pub fn commit(self: *Builder) Error!void {
        self.publication = .complete;
    }
    /// Best-effort finalization of owned output, outside bounded execution.
    /// Never allocate/copy or fail a successful parse just to discard slack.
    pub fn trimCapacity(self: *Builder) void {
        const allocator = self.allocator orelse return;
        inline for (.{ "list", "attributes" }) |field| {
            const pool = &@field(self, field);
            if (pool.capacity != pool.items.len and allocator.resize(pool.allocatedSlice(), pool.items.len))
                pool.capacity = pool.items.len;
        }
    }
    pub fn abort(self: *Builder) void {
        self.list.clearRetainingCapacity();
        self.attributes.clearRetainingCapacity();
        self.publication = null;
        self.retained_end = 0;
    }
    pub fn document(self: *const Builder) ?Document {
        const state = self.publication orelse return null;
        return .{ .source = self.source, .records = self.list.items, .attributes = self.attributes.items, .state = state, .retained_end = if (state == .complete) @intCast(self.source.len) else self.retained_end };
    }
    pub fn deinit(self: *Builder) void {
        if (self.allocator) |a| {
            self.list.deinit(a);
            self.attributes.deinit(a);
        }
        self.* = .{ .source = &.{} };
    }
};

/// Second event consumer: no retained node storage or hidden tree.
pub const Counter = struct {
    pub const Error = error{};
    pub fn begin(_: *Counter) Error!void {}
    pub fn open(_: *Counter, _: Span, _: Span) Error!u32 {
        return 0;
    }
    pub fn leaf(_: *Counter, _: Kind, _: Span) Error!void {}
    pub fn attribute(_: *Counter, _: u32, _: Span, _: Span) Error!void {}
    pub fn close(_: *Counter, _: u32, _: u32) Error!void {}
    pub fn commit(_: *Counter) Error!void {}
    pub fn abort(_: *Counter) void {}
    pub fn unfinished(_: *Counter, _: u32) void {}
    pub fn header(_: *Counter, _: u32, _: u32) void {}
    pub fn retainThrough(_: *Counter, _: u32) void {}
    pub fn freezePrefix(_: *Counter) void {}
};

test "attribute metadata precondition rejects interleaved owners and invalid spans" {
    const source = "<a x='1'><b y='2' z='3'/></a>";
    const S = struct {
        fn span(bytes: []const u8) Span {
            return .{ .start = @intCast(std.mem.indexOf(u8, source, bytes).?), .len = @intCast(bytes.len) };
        }
    };
    var nodes = [_]Node{
        .{ .span = S.span(source), .name = S.span("a"), .subtree_end = 2 },
        .{ .span = S.span("<b y='2' z='3'/>"), .name = S.span("b"), .subtree_end = 2 },
    };
    const original = [_]Attribute{
        .{ .owner = @enumFromInt(0), .name = S.span("x"), .value = S.span("'1'") },
        .{ .owner = @enumFromInt(1), .name = S.span("y"), .value = S.span("'2'") },
        .{ .owner = @enumFromInt(1), .name = S.span("z"), .value = S.span("'3'") },
    };
    var attributes = original;
    const doc: Document = .{ .source = source, .records = &nodes, .attributes = &attributes };
    for (0..3) |i| try std.testing.expect(attributeInvariant(&doc, @intCast(i)));
    // Source spans remain ordered and lie within a's raw span, but ownership
    // 0,1,0 violates the contiguous-owner contract the validator depends on.
    attributes[2].owner = @enumFromInt(0);
    try std.testing.expect(!attributeInvariant(&doc, 2));
    attributes = original;
    attributes[2].owner = @enumFromInt(99);
    try std.testing.expect(!attributeInvariant(&doc, 2));
    attributes = original;
    attributes[2].value.len = std.math.maxInt(u32);
    try std.testing.expect(!attributeInvariant(&doc, 2));
    attributes = original;
    attributes[2] = original[1];
    try std.testing.expect(!attributeInvariant(&doc, 2));
    attributes = original;
    attributes[2].value.len = 1;
    try std.testing.expect(!attributeInvariant(&doc, 2));
    attributes = original;
    nodes[1].name.len = 0;
    try std.testing.expect(!attributeInvariant(&doc, 1));
}

test "node metadata rejects invalid leaf discriminators and out-of-bounds spans" {
    var nodes = [_]Node{.{ .span = .{ .start = 0, .len = 4 }, .name = .{ .start = @intFromEnum(Kind.text), .len = 0 }, .subtree_end = 1 }};
    const doc: Document = .{ .source = "text", .records = &nodes, .attributes = &.{} };
    try std.testing.expect(nodeInvariant(&doc, 0));
    const original = nodes[0];
    nodes[0].name.start = 5;
    try std.testing.expect(!nodeInvariant(&doc, 0));
    nodes[0] = original;
    nodes[0].span.len = std.math.maxInt(u32);
    try std.testing.expect(!nodeInvariant(&doc, 0));
    nodes[0] = original;
    nodes[0].subtree_end = 2;
    try std.testing.expect(!nodeInvariant(&doc, 0));
    nodes[0] = original;
    nodes[0].name = .{ .start = 3, .len = 2 };
    try std.testing.expect(!nodeInvariant(&doc, 0));
}
