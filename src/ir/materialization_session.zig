//! Bounded expansion for owning materialization and pull streaming. Compile-time
//! storage selection keeps non-strict streaming free of an output edge array.
//! The direct drivers remain specialized for throughput.
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
const scratch = @import("query_storage.zig");

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
    return Engine(Graph, caps, attributes, false, null, false);
}

/// Internal record result; public streaming wraps the record in the owning
/// graph's complete/partial view without a second traversal or a queue.
pub const StreamProgress = struct {
    work_used: u32,
    total_work: u64,
    pairs_visited: u64,
    edges_emitted: u32,
    edge: ?t.Edge,
    outcome: ?Outcome,
};
pub fn Streaming(comptime Graph: type, comptime caps: encoding.Capabilities, comptime fixed: ?@import("execution_policy.zig").Effective) type {
    return Engine(Graph, caps, false, true, fixed, false);
}
pub fn FixedStreaming(comptime Graph: type, comptime caps: encoding.Capabilities, comptime fixed: ?@import("execution_policy.zig").Effective) type {
    return Engine(Graph, caps, false, true, fixed, true);
}

fn Engine(comptime Graph: type, comptime caps: encoding.Capabilities, comptime attributes: bool, comptime streaming: bool, comptime fixed: ?@import("execution_policy.zig").Effective, comptime fixed_storage: bool) type {
    const Stored = if (streaming) [2]u32 else t.Edge;
    const StepProgress = if (streaming) StreamProgress else Progress;
    const has_cancellation = !streaming or fixed == null or fixed.?.cancellation;
    const Polling = @import("parser_support").execution.CancellationPolling(streaming and has_cancellation, if (fixed) |v| v.cancellation_interval else null);
    return struct {
        const Self = @This();
        pub const Result = if (streaming) void else if (attributes) Graph.Materialized else t.MaterializedTopology;
        pub const SessionProgress = StepProgress;
        const Endpoint = struct {
            // none is never an admitted node ID. These two u32s occupy the
            // old optional-ID slot: cache cardinality without growing scratch.
            singleton: u32 = none,
            count: u32 = 0,
            nodes: std.ArrayList(t.NodeId) = .empty,
            growth: if (fixed_storage) void else Growth(t.NodeId) = if (fixed_storage) {} else .{},
            fn len(self: *const Endpoint) u32 {
                return self.count;
            }
            fn at(self: *const Endpoint, index: u32) t.NodeId {
                return if (self.singleton != none) @fromBackingInt(self.singleton) else self.nodes.items[index];
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
        cancellation: if (has_cancellation) ?r.Cancellation else void,
        memory: if (fixed_storage) scratch.EdgeState else r.Memory,
        total_work: u64 = 0,
        outcome: ?Outcome = null,
        // Keep owning sessions' field count/order unchanged. Even void fields
        // can change Zig's automatic layout and Small's outlined hot code.
        // Streaming reuses this ownership-state slot for its delivery state.
        taken: if (streaming) struct {
            interval: if (has_cancellation) u32 else void = if (has_cancellation) 1 else {},
            polling: Polling = .{},
            emitted: u32 = 0,
            ready_edge: ?t.Edge = null,
        } else bool = if (streaming) .{} else false,
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
        stored: std.ArrayList(Stored) = .empty,
        edge_growth: if (fixed_storage) void else Growth(Stored) = if (fixed_storage) {} else .{},
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
            if (has_cancellation) if (options.cancellation) |c| if (c.requested()) return error.Cancelled;
            return .{
                .graph = graph,
                .limits = limits,
                .cancellation = if (has_cancellation) options.cancellation else {},
                .memory = .{ .backing = graph.allocator, .limit = limits.max_bytes },
                .phase = if (attributes and graph.has_ports) .port_catalog else .connection,
                .maps = if (attributes) .{ .limit = limits.max_attribute_states } else {},
            };
        }
        pub fn deinit(self: *Self) void {
            if (fixed_storage) {
                self.* = undefined;
                return;
            }
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
        pub fn initIn(graph: *const Graph, memory: scratch.EdgeScratch, options: r.Options) r.Error!Self {
            const limits = options.limits orelse graph.limits;
            if (has_cancellation) if (options.cancellation) |c| if (c.requested()) return error.Cancelled;
            const bound = try scratch.EdgeState.init(memory, graph, limits);
            return .{ .graph = graph, .limits = limits, .cancellation = if (has_cancellation) options.cancellation else {}, .memory = bound, .stored = .initBuffer(bound.pairs), .phase = .connection, .maps = {} };
        }
        pub fn shortfall(self: *const Self) ?@import("fixed_storage.zig").StorageShortfall {
            if (!fixed_storage) @compileError("shortfall requires fixed scratch");
            return self.memory.shortfall;
        }
        pub fn scratchPeak(self: *const Self) scratch.EdgeScratchCapacities {
            if (!fixed_storage) @compileError("scratchPeak requires fixed scratch");
            return self.memory.used;
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome == null) self.outcome = .{ .failure = error.Cancelled };
        }
        inline fn progress(self: *const Self, used: u32) StepProgress {
            if (streaming) return .{ .work_used = used, .total_work = self.total_work, .pairs_visited = self.visited, .edges_emitted = self.taken.emitted, .edge = self.taken.ready_edge, .outcome = self.outcome };
            return .{ .work_used = used, .total_work = self.total_work, .pairs_visited = self.visited, .edges_created = if (self.taken) self.target else @intCast(self.stored.items.len), .outcome = self.outcome };
        }
        inline fn poll(self: *Self) bool {
            return @import("execution_policy.zig").pollSession(self, has_cancellation);
        }
        /// One credit is one bounded state transition: a record/probe/AVL node,
        /// a source code unit, or <=64 bytes of buffer copying/initialization.
        /// Allocator callbacks are external, not wall-time bounded. Zero polls
        /// cancellation but does no semantic work. Every stop is latched.
        /// Keep this wrapper small/inlined: copying Progress through another
        /// call frame dominates budget-one resumes, particularly in Small.
        pub inline fn advance(self: *Self, budget: u32) StepProgress {
            if (streaming) self.taken.ready_edge = null;
            if (self.outcome != null or !self.poll()) return self.progress(0);
            if (streaming and has_cancellation) {
                self.taken.polling = .{};
                _ = self.taken.polling.due(self.taken.interval); // Entry poll covers the first credit.
            }
            const before = self.total_work;
            if (streaming and budget >= 3) {
                const no_hook = if (has_cancellation) self.cancellation == null else true;
                if (no_hook and self.streamReady(budget)) return self.progress(@intCast(self.total_work - before));
            }
            // Select once per resume, not at every tiny transition. Owning
            // sessions poll before each credit; streaming uses its interval.
            // Inline just the one-credit streaming dispatch. Inlining the
            // larger multi-credit drivers duplicates cold phases and hurts Small.
            const result = if (budget == 1)
                @call(if (streaming) .always_inline else .auto, drive, .{ self, false, true, 1 })
            else if (!has_cancellation)
                self.drive(false, false, budget)
            else if (self.cancellation == null)
                self.drive(false, false, budget)
            else
                self.drive(true, false, budget);
            result catch |err| {
                self.outcome = .{ .failure = self.memory.failure(err) };
            };
            return self.progress(@intCast(self.total_work - before));
        }
        /// Fuse only a complete, allocation-free, non-strict edge path. Every
        /// original transition is still charged. No hook may observe the
        /// intermediate states, and a grant/limit ending inside the path falls
        /// back to drive(), so budget-one and failure prefixes stay identical.
        inline fn streamReady(self: *Self, budget: u32) bool {
            if (self.graph.strict) return false;
            var connection = self.connection;
            var cost: u32 = 3; // pair, prepare, append_edge
            const prepare = switch (self.phase) {
                .connection => blk: {
                    cost = 9; // connection + two endpoint/done pairs + product
                    break :blk true;
                },
                .pair => blk: {
                    if (self.left_index != self.endpoints[0].len()) break :blk false;
                    connection += 1;
                    cost = 10; // also retire the preceding exhausted pair
                    break :blk true;
                },
                else => return false,
            };
            if (budget < cost or self.limits.max_work - self.total_work < cost or
                self.visited >= self.limits.max_pairs or self.taken.emitted >= self.limits.max_edges) return false;
            if (prepare) {
                if (connection >= self.graph.connections.len) return false;
                const source = self.graph.connections[connection];
                const left = @backingInt(source.left.members);
                const right = @backingInt(source.right.members);
                if (left & right & t.node_bit == 0) {
                    // Fast benefits from fusing preparation into the caller.
                    // Forcing the same inlining in Small enlarges the mixed-
                    // budget caller and slows its one-credit path.
                    return @call(if (@import("builtin").mode == .fast) .always_inline else .auto, streamSetEdge, .{ self, connection, budget, cost });
                }
                self.connection = connection;
                inline for (.{ left, right }, 0..) |id, i| {
                    self.endpoints[i].singleton = id & ~t.node_bit;
                    self.endpoints[i].count = 1;
                    self.endpoints[i].nodes.items.len = 0;
                }
                self.side = 1;
                self.left_index = 0;
                self.right_index = 0;
            }
            self.deliverStreamEdge(connection, cost);
            return true;
        }
        inline fn deliverStreamEdge(self: *Self, connection: u32, cost: u32) void {
            self.visited += 1;
            self.candidate = .{ .from = self.endpoints[0].at(self.left_index), .to = self.endpoints[1].at(self.right_index), .operator = self.graph.connections[connection].effective_operator, .first_connection = @fromBackingInt(connection) };
            self.right_index += 1;
            if (self.right_index == self.endpoints[1].len()) {
                self.right_index = 0;
                self.left_index += 1;
            }
            self.taken.emitted += 1;
            self.taken.ready_edge = self.candidate;
            self.phase = .pair;
            self.total_work += cost;
        }
        /// Extend ready delivery to warm, single-body sets. Inspect only two
        /// body headers before committing: their written sizes bound both the
        /// required capacity and credits, even if every mention is unique.
        /// Reopened bodies, empty sets, growth and mark-generation rollover
        /// keep the stepped path. This never pre-scans a set or allocates.
        fn streamSetEdge(self: *Self, connection: u32, budget: u32, base_cost: u32) bool {
            // Fixed endpoints share a buffer; use the metered collector rather
            // than this growable-only capacity preflight. Singleton/pair fusion
            // remains available and charges exactly the same transitions.
            if (fixed_storage) return false;
            if (self.marks.len == 0 or self.generation > std.math.maxInt(u32) - 2) return false;
            const source = self.graph.connections[connection];
            const handles = [2]u32{ @backingInt(source.left.members), @backingInt(source.right.members) };
            var bodies: [2]?t.Body = .{ null, null };
            var upper: u64 = base_cost;
            inline for (handles, 0..) |handle, i| {
                if (handle & t.node_bit == 0) {
                    const body = self.graph.bodies[handle];
                    const count = body.end - body.start;
                    const out = &self.endpoints[i];
                    if (body.first != handle or count == 0 or out.growth.pending.len != 0 or count > out.nodes.capacity) return false;
                    bodies[i] = body;
                    // In addition to endpoint/done: body, mention/append per
                    // node, exhausted mention, exhausted body. Repeats do not
                    // consume append credits; compute the actual cost below.
                    upper += @as(u64, count) * 2 + 3;
                }
            }
            if (upper > budget or upper > self.limits.max_work - self.total_work) return false;
            var cost = base_cost;
            inline for (handles, 0..) |handle, i| {
                const out = &self.endpoints[i];
                out.nodes.items.len = 0;
                if (bodies[i]) |body| {
                    out.singleton = none;
                    self.generation += 1;
                    var end: u32 = 0;
                    const nodes = out.nodes.allocatedSlice();
                    for (self.graph.mentions[body.start..body.end]) |mention| {
                        const id = @backingInt(mention.node);
                        if (self.marks[id] == self.generation) continue;
                        self.marks[id] = self.generation;
                        self.pending_node = mention.node;
                        nodes[end] = mention.node;
                        end += 1;
                    }
                    out.nodes.items.len = end;
                    out.count = end;
                    self.body_index = handle + 1;
                    self.body_end = handle + 1;
                    self.mention_index = body.end;
                    self.mention_end = body.end;
                    cost += body.end - body.start + end + 3;
                } else {
                    out.singleton = handle & ~t.node_bit;
                    out.count = 1;
                }
            }
            self.connection = connection;
            self.side = 1;
            self.left_index = 0;
            self.right_index = 0;
            self.deliverStreamEdge(connection, cost);
            return true;
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
            const a = if (fixed_storage) undefined else self.memory.allocator();
            // The borrowed IR is immutable. Avoid reloading its kind at each
            // pair/prepare transition, but do not read it for unrelated single
            // steps (which return after exactly one phase).
            const strict = if (single) false else self.graph.strict;
            // Literal successors are direct control-flow edges, not a return to
            // a central step() dispatch. Every edge (including a self-loop)
            // still goes through the same credit/poll gate. Keep accounting
            // local without cancellation; publish it on every exit, and before
            // callbacks when cancellation is enabled. No state or work is lost
            // on a pause, allocator failure or other terminal error.
            machine: switch (self.phase) {
                // Single-credit successors already saved their phase. Keep
                // their direct return out of the multi-credit limit epilogue.
                .yielded => if (single) return else break :machine,
                inline else => |phase| {
                    current = phase;
                    if (single) {
                        // advance already polled. One step has no intermediate
                        // poll, countdown or repeated lifetime-limit test.
                        if (used != 0) return;
                        used = 1;
                    } else {
                        if (used == grant) break :machine;
                        if (cancellable) {
                            self.phase = phase;
                            if (streaming) {
                                if (used != 0 and self.taken.polling.due(self.taken.interval) and !self.poll()) return;
                            } else if (used != 0 and !self.poll()) return;
                        }
                        used += 1;
                        if (cancellable) self.total_work = initial_work + used;
                    }
                    if (streaming and cancellable) self.taken.polling.spend(1);
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
                                    self.port_match = .{ .name = .{ .raw = self.graph.text(key.name), .actual = @import("names.zig").reader(caps, self.graph.source_info.encoding) } };
                                    continue :machine self.successor(single, .port_name);
                                }
                            };
                            self.catalog_index += 1;
                        } else unreachable,
                        .port_name => if (attributes) {
                            const name: []const u8 = if (self.port_index == 0) "tailport" else "headport";
                            if (try self.port_match.step(name)) |matches| {
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
                            if (fixed_storage) {
                                const offset = if (self.side == 0) 0 else self.endpoints[0].nodes.items.len;
                                out.nodes = .initBuffer(self.memory.members[offset..]);
                            }
                            // clearRetainingCapacity poisons the whole used slice in
                            // safety builds. No old item is readable after this reset.
                            out.nodes.items.len = 0;
                            out.count = 0;
                            if (handle & t.node_bit != 0) {
                                out.singleton = handle & ~t.node_bit;
                                out.count = 1;
                                continue :machine self.successor(single, .endpoint_done);
                            } else {
                                out.singleton = none;
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
                                if (fixed_storage) {
                                    if (self.memory.members.len == 0) try self.memory.needMembers(1);
                                    self.marks = self.memory.marks;
                                } else self.marks = try storage.allocate(u32, a, self.graph.nodes.len);
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
                            if (fixed_storage) {
                                const offset = if (self.side == 0) 0 else self.endpoints[0].nodes.items.len;
                                try self.memory.needMembers(offset + out.nodes.items.len + 1);
                            } else if (!try out.growth.step(&out.nodes, a)) continue :machine self.successor(single, phase);
                            out.nodes.appendAssumeCapacity(self.pending_node);
                            out.count += 1;
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
                            if (!streaming and product > self.limits.max_pairs - self.visited) return error.PairLimit;
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
                            if (streaming and self.visited >= self.limits.max_pairs) return error.PairLimit;
                            self.visited += 1;
                            self.candidate = .{ .from = self.endpoints[0].at(self.left_index), .to = self.endpoints[1].at(self.right_index), .operator = self.graph.connections[self.connection].effective_operator, .first_connection = @fromBackingInt(self.connection) };
                            self.right_index += 1;
                            if (self.right_index == self.endpoints[1].len()) {
                                self.right_index = 0;
                                self.left_index += 1;
                            }
                            if ((if (single) self.graph.strict else strict) and self.slots.len != 0) {
                                self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                continue :machine self.successor(single, .probe);
                            } else continue :machine self.successor(single, .prepare);
                        },
                        .probe => {
                            const id = self.slots[self.slot];
                            if (id == none) {
                                continue :machine self.successor(single, .prepare);
                            }
                            if (std.meta.eql(storedPair(self.stored.items[id]), edges.canonical(self.candidate))) {
                                self.target = id;
                                continue :machine self.successor(single, if (attributes) .apply else .pair);
                            } else self.slot = @intCast((@as(usize, self.slot) + 1) & (self.slots.len - 1));
                        },
                        .prepare => {
                            if ((if (streaming) self.taken.emitted else self.stored.items.len) >= self.limits.max_edges) return error.EdgeLimit;
                            if (!(if (single) self.graph.strict else strict)) {
                                continue :machine self.successor(single, .append_edge);
                            }
                            if (fixed_storage) {
                                try self.memory.needPair(self.stored.items.len + 1);
                                if (self.slots.len == 0) {
                                    self.new_slots = self.memory.slots;
                                    self.table_index = 0;
                                    continue :machine self.successor(single, .table_clear);
                                }
                                self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                continue :machine self.successor(single, .insert);
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
                                if (fixed_storage) {
                                    self.slots = self.new_slots;
                                    self.new_slots = &.{};
                                    self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                    continue :machine self.successor(single, .insert);
                                }
                                self.rehash_index = 0;
                                continue :machine self.successor(single, .rehash_scan);
                            }
                        },
                        .rehash_scan => {
                            if (self.rehash_index == self.slots.len) {
                                if (!fixed_storage) storage.release(u32, a, self.slots);
                                self.slots = self.new_slots;
                                self.new_slots = &.{};
                                self.slot = @intCast(hash(self.candidate) & (self.slots.len - 1));
                                continue :machine self.successor(single, .insert);
                            }
                            const id = self.slots[self.rehash_index];
                            self.rehash_index += 1;
                            if (id != none) {
                                self.rehash_id = id;
                                const stored_hash = if (streaming) edges.pairHash(self.candidate.operator, self.stored.items[id]) else hash(self.stored.items[id]);
                                self.slot = @intCast(stored_hash & (self.new_slots.len - 1));
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
                            if (!streaming or (if (single) self.graph.strict else strict)) {
                                if (fixed_storage) {
                                    try self.memory.needPair(self.stored.items.len + 1);
                                } else if (!try self.edge_growth.step(&self.stored, a)) continue :machine self.successor(single, phase);
                                self.target = try r.index(self.stored.items.len);
                                self.stored.appendAssumeCapacity(if (streaming) edges.canonical(self.candidate) else self.candidate);
                                if (fixed_storage) self.memory.used.strict_pairs = @intCast(self.stored.items.len);
                            }
                            if (streaming) {
                                self.taken.emitted += 1;
                                self.taken.ready_edge = self.candidate;
                                current = .pair;
                                self.phase = .pair;
                                return; // Deliver once, even when the grant has credits left.
                            }
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
            if (used == budget) return;
            // Centralize the exhausted-grant exit instead of duplicating its
            // error/poll handling at every phase. Cancellation still wins over
            // a lifetime limit; a budget pause does not add a poll.
            if (cancellable) {
                self.phase = current;
                if (used != 0 and !self.poll()) return;
            }
            return error.WorkLimit;
        }
        /// Drives the same bounded machine without yielding; work_used is the
        /// final advance's count, while total_work covers the complete lifetime.
        pub fn run(self: *Self) StepProgress {
            while (true) {
                const p = self.advance(std.math.maxInt(u32));
                if (streaming and p.edge != null) return p;
                if (p.outcome != null) return p;
            }
        }
        /// Transfer completed output exactly once. Failed operations never
        /// publish a half-built graph. NotReady leaves an active session intact.
        pub fn takeResult(self: *Self) TakeError!Result {
            if (streaming) @compileError("streaming delivers edges through progress, not an owning result");
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
        inline fn storedPair(value: Stored) [2]u32 {
            return if (streaming) value else edges.canonical(value);
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

/// Collision-safe comparison to the two ASCII port keys, reusing the session
/// logical-name reader. A step still inspects at most one code unit/scalar.
fn AsciiName(comptime caps: encoding.Capabilities) type {
    return struct {
        name: @import("lowering_primitives.zig").Name(caps) = .{},
        matched: u32 = 0,
        fn step(self: *@This(), wanted: []const u8) r.Error!?bool {
            switch (try self.name.step()) {
                .pending => return null,
                .end => return self.matched == wanted.len,
                .byte => |unit| {
                    if (self.matched == wanted.len or unit != wanted[self.matched]) return false;
                    self.matched += 1;
                    return null;
                },
            }
        }
    };
}
