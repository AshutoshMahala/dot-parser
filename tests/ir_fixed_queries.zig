const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const Retained = IR.FixedGraphStorage(.{ .nodes = 64 });

const EdgeMemory = struct {
    bytes: []align(16) u8,
    bound: IR.EdgeScratch,
    fn init(graph: anytype, caps: dot.ir.EdgeScratchCapacities) !EdgeMemory {
        const layout = try IR.edgeScratchLayout(graph, caps);
        const bytes = try a.alignedAlloc(u8, .@"16", layout.byte_size + 16);
        errdefer a.free(bytes);
        @memset(bytes, 0xcd);
        return .{ .bytes = bytes, .bound = try layout.bind(bytes) };
    }
    fn deinit(self: EdgeMemory) void {
        a.free(self.bytes);
    }
    fn canaries(self: EdgeMemory) !void {
        for (self.bytes[self.bound.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
    }
};
fn attributes(view: anytype, comptime folded: bool, caps: dot.ir.AttributeScratchCapacities) !void {
    const layout = try IR.attributeScratchLayout(caps);
    const bytes = try a.alignedAlloc(u8, .@"16", layout.byte_size + 16);
    defer a.free(bytes);
    const bound = try layout.bind(bytes);
    var total: ?u64 = null;
    for ([_]u32{ 1, 2, 7, 64, 4096 }) |grant| {
        @memset(bytes, 0xcd);
        var expected = if (folded) try view.attributesWith(.{}) else try view.attributes(.{});
        defer if (!folded) expected.deinit();
        var s = try IR.attributesSessionIn(view, bound, .{});
        defer s.deinit();
        var emitted: u32 = 0;
        var work: u64 = 0;
        while (true) {
            const zero = s.advance(0);
            try eq(@as(u32, 0), zero.work_used);
            try expect(zero.attribute == null);
            const p = s.advance(grant);
            try expect(p.work_used <= grant);
            work += p.work_used;
            try eq(work, p.total_work);
            if (p.attribute) |v| {
                try eq((try expected.next()).?, v);
                emitted += 1;
            }
            try eq(emitted, p.attributes_emitted);
            if (p.outcome) |outcome| {
                try expect(outcome == .success);
                try expect(try expected.next() == null);
                break;
            }
        }
        if (total) |n| try eq(n, work) else total = work;
        try eq(layout.byte_size, s.peakBytes());
        try expect(s.shortfall() == null);
        s.cancel();
        try expect(s.run().outcome.? == .success);
        try expect(s.run().attribute == null);
        for (bytes[layout.byte_size..]) |b| try eq(@as(u8, 0xcd), b);
    }
    if (!folded) {
        var expected = try view.attributes(.{});
        defer expected.deinit();
        var actual = try view.attributesIn(bound, .{});
        defer actual.deinit();
        while (try expected.next()) |v| try eq(v, (try actual.next()).?);
        try expect(try actual.next() == null);
        try expect(actual.shortfall() == null);
    }
}
fn compare(graph: anytype) !void {
    const caps = try IR.edgeScratchBounds(graph, .{});
    const memory = try EdgeMemory.init(graph, caps);
    defer memory.deinit();
    const attr_caps = IR.attributeScratchBounds(graph);
    var peak: ?dot.ir.EdgeScratchCapacities = null;
    var total: ?u64 = null;
    for ([_]u32{ 1, 2, 7, 64, 4096 }) |grant| {
        @memset(memory.bytes, 0xcd);
        var expected = try graph.edgeIterator(.{});
        defer expected.deinit();
        var actual = try IR.edgeSessionIn(graph, memory.bound, .{});
        defer actual.deinit();
        try eq(memory.bound.bytes.len, actual.peakBytes());
        var work: u64 = 0;
        var count: u32 = 0;
        while (true) {
            const zero = actual.advance(0);
            try expect(zero.edge == null);
            try eq(@as(u32, 0), zero.work_used);
            const p = actual.advance(grant);
            try expect(p.work_used <= grant);
            work += p.work_used;
            try eq(work, p.total_work);
            if (p.edge) |edge| {
                const e = (try expected.next()).?;
                try eq(e.edge, edge.edge);
                try eq(try e.attribute("color"), try edge.attribute("color"));
                if (grant == 1) try attributes(edge, false, attr_caps);
                count += 1;
            }
            try eq(count, p.edges_emitted);
            if (p.outcome) |outcome| {
                try expect(outcome == .success);
                break;
            }
        }
        try expect(try expected.next() == null);
        if (total) |n| try eq(n, work) else total = work;
        if (peak) |n| try eq(n, actual.scratchPeak()) else peak = actual.scratchPeak();
        actual.cancel();
        const done = actual.advance(1);
        try expect(done.edge == null and done.outcome.? == .success);
        try eq(@as(u32, 0), done.work_used);
        try memory.canaries();
    }
    // The observed combined capacity must suffice exactly, for both drivers.
    const exact = try EdgeMemory.init(graph, peak.?);
    defer exact.deinit();
    var expected = try graph.edgeIterator(.{});
    defer expected.deinit();
    var direct = try graph.edgeIteratorIn(exact.bound, .{});
    defer direct.deinit();
    while (try expected.next()) |v| try eq(v.edge, (try direct.next()).?.edge);
    try expect(try direct.next() == null);
    try eq(peak.?, direct.scratchPeak());
    try exact.canaries();
    var nodes = graph.nodeIterator();
    while (nodes.next()) |node| try attributes(node, false, .{});
    try attributes(try graph.scopeView(.root), false, .{});
    var folded = try graph.materialize(.{});
    defer folded.deinit();
    var edges = folded.edgeIterator();
    while (edges.next()) |edge| try attributes(edge, true, .{});
}

test "fixed query scratch matches direct and resumable complete and partial traversal" {
    for ([_][]const u8{
        "digraph {}",
        "digraph {a->b;a:p->c:q[color=red];a->b}",
        "digraph {{a b a c d}->x;x->{a b};{}->a;{a b}->{a b};a->{};q->r}",
        "strict graph {edge[color=red];{a b}--{a b}[color=blue];b:r--a:s[color=green];a--c}",
        "strict digraph {subgraph s{a}->x[color=red];subgraph s{b}->x;subgraph s{a}->x[color=blue]}",
        "digraph {graph[label=root];node[color=blue];a->{edge[color=red];b->c}->d;}",
    }) |source| {
        var result = try dot.ir.parse(a, source, .{});
        defer result.deinit();
        try compare(result.ir().?);
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        try compare(partial.ir().?);
    }
    var partial = try dot.ir.parsePartial(a, "strict digraph {a->b[color=red];broken->;a->b[color=blue];c->d", .{});
    defer partial.deinit();
    try compare(partial.ir().?);
}

test "fixed pair exhaustion preserves prefix skips full-table duplicates and latches" {
    var result = try dot.ir.parse(a, "strict digraph {a->b;b->c;a->b;c->d}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var scratch: IR.FixedEdgeScratch(Retained, .{ .strict_pairs = 2 }) = .{};
    var iterator = try graph.edgeIteratorIn(scratch.storage(), .{});
    const first = (try iterator.next()).?;
    try expect(try iterator.next() != null);
    try std.testing.expectError(error.PoolExhausted, iterator.next());
    try eq(dot.ir.StorageShortfall{ .resource = .strict_pairs, .limit = 2, .required_at_least = 3 }, iterator.shortfall().?);
    try std.testing.expectError(error.PoolExhausted, iterator.next());
    iterator.deinit();
    for ([_]u32{ 1, 2, 64, 4096 }) |grant| {
        var s = try IR.edgeSessionIn(graph, scratch.storage(), .{});
        defer s.deinit();
        var count: u32 = 0;
        while (true) {
            const p = s.advance(grant);
            if (p.edge != null) count += 1;
            if (p.outcome) |o| {
                try eq(error.PoolExhausted, o.failure);
                try eq(@as(u64, 4), p.pairs_visited);
                try eq(@as(u32, 2), p.edges_emitted);
                break;
            }
        }
        try eq(@as(u32, 2), count);
        s.cancel();
        try eq(error.PoolExhausted, s.run().outcome.?.failure);
        try expect(s.run().edge == null);
    }
    // Escaped views survive operation destruction and scratch reuse.
    var bytes: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.print("{f}", .{first.from().name()});
    try std.testing.expectEqualStrings("a", writer.buffered());
}

test "fixed query bounds are explicit graph metadata and checked layouts" {
    var result = try dot.ir.parse(a, "strict digraph {a->b;a[x=1];graph[y=2];edge[z=3]}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    try eq(dot.ir.EdgeScratchCapacities{ .members = 4, .strict_pairs = 4 }, try IR.edgeScratchBounds(graph, .{}));
    try eq(@as(u32, 3), IR.attributeScratchBounds(graph).winners);
    try eq(@as(u32, 1), (try IR.edgeScratchBounds(graph, .{ .limits = .{ .max_pairs = 1 } })).strict_pairs);
    const layout = try IR.edgeScratchLayout(graph, .{ .members = 4, .strict_pairs = 4 });
    var bytes: [1024]u8 align(16) = @splat(0xcd);
    try std.testing.expectError(error.BufferTooSmall, layout.bind(bytes[0 .. layout.byte_size - 1]));
    try std.testing.expectError(error.InvalidStorage, layout.bind(bytes[1..]));
    var forged = layout;
    forged.slots_offset += 4;
    try std.testing.expectError(error.InvalidStorage, forged.bind(&bytes));
    const bound = try layout.bind(&bytes);
    for (bytes) |b| try eq(@as(u8, 0xcd), b);
    try std.testing.expectError(error.MemoryLimit, graph.edgeIteratorIn(bound, .{ .limits = .{ .max_bytes = layout.byte_size - 1 } }));
    var too_small: IR.FixedEdgeScratch(IR.FixedGraphStorage(.{ .nodes = 1 }), .{ .members = 1 }) = .{};
    try std.testing.expectError(error.InvalidStorage, graph.edgeIteratorIn(too_small.storage(), .{}));
    var no_members: IR.FixedEdgeScratch(IR.FixedGraphStorage(.{}), .{ .strict_pairs = 1 }) = .{};
    var s = try graph.edgeIteratorIn(no_members.storage(), .{});
    defer s.deinit();
    try expect(try s.next() != null);
    try expect(try s.next() == null);
    try std.testing.expectError(error.IndexLimit, IR.attributeScratchLayout(.{ .winners = std.math.maxInt(u32) }));
}

test "shared member shortfalls occur after a prefix without guessing missing marks" {
    var result = try dot.ir.parse(a, "digraph {x->y;{a b c}->x;{a b}->{a b}}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    inline for (.{ 0, 2, 3, 4 }) |capacity| {
        var memory: IR.FixedEdgeScratch(Retained, .{ .members = capacity }) = .{};
        var direct = try graph.edgeIteratorIn(memory.storage(), .{});
        defer direct.deinit();
        var count: u32 = 0;
        while (direct.next() catch |err| {
            try eq(error.PoolExhausted, err);
            break;
        }) |_| count += 1;
        const expected: u32 = if (capacity == 4) 8 else if (capacity == 3) 4 else 1;
        try eq(expected, count);
        if (capacity < 4) {
            try eq(dot.ir.StorageShortfall{ .resource = .members, .limit = capacity, .required_at_least = capacity + 1 }, direct.shortfall().?);
            try std.testing.expectError(error.PoolExhausted, direct.next());
        }
        var s = try IR.edgeSessionIn(graph, memory.storage(), .{});
        defer s.deinit();
        var emitted: u32 = 0;
        while (true) {
            const p = s.advance(1);
            if (p.edge != null) emitted += 1;
            if (p.outcome) |o| {
                if (capacity == 4) try expect(o == .success) else try eq(error.PoolExhausted, o.failure);
                break;
            }
        }
        try eq(count, emitted);
        try eq(direct.shortfall(), s.shortfall());
        try eq(direct.scratchPeak(), s.scratchPeak());
    }
}

test "winner shortfalls publish no provisional attributes and semantic limits precede pair slots" {
    var result = try dot.ir.parse(a, "strict digraph {edge[color=red];a:p->b:q[label=first];a->b[label=last];b->c}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var edge_memory: IR.FixedEdgeScratch(Retained, .{ .strict_pairs = 1 }) = .{};
    var edges = try graph.edgeIteratorIn(edge_memory.storage(), .{ .limits = .{ .max_edges = 1 } });
    defer edges.deinit();
    const edge = (try edges.next()).?;
    try std.testing.expectError(error.EdgeLimit, edges.next());
    try expect(edges.shortfall() == null);
    inline for (.{ 0, 1, 2 }) |count| {
        var memory: IR.FixedAttributeScratch(.{ .winners = count }) = .{};
        var iterator = try edge.attributesIn(memory.storage(), .{});
        defer iterator.deinit();
        if (count < 2) {
            try std.testing.expectError(error.PoolExhausted, iterator.next());
            try eq(dot.ir.StorageShortfall{ .resource = .attribute_winners, .limit = count, .required_at_least = 2 }, iterator.shortfall().?);
        } else while (try iterator.next()) |_| {}
        var s = try IR.attributesSessionIn(edge, memory.storage(), .{});
        defer s.deinit();
        var emitted: u32 = 0;
        while (true) {
            const p = s.advance(1);
            if (p.attribute != null) emitted += 1;
            if (p.outcome) |o| {
                if (count < 2) {
                    try eq(error.PoolExhausted, o.failure);
                    try eq(@as(u32, 0), emitted);
                } else try expect(o == .success);
                break;
            }
        }
        try eq(iterator.shortfall(), s.shortfall());
        try eq(iterator.scratchPeak(), s.scratchPeak());
    }
}

const Polls = struct {
    count: u32 = 0,
    stop: u32 = std.math.maxInt(u32),
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        return self.count >= self.stop;
    }
    fn hook(self: *Polls) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};
test "fixed sessions preserve cancellation intervals zero grants terminal outcomes and runtime policies" {
    const R = dot.ir.Lowering(.{ .runtime_policy = true });
    var result = try dot.ir.parse(a, "strict digraph {{a b}->{a b}[x=1 y=2];a->b[x=3]}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var memory: IR.FixedEdgeScratch(Retained, .{ .members = 4, .strict_pairs = 4 }) = .{};
    var am: IR.FixedAttributeScratch(.{ .winners = 2 }) = .{};
    @memset(&memory.bytes, 0xcd);
    @memset(&am.bytes, 0xcd);
    var disabled = try R.edgeSessionIn(graph, memory.storage(), .{});
    try std.testing.expectError(error.MeteringDisabled, disabled.advance(1));
    disabled.deinit();
    try std.testing.expectError(error.InvalidCancellationInterval, R.edgeSessionIn(graph, memory.storage(), .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    for ([_]u32{ 1, 4, 64 }) |interval| {
        const policy: dot.ir.Policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } };
        var baseline: Polls = .{};
        var full = try R.edgeSessionIn(graph, memory.storage(), .{ .policy = policy, .cancellation = baseline.hook() });
        while (full.run().outcome == null) {}
        full.deinit();
        for (1..baseline.count + 1) |stop| {
            var polls: Polls = .{ .stop = @intCast(stop) };
            var stream = R.edgeSessionIn(graph, memory.storage(), .{ .policy = policy, .cancellation = polls.hook() }) catch |err| {
                try eq(error.Cancelled, err);
                try eq(@as(usize, 1), stop);
                continue;
            };
            defer stream.deinit();
            var reference = try graph.edgeIterator(.{});
            defer reference.deinit();
            while (true) {
                const p = stream.run();
                if (p.edge) |v| try eq((try reference.next()).?.edge, v.edge);
                if (p.outcome) |o| {
                    try eq(error.Cancelled, o.failure);
                    break;
                }
            }
            const calls = polls.count;
            const checksum = std.hash.Wyhash.hash(0, &memory.bytes);
            const terminal = try stream.advance(0);
            try eq(@as(u32, 0), terminal.work_used);
            try expect(terminal.edge == null);
            try eq(error.Cancelled, terminal.outcome.?.failure);
            try eq(calls, polls.count);
            try eq(checksum, std.hash.Wyhash.hash(0, &memory.bytes));
        }
        var edges = try graph.edgeIterator(.{});
        defer edges.deinit();
        const edge = (try edges.next()).?;
        var polls: Polls = .{};
        var s = try R.attributesSessionIn(edge, am.storage(), .{ .policy = policy, .cancellation = polls.hook() });
        defer s.deinit();
        const before = std.hash.Wyhash.hash(0, &am.bytes);
        const zero = try s.advance(0);
        try eq(@as(u32, 0), zero.work_used);
        try eq(before, std.hash.Wyhash.hash(0, &am.bytes));
        // Stop at every operation boundary is possible even with a large interval.
        polls.stop = polls.count + 1;
        try eq(error.Cancelled, (try s.advance(0)).outcome.?.failure);
        try expect(s.run().attribute == null);
    }
}

test "query scratch cannot alias owners pools or source and never calls the graph allocator" {
    var result = try dot.ir.parse(a, "strict graph {{a b}--{a b}[x=1];b--a[x=2]}", .{});
    defer result.deinit();
    const original = result.ir().?;
    var graph = original.*; // Borrow all storage; never deinit this descriptor.
    var trap: std.testing.FailingAllocator = .init(a, .{ .fail_index = 0 });
    graph.allocator = trap.allocator();
    var memory: IR.FixedEdgeScratch(Retained, .{ .members = 4, .strict_pairs = 3 }) = .{};
    var am: IR.FixedAttributeScratch(.{ .winners = 1 }) = .{};
    var direct = try graph.edgeIteratorIn(memory.storage(), .{});
    const edge = (try direct.next()).?;
    while (try direct.next()) |_| {}
    direct.deinit();
    var attrs = try edge.attributesIn(am.storage(), .{});
    while (try attrs.next()) |_| {}
    attrs.deinit();
    var s = try IR.edgeSessionIn(&graph, memory.storage(), .{});
    while (s.run().outcome == null) {}
    s.deinit();
    var as = try IR.attributesSessionIn(edge, am.storage(), .{});
    while (as.run().outcome == null) {}
    as.deinit();
    try eq(@as(usize, 0), trap.alloc_index);
    const bad: IR.AttributeScratch = .{ .bytes = std.mem.sliceAsBytes(@constCast(graph.nodes)), .capacities = .{ .winners = 1 } };
    try std.testing.expectError(error.InvalidStorage, edge.attributesIn(bad, .{}));
    try std.testing.expectError(error.InvalidStorage, IR.attributesSessionIn(edge, bad, .{}));
    var folded = try original.materialize(.{});
    defer folded.deinit();
    var views = folded.edgeIterator();
    const view = views.next().?;
    try std.testing.expectError(error.InvalidStorage, IR.attributesSessionIn(view, .{ .bytes = std.mem.asBytes(&folded), .capacities = .{ .winners = 1 } }, .{}));
}

test "fixed query scratch rejects sparse port storage before writing" {
    var result = try dot.ir.parse(a, "strict digraph {a:p->b:q[x=1]}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    const bytes = std.mem.sliceAsBytes(@constCast(graph.endpoint_ports));
    const checksum = std.hash.Wyhash.hash(0, bytes);
    // Bind successfully first: rejection must be due to aliasing, not an
    // alignment or capacity error in the descriptor itself.
    const attrs = try (try IR.attributeScratchLayout(.{ .winners = 1 })).bind(bytes);
    try std.testing.expectError(error.InvalidStorage, edge.attributesIn(attrs, .{}));
    try std.testing.expectError(error.InvalidStorage, IR.attributesSessionIn(edge, attrs, .{}));
    const stream = try (try IR.edgeScratchLayout(graph, .{ .members = 1 })).bind(bytes);
    try std.testing.expectError(error.InvalidStorage, graph.edgeIteratorIn(stream, .{}));
    try std.testing.expectError(error.InvalidStorage, IR.edgeSessionIn(graph, stream, .{}));
    try eq(checksum, std.hash.Wyhash.hash(0, bytes));
}

test "fixed query work limits and byte accounting cover full reservation without initialization" {
    var result = try dot.ir.parse(a, "strict digraph {{a b}->{a b}[x=1];a->b[x=2]}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var memory: IR.FixedEdgeScratch(Retained, .{ .members = 4, .strict_pairs = 4 }) = .{};
    @memset(&memory.bytes, 0xcd);
    var full = try IR.edgeSessionIn(graph, memory.storage(), .{});
    const size = full.peakBytes();
    for (memory.bytes) |b| try eq(@as(u8, 0xcd), b);
    var total: u64 = 0;
    while (true) {
        const p = full.advance(1);
        if (p.outcome != null) {
            total = p.total_work;
            break;
        }
    }
    full.deinit();
    for (0..total) |limit| {
        var s = try IR.edgeSessionIn(graph, memory.storage(), .{ .limits = .{ .max_work = limit } });
        defer s.deinit();
        while (true) {
            const p = s.run();
            if (p.outcome) |o| {
                try eq(error.WorkLimit, o.failure);
                try eq(@as(u64, limit), p.total_work);
                break;
            }
        }
        try eq(size, s.peakBytes());
        try expect(s.shortfall() == null);
    }
    var am: IR.FixedAttributeScratch(.{ .winners = 1 }) = .{};
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    var whole = try IR.attributesSessionIn(edge, am.storage(), .{});
    while (true) {
        const p = whole.run();
        if (p.outcome != null) {
            total = p.total_work;
            break;
        }
    }
    whole.deinit();
    for (0..total) |limit| {
        var s = try IR.attributesSessionIn(edge, am.storage(), .{ .limits = .{ .max_work = limit } });
        defer s.deinit();
        while (true) {
            const p = s.run();
            if (p.outcome) |o| {
                try eq(error.WorkLimit, o.failure);
                try eq(@as(u64, limit), p.total_work);
                break;
            }
        }
        try expect(s.shortfall() == null);
    }
}

test "fixed scratch works without a query allocator and aliases are checked before writes" {
    var parsed = dot.parseAndValidate(a, "strict digraph {{a b}->{a b}[x=1]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) };
    const bounds = try IR.loweringBounds(doc.capacities(), options);
    const layout = try IR.loweringLayout(bounds.graph, bounds.scratch);
    const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
    defer a.free(retained);
    const temporary = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
    defer a.free(temporary);
    var lowered = IR.lowerCompleteIn(doc, try layout.bind(retained, temporary), options);
    try expect(lowered.outcome == .success);
    const graph = &lowered.graph.?;
    defer graph.deinit();
    var growable = try graph.edgeIterator(.{});
    defer growable.deinit();
    try std.testing.expectError(error.StorageRequired, growable.next());
    var memory: IR.FixedEdgeScratch(Retained, .{ .members = 4, .strict_pairs = 4 }) = .{};
    var am: IR.FixedAttributeScratch(.{ .winners = 1 }) = .{};
    var direct = try graph.edgeIteratorIn(memory.storage(), .{});
    defer direct.deinit();
    const first = (try direct.next()).?;
    var attrs = try first.attributesIn(am.storage(), .{});
    try expect(try attrs.next() != null);
    attrs.deinit();
    direct.deinit();
    direct = try graph.edgeIteratorIn(memory.storage(), .{});
    while (try direct.next()) |_| {}
    var session_memory: IR.FixedEdgeScratch(Retained, .{ .members = 4, .strict_pairs = 4 }) = .{};
    var session = try IR.edgeSessionIn(graph, session_memory.storage(), .{});
    defer session.deinit();
    var count: u32 = 0;
    while (true) {
        const p = session.advance(1);
        if (p.edge) |edge| {
            count += 1;
            var s = try IR.attributesSessionIn(edge, am.storage(), .{});
            defer s.deinit();
            while (true) {
                const v = s.advance(1);
                if (v.outcome) |o| {
                    try expect(o == .success);
                    break;
                }
            }
        }
        if (p.outcome) |o| {
            try expect(o == .success);
            break;
        }
    }
    try eq(@as(u32, 4), count);
    try std.testing.expectError(error.InvalidStorage, graph.edgeIteratorIn(.{ .bytes = retained, .node_capacity = 2, .capacities = .{ .members = 4 } }, .{}));
    // Even unpopulated fixed pools and final padding belong to the graph.
    const last = retained[retained.len - 4 ..];
    try std.testing.expectError(error.InvalidStorage, graph.edgeIteratorIn(.{ .bytes = last, .node_capacity = 0, .capacities = .{ .members = 1 } }, .{}));
    // Extra bytes are ignored even if the excess overlaps a known owner.
    var empty = try graph.edgeIteratorIn(.{ .bytes = retained, .node_capacity = 0, .capacities = .{} }, .{});
    defer empty.deinit();
    try eq(@as(usize, 0), empty.peakBytes());
    comptime {
        if (@hasDecl(IR, "storageLayout") or @hasDecl(IR, "capacityBounds") or @hasDecl(IR, "partialCapacityBounds")) @compileError("legacy lowering alias");
    }
}

test "fixed query native encodings and partial answers match allocator backed operations" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .retention = .{ .partial = true } } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .execution = .{ .metering = true } } });
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |encoding| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        var points = (try std.unicode.Utf8View.init("strict graph {{a b}--{a b}[\"café😀\"=yes];b:p--a:q;bad--;a--b[\"café😀\"=no];}")).iterator();
        while (points.nextCodepoint()) |cp| switch (encoding) {
            .utf8 => {
                var bytes: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(cp, &bytes);
                try source.writer.writeAll(bytes[0..n]);
            },
            .utf16le, .utf16be => {
                const order = if (encoding == .utf16be) .big else .little;
                if (cp < 0x10000) try source.writer.writeInt(u16, @intCast(cp), order) else {
                    try source.writer.writeInt(u16, @intCast(0xd800 + ((cp - 0x10000) >> 10)), order);
                    try source.writer.writeInt(u16, @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff)), order);
                }
            },
            .utf32le, .utf32be => try source.writer.writeInt(u32, cp, if (encoding == .utf32be) .big else .little),
            else => unreachable,
        };
        var parsed = try P.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{ .encoding = encoding });
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        var graph = try Native.lowerPartial(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
        defer graph.deinit();
        var memory: Native.FixedEdgeScratch(Retained, .{ .members = 4, .strict_pairs = 3 }) = .{};
        var am: Native.FixedAttributeScratch(.{ .winners = 1 }) = .{};
        for ([_]u32{ 1, 64 }) |grant| {
            var expected = try graph.edgeIterator(.{});
            defer expected.deinit();
            var actual = try Native.edgeSessionIn(&graph, memory.storage(), .{});
            defer actual.deinit();
            while (true) {
                const p = actual.advance(grant);
                try expect(p.work_used <= grant);
                if (p.edge) |edge| {
                    try eq((try expected.next()).?.edge, edge.edge);
                    var attrs = try edge.attributesIn(am.storage(), .{});
                    var reference = try edge.attributes(.{});
                    while (try reference.next()) |value| try eq(value, (try attrs.next()).?);
                    try expect(try attrs.next() == null);
                    attrs.deinit();
                    reference.deinit();
                    var stream = try Native.attributesSessionIn(edge, am.storage(), .{});
                    defer stream.deinit();
                    while (true) {
                        const v = stream.advance(grant);
                        if (v.outcome) |o| {
                            try expect(o == .success);
                            break;
                        }
                    }
                }
                if (p.outcome) |o| {
                    try expect(o == .success);
                    break;
                }
            }
            try expect(try expected.next() == null);
        }
    }
}

