//! Forward attribute folding. Defaults remain borrowed immutable maps;
//! explicit winners use mutable, per-edge AVL maps (no retained update history).
const std = @import("std");
const t = @import("topology.zig");
const attrs = @import("attributes.zig");
const r = @import("resources.zig");
const encoding = @import("parser_support").encoding;
const Unmetered = @import("../dot/identifier_cursor.zig").Unmetered;
const none = attrs.none;
const ports = @import("ports.zig");

pub const Cell = struct {
    key: u32,
    attribute: u32,
    connection: t.ConnectionId,
    left: u32 = none,
    right: u32 = none,
    height: u8 = 1,
};

/// Unlike the IR's persistent maps, these maps have disjoint ownership and can
/// update in place. One cell per explicit (edge, key), not per contribution.
pub fn Builder(comptime with_ports: bool) type {
    return struct {
        const Self = @This();
        roots: std.ArrayList(u32) = .empty,
        cells: std.ArrayList(Cell) = .empty,
        keys: std.ArrayList(u32) = .empty,
        limit: u32,
        port_keys: if (with_ports) ports.Keys else void = if (with_ports) .{} else {},
        port_introductions: if (with_ports) [2]?ports.Selection else void = if (with_ports) .{ null, null } else {},
        ports_initialized: if (with_ports) bool else void = if (with_ports) false else {},

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.roots.deinit(a);
            self.cells.deinit(a);
            self.keys.deinit(a);
        }
        fn height(self: *const Self, id: u32) u8 {
            return if (id == none) 0 else self.cells.items[id].height;
        }
        fn refresh(self: *Self, id: u32) void {
            const cell = &self.cells.items[id];
            cell.height = 1 + @max(self.height(cell.left), self.height(cell.right));
        }
        fn rotate(self: *Self, root: u32, comptime left: bool) u32 {
            const lower = &self.cells.items[root];
            const upper_id = if (left) lower.right else lower.left;
            const upper = &self.cells.items[upper_id];
            if (left) {
                lower.right = upper.left;
                upper.left = root;
            } else {
                lower.left = upper.right;
                upper.right = root;
            }
            self.refresh(root);
            self.refresh(upper_id);
            return upper_id;
        }
        /// One bounded ancestor update, shared by direct and resumable folding.
        pub inline fn link(self: *Self, id: u32, key: u32, child: u32) u32 {
            const cell = &self.cells.items[id];
            if (key < cell.key) cell.left = child else cell.right = child;
            const left_height = self.height(cell.left);
            const right_height = self.height(cell.right);
            const balance = @as(i16, left_height) - right_height;
            if (balance > 1) {
                const branch = self.cells.items[cell.left];
                if (self.height(branch.left) < self.height(branch.right)) cell.left = self.rotate(cell.left, true);
                return self.rotate(id, false);
            } else if (balance < -1) {
                const branch = self.cells.items[cell.right];
                if (self.height(branch.right) < self.height(branch.left)) cell.right = self.rotate(cell.right, false);
                return self.rotate(id, true);
            } else {
                cell.height = 1 + @max(left_height, right_height);
                return id;
            }
        }
        fn set(self: *Self, a: std.mem.Allocator, root: u32, key: u32, attribute: u32, connection: t.ConnectionId, work: *r.Work) r.Error!u32 {
            // With u32 cell IDs an AVL path has fewer than 48 entries. No recursion
            // or source-dependent stack, and rotations cannot allocate or fail.
            var path: [48]u32 = undefined;
            var depth: u32 = 0;
            var cursor = root;
            while (cursor != none) {
                try work.spend(1);
                const cell = &self.cells.items[cursor];
                if (cell.key == key) {
                    cell.attribute = attribute;
                    cell.connection = connection;
                    return root;
                }
                if (depth == path.len) return error.IndexLimit;
                path[depth] = cursor;
                depth += 1;
                cursor = if (key < cell.key) cell.left else cell.right;
            }
            try work.spend(1);
            if (self.cells.items.len >= self.limit) return error.AttributeStateLimit;
            var child = try r.index(self.cells.items.len);
            try self.cells.append(a, .{ .key = key, .attribute = attribute, .connection = connection });
            while (depth != 0) {
                try work.spend(1);
                depth -= 1;
                const id = path[depth];
                child = self.link(id, key, child);
            }
            return child;
        }
        pub fn apply(self: *Self, graph: anytype, edge: u32, connection: t.ConnectionId, target: if (with_ports) t.Edge else void, a: std.mem.Allocator, work: *r.Work) r.Error!void {
            const source = graph.connections[@backingInt(connection)];
            const range = source.attributes;
            if (range.len == 0 and (!with_ports or (source.left.port == .none and source.right.port == .none))) return;
            if (with_ports and !self.ports_initialized) {
                self.port_keys = try graph.portKeys(work);
                self.ports_initialized = true;
            }
            // Attribute-free materialization needs no root/cell allocation. Gaps
            // before the first explicit update carry no map, not copied defaults.
            while (self.roots.items.len <= edge) {
                try work.spend(1);
                try self.roots.append(a, none);
            }
            var root = self.roots.items[edge];
            if (with_ports) {
                for (ports.suffixes(source, connection, target), 0..) |suffix, i| if (suffix) |selection| {
                    try work.spend(1);
                    if (self.port_introductions[i] == null) self.port_introductions[i] = selection;
                    root = try self.set(a, root, self.port_keys.ids[i], selection.attribute, connection, work);
                };
            }
            for (range.start..range.start + range.len) |attribute| {
                try work.spend(1);
                root = try self.set(a, root, graph.attribute_data.meta[attribute].key, @intCast(attribute), connection, work);
            }
            self.roots.items[edge] = root;
        }
        fn lookup(self: *const Self, edge: u32, key: u32, work: anytype) r.Error!?Cell {
            var cursor = if (edge < self.roots.items.len) self.roots.items[edge] else none;
            while (cursor != none) {
                try work.spend(1);
                const cell = self.cells.items[cursor];
                if (cell.key == key) return cell;
                cursor = if (key < cell.key) cell.left else cell.right;
            }
            return null;
        }
        fn retainedBytes(self: *const Self) usize {
            return self.roots.capacity * @sizeOf(u32) + self.cells.capacity * @sizeOf(Cell) + self.keys.capacity * @sizeOf(u32);
        }
        pub fn transfer(self: Self) Builder(true) {
            return .{ .roots = self.roots, .cells = self.cells, .keys = self.keys, .limit = self.limit, .port_keys = if (with_ports) self.port_keys else .{}, .port_introductions = if (with_ports) self.port_introductions else .{ null, null }, .ports_initialized = if (with_ports) self.ports_initialized else false };
        }
    };
}

