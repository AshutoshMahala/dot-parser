//! Bounded, owning expansion. The direct driver remains specialized for throughput;
//! both drivers share edge identity, port semantics, output and AVL folding.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const attrs = @import("attributes.zig");
const ports = @import("ports.zig");
const edges = @import("edges.zig");
const folded = @import("materialized_attributes.zig");
const storage = @import("session_storage.zig");
const Growth = storage.Growth;
const encoding = @import("parser_support").encoding;
const none = attrs.none;

pub const Outcome = union(enum) { success, failure: r.Error };
pub const Progress = struct {
    /// Work consumed by this call, not the lifetime total.
    work_used: u32,
    total_work: u64,
    /// Actually visited candidate pairs (including strict duplicates).
    pairs_visited: u64,
    edges_created: u32,
    outcome: ?Outcome,
};
pub const TakeError = r.Error || error{ NotReady, AlreadyTaken };

pub fn Session(comptime Graph: type, comptime caps: encoding.Capabilities, comptime attributes: bool) type {
    return struct {
        const Self = @This();
        pub const Result = if (attributes) Graph.Materialized else t.MaterializedTopology;
        pub const SessionProgress = Progress;
        const Endpoint = struct {
            singleton: ?t.NodeId = null,
            nodes: std.ArrayList(t.NodeId) = .empty,
            growth: Growth(t.NodeId) = .{},
            fn len(self: Endpoint) u32 {
                return if (self.singleton != null) 1 else @intCast(self.nodes.items.len);
            }
            fn at(self: Endpoint, index: u32) t.NodeId {
                return self.singleton orelse self.nodes.items[index];
            }
        };
        const Phase = enum {
            port_catalog,
            port_name,
            connection,
            endpoint,
            body,
            mention,
            endpoint_append,
            marks_clear,
            endpoint_done,
            product,
            pair,
            probe,
            prepare,
            table_clear,
            rehash_scan,
            rehash_probe,
            insert,
            append_edge,
            apply,
            roots,
            suffix,
            attribute,
            set_probe,
            set_insert,
            set_unwind,
            catalog,
            key_append,
            finish,
            yielded, // Driver exit only; never saved as a resumable phase.
        };
        graph: *const Graph,
        limits: r.Limits,
        cancellation: ?r.Cancellation,
        memory: r.Memory,
        total_work: u64 = 0,
        outcome: ?Outcome = null,
        taken: bool = false,
        phase: Phase,
        endpoints: [2]Endpoint = .{ .{}, .{} },
        side: u1 = 0,
        body_index: u32 = 0,
        body_end: u32 = 0,
        mention_index: u32 = 0,
        mention_end: u32 = 0,
        pending_node: t.NodeId = undefined,
        marks: []u32 = &.{},
        mark_index: u32 = 0,
        marks_after: Phase = .body,
        generation: u32 = 0,
        connection: u32 = 0,
        left_index: u32 = 0,
        right_index: u32 = 0,
        visited: u64 = 0,
        stored: std.ArrayList(t.Edge) = .empty,
        edge_growth: Growth(t.Edge) = .{},
        candidate: t.Edge = undefined,
        target: u32 = 0,
        slots: []u32 = &.{},
        new_slots: []u32 = &.{},
        table_index: u32 = 0,
        rehash_index: u32 = 0,
        rehash_id: u32 = 0,
        slot: u32 = 0,
        maps: if (attributes) folded.Builder(true) else void,
        root_growth: if (attributes) Growth(u32) else void = if (attributes) .{} else {},
        cell_growth: if (attributes) Growth(folded.Cell) else void = if (attributes) .{} else {},
        key_growth: if (attributes) Growth(u32) else void = if (attributes) .{} else {},
        catalog_index: if (attributes) u32 else void = if (attributes) 0 else {},
        pending_key: if (attributes) u32 else void = if (attributes) 0 else {},
        port_index: if (attributes) u2 else void = if (attributes) 0 else {},
        port_match: if (attributes) AsciiName(caps) else void = if (attributes) .{} else {},
        attribute_index: if (attributes) u32 else void = if (attributes) 0 else {},
        set_key: if (attributes) u32 else void = if (attributes) 0 else {},
        set_attribute: if (attributes) u32 else void = if (attributes) 0 else {},
        set_cursor: if (attributes) u32 else void = if (attributes) none else {},
        set_child: if (attributes) u32 else void = if (attributes) none else {},
        set_path: if (attributes) [48]u32 else void = undefined,
        set_depth: if (attributes) u8 else void = if (attributes) 0 else {},
        set_after: if (attributes) Phase else void = if (attributes) .attribute else {},

        /// No scan or allocation. Borrows the immutable IR until the session
        /// and its attribute-bearing result are destroyed. Do not copy after use.
        pub fn init(graph: *const Graph, options: r.Options) r.Error!Self {
            const limits = options.limits orelse graph.limits;
            if (options.cancellation) |c| if (c.requested()) return error.Cancelled;
            return .{
                .graph = graph,
                .limits = limits,
                .cancellation = options.cancellation,
                .memory = .{ .backing = graph.allocator, .limit = limits.max_bytes },
                .phase = if (attributes and graph.has_ports) .port_catalog else .connection,
                .maps = if (attributes) .{ .limit = limits.max_attribute_states } else {},
            };
        }
        pub fn deinit(self: *Self) void {
            const a = self.memory.allocator();
            for (&self.endpoints) |*endpoint| {
                endpoint.growth.deinit(a);
                endpoint.nodes.deinit(a);
            }
            a.free(self.marks);
            a.free(self.slots);
            a.free(self.new_slots);
            self.edge_growth.deinit(a);
            self.stored.deinit(a);
            if (attributes) {
                self.root_growth.deinit(a);
                self.cell_growth.deinit(a);
                self.key_growth.deinit(a);
                self.maps.deinit(a);
            }
            self.* = undefined;
        }
        pub fn peakBytes(self: *const Self) usize {
            return self.memory.peak;
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome == null) self.outcome = .{ .failure = error.Cancelled };
        }
        inline fn progress(self: *const Self, used: u32) Progress {
            return .{ .work_used = used, .total_work = self.total_work, .pairs_visited = self.visited, .edges_created = if (self.taken) self.target else @intCast(self.stored.items.len), .outcome = self.outcome };
        }
        inline fn poll(self: *Self) bool {
            if (self.cancellation) |c| if (c.requested()) {
                self.cancel();
                return false;
            };
            return true;
        }
        /// One credit is one bounded state transition: a record/probe/AVL node,
        /// a source code unit, or <=64 bytes of buffer copying/initialization.
        /// Allocator callbacks are external, not wall-time bounded. Zero polls
        /// cancellation but does no semantic work. Every stop is latched.
        /// Keep this wrapper small/inlined: copying Progress through another
        /// call frame dominates budget-one resumes, particularly in Small.
        pub inline fn advance(self: *Self, budget: u32) Progress {
            if (self.outcome != null or !self.poll()) return self.progress(0);
            const before = self.total_work;
            // Select once per resume, not at every tiny transition. The enabled
            // driver still polls before every credit, including a limit stop.
            const result = if (budget == 1)
                self.drive(false, true, 1)
            else if (self.cancellation == null)
                self.drive(false, false, budget)
            else
                self.drive(true, false, budget);
            result catch |err| {
                self.outcome = .{ .failure = self.memory.failure(err) };
            };
            return self.progress(@intCast(self.total_work - before));
        }
        fn drive(self: *Self, comptime cancellable: bool, comptime single: bool, requested: u32) r.Error!void {
            const budget = if (single) 1 else requested;
            var used: u32 = 0;
            var current = self.phase;
            defer if (!single) {
                self.phase = current;
            };
            const initial_work = self.total_work;
            defer self.total_work = initial_work + used;
            const grant: u32 = @intCast(@min(budget, self.limits.max_work - initial_work));
            if (single and grant == 0) return error.WorkLimit;
            const a = self.memory.allocator();
            // Literal successors are direct control-flow edges, not a return to
            // a central step() dispatch. Every edge (including a self-loop)
            // still goes through the same credit/poll gate. Keep accounting
            // local without cancellation; publish it on every exit, and before
            // callbacks when cancellation is enabled. No state or work is lost
            // on a pause, allocator failure or other terminal error.
            machine: switch (self.phase) {
                .yielded => return,
                inline else => |phase| {
                    current = phase;
                    if (single) {
                        // advance already polled. One step has no intermediate
                        // poll, countdown or repeated lifetime-limit test.
                        if (used != 0) return;
                        used = 1;
                    } else {
                        if (used == grant) {
                            if (used == budget) return;
                            // Cancellation precedes lifetime exhaustion.
                            if (cancellable) {
                                self.phase = phase;
                                if (used != 0 and !self.poll()) return;
                            }
                            return error.WorkLimit;
                        }
                        if (cancellable) {
                            self.phase = phase;
                            if (used != 0 and !self.poll()) return;
                        }
                        used += 1;
                        if (cancellable) self.total_work = initial_work + used;
                    }
                    switch (phase) {
                        .port_catalog => if (attributes) {
                            if (self.catalog_index == self.graph.attribute_data.keys.items.len) {
                                self.catalog_index = 0;
                                self.maps.ports_initialized = true;
                                continue :machine self.successor(single, .connection);
                            }
                            const key = self.graph.attribute_data.keys.items[self.catalog_index];
                            if (key.kind == .edge) inline for (.{ "tailport", "headport" }, 0..) |name, i| {
                                const wanted = std.hash.Wyhash.hash(0, name) ^ @as(u64, @backingInt(attrs.Kind.edge));
                                if (key.hash == wanted) {
                                    self.port_index = i;
                                    self.port_match = .{ .raw = self.graph.text(key.name), .actual = self.graph.source_info.encoding };
                                    continue :machine self.successor(single, .port_name);
                                }
                            };
                            self.catalog_index += 1;
                        } else unreachable,
                        .port_name => if (attributes) {
                            const name: []const u8 = if (self.port_index == 0) "tailport" else "headport";
                            if (self.port_match.step(name)) |matches| {
                                if (matches) self.maps.port_keys.ids[self.port_index] = self.catalog_index;
                                self.catalog_index += 1;
                                continue :machine self.successor(single, .port_catalog);
                            }
                        } else unreachable,
                        .connection => {
                            if (self.connection == self.graph.connections.len) {
                                if (attributes) {
                                    self.catalog_index = 0;
                                    self.port_index = 0;
                                }
                                continue :machine self.successor(single, if (attributes and self.stored.items.len != 0) .catalog else .finish);
                            } else {
                                self.side = 0;
                                continue :machine self.successor(single, .endpoint);
                            }
                        },
                        .endpoint => {
                            const source = self.graph.connections[self.connection];
                            const members = if (self.side == 0) source.left.members else source.right.members;
                            const handle = @backingInt(members);
                            const out = &self.endpoints[self.side];
                            // clearRetainingCapacity poisons the whole used slice in
                            // safety builds. No old item is readable after this reset.
                            out.nodes.items.len = 0;
                            if (handle & t.node_bit != 0) {
                                out.singleton = @fromBackingInt(handle & ~t.node_bit);
                                continue :machine self.successor(single, .endpoint_done);
                            } else {
                                out.singleton = null;
                                self.body_index = self.graph.bodies[handle].first;
                                self.body_end = handle + 1;
                                if (self.generation == std.math.maxInt(u32)) {
                                    self.mark_index = 0;
                                    self.marks_after = .body;
                                    continue :machine self.successor(single, .marks_clear);
                                } else {
                                    self.generation += 1;
                                    continue :machine self.successor(single, .body);
                                }
                            }
                        },
                        .body => {
                            if (self.body_index == self.body_end) {
                                continue :machine self.successor(single, .endpoint_done);
                            }
                            const body = self.graph.bodies[self.body_index];
                            self.body_index += 1;
                            if (body.start == body.end) continue :machine self.successor(single, phase);
                            self.mention_index = body.start;
                            self.mention_end = body.end;
                            if (self.marks.len == 0) {
                                self.marks = try storage.allocate(u32, a, self.graph.nodes.len);
                                self.mark_index = 0;
                                self.marks_after = .mention;
                                continue :machine self.successor(single, .marks_clear);
                            }
                            continue :machine self.successor(single, .mention);
                        },
                        .marks_clear => {
                            const end = self.mark_index + @min(self.marks.len - self.mark_index, 16);
                            @memset(self.marks[self.mark_index..end], 0);
                            self.mark_index = @intCast(end);
                            if (end == self.marks.len) {
                                self.generation = 1;
                                continue :machine self.successor(single, self.marks_after);
                            }
                        },
                        .mention => {
                            if (self.mention_index == self.mention_end) {
                                continue :machine self.successor(single, .body);
                            }
                            const node = self.graph.mentions[self.mention_index].node;
                            self.mention_index += 1;
                            const id = @backingInt(node);
                            if (self.marks[id] == self.generation) continue :machine self.successor(single, phase);
                            self.marks[id] = self.generation;
                            self.pending_node = node;
                            continue :machine self.successor(single, .endpoint_append);
                        },
                        .endpoint_append => {
                            const out = &self.endpoints[self.side];
                            if (!try out.growth.step(&out.nodes, a)) continue :machine self.successor(single, phase);
                            out.nodes.appendAssumeCapacity(self.pending_node);
                            continue :machine self.successor(single, .mention);
                        },
                        .endpoint_done => if (self.side == 0) {
                            self.side = 1;
                            continue :machine self.successor(single, .endpoint);
                        } else {
                            continue :machine self.successor(single, .product);
                        },
                        .product => {
                            const product = std.math.mul(u64, self.endpoints[0].len(), self.endpoints[1].len()) catch return error.PairLimit;
                            if (product > self.limits.max_pairs - self.visited) return error.PairLimit;
                            if (product == 0) {
                                self.connection += 1;
                                continue :machine self.successor(single, .connection);
                            }
                            self.left_index = 0;
                            self.right_index = 0;
                            continue :machine self.successor(single, .pair);
                        },
                        .pair => {
                            if (self.left_index == self.endpoints[0].len()) {
                                self.connection += 1;
                                continue :machine self.successor(single, .connection);
                            }
                            self.visited += 1;
                            self.candidate = .{ .from = self.endpoints[0].at(self.left_index), .to = self.endpoints[1].at(self.right_index), .operator = self.graph.connections[self.connection].effective_operator, .first_connection = @fromBackingInt(self.connection) };
                            self.right_index += 1;
                            if (self.right_index == self.endpoints[1].len()) {
                                self.right_index = 0;
                                self.left_index += 1;
                            }
                            if (self.graph.strict and self.slots.len != 0) {
                                self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                continue :machine self.successor(single, .probe);
                            } else continue :machine self.successor(single, .prepare);
                        },
                        .probe => {
                            const id = self.slots[self.slot];
                            if (id == none) {
                                continue :machine self.successor(single, .prepare);
                            }
                            if (std.meta.eql(edges.canonical(self.stored.items[id]), edges.canonical(self.candidate))) {
                                self.target = id;
                                continue :machine self.successor(single, if (attributes) .apply else .pair);
                            } else self.slot = @intCast((@as(usize, self.slot) + 1) & (self.slots.len - 1));
                        },
                        .prepare => {
                            if (self.stored.items.len >= self.limits.max_edges) return error.EdgeLimit;
                            if (!self.graph.strict) {
                                continue :machine self.successor(single, .append_edge);
                            }
                            if (self.slots.len != 0 and self.stored.items.len < self.slots.len / 2) {
                                self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                continue :machine self.successor(single, .insert);
                            } else {
                                const capacity = if (self.slots.len == 0) 16 else std.math.mul(usize, self.slots.len, 2) catch return error.IndexLimit;
                                if (capacity > std.math.maxInt(u32)) return error.IndexLimit;
                                self.new_slots = try storage.allocate(u32, a, capacity);
                                self.table_index = 0;
                                continue :machine self.successor(single, .table_clear);
                            }
                        },
                        .table_clear => {
                            const end = @min(self.new_slots.len, @as(usize, self.table_index) + 16);
                            @memset(self.new_slots[self.table_index..end], none);
                            self.table_index = @intCast(end);
                            if (end == self.new_slots.len) {
                                self.rehash_index = 0;
                                continue :machine self.successor(single, .rehash_scan);
                            }
                        },
                        .rehash_scan => {
                            if (self.rehash_index == self.slots.len) {
                                storage.release(u32, a, self.slots);
                                self.slots = self.new_slots;
                                self.new_slots = &.{};
                                self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                continue :machine self.successor(single, .insert);
                            }
                            const id = self.slots[self.rehash_index];
                            self.rehash_index += 1;
                            if (id != none) {
                                self.rehash_id = id;
                                self.slot = @intCast(hash(self.stored.items[id]) & (self.new_slots.len - 1));
                                continue :machine self.successor(single, .rehash_probe);
                            }
                        },
                        .rehash_probe => {
                            if (self.new_slots[self.slot] == none) {
                                self.new_slots[self.slot] = self.rehash_id;
                                continue :machine self.successor(single, .rehash_scan);
                            } else self.slot = @intCast((@as(usize, self.slot) + 1) & (self.new_slots.len - 1));
                        },
                        .insert => {
                            if (self.slots[self.slot] == none) {
                                self.slots[self.slot] = try r.index(self.stored.items.len);
                                continue :machine self.successor(single, .append_edge);
                            } else self.slot = @intCast((@as(usize, self.slot) + 1) & (self.slots.len - 1));
                        },
                        .append_edge => {
                            if (!try self.edge_growth.step(&self.stored, a)) continue :machine self.successor(single, phase);
                            self.target = try r.index(self.stored.items.len);
                            self.stored.appendAssumeCapacity(self.candidate);
                            continue :machine self.successor(single, if (attributes) .apply else .pair);
                        },
                        .apply => if (attributes) {
                            const source = self.graph.connections[self.connection];
                            continue :machine self.successor(single, if (source.attributes.len == 0 and source.left.port == null and source.right.port == null) .pair else .roots);
                        } else unreachable,
                        .roots => if (attributes) {
                            if (self.maps.roots.items.len <= self.target) {
                                if (!try self.root_growth.step(&self.maps.roots, a)) continue :machine self.successor(single, phase);
                                self.maps.roots.appendAssumeCapacity(none);
                            } else {
                                self.port_index = 0;
                                self.attribute_index = 0;
                                continue :machine self.successor(single, .suffix);
                            }
                        } else unreachable,
                        .suffix => if (attributes) {
                            if (self.port_index == 2) {
                                continue :machine self.successor(single, .attribute);
                            }
                            const index = self.port_index;
                            self.port_index += 1;
                            const suffix = ports.suffixes(self.graph.connections[self.connection], @fromBackingInt(self.connection), self.stored.items[self.target])[index];
                            if (suffix) |selection| {
                                if (self.maps.port_introductions[index] == null) self.maps.port_introductions[index] = selection;
                                self.startSet(self.maps.port_keys.ids[index], selection.attribute, .suffix);
                                continue :machine self.successor(single, .set_probe);
                            }
                        } else unreachable,
                        .attribute => if (attributes) {
                            const range = self.graph.connections[self.connection].attributes;
                            if (self.attribute_index == range.len) {
                                continue :machine self.successor(single, .pair);
                            }
                            const id = range.start + self.attribute_index;
                            self.attribute_index += 1;
                            self.startSet(self.graph.attribute_data.meta[id].key, id, .attribute);
                            continue :machine self.successor(single, .set_probe);
                        } else unreachable,
                        .set_probe => if (attributes) {
                            if (self.set_cursor == none) {
                                continue :machine self.successor(single, .set_insert);
                            }
                            const cell = &self.maps.cells.items[self.set_cursor];
                            if (cell.key == self.set_key) {
                                cell.attribute = self.set_attribute;
                                cell.connection = @fromBackingInt(self.connection);
                                continue :machine self.successor(single, self.set_after);
                            } else {
                                if (self.set_depth == self.set_path.len) return error.IndexLimit;
                                self.set_path[self.set_depth] = self.set_cursor;
                                self.set_depth += 1;
                                self.set_cursor = if (self.set_key < cell.key) cell.left else cell.right;
                            }
                        } else unreachable,
                        .set_insert => if (attributes) {
                            if (self.maps.cells.items.len >= self.maps.limit) return error.AttributeStateLimit;
                            if (!try self.cell_growth.step(&self.maps.cells, a)) continue :machine self.successor(single, phase);
                            self.set_child = try r.index(self.maps.cells.items.len);
                            self.maps.cells.appendAssumeCapacity(.{ .key = self.set_key, .attribute = self.set_attribute, .connection = @fromBackingInt(self.connection) });
                            continue :machine self.successor(single, .set_unwind);
                        } else unreachable,
                        .set_unwind => if (attributes) {
                            if (self.set_depth == 0) {
                                self.maps.roots.items[self.target] = self.set_child;
                                continue :machine self.successor(single, self.set_after);
                            } else {
                                self.set_depth -= 1;
                                self.set_child = self.maps.link(self.set_path[self.set_depth], self.set_key, self.set_child);
                            }
                        } else unreachable,
                        .catalog => if (attributes) {
                            if (self.catalog_index < self.graph.attribute_data.keys.items.len) {
                                const id = self.catalog_index;
                                self.catalog_index += 1;
                                if (self.graph.attribute_data.keys.items[id].kind == .edge) {
                                    self.pending_key = id;
                                    continue :machine self.successor(single, .key_append);
                                }
                            } else if (self.port_index < 2) {
                                const i = self.port_index;
                                self.port_index += 1;
                                if (self.maps.port_introductions[i] != null and self.maps.port_keys.ids[i] >= ports.right) {
                                    self.pending_key = self.maps.port_keys.ids[i];
                                    continue :machine self.successor(single, .key_append);
                                }
                            } else continue :machine self.successor(single, .finish);
                        } else unreachable,
                        .key_append => if (attributes) {
                            if (!try self.key_growth.step(&self.maps.keys, a)) continue :machine self.successor(single, phase);
                            self.maps.keys.appendAssumeCapacity(self.pending_key);
                            continue :machine self.successor(single, .catalog);
                        } else unreachable,
                        .yielded => unreachable,
                        .finish => {
                            self.outcome = .success;
                            return;
                        },
                    }
                    continue :machine self.successor(single, phase);
                },
            }
        }
        /// Drives the same bounded machine without yielding; work_used is the
        /// final advance's count, while total_work covers the complete lifetime.
        pub fn run(self: *Self) Progress {
            while (true) {
                const p = self.advance(std.math.maxInt(u32));
                if (p.outcome != null) return p;
            }
        }
        /// Transfer completed output exactly once. Failed operations never
        /// publish a half-built graph. NotReady leaves an active session intact.
        pub fn takeResult(self: *Self) TakeError!Result {
            if (self.taken) return error.AlreadyTaken;
            const outcome = self.outcome orelse return error.NotReady;
            switch (outcome) {
                .failure => |err| return err,
                .success => {},
            }
            const result: Result = if (attributes) .{
                .graph = self.graph,
                .edges = self.stored.items,
                .storage = self.stored.allocatedSlice(),
                .allocator = self.graph.allocator,
                .peak_bytes = self.memory.peak,
                .folded = self.maps,
            } else .{
                .edges = self.stored.items,
                .storage = self.stored.allocatedSlice(),
                .allocator = self.graph.allocator,
                .peak_bytes = self.memory.peak,
            };
            self.target = @intCast(self.stored.items.len); // Stable progress after transfer.
            self.stored = .empty;
            if (attributes) self.maps = .{ .limit = 0 };
            self.taken = true;
            return result;
        }
        fn hash(edge: t.Edge) u64 {
            return edges.pairHash(edge.operator, edges.canonical(edge));
        }
        inline fn successor(self: *Self, comptime single: bool, next: Phase) Phase {
            if (single) {
                self.phase = next;
                return .yielded;
            }
            return next;
        }
        fn startSet(self: *Self, key: u32, attribute: u32, after: Phase) void {
            self.set_key = key;
            self.set_attribute = attribute;
            self.set_cursor = self.maps.roots.items[self.target];
            self.set_depth = 0;
            self.set_after = after;
        }
    };
}

