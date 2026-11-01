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
const scratch = @import("query_storage.zig");
const materialization = @import("materialization_options.zig");

pub fn Graph(comptime rep: @import("representation.zig").Identity) type {
    const caps = rep.encodings;
    const Coverage = c.DataFor(rep.attributes);
    const Core = t.GraphWith(rep, true);
    return struct {
        const Self = @This();
        pub const capabilities = Core.capabilities;
        pub const indexes = Core.indexes;
        _data: Core,
        _coverage: Coverage,
        pub const AttributeView = Core.AttributeView;
        const Edges = @import("partial_edges.zig").For(Self, Core, caps);
        pub const EdgeView = Edges.Edge(false);
        pub const EdgeIterator = Edges.Iterator;
        pub const FixedEdgeIterator = Edges.FixedIterator;
        pub const Materialized = Edges.Materialized(true);
        pub const MaterializedTopology = Edges.Materialized(false);
        pub const Orientation = Edges.Orientation;
        pub const PortView = Core.PortView;

        /// Expands retained connections only, with the shared engine's limits.
        /// Exhaustion is not proof that missing input contains no other edges.
        pub fn edgeIterator(self: *const Self, options: r.Options) r.Error!EdgeIterator {
            return .{ .graph = self, .inner = try self._data.edgeIterator(options) };
        }
        pub fn edgeIteratorIn(self: *const Self, memory: scratch.EdgeScratch, options: r.Options) r.Error!FixedEdgeIterator {
            try scratch.checkGraph(try scratch.checkedBytes(memory), self);
            return .{ .graph = self, .inner = try self._data.edgeIteratorIn(memory, options) };
        }
        pub fn edgeView(self: *const Self, edge: t.Edge) r.Error!EdgeView {
            _ = try self._data.edgeView(edge);
            return .{ .graph = self, .edge = edge };
        }
        /// Successful construction retains all snapshot edges, never changes
        /// source coverage. Failure frees all output; values borrow this IR.
        pub fn MaterializedFor(comptime config: anytype) type {
            materialization.checkSelection(config);
            return @import("adjacency.zig").Result(Self, materialization.selection(rep.attributes, config));
        }
        pub inline fn materialize(self: *const Self, options: anytype) r.Error!MaterializedFor(.{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none }) {
            const selected: materialization.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none };
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").direct(Self, selected, self, materialization.options(selected, options));
            const data = try self._data.materialize(options);
            return .{ .graph = self, ._data = data, .edges = data.edges, .peak_bytes = data.peak_bytes };
        }
        pub fn MaterializationSession(comptime config: anytype) type {
            materialization.checkSelection(config);
            const selected = materialization.selection(rep.attributes, config);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").Session(Self, selected, false);
            return MaterializationSessionWith(selected.attributes, false);
        }
        pub fn FixedMaterializationSession(comptime config: anytype) type {
            materialization.checkSelection(config);
            const selected = materialization.selection(rep.attributes, config);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").Session(Self, selected, true);
            return MaterializationSessionWith(selected.attributes, true);
        }
        pub fn FixedMaterializationResult(comptime config: anytype) type {
            materialization.checkSelection(config);
            const selected = materialization.selection(rep.attributes, config);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").FixedResult(Self, selected);
            return @import("fixed_materialization.zig").Result(Self, selected.attributes);
        }
        pub inline fn materializeIn(self: *const Self, memory: anytype, options: anytype) FixedMaterializationResult(@import("materialization_storage.zig").selected(@TypeOf(memory))) {
            const selected = comptime @import("materialization_storage.zig").selected(@TypeOf(memory));
            const execution = materialization.options(selected, options);
            if (selected.adjacency != .none) return @import("adjacency_materialization.zig").directIn(Self, selected, self, memory, execution);
            return @import("fixed_materialization.zig").direct(Self, selected.attributes, self, memory, execution);
        }
        pub inline fn materializationSessionIn(self: *const Self, memory: anytype, options: anytype) r.Error!FixedMaterializationSession(@import("materialization_storage.zig").selected(@TypeOf(memory))) {
            const selected = comptime @import("materialization_storage.zig").selected(@TypeOf(memory));
            const execution = materialization.options(selected, options);
            if (selected.adjacency != .none) return FixedMaterializationSession(selected).initIn(self, memory, execution);
            return .{ .graph = self, .inner = try Core.FixedMaterializationSession(.{ .attributes = selected.attributes }).initInOwner(&self._data, memory, execution, self) };
        }
        fn MaterializationSessionWith(comptime attributes: bool, comptime fixed: bool) type {
            if (attributes) comptime @import("representation.zig").requireAttributes(rep.attributes);
            return struct {
                const Session = @This();
                pub const Result = if (attributes) Materialized else MaterializedTopology;
                graph: *const Self,
                inner: if (fixed) Core.FixedMaterializationSession(.{ .attributes = attributes }) else Core.MaterializationSession(.{ .attributes = attributes }),
                pub fn advance(session: *Session, budget: u32) @import("materialization_session.zig").Progress {
                    return session.inner.advance(budget);
                }
                pub fn run(session: *Session) @import("materialization_session.zig").Progress {
                    return session.inner.run();
                }
                pub fn cancel(session: *Session) void {
                    session.inner.cancel();
                }
                pub fn deinit(session: *Session) void {
                    session.inner.deinit();
                    session.* = undefined;
                }
                pub fn peakBytes(session: *const Session) usize {
                    return session.inner.peakBytes();
                }
                pub fn shortfall(session: *const Session) ?@import("fixed_storage.zig").StorageShortfall {
                    if (!fixed) @compileError("shortfall requires fixed materialization");
                    return session.inner.shortfall();
                }
                pub fn scratchPeak(session: *const Session) @import("materialization_storage.zig").ScratchCapacities {
                    if (!fixed) @compileError("scratchPeak requires fixed materialization");
                    return session.inner.scratchPeak();
                }
                pub fn takeResult(session: *Session) @import("materialization_session.zig").TakeError!Result {
                    const data = try session.inner.takeResult();
                    return .{ .graph = session.graph, ._data = data, .edges = data.edges, .peak_bytes = data.peak_bytes };
                }
            };
        }
        pub inline fn materializationSession(self: *const Self, options: anytype) r.Error!MaterializationSession(.{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none }) {
            const selected: materialization.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(options), "attributes")) options.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(options), "adjacency")) options.adjacency else .none };
            if (selected.adjacency != .none) return MaterializationSession(selected).init(self, materialization.options(selected, options));
            return .{ .graph = self, .inner = try self._data.materializationSession(options) };
        }

        pub fn deinit(self: *Self) void {
            if (self._data.borrowedBytes() == 0) self._coverage.deinit(self._data.allocator);
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
            if (self._data.borrowedBytes() != 0) return self._data.borrowedBytes();
            return self._data.retainedBytes() + self._coverage.retainedBytes();
        }
        pub fn capacities(self: *const Self) @import("fixed_storage.zig").GraphCapacities {
            var result = self._data.capacities();
            result.coverage_gaps = @intCast(self._coverage.entries.items.len);
            return result;
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
            entries: []const c.EntryFor(rep.attributes),
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
        /// Node/scope catalog iteration over retained input. Reuses the core
        /// iterator and charges qualification to its lifetime work allowance.
        pub const AttributeIterator = AttributeIteratorFor(false);
        pub const FixedAttributeIterator = AttributeIteratorFor(true);
        fn AttributeIteratorFor(comptime fixed: bool) type {
            return struct {
                const IteratorSelf = @This();
                graph: *const Self,
                inner: if (fixed) Core.FixedAttributeIterator else Core.AttributeIterator,
                failure: ?r.Error = null,

                pub fn deinit(self: *IteratorSelf) void {
                    self.inner.deinit();
                    self.* = undefined;
                }
                pub fn peakBytes(self: *const IteratorSelf) usize {
                    return self.inner.peakBytes();
                }
                /// One qualified value per retained key, including implicit empties.
                /// Exhaustion is not proof that missing input introduces no keys.
                /// Errors are terminal and repeat, including qualification stops.
                pub inline fn next(self: *IteratorSelf) r.Error!?c.Knowledge(AttributeView) {
                    if (self.failure) |err| return err;
                    const value = (try self.inner.next()) orelse return null;
                    const answer = (if (fixed and self.inner.target == .edge) Edges.qualify(self.graph, self.inner.target.edge, value, &self.inner.work) else self.graph.qualifyAttributeWith(value, &self.inner.work)) catch |err| {
                        self.failure = err;
                        return err;
                    };
                    return switch (answer) {
                        .known => |known| .{ .known = known.? },
                        .unknown => |unknown| .{ .unknown = .{ .uncertainty = unknown.uncertainty, .retained = unknown.retained } },
                    };
                }
                pub fn shortfall(self: *const IteratorSelf) ?@import("fixed_storage.zig").StorageShortfall {
                    if (!fixed) @compileError("shortfall requires fixed scratch");
                    return self.inner.shortfall();
                }
                pub fn scratchPeak(self: *const IteratorSelf) scratch.AttributeScratchCapacities {
                    if (!fixed) @compileError("scratchPeak requires fixed scratch");
                    return self.inner.scratchPeak();
                }
            };
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
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                return self.graph.qualifyAttribute(self.core().attribute(key));
            }
            pub fn attributeWith(self: NodeView, key: []const u8, options: r.Options) r.Error!c.Knowledge(?AttributeView) {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                const data = &self.graph._data;
                if (@backingInt(self.id) >= data.nodes.len) return error.InvalidHandle;
                var work = try r.Work.init(options.limits orelse data.limits, options.cancellation);
                const resolved = try attrs.lookupNode(caps, data, self.id, key, &work);
                return self.graph.qualifyAttributeWith(if (resolved) |value| .{ .graph = data, .resolved = value } else null, &work);
            }
            pub fn attributes(self: NodeView, options: r.Options) r.Error!AttributeIterator {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                return .{ .graph = self.graph, .inner = try self.core().attributes(options) };
            }
            pub fn attributesIn(self: NodeView, memory: scratch.AttributeScratch, options: r.Options) r.Error!FixedAttributeIterator {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                try scratch.checkGraph(try scratch.checkedBytes(memory), self.graph);
                return .{ .graph = self.graph, .inner = try self.core().attributesIn(memory, options) };
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
                return .{ .raw = data.text(range), .actual = names.reader(caps, data.source_info.encoding) };
            }
            pub fn attribute(self: ScopeView, key: []const u8) c.Knowledge(?AttributeView) {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                return self.graph.qualifyAttribute(self.core().attribute(key));
            }
            pub fn attributeWith(self: ScopeView, key: []const u8, options: r.Options) r.Error!c.Knowledge(?AttributeView) {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                const data = &self.graph._data;
                if (@backingInt(self.id) >= data.scopes.len) return error.InvalidHandle;
                var work = try r.Work.init(options.limits orelse data.limits, options.cancellation);
                const resolved = try attrs.lookupScope(caps, data, self.id, key, &work);
                return self.graph.qualifyAttributeWith(if (resolved) |value| .{ .graph = data, .resolved = value } else null, &work);
            }
            pub fn attributes(self: ScopeView, options: r.Options) r.Error!AttributeIterator {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                return .{ .graph = self.graph, .inner = try self.core().attributes(options) };
            }
            pub fn attributesIn(self: ScopeView, memory: scratch.AttributeScratch, options: r.Options) r.Error!FixedAttributeIterator {
                comptime @import("representation.zig").requireAttributes(rep.attributes);
                try scratch.checkGraph(try scratch.checkedBytes(memory), self.graph);
                return .{ .graph = self.graph, .inner = try self.core().attributesIn(memory, options) };
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
