//! Immutable attribute maps: values and origins stay in the written pools.
//! Snapshots share unchanged AVL branches; no node-default or edge-set copying.
const std = @import("std");
const t = @import("topology.zig");
const syntax = @import("../dot/syntax.zig");
const encoding = @import("parser_support").encoding;
const names = @import("names.zig");
const r = @import("resources.zig");
pub const none = names.empty;
pub const Kind = enum { graph, node, edge };
/// Port sides name the written statement, not the stored edge's orientation.
pub const Origin = union(enum) { declaration: u32, connection: t.ConnectionId, written_left_port: t.ConnectionId, written_right_port: t.ConnectionId };
pub const PortReference = struct { connection: t.ConnectionId, side: enum { left, right } };
pub const Value = union(enum) { written: t.Range, port: PortReference, empty };
pub const Resolved = struct {
    value: Value,
    /// Inherited means a default or another scope supplied this value.
    kind: enum { explicit, inherited, derived, empty },
    /// Empty values name the assignment that introduced the key, not a fake
    /// assignment of an empty string.
    attribute: ?u32,
    /// Present for a derived endpoint value (or its introduced empty), which
    /// has no written attribute assignment. Never invent a source range.
    port_key: ?@import("ports.zig").Key = null,
    origin: Origin,
    scope: t.ScopeId,
};
pub const Key = struct { name: t.Range, hash: u64, first_attribute: u32, kind: Kind };
pub const Meta = struct { key: u32 = none, origin: Origin = undefined };
pub const Cell = struct { key: u32, attribute: u32, left: u32 = none, right: u32 = none, height: u8 = 1 };
pub const Scope = struct {
    graph: u32 = none,
    node: u32 = none,
    edge: u32 = none,
    local_node: u32 = none,
    local_edge: u32 = none,
    parent_node: u32 = none,
    parent_edge: u32 = none,
};

