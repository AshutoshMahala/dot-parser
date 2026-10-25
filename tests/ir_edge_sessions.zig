const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const equal = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

// Make actual copy credits deterministic across partition/cancellation tests.
const NoResize = struct {
    backing: std.mem.Allocator,
    fn allocator(self: *NoResize) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(n, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(bytes, alignment, ra);
    }
};

fn check(original: anytype) !void {
    var copy = original.*; // Borrow owning buffers; never deinit this copy.
    const partial = @hasField(@TypeOf(copy), "_data");
    var memory: NoResize = .{ .backing = a };
    if (partial) copy._data.allocator = memory.allocator() else copy.allocator = memory.allocator();
    const graph = &copy;
    var total: ?u64 = null;
    for ([_]u32{ 0, 1, 2, 7, 64, 4096, std.math.maxInt(u32) }) |budget| {
        var direct = try graph.edgeIterator(.{});
        defer direct.deinit();
        var session = try IR.edgeSession(graph, .{});
        defer session.deinit();
        try equal(@as(usize, 0), session.peakBytes());
        var consumed: u64 = 0;
        var count: u32 = 0;
        var turn: usize = 0;
        while (true) {
            const zero = session.advance(0);
            try equal(@as(u32, 0), zero.work_used);
            try equal(consumed, zero.total_work);
            try expect(zero.edge == null and zero.outcome == null);
            const grant = if (budget != 0) budget else ([_]u32{ 1, 7, 64, 2, 4096 })[turn % 5];
            turn += 1;
            const p = session.advance(grant);
            try expect(p.work_used > 0 and p.work_used <= grant);
            consumed += p.work_used;
            try equal(consumed, p.total_work);
            if (p.edge) |edge| {
                count += 1;
                try expect(p.outcome == null);
                const expected = (try direct.next()).?;
                try equal(expected.edge, edge.edge);
                try equal(try expected.attribute("color"), try edge.attribute("color"));
                try equal(try expected.tailPort(), try edge.tailPort());
                if (partial) try equal(expected.firstConnection(), edge.firstConnection());
            }
            try equal(count, p.edges_emitted);
            if (p.outcome) |outcome| {
                try equal(dot.ir.EdgeStreamingOutcome.success, outcome);
                break;
            }
        }
        try expect(try direct.next() == null);
        if (total) |n| try equal(n, consumed) else total = consumed;
        session.cancel();
        const terminal = session.advance(4096);
        try equal(@as(u32, 0), terminal.work_used);
        try expect(terminal.edge == null);
        try equal(dot.ir.EdgeStreamingOutcome.success, terminal.outcome.?);
    }
}

