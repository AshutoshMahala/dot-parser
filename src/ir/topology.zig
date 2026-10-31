const std = @import("std");
const syntax = @import("../dot/syntax.zig");
const policy = @import("../dot/policy.zig");
const support = @import("parser_support");
const encoding = support.encoding;
const names = @import("names.zig");
const r = @import("resources.zig");
const attrs = @import("attributes.zig");
const ports = @import("ports.zig");
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
pub const Node = struct { name: Range, first_mention: u32, attribute_state: u32 = attrs.none, hash: u64 };
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
pub const Connection = struct {
    left: Endpoint,
    right: Endpoint,
    written_operator: syntax.EdgeOperator,
    effective_operator: syntax.EdgeOperator,
    operator_source: Range,
    occurrence: OccurrenceId,
    attributes: syntax.AttributeRange,
};
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
    allocator: std.mem.Allocator,
    storage: []Edge,
    pub fn deinit(self: *MaterializedTopology) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

// Normalize anonymous option literals without losing field checking/defaults.
// Typed runtime optionals and explicit null use the same execution contract.
fn optionalOption(comptime T: type, value: anytype) ?T {
    if (@TypeOf(value) == T) return value;
    switch (@typeInfo(@TypeOf(value))) {
        .null => return null,
        .optional => return if (value) |payload| optionalOption(T, payload) else null,
        else => {},
    }
    comptime {
        for (@typeInfo(@TypeOf(value)).@"struct".field_names) |field| {
            if (!@hasField(T, field)) @compileError("unknown IR materialization option field: " ++ field);
        }
    }
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, Field, attr| {
        @field(result, name) = if (@hasField(@TypeOf(value), name))
            @field(value, name)
        else if (attr.default_value_ptr) |ptr|
            @as(*const Field, @ptrCast(@alignCast(ptr))).*
        else
            @compileError("missing IR materialization option field: " ++ name);
    }
    return result;
}

pub fn Graph(comptime caps: encoding.Capabilities) type {
    return GraphWith(caps, false);
}