pub const Store = struct {
    keys: std.ArrayList(Key) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    table: names.Table = .{},
    meta: []Meta = &.{},
    scopes: []Scope = &.{},
    connection_defaults: []u32 = &.{},

    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        self.keys.deinit(a);
        self.cells.deinit(a);
        self.table.deinit(a);
        a.free(self.meta);
        a.free(self.scopes);
        a.free(self.connection_defaults);
    }
    pub fn retainedBytes(self: Store) usize {
        return self.keys.capacity * @sizeOf(Key) + self.cells.capacity * @sizeOf(Cell) +
            self.table.slots.len * 4 + self.meta.len * @sizeOf(Meta) +
            self.scopes.len * @sizeOf(Scope) + self.connection_defaults.len * 4;
    }
    pub fn init(self: *Store, a: std.mem.Allocator, attributes: usize, scopes: usize, connections: usize, work: *r.Work) r.Error!void {
        if (attributes == 0) return;
        self.meta = try a.alloc(Meta, attributes);
        for (self.meta) |*meta| {
            try work.spend(1);
            meta.* = .{};
        }
        self.scopes = try a.alloc(Scope, scopes);
        for (self.scopes) |*scope| {
            try work.spend(1);
            scope.* = .{};
        }
        self.connection_defaults = try a.alloc(u32, connections);
        // Written connections initialize their own default snapshot.
    }
    pub fn hashFor(self: *const Store, id: u32) u64 {
        return self.keys.items[id].hash;
    }
    pub fn bind(self: *Store, comptime actual: encoding.Actual, a: std.mem.Allocator, source: []const u8, attributes: []const syntax.Attribute, range: syntax.AttributeRange, kind: Kind, origin: Origin, work: *r.Work) r.Error!void {
        if (range.start > attributes.len or range.len > attributes.len - range.start) return error.InvalidDocument;
        for (range.start..range.start + range.len) |index| {
            try work.spend(1);
            if (self.meta[index].key != none) continue; // Shared chain attributes.
            const name = attributes[index].key;
            const raw = source[name.start..][0..name.len];
            const hash = (try names.hash(actual, raw, work)) ^ @as(u64, @backingInt(kind));
            if (comptime encoding.Reader(actual).width != 1) {
                const value = attributes[index].value;
                _ = try names.hash(actual, source[value.start..][0..value.len], work);
            }
            var found: ?u32 = null;
            if (self.table.slots.len != 0) {
                var at: usize = @intCast(hash & (self.table.slots.len - 1));
                while (self.table.slots[at] != none) : (at = (at + 1) & (self.table.slots.len - 1)) {
                    try work.spend(1);
                    const id = self.table.slots[at];
                    const key = self.keys.items[id];
                    if (key.hash == hash and key.kind == kind and try names.eql(actual, source[key.name.start..][0..key.name.len], raw, work)) {
                        found = id;
                        break;
                    }
                }
            }
            const id = found orelse blk: {
                const id = try r.index(self.keys.items.len);
                try self.table.prepare(a, work, self);
                try self.keys.append(a, .{ .name = name, .hash = hash, .kind = kind, .first_attribute = @intCast(index) });
                try self.table.insert(hash, id, work);
                break :blk id;
            };
            self.meta[index] = .{ .key = id, .origin = origin };
        }
    }
    pub fn height(self: Store, id: u32) u8 {
        return if (id == none) 0 else self.cells.items[id].height;
    }
    pub fn add(self: *Store, a: std.mem.Allocator, cell: Cell, limit: u32, work: *r.Work) r.Error!u32 {
        try work.spend(1);
        if (self.cells.items.len >= limit) return error.AttributeStateLimit;
        const id = try r.index(self.cells.items.len);
        var value = cell;
        value.height = 1 + @max(self.height(value.left), self.height(value.right));
        try self.cells.append(a, value);
        return id;
    }
    pub fn rotate(self: *Store, a: std.mem.Allocator, root: u32, comptime left: bool, limit: u32, work: *r.Work) r.Error!u32 {
        var lower = self.cells.items[root];
        var upper = self.cells.items[if (left) lower.right else lower.left];
        if (left) lower.right = upper.left else lower.left = upper.right;
        const child = try self.add(a, lower, limit, work);
        if (left) upper.left = child else upper.right = child;
        return self.add(a, upper, limit, work);
    }
    pub fn set(self: *Store, a: std.mem.Allocator, root: u32, key: u32, attribute: u32, limit: u32, work: *r.Work) r.Error!u32 {
        // An AVL tree with <2^32 cells has height <48. This is an implementation
        // bound, not input nesting; no recursion or source-sized stack.
        var path: [48]u32 = undefined;
        var depth: usize = 0;
        var cursor = root;
        while (cursor != none) {
            try work.spend(1);
            const cell = self.cells.items[cursor];
            if (cell.key == key) {
                if (cell.attribute == attribute) return root;
                break;
            }
            if (depth == path.len) return error.IndexLimit;
            path[depth] = cursor;
            depth += 1;
            cursor = if (key < cell.key) cell.left else cell.right;
        }
        var child = if (cursor == none) try self.add(a, .{ .key = key, .attribute = attribute }, limit, work) else blk: {
            var cell = self.cells.items[cursor];
            cell.attribute = attribute;
            break :blk try self.add(a, cell, limit, work);
        };
        while (depth != 0) {
            depth -= 1;
            var cell = self.cells.items[path[depth]];
            if (key < cell.key) cell.left = child else cell.right = child;
            const balance = @as(i16, self.height(cell.left)) - self.height(cell.right);
            if (balance > 1) {
                const branch = self.cells.items[cell.left];
                if (self.height(branch.left) < self.height(branch.right)) cell.left = try self.rotate(a, cell.left, true, limit, work);
                child = try self.rotate(a, try self.add(a, cell, limit, work), false, limit, work);
            } else if (balance < -1) {
                const branch = self.cells.items[cell.right];
                if (self.height(branch.right) < self.height(branch.left)) cell.right = try self.rotate(a, cell.right, false, limit, work);
                child = try self.rotate(a, try self.add(a, cell, limit, work), true, limit, work);
            } else child = try self.add(a, cell, limit, work);
        }
        return child;
    }
    pub fn lookup(self: Store, root: u32, key: u32, work: anytype) r.Error!?u32 {
        var cursor = root;
        while (cursor != none) {
            try work.spend(1);
            const cell = self.cells.items[cursor];
            if (cell.key == key) return cell.attribute;
            cursor = if (key < cell.key) cell.left else cell.right;
        }
        return null;
    }
    pub fn apply(self: *Store, a: std.mem.Allocator, root: u32, range: syntax.AttributeRange, limit: u32, work: *r.Work) r.Error!u32 {
        var next = root;
        for (range.start..range.start + range.len) |id| next = try self.set(a, next, self.meta[id].key, @intCast(id), limit, work);
        return next;
    }
    fn overlay(self: *Store, a: std.mem.Allocator, base: u32, local: u32, limit: u32, work: *r.Work) r.Error!u32 {
        var path: [48]u32 = undefined;
        var depth: usize = 0;
        var cursor = local;
        var result = base;
        while (cursor != none or depth != 0) {
            while (cursor != none) {
                try work.spend(1);
                if (depth == path.len) return error.IndexLimit;
                path[depth] = cursor;
                depth += 1;
                cursor = self.cells.items[cursor].left;
            }
            depth -= 1;
            const cell = self.cells.items[path[depth]];
            result = try self.set(a, result, cell.key, cell.attribute, limit, work);
            cursor = cell.right;
        }
        return result;
    }
    pub fn enter(self: *Store, a: std.mem.Allocator, id: u32, parent: u32, first: bool, limit: u32, work: *r.Work) r.Error!void {
        if (self.scopes.len == 0 or id == 0) return;
        const inherited = self.scopes[parent];
        const scope = &self.scopes[id];
        if (first) scope.graph = inherited.graph;
        // Graph attributes freeze at scope creation. Node/edge defaults inherit
        // the current parent unless locally overridden (Graphviz 16.0.0).
        if (scope.parent_node != inherited.node) {
            scope.node = try self.overlay(a, inherited.node, scope.local_node, limit, work);
            scope.parent_node = inherited.node;
        }
        if (scope.parent_edge != inherited.edge) {
            scope.edge = try self.overlay(a, inherited.edge, scope.local_edge, limit, work);
            scope.parent_edge = inherited.edge;
        }
    }
};

