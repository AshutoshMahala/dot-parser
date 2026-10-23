//! Borrowed component views. Stored IR records remain compact, owner-free IDs.
const std = @import("std");
const t = @import("topology.zig");
const attrs = @import("attributes.zig");
const names = @import("names.zig");
const r = @import("resources.zig");
const encoding = @import("parser_support").encoding;
const Unmetered = @import("../dot/identifier_cursor.zig").Unmetered;

pub fn For(comptime Graph: type, comptime caps: encoding.Capabilities, comptime covers: anytype) type {
    return struct {
        pub const Attribute = struct {
            graph: *const Graph,
            resolved: attrs.Resolved,

            /// Logical key/value formatters borrow the source; no decoded copy.
            pub fn key(self: Attribute) names.Formatted(caps) {
                return .{
                    .raw = self.graph.text(self.graph.attributes[self.resolved.attribute].key),
                    .actual = if (self.graph.source_info.encoding == .ascii and caps.utf8) .utf8 else self.graph.source_info.encoding,
                };
            }
            pub fn value(self: Attribute) Graph.ValueView {
                return self.graph.attributeValue(self.resolved);
            }
        };

        pub const Node = struct {
            graph: *const Graph,
            id: t.NodeId,

            pub fn name(self: Node) names.Formatted(caps) {
                return .{
                    .raw = self.graph.text(self.graph.nodes[@backingInt(self.id)].name),
                    .actual = if (self.graph.source_info.encoding == .ascii and caps.utf8) .utf8 else self.graph.source_info.encoding,
                };
            }
            pub fn attribute(self: Node, key: []const u8) ?Attribute {
                // Certified view/native names, no work budget: no fallible
                // prerequisite remains. Never convert a failed query to absence.
                const value = attrs.lookupNode(caps, self.graph, self.id, key, Unmetered{}) catch unreachable;
                return if (value) |found| .{ .graph = self.graph, .resolved = found } else null;
            }
            pub fn attributeWith(self: Node, key: []const u8, options: r.Options) r.Error!?Attribute {
                return if (try self.graph.nodeAttributeWith(self.id, key, options)) |value|
                    .{ .graph = self.graph, .resolved = value }
                else
                    null;
            }
            pub fn attributes(self: Node, options: r.Options) r.Error!Iterator {
                return Iterator.init(self.graph, .{ .node = self.id }, options);
            }
        };

        pub const Scope = struct {
            graph: *const Graph,
            id: t.ScopeId,

            pub fn attribute(self: Scope, key: []const u8) ?Attribute {
                const value = attrs.lookupScope(caps, self.graph, self.id, key, Unmetered{}) catch unreachable;
                return if (value) |found| .{ .graph = self.graph, .resolved = found } else null;
            }
            pub fn attributeWith(self: Scope, key: []const u8, options: r.Options) r.Error!?Attribute {
                return if (try self.graph.scopeAttributeWith(self.id, key, options)) |value|
                    .{ .graph = self.graph, .resolved = value }
                else
                    null;
            }
            pub fn attributes(self: Scope, options: r.Options) r.Error!Iterator {
                return Iterator.init(self.graph, .{ .graph = self.id }, options);
            }
        };

        pub const Edge = struct {
            graph: *const Graph,
            edge: t.Edge,

            pub fn from(self: Edge) Node {
                return .{ .graph = self.graph, .id = self.edge.from };
            }
            pub fn to(self: Edge) Node {
                return .{ .graph = self.graph, .id = self.edge.to };
            }
            pub fn attribute(self: Edge, key: []const u8) r.Error!?Attribute {
                return self.attributeWith(key, .{});
            }
            pub fn attributeWith(self: Edge, key: []const u8, options: r.Options) r.Error!?Attribute {
                return if (try self.graph.edgeAttributeWith(self.edge, key, options)) |value|
                    .{ .graph = self.graph, .resolved = value }
                else
                    null;
            }
            pub fn attributes(self: Edge, options: r.Options) r.Error!Iterator {
                return Iterator.init(self.graph, .{ .edge = self.edge }, options);
            }
        };

        const Target = union(attrs.Kind) { graph: t.ScopeId, node: t.NodeId, edge: t.Edge };
        const Winner = struct { key: u32, attribute: u32 = attrs.none, connection: t.ConnectionId = undefined };

        pub const Iterator = struct {
            graph: *const Graph,
            target: Target,
            work: r.Work,
            memory: r.Memory,
            winners: []Winner = &.{},
            winner_index: u32 = 0,
            index: u32 = 0,
            prepared: bool = false,
            done: bool = false,
            failure: ?r.Error = null,

            fn init(graph: *const Graph, target: Target, options: r.Options) r.Error!Iterator {
                switch (target) {
                    .node => |id| if (@backingInt(id) >= graph.nodes.len) return error.InvalidHandle,
                    .graph => |id| if (@backingInt(id) >= graph.scopes.len) return error.InvalidHandle,
                    .edge => |edge| if (@backingInt(edge.from) >= graph.nodes.len or @backingInt(edge.to) >= graph.nodes.len or
                        @backingInt(edge.first_connection) >= graph.connections.len) return error.InvalidHandle,
                }
                const limits = options.limits orelse graph.limits;
                return .{
                    .graph = graph,
                    .target = target,
                    .work = try r.Work.init(limits, options.cancellation),
                    .memory = .{ .backing = graph.allocator, .limit = limits.max_bytes },
                };
            }

            /// Always deinit, including on early exit/error. Only strict-edge
            /// explicit merging needs scratch; other targets allocate nothing.
            pub fn deinit(self: *Iterator) void {
                self.memory.allocator().free(self.winners);
                self.* = undefined;
            }
            pub fn peakBytes(self: *const Iterator) usize {
                return self.memory.peak;
            }

            /// One effective value per key, in first-introduction order for
            /// this object kind, including implicit empties. Errors are terminal
            /// and repeat. Work/cancellation cover the whole iterator lifetime.
            pub fn next(self: *Iterator) r.Error!?Attribute {
                if (self.failure) |err| return err;
                if (self.done) return null;
                return self.nextImpl() catch |err| {
                    const failure = self.memory.failure(err);
                    self.failure = failure;
                    return failure;
                };
            }

            fn initWinners(self: *Iterator) r.Error!void {
                var count: u32 = 0;
                for (self.graph.attribute_data.keys.items) |key| {
                    try self.work.spend(1);
                    if (key.kind == .edge) count += 1;
                }
                self.winners = try self.memory.allocator().alloc(Winner, count);
                var index: u32 = 0;
                for (self.graph.attribute_data.keys.items, 0..) |key, id| {
                    try self.work.spend(1);
                    if (key.kind != .edge) continue;
                    self.winners[index] = .{ .key = @intCast(id) };
                    index += 1;
                }
            }

            fn setWinner(self: *Iterator, key: u32, attribute: u32, connection: t.ConnectionId) r.Error!void {
                // Sorted intern IDs: bounded comparisons, no hash-flooding or
                // per-contribution storage. Repeated writes replace one slot.
                var lo: usize = 0;
                var hi = self.winners.len;
                while (lo < hi) {
                    try self.work.spend(1);
                    const mid = lo + (hi - lo) / 2;
                    const slot = &self.winners[mid];
                    if (slot.key == key) {
                        slot.attribute = attribute;
                        slot.connection = connection;
                        return;
                    }
                    if (slot.key < key) lo = mid + 1 else hi = mid;
                }
                unreachable; // All bound edge keys were included by initWinners.
            }

            fn prepareEdge(self: *Iterator, edge: t.Edge) r.Error!void {
                const graph = self.graph;
                const id = @backingInt(edge.first_connection);
                const start: usize = if (graph.strict) 0 else id;
                const end = if (graph.strict) graph.connections.len else @as(usize, id) + 1;
                var first: ?u32 = null;
                for (graph.connections[start..end], start..) |connection, index| {
                    try self.work.spend(1);
                    if (!try covers(graph, connection, edge, &self.work)) continue;
                    if (first == null) {
                        first = @intCast(index);
                        if (first != id) return error.InvalidHandle;
                    }
                    // All-attribute iteration must not silently omit synthetic
                    // headport/tailport, even if their keys aren't in the catalog.
                    if (connection.left.port != null or connection.right.port != null) return error.UnsupportedSemantics;
                    if (!graph.strict or connection.attributes.len == 0) continue;
                    if (self.winners.len == 0) try self.initWinners();
                    for (connection.attributes.start..connection.attributes.start + connection.attributes.len) |attribute| {
                        try self.work.spend(1);
                        try self.setWinner(graph.attribute_data.meta[attribute].key, @intCast(attribute), @fromBackingInt(@as(u32, @intCast(index))));
                    }
                }
                if (first == null) return error.InvalidHandle;
            }

            fn nextImpl(self: *Iterator) r.Error!?Attribute {
                try self.work.spend(0);
                if (!self.prepared) {
                    if (self.target == .edge) try self.prepareEdge(self.target.edge);
                    self.prepared = true;
                }
                const graph = self.graph;
                const store = &graph.attribute_data;
                while (self.index < store.keys.items.len) {
                    try self.work.spend(1);
                    const id = self.index;
                    self.index += 1;
                    const key = store.keys.items[id];
                    if (key.kind != std.meta.activeTag(self.target)) continue;
                    var scope: t.ScopeId = .root;
                    const root: u32 = switch (self.target) {
                        .node => |node_id| blk: {
                            const node = graph.nodes[@backingInt(node_id)];
                            scope = graph.occurrences[@backingInt(graph.mentions[node.first_mention].occurrence)].scope;
                            break :blk node.attribute_state;
                        },
                        .graph => |scope_id| blk: {
                            scope = scope_id;
                            break :blk store.scopes[@backingInt(scope_id)].graph;
                        },
                        .edge => |edge| blk: {
                            const connection_id = @backingInt(edge.first_connection);
                            var attribute: ?u32 = null;
                            var origin = edge.first_connection;
                            if (self.winners.len != 0) {
                                const winner = self.winners[self.winner_index];
                                self.winner_index += 1;
                                if (winner.attribute != attrs.none) {
                                    attribute = winner.attribute;
                                    origin = winner.connection;
                                }
                            } else if (!graph.strict) {
                                const range = graph.connections[connection_id].attributes;
                                var at = range.start + range.len;
                                while (at != range.start) {
                                    at -= 1;
                                    try self.work.spend(1);
                                    if (store.meta[at].key == id) {
                                        attribute = at;
                                        break;
                                    }
                                }
                            }
                            if (attribute) |written| return .{ .graph = graph, .resolved = attrs.resolvedConnection(graph, written, origin) };
                            scope = graph.occurrences[@backingInt(graph.connections[connection_id].occurrence)].scope;
                            break :blk store.connection_defaults[connection_id];
                        },
                    };
                    const written = try store.lookup(root, id, &self.work);
                    return .{ .graph = graph, .resolved = attrs.resolved(graph, written orelse key.first_attribute, key.kind, scope, written == null) };
                }
                self.done = true;
                return null;
            }
        };
    };
}
