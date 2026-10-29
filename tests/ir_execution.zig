//! Direct lowering and resumable lowering share execution policy semantics.
const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const Dot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
const Plain = dot.ir.Lowering(.{});
const source = "digraph {node[color=red];a->subgraph s {b;c};subgraph s{d};a[label=\"long logical value\"];a:p->b:q}";

const Counter = struct {
    polls: u64 = 0,
    stop_at: u64 = std.math.maxInt(u64),
    fn requested(raw: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.polls += 1;
        return self.polls >= self.stop_at;
    }
    fn hook(self: *Counter) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

const Memory = struct {
    retained: []align(16) u8,
    scratch: []align(16) u8,
    bound: Plain.LoweringMemory,
    fn init(comptime partial: bool, doc: *const dot.Document) !Memory {
        const bounds = if (partial) try Plain.partialLoweringBounds(doc.capacities(), .{}) else try Plain.loweringBounds(doc.capacities(), .{});
        const layout = try Plain.loweringLayout(bounds.graph, bounds.scratch);
        const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
        errdefer a.free(retained);
        const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
        errdefer a.free(scratch);
        return .{ .retained = retained, .scratch = scratch, .bound = try layout.bind(retained, scratch) };
    }
    fn deinit(self: Memory) void {
        a.free(self.retained);
        a.free(self.scratch);
    }
};

fn compare(comptime partial: bool, expected: anytype, actual: anytype) !void {
    const left = if (partial) expected._data else expected;
    const right = if (partial) actual._data else actual;
    inline for (.{ "nodes", "scopes", "connections", "attributes", "mentions", "occurrences", "posting_offsets", "posting_positions" }) |field|
        try eq(@field(left, field), @field(right, field));
    try eq(left.attribute_data.keys.items, right.attribute_data.keys.items);
    try eq(left.attribute_data.cells.items, right.attribute_data.cells.items);
    if (partial) try eq(expected._coverage.entries.items, actual._coverage.entries.items);
}

test "direct lowering follows compile-time and runtime execution settings for both storage paths" {
    inline for (.{ false, true }) |partial| {
        var parsed = Dot.parseAndValidate(a, if (partial) source[0 .. source.len - 1] else source, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        const interpretation = Dot.interpretation(doc, .{});
        const memory = try Memory.init(partial, doc);
        defer memory.deinit();
        var expected = if (partial) try Plain.lowerPartial(a, doc, .{ .interpretation = interpretation }) else try Plain.lowerComplete(a, doc, .{ .interpretation = interpretation });
        defer expected.deinit();
        inline for (.{ false, true }) |runtime| {
            inline for (.{ false, true }) |metered| {
                inline for (.{ false, true }) |cancellable| {
                    inline for (.{ 1, 7, 64 }) |interval| {
                        const policy: dot.ir.Policy = .{ .execution = .{ .metering = metered, .cancellation = cancellable, .cancellation_interval = interval } };
                        // Runtime overrides deliberately reverse both baseline switches.
                        const IR = dot.ir.Lowering(.{ .runtime_policy = runtime, .policy = if (runtime) .{ .execution = .{ .metering = !metered, .cancellation = !cancellable } } else policy });
                        var counter: Counter = .{ .stop_at = if (cancellable) std.math.maxInt(u64) else 1 };
                        const Hook = if (runtime or cancellable) ?dot.ir.Cancellation else void;
                        const opts = .{
                            .interpretation = interpretation,
                            .cancellation = if (Hook == void) {} else @as(Hook, counter.hook()),
                        };
                        const options = if (runtime) .{ .interpretation = interpretation, .cancellation = opts.cancellation, .policy = policy } else opts;
                        var direct = if (partial) try IR.lowerPartial(a, doc, options) else try IR.lowerComplete(a, doc, options);
                        defer direct.deinit();
                        try compare(partial, expected, direct);
                        const direct_polls = counter.polls;
                        counter.polls = 0;
                        var session = if (partial) try IR.partialLoweringSession(a, doc, options) else try IR.loweringSession(a, doc, options);
                        defer session.deinit();
                        try eq(dot.ir.LoweringOutcome.success, session.run().outcome.?);
                        var resumed = try session.takeResult();
                        defer resumed.deinit();
                        try compare(partial, expected, resumed);
                        try eq(direct_polls, counter.polls);
                        if (!cancellable) try eq(@as(u64, 0), counter.polls);

                        counter.polls = 0;
                        const pending = if (partial) IR.lowerPartialIn(doc, memory.bound, options) else IR.lowerCompleteIn(doc, memory.bound, options);
                        var fixed = if (runtime) try pending else pending;
                        defer if (fixed.graph) |*graph| graph.deinit();
                        try eq(dot.ir.LoweringOutcome.success, fixed.outcome);
                        try compare(partial, expected, fixed.graph.?);
                        const fixed_polls = counter.polls;
                        // Drop the borrowed view before reusing its storage.
                        fixed.graph.?.deinit();
                        fixed.graph = null;
                        counter.polls = 0;
                        var fixed_session = if (partial) try IR.partialLoweringSessionIn(doc, memory.bound, options) else try IR.loweringSessionIn(doc, memory.bound, options);
                        defer fixed_session.deinit();
                        try eq(dot.ir.LoweringOutcome.success, fixed_session.run().outcome.?);
                        var fixed_graph = try fixed_session.takeResult();
                        defer fixed_graph.deinit();
                        try compare(partial, expected, fixed_graph);
                        try eq(fixed_polls, counter.polls);
                    }
                }
            }
        }
    }
}

test "direct metered lowering uses session work limits and preserves fixed shortfalls" {
    const IR = dot.ir.Lowering(.{ .runtime_policy = true });
    var parsed = Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    inline for (.{ false, true }) |partial| {
        const memory = try Memory.init(partial, doc);
        defer memory.deinit();
        const options = .{ .interpretation = Dot.interpretation(doc, .{}), .policy = .{ .execution = .{ .metering = true } } };
        var session = if (partial) try IR.partialLoweringSessionIn(doc, memory.bound, options) else try IR.loweringSessionIn(doc, memory.bound, options);
        defer session.deinit();
        const progress = session.run();
        try eq(dot.ir.LoweringOutcome.success, progress.outcome.?);
        for ([_]u64{ progress.total_work - 1, progress.total_work }) |work| {
            const limited = .{ .interpretation = options.interpretation, .policy = options.policy, .limits = .{ .max_work = work } };
            var result = if (partial) try IR.lowerPartialIn(doc, memory.bound, limited) else try IR.lowerCompleteIn(doc, memory.bound, limited);
            if (work < progress.total_work) {
                try eq(error.WorkLimit, result.outcome.failure);
                try std.testing.expect(result.graph == null);
            } else {
                try eq(dot.ir.LoweringOutcome.success, result.outcome);
                result.graph.?.deinit();
            }
        }
        var counts = memory.bound.graph.capacities;
        counts.nodes = 0;
        const layout = try Plain.loweringLayout(counts, memory.bound.scratch.capacities);
        const small = try layout.bind(memory.retained, memory.scratch);
        const failed = if (partial) try IR.lowerPartialIn(doc, small, options) else try IR.lowerCompleteIn(doc, small, options);
        try eq(error.PoolExhausted, failed.outcome.failure);
        try eq(dot.ir.Resource.node_pool, failed.shortfall.?.resource);
        try std.testing.expect(failed.graph == null);
    }
}

test "direct runtime policy validation precedes hooks allocation and fixed storage writes" {
    const IR = dot.ir.Lowering(.{ .runtime_policy = true });
    var parsed = Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    var counter: Counter = .{ .stop_at = 1 };
    const options = .{ .interpretation = Dot.interpretation(doc, .{}), .cancellation = counter.hook(), .policy = .{ .execution = .{ .cancellation = true, .cancellation_interval = 0 } } };
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    inline for (.{ false, true }) |partial| {
        try std.testing.expectError(error.InvalidCancellationInterval, if (partial) IR.lowerPartial(failing.allocator(), doc, options) else IR.lowerComplete(failing.allocator(), doc, options));
        const memory = try Memory.init(partial, doc);
        defer memory.deinit();
        @memset(memory.retained, 0xa5);
        @memset(memory.scratch, 0xa5);
        try std.testing.expectError(error.InvalidCancellationInterval, if (partial) IR.lowerPartialIn(doc, memory.bound, options) else IR.lowerCompleteIn(doc, memory.bound, options));
        for (memory.retained) |byte| try eq(@as(u8, 0xa5), byte);
        for (memory.scratch) |byte| try eq(@as(u8, 0xa5), byte);
    }
    try eq(@as(u64, 0), counter.polls);
    try eq(@as(usize, 0), failing.alloc_index);
}

test "execution overrides preserve profile limits and stops never publish a graph" {
    const IR = dot.ir.Lowering(.{ .runtime_policy = true, .limits = .{ .max_nodes = 1 } });
    var parsed = Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    inline for (.{ false, true }) |partial| {
        const memory = try Memory.init(partial, doc);
        defer memory.deinit();
        inline for (.{ false, true }) |metered| {
            const options = .{ .interpretation = Dot.interpretation(doc, .{}), .policy = .{ .execution = .{ .metering = metered } } };
            try std.testing.expectError(error.NodeLimit, if (partial) IR.lowerPartial(a, doc, options) else IR.lowerComplete(a, doc, options));
            const limited = if (partial) try IR.lowerPartialIn(doc, memory.bound, options) else try IR.lowerCompleteIn(doc, memory.bound, options);
            try eq(error.NodeLimit, limited.outcome.failure);
            try std.testing.expect(limited.graph == null);
        }
        inline for (.{ 1, 7, 64 }) |interval| {
            for ([_]u64{ 1, 2, 3 }) |stop_at| {
                var counter: Counter = .{ .stop_at = stop_at };
                const options = .{ .interpretation = Dot.interpretation(doc, .{}), .limits = dot.ir.Limits{}, .cancellation = counter.hook(), .policy = .{ .execution = .{ .cancellation = true, .cancellation_interval = interval } } };
                try std.testing.expectError(error.Cancelled, if (partial) IR.lowerPartial(a, doc, options) else IR.lowerComplete(a, doc, options));
                try eq(stop_at, counter.polls);
                counter.polls = 0;
                const stopped = if (partial) try IR.lowerPartialIn(doc, memory.bound, options) else try IR.lowerCompleteIn(doc, memory.bound, options);
                try eq(error.Cancelled, stopped.outcome.failure);
                try eq(stop_at, counter.polls);
                try std.testing.expect(stopped.graph == null);
            }
        }
    }
}

fn allocationProbe(allocator: std.mem.Allocator, doc: *const dot.Document) !void {
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var result = try IR.lowerComplete(allocator, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer result.deinit();
}
test "direct session driver frees all allocations on failure" {
    var parsed = Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{&parsed.document.?});
}
