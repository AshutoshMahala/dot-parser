const std = @import("std");
const syntax = @import("../dot/syntax.zig");
const policy = @import("../dot/policy.zig");
const support = @import("parser_support");
const encoding = support.encoding;
const names = @import("names.zig");
const r = @import("resources.zig");
const attrs = @import("attributes.zig");
const ports = @import("ports.zig");
const query_indexes = @import("query_indexes.zig");
const materialization = @import("materialization_options.zig");
pub const Range = support.location.Range;
pub const NodeId = enum(u32) { _ };
pub const ScopeId = enum(u32) { root, _ };
pub const OccurrenceId = enum(u32) { root, _ };
pub const ConnectionId = enum(u32) { _ };
/// An IR-local handle, not a mutable set. Singletons carry their node inline;
/// sets refer to an immutable prefix of one semantic scope's body intervals.
pub const Membership = enum(u32) { _ };
pub const node_bit: u32 = 1 << 31;
pub const Body = struct { start: u32, end: u32, first: u32 };
pub const Node = NodeFor(true);
pub fn NodeFor(comptime attributes: bool) type {
    return struct { name: Range, first_mention: u32, attribute_state: if (attributes) u32 else void = if (attributes) attrs.none else {}, hash: u64 };
}
pub const Scope = struct { parent: ?ScopeId, name: ?Range, first_occurrence: OccurrenceId, hash: u64 };
pub const Occurrence = struct { scope: ScopeId, parent: ?OccurrenceId, source: Range, membership: Membership };
pub const Mention = struct { node: NodeId, occurrence: OccurrenceId, source: Range };
/// Written port syntax is stored once per qualified edge endpoint, shared by
/// adjacent links in a chain. The sentinel costs no optional-tag storage.
pub const PortId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Endpoint = struct {
    members: Membership,
    port: PortId = .none,

    /// Borrows syntax from the owning graph; this endpoint must belong to it.
    pub fn portSyntax(self: Endpoint, graph: anytype) ?syntax.PortSyntax {
        return if (self.port == .none) null else graph.endpoint_ports[@backingInt(self.port)];
    }
};
pub const Connection = ConnectionFor(true);
pub fn ConnectionFor(comptime with_attributes: bool) type {
    return struct {
        left: Endpoint,
        right: Endpoint,
        written_operator: syntax.EdgeOperator,
        effective_operator: syntax.EdgeOperator,
        operator_source: Range,
        occurrence: OccurrenceId,
        attributes: if (with_attributes) syntax.AttributeRange else void,
    };
}
/// Retained raw declarations. Array order is semantic
/// execution order (children precede the containing edge's contribution).
pub const Declaration = struct {
    target: union(enum) { node: NodeId, defaults: syntax.AttributeTarget, graph_assignment },
    occurrence: OccurrenceId,
    attributes: syntax.AttributeRange,
};
pub const Edge = struct { from: NodeId, to: NodeId, operator: syntax.EdgeOperator, first_connection: ConnectionId };
pub const MaterializedTopology = struct {
    edges: []const Edge,
    peak_bytes: usize,
    _ownership: @import("materialization_storage.zig").Ownership,
    pub fn deinit(self: *MaterializedTopology) void {
        if (self._ownership == .allocated) self._ownership.allocated.allocator.free(self._ownership.edgeStorage(self.edges));
        self.* = undefined;
    }
    pub fn capacities(self: *const MaterializedTopology) @import("materialization_storage.zig").Capacities {
        return .{ .edges = @intCast(self.edges.len) };
    }
    pub fn retainedBytes(self: *const MaterializedTopology) usize {
        return if (self._ownership == .borrowed) self._ownership.borrowed.len else self._ownership.allocated.capacity * @sizeOf(Edge);
    }
};

pub fn Graph(comptime rep: @import("representation.zig").Identity) type {
    return GraphWith(rep, false);
}

