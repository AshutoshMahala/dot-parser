//! Optional bounded queries over symbolic connections and membership postings.
//! No expansion, allocation, name decoding or graph mutation. The direct query
//! drivers remain independent throughput paths.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const execution = @import("execution_policy.zig");
const coverage = @import("coverage.zig");
// The bounded loop primarily amortizes Safe's repeated slice/bounds checks.
// Fast/Small measurements favor retaining the compact driver across routes.
// This selects code generation, never different work or polling semantics.
const batch_mode = @import("builtin").mode.runtimeSafety();

pub const Kind = enum { has_edge, contains };
pub fn OutcomeFor(comptime partial: bool) type {
    return union(enum) { success: if (partial) coverage.Knowledge(bool) else bool, failure: r.Error };
}

/// Shared cursor for both query kinds. A step inspects one singleton, body or
/// binary-search probe. Finish/selection transitions are constant work folded
/// into that step; no loop over bodies or postings is hidden in a credit.
pub const MembershipCursor = struct {
    members: u32,
    node: u32,
    body: u32 = 0,
    lo: u32 = 0,
    hi: u32 = 0,
    phase: enum { start, body, search } = .start,

    const Consumed = struct { used: u32, found: ?bool = null };

    // The caller grants only credits preceding the next pause, lifetime limit
    // or cancellation poll. Keep the immutable posting slice and body local
    // across probes; yielding still retains exactly the one-step cursor.
    inline fn consume(self: *MembershipCursor, graph: anytype, grant: u32) Consumed {
        std.debug.assert(grant != 0);
        if (self.members & t.node_bit != 0) return .{ .used = 1, .found = self.members & ~t.node_bit == self.node };
        return self.consumeSet(graph, grant);
    }

    inline fn beginSearch(self: *MembershipCursor, len: usize) void {
        self.lo = 0;
        self.hi = @intCast(len);
        self.phase = .search;
    }
    inline fn probe(self: *MembershipCursor, positions: []const u32, start: u32) void {
        const mid = self.lo + (self.hi - self.lo) / 2;
        if (positions[mid] < start) self.lo = mid + 1 else self.hi = mid;
    }
    inline fn finishBody(self: *MembershipCursor, positions: []const u32, end: u32) ?bool {
        if (self.lo < self.hi) return null;
        if (self.lo < positions.len and positions[self.lo] < end) return true;
        if (self.body == self.members) return false;
        self.body += 1;
        self.phase = .body;
        return null;
    }

    // One-credit resumes and interval-one polls need no batched-loop setup.
    pub inline fn step(self: *MembershipCursor, graph: anytype) ?bool {
        if (self.phase == .start) {
            if (self.members & t.node_bit != 0) return self.members & ~t.node_bit == self.node;
            self.body = graph.bodies[self.members].first;
            self.phase = .body;
        }
        const positions = graph.posting_positions[graph.posting_offsets[self.node]..graph.posting_offsets[self.node + 1]];
        const body = graph.bodies[self.body];
        if (self.phase == .body) self.beginSearch(positions.len) else self.probe(positions, body.start);
        return self.finishBody(positions, body.end);
    }

    // Keep set traversal out of the common singleton transition path.
    noinline fn consumeSet(self: *MembershipCursor, graph: anytype, grant: u32) Consumed {
        var used: u32 = 1;
        if (self.phase == .start) {
            self.body = graph.bodies[self.members].first;
            self.phase = .body;
        }
        const positions = graph.posting_positions[graph.posting_offsets[self.node]..graph.posting_offsets[self.node + 1]];
        if (positions.len == 0) {
            // An absent posting cannot match any body. Account for the same
            // body credits and leave exactly the scalar cursor at a pause.
            // Every eliminated body visit is still charged, and the grant
            // cannot cross a pause, lifetime limit or cancellation checkpoint.
            const remaining = self.members - self.body + 1;
            const count = @min(grant, remaining);
            self.lo = 0;
            self.hi = 0;
            if (count == remaining) {
                self.body = self.members;
                self.phase = .search;
                return .{ .used = count, .found = false };
            }
            self.body += count;
            self.phase = .body;
            return .{ .used = count };
        }
        var body = graph.bodies[self.body];
        const Phase = enum { body, search, finish };
        machine: switch (@as(Phase, if (self.phase == .body) .body else .search)) {
            .body => {
                self.beginSearch(positions.len);
                if (self.lo == self.hi) continue :machine .finish;
                if (used == grant) return .{ .used = used };
                used += 1;
                continue :machine .search;
            },
            .search => {
                self.probe(positions, body.start);
                if (self.lo == self.hi) continue :machine .finish;
                if (used == grant) return .{ .used = used };
                used += 1;
                continue :machine .search;
            },
            .finish => {
                if (self.finishBody(positions, body.end)) |found| return .{ .used = used, .found = found };
                if (used == grant) return .{ .used = used };
                used += 1;
                body = graph.bodies[self.body];
                continue :machine .body;
            },
        }
    }
};

