const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const Full = dot.ir.Lowering(.{});
const Topology = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
const ScheduledFull = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const Scheduled = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const fixtures = [_][]const u8{
    "digraph {}",
    "digraph {a->b;a->b; a->{}; {}->b; isolated}",
    "strict digraph {edge[color=red]; {a b}->{x y}[label=old];a->x[label=new];x->x}",
    "strict graph {a:p:n--b:q[color=red];b:r--a:s[tailport=override];a--a}",
    "digraph {subgraph s{a;subgraph inner{b}};x->subgraph s{c};subgraph s{d};x->subgraph s{}}",
    "digraph {\"a\"+\"b\"->ab;\"é\"-><<B>x</B>>;ab:p->\"é\":q}",
};

fn core(graph: anytype) if (@hasField(@TypeOf(graph.*), "_data")) *const @FieldType(@TypeOf(graph.*), "_data") else @TypeOf(graph) {
    return if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph;
}

fn compareQueryProgress(expected: anytype, actual: anytype) !void {
    try eq(expected.work_used, actual.work_used);
    try eq(expected.total_work, actual.total_work);
    try eq(expected.outcome, actual.outcome);
}

fn compareOperations(full: anytype, graph: anytype) !void {
    const partial = @hasField(@TypeOf(graph.*), "_data");
    const f = core(full);
    const g = core(graph);
    try eq(f.nodes.len, g.nodes.len);
    try eq(f.scopes.len, g.scopes.len);
    if (partial) {
        try eq(full.state(), graph.state());
        try eq(full.kind(), graph.kind());
        var fg = full.gaps();
        var gaps = graph.gaps();
        while (fg.next()) |gap| try eq(gap, gaps.next().?);
        try expect(gaps.next() == null);
    }
    try eq(try full.findNode("absent"), try graph.findNode("absent"));
    var nodes = graph.nodeIterator();
    var fnodes = full.nodeIterator();
    while (nodes.next()) |node| {
        const other = fnodes.next().?;
        try eq(other.id, node.id);
        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print("{f}", .{node.name()});
        try eq(try full.findNode(writer.buffered()), try graph.findNode(writer.buffered()));
        if (partial) {
            var fm = other.mentions();
            var mentions = node.mentions();
            while (fm.next()) |mention| try eq(mention, mentions.next().?);
            try expect(mentions.next() == null);
        }
        for (0..g.nodes.len) |index| {
            const target: dot.ir.NodeId = @fromBackingInt(@as(u32, @intCast(index)));
            try eq(try full.hasEdge(node.id, target), try graph.hasEdge(node.id, target));
        }
        for (0..g.scopes.len) |index| {
            const id: dot.ir.ScopeId = @fromBackingInt(@as(u32, @intCast(index)));
            _ = try graph.scopeView(id);
            const members = try g.scopeMembership(id);
            try eq(try f.scopeMembership(id), members);
            try eq(try full.contains(members, node.id), try graph.contains(members, node.id));
        }
    }
    try expect(fnodes.next() == null);
    try std.testing.expectError(error.InvalidHandle, graph.nodeView(@fromBackingInt(std.math.maxInt(u32))));
    try std.testing.expectError(error.InvalidHandle, graph.scopeView(@fromBackingInt(std.math.maxInt(u32))));
    var expected = try full.materialize(.{ .attributes = false });
    defer expected.deinit();
    var actual = try graph.materialize(.{});
    defer actual.deinit();
    try eq(expected.edges, actual.edges);
    try eq(expected.peak_bytes, actual.peak_bytes);
    if (partial) {
        try eq(expected.state(), actual.state());
        var fe = expected.edgeIterator();
        var edges = actual.edgeIterator();
        while (fe.next()) |edge| {
            const other = edges.next().?;
            try eq(edge.edge, other.edge);
            try eq(edge.orientation(), other.orientation());
            try eq(edge.firstConnection(), other.firstConnection());
        }
        try expect(edges.next() == null);
    } else try eq(dot.ir.MaterializedTopology, @TypeOf(actual));
    var stream = try graph.edgeIterator(.{});
    defer stream.deinit();
    for (expected.edges) |edge| {
        const view = (try stream.next()).?;
        try eq(edge, view.edge);
        const checked = try graph.edgeView(edge);
        try eq(view.from().id, checked.from().id);
        try eq(view.to().id, checked.to().id);
    }
    try expect(try stream.next() == null);
    try expect(try stream.next() == null);
    var limited = try graph.materialize(.{ .limits = dot.ir.Limits{ .max_attributes = 0, .max_attribute_states = 0 } });
    defer limited.deinit();
    try eq(actual.edges, limited.edges);
}

