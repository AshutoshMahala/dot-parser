//! Partial-aware views over the existing expansion and attribute-folding engines.
//! No second traversal, pair map, winner map or value representation.
const t = @import("topology.zig");
const c = @import("coverage.zig");
const r = @import("resources.zig");
const attrs = @import("attributes.zig");
const encoding = @import("parser_support").encoding;
const Unmetered = @import("../dot/identifier_cursor.zig").Unmetered;

pub fn For(comptime Graph: type, comptime Core: type, comptime caps: encoding.Capabilities) type {
    return struct {
        pub const Orientation = struct { from: t.NodeId, to: t.NodeId };

        inline fn qualify(graph: *const Graph, edge: t.Edge, value: ?Core.AttributeView, work: anytype) r.Error!c.Knowledge(?Core.AttributeView) {
            // Keep the large borrowed answer at the call site; the outlined
            // decision returns only a small uncertainty, not another value copy.
            if (try uncertainty(graph, edge, value, work)) |u|
                return .{ .unknown = .{ .uncertainty = u, .retained = value } };
            return .{ .known = value };
        }
        fn uncertainty(graph: *const Graph, edge: t.Edge, value: ?Core.AttributeView, work: anytype) r.Error!?c.Uncertainty {
            const all = graph._coverage.uncertainty(null) orelse return null;
            if (value) |v| {
                if (v.resolved.kind == .explicit or v.resolved.kind == .derived) {
                    const connection = switch (v.resolved.origin) {
                        .connection, .written_left_port, .written_right_port => |id| id,
                        .declaration => return all,
                    };
                    // A later statement cannot update a non-strict occurrence.
                    if (!graph._data.strict) return null;
                    // A missing first contribution can reverse an undirected
                    // edge. Do not certify tail/head values in that orientation.
                    if (edge.operator == .undirected and edge.from != edge.to) {
                        const port = v.resolved.port_key != null or if (v.resolved.attribute) |attribute| blk: {
                            const key = graph._data.attribute_data.meta[attribute].key;
                            inline for (.{ "tailport", "headport" }) |name| {
                                if (try attrs.findKey(caps, &graph._data, .edge, name, work)) |id| if (id == key) break :blk true;
                            }
                            break :blk false;
                        } else false;
                        if (port) return all;
                    }
                    return graph._coverage.afterConnectionWith(@backingInt(connection), work);
                }
            }
            // Missing input can change creation defaults and introduce keys.
            return all;
        }

        fn portAnswer(answer: c.Knowledge(?Core.AttributeView)) c.Knowledge(?Core.PortView) {
            return switch (answer) {
                .known => |value| .{ .known = if (value) |v| .{ .graph = v.graph, .resolved = v.resolved } else null },
                .unknown => |u| .{ .unknown = .{ .uncertainty = u.uncertainty, .retained = if (u.retained) |v| .{ .graph = v.graph, .resolved = v.resolved } else null } },
            };
        }

        fn entry(answer: c.Knowledge(?Core.AttributeView)) c.Knowledge(Core.AttributeView) {
            return switch (answer) {
                .known => |value| .{ .known = value.? },
                .unknown => |u| .{ .unknown = .{ .uncertainty = u.uncertainty, .retained = u.retained } },
            };
        }

        pub fn Edge(comptime folded: bool) type {
            return struct {
                const Self = @This();
                graph: *const Graph,
                /// Retained snapshot orientation and first connection, not a
                /// claim about a missing earlier contribution. Use the queries
                /// below when certainty about first creation matters.
                edge: t.Edge,
                stored: if (folded) struct { owner: *const Core.Materialized, index: u32 } else void = if (folded) undefined else {},

                pub fn from(self: Self) Graph.NodeView {
                    return .{ .graph = self.graph, .id = self.edge.from };
                }
                pub fn to(self: Self) Graph.NodeView {
                    return .{ .graph = self.graph, .id = self.edge.to };
                }
                pub fn orientation(self: Self) c.Knowledge(Orientation) {
                    const value: Orientation = .{ .from = self.edge.from, .to = self.edge.to };
                    if (self.graph._data.strict and self.edge.operator == .undirected and self.edge.from != self.edge.to)
                        if (self.graph._coverage.uncertainty(null)) |u| return .{ .unknown = .{ .uncertainty = u, .retained = value } };
                    return .{ .known = value };
                }
                pub fn firstConnection(self: Self) c.Knowledge(t.ConnectionId) {
                    if (self.graph._data.strict) if (self.graph._coverage.uncertainty(null)) |u|
                        return .{ .unknown = .{ .uncertainty = u, .retained = self.edge.first_connection } };
                    return .{ .known = self.edge.first_connection };
                }
                fn core(self: Self) Core.Materialized.EdgeView {
                    return .{ .owner = self.stored.owner, .index = self.stored.index, .edge = self.edge };
                }
                pub fn attribute(self: Self, key: []const u8) if (folded) c.Knowledge(?Core.AttributeView) else r.Error!c.Knowledge(?Core.AttributeView) {
                    if (folded) return self.lookup(key, Unmetered{}) catch unreachable;
                    return self.attributeWith(key, .{});
                }
                pub fn attributeWith(self: Self, key: []const u8, options: r.Options) r.Error!c.Knowledge(?Core.AttributeView) {
                    var work = try r.Work.init(options.limits orelse self.graph._data.limits, options.cancellation);
                    return self.lookup(key, &work);
                }
                fn lookup(self: Self, key: []const u8, work: anytype) r.Error!c.Knowledge(?Core.AttributeView) {
                    const value: ?Core.AttributeView = if (folded) try self.core().lookup(key, work) else blk: {
                        const resolved = try self.graph._data.edgeAttributeWork(self.edge, key, work);
                        break :blk if (resolved) |v| .{ .graph = &self.graph._data, .resolved = v } else null;
                    };
                    return qualify(self.graph, self.edge, value, work);
                }
                pub fn tailPort(self: Self) if (folded) c.Knowledge(?Core.PortView) else r.Error!c.Knowledge(?Core.PortView) {
                    if (folded) return portAnswer(self.attribute("tailport"));
                    return self.tailPortWith(.{});
                }
                pub fn headPort(self: Self) if (folded) c.Knowledge(?Core.PortView) else r.Error!c.Knowledge(?Core.PortView) {
                    if (folded) return portAnswer(self.attribute("headport"));
                    return self.headPortWith(.{});
                }
                pub fn tailPortWith(self: Self, options: r.Options) r.Error!c.Knowledge(?Core.PortView) {
                    return portAnswer(try self.attributeWith("tailport", options));
                }
                pub fn headPortWith(self: Self, options: r.Options) r.Error!c.Knowledge(?Core.PortView) {
                    return portAnswer(try self.attributeWith("headport", options));
                }
                // The argument lists intentionally match the complete API:
                // compact iteration is bounded; folded iteration is infallible.
                pub const attributes = if (folded) foldedAttributes else compactAttributes;
                fn foldedAttributes(self: Self) FoldedAttributes {
                    return .{ .graph = self.graph, .edge = self.edge, .inner = self.core().attributes() };
                }
                fn compactAttributes(self: Self, options: r.Options) r.Error!CompactAttributes {
                    const view: Core.EdgeView = .{ .graph = &self.graph._data, .edge = self.edge };
                    return .{ .graph = self.graph, .edge = self.edge, .inner = try view.attributes(options) };
                }
                pub fn attributesWith(self: Self, options: r.Options) r.Error!(if (folded) BoundedFoldedAttributes else CompactAttributes) {
                    if (!folded) return self.compactAttributes(options);
                    return .{ .inner = self.foldedAttributes(), .work = try r.Work.init(options.limits orelse self.graph._data.limits, options.cancellation) };
                }
            };
        }

        pub const CompactAttributes = struct {
            graph: *const Graph,
            edge: t.Edge,
            inner: Core.AttributeIterator,
            failure: ?r.Error = null,
            pub fn deinit(self: *CompactAttributes) void {
                self.inner.deinit();
                self.* = undefined;
            }
            pub fn peakBytes(self: *const CompactAttributes) usize {
                return self.inner.peakBytes();
            }
            pub fn next(self: *CompactAttributes) r.Error!?c.Knowledge(Core.AttributeView) {
                if (self.failure) |err| return err;
                const value = (try self.inner.next()) orelse return null;
                return entry(qualify(self.graph, self.edge, value, &self.inner.work) catch |err| {
                    self.failure = err;
                    return err;
                });
            }
        };
        pub const FoldedAttributes = struct {
            graph: *const Graph,
            edge: t.Edge,
            inner: Core.Materialized.AttributeIterator,
            pub inline fn next(self: *FoldedAttributes) ?c.Knowledge(Core.AttributeView) {
                return self.nextWork(Unmetered{}) catch unreachable;
            }
            inline fn nextWork(self: *FoldedAttributes, work: anytype) r.Error!?c.Knowledge(Core.AttributeView) {
                const value = (try self.inner.nextWork(work)) orelse return null;
                return entry(try qualify(self.graph, self.edge, value, work));
            }
        };
        pub const BoundedFoldedAttributes = struct {
            inner: FoldedAttributes,
            work: r.Work,
            failure: ?r.Error = null,
            done: bool = false,
            pub fn next(self: *BoundedFoldedAttributes) r.Error!?c.Knowledge(Core.AttributeView) {
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

        pub const Iterator = struct {
            graph: *const Graph,
            inner: Core.EdgeIterator,
            pub fn deinit(self: *Iterator) void {
                self.inner.deinit();
                self.* = undefined;
            }
            pub fn peakBytes(self: *const Iterator) usize {
                return self.inner.peakBytes();
            }
            pub inline fn next(self: *Iterator) r.Error!?Edge(false) {
                const value = (try self.inner.next()) orelse return null;
                return .{ .graph = self.graph, .edge = value.edge };
            }
        };

        pub fn Materialized(comptime folded: bool) type {
            return struct {
                const Self = @This();
                pub const EdgeView = Edge(folded);
                graph: *const Graph,
                _data: if (folded) Core.Materialized else t.MaterializedTopology,
                edges: []const t.Edge,
                peak_bytes: usize,
                pub fn deinit(self: *Self) void {
                    self._data.deinit();
                    self.* = undefined;
                }
                pub fn state(self: *const Self) @import("parser_support").Completeness {
                    return self.graph.state();
                }
                pub fn kind(self: *const Self) c.Knowledge(@import("../dot/policy.zig").GraphKind) {
                    return self.graph.kind();
                }
                pub fn retainedBytes(self: *const Self) usize {
                    return if (folded) self._data.retainedBytes() else self._data.storage.len * @sizeOf(t.Edge);
                }
                pub const EdgeIterator = struct {
                    owner: *const Self,
                    index: u32 = 0,
                    pub fn next(self: *EdgeIterator) ?Edge(folded) {
                        if (self.index >= self.owner.edges.len) return null;
                        const index = self.index;
                        self.index += 1;
                        return .{ .graph = self.owner.graph, .edge = self.owner.edges[index], .stored = if (folded) .{ .owner = &self.owner._data, .index = index } else {} };
                    }
                };
                pub fn edgeIterator(self: *const Self) EdgeIterator {
                    return .{ .owner = self };
                }
            };
        }
    };
}
