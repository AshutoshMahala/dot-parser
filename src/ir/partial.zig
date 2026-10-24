//! Retained facts and qualified queries. No complete-graph escape or implicit
//! edge expansion. Borrowed views require this owner to stay alive and unmoved.
const std = @import("std");
const encoding = @import("parser_support").encoding;
const Completeness = @import("parser_support").Completeness;
const policy = @import("../dot/policy.zig");
const t = @import("topology.zig");
const r = @import("resources.zig");
const c = @import("coverage.zig");
const names = @import("names.zig");
const attrs = @import("attributes.zig");
const Unmetered = @import("../dot/identifier_cursor.zig").Unmetered;

pub fn Graph(comptime caps: encoding.Capabilities) type {
    const Core = t.GraphWith(caps, true);
    return struct {
        const Self = @This();
        _data: Core,
        _coverage: c.Data,
        pub const AttributeView = Core.AttributeView;
        const Edges = @import("partial_edges.zig").For(Self, Core, caps);
        pub const EdgeView = Edges.Edge(false);
        pub const EdgeIterator = Edges.Iterator;
        pub const Materialized = Edges.Materialized(true);
        pub const MaterializedTopology = Edges.Materialized(false);
        pub const Orientation = Edges.Orientation;
        pub const PortView = Core.PortView;

        /// Expands retained connections only, with the shared engine's limits.
        /// Exhaustion is not proof that missing input contains no other edges.
        pub fn edgeIterator(self: *const Self, options: r.Options) r.Error!EdgeIterator {
            return .{ .graph = self, .inner = try self._data.edgeIterator(options) };
        }
        pub fn edgeView(self: *const Self, edge: t.Edge) r.Error!EdgeView {
            _ = try self._data.edgeView(edge);
            return .{ .graph = self, .edge = edge };
        }
        /// Successful construction retains all snapshot edges, never changes
        /// source coverage. Failure frees all output; values borrow this IR.
        pub inline fn materialize(self: *const Self, options: anytype) r.Error!(if (if (@hasField(@TypeOf(options), "attributes")) options.attributes else true) Materialized else MaterializedTopology) {
            const data = try self._data.materialize(options);
            return .{ .graph = self, ._data = data, .edges = data.edges, .peak_bytes = data.peak_bytes };
        }

        pub fn deinit(self: *Self) void {
            self._coverage.deinit(self._data.allocator);
            self._data.deinit();
            self.* = undefined;
        }
        pub fn state(self: *const Self) Completeness {
            return if (self._coverage.entries.items.len == 0 and self._data.kind != null) .complete else .partial;
        }
        pub fn kind(self: *const Self) c.Knowledge(policy.GraphKind) {
            return if (self._data.kind) |value| .{ .known = value } else .{ .unknown = .{ .uncertainty = .{ .reason = .unresolved_kind, .span = null } } };
        }
        pub fn retainedBytes(self: *const Self) usize {
            return self._data.retainedBytes() + self._coverage.retainedBytes();
        }
        pub fn peakBytes(self: *const Self) usize {
            return self._data.peak_bytes;
        }
        pub fn nodeCount(self: *const Self) u32 {
            return @intCast(self._data.nodes.len);
        }
        pub fn scopeCount(self: *const Self) u32 {
            return @intCast(self._data.scopes.len);
        }
        pub fn connectionCount(self: *const Self) u32 {
            return @intCast(self._data.connections.len);
        }

        pub const GapIterator = struct {
            entries: []const c.Entry,
            index: u32 = 0,
            pub fn next(self: *GapIterator) ?c.Gap {
                if (self.index == self.entries.len) return null;
                const gap = self.entries[self.index].gap;
                self.index += 1;
                return gap;
            }
        };
        pub fn gaps(self: *const Self) GapIterator {
            return .{ .entries = self._coverage.entries.items };
        }

        fn qualifyAttribute(self: *const Self, value: ?AttributeView) c.Knowledge(?AttributeView) {
            return self.qualifyAttributeWith(value, Unmetered{}) catch unreachable;
        }
        fn qualifyAttributeWith(self: *const Self, value: ?AttributeView, work: anytype) r.Error!c.Knowledge(?AttributeView) {
            // Only an explicit retained assignment can overwrite all prior
            // missing updates. Defaults depend on possibly hidden first creation.
            const after: ?u32 = if (value) |v| if (v.resolved.kind == .explicit and v.resolved.origin == .declaration) v.resolved.origin.declaration else null else null;
            if (try self._coverage.uncertaintyWith(after, work)) |uncertainty|
                return .{ .unknown = .{ .uncertainty = uncertainty, .retained = value } };
            return .{ .known = value };
        }
        pub const NodeView = struct {
            graph: *const Self,
            id: t.NodeId,
            fn core(self: NodeView) Core.NodeView {
                return .{ .graph = &self.graph._data, .id = self.id };
            }
            pub fn name(self: NodeView) names.Formatted(caps) {
                return self.core().name();
            }
            pub fn attribute(self: NodeView, key: []const u8) c.Knowledge(?AttributeView) {
                return self.graph.qualifyAttribute(self.core().attribute(key));
            }
            pub fn attributeWith(self: NodeView, key: []const u8, options: r.Options) r.Error!c.Knowledge(?AttributeView) {
                const data = &self.graph._data;
                if (@backingInt(self.id) >= data.nodes.len) return error.InvalidHandle;
                var work = try r.Work.init(options.limits orelse data.limits, options.cancellation);
                const resolved = try attrs.lookupNode(caps, data, self.id, key, &work);
                return self.graph.qualifyAttributeWith(if (resolved) |value| .{ .graph = data, .resolved = value } else null, &work);
            }
            pub fn mentions(self: NodeView) MentionIterator {
                const data = &self.graph._data;
                const id = @backingInt(self.id);
                return .{ .graph = self.graph, .positions = data.posting_positions[data.posting_offsets[id]..data.posting_offsets[id + 1]] };
            }
        };
        pub const MentionIterator = struct {
            graph: *const Self,
            positions: []const u32,
            index: u32 = 0,
            pub fn next(self: *MentionIterator) ?t.Mention {
                if (self.index == self.positions.len) return null;
                const value = self.graph._data.mentions[self.positions[self.index]];
                self.index += 1;
                return value;
            }
        };
        pub const ScopeView = struct {
            graph: *const Self,
            id: t.ScopeId,
            fn core(self: ScopeView) Core.ScopeView {
                return .{ .graph = &self.graph._data, .id = self.id };
            }
            pub fn name(self: ScopeView) ?names.Formatted(caps) {
                const data = &self.graph._data;
                const range = data.scopes[@backingInt(self.id)].name orelse return null;
                return .{ .raw = data.text(range), .actual = if (data.source_info.encoding == .ascii and caps.utf8) .utf8 else data.source_info.encoding };
            }
            pub fn attribute(self: ScopeView, key: []const u8) c.Knowledge(?AttributeView) {
                return self.graph.qualifyAttribute(self.core().attribute(key));
            }
            pub fn attributeWith(self: ScopeView, key: []const u8, options: r.Options) r.Error!c.Knowledge(?AttributeView) {
                const data = &self.graph._data;
                if (@backingInt(self.id) >= data.scopes.len) return error.InvalidHandle;
                var work = try r.Work.init(options.limits orelse data.limits, options.cancellation);
                const resolved = try attrs.lookupScope(caps, data, self.id, key, &work);
                return self.graph.qualifyAttributeWith(if (resolved) |value| .{ .graph = data, .resolved = value } else null, &work);
            }
            /// Last retained membership version, not a promise of final contents.
            pub fn membership(self: ScopeView) r.Error!t.Membership {
                return self.graph._data.scopeMembership(self.id);
            }
        };
        pub const NodeIterator = struct {
            graph: *const Self,
            index: u32 = 0,
            pub fn next(self: *NodeIterator) ?NodeView {
                if (self.index == self.graph._data.nodes.len) return null;
                const id = self.index;
                self.index += 1;
                return .{ .graph = self.graph, .id = @fromBackingInt(id) };
            }
        };
        pub const ScopeIterator = struct {
            graph: *const Self,
            index: u32 = 0,
            pub fn next(self: *ScopeIterator) ?ScopeView {
                if (self.index == self.graph._data.scopes.len) return null;
                const id = self.index;
                self.index += 1;
                return .{ .graph = self.graph, .id = @fromBackingInt(id) };
            }
        };
        pub fn nodeIterator(self: *const Self) NodeIterator {
            return .{ .graph = self };
        }
        pub fn scopeIterator(self: *const Self) ScopeIterator {
            return .{ .graph = self };
        }
        pub fn nodeView(self: *const Self, id: t.NodeId) r.Error!NodeView {
            if (@backingInt(id) >= self._data.nodes.len) return error.InvalidHandle;
            return .{ .graph = self, .id = id };
        }
        pub fn scopeView(self: *const Self, id: t.ScopeId) r.Error!ScopeView {
            if (@backingInt(id) >= self._data.scopes.len) return error.InvalidHandle;
            return .{ .graph = self, .id = id };
        }
        pub fn findNode(self: *const Self, name: []const u8) r.Error!c.Knowledge(?t.NodeId) {
            return self.findNodeWith(name, .{});
        }
        pub fn findNodeWith(self: *const Self, name: []const u8, options: r.Options) r.Error!c.Knowledge(?t.NodeId) {
            const found = try self._data.findNodeWith(name, options);
            if (found == null) if (self._coverage.uncertainty(null)) |uncertainty| return .{ .unknown = .{ .uncertainty = uncertainty } };
            return .{ .known = found };
        }
        pub fn hasEdge(self: *const Self, from: t.NodeId, to: t.NodeId) r.Error!c.Knowledge(bool) {
            return self.hasEdgeWith(from, to, .{});
        }
        pub fn hasEdgeWith(self: *const Self, from: t.NodeId, to: t.NodeId, options: r.Options) r.Error!c.Knowledge(bool) {
            const found = try self._data.hasEdgeWith(from, to, options);
            if (!found) if (self._coverage.uncertainty(null)) |uncertainty| return .{ .unknown = .{ .uncertainty = uncertainty } };
            return .{ .known = found };
        }
        pub fn contains(self: *const Self, members: t.Membership, node: t.NodeId) r.Error!c.Knowledge(bool) {
            return self.containsWith(members, node, .{});
        }
        pub fn containsWith(self: *const Self, members: t.Membership, node: t.NodeId, options: r.Options) r.Error!c.Knowledge(bool) {
            var work = try r.Work.init(options.limits orelse self._data.limits, options.cancellation);
            const found = try self._data.containsWork(members, node, &work);
            if (!found) if (self._coverage.uncertainty(null)) |uncertainty| return .{ .unknown = .{ .uncertainty = uncertainty } };
            return .{ .known = found };
        }
    };
}