test "fixed marks rollover is bounded and large symbolic products only retain a prefix" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("strict digraph {a->b;{");
    for (0..256) |_| try source.writer.writeAll("{");
    for (0..100) |i| try source.writer.print("n{d};", .{i});
    for (0..256) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("}->{");
    for (0..100) |i| try source.writer.print("m{d};", .{i});
    try source.writer.writeAll("}}");
    var parsed = try dot.ir.parse(a, source.written(), .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    try eq(@as(usize, 2), graph.connections.len);
    const caps = dot.ir.EdgeScratchCapacities{ .members = 200, .strict_pairs = 32 };
    const memory = try EdgeMemory.init(graph, caps);
    defer memory.deinit();
    var reference = try graph.edgeIterator(.{});
    defer reference.deinit();
    var session = try IR.edgeSessionIn(graph, memory.bound, .{});
    defer session.deinit();
    const first = session.run();
    try eq((try reference.next()).?.edge, first.edge.?.edge);
    session.core.generation = std.math.maxInt(u32);
    var count: u32 = 1;
    while (true) {
        const p = session.advance(1);
        try expect(p.work_used <= 1);
        if (p.edge) |e| {
            count += 1;
            try eq((try reference.next()).?.edge, e.edge);
        }
        if (p.outcome) |o| {
            try eq(error.PoolExhausted, o.failure);
            break;
        }
    }
    try eq(@as(u32, 32), count);
    try eq(caps, session.scratchPeak());
    try memory.canaries();
}

