//! Shared forward expansion for streaming and owning edge results. Endpoint
//! scratch is reused; the non-strict streaming path retains no emitted edges.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const names = @import("names.zig");
const Operator = @import("../dot/syntax.zig").EdgeOperator;

const Endpoint = struct {
    singleton: ?t.NodeId = null,
    nodes: std.ArrayList(t.NodeId) = .empty,
    count: u32 = 0,

    fn len(self: Endpoint) u32 {
        return self.count;
    }
    fn at(self: Endpoint, index: u32) t.NodeId {
        return self.singleton orelse self.nodes.items[index];
    }
};

fn canonical(edge: t.Edge) [2]u32 {
    const from = @backingInt(edge.from);
    const to = @backingInt(edge.to);
    return if (edge.operator == .undirected and from > to) .{ to, from } else .{ from, to };
}
fn pairHash(operator: Operator, pair: [2]u32) u64 {
    return std.hash.Wyhash.hash(@backingInt(operator), std.mem.asBytes(&pair));
}

/// `retaining` is private specialization, not a consumer option. Materializing
/// indexes the output itself for strict deduplication; streaming keeps only
/// compact pair keys. Neither path maintains a second copy of its edge list.
pub fn Iterator(comptime Graph: type, comptime retaining: bool) type {
    return struct {
        const Self = @This();
        const Stored = if (retaining) t.Edge else [2]u32;
        graph: *const Graph,
        // Retain only expansion limits. Lowering-only settings (including
        // attribute-map limits) must not enlarge this per-edge hot state.
        max_pairs: u64,
        max_edges: u32,
        work: r.Work,
        memory: r.Memory,
        left: Endpoint = .{},
        right: Endpoint = .{},
        marks: []u32 = &.{},
        generation: u32 = 0,
        pairs: names.Table = .{},
        stored: std.ArrayList(Stored) = .empty,
        connection: u32 = 0,
        left_index: u32 = 0,
        right_index: u32 = 0,
        ready: bool = false,
        visited: u64 = 0,
        emitted: u32 = 0,
        done: bool = false,
        failure: ?r.Error = null,

        pub fn init(graph: *const Graph, options: r.Options) r.Error!Self {
            const limits = options.limits orelse graph.limits;
            return .{
                .graph = graph,
                .max_pairs = limits.max_pairs,
                .max_edges = limits.max_edges,
                .work = try r.Work.init(limits, options.cancellation),
                .memory = .{ .backing = graph.allocator, .limit = limits.max_bytes },
            };
        }

        /// Release scratch even after early exit or error. Do not copy an
        /// iterator after use; keep its graph alive, unmoved and immutable.
        pub fn deinit(self: *Self) void {
            const a = self.memory.allocator();
            self.left.nodes.deinit(a);
            self.right.nodes.deinit(a);
            a.free(self.marks);
            self.pairs.deinit(a);
            self.stored.deinit(a);
            self.* = undefined;
        }

        /// Peak requested allocation bytes, excluding the borrowed IR and
        /// allocator overhead/arena slack. Non-strict singleton streams use 0.
        pub fn peakBytes(self: *const Self) usize {
            return self.memory.peak;
        }

        /// Forward semantic order; endpoint members follow first mention.
        /// Strict pairs appear once, with their first connection/orientation.
        /// Null means exhaustion, never cancellation or a resource shortfall.
        /// Errors are terminal and repeat on later calls. Budgets accumulate
        /// across calls; this is pull iteration, not replenishable metering.
        pub fn next(self: *Self) r.Error!?t.Edge {
            if (self.failure) |err| return err;
            if (self.done) return null;
            return self.nextImpl() catch |err| {
                const failure = self.memory.failure(err);
                self.failure = failure;
                return failure;
            };
        }

        fn clearMarks(self: *Self) r.Error!void {
            for (self.marks) |*mark| {
                try self.work.spend(1);
                mark.* = 0;
            }
            self.generation = 0;
        }

        fn enumerate(self: *Self, members: t.Membership, out: *Endpoint) r.Error!void {
            out.nodes.clearRetainingCapacity();
            const handle = @backingInt(members);
            if (handle & t.node_bit != 0) {
                try self.work.spend(1);
                out.singleton = @fromBackingInt(handle & ~t.node_bit);
                out.count = 1;
                return;
            }
            out.singleton = null;
            if (self.generation == std.math.maxInt(u32)) try self.clearMarks();
            self.generation += 1;
            const a = self.memory.allocator();
            for (self.graph.bodies[self.graph.bodies[handle].first .. handle + 1]) |body| {
                try self.work.spend(1);
                // Empty sets do not allocate a graph-sized marks array.
                if (body.start == body.end) continue;
                if (self.marks.len == 0) {
                    self.marks = try a.alloc(u32, self.graph.nodes.len);
                    try self.clearMarks();
                    self.generation = 1;
                }
                for (self.graph.mentions[body.start..body.end]) |mention| {
                    try self.work.spend(1);
                    const id = @backingInt(mention.node);
                    if (self.marks[id] == self.generation) continue;
                    self.marks[id] = self.generation;
                    try out.nodes.append(a, mention.node);
                }
            }
            out.count = @intCast(out.nodes.items.len);
        }

        fn storedPair(value: Stored) [2]u32 {
            return if (retaining) canonical(value) else value;
        }

        // Keep the shared engine inside its error-state wrapper. Outlining it
        // adds another call on every streamed edge (especially in ReleaseSafe).
        inline fn nextImpl(self: *Self) r.Error!?t.Edge {
            while (true) {
                if (!self.ready) {
                    try self.work.spend(0); // Poll even at empty input/end.
                    if (self.connection >= self.graph.connections.len) {
                        self.done = true;
                        return null;
                    }
                    const connection = self.graph.connections[self.connection];
                    try self.enumerate(connection.left.members, &self.left);
                    try self.enumerate(connection.right.members, &self.right);
                    if (retaining) {
                        // Owning output is all-or-error: reject an excessive
                        // product before allocating it. Streaming can consume
                        // just a prefix; it charges each visited pair instead.
                        const product = std.math.mul(u64, self.left.len(), self.right.len()) catch return error.PairLimit;
                        if (product > self.max_pairs - self.visited) return error.PairLimit;
                        self.visited += product;
                    }
                    if (self.left.len() == 0 or self.right.len() == 0) {
                        self.connection += 1;
                        continue;
                    }
                    self.left_index = 0;
                    self.right_index = 0;
                    self.ready = true;
                }
                try self.work.spend(1);
                if (!retaining) {
                    if (self.visited >= self.max_pairs) return error.PairLimit;
                    self.visited += 1;
                }
                const edge: t.Edge = .{
                    .from = self.left.at(self.left_index),
                    .to = self.right.at(self.right_index),
                    .operator = self.graph.connections[self.connection].effective_operator,
                    .first_connection = @fromBackingInt(self.connection),
                };
                self.right_index += 1;
                if (self.right_index == self.right.len()) {
                    self.right_index = 0;
                    self.left_index += 1;
                    if (self.left_index == self.left.len()) {
                        self.ready = false;
                        self.connection += 1;
                    }
                }
                const a = self.memory.allocator();
                const key = canonical(edge);
                if (self.graph.strict) {
                    const hash = pairHash(edge.operator, key);
                    if (self.pairs.slots.len != 0) {
                        var at: usize = @intCast(hash & (self.pairs.slots.len - 1));
                        var found = false;
                        while (self.pairs.slots[at] != names.empty) : (at = (at + 1) & (self.pairs.slots.len - 1)) {
                            try self.work.spend(1);
                            if (std.meta.eql(storedPair(self.stored.items[self.pairs.slots[at]]), key)) {
                                found = true;
                                break;
                            }
                        }
                        if (found) continue;
                    }
                    if (self.emitted >= self.max_edges) return error.EdgeLimit;
                    const Owner = struct {
                        items: []const Stored,
                        operator: Operator,
                        pub fn hashFor(owner: @This(), id: u32) u64 {
                            return pairHash(owner.operator, storedPair(owner.items[id]));
                        }
                    };
                    // Lowering admits strict concrete graphs with one effective
                    // operator only. Keys therefore need no per-pair kind tag.
                    try self.pairs.prepare(a, &self.work, Owner{ .items = self.stored.items, .operator = edge.operator });
                    try self.pairs.insert(hash, try r.index(self.stored.items.len), &self.work);
                } else if (self.emitted >= self.max_edges) return error.EdgeLimit;
                if (retaining) {
                    try self.stored.append(a, edge);
                } else if (self.graph.strict) {
                    try self.stored.append(a, key);
                }
                self.emitted += 1;
                // The owning specialization drains in this call: no per-edge
                // public-call/error-state bookkeeping or returned Edge copy.
                if (!retaining) return edge;
            }
        }
    };
}

pub fn materialize(comptime Graph: type, graph: *const Graph, options: r.Options) r.Error!t.Materialized {
    var iterator = try Iterator(Graph, true).init(graph, options);
    defer iterator.deinit();
    _ = try iterator.next();
    const result: t.Materialized = .{
        .edges = iterator.stored.items,
        .storage = iterator.stored.allocatedSlice(),
        .allocator = graph.allocator,
        .peak_bytes = iterator.peakBytes(),
    };
    iterator.stored = .empty; // Transfer ownership, not the scoped allocator.
    return result;
}