test "edge sessions match streaming order views and partial qualifications at every budget" {
    for ([_][]const u8{
        "digraph {}",
        "digraph {a->b;a->b;a:p->c:q[color=red]}",
        "digraph {a->{b c b};{}->a;a->b;{a b}->{};{a b a}->{c d c};d->a}",
        "strict graph {edge[color=red];{a b}--{a b}[color=blue];b:r--a:s[color=green];a--c}",
        "strict digraph {subgraph s{a}->x[color=red];subgraph s{b}->x;subgraph s{a}->x[color=blue]}",
        "digraph {edge[color=red];a->{edge[color=blue];b->c}->d;}",
    }) |source| {
        var result = try dot.ir.parse(a, source, .{});
        defer result.deinit();
        try check(result.ir().?);
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        try check(partial.ir().?);
    }
    for ([_][]const u8{
        "strict graph {a:p--b:q[color=red];broken->;b:r--a:s[color=blue];c--d}",
        "digraph {a->b;subgraph s{c->d;e->",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        try check(result.ir().?);
    }
}

test "streaming has no non-strict output array and consumes over-budget product prefixes" {
    var result = try dot.ir.parse(a, "digraph {{a b c}->{d e f}}", .{});
    defer result.deinit();
    var session = try IR.edgeSession(result.ir().?, .{ .limits = .{ .max_pairs = 2 } });
    const first = session.run().edge.?;
    try equal(@as(u32, 2), session.run().edges_emitted);
    const stopped = session.run();
    try equal(error.PairLimit, stopped.outcome.?.failure);
    try equal(@as(u64, 2), stopped.pairs_visited);
    try expect(stopped.edge == null);
    try equal(@as(usize, 0), session.core.stored.capacity);
    session.deinit();
    // Edge views borrow IR, not session scratch, and survive a later failure.
    try equal(first.edge.from, first.from().id);
    try expect((try first.attribute("missing")) == null);

    var singleton = try dot.ir.parse(a, "digraph {a->b;a->b}", .{});
    defer singleton.deinit();
    var no_memory = try IR.edgeSession(singleton.ir().?, .{ .limits = .{ .max_bytes = 0 } });
    defer no_memory.deinit();
    try expect(no_memory.run().edge != null);
    try expect(no_memory.run().edge != null);
    try equal(dot.ir.EdgeStreamingOutcome.success, no_memory.run().outcome.?);
    try equal(@as(usize, 0), no_memory.peakBytes());
}

const Stop = struct {
    calls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    work: ?*const u64 = null,
    previous: u64 = 0,
    max_gap: u64 = 0,
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.work) |work| {
            self.max_gap = @max(self.max_gap, work.* - self.previous);
            self.previous = work.*;
        }
        return self.calls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "edge sessions poll at every resume and bounded interval and latch stops" {
    const C = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var result = try dot.ir.parse(a, "strict graph {{a b}--{a b};b--a;a--c}", .{});
    defer result.deinit();
    var stop: Stop = .{};
    var session = try C.edgeSession(result.ir().?, .{ .cancellation = stop.token() });
    while (session.run().outcome == null) {}
    session.deinit();
    const all_polls = stop.calls;
    for (0..all_polls) |i| {
        stop = .{ .at = i + 1 };
        if (i == 0) {
            try std.testing.expectError(error.Cancelled, C.edgeSession(result.ir().?, .{ .cancellation = stop.token() }));
            continue;
        }
        var current = try C.edgeSession(result.ir().?, .{ .cancellation = stop.token() });
        defer current.deinit();
        while (true) {
            const p = current.run();
            if (p.outcome) |outcome| {
                try equal(error.Cancelled, outcome.failure);
                try expect(p.edge == null);
                break;
            }
        }
        const calls = stop.calls;
        try equal(error.Cancelled, current.advance(0).outcome.?.failure);
        try equal(calls, stop.calls);
    }
    inline for (.{ 1, 4, 64 }) |interval| {
        const P = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } });
        stop = .{};
        var s = try P.edgeSession(result.ir().?, .{ .cancellation = stop.token() });
        defer s.deinit();
        stop.work = &s.core.total_work;
        while (true) {
            const calls = stop.calls;
            _ = s.advance(0);
            try equal(calls + 1, stop.calls);
            const p = s.advance(4096);
            if (p.outcome != null) break;
        }
        try expect(stop.max_gap <= interval);
    }
}