pub fn Bound(comptime Graph: type, comptime kind: Kind, comptime config: anytype) type {
    const partial = @hasField(Graph, "_data");
    const Data = if (partial) @FieldType(Graph, "_data") else Graph;
    const baseline = comptime execution.resolve(.{}, config.policy);
    // A fixed interval-one profile has no polling window to batch. Keeping
    // its original driver also avoids duplicating single-step specializations.
    const batching = batch_mode and (config.runtime_policy or !baseline.cancellation or baseline.cancellation_interval != 1);
    const has_cancellation = config.runtime_policy or baseline.cancellation;
    const Hook = if (has_cancellation) ?r.Cancellation else void;
    const Polling = @import("parser_support").execution.CancellationPolling(has_cancellation, if (config.runtime_policy) null else baseline.cancellation_interval);
    return struct {
        const Self = @This();
        pub const Answer = if (partial) coverage.Knowledge(bool) else bool;
        pub const Outcome = OutcomeFor(partial);
        pub const Progress = struct {
            work_used: u32,
            total_work: u64,
            /// Only success contains an answer. Pauses and failures are never
            /// false/absent; partial success can still be unknown.
            outcome: ?Outcome,
        };
        pub const Options = execution.OptionsFor(config);
        const Stage = enum { connection, left, right, reverse_left, reverse_right };
        graph: *const Graph,
        max_work: u64,
        total_work: u64 = 0,
        outcome: ?Outcome = null,
        cancellation: Hook,
        effective: if (config.runtime_policy) execution.Effective else void,
        cursor: MembershipCursor,
        from: if (kind == .has_edge) t.NodeId else void,
        to: if (kind == .has_edge) t.NodeId else void,
        connection: if (kind == .has_edge) u32 else void = if (kind == .has_edge) 0 else {},
        stage: if (kind == .has_edge) Stage else void = if (kind == .has_edge) .connection else {},

        /// Only O(1) option/handle checks and the enabled entry poll. The graph
        /// and source must remain alive, immutable and unmoved until deinit.
        pub fn init(graph: *const Graph, first: if (kind == .has_edge) t.NodeId else t.Membership, node: t.NodeId, options: anytype) !Self {
            comptime {
                // The typed contract includes void fields for compiled-out
                // capabilities. They carry no override and must remain usable.
                if (@TypeOf(options) != Options) for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
                    if (!std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !(config.runtime_policy and std.mem.eql(u8, field, "policy")))
                        @compileError("unknown IR query session option: " ++ field);
                };
            }
            const normalized = execution.option(Options, options);
            const effective = if (config.runtime_policy) execution.resolve(baseline, normalized.policy) else baseline;
            if (config.runtime_policy) try execution.validate(effective);
            const data = if (partial) &graph._data else graph;
            if (@backingInt(node) >= data.nodes.len) return error.InvalidHandle;
            const handle = @backingInt(first);
            if (kind == .has_edge) {
                if (handle >= data.nodes.len) return error.InvalidHandle;
            } else if (handle & t.node_bit != 0) {
                if (handle & ~t.node_bit >= data.nodes.len) return error.InvalidHandle;
            } else if (handle >= data.bodies.len) return error.InvalidHandle;
            const hook = if (has_cancellation) (if (effective.cancellation) normalized.cancellation else null) else {};
            if (has_cancellation) if (hook) |c| if (c.requested()) return error.Cancelled;
            return .{
                .graph = graph,
                .max_work = (normalized.limits orelse data.limits).max_work,
                .cancellation = hook,
                .effective = if (config.runtime_policy) effective else {},
                .cursor = .{ .members = handle, .node = @backingInt(node) },
                .from = if (kind == .has_edge) first else {},
                .to = if (kind == .has_edge) node else {},
            };
        }
        inline fn borrowed(self: *const Self) *const Data {
            return if (partial) &self.graph._data else self.graph;
        }
        inline fn progress(self: *const Self, used: u32) Progress {
            return .{ .work_used = used, .total_work = self.total_work, .outcome = self.outcome };
        }
        inline fn poll(self: *Self) bool {
            if (has_cancellation) if (self.cancellation) |c| {
                if (c.requested()) self.cancel();
                return self.outcome == null;
            };
            return true;
        }
        inline fn finish(self: *Self, found: bool) void {
            if (partial) {
                // after=null is a single precomputed suffix-index lookup, not
                // a coverage scan. Match the existing direct query contract.
                if (!found) if (self.graph._coverage.uncertainty(null)) |uncertainty| {
                    self.outcome = .{ .success = .{ .unknown = .{ .uncertainty = uncertainty } } };
                    return;
                };
                self.outcome = .{ .success = .{ .known = found } };
            } else self.outcome = .{ .success = found };
        }
        inline fn member(self: *Self, members: t.Membership, node: t.NodeId, stage: Stage) void {
            self.cursor = .{ .members = @backingInt(members), .node = @backingInt(node) };
            self.stage = stage;
        }
        inline fn nextConnection(self: *Self) void {
            self.connection += 1;
            self.stage = .connection;
        }
        inline fn reverseOrNext(self: *Self, connection: t.Connection) void {
            if (connection.effective_operator == .undirected)
                self.member(connection.left.members, self.to, .reverse_left)
            else
                self.nextConnection();
        }
        inline fn transition(self: *Self, connection: t.Connection, found: bool) void {
            switch (self.stage) {
                .connection => unreachable,
                .left => if (found) self.member(connection.right.members, self.to, .right) else self.reverseOrNext(connection),
                .right => if (found) self.finish(true) else self.reverseOrNext(connection),
                .reverse_left => if (found) self.member(connection.right.members, self.from, .reverse_right) else self.nextConnection(),
                .reverse_right => if (found) self.finish(true) else self.nextConnection(),
            }
        }
        inline fn step(self: *Self) void {
            const graph = self.borrowed();
            if (kind == .contains) {
                if (self.cursor.step(graph)) |found| self.finish(found);
                return;
            }
            if (self.stage == .connection) {
                if (self.connection >= graph.connections.len) {
                    self.finish(false);
                    return;
                }
                self.member(graph.connections[self.connection].left.members, self.from, .left);
                return;
            }
            const found = self.cursor.step(graph) orelse return;
            self.transition(graph.connections[self.connection], found);
        }
        inline fn consume(self: *Self, grant: u32) u32 {
            const graph = self.borrowed();
            if (kind == .contains) {
                const result = self.cursor.consume(graph, grant);
                if (result.found) |found| self.finish(found);
                return result.used;
            }
            var selected: u32 = 0;
            if (self.stage == .connection) {
                if (self.connection >= graph.connections.len) {
                    self.finish(false);
                    return 1;
                }
                self.member(graph.connections[self.connection].left.members, self.from, .left);
                if (grant == 1) return 1;
                selected = 1;
            }
            const result = self.cursor.consume(graph, grant - selected);
            const used = selected + result.used;
            const found = result.found orelse return used;
            self.transition(graph.connections[self.connection], found);
            return used;
        }
        pub inline fn advance(self: *Self, budget: u32) (if (config.runtime_policy) execution.Error!Progress else Progress) {
            if (config.runtime_policy) {
                if (!self.effective.metering) return error.MeteringDisabled;
            } else if (!baseline.metering) @compileError("metering is disabled; use run()");
            return self.advanceCore(budget);
        }
        inline fn advanceCore(self: *Self, budget: u32) Progress {
            if (self.outcome != null or !self.poll()) return self.progress(0);
            if (!has_cancellation) return self.dispatch(false, budget);
            return if (self.cancellation == null) self.dispatch(false, budget) else self.dispatch(true, budget);
        }
        inline fn dispatch(self: *Self, comptime cancellable: bool, budget: u32) Progress {
            if (batching and budget == 1) {
                return @call(.always_inline, drive, .{ self, cancellable, true, 1 });
            }
            // Without reopened scopes, connection selection dominates the
            // measured existence workloads. Prefer the compact loop there;
            // standalone membership searches can still batch their probes.
            // This only selects an equivalent driver, never a query answer.
            if (batching and !cancellable and kind == .has_edge and self.borrowed().bodies.len == self.borrowed().scopes.len) {
                if (config.runtime_policy) return @call(.never_inline, drive, .{ self, false, true, budget });
                return self.drive(cancellable, true, budget);
            }
            // Keep the resolved runtime-policy loop local: inlining its state
            // alongside fixed-policy specializations causes caller spills.
            if (batching and config.runtime_policy and !cancellable)
                return @call(.never_inline, drive, .{ self, false, false, budget });
            return self.drive(cancellable, false, budget);
        }
        fn drive(self: *Self, comptime cancellable: bool, comptime single: bool, budget: u32) Progress {
            var polling: Polling = .{};
            const interval = if (config.runtime_policy) self.effective.cancellation_interval else baseline.cancellation_interval;
            if (cancellable) _ = polling.due(interval); // Entry poll covers first credit.
            var used: u32 = 0;
            const before = self.total_work;
            const grant: u32 = @intCast(@min(budget, self.max_work - before));
            while (used < grant and self.outcome == null) {
                if (cancellable and used != 0 and polling.due(interval) and !self.poll()) break;
                if (!batching or single or (cancellable and interval == 1)) {
                    used += 1;
                    if (cancellable) {
                        self.total_work = before + used;
                        polling.spend(1);
                    }
                    self.step();
                } else {
                    const allowance = if (cancellable) @min(grant - used, polling.allowance()) else grant - used;
                    const consumed = self.consume(allowance);
                    used += consumed;
                    if (cancellable) {
                        self.total_work = before + used;
                        polling.spend(consumed);
                    }
                }
            }
            self.total_work = before + used;
            if (self.outcome == null and used < budget and used == grant) {
                // Poll at a lifetime stop as well as at interval boundaries,
                // matching lowering/edge sessions. A budget pause adds no poll.
                if (used == 0 or !cancellable or self.poll()) self.outcome = .{ .failure = error.WorkLimit };
            }
            return self.progress(used);
        }
        pub fn run(self: *Self) Progress {
            while (true) {
                const p = self.advanceCore(std.math.maxInt(u32));
                if (p.outcome != null) return p;
            }
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome == null) self.outcome = .{ .failure = error.Cancelled };
        }
        pub fn peakBytes(_: *const Self) usize {
            return 0; // Only inline cursor state; never allocates.
        }
        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }
    };
}
