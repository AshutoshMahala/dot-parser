//! Policy-bound attribute resolution. Compact targets remain symbolic;
//! materialized targets read their existing folded maps. Direct APIs are separate.
const std = @import("std");
const t = @import("topology.zig");
const attrs = @import("attributes.zig");
const ports = @import("ports.zig");
const r = @import("resources.zig");
const execution = @import("execution_policy.zig");
const coverage = @import("coverage.zig");
const p = @import("attribute_primitives.zig");
const storage = @import("session_storage.zig");
const encoding = @import("parser_support").encoding;
const none = attrs.none;
const scratch = @import("query_storage.zig");
const Winner = scratch.Winner;

pub fn Bound(comptime Graph: type, comptime caps: encoding.Capabilities, comptime all: bool, comptime config: anytype) type {
    return WithStorage(Graph, caps, all, config, false);
}
pub fn FixedBound(comptime Graph: type, comptime caps: encoding.Capabilities, comptime config: anytype) type {
    return WithStorage(Graph, caps, true, config, true);
}
fn WithStorage(comptime Graph: type, comptime caps: encoding.Capabilities, comptime all: bool, comptime config: anytype, comptime fixed_storage: bool) type {
    const partial = @hasField(Graph, "_data");
    const Data = if (partial) @FieldType(Graph, "_data") else Graph;
    const baseline = comptime execution.resolve(.{}, config.policy);
    const has_hook = config.runtime_policy or baseline.cancellation;
    const Hook = if (has_hook) ?r.Cancellation else void;
    const Polling = @import("parser_support").execution.CancellationPolling(has_hook, if (config.runtime_policy) null else baseline.cancellation_interval);
    return struct {
        const Self = @This();
        pub const Answer = if (partial) coverage.Knowledge(?Data.AttributeView) else ?Data.AttributeView;
        pub const Entry = if (partial) coverage.Knowledge(Data.AttributeView) else Data.AttributeView;
        pub const Outcome = if (all) union(enum) { success, failure: r.Error } else union(enum) { success: Answer, failure: r.Error };
        pub const Progress = if (all) struct {
            work_used: u32,
            total_work: u64,
            attribute: ?Entry,
            attributes_emitted: u32,
            outcome: ?Outcome,
        } else struct { work_used: u32, total_work: u64, outcome: ?Outcome };
        pub const Options = execution.OptionsFor(config);
        const Target = union(enum) {
            node: t.NodeId,
            scope: t.ScopeId,
            edge: t.Edge,
            folded: Data.Materialized.EdgeView,
        };
        const Phase = enum {
            start,
            query_key,
            port_keys,
            connection,
            covers,
            suffix,
            assignments,
            winner_count,
            winner_alloc,
            winner_init,
            winner_update,
            catalog,
            select,
            reverse_attributes,
            folded_map,
            default_map,
            introduction,
            qualify,
            coverage_probe,
            publish,
        };
        graph: *const Graph,
        target: Target,
        cancellation: Hook,
        effective: if (config.runtime_policy) execution.Effective else void,
        max_work: u64,
        total_work: u64 = 0,
        outcome: ?Outcome = null,
        phase: Phase = .start,
        finder: p.Key(caps),
        key_id: u32 = none,
        port_key: ?ports.Key = null,
        port_keys: ports.Keys = .{},
        port_index: u2 = 0,
        port_winners: [2]?ports.Selection = .{ null, null },
        connection: u32 = 0,
        first: ?u32 = null,
        covers: p.Covers = undefined,
        attribute_index: u32 = 0,
        selected: ?ports.Selection = null,
        map: u32 = none,
        scope: t.ScopeId = .root,
        intro: p.Introduction = undefined,
        resolved: ?attrs.Resolved = null,
        uncertainty: if (partial) ?coverage.Uncertainty else void = if (partial) null else {},
        after: if (partial) u32 else void = if (partial) 0 else {},
        coverage_connection: if (partial) bool else void = if (partial) false else {},
        lo: u32 = 0,
        hi: u32 = 0,
        memory: if (all) (if (fixed_storage) scratch.AttributeState else r.Memory) else void,
        winners: if (all) []Winner else void = if (all) &.{} else {},
        winner_count: if (all) u32 else void = if (all) 0 else {},
        winner_read: if (all) u32 else void = if (all) 0 else {},
        catalog: if (all) u32 else void = if (all) 0 else {},
        extra: if (all) u2 else void = if (all) 0 else {},
        emitted: if (all) u32 else void = if (all) 0 else {},
        entry: if (all) ?Entry else void = if (all) null else {},

        pub fn accepts(comptime V: type) bool {
            return V == Graph.NodeView or V == Graph.ScopeView or V == Graph.EdgeView or V == Graph.Materialized.EdgeView;
        }
        pub fn init(view: anytype, key: if (all) void else []const u8, options: anytype) !Self {
            return initWith(view, key, {}, options);
        }
        pub fn initIn(view: anytype, memory: scratch.AttributeScratch, options: anytype) !Self {
            return initWith(view, {}, memory, options);
        }
        inline fn initWith(view: anytype, key: if (all) void else []const u8, memory: if (fixed_storage) scratch.AttributeScratch else void, options: anytype) !Self {
            const V = @TypeOf(view);
            if (comptime !accepts(V)) @compileError("attribute sessions require a compatible IR component view");
            comptime if (@TypeOf(options) != Options) for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
                if (!std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !(config.runtime_policy and std.mem.eql(u8, field, "policy")))
                    @compileError("unknown IR attribute session option: " ++ field);
            };
            const opts = execution.option(Options, options);
            const effective = if (config.runtime_policy) execution.resolve(baseline, opts.policy) else baseline;
            if (config.runtime_policy) try execution.validate(effective);
            const graph: *const Graph = if (V == Graph.Materialized.EdgeView and !partial) view.owner.graph else view.graph;
            const data = if (partial) &graph._data else graph;
            const target: Target = if (V == Graph.NodeView) .{ .node = view.id } else if (V == Graph.ScopeView) .{ .scope = view.id } else if (V == Graph.EdgeView) .{ .edge = view.edge } else .{ .folded = if (partial) .{ .owner = view.stored.owner, .index = view.stored.index, .edge = view.edge } else view };
            switch (target) {
                .node => |id| if (@backingInt(id) >= data.nodes.len) return error.InvalidHandle,
                .scope => |id| if (@backingInt(id) >= data.scopes.len) return error.InvalidHandle,
                .edge => |edge| try checkEdge(data, edge),
                .folded => |edge| {
                    try checkEdge(data, edge.edge);
                    if (edge.index >= edge.owner.edges.len) return error.InvalidHandle;
                },
            }
            const hook = if (has_hook) (if (effective.cancellation) opts.cancellation else null) else {};
            if (has_hook) if (hook) |h| if (h.requested()) return error.Cancelled;
            const limits = opts.limits orelse data.limits;
            if (fixed_storage and target == .folded) try scratch.checkMaterialized(try scratch.checkedBytes(memory), target.folded.owner);
            return .{
                .graph = graph,
                .target = target,
                .cancellation = hook,
                .effective = if (config.runtime_policy) effective else {},
                .max_work = limits.max_work,
                .finder = .{ .bytes = if (all) &.{} else key, .kind = targetKind(target) },
                .memory = if (fixed_storage) try scratch.AttributeState.init(memory, graph, limits) else if (all) .{ .backing = data.allocator, .limit = limits.max_bytes } else {},
            };
        }
        fn checkEdge(data: *const Data, edge: t.Edge) r.Error!void {
            if (@backingInt(edge.from) >= data.nodes.len or @backingInt(edge.to) >= data.nodes.len or @backingInt(edge.first_connection) >= data.connections.len) return error.InvalidHandle;
        }
        inline fn borrowed(self: *const Self) *const Data {
            return if (partial) &self.graph._data else self.graph;
        }
        fn targetKind(target: Target) attrs.Kind {
            return switch (target) {
                .node => .node,
                .scope => .graph,
                .edge, .folded => .edge,
            };
        }
        fn edgeRecord(self: *const Self) t.Edge {
            return switch (self.target) {
                .edge => |e| e,
                .folded => |e| e.edge,
                else => unreachable,
            };
        }
        fn prepare(self: *Self) void {
            if (self.target == .edge) {
                self.connection = if (self.borrowed().strict) 0 else @backingInt(self.target.edge.first_connection);
                self.phase = .connection;
            } else self.phase = if (all) .catalog else .select;
        }
        fn fallback(self: *Self) void {
            const graph = self.borrowed();
            if (self.key_id == none or self.key_id >= ports.right) {
                if (self.port_key) |key| {
                    if (self.target == .folded) {
                        const intro = self.target.folded.owner.folded.port_introductions[@backingInt(key)];
                        self.finishValue(if (intro) |i| ports.resolve(graph, i, key, true) else null);
                    } else {
                        self.intro = .{ .wanted = key };
                        self.phase = .introduction;
                    }
                } else self.finishValue(null);
                return;
            }
            switch (self.target) {
                .node => |id| {
                    const n = graph.nodes[@backingInt(id)];
                    self.scope = graph.occurrences[@backingInt(graph.mentions[n.first_mention].occurrence)].scope;
                    self.map = n.attribute_state;
                },
                .scope => |id| {
                    self.scope = id;
                    self.map = graph.attribute_data.scopes[@backingInt(id)].graph;
                },
                .edge, .folded => {
                    const id = @backingInt(self.edgeRecord().first_connection);
                    self.scope = graph.occurrences[@backingInt(graph.connections[id].occurrence)].scope;
                    self.map = graph.attribute_data.connection_defaults[id];
                },
            }
            self.phase = .default_map;
        }
        fn finishValue(self: *Self, value: ?attrs.Resolved) void {
            self.resolved = value;
            self.phase = if (partial) .qualify else .publish;
        }
        fn finishSelection(self: *Self, selection: ports.Selection) void {
            self.finishValue(if (selection.attribute >= ports.right)
                ports.resolve(self.borrowed(), selection, self.port_key.?, false)
            else
                attrs.resolvedConnection(self.borrowed(), selection.attribute, selection.connection));
        }
        fn step(self: *Self) r.Error!void {
            const graph = self.borrowed();
            const store = &graph.attribute_data;
            switch (self.phase) {
                .start => {
                    if (all) {
                        if (targetKind(self.target) == .edge and (graph.has_ports or partial)) {
                            self.finder = .{ .bytes = "tailport", .kind = .edge };
                            self.phase = .port_keys;
                        } else self.prepare();
                    } else {
                        if (targetKind(self.target) == .edge) {
                            if (std.mem.eql(u8, self.finder.bytes, "tailport")) self.port_key = .tailport;
                            if (std.mem.eql(u8, self.finder.bytes, "headport")) self.port_key = .headport;
                        }
                        self.phase = .query_key;
                    }
                },
                .query_key => if (try self.finder.step(graph)) {
                    self.key_id = self.finder.found orelse none;
                    self.prepare();
                },
                .port_keys => if (all) {
                    if (try self.finder.step(graph)) {
                        if (self.finder.found) |id| self.port_keys.ids[self.port_index] = id;
                        self.port_index += 1;
                        if (self.port_index == 2) self.prepare() else self.finder = .{ .bytes = "headport", .kind = .edge };
                    }
                } else unreachable,
                .connection => {
                    const end = if (graph.strict) graph.connections.len else @as(usize, @backingInt(self.target.edge.first_connection)) + 1;
                    if (self.connection == end) {
                        if (self.first != @backingInt(self.target.edge.first_connection)) return error.InvalidHandle;
                        self.phase = if (all) .catalog else .select;
                    } else {
                        self.covers = .{ .edge = self.target.edge };
                        self.phase = .covers;
                    }
                },
                .covers => if (self.covers.step(graph, graph.connections[self.connection])) |found| {
                    if (found.forward or found.backward) {
                        if (self.first == null) {
                            self.first = self.connection;
                            if (self.first != @backingInt(self.target.edge.first_connection)) return error.InvalidHandle;
                        }
                        self.phase = .suffix;
                    } else {
                        self.connection += 1;
                        self.phase = .connection;
                    }
                },
                .suffix => {
                    const c = graph.connections[self.connection];
                    const suffixes = ports.suffixes(c, @fromBackingInt(self.connection), self.target.edge);
                    if (all) {
                        for (suffixes, 0..) |suffix, i| if (suffix) |s| {
                            self.port_winners[i] = s;
                        };
                        self.attribute_index = c.attributes.start;
                    } else {
                        if (self.port_key) |key| if (suffixes[@backingInt(key)]) |s| {
                            self.selected = s;
                        };
                        self.attribute_index = c.attributes.start + c.attributes.len;
                    }
                    self.phase = .assignments;
                },
                .assignments => {
                    const range = graph.connections[self.connection].attributes;
                    if (all) {
                        if (self.attribute_index == range.start + range.len or (!graph.strict and !graph.has_ports)) {
                            self.connection += 1;
                            self.phase = .connection;
                            return;
                        }
                        if (graph.strict and self.winners.len == 0) {
                            self.catalog = 0;
                            self.phase = .winner_count;
                            return;
                        }
                        const key = store.meta[self.attribute_index].key;
                        if (self.port_keys.key(key)) |pk| self.port_winners[@backingInt(pk)] = .{ .attribute = self.attribute_index, .connection = @fromBackingInt(self.connection) };
                        if (graph.strict) {
                            self.lo = 0;
                            self.hi = @intCast(self.winners.len);
                            self.phase = .winner_update;
                        } else self.attribute_index += 1;
                    } else {
                        if (self.key_id == none or self.attribute_index == range.start) {
                            self.connection += 1;
                            self.phase = .connection;
                            return;
                        }
                        self.attribute_index -= 1;
                        if (store.meta[self.attribute_index].key == self.key_id) {
                            self.selected = .{ .attribute = self.attribute_index, .connection = @fromBackingInt(self.connection) };
                            self.connection += 1;
                            self.phase = .connection;
                        }
                    }
                },
                .winner_count => if (all) {
                    if (self.catalog == store.keys.items.len) self.phase = .winner_alloc else {
                        if (store.keys.items[self.catalog].kind == .edge) self.winner_count += 1;
                        self.catalog += 1;
                    }
                } else unreachable,
                .winner_alloc => if (all) {
                    self.winners = if (fixed_storage) try self.memory.take(self.winner_count) else try storage.allocate(Winner, self.memory.allocator(), self.winner_count);
                    self.catalog = 0;
                    self.winner_count = 0;
                    self.phase = .winner_init;
                } else unreachable,
                .winner_init => if (all) {
                    if (self.catalog == store.keys.items.len) {
                        self.catalog = 0;
                        self.phase = .assignments;
                    } else {
                        if (store.keys.items[self.catalog].kind == .edge) {
                            self.winners[self.winner_count] = .{ .key = self.catalog };
                            self.winner_count += 1;
                        }
                        self.catalog += 1;
                    }
                } else unreachable,
                .winner_update => if (all) {
                    const mid = self.lo + (self.hi - self.lo) / 2;
                    const key = store.meta[self.attribute_index].key;
                    const slot = &self.winners[mid];
                    if (slot.key == key) {
                        slot.attribute = self.attribute_index;
                        slot.connection = @fromBackingInt(self.connection);
                        self.attribute_index += 1;
                        self.phase = .assignments;
                    } else if (slot.key < key) self.lo = mid + 1 else self.hi = mid;
                } else unreachable,
                .catalog => if (all) {
                    if (self.target == .folded) {
                        const keys = self.target.folded.owner.folded.keys.items;
                        if (self.catalog == keys.len) {
                            self.outcome = .success;
                            return;
                        }
                        self.key_id = keys[self.catalog];
                        self.catalog += 1;
                    } else if (self.catalog < store.keys.items.len) {
                        const id = self.catalog;
                        self.catalog += 1;
                        if (store.keys.items[id].kind != targetKind(self.target)) return;
                        self.key_id = id;
                    } else {
                        if (targetKind(self.target) != .edge or self.extra == 2) {
                            self.outcome = .success;
                            return;
                        }
                        const id = self.port_keys.ids[self.extra];
                        self.extra += 1;
                        if (id < ports.right) return;
                        self.key_id = id;
                    }
                    self.port_key = if (targetKind(self.target) == .edge) self.port_keys.key(self.key_id) else null;
                    self.selected = null;
                    if (self.target == .edge and self.key_id < ports.right and self.winners.len != 0) {
                        const winner = self.winners[self.winner_read];
                        self.winner_read += 1;
                        if (winner.attribute != none) self.selected = .{ .attribute = winner.attribute, .connection = winner.connection };
                    }
                    self.phase = .select;
                } else unreachable,
                .select => {
                    switch (self.target) {
                        .node, .scope => self.fallback(),
                        .folded => |view| {
                            self.map = if (view.index < view.owner.folded.roots.items.len) view.owner.folded.roots.items[view.index] else none;
                            self.phase = .folded_map;
                        },
                        .edge => {
                            if (all) if (self.port_key) |pk| if (self.port_winners[@backingInt(pk)]) |s| {
                                self.finishSelection(s);
                                return;
                            };
                            if (self.selected) |s| self.finishSelection(s) else if (all and !graph.strict and self.key_id < ports.right) {
                                const range = graph.connections[@backingInt(self.target.edge.first_connection)].attributes;
                                self.attribute_index = range.start + range.len;
                                self.phase = .reverse_attributes;
                            } else self.fallback();
                        },
                    }
                },
                .reverse_attributes => {
                    const range = graph.connections[@backingInt(self.edgeRecord().first_connection)].attributes;
                    if (self.attribute_index == range.start) self.fallback() else {
                        self.attribute_index -= 1;
                        if (store.meta[self.attribute_index].key == self.key_id) self.finishSelection(.{ .attribute = self.attribute_index, .connection = self.edgeRecord().first_connection });
                    }
                },
                .folded_map => {
                    // Synthetic keys use reserved IDs even when no written key exists.
                    const key = if (self.key_id == none and self.port_key != null) self.target.folded.owner.folded.port_keys.ids[@backingInt(self.port_key.?)] else self.key_id;
                    if (self.map == none) self.fallback() else {
                        const cell = self.target.folded.owner.folded.cells.items[self.map];
                        if (cell.key == key) self.finishSelection(.{ .attribute = cell.attribute, .connection = cell.connection }) else self.map = if (key < cell.key) cell.left else cell.right;
                    }
                },
                .default_map => {
                    if (self.map == none) self.finishValue(attrs.resolved(graph, store.keys.items[self.key_id].first_attribute, targetKind(self.target), self.scope, true)) else {
                        const cell = store.cells.items[self.map];
                        if (cell.key == self.key_id) self.finishValue(attrs.resolved(graph, cell.attribute, targetKind(self.target), self.scope, false)) else self.map = if (self.key_id < cell.key) cell.left else cell.right;
                    }
                },
                .introduction => if (self.intro.step(graph)) self.finishValue(if (self.intro.found) |i| ports.resolve(graph, i, self.port_key.?, true) else null),
                .qualify => if (partial) {
                    self.uncertainty = null;
                    const entries = self.graph._coverage.entries.items;
                    if (entries.len == 0 or (all and self.resolved == null)) {
                        self.phase = .publish;
                        return;
                    }
                    var after: ?u32 = null;
                    self.coverage_connection = targetKind(self.target) == .edge;
                    if (self.resolved) |value| {
                        if (!self.coverage_connection) {
                            if (value.kind == .explicit and value.origin == .declaration) after = value.origin.declaration;
                        } else if (value.kind == .explicit or value.kind == .derived) {
                            const conn: ?t.ConnectionId = switch (value.origin) {
                                .connection, .written_left_port, .written_right_port => |id| id,
                                .declaration => null,
                            };
                            if (conn) |id| {
                                if (!graph.strict) {
                                    self.phase = .publish;
                                    return;
                                }
                                const e = self.edgeRecord();
                                const later_set = self.graph._coverage.setConnectionAfter(id);
                                if (!later_set and !(e.operator == .undirected and e.from != e.to and self.port_key != null)) after = @backingInt(id);
                            }
                        }
                    }
                    if (after) |id| {
                        self.after = id;
                        self.lo = 0;
                        self.hi = @intCast(entries.len);
                        self.phase = .coverage_probe;
                    } else {
                        const gap = entries[entries[0].suffix_first].gap;
                        self.uncertainty = .{ .reason = gap.reason, .span = gap.range };
                        self.phase = .publish;
                    }
                } else unreachable,
                .coverage_probe => if (partial) {
                    const entries = self.graph._coverage.entries.items;
                    if (self.lo == self.hi) {
                        if (self.lo < entries.len) {
                            const gap = entries[entries[self.lo].suffix_first].gap;
                            self.uncertainty = .{ .reason = gap.reason, .span = gap.range };
                        }
                        self.phase = .publish;
                    } else {
                        const mid = self.lo + (self.hi - self.lo) / 2;
                        const boundary = if (self.coverage_connection) entries[mid].connection_boundary else entries[mid].boundary;
                        if (boundary <= self.after) self.lo = mid + 1 else self.hi = mid;
                    }
                } else unreachable,
                .publish => {
                    const value: ?Data.AttributeView = if (self.resolved) |v| .{ .graph = graph, .resolved = v } else null;
                    if (all) {
                        if (value) |v| {
                            if (self.emitted == std.math.maxInt(u32)) return error.IndexLimit;
                            self.entry = if (partial) (if (self.uncertainty) |u| .{ .unknown = .{ .uncertainty = u, .retained = v } } else .{ .known = v }) else v;
                            self.emitted += 1;
                        }
                        self.phase = .catalog;
                    } else self.outcome = .{ .success = if (partial) (if (self.uncertainty) |u| .{ .unknown = .{ .uncertainty = u, .retained = value } } else .{ .known = value }) else value };
                },
            }
        }
        fn progress(self: *const Self, used: u32) Progress {
            if (all) return .{ .work_used = used, .total_work = self.total_work, .attribute = self.entry, .attributes_emitted = self.emitted, .outcome = self.outcome };
            return .{ .work_used = used, .total_work = self.total_work, .outcome = self.outcome };
        }
        fn poll(self: *Self) bool {
            return execution.pollSession(self, has_hook);
        }
        pub fn advance(self: *Self, budget: u32) (if (config.runtime_policy) execution.Error!Progress else Progress) {
            if (config.runtime_policy) {
                if (!self.effective.metering) return error.MeteringDisabled;
            } else if (!baseline.metering) @compileError("metering is disabled; use run()");
            return self.drive(budget);
        }
        fn drive(self: *Self, budget: u32) Progress {
            if (all) self.entry = null;
            if (self.outcome != null or !self.poll()) return self.progress(0);
            const interval = if (config.runtime_policy) self.effective.cancellation_interval else baseline.cancellation_interval;
            var polling: Polling = .{};
            _ = polling.due(interval); // Entry poll covers the first credit.
            var used: u32 = 0;
            while (used < budget and self.outcome == null and (if (all) self.entry == null else true)) {
                if (self.total_work == self.max_work) {
                    if (used == 0 or self.poll()) self.outcome = .{ .failure = error.WorkLimit };
                    break;
                }
                if (used != 0 and polling.due(interval) and !self.poll()) break;
                self.total_work += 1;
                used += 1;
                polling.spend(1);
                self.step() catch |err| {
                    self.outcome = .{ .failure = if (all) self.memory.failure(err) else err };
                };
            }
            return self.progress(used);
        }
        pub fn run(self: *Self) Progress {
            while (true) {
                const result = self.drive(std.math.maxInt(u32));
                if (result.outcome != null or (if (all) result.attribute != null else false)) return result;
            }
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome == null) self.outcome = .{ .failure = error.Cancelled };
        }
        pub fn peakBytes(self: *const Self) usize {
            return if (all) self.memory.peak else 0;
        }
        pub fn deinit(self: *Self) void {
            if (all and !fixed_storage) storage.release(Winner, self.memory.allocator(), self.winners);
            self.* = undefined;
        }
        pub fn shortfall(self: *const Self) ?@import("fixed_storage.zig").StorageShortfall {
            if (!fixed_storage) @compileError("shortfall requires fixed scratch");
            return self.memory.shortfall;
        }
        pub fn scratchPeak(self: *const Self) scratch.AttributeScratchCapacities {
            if (!fixed_storage) @compileError("scratchPeak requires fixed scratch");
            return self.memory.used;
        }
    };
}