test "edge session execution policies are explicit and runtime overrides validate once" {
    const R = dot.ir.Lowering(.{ .runtime_policy = true });
    var result = try dot.ir.parse(a, "digraph {a->b;a->c}", .{});
    defer result.deinit();
    var stop: Stop = .{ .at = 1 };
    var disabled = try R.edgeSession(result.ir().?, .{ .cancellation = stop.token() });
    defer disabled.deinit();
    try std.testing.expectError(error.MeteringDisabled, disabled.advance(1));
    try equal(@as(u64, 0), disabled.core.total_work);
    try expect(disabled.run().edge != null); // Disabled hook stays disabled.
    try equal(@as(u64, 0), stop.calls);
    stop = .{};
    var runtime_hook = try R.edgeSession(result.ir().?, .{
        .cancellation = stop.token(),
        .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = 4 } },
    });
    defer runtime_hook.deinit();
    stop.work = &runtime_hook.core.total_work;
    while ((try runtime_hook.advance(4096)).outcome == null) {}
    try expect(stop.calls > 1 and stop.max_gap <= 4);
    var enabled = try R.edgeSession(result.ir().?, .{ .policy = .{ .execution = .{ .metering = true } } });
    defer enabled.deinit();
    while ((try enabled.advance(64)).outcome == null) {}
    try std.testing.expectError(error.InvalidCancellationInterval, R.edgeSession(result.ir().?, .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    var plain = try dot.ir.Lowering(.{}).edgeSession(result.ir().?, .{});
    defer plain.deinit();
    try expect(plain.run().edge != null);
    try expect(plain.run().edge != null);
    try equal(dot.ir.EdgeStreamingOutcome.success, plain.run().outcome.?);
}

test "streaming work boundaries preserve prefixes and cancellation wins over exhaustion" {
    var result = try dot.ir.parse(a, "digraph {a->b;a->c}", .{});
    defer result.deinit();
    var measured = try IR.edgeSession(result.ir().?, .{});
    defer measured.deinit();
    while (measured.run().outcome == null) {}
    const total = measured.core.total_work;
    inline for (.{ true, false }) |enough| {
        var s = try IR.edgeSession(result.ir().?, .{ .limits = .{ .max_work = total - @intFromBool(!enough) } });
        defer s.deinit();
        var count: u32 = 0;
        while (true) {
            const p = s.advance(1);
            if (p.edge != null) count += 1;
            if (p.outcome) |outcome| {
                if (enough) try equal(dot.ir.EdgeStreamingOutcome.success, outcome) else try equal(error.WorkLimit, outcome.failure);
                try equal(@as(u32, 2), count);
                break;
            }
        }
    }
    const C = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var stop: Stop = .{ .at = 2 };
    var cancelled = try C.edgeSession(result.ir().?, .{ .limits = .{ .max_work = 0 }, .cancellation = stop.token() });
    defer cancelled.deinit();
    const p = cancelled.advance(0);
    try equal(error.Cancelled, p.outcome.?.failure);
    try equal(@as(u64, 0), p.total_work);
    try expect(p.edge == null);
}

test "edge session traversal handles deep reopened scopes and strict table rehashing" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("strict digraph {");
    for (0..40) |i| try source.writer.print("subgraph s{{n{d}}}->{{x y z}};", .{i});
    for (0..512) |_| try source.writer.writeAll("{");
    try source.writer.writeAll("q r");
    for (0..512) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("->x;}");
    var result = try dot.ir.parse(a, source.written(), .{});
    defer result.deinit();
    try check(result.ir().?);
}

test "streaming keeps generic operators and native source views" {
    const P = dot.Profile(.{ .source_encodings = &.{.utf16}, .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{.utf16}, .policy = .{ .execution = .{ .metering = true } } });
    var encoded = std.Io.Writer.Allocating.init(a);
    defer encoded.deinit();
    for ("graph {{a b}->c;{a b a}->c;a--b;a:p->d:q[color=red]}") |byte| try encoded.writer.writeInt(u16, byte, .little);
    var parsed = try P.parseAndValidate(a, encoded.written(), dot.diagnostic.discard, .{ .encoding = .utf16le });
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    var graph = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
    defer graph.deinit();
    for ([_]u32{ 1, 3, 9, 64 }) |budget| {
        var direct = try graph.edgeIterator(.{});
        defer direct.deinit();
        var session = try Native.edgeSession(&graph, .{});
        defer session.deinit();
        while (true) {
            const p = session.advance(budget);
            if (p.edge) |edge| {
                const expected = (try direct.next()).?;
                try equal(expected.edge, edge.edge);
                try equal(try expected.tailPort(), try edge.tailPort());
                try equal(try expected.attribute("color"), try edge.attribute("color"));
            }
            if (p.outcome) |outcome| {
                try equal(dot.ir.EdgeStreamingOutcome.success, outcome);
                break;
            }
        }
        try expect(try direct.next() == null);
    }
}

fn allocationCase(allocator: std.mem.Allocator, original: *const IR.Graph, budget: u32) !void {
    var copy = original.*;
    var moving: NoResize = .{ .backing = allocator };
    copy.allocator = moving.allocator();
    var session = try IR.edgeSession(&copy, .{});
    defer session.deinit();
    while (true) {
        const p = session.advance(budget);
        if (p.outcome) |outcome| switch (outcome) {
            .success => return,
            .failure => |err| return err,
        };
    }
}

test "edge streaming frees pending growth on allocation failure and enforces cumulative limits" {
    var result = try dot.ir.parse(a, "strict digraph {{a b c d e f g h}->{i j k l m n o p};a->i}", .{});
    defer result.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ result.ir().?, 1 });
    var sets = try dot.ir.parse(a, "digraph {x->{a b};x->{a b};{a b c d e f g h i j k l m n o p q r}->{x y};{a a b}->{x y}}", .{});
    defer sets.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ sets.ir().?, 4096 });
    inline for (.{
        .{ dot.ir.Limits{ .max_work = 0 }, error.WorkLimit },
        .{ dot.ir.Limits{ .max_pairs = 0 }, error.PairLimit },
        .{ dot.ir.Limits{ .max_edges = 0 }, error.EdgeLimit },
        .{ dot.ir.Limits{ .max_bytes = 0 }, error.MemoryLimit },
    }) |case| {
        var session = try IR.edgeSession(result.ir().?, .{ .limits = case[0] });
        defer session.deinit();
        while (true) {
            const p = session.advance(1);
            if (p.outcome) |outcome| {
                try equal(case[1], outcome.failure);
                try expect(p.edge == null);
                break;
            }
        }
        session.cancel();
        try equal(case[1], session.run().outcome.?.failure);
    }
}