test "topology operations match full IR across views queries symbolic sets and strict identity" {
    for (fixtures) |source| {
        var full = try Full.parse(a, source, .{});
        defer full.deinit();
        var lean = try Topology.parse(a, source, .{});
        defer lean.deinit();
        try compareOperations(full.ir().?, lean.ir().?);
    }
}

test "topology partial operations keep unknown answers orientation gaps and later facts" {
    for ([_][]const u8{
        "digraph {a->b;bad -> ;c->d;}",
        "strict graph {bad -> ;a:p--b:q;b:r--a:s;isolated}",
        "digraph {a->{b->c;} -> ;d->e;}",
        "digraph {subgraph s{b->c;",
        "digraph {b->c;unfinished[label=\"fake -> edge",
        "digraph {b->c;/* fake -> edge",
        "digraph {b->c;unfinished[label=<fake edge",
    }) |source| {
        var full = try Full.parsePartial(a, source, .{});
        defer full.deinit();
        var lean = try Topology.parsePartial(a, source, .{});
        defer lean.deinit();
        try compareOperations(full.ir().?, lean.ir().?);
        try expect(lean.ir().?.state() == .partial);
        try expect(try lean.ir().?.findNode("absent") == .unknown);
    }
    const Dot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .validation = .{ .graph = .{ .treated_as = .auto } } } });
    var parsed = Dot.parseAndValidate(a, "graph {a--b;c--d;", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var full = try Full.lowerPartial(a, doc, options);
    defer full.deinit();
    var lean = try Topology.lowerPartial(a, doc, options);
    defer lean.deinit();
    try compareOperations(&full, &lean);
    try expect(lean.kind() == .unknown);
}

fn compareSessions(full: anytype, graph: anytype) !void {
    for ([_]u32{ 1, 7, 64, 4096 }) |grant| {
        var left = try ScheduledFull.edgeSession(full, .{});
        defer left.deinit();
        var right = try Scheduled.edgeSession(graph, .{});
        defer right.deinit();
        var total: u64 = 0;
        while (true) {
            const zero = right.advance(0);
            try eq(@as(u32, 0), zero.work_used);
            try eq(total, zero.total_work);
            try expect(zero.edge == null);
            const p = right.advance(grant);
            const q = left.advance(grant);
            try expect(p.work_used <= grant);
            total += p.work_used;
            try eq(total, p.total_work);
            try eq(q.work_used, p.work_used);
            try eq(q.total_work, p.total_work);
            try eq(q.pairs_visited, p.pairs_visited);
            try eq(q.edges_emitted, p.edges_emitted);
            try eq(q.outcome, p.outcome);
            try eq(if (q.edge) |e| e.edge else null, if (p.edge) |e| e.edge else null);
            if (p.outcome != null) break;
        }
        try eq(left.peakBytes(), right.peakBytes());
        try expect(right.run().edge == null);
        var lm = try full.materializationSession(.{ .attributes = false });
        defer lm.deinit();
        var rm = try graph.materializationSession(.{});
        defer rm.deinit();
        const Engine = if (@hasField(@TypeOf(rm), "inner")) @FieldType(@TypeOf(rm), "inner") else @TypeOf(rm);
        try eq(void, @FieldType(Engine, "maps"));
        while (true) {
            try eq(@as(u32, 0), rm.advance(0).work_used);
            const p = rm.advance(grant);
            try eq(lm.advance(grant), p);
            try expect(p.work_used <= grant);
            if (p.outcome != null) break;
        }
        var expected = try lm.takeResult();
        defer expected.deinit();
        var actual = try rm.takeResult();
        defer actual.deinit();
        try eq(expected.edges, actual.edges);
        try eq(expected.peak_bytes, actual.peak_bytes);
        try std.testing.expectError(error.AlreadyTaken, rm.takeResult());
        const g = core(graph);
        if (g.nodes.len == 0) continue;
        const from: dot.ir.NodeId = @fromBackingInt(0);
        const to: dot.ir.NodeId = @fromBackingInt(@as(u32, @intCast(g.nodes.len - 1)));
        var lq = try ScheduledFull.hasEdgeSession(full, from, to, .{});
        defer lq.deinit();
        var rq = try Scheduled.hasEdgeSession(graph, from, to, .{});
        defer rq.deinit();
        while (true) {
            try eq(@as(u32, 0), rq.advance(0).work_used);
            const p = rq.advance(grant);
            try compareQueryProgress(lq.advance(grant), p);
            try expect(p.work_used <= grant);
            if (p.outcome != null) break;
        }
        try eq(try graph.hasEdge(from, to), rq.run().outcome.?.success);
        const members = try g.scopeMembership(.root);
        var lc = try ScheduledFull.containsSession(full, members, to, .{});
        defer lc.deinit();
        var rc = try Scheduled.containsSession(graph, members, to, .{});
        defer rc.deinit();
        while (true) {
            const p = rc.advance(grant);
            try compareQueryProgress(lc.advance(grant), p);
            try expect(p.work_used <= grant);
            if (p.outcome != null) break;
        }
        try eq(try graph.contains(members, to), rc.run().outcome.?.success);
    }
}

