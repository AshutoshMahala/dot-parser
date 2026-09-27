//! Compact source-order forest. Trees are preorder intervals, not per-node
//! child arrays. No decoding, parent lookup table, normalization or validation.
const std = @import("std");
const Span = @import("parser_support").location.Span;
pub const NodeId = enum(u32) { _ };
pub const Kind = enum { element, text };
pub const Node = struct {
    span: Span,
    /// Zero length identifies text; element names cannot be empty.
    name: Span,
    /// First index after this node and all its descendants.
    subtree_end: u32,
    pub fn kind(self: Node) Kind {
        return if (self.name.len == 0) .text else .element;
    }
};
pub const Storage = struct { nodes: []Node = &.{} };
pub fn Fixed(comptime capacity: u32) type {
    return struct {
        nodes: [capacity]Node = undefined,
        pub const byte_size = @sizeOf(@This());
        pub fn storage(self: *@This()) Storage {
            return .{ .nodes = &self.nodes };
        }
    };
}

/// Non-owning completed view. Source and backing records must remain alive and
/// unchanged. No deinit: disposal belongs to the owning result or caller storage.
pub const Document = struct {
    source: []const u8,
    records: []const Node,
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
        return self.document.records[@intFromEnum(self.id)];
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
    pub fn name(self: NodeView) ?[]const u8 {
        const r = self.record();
        return if (r.kind() == .element) r.name.slice(self.document.source) else null;
    }
    pub fn children(self: NodeView) Iterator {
        return .{ .document = self.document, .next_index = @intFromEnum(self.id) + 1, .end = self.record().subtree_end };
    }
};
pub const Iterator = struct {
    document: Document,
    next_index: u32,
    end: u32,
    pub fn next(self: *Iterator) ?NodeView {
        if (self.next_index == self.end) return null;
        const id: NodeId = @enumFromInt(self.next_index);
        self.next_index = self.document.records[self.next_index].subtree_end;
        return .{ .document = self.document, .id = id };
    }
};

/// Private syntax-event consumer. Both storage paths share these methods.
pub const Builder = struct {
    source: []const u8,
    list: std.ArrayList(Node) = .empty,
    allocator: ?std.mem.Allocator = null,
    committed: bool = false,
    pub const Error = error{ OutOfMemory, NodeStorageExhausted };

    pub fn fixed(source: []const u8, storage: Storage) Builder {
        return .{ .source = source, .list = .initBuffer(storage.nodes) };
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
    pub fn text(self: *Builder, span: Span) Error!void {
        _ = try self.append(.{ .span = span, .name = .{ .start = 0, .len = 0 }, .subtree_end = @intCast(self.list.items.len + 1) });
    }
    pub fn close(self: *Builder, handle: u32, end: u32) Error!void {
        const node = &self.list.items[handle];
        node.span.len = end - node.span.start;
        node.subtree_end = @intCast(self.list.items.len);
    }
    pub fn commit(self: *Builder) Error!void {
        self.committed = true;
    }
    pub fn abort(self: *Builder) void {
        self.list.clearRetainingCapacity();
        self.committed = false;
    }
    pub fn document(self: *const Builder) ?Document {
        return if (self.committed) .{ .source = self.source, .records = self.list.items } else null;
    }
    pub fn deinit(self: *Builder) void {
        if (self.allocator) |a| self.list.deinit(a);
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
    pub fn text(_: *Counter, _: Span) Error!void {}
    pub fn close(_: *Counter, _: u32, _: u32) Error!void {}
    pub fn commit(_: *Counter) Error!void {}
    pub fn abort(_: *Counter) void {}
};