fn compareCreditBoundaries(original: anytype, work_limits: u64) !void {
    var memory: NoResize = .{ .backing = a };
    var graph = original.*;
    if (@hasField(@TypeOf(graph), "_data")) graph._data.allocator = memory.allocator() else graph.allocator = memory.allocator();
    // Include stops inside the fused singleton path (9/10 credits), inside
    // ready-pair delivery (3), and after endpoint scratch has been populated.
    for (0..work_limits + 17) |limit| {
        const limits: dot.ir.Limits = if (limit < work_limits)
            .{ .max_work = @as(u64, limit) }
        else if (limit < work_limits + 8)
            .{ .max_pairs = @as(u64, limit - work_limits) }
        else if (limit < work_limits + 16)
            .{ .max_edges = @intCast(limit - work_limits - 8) }
        else
            .{ .max_bytes = 0 };
        for ([_]u32{ 2, 3, 4, 8, 9, 10, 11, 64, 4096 }) |budget| {
            var reference = try IR.edgeSession(&graph, .{ .limits = limits });
            defer reference.deinit();
            var batched = try IR.edgeSession(&graph, .{ .limits = limits });
            defer batched.deinit();
            while (true) {
                const p = batched.advance(budget);
                var last = reference.advance(0);
                for (0..p.work_used) |i| {
                    last = reference.advance(1);
                    try equal(@as(u32, 1), last.work_used);
                    if (i + 1 != p.work_used) try expect(last.edge == null and last.outcome == null);
                }
                // A multi-credit call can observe the lifetime limit after
                // its final step, where the one-credit call paused exactly.
                if (p.outcome != null and last.outcome == null) {
                    const stop = reference.advance(1);
                    try equal(@as(u32, 0), stop.work_used);
                    last = stop;
                }
                try equal(last.total_work, p.total_work);
                try equal(last.pairs_visited, p.pairs_visited);
                try equal(last.edges_emitted, p.edges_emitted);
                try equal(last.outcome, p.outcome);
                try equal(if (last.edge) |e| e.edge else null, if (p.edge) |e| e.edge else null);
                try equal(reference.core.phase, batched.core.phase);
                try equal(reference.core.connection, batched.core.connection);
                try equal(reference.core.left_index, batched.core.left_index);
                try equal(reference.core.right_index, batched.core.right_index);
                try equal(reference.core.side, batched.core.side);
                try equal(reference.core.body_index, batched.core.body_index);
                try equal(reference.core.body_end, batched.core.body_end);
                try equal(reference.core.mention_index, batched.core.mention_index);
                try equal(reference.core.mention_end, batched.core.mention_end);
                try equal(reference.core.generation, batched.core.generation);
                for (reference.core.endpoints, batched.core.endpoints) |expected, actual| {
                    try equal(expected.singleton, actual.singleton);
                    try equal(expected.count, actual.count);
                    try equal(expected.nodes.items, actual.nodes.items);
                }
                if (reference.core.phase == .endpoint_append) try equal(reference.core.pending_node, batched.core.pending_node);
                // A marks allocation is initialized in bounded chunks. Do not
                // read its unwritten suffix while clearing it for the first time.
                const initialized = if (reference.core.phase == .marks_clear) reference.core.mark_index else reference.core.marks.len;
                try equal(reference.core.marks[0..initialized], batched.core.marks[0..initialized]);
                try equal(reference.peakBytes(), batched.peakBytes());
                if (p.outcome != null) break;
            }
        }
    }
}

test "fused streaming preserves every credit limit and retained edge prefix" {
    const source = "digraph {a:p->b:q;a->c;{a b}->{c d};{}->a;a->{};d->e;e->e}";
    var result = try dot.ir.parse(a, source, .{});
    defer result.deinit();
    try compareCreditBoundaries(result.ir().?, 90);
    var partial = try dot.ir.parsePartial(a, "digraph {a->b;bad->;a->{b c};d->e;f->", .{});
    defer partial.deinit();
    try compareCreditBoundaries(partial.ir().?, 90);
}