test "topology operation sessions preserve exact work partitions and avoid attribute state" {
    for (fixtures[0..5]) |source| {
        var full = try Full.parse(a, source, .{});
        defer full.deinit();
        var lean = try Topology.parse(a, source, .{});
        defer lean.deinit();
        try compareSessions(full.ir().?, lean.ir().?);
    }
    const source = "strict graph {a:p--b:q;bad -> ;{a b}--{c d};d--a}";
    var full = try Full.parsePartial(a, source, .{});
    defer full.deinit();
    var lean = try Topology.parsePartial(a, source, .{});
    defer lean.deinit();
    try compareSessions(full.ir().?, lean.ir().?);
}

test "topology native-encoding operations retain logical names and endpoint identity" {
    const NativeFull = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const text = "strict graph{\"a\"+\"b\":p:n--ab:q; subgraph s{x;y};ab--subgraph s{z}}";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width = comptime dot.encoding.unitBytes(actual);
        const big = actual == .utf16be or actual == .utf32be;
        var bytes: [text.len * width]u8 = @splat(0);
        for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        var full = try NativeFull.parse(a, &bytes, .{ .dot = .{ .encoding = actual } });
        defer full.deinit();
        var lean = try Native.parse(a, &bytes, .{ .dot = .{ .encoding = actual } });
        defer lean.deinit();
        try compareOperations(full.ir().?, lean.ir().?);
    }
}

fn compareFixed(graph: anytype) !void {
    const layout = try Topology.edgeScratchLayout(graph, try Topology.edgeScratchBounds(graph, .{}));
    const bytes = try a.alignedAlloc(u8, .@"16", layout.byte_size + 16);
    defer a.free(bytes);
    @memset(bytes, 0xcd);
    const memory = try layout.bind(bytes);
    var expected = try graph.materialize(.{});
    defer expected.deinit();
    // Change the allocator before lending the graph to operations, restoring
    // it before destroying retained storage. Fixed operations may not fall back.
    const mutable = @constCast(core(graph));
    const original = mutable.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    mutable.allocator = failing.allocator();
    defer mutable.allocator = original;
    {
        var stream = try graph.edgeIteratorIn(memory, .{});
        defer stream.deinit();
        for (expected.edges) |edge| try eq(edge, (try stream.next()).?.edge);
        try expect(try stream.next() == null);
        try expect(stream.shortfall() == null);
    }
    for ([_]u32{ 1, 64 }) |grant| {
        var session = try Scheduled.edgeSessionIn(graph, memory, .{});
        defer session.deinit();
        var count: usize = 0;
        while (true) {
            const p = session.advance(grant);
            try expect(p.work_used <= grant);
            if (p.edge) |edge| {
                try eq(expected.edges[count], edge.edge);
                count += 1;
            }
            if (p.outcome) |outcome| {
                try expect(outcome == .success);
                break;
            }
        }
        try eq(expected.edges.len, count);
        try expect(session.shortfall() == null);
    }
    for (bytes[layout.byte_size..]) |byte| try eq(@as(u8, 0xcd), byte);
    const alias_layout = try Topology.edgeScratchLayout(graph, .{ .members = 1 });
    const alias = try alias_layout.bind(@constCast(std.mem.sliceAsBytes(mutable.node_storage)));
    try std.testing.expectError(error.InvalidStorage, graph.edgeIteratorIn(alias, .{}));
    try std.testing.expectError(error.InvalidStorage, Scheduled.edgeSessionIn(graph, alias, .{}));
}

test "topology fixed edge scratch protects owners and requires no allocator" {
    var full = try Topology.parse(a, fixtures[2], .{});
    defer full.deinit();
    try compareFixed(full.ir().?);
    var partial = try Topology.parsePartial(a, "strict graph {a--b;bad -> ;{a b}--{c d}}", .{});
    defer partial.deinit();
    try compareFixed(partial.ir().?);
}