/// Partial storage never guesses a concrete kind for unresolved .auto input.
pub fn GraphWith(comptime caps: encoding.Capabilities, comptime partial: bool) type {
    return struct {
        const Self = @This();
        source: []const u8,
        source_info: encoding.Info,
        declared_kind: syntax.GraphKind,
        kind: if (partial) ?policy.GraphKind else policy.GraphKind,
        strict: bool,
        name: ?Range,
        nodes: []const Node,
        scopes: []const Scope,
        occurrences: []const Occurrence,
        mentions: []const Mention,
        connections: []const Connection,
        attributes: []const syntax.Attribute,
        declarations: []const Declaration,
        attribute_data: attrs.Store,
        /// Peak live requested bytes during lowering, including scratch/growth.
        peak_bytes: usize,
        limits: r.Limits,
        allocator: std.mem.Allocator,
        node_storage: []Node,
        scope_storage: []Scope,
        declaration_storage: []Declaration,
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
        borrowed_bytes: usize = 0,
        endpoint_ports: []const syntax.PortSyntax,

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
            if (self.borrowed_bytes != 0) {
                self.* = undefined;
                return;
            }
            const a = self.allocator;
            a.free(self.node_storage);
            a.free(self.scope_storage);
            a.free(self.occurrences);
            a.free(self.mentions);
            @import("topology_storage.zig").release(a, self);
            a.free(self.attributes);
            a.free(self.declaration_storage);
            a.free(self.bodies);
            a.free(self.node_slots);
            a.free(self.posting_offsets);
            a.free(self.posting_positions);
            self.attribute_data.deinit(a);
            self.* = undefined;
        }

        /// Retained allocation payload (including spare capacity), not source,
        /// allocator metadata, arena slack, or temporary operation scratch.
        pub fn retainedBytes(self: *const Self) usize {
            if (self.borrowed_bytes != 0) return self.borrowed_bytes;
            var bytes: usize = 0;
            inline for (.{ "node_storage", "scope_storage", "declaration_storage", "occurrences", "mentions", "connections", "endpoint_ports", "attributes", "bodies", "node_slots", "posting_offsets", "posting_positions" }) |field| {
                const slice = @field(self, field);
                bytes += slice.len * @sizeOf(std.meta.Elem(@TypeOf(slice)));
            }
            return bytes + self.attribute_data.retainedBytes();
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
                .declarations = @intCast(self.declarations.len),
                .attributes = @intCast(self.attributes.len),
                .attribute_keys = @intCast(self.attribute_data.keys.items.len),
                .attribute_states = @intCast(self.attribute_data.cells.items.len),
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
            if (range.start > self.attributes.len or range.len > self.attributes.len - range.start) return null;
            return self.attributes[range.start..][0..range.len];
        }

        /// Final node value. Null means the key was never introduced for nodes;
        /// `.empty` is DOT's language-defined empty, not absence. Names are
        /// logical UTF-8, case-sensitive, just like findNode. No allocation.
        pub fn nodeAttribute(self: *const Self, id: NodeId, key: []const u8) r.Error!?attrs.Resolved {
            return self.nodeAttributeWith(id, key, .{});
        }
        pub fn nodeAttributeWith(self: *const Self, id: NodeId, key: []const u8, options: r.Options) r.Error!?attrs.Resolved {
            if (@backingInt(id) >= self.nodes.len) return error.InvalidHandle;
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            return attrs.lookupNode(caps, self, id, key, &work);
        }

        /// Graph/subgraph attributes, including definition-time inheritance.
        pub fn scopeAttribute(self: *const Self, id: ScopeId, key: []const u8) r.Error!?attrs.Resolved {
            return self.scopeAttributeWith(id, key, .{});
        }
        pub fn scopeAttributeWith(self: *const Self, id: ScopeId, key: []const u8, options: r.Options) r.Error!?attrs.Resolved {
            if (@backingInt(id) >= self.scopes.len) return error.InvalidHandle;
            var work = try r.Work.init(options.limits orelse self.limits, options.cancellation);
            return attrs.lookupScope(caps, self, id, key, &work);
        }

        fn connectionCovers(self: *const Self, connection: Connection, edge: Edge, work: *r.Work) r.Error!bool {
            if (connection.effective_operator != edge.operator) return false;
            if (try self.containsWork(connection.left.members, edge.from, work) and try self.containsWork(connection.right.members, edge.to, work)) return true;
            return edge.operator == .undirected and try self.containsWork(connection.left.members, edge.to, work) and try self.containsWork(connection.right.members, edge.from, work);
        }

        /// Final value for a streamed/materialized edge. Strict contributions
        /// merge in semantic order; non-strict edges use their own connection.
        /// This bounded query scans symbolic connections, never expands pairs.
        /// For bulk export, do not mistake per-edge queries for a folded index.
        pub fn edgeAttribute(self: *const Self, edge: Edge, key: []const u8) r.Error!?attrs.Resolved {
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
                        if (self.strict) for (self.connections[0..id]) |connection| {
                            try work.spend(1);
                            if (try self.connectionCovers(connection, edge, work)) return error.InvalidHandle;
                        };
                        return null;
                    }
                    var first: ?u32 = null;
                    var explicit: ?u32 = null;
                    var explicit_connection: ConnectionId = edge.first_connection;
                    const start: usize = if (self.strict) 0 else id;
                    const end: usize = if (self.strict) self.connections.len else @as(usize, id) + 1;
                    for (self.connections[start..end], start..) |connection, index| {
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
            return .{ .graph = self, .selected = resolved.value };
        }
        pub fn scopeMembership(self: *const Self, id: ScopeId) r.Error!Membership {
            const raw = @backingInt(id);
            if (raw >= self.scopes.len) return error.InvalidHandle;
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
        pub fn MaterializationSession(comptime attributes: bool) type {
            return @import("materialization_session.zig").Session(Self, caps, attributes);
        }
        /// Opt-in resumable equivalent of materialize. The same compile-time
        /// attribute selection and runtime options; no hidden preparation pass.
        pub inline fn materializationSession(self: *const Self, options: anytype) r.Error!MaterializationSession(if (@hasField(@TypeOf(options), "attributes")) options.attributes else true) {
            comptime {
                for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
                    if (!std.mem.eql(u8, field, "attributes") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation"))
                        @compileError("unknown IR materialization option: " ++ field);
                }
            }
            return MaterializationSession(comptime if (@hasField(@TypeOf(options), "attributes")) options.attributes else true).init(self, .{
                .limits = if (@hasField(@TypeOf(options), "limits")) optionalOption(r.Limits, options.limits) else null,
                .cancellation = if (@hasField(@TypeOf(options), "cancellation")) optionalOption(r.Cancellation, options.cancellation) else null,
            });
        }

        /// Owning expansion with effective attributes by default. Set the
        /// compile-time option .attributes = false for topology-only output.
        /// Limits/cancellation remain runtime values and cover the whole operation.
        /// Attribute results borrow this IR; topology-only records own their array.
        /// All-or-error. No attribute/endpoint-port folding code or state is
        /// instantiated by the topology-only specialization.
        pub inline fn materialize(self: *const Self, options: anytype) r.Error!(if (if (@hasField(@TypeOf(options), "attributes")) options.attributes else true) Materialized else MaterializedTopology) {
            comptime {
                for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
                    if (!std.mem.eql(u8, field, "attributes") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation"))
                        @compileError("unknown IR materialization option: " ++ field);
                }
            }
            const execution: r.Options = .{
                .limits = if (@hasField(@TypeOf(options), "limits")) optionalOption(r.Limits, options.limits) else null,
                .cancellation = if (@hasField(@TypeOf(options), "cancellation")) optionalOption(r.Cancellation, options.cancellation) else null,
            };
            return self.materializeImpl(comptime if (@hasField(@TypeOf(options), "attributes")) options.attributes else true, execution);
        }

        // Keep execution behind one typed boundary regardless of the literal's
        // shape. The inline public adapter only selects/coerces configuration.
        fn materializeImpl(self: *const Self, comptime attributes: bool, options: r.Options) r.Error!(if (attributes) Materialized else MaterializedTopology) {
            return if (attributes)
                @import("materialized_attributes.zig").materialize(Self, self, options)
            else
                @import("edges.zig").materialize(Self, self, options);
        }
    };
}