/// Collision-safe comparison to the two ASCII port keys. Trusted identifier
/// spelling, including HTML operands, empty operands and arbitrarily long glue.
/// A step inspects one code unit; no complete-name decoding hides in a credit.
fn AsciiName(comptime caps: encoding.Capabilities) type {
    return struct {
        raw: []const u8 = &.{},
        actual: encoding.Actual = .utf8,
        offset: u32 = 0,
        matched: u32 = 0,
        state: enum { initial, bare, quote, html, gap, escape, cr, slash, line, block, star } = .initial,
        fn step(self: *@This(), wanted: []const u8) ?bool {
            if (self.offset == self.raw.len) return self.matched == wanted.len;
            switch (self.actual) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    const E = encoding.Reader(actual);
                    const unit = E.unit(self.raw, self.offset);
                    self.offset += E.width;
                    if (self.state == .cr) {
                        self.state = .quote;
                        if (unit == '\n') return null;
                    }
                    switch (self.state) {
                        .initial => switch (unit) {
                            '"' => {
                                self.state = .quote;
                                return null;
                            },
                            '<' => {
                                self.state = .html;
                                return null;
                            },
                            else => self.state = .bare,
                        },
                        .bare => {},
                        .quote => switch (unit) {
                            '"' => {
                                self.state = .gap;
                                return null;
                            },
                            '\\' => {
                                self.state = .escape;
                                return null;
                            },
                            else => {},
                        },
                        .html => if (unit == '>') {
                            self.state = .gap;
                            return null;
                        },
                        .escape => {
                            self.state = .quote;
                            if (unit == '\r') {
                                self.state = .cr;
                                return null;
                            }
                            if (unit == '\n') return null;
                            return false;
                        },
                        .gap => {
                            switch (unit) {
                                '"' => self.state = .quote,
                                '<' => self.state = .html,
                                '/' => self.state = .slash,
                                '#' => self.state = .line,
                                else => {},
                            }
                            return null;
                        },
                        .slash => {
                            self.state = if (unit == '/') .line else .block;
                            return null;
                        },
                        .line => {
                            if (unit == '\r' or unit == '\n') self.state = .gap;
                            return null;
                        },
                        .block => {
                            if (unit == '*') self.state = .star;
                            return null;
                        },
                        .star => {
                            self.state = if (unit == '/') .gap else if (unit == '*') .star else .block;
                            return null;
                        },
                        .cr => unreachable,
                    }
                    if (self.matched == wanted.len or unit != wanted[self.matched]) return false;
                    self.matched += 1;
                    return null;
                } else unreachable,
            }
        }
    };
}