/// Partial storage never guesses a concrete kind for unresolved .auto input.
pub fn GraphWith(comptime rep: @import("representation.zig").Identity, comptime partial: bool) type {
    const caps = rep.encodings;
    const NodeRecord = NodeFor(rep.attributes);
    const ConnectionRecord = ConnectionFor(rep.attributes);
    return struct {
        const Self = @This();
        pub const capabilities: @import("representation.zig").Capabilities = .{ .attributes = rep.attributes };
        pub const indexes = rep.indexes;
        source: []const u8,
        source_info: encoding.Info,
        declared_kind: syntax.GraphKind,
        kind: if (partial) ?policy.GraphKind else policy.GraphKind,
        strict: bool,
        name: ?Range,
        nodes: []const NodeRecord,
        scopes: []const Scope,
        occurrences: []const Occurrence,
        mentions: []const Mention,
        connections: []const ConnectionRecord,
        attributes: if (rep.attributes) []const syntax.Attribute else void,
        declarations: if (rep.attributes) []const Declaration else void,
        attribute_data: if (rep.attributes) attrs.Store else void,
        /// Peak live requested bytes during lowering, including scratch/growth.
        peak_bytes: usize,
        limits: r.Limits,
        allocator: std.mem.Allocator,
        node_storage: []NodeRecord,
        scope_storage: []Scope,
        declaration_storage: if (rep.attributes) []Declaration else void,
        bodies: []const Body,
        node_slots: []const u32,
        posting_offsets: []const u32,
        posting_positions: []const u32,
        /// True when retained edge endpoints have written port suffixes.
        /// Keep new cold flags after the pools: Zig's automatic layout otherwise
        /// moves the connection/membership fields used by topology-only loops.
        has_ports: bool,
        /// Nonzero only for borrowed fixed storage; includes unused pools and
        /// padding. Query allocator, if any, does not own this reservation.
        _storage: if (rep.indexes.any()) struct {
            borrowed_bytes: usize = 0,
            indexes: query_indexes.Data(rep.indexes) = .{},
        } else usize = if (rep.indexes.any()) .{} else 0,
        endpoint_ports: []const syntax.PortSyntax,

        // Reuse a cold field instead of adding even a void field: field count
        // changes can reorder Zig's automatic layout in the default profile.
        pub inline fn borrowedBytes(self: *const Self) usize {
            return if (comptime rep.indexes.any()) self._storage.borrowed_bytes else self._storage;
        }
        pub inline fn queryIndexes(self: *const Self) *const query_indexes.Data(rep.indexes) {
            return &self._storage.indexes;
        }

        const Views = @import("views.zig").For(Self, caps, connectionCovers);
        pub const NodeView = Views.Node;
        pub const ScopeView = Views.Scope;
        pub const EdgeView = Views.Edge;
        pub const AttributeView = Views.Attribute;
        pub const AttributeIterator = Views.Iterator;
        pub const FixedAttributeIterator = Views.FixedIterator;
        const Values = @import("values.zig").For(Self, caps);
        pub const ValueView = Values.Value;
        pub const OperandView = Values.Operand;
        const Ports = @import("port_views.zig").For(Self);
        pub const PortView = Ports.Port;
        pub const PortSyntaxView = Ports.Syntax;
        pub const GraphvizPortParts = Ports.GraphvizParts;
        pub const PortText = Ports.Text;
        pub const CompassStatus = Ports.CompassStatus;

        pub fn portKeys(self: *const Self, work: anytype) r.Error!ports.Keys {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            return ports.Keys.init(caps, self, work);
        }

        /// Borrowed context for component-oriented access. No allocation or
        /// owner pointer in retained records. Keep this IR alive and unmoved.
        pub fn nodeView(self: *const Self, id: NodeId) r.Error!NodeView {
            if (@backingInt(id) >= self.nodes.len) return error.InvalidHandle;
            return .{ .graph = self, .id = id };
        }
        pub fn scopeView(self: *const Self, id: ScopeId) r.Error!ScopeView {
            if (@backingInt(id) >= self.scopes.len) return error.InvalidHandle;
            return .{ .graph = self, .id = id };
        }
        /// Use an edge from this IR's iterator/materialization. Bounds checked
        /// here; membership and strict first-contribution checks occur on access.
        pub fn edgeView(self: *const Self, edge: Edge) r.Error!EdgeView {
            if (@backingInt(edge.from) >= self.nodes.len or @backingInt(edge.to) >= self.nodes.len or
                @backingInt(edge.first_connection) >= self.connections.len) return error.InvalidHandle;
            return .{ .graph = self, .edge = edge };
        }

        pub fn deinit(self: *Self) void {
            if (self.borrowedBytes() != 0) {
                self.* = undefined;
                return;
            }
            const a = self.allocator;
            a.free(self.node_storage);
            a.free(self.scope_storage);
            a.free(self.occurrences);
            a.free(self.mentions);
            @import("topology_storage.zig").release(a, self);
            if (rep.attributes) {
                a.free(self.attributes);
                a.free(self.declaration_storage);
            }
            a.free(self.bodies);
            a.free(self.node_slots);
            a.free(self.posting_offsets);
            a.free(self.posting_positions);
            if (comptime rep.indexes.any()) query_indexes.release(a, self.queryIndexes());
            if (rep.attributes) self.attribute_data.deinit(a);
            self.* = undefined;
        }

        /// Retained allocation payload (including spare capacity), not source,
        /// allocator metadata, arena slack, or temporary operation scratch.
        pub fn retainedBytes(self: *const Self) usize {
            if (self.borrowedBytes() != 0) return self.borrowedBytes();
            var bytes: usize = 0;
            inline for (.{ "node_storage", "scope_storage", "declaration_storage", "occurrences", "mentions", "connections", "endpoint_ports", "attributes", "bodies", "node_slots", "posting_offsets", "posting_positions" }) |field| {
                if (@FieldType(Self, field) == void) continue;
                const slice = @field(self, field);
                bytes += slice.len * @sizeOf(std.meta.Elem(@TypeOf(slice)));
            }
            return bytes + (if (rep.attributes) self.attribute_data.retainedBytes() else 0) + (if (comptime rep.indexes.any()) query_indexes.bytes(self.queryIndexes()) else 0);
        }

        /// Used records, not reserved capacity or a bound for changed input.
        pub fn capacities(self: *const Self) @import("fixed_storage.zig").GraphCapacities {
            return .{
                .nodes = @intCast(self.nodes.len),
                .scopes = @intCast(self.scopes.len),
                .occurrences = @intCast(self.occurrences.len),
                .mentions = @intCast(self.mentions.len),
                .connections = @intCast(self.connections.len),
                .endpoint_ports = @intCast(self.endpoint_ports.len),
                .declarations = if (rep.attributes) @intCast(self.declarations.len) else 0,
                .attributes = if (rep.attributes) @intCast(self.attributes.len) else 0,
                .attribute_keys = if (rep.attributes) @intCast(self.attribute_data.keys.items.len) else 0,
                .attribute_states = if (rep.attributes) @intCast(self.attribute_data.cells.items.len) else 0,
                .left_offsets = if (rep.indexes.connections) @intCast(self.queryIndexes().left_offsets.len) else 0,
                .right_offsets = if (rep.indexes.connections) @intCast(self.queryIndexes().right_offsets.len) else 0,
                .left_entries = if (rep.indexes.connections) @intCast(self.queryIndexes().left_entries.len) else 0,
                .right_entries = if (rep.indexes.connections) @intCast(self.queryIndexes().right_entries.len) else 0,
                .scope_memberships = if (rep.indexes.scope_memberships) @intCast(self.queryIndexes().scope_memberships.len) else 0,
            };
        }

        /// Logical UTF-8 bytes, not a DOT spelling. No case folding, entity
        /// expansion, number normalization, or Unicode normalization.
        pub fn findNode(self: *const Self, value: []const u8) r.Error!?NodeId {
            return self.findNodeWith(value, .{});
        }
        pub fn findNodeWith(self: *const Self, value: []const u8, options: r.Options) r.Error!?NodeId {
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            try work.spend(value.len);
            const hash = std.hash.Wyhash.hash(0, value);
            if (self.node_slots.len == 0) return null;
            var at: usize = @intCast(hash & (self.node_slots.len - 1));
            while (true) : (at = (at + 1) & (self.node_slots.len - 1)) {
                try work.spend(1);
                const id = self.node_slots[at];
                if (id == names.empty) return null;
                const node = self.nodes[id];
                if (node.hash != hash) continue;
                const raw = self.text(node.name);
                const reader = names.reader(caps, self.source_info.encoding);
                const equal = switch (reader) {
                    inline else => |actual| if (comptime caps.allows(actual)) try names.matches(actual, raw, value, &work) else return error.UnsupportedEncoding,
                };
                if (equal) return @fromBackingInt(id);
            }
        }

        pub const NodeIterator = struct {
            graph: *const Self,
            index: u32 = 0,

            pub fn next(self: *NodeIterator) ?NodeView {
                if (self.index >= self.graph.nodes.len) return null;
                const id: NodeId = @fromBackingInt(self.index);
                self.index += 1;
                return .{ .graph = self.graph, .id = id };
            }
        };

        /// Borrowed views in first-introduction order; no allocation or scan.
        pub fn nodeIterator(self: *const Self) NodeIterator {
            return .{ .graph = self };
        }

        /// A borrowed logical name for `{f}`. O(1) access; decoding happens on
        /// formatting, without allocation or repeated syntax validation.
        /// Formatting has ordinary writer semantics, not IR work accounting;
        /// use writeNodeNameWith for explicitly limited/cancellable writes.
        pub fn nodeName(self: *const Self, id: NodeId) r.Error!names.Formatted(caps) {
            return .{
                .raw = try self.nodeSpelling(id),
                .actual = names.reader(caps, self.source_info.encoding),
            };
        }

        /// Borrow the first source spelling, including quotes/concatenation,
        /// in the original source encoding. This is not the logical name.
        pub fn nodeSpelling(self: *const Self, id: NodeId) r.Error![]const u8 {
            const index = @backingInt(id);
            if (index >= self.nodes.len) return error.InvalidHandle;
            return self.text(self.nodes[index].name);
        }

        /// Stream the logical name, with the same byte semantics as findNode.
        /// No allocation or repeat syntax validation. Writer failures propagate;
        /// output can be partial if writing or cancellation stops the operation.
        pub fn writeNodeName(self: *const Self, id: NodeId, writer: anytype) !void {
            return self.writeNodeNameWith(id, writer, .{});
        }
        pub fn writeNodeNameWith(self: *const Self, id: NodeId, writer: anytype, options: r.Options) !void {
            const raw = try self.nodeSpelling(id);
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            const reader = names.reader(caps, self.source_info.encoding);
            switch (reader) {
                inline else => |actual| if (comptime caps.allows(actual)) try names.write(actual, raw, writer, &work) else return error.UnsupportedEncoding,
            }
        }

        pub fn text(self: *const Self, range: Range) []const u8 {
            return self.source[range.start..][0..range.len];
        }
        pub fn attributeSlice(self: *const Self, range: syntax.AttributeRange) ?[]const syntax.Attribute {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            if (range.start > self.attributes.len or range.len > self.attributes.len - range.start) return null;
            return self.attributes[range.start..][0..range.len];
        }

        /// Final node value. Null means the key was never introduced for nodes;
        /// `.empty` is DOT's language-defined empty, not absence. Names are
        /// logical UTF-8, case-sensitive, just like findNode. No allocation.
        pub fn nodeAttribute(self: *const Self, id: NodeId, key: []const u8) r.Error!?attrs.Resolved {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            return self.nodeAttributeWith(id, key, .{});
        }
        pub fn nodeAttributeWith(self: *const Self, id: NodeId, key: []const u8, options: r.Options) r.Error!?attrs.Resolved {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            if (@backingInt(id) >= self.nodes.len) return error.InvalidHandle;
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            return attrs.lookupNode(caps, self, id, key, &work);
        }

        /// Graph/subgraph attributes, including definition-time inheritance.
        pub fn scopeAttribute(self: *const Self, id: ScopeId, key: []const u8) r.Error!?attrs.Resolved {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            return self.scopeAttributeWith(id, key, .{});
        }
        pub fn scopeAttributeWith(self: *const Self, id: ScopeId, key: []const u8, options: r.Options) r.Error!?attrs.Resolved {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            if (@backingInt(id) >= self.scopes.len) return error.InvalidHandle;
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            return attrs.lookupScope(caps, self, id, key, &work);
        }

        fn connectionCovers(self: *const Self, connection: ConnectionRecord, edge: Edge, work: *r.Work) r.Error!bool {
            if (connection.effective_operator != edge.operator) return false;
            if (try self.containsWork(connection.left.members, edge.from, work) and try self.containsWork(connection.right.members, edge.to, work)) return true;
            return edge.operator == .undirected and try self.containsWork(connection.left.members, edge.to, work) and try self.containsWork(connection.right.members, edge.from, work);
        }

        /// Final value for a streamed/materialized edge. Strict contributions
        /// merge in semantic order; non-strict edges use their own connection.
        /// This bounded query scans symbolic connections, never expands pairs.
        /// For bulk export, do not mistake per-edge queries for a folded index.
        pub fn edgeAttribute(self: *const Self, edge: Edge, key: []const u8) r.Error!?attrs.Resolved {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            return self.edgeAttributeWith(edge, key, .{});
        }
        pub const edgeAttributeWith = EdgeAttributeQuery(false).run;
        /// Internal composition hook: value lookup and coverage share one budget.
        pub const edgeAttributeWork = EdgeAttributeQuery(true).run;
        // Select budget ownership without an extra large error-union return
        // adapter. Both entry points compile the same query body directly.
        fn EdgeAttributeQuery(comptime shared_work: bool) type {
            return struct {
                pub fn run(self: *const Self, edge: Edge, key: []const u8, options: if (shared_work) *r.Work else r.Options) r.Error!?attrs.Resolved {
                    comptime @import("representation.zig").requireAttributes(rep.attributes);
                    const id = @backingInt(edge.first_connection);
                    if (id >= self.connections.len or @backingInt(edge.from) >= self.nodes.len or @backingInt(edge.to) >= self.nodes.len) return error.InvalidHandle;
                    var owned_work: if (shared_work) void else r.Work = if (shared_work) {} else try r.Work.init(options.limits orelse self.limits, options.cancellation);
                    const work = if (shared_work) options else &owned_work;
                    if (!try self.connectionCovers(self.connections[id], edge, work)) return error.InvalidHandle;
                    const port_key: ?ports.Key = if (!self.has_ports) null else if (std.mem.eql(u8, key, "tailport")) .tailport else if (std.mem.eql(u8, key, "headport")) .headport else null;
                    const key_id = try attrs.findKey(caps, self, .edge, key, work);
                    if (key_id == null and port_key == null) {
                        // No written/default or synthetic value can exist.
                        // A strict caller-supplied edge must still identify its
                        // first contribution, even for an absent key. Later
                        // connections cannot affect that admission check.
                        if (self.strict) {
                            var scan: if (rep.indexes.connections) query_indexes.Scan else void = if (rep.indexes.connections) .init(self, 0, id, edge.from, edge.to, true) else {};
                            for (self.connections[0..id]) |direct_connection| {
                                const connection = if (rep.indexes.connections) self.connections[scan.next() orelse break] else direct_connection;
                                try work.spend(1);
                                if (try self.connectionCovers(connection, edge, work)) return error.InvalidHandle;
                            }
                        }
                        return null;
                    }
                    var first: ?u32 = null;
                    var explicit: ?u32 = null;
                    var explicit_connection: ConnectionId = edge.first_connection;
                    const start: usize = if (self.strict) 0 else id;
                    const end: usize = if (self.strict) self.connections.len else @as(usize, id) + 1;
                    var scan: if (rep.indexes.connections) query_indexes.Scan else void = if (rep.indexes.connections) .init(self, start, end, edge.from, edge.to, self.strict) else {};
                    for (self.connections[start..end], start..) |direct_connection, direct_index| {
                        const index = if (rep.indexes.connections) scan.next() orelse break else direct_index;
                        const connection = if (rep.indexes.connections) self.connections[index] else direct_connection;
                        try work.spend(1);
                        if (self.strict and !try self.connectionCovers(connection, edge, work)) continue;
                        if (port_key) |wanted| if (ports.suffixes(connection, @fromBackingInt(@as(u32, @intCast(index))), edge)[@backingInt(wanted)]) |suffix| {
                            explicit = suffix.attribute;
                            explicit_connection = suffix.connection;
                        };
                        if (first == null) first = @intCast(index);
                        if (key_id) |wanted| {
                            var at = connection.attributes.start + connection.attributes.len;
                            while (at != connection.attributes.start) {
                                at -= 1;
                                try work.spend(1);
                                if (self.attribute_data.meta[at].key == wanted) {
                                    explicit = at;
                                    explicit_connection = @fromBackingInt(@as(u32, @intCast(index)));
                                    break;
                                }
                            }
                        }
                    }
                    if (first != id) return error.InvalidHandle;
                    if (explicit) |attribute| {
                        if (attribute >= ports.right) return ports.resolve(self, .{ .attribute = attribute, .connection = explicit_connection }, port_key.?, false);
                        return attrs.resolvedConnection(self, attribute, explicit_connection);
                    }
                    const wanted = key_id orelse {
                        if (port_key) |key_kind| if (try ports.introduction(self, key_kind, work)) |intro| return ports.resolve(self, intro, key_kind, true);
                        return null;
                    };
                    const root = self.attribute_data.connection_defaults[id];
                    const value = try self.attribute_data.lookup(root, wanted, work);
                    const scope = self.occurrences[@backingInt(self.connections[id].occurrence)].scope;
                    return attrs.resolved(self, value orelse self.attribute_data.keys.items[wanted].first_attribute, .edge, scope, value == null);
                }
            };
        }

        /// Borrowed value view/formatter; no renderer escapes, HTML entity
        /// expansion or decoded allocation. Construct only from this IR's result.
        pub fn attributeValue(self: *const Self, resolved: attrs.Resolved) ValueView {
            comptime @import("representation.zig").requireAttributes(rep.attributes);
            return .{ .graph = self, .selected = resolved.value };
        }
        pub fn scopeMembership(self: *const Self, id: ScopeId) r.Error!Membership {
            const raw = @backingInt(id);
            if (raw >= self.scopes.len) return error.InvalidHandle;
            if (rep.indexes.scope_memberships) {
                var work = try r.Work.init(self.limits, null);
                try work.spend(1);
                return self.queryIndexes().scope_memberships[raw];
            }
            // Occurrences are in opening order, so the last is the full version.
            // Direct callers normally use an occurrence/connection snapshot.
            var work = try r.Work.init(self.limits, null);
            var index = self.occurrences.len;
            while (index != 0) {
                index -= 1;
                try work.spend(1);
                if (self.occurrences[index].scope == id) return self.occurrences[index].membership;
            }
            return error.InvalidHandle;
        }
        pub fn contains(self: *const Self, members: Membership, node: NodeId) r.Error!bool {
            var work = try r.Work.init(self.limits, null);
            return self.containsWork(members, node, &work);
        }
        pub inline fn containsWork(self: *const Self, members: Membership, node: NodeId, work: *r.Work) r.Error!bool {
            const id = @backingInt(node);
            if (id >= self.nodes.len) return error.InvalidHandle;
            const handle = @backingInt(members);
            if (handle & node_bit != 0) {
                if (handle & ~node_bit >= self.nodes.len) return error.InvalidHandle;
                try work.spend(1);
                return handle & ~node_bit == id;
            }
            return self.containsSetWork(handle, id, work);
        }
        // Singleton checks stay local to their caller. Keep the interval/posting
        // search out of that hot path without changing its checks or charges.
        noinline fn containsSetWork(self: *const Self, handle: u32, id: u32, work: *r.Work) r.Error!bool {
            if (handle >= self.bodies.len) return error.InvalidHandle;
            const first = self.bodies[handle].first;
            const positions = self.posting_positions[self.posting_offsets[id]..self.posting_offsets[id + 1]];
            for (self.bodies[first .. handle + 1]) |body| {
                try work.spend(1);
                var lo: usize = 0;
                var hi = positions.len;
                while (lo < hi) {
                    try work.spend(1);
                    const mid = lo + (hi - lo) / 2;
                    if (positions[mid] < body.start) lo = mid + 1 else hi = mid;
                }
                if (lo < positions.len and positions[lo] < body.end) return true;
            }
            return false;
        }
        pub fn hasEdge(self: *const Self, from: NodeId, to: NodeId) r.Error!bool {
            return self.hasEdgeWith(from, to, .{});
        }
        pub fn hasEdgeWith(self: *const Self, from: NodeId, to: NodeId, options: r.Options) r.Error!bool {
            if (@backingInt(from) >= self.nodes.len or @backingInt(to) >= self.nodes.len) return error.InvalidHandle;
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            if (rep.indexes.connections) {
                try work.spend(1);
                if (query_indexes.select(self, from, to)) |selected| {
                    var cursor = selected;
                    while (true) {
                        try work.spend(1);
                        const id = cursor.next() orelse return false;
                        const connection = self.connections[id];
                        if (try self.containsWork(connection.left.members, from, &work) and try self.containsWork(connection.right.members, to, &work)) return true;
                        if (connection.effective_operator == .undirected and try self.containsWork(connection.left.members, to, &work) and try self.containsWork(connection.right.members, from, &work)) return true;
                    }
                }
            }
            for (self.connections) |connection| {
                try work.spend(1);
                if (try self.containsWork(connection.left.members, from, &work) and try self.containsWork(connection.right.members, to, &work)) return true;
                if (connection.effective_operator == .undirected and try self.containsWork(connection.left.members, to, &work) and try self.containsWork(connection.right.members, from, &work)) return true;
            }
            return false;
        }

        pub const EdgeIterator = @import("edges.zig").Iterator(Self, false);
        pub const FixedEdgeIterator = @import("edges.zig").FixedIterator(Self);

        /// Pull individual edges without retaining the output array. Scratch
        /// is allocated lazily and must be released with iterator.deinit().
        pub fn edgeIterator(self: *const Self, options: r.Options) r.Error!EdgeIterator {
            return EdgeIterator.init(self, options);
        }
        pub fn edgeIteratorIn(self: *const Self, memory: @import("query_storage.zig").EdgeScratch, options: r.Options) r.Error!FixedEdgeIterator {
            return FixedEdgeIterator.initIn(self, memory, options);
        }

        pub const Materialized = @import("materialized_attributes.zig").For(Self, caps);
        pub fn MaterializedFor(comptime config: anytype) type {
            materialization.checkSelection(config);
            return @import("adjacency.zig").Result(Self, materialization.selection(rep.attributes, config));
        }
        pub fn FixedMaterializationResult(comptime config: anytype) type {
            materialization.checkSelection(config);
            const selected = materialization.selection(rep.attributes, config);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").FixedResult(Self, selected);
            return @import("fixed_materialization.zig").Result(Self, selected.attributes);
        }
        pub fn FixedMaterializationSession(comptime config: anytype) type {
            materialization.checkSelection(config);
            const selected = materialization.selection(rep.attributes, config);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").Session(Self, selected, true);
            return @import("materialization_session.zig").FixedSession(Self, caps, selected.attributes);
        }
        pub inline fn materializeIn(self: *const Self, memory: anytype, options: anytype) FixedMaterializationResult(@import("materialization_storage.zig").selected(@TypeOf(memory))) {
            const selected = comptime @import("materialization_storage.zig").selected(@TypeOf(memory));
            const execution = materialization.options(selected, options);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").directIn(Self, selected, self, memory, execution);
            return @import("fixed_materialization.zig").direct(Self, selected.attributes, self, memory, execution);
        }
        pub inline fn materializationSessionIn(self: *const Self, memory: anytype, options: anytype) r.Error!FixedMaterializationSession(@import("materialization_storage.zig").selected(@TypeOf(memory))) {
            const selected = comptime @import("materialization_storage.zig").selected(@TypeOf(memory));
            return FixedMaterializationSession(selected).initIn(self, memory, materialization.options(selected, options));
        }
        pub fn MaterializationSession(comptime config: anytype) type {
            materialization.checkSelection(config);
            const selected = materialization.selection(rep.attributes, config);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").Session(Self, selected, false);
            return @import("materialization_session.zig").Session(Self, caps, selected.attributes);
        }
        /// Opt-in resumable equivalent of materialize. The same compile-time
        /// attribute selection and runtime options; no hidden preparation pass.
        pub inline fn materializationSession(self: *const Self, options: anytype) r.Error!MaterializationSession(.{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none }) {
            const selected: materialization.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none };
            return MaterializationSession(selected).init(self, materialization.options(selected, options));
        }

        /// Owning expansion with effective attributes by default. Set the
        /// compile-time option .attributes = false for topology-only output.
        /// Limits/cancellation remain runtime values and cover the whole operation.
        /// Attribute results borrow this IR; topology-only records own their array.
        /// All-or-error. No attribute/endpoint-port folding code or state is
        /// instantiated by the topology-only specialization.
        pub inline fn materialize(self: *const Self, options: anytype) r.Error!MaterializedFor(.{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none }) {
            const selected: materialization.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none };
            const execution = materialization.options(selected, options);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").direct(Self, selected, self, execution);
            return self.materializeImpl(selected.attributes, execution);
        }

        // Keep execution behind one typed boundary regardless of the literal's
        // shape. The inline public adapter only selects/coerces configuration.
        fn materializeImpl(self: *const Self, comptime attributes: bool, options: r.Options) r.Error!(if (attributes) Materialized else MaterializedTopology) {
            if (attributes) comptime @import("representation.zig").requireAttributes(rep.attributes);
            return if (attributes)
                @import("materialized_attributes.zig").materialize(Self, self, options)
            else
                @import("edges.zig").materialize(Self, self, options);
        }
    };
}