const Stop = struct {
    stop: bool = false,
    polls: usize = 0,
    fn requested(raw: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(raw.?));
        self.polls += 1;
        return self.stop;
    }
    fn hook(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "topology operation stops retain their causes and already emitted views" {
    var parsed = try Topology.parse(a, "strict digraph {a:p->b:q;a->b;{a b}->{c d}}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    const from = (try graph.findNode("a")).?;
    const to = (try graph.findNode("d")).?;
    try std.testing.expectError(error.WorkLimit, graph.hasEdgeWith(from, to, .{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.EdgeLimit, graph.materialize(.{ .limits = .{ .max_edges = 1 } }));
    try std.testing.expectError(error.PairLimit, graph.materialize(.{ .limits = .{ .max_pairs = 1 } }));
    try std.testing.expectError(error.MemoryLimit, graph.materialize(.{ .limits = .{ .max_bytes = 0 } }));
    var stop: Stop = .{};
    var stream = try graph.edgeIterator(.{ .cancellation = stop.hook() });
    defer stream.deinit();
    const first = (try stream.next()).?;
    stop.stop = true;
    try std.testing.expectError(error.Cancelled, stream.next());
    stop.stop = false;
    try std.testing.expectError(error.Cancelled, stream.next());
    try eq(from, first.from().id);
    // A fixed-pool shortfall is terminal, not exhaustion or an implicit restart.
    const layout = try Topology.edgeScratchLayout(graph, .{ .strict_pairs = 1 });
    var bytes: [128]u8 align(16) = undefined;
    const memory = try layout.bind(&bytes);
    {
        var fixed = try graph.edgeIteratorIn(memory, .{});
        defer fixed.deinit();
        const saved = (try fixed.next()).?;
        try std.testing.expectError(error.PoolExhausted, fixed.next());
        try eq(.members, fixed.shortfall().?.resource);
        try std.testing.expectError(error.PoolExhausted, fixed.next());
        try eq(from, saved.from().id);
    }
    var fixed = try Scheduled.edgeSessionIn(graph, memory, .{});
    defer fixed.deinit();
    try expect(fixed.run().edge != null);
    try eq(dot.ir.EdgeStreamingOutcome{ .failure = error.PoolExhausted }, fixed.run().outcome.?);
    try eq(@as(u32, 0), fixed.advance(1).work_used);

    const Runtime = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .runtime_policy = true });
    var runtime = try Runtime.edgeSession(graph, .{ .cancellation = stop.hook(), .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = 4 } } });
    defer runtime.deinit();
    _ = try runtime.advance(1);
    stop.stop = true;
    try eq(dot.ir.EdgeStreamingOutcome{ .failure = error.Cancelled }, (try runtime.advance(1)).outcome.?);
    stop.stop = false;
    try eq(@as(u32, 0), (try runtime.advance(1)).work_used);
    var query = try Scheduled.hasEdgeSession(graph, from, to, .{ .cancellation = stop.hook() });
    defer query.deinit();
    _ = query.advance(1);
    stop.stop = true;
    try expect(query.advance(1).outcome.?.failure == error.Cancelled);
    try eq(@as(u32, 0), query.advance(1).work_used);
    stop.stop = false;
    var materializer = try graph.materializationSession(.{ .cancellation = stop.hook() });
    defer materializer.deinit();
    _ = materializer.advance(1);
    stop.stop = true;
    try expect(materializer.advance(1).outcome.?.failure == error.Cancelled);
    try std.testing.expectError(error.Cancelled, materializer.takeResult());
}

fn allocationFailures(allocator: std.mem.Allocator, graph: *Topology.Graph) !void {
    const original = graph.allocator;
    graph.allocator = allocator;
    defer graph.allocator = original;
    var output = try graph.materialize(.{});
    defer output.deinit();
    var stream = try graph.edgeIterator(.{});
    defer stream.deinit();
    while (try stream.next()) |_| {}
    var session = try graph.materializationSession(.{});
    defer session.deinit();
    switch (session.run().outcome.?) {
        .failure => |err| return err,
        .success => {},
    }
    var result = try session.takeResult();
    defer result.deinit();
    try eq(output.edges, result.edges);
}

test "topology operations release scratch and unpublished materialization on allocation failure" {
    var parsed = try Topology.parse(a, fixtures[2], .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{@constCast(parsed.ir().?)});
}