test "warm set streaming preserves exact state at grants and lifetime limits" {
    for ([_][]const u8{
        "digraph {a->{b c};a->{b c};{a b}->{c d};{a a b b}->{c d c};{a b c d e f g h i j k l m n o p q r}->x;{a b}->x}",
        "digraph {{a b}->x;{a a}->x;{}->x;x->{};subgraph s{a}->x;subgraph s{b}->x;subgraph s{}->x;{a {b {c}}}->x}",
        "strict graph {{a b}--{c d};{a b a}--{c d c};{a b}--{a b}}",
    }) |source| {
        var result = try dot.ir.parse(a, source, .{});
        defer result.deinit();
        try compareCreditBoundaries(result.ir().?, 256);
        try check(result.ir().?);
    }
    var partial = try dot.ir.parsePartial(a, "digraph {a->{b c};broken->;a->{b b c};{a b}->{c d};f->", .{});
    defer partial.deinit();
    try compareCreditBoundaries(partial.ir().?, 128);
}

test "warm set streaming handles mark rollover and runtime policy dispatch" {
    var result = try dot.ir.parse(a, "digraph {{a b}->{c d};{a a b}->{c d c};{a b}->{c d};x->y}", .{});
    defer result.deinit();
    var memory: NoResize = .{ .backing = a };
    var graph = result.ir().?.*;
    graph.allocator = memory.allocator();
    inline for (.{ std.math.maxInt(u32) - 2, std.math.maxInt(u32) - 1, std.math.maxInt(u32) }) |generation| {
        var reference = try IR.edgeSession(&graph, .{});
        defer reference.deinit();
        var batched = try IR.edgeSession(&graph, .{});
        defer batched.deinit();
        while (reference.advance(1).edge == null) {}
        try expect(batched.advance(4096).edge != null);
        reference.core.generation = generation;
        batched.core.generation = generation;
        while (true) {
            const p = batched.advance(4096);
            var last = reference.advance(0);
            for (0..p.work_used) |_| last = reference.advance(1);
            try equal(last.total_work, p.total_work);
            try equal(last.outcome, p.outcome);
            try equal(if (last.edge) |e| e.edge else null, if (p.edge) |e| e.edge else null);
            try equal(reference.core.generation, batched.core.generation);
            try equal(reference.core.marks, batched.core.marks);
            try equal(reference.peakBytes(), batched.peakBytes());
            if (p.outcome != null) break;
        }
    }
    const Runtime = dot.ir.Lowering(.{ .runtime_policy = true });
    var runtime = try Runtime.edgeSession(&graph, .{ .policy = .{ .execution = .{ .metering = true } } });
    defer runtime.deinit();
    var reference = try IR.edgeSession(&graph, .{});
    defer reference.deinit();
    while (true) {
        const p = try runtime.advance(64);
        var last = reference.advance(0);
        for (0..p.work_used) |_| last = reference.advance(1);
        try equal(last.total_work, p.total_work);
        try equal(last.outcome, p.outcome);
        try equal(if (last.edge) |e| e.edge else null, if (p.edge) |e| e.edge else null);
        if (p.outcome != null) break;
    }
}

test "streaming shortcuts never bypass a cancellation checkpoint" {
    const C = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var result = try dot.ir.parse(a, "digraph {a->b;a->{c d};a->{c d c};{a b}->{c d};d->e}", .{});
    defer result.deinit();
    var stop: Stop = .{};
    var full = try C.edgeSession(result.ir().?, .{ .cancellation = stop.token() });
    while (full.advance(4096).outcome == null) {}
    full.deinit();
    const polls = stop.calls;
    for (2..polls + 1) |at| {
        stop = .{ .at = at };
        var current = try C.edgeSession(result.ir().?, .{ .cancellation = stop.token() });
        defer current.deinit();
        stop.work = &current.core.total_work;
        while (current.advance(4096).outcome == null) {}
        try equal(error.Cancelled, current.core.outcome.?.failure);
        try equal(@as(u64, at), stop.calls);
        try equal(@as(u64, at - 2), current.core.total_work);
        try expect(stop.max_gap <= 1);
    }
}
