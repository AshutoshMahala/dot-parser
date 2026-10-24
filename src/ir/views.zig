//! Borrowed component views. Stored IR records remain compact, owner-free IDs.
const std = @import("std");
const t = @import("topology.zig");
const attrs = @import("attributes.zig");
const names = @import("names.zig");
const r = @import("resources.zig");
const encoding = @import("parser_support").encoding;
const Unmetered = @import("../dot/identifier_cursor.zig").Unmetered;
const ports = @import("ports.zig");

pub fn For(comptime Graph: type, comptime caps: encoding.Capabilities, comptime covers: anytype) type {
    return struct {
        pub const Attribute = struct {
            graph: *const Graph,
            resolved: attrs.Resolved,

            /// Logical key/value formatters borrow the source; no decoded copy.
            pub const Key = union(enum) {
                written: names.Formatted(caps),
                port: ports.Key,
                pub fn format(self: Key, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    switch (self) {
                        .written => |written| try written.format(writer),
                        .port => |key_name| try writer.writeAll(@tagName(key_name)),
                    }
                }
            };
            pub fn key(self: Attribute) Key {
                if (self.resolved.port_key) |key_name| return .{ .port = key_name };
                return .{ .written = .{
                    .raw = self.graph.text(self.graph.attributes[self.resolved.attribute.?].key),
                    .actual = if (self.graph.source_info.encoding == .ascii and caps.utf8) .utf8 else self.graph.source_info.encoding,
                } };
            }
            pub fn value(self: Attribute) Graph.ValueView {
                return self.graph.attributeValue(self.resolved);
            }
            /// Same joined logical output as value(); no allocation or escaping.
            pub fn format(self: Attribute, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.value().format(writer);
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
            /// Effective ports belong to from()/to(), not the latest written sides.
            pub fn tailPort(self: Edge) r.Error!?Graph.PortView {
                return self.tailPortWith(.{});
            }
            pub fn headPort(self: Edge) r.Error!?Graph.PortView {
                return self.headPortWith(.{});
            }
            pub fn tailPortWith(self: Edge, options: r.Options) r.Error!?Graph.PortView {
                return if (try self.attributeWith("tailport", options)) |found|
                    .{ .graph = found.graph, .resolved = found.resolved }
                else
                    null;
            }
            pub fn headPortWith(self: Edge, options: r.Options) r.Error!?Graph.PortView {
                return if (try self.attributeWith("headport", options)) |found|
                    .{ .graph = found.graph, .resolved = found.resolved }
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
            // Initialized only by the port-bearing edge preparation path.
            // Node/scope and port-free iterators never touch this scratch.
            port_keys: ports.Keys = undefined,
            port_winners: [2]?ports.Selection = undefined,
            port_index: u2 = undefined,

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

            /// One effective value per key, in written-catalog order followed
            /// by suffix-only tailport/headport keys, including implicit empties. Errors are terminal
            /// and repeat. Work/cancellation cover the whole iterator lifetime.
            pub fn next(self: *Iterator) r.Error!?Attribute {
                if (self.failure) |err| return err;
                if (self.done) return null;
                return (if (self.graph.has_ports) self.nextImpl(true) else self.nextImpl(false)) catch |err| {
                    const failure = self.memory.failure(err);
                    self.failure = failure;
                    return failure;
                };
            }

            noinline fn preparePorts(self: *Iterator, edge: t.Edge) r.Error!void {
                // Keep the derived-key/history preparation out of port-free
                // iteration; leave per-value resolution inline for port users.
                return self.prepareEdge(true, edge);
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

            fn prepareEdge(self: *Iterator, comptime with_ports: bool, edge: t.Edge) r.Error!void {
                const graph = self.graph;
                if (with_ports) {
                    self.port_keys = try ports.Keys.init(caps, graph, &self.work);
                    self.port_winners = .{ null, null };
                    self.port_index = 0;
                }
                const id = @backingInt(edge.first_connection);
                const start: usize = if (graph.strict) 0 else id;
                const end = if (graph.strict) graph.connections.len else @as(usize, id) + 1;
                var first: ?u32 = null;
                for (graph.connections[start..end], start..) |connection, index| {
                    try self.work.spend(1);
                    // Project only membership/operator fields here. An outlined
                    // wrapper copies the whole connection (including ports) per
                    // candidate; the underlying bounded checks stay unchanged.
                    if (!try @call(.always_inline, covers, .{ graph, connection, edge, &self.work })) continue;
                    if (first == null) {
                        first = @intCast(index);
                        if (first != id) return error.InvalidHandle;
                    }
                    const connection_id: t.ConnectionId = @fromBackingInt(@as(u32, @intCast(index)));
                    if (with_ports) {
                        for (ports.suffixes(connection, connection_id, edge), 0..) |suffix, side| if (suffix) |value| {
                            self.port_winners[side] = value;
                        };
                        for (connection.attributes.start..connection.attributes.start + connection.attributes.len) |attribute| {
                            try self.work.spend(1);
                            if (self.port_keys.key(graph.attribute_data.meta[attribute].key)) |key| self.port_winners[@backingInt(key)] = .{ .attribute = @intCast(attribute), .connection = connection_id };
                        }
                    }
                    if (!graph.strict or connection.attributes.len == 0) continue;
                    if (self.winners.len == 0) try self.initWinners();
                    for (connection.attributes.start..connection.attributes.start + connection.attributes.len) |attribute| {
                        try self.work.spend(1);
                        try self.setWinner(graph.attribute_data.meta[attribute].key, @intCast(attribute), @fromBackingInt(@as(u32, @intCast(index))));
                    }
                }
                if (first == null) return error.InvalidHandle;
            }

            inline fn nextImpl(self: *Iterator, comptime with_ports: bool) r.Error!?Attribute {
                try self.work.spend(0);
                if (!self.prepared) {
                    if (self.target == .edge) {
                        if (with_ports) try self.preparePorts(self.target.edge) else try self.prepareEdge(false, self.target.edge);
                    }
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
                            if (with_ports) if (self.port_keys.key(id)) |port_key| if (self.port_winners[@backingInt(port_key)]) |selection| return .{ .graph = graph, .resolved = ports.resolve(graph, selection, port_key, false) };
                            if (attribute) |written| return .{ .graph = graph, .resolved = attrs.resolvedConnection(graph, written, origin) };
                            scope = graph.occurrences[@backingInt(graph.connections[connection_id].occurrence)].scope;
                            break :blk store.connection_defaults[connection_id];
                        },
                    };
                    const written = try store.lookup(root, id, &self.work);
                    // Project provenance here so callers can eliminate unused
                    // view fields, without forcing inlining for other queries.
                    return .{ .graph = graph, .resolved = @call(.always_inline, attrs.resolved, .{ graph, written orelse key.first_attribute, key.kind, scope, written == null }) };
                }
                if (self.target == .edge and with_ports) {
                    while (self.port_index < 2) {
                        const index = self.port_index;
                        self.port_index += 1;
                        if (self.port_keys.ids[index] < ports.right) continue;
                        const key: ports.Key = @fromBackingInt(@intCast(index));
                        if (self.port_winners[index]) |selection| return .{ .graph = graph, .resolved = ports.resolve(graph, selection, key, false) };
                        if (try ports.introduction(graph, key, &self.work)) |intro| return .{ .graph = graph, .resolved = ports.resolve(graph, intro, key, true) };
                    }
                }
                self.done = true;
                return null;
            }
        };
    };
}