pub fn For(comptime Graph: type, comptime caps: encoding.Capabilities) type {
    return struct {
        const Self = @This();
        /// Records keep the first connection/orientation, just like topology-only
        /// materialization. Use edgeIterator for views of the folded attributes.
        edges: []const t.Edge,
        peak_bytes: usize,
        graph: *const Graph,
        allocator: std.mem.Allocator,
        storage: []t.Edge,
        folded: Builder(true),

        /// Owns only output/index storage. Keep the borrowed IR and source alive,
        /// immutable and unmoved. Edge views/iterators additionally borrow this
        /// result; returned AttributeView/ValueView objects borrow only the IR.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.storage);
            self.folded.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn retainedBytes(self: *const Self) usize {
            return self.storage.len * @sizeOf(t.Edge) + self.folded.retainedBytes();
        }
        pub const EdgeView = struct {
            owner: *const Self,
            index: u32,
            edge: t.Edge,

            pub fn from(self: EdgeView) Graph.NodeView {
                return .{ .graph = self.owner.graph, .id = self.edge.from };
            }
            pub fn to(self: EdgeView) Graph.NodeView {
                return .{ .graph = self.owner.graph, .id = self.edge.to };
            }
            /// Indexed lookup on a certified view; never scans contributions.
            pub fn attribute(self: EdgeView, key: []const u8) ?Graph.AttributeView {
                return self.lookup(key, Unmetered{}) catch unreachable;
            }
            pub fn attributeWith(self: EdgeView, key: []const u8, options: r.Options) r.Error!?Graph.AttributeView {
                var work = try r.Work.init(options.limits orelse self.owner.graph.limits, options.cancellation);
                return self.lookup(key, &work);
            }
            /// Same indexed winners as attribute(); these views borrow only the IR.
            pub fn tailPort(self: EdgeView) ?Graph.PortView {
                return if (self.attribute("tailport")) |found|
                    .{ .graph = found.graph, .resolved = found.resolved }
                else
                    null;
            }
            pub fn headPort(self: EdgeView) ?Graph.PortView {
                return if (self.attribute("headport")) |found|
                    .{ .graph = found.graph, .resolved = found.resolved }
                else
                    null;
            }
            pub fn tailPortWith(self: EdgeView, options: r.Options) r.Error!?Graph.PortView {
                return if (try self.attributeWith("tailport", options)) |found|
                    .{ .graph = found.graph, .resolved = found.resolved }
                else
                    null;
            }
            pub fn headPortWith(self: EdgeView, options: r.Options) r.Error!?Graph.PortView {
                return if (try self.attributeWith("headport", options)) |found|
                    .{ .graph = found.graph, .resolved = found.resolved }
                else
                    null;
            }
            /// Internal composition hook; accepts a shared work allowance.
            pub fn lookup(self: EdgeView, key: []const u8, work: anytype) r.Error!?Graph.AttributeView {
                const id = try attrs.findKey(caps, self.owner.graph, .edge, key, work) orelse blk: {
                    if (self.owner.graph.has_ports) inline for (.{ ports.Key.tailport, ports.Key.headport }, 0..) |port_key, i| {
                        if (self.owner.folded.port_introductions[i] != null and std.mem.eql(u8, key, @tagName(port_key))) break :blk self.owner.folded.port_keys.ids[i];
                    };
                    return null;
                };
                return try self.resolve(id, work);
            }
            inline fn resolve(self: EdgeView, key: u32, work: anytype) r.Error!Graph.AttributeView {
                // A port-free IR cannot contain synthetic winners or keys.
                // Keep their resolution out of ordinary/default value loops.
                return if (self.owner.graph.has_ports) self.resolveImpl(true, key, work) else self.resolveImpl(false, key, work);
            }
            inline fn resolveImpl(self: EdgeView, comptime with_ports: bool, key: u32, work: anytype) r.Error!Graph.AttributeView {
                const graph = self.owner.graph;
                if (try self.owner.folded.lookup(self.index, key, work)) |cell| {
                    // Keep this small projection visible to the caller. An
                    // outlined port branch prevents hoisting immutable owner
                    // data even when only ordinary/default values are visited.
                    const resolved = if (with_ports and cell.attribute >= ports.right)
                        @call(.always_inline, ports.resolve, .{ graph, ports.Selection{ .attribute = cell.attribute, .connection = cell.connection }, self.owner.folded.port_keys.key(key).?, false })
                    else
                        attrs.resolvedConnection(graph, cell.attribute, cell.connection);
                    return .{ .graph = graph, .resolved = resolved };
                }
                if (with_ports and key >= ports.right) {
                    const port_key = self.owner.folded.port_keys.key(key).?;
                    return .{ .graph = graph, .resolved = @call(.always_inline, ports.resolve, .{ graph, self.owner.folded.port_introductions[@backingInt(port_key)].?, port_key, true }) };
                }
                const connection = @backingInt(self.edge.first_connection);
                const root = graph.attribute_data.connection_defaults[connection];
                const written = try graph.attribute_data.lookup(root, key, work);
                const scope = graph.occurrences[@backingInt(graph.connections[connection].occurrence)].scope;
                return .{ .graph = graph, .resolved = attrs.resolved(graph, written orelse graph.attribute_data.keys.items[key].first_attribute, .edge, scope, written == null) };
            }
            pub fn attributes(self: EdgeView) AttributeIterator {
                return .{ .edge = self };
            }
            pub fn attributesWith(self: EdgeView, options: r.Options) r.Error!BoundedAttributeIterator {
                return .{ .inner = self.attributes(), .work = try r.Work.init(options.limits orelse self.owner.graph.limits, options.cancellation) };
            }
        };
        pub const EdgeIterator = struct {
            owner: *const Self,
            index: u32 = 0,
            pub fn next(self: *EdgeIterator) ?EdgeView {
                if (self.index >= self.owner.edges.len) return null;
                const index = self.index;
                self.index += 1;
                return .{ .owner = self.owner, .index = index, .edge = self.owner.edges[index] };
            }
        };
        pub fn edgeIterator(self: *const Self) EdgeIterator {
            return .{ .owner = self };
        }
        /// Written-catalog order, then suffix-only tailport/headport keys,
        /// including implicit empties (the same order as compact iteration).
        /// No allocation, history scan, processing or deinit required.
        pub const AttributeIterator = struct {
            edge: EdgeView,
            index: u32 = 0,
            pub fn next(self: *AttributeIterator) ?Graph.AttributeView {
                return self.nextWork(Unmetered{}) catch unreachable;
            }
            pub fn nextWork(self: *AttributeIterator, work: anytype) r.Error!?Graph.AttributeView {
                try work.spend(1);
                const keys = self.edge.owner.folded.keys.items;
                if (self.index >= keys.len) return null;
                const value = try self.edge.resolve(keys[self.index], work);
                self.index += 1;
                return value;
            }
        };
        pub const BoundedAttributeIterator = struct {
            inner: AttributeIterator,
            work: r.Work,
            done: bool = false,
            failure: ?r.Error = null,
            pub fn next(self: *BoundedAttributeIterator) r.Error!?Graph.AttributeView {
                if (self.failure) |err| return err;
                if (self.done) return null;
                const value = self.inner.nextWork(&self.work) catch |err| {
                    self.failure = err;
                    return err;
                };
                if (value == null) self.done = true;
                return value;
            }
        };
    };
}