test "metadata bounds cover generated overlapping products repeated pairs and unrelated keys" {
    const ends = [_][]const u8{ "a", "b:p", "{a b c}", "{b a c}", "{}", "subgraph s {a c}", "{a a b}" };
    for (0..21) |seed| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        const directed = seed % 2 == 0;
        try source.writer.writeAll(if (directed) "strict digraph {" else "strict graph {");
        try source.writer.writeAll("node[node_key=x];graph[graph_key=y];");
        for (0..7) |i| try source.writer.print("{s}{s}{s}[k{d}=v{d}];", .{ ends[(seed + i) % ends.len], if (directed) "->" else "--", ends[(seed * 3 + i * 5) % ends.len], i % 3, i });
        try source.writer.writeAll("}");
        var parsed = try dot.ir.parse(a, source.written(), .{});
        defer parsed.deinit();
        try compare(parsed.ir().?);
    }
    // Many distinct pairs occupy the collision-checked map, then repeat in
    // reverse order. A full fixed key pool must still skip every duplicate.
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("strict digraph {");
    for (0..2) |round| for (0..400) |i| {
        const p = if (round == 0) i else 399 - i;
        try source.writer.print("n{d}->n{d};", .{ p / 20, p % 20 });
    };
    try source.writer.writeAll("}");
    var parsed = try dot.ir.parse(a, source.written(), .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    var memory: IR.FixedEdgeScratch(Retained, .{ .strict_pairs = 400 }) = .{};
    for ([_]u32{ 1, 64, 4096 }) |grant| {
        var expected = try graph.edgeIterator(.{});
        defer expected.deinit();
        var actual = try IR.edgeSessionIn(graph, memory.storage(), .{});
        defer actual.deinit();
        while (true) {
            const p = actual.advance(grant);
            if (p.edge) |edge| try eq((try expected.next()).?.edge, edge.edge);
            if (p.outcome) |o| {
                try expect(o == .success);
                try eq(@as(u32, 400), p.edges_emitted);
                try eq(@as(u64, 800), p.pairs_visited);
                break;
            }
        }
        try expect(try expected.next() == null);
    }
}