pub fn findKey(comptime caps: encoding.Capabilities, graph: anytype, kind: Kind, key: []const u8, work: anytype) r.Error!?u32 {
    try work.spend(key.len);
    const store = &graph.attribute_data;
    if (store.table.slots.len == 0) return null;
    const hash = std.hash.Wyhash.hash(0, key) ^ @as(u64, @backingInt(kind));
    var at: usize = @intCast(hash & (store.table.slots.len - 1));
    while (store.table.slots[at] != none) : (at = (at + 1) & (store.table.slots.len - 1)) {
        try work.spend(1);
        const id = store.table.slots[at];
        const entry = store.keys.items[id];
        if (entry.kind != kind or entry.hash != hash) continue;
        const reader = if (graph.source_info.encoding == .ascii and caps.utf8) .utf8 else graph.source_info.encoding;
        const matches = switch (reader) {
            inline else => |actual| if (comptime caps.allows(actual)) try names.matches(actual, graph.text(entry.name), key, work) else return error.UnsupportedEncoding,
        };
        if (matches) return id;
    }
    return null;
}

/// Shared indexed lookup for checked ID APIs and certified views. No history scan.
pub fn lookupNode(comptime caps: encoding.Capabilities, graph: anytype, id: t.NodeId, key: []const u8, work: anytype) r.Error!?Resolved {
    const key_id = try findKey(caps, graph, .node, key, work) orelse return null;
    const node = graph.nodes[@backingInt(id)];
    const value = try graph.attribute_data.lookup(node.attribute_state, key_id, work);
    const scope = graph.occurrences[@backingInt(graph.mentions[node.first_mention].occurrence)].scope;
    return resolved(graph, value orelse graph.attribute_data.keys.items[key_id].first_attribute, .node, scope, value == null);
}

pub fn lookupScope(comptime caps: encoding.Capabilities, graph: anytype, id: t.ScopeId, key: []const u8, work: anytype) r.Error!?Resolved {
    const key_id = try findKey(caps, graph, .graph, key, work) orelse return null;
    const value = try graph.attribute_data.lookup(graph.attribute_data.scopes[@backingInt(id)].graph, key_id, work);
    return resolved(graph, value orelse graph.attribute_data.keys.items[key_id].first_attribute, .graph, id, value == null);
}

pub fn resolved(graph: anytype, attribute: u32, target: Kind, scope: t.ScopeId, empty: bool) Resolved {
    const meta = graph.attribute_data.meta[attribute];
    const origin_scope = switch (meta.origin) {
        .declaration => |id| graph.occurrences[@backingInt(graph.declarations[id].occurrence)].scope,
        .connection => |id| graph.occurrences[@backingInt(graph.connections[@backingInt(id)].occurrence)].scope,
        .written_left_port, .written_right_port => unreachable, // Only written assignments have Meta.
    };
    const inherited = switch (meta.origin) {
        .declaration => |id| if (target == .graph) origin_scope != scope else graph.declarations[id].target == .defaults,
        .connection => false,
        .written_left_port, .written_right_port => unreachable,
    };
    return .{ .value = if (empty) .empty else .{ .written = graph.attributes[attribute].value }, .kind = if (empty) .empty else if (inherited) .inherited else .explicit, .attribute = attribute, .origin = meta.origin, .scope = origin_scope };
}

pub inline fn resolvedConnection(graph: anytype, attribute: u32, connection: t.ConnectionId) Resolved {
    // An explicit winner is already known to belong to this contribution.
    // A chain shares its written range: use the actual link's provenance,
    // without resolving and then discarding the first link's origin/defaults.
    return .{
        .value = .{ .written = graph.attributes[attribute].value },
        .kind = .explicit,
        .attribute = attribute,
        .origin = .{ .connection = connection },
        .scope = graph.occurrences[@backingInt(graph.connections[@backingInt(connection)].occurrence)].scope,
    };
}