pub fn materialize(comptime Graph: type, graph: *const Graph, options: r.Options) r.Error!Graph.Materialized {
    return if (graph.has_ports) materializeImpl(Graph, true, graph, options) else materializeImpl(Graph, false, graph, options);
}

fn materializeImpl(comptime Graph: type, comptime with_ports: bool, graph: *const Graph, options: r.Options) r.Error!Graph.Materialized {
    var iterator = try @import("edges.zig").AttributeMaterializer(Graph, with_ports).init(graph, options);
    defer iterator.deinit();
    _ = try iterator.next();
    if (iterator.stored.items.len != 0) {
        for (graph.attribute_data.keys.items, 0..) |key, id| {
            try iterator.work.spend(1);
            if (key.kind == .edge) iterator.folded.keys.append(iterator.memory.allocator(), @intCast(id)) catch |err| return iterator.memory.failure(err);
        }
        if (with_ports) for (iterator.folded.port_introductions, 0..) |intro, i| {
            if (intro != null and iterator.folded.port_keys.ids[i] >= ports.right) {
                try iterator.work.spend(1);
                iterator.folded.keys.append(iterator.memory.allocator(), iterator.folded.port_keys.ids[i]) catch |err| return iterator.memory.failure(err);
            }
        };
    }
    const result: Graph.Materialized = .{
        .edges = iterator.stored.items,
        .storage = iterator.stored.allocatedSlice(),
        .folded = iterator.folded.transfer(),
        .graph = graph,
        .allocator = graph.allocator,
        .peak_bytes = iterator.peakBytes(),
    };
    iterator.stored = .empty;
    iterator.folded = .{ .limit = 0 };
    return result;
}
