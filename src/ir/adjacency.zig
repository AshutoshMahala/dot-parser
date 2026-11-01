//! Materialized adjacency views. Stored edges and attribute resolution are shared
//! with ordinary materialization; only selected results carry an adjacency owner.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const options = @import("materialization_options.zig");
const rows = @import("adjacency_rows.zig");
const q = @import("query_storage.zig");
const coverage = @import("coverage.zig");

pub const Directions = struct { incoming: bool, outgoing: bool, undirected: bool };

pub fn Result(comptime Graph: type, comptime selected: options.Selection) type {
    const partial = @hasField(Graph, "_coverage");
    const Base = if (selected.attributes) Graph.Materialized else if (partial) Graph.MaterializedTopology else t.MaterializedTopology;
    if (selected.adjacency == .none) return Base;
    const BaseEdge = if (selected.attributes) Graph.Materialized.EdgeView else Graph.EdgeView;
    const BaseNode = Graph.NodeView;
    const NodeAttribute = @typeInfo(@TypeOf(BaseNode.attribute)).@"fn".return_type.?;
    const Attribute = @typeInfo(@TypeOf(BaseEdge.attribute)).@"fn".return_type.?;
    const Port = @typeInfo(@TypeOf(BaseEdge.tailPort)).@"fn".return_type.?;
    return struct {
        const Self = @This();
        pub const selection = selected;
        graph: *const Graph,
        base: Base,
        edges: []const t.Edge,
        peak_bytes: usize,
        index: rows.Rows,
        /// Non-null for caller-owned storage; includes reserved unused bytes.
        borrowed: ?[]u8 = null,

        pub fn deinit(self: *Self) void {
            if (self.borrowed == null) self.index.deinit(q.data(self.graph).allocator);
            self.base.deinit();
            self.* = undefined;
        }
        pub fn retainedBytes(self: *const Self) usize {
            return if (self.borrowed) |bytes| bytes.len else self.base.retainedBytes() + self.index.bytes();
        }
        pub fn capacities(self: *const Self) @import("materialization_storage.zig").Capacities {
            var counts = self.base.capacities();
            counts.adjacency_offsets = @intCast(self.index.offsets.len);
            counts.adjacency_entries = @intCast(self.index.entries.len);
            return counts;
        }
        pub fn state(self: *const Self) @import("parser_support").Completeness {
            if (!partial) @compileError("state requires a partial-aware materialized result");
            return self.graph.state();
        }
        pub fn kind(self: *const Self) coverage.Knowledge(@import("../dot/policy.zig").GraphKind) {
            if (!partial) @compileError("kind requires a partial-aware materialized result");
            return self.graph.kind();
        }
        fn checkScratch(self: *const Self, memory: q.AttributeScratch) r.Error!void {
            const bytes = try q.checkedBytes(memory);
            try q.disjoint(bytes, @as([*]const Self, @ptrCast(self))[0..1]);
            if (self.borrowed) |reserved| try q.disjoint(bytes, reserved);
            try q.disjoint(bytes, self.index.offsets);
            try q.disjoint(bytes, self.index.entries);
            if (selected.attributes) {
                try q.checkMaterialized(bytes, if (partial) &self.base._data else &self.base);
            } else {
                const owner = if (partial) &self.base._data else &self.base;
                try q.disjoint(bytes, owner._ownership.edgeStorage(owner.edges));
            }
        }
        pub const NodeView = struct {
            owner: *const Self,
            id: t.NodeId,
            /// Internal session adapter; shares the existing attribute engine.
            pub fn attributeSessionView(self: NodeView) BaseNode {
                return .{ .graph = self.owner.graph, .id = self.id };
            }
            pub fn checkAttributeScratch(self: NodeView, memory: q.AttributeScratch) r.Error!void {
                return self.owner.checkScratch(memory);
            }
            pub fn name(self: NodeView) @typeInfo(@TypeOf(BaseNode.name)).@"fn".return_type.? {
                return self.attributeSessionView().name();
            }
            pub fn attribute(self: NodeView, key: []const u8) NodeAttribute {
                return self.attributeSessionView().attribute(key);
            }
            pub fn attributeWith(self: NodeView, key: []const u8, opts: r.Options) r.Error!NodeAttribute {
                return self.attributeSessionView().attributeWith(key, opts);
            }
            pub fn attributes(self: NodeView, opts: r.Options) r.Error!Graph.AttributeIterator {
                return self.attributeSessionView().attributes(opts);
            }
            pub fn attributesIn(self: NodeView, memory: q.AttributeScratch, opts: r.Options) r.Error!Graph.FixedAttributeIterator {
                try self.checkAttributeScratch(memory);
                return self.attributeSessionView().attributesIn(memory, opts);
            }
            pub fn mentions(self: NodeView) Graph.MentionIterator {
                if (!partial) @compileError("mention iteration requires a partial-aware node view");
                return self.attributeSessionView().mentions();
            }
            pub fn edges(self: NodeView, comptime opts: options.EdgeOptions) IncidentIterator(opts) {
                return IncidentIterator(opts).init(self);
            }
            pub fn edgeCount(self: NodeView, comptime opts: options.EdgeOptions) if (partial) coverage.Knowledge(u32) else u32 {
                const mask = comptime options.mask(selected.adjacency, opts);
                var total: u32 = 0;
                inline for (0..4) |category| if (mask & (@as(u4, 1) << category) != 0) {
                    const range = self.owner.index.range(category, @backingInt(self.id));
                    total += range.end - range.start;
                };
                if (!partial) return total;
                if (self.owner.graph._coverage.uncertainty(null)) |uncertainty|
                    return .{ .unknown = .{ .uncertainty = uncertainty, .retained = total } };
                return .{ .known = total };
            }
        };
        pub const NodeIterator = struct {
            owner: *const Self,
            position: u32 = 0,
            pub fn next(self: *NodeIterator) ?NodeView {
                if (self.position == q.data(self.owner.graph).nodes.len) return null;
                const id: t.NodeId = @fromBackingInt(self.position);
                self.position += 1;
                return .{ .owner = self.owner, .id = id };
            }
        };
        pub fn nodeIterator(self: *const Self) NodeIterator {
            return .{ .owner = self };
        }
        pub fn nodeView(self: *const Self, id: t.NodeId) r.Error!NodeView {
            if (@backingInt(id) >= q.data(self.graph).nodes.len) return error.InvalidHandle;
            return .{ .owner = self, .id = id };
        }
        pub const EdgeView = struct {
            owner: *const Self,
            index: u32,
            edge: t.Edge,
            pub fn from(self: EdgeView) NodeView {
                return .{ .owner = self.owner, .id = self.edge.from };
            }
            pub fn to(self: EdgeView) NodeView {
                return .{ .owner = self.owner, .id = self.edge.to };
            }
            /// Internal session adapter; preserves folded versus compact costs.
            pub fn attributeSessionView(self: EdgeView) BaseEdge {
                if (partial) return .{ .graph = self.owner.graph, .edge = self.edge, .stored = if (selected.attributes) .{ .owner = &self.owner.base._data, .index = self.index } else {} };
                if (selected.attributes) return .{ .owner = &self.owner.base, .index = self.index, .edge = self.edge };
                return .{ .graph = self.owner.graph, .edge = self.edge };
            }
            pub fn checkAttributeScratch(self: EdgeView, memory: q.AttributeScratch) r.Error!void {
                return self.owner.checkScratch(memory);
            }
            pub fn attribute(self: EdgeView, key: []const u8) Attribute {
                return self.attributeSessionView().attribute(key);
            }
            pub fn attributeWith(self: EdgeView, key: []const u8, opts: r.Options) @typeInfo(@TypeOf(BaseEdge.attributeWith)).@"fn".return_type.? {
                return self.attributeSessionView().attributeWith(key, opts);
            }
            pub fn tailPort(self: EdgeView) Port {
                return self.attributeSessionView().tailPort();
            }
            pub fn headPort(self: EdgeView) Port {
                return self.attributeSessionView().headPort();
            }
            pub fn tailPortWith(self: EdgeView, opts: r.Options) @typeInfo(@TypeOf(BaseEdge.tailPortWith)).@"fn".return_type.? {
                return self.attributeSessionView().tailPortWith(opts);
            }
            pub fn headPortWith(self: EdgeView, opts: r.Options) @typeInfo(@TypeOf(BaseEdge.headPortWith)).@"fn".return_type.? {
                return self.attributeSessionView().headPortWith(opts);
            }
            pub const attributes = if (selected.attributes) foldedAttributes else compactAttributes;
            fn foldedAttributes(self: EdgeView) @typeInfo(@TypeOf(BaseEdge.attributes)).@"fn".return_type.? {
                return self.attributeSessionView().attributes();
            }
            fn compactAttributes(self: EdgeView, opts: r.Options) @typeInfo(@TypeOf(BaseEdge.attributes)).@"fn".return_type.? {
                return self.attributeSessionView().attributes(opts);
            }
            pub fn attributesIn(self: EdgeView, memory: q.AttributeScratch, opts: r.Options) r.Error!Graph.FixedAttributeIterator {
                if (selected.attributes) @compileError("materialized attributes need no scratch; use attributes or attributesWith");
                try self.checkAttributeScratch(memory);
                return self.attributeSessionView().attributesIn(memory, opts);
            }
            pub fn attributesWith(self: EdgeView, opts: r.Options) @typeInfo(@TypeOf(if (@hasDecl(BaseEdge, "attributesWith")) BaseEdge.attributesWith else BaseEdge.attributes)).@"fn".return_type.? {
                if (@hasDecl(BaseEdge, "attributesWith")) return self.attributeSessionView().attributesWith(opts);
                return self.attributeSessionView().attributes(opts);
            }
            pub fn orientation(self: EdgeView) coverage.Knowledge(Graph.Orientation) {
                if (!partial) @compileError("orientation qualification requires a partial-aware edge");
                return self.attributeSessionView().orientation();
            }
            pub fn firstConnection(self: EdgeView) coverage.Knowledge(t.ConnectionId) {
                if (!partial) @compileError("firstConnection qualification requires a partial-aware edge");
                return self.attributeSessionView().firstConnection();
            }
        };
        pub const EdgeIterator = struct {
            owner: *const Self,
            position: u32 = 0,
            pub fn next(self: *EdgeIterator) ?EdgeView {
                if (self.position == self.owner.edges.len) return null;
                const index = self.position;
                self.position += 1;
                return .{ .owner = self.owner, .index = index, .edge = self.owner.edges[index] };
            }
        };
        pub fn edgeIterator(self: *const Self) EdgeIterator {
            return .{ .owner = self };
        }
        pub const Entry = struct {
            owner: *const Self,
            node: t.NodeId,
            index: u32,
            pub fn neighbor(self: Entry) NodeView {
                const value = self.owner.edges[self.index];
                return .{ .owner = self.owner, .id = if (value.from == self.node) value.to else value.from };
            }
            pub fn edge(self: Entry) EdgeView {
                return .{ .owner = self.owner, .index = self.index, .edge = self.owner.edges[self.index] };
            }
            pub fn directions(self: Entry) Directions {
                const value = self.owner.edges[self.index];
                return .{ .incoming = value.operator == .directed and value.to == self.node, .outgoing = value.operator == .directed and value.from == self.node, .undirected = value.operator == .undirected };
            }
        };
        pub fn IncidentIterator(comptime opts: options.EdgeOptions) type {
            const mask = options.mask(selected.adjacency, opts);
            return struct {
                node: NodeView,
                positions: [4]u32 = @splat(0),
                ends: [4]u32 = @splat(0),
                fn init(node: NodeView) @This() {
                    var result: @This() = .{ .node = node };
                    inline for (0..4) |category| if (mask & (@as(u4, 1) << category) != 0) {
                        const range = node.owner.index.range(category, @backingInt(node.id));
                        result.positions[category] = range.start;
                        result.ends[category] = range.end;
                    };
                    return result;
                }
                pub fn next(self: *@This()) ?Entry {
                    var found: u32 = std.math.maxInt(u32);
                    var selected_category: u2 = 0;
                    inline for (0..4) |category| if (mask & (@as(u4, 1) << category) != 0) {
                        if (self.positions[category] != self.ends[category]) {
                            const index = self.node.owner.index.entries[self.positions[category]];
                            if (index < found) {
                                found = index;
                                selected_category = category;
                            }
                        }
                    };
                    if (found == std.math.maxInt(u32)) return null;
                    self.positions[selected_category] += 1;
                    return .{ .owner = self.node.owner, .node = self.node.id, .index = found };
                }
            };
        }
    };
}
