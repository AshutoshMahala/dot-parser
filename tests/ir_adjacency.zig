const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const eq = std.testing.expectEqualDeep;
const IR = dot.ir.Lowering(.{});
const Topology = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
const Selection = struct { attributes: bool, adjacency: dot.ir.Adjacency };

fn available(comptime selection: dot.ir.Adjacency, comptime direction: dot.ir.EdgeDirection) bool {
    return switch (selection) {
        .all => true,
        .forward => direction == .outgoing or direction == .undirected or direction == .forward,
        .backward => direction == .incoming or direction == .undirected or direction == .backward,
        .none => false,
    };
}
fn matches(edge: dot.ir.Edge, id: dot.ir.NodeId, direction: dot.ir.EdgeDirection) bool {
    const incident = edge.from == id or edge.to == id;
    return switch (direction) {
        .all => incident,
        .undirected => incident and edge.operator == .undirected,
        .outgoing => edge.from == id and edge.operator == .directed,
        .incoming => edge.to == id and edge.operator == .directed,
        .forward => if (edge.operator == .undirected) incident else edge.from == id,
        .backward => if (edge.operator == .undirected) incident else edge.to == id,
    };
}
fn verify(comptime selection: Selection, graph: anytype, materialized: anytype) !void {
    const partial = @hasField(@TypeOf(graph.*), "_coverage");
    if (partial) {
        try eq(graph.state(), materialized.state());
        try eq(graph.kind(), materialized.kind());
    }
    var nodes = materialized.nodeIterator();
    var count: u32 = 0;
    while (nodes.next()) |node| {
        try eq(count, @backingInt(node.id));
        count += 1;
        try expect(@TypeOf(node) == @TypeOf(try materialized.nodeView(node.id)));
        if (partial) {
            var actual_mentions = node.mentions();
            var expected_mentions = (try graph.nodeView(node.id)).mentions();
            while (expected_mentions.next()) |mention| try eq(mention, actual_mentions.next().?);
            try expect(actual_mentions.next() == null);
        }
        inline for (comptime std.meta.tags(dot.ir.EdgeDirection)) |direction| if (comptime available(selection.adjacency, direction)) {
            var actual = node.edges(.{ .direction = direction });
            var expected_count: u32 = 0;
            for (materialized.edges, 0..) |edge, index| {
                if (!matches(edge, node.id, direction)) continue;
                expected_count += 1;
                const entry = actual.next() orelse return error.MissingEdge;
                try eq(@as(u32, @intCast(index)), entry.index);
                try eq(edge, entry.edge().edge);
                try eq(if (edge.from == node.id) edge.to else edge.from, entry.neighbor().id);
                try expect(@TypeOf(entry.neighbor()) == @TypeOf(node));
                try expect(@TypeOf(entry.edge().from()) == @TypeOf(node));
                try expect(@TypeOf(entry.edge().to()) == @TypeOf(node));
                const flags = entry.directions();
                try eq(edge.operator == .undirected, flags.undirected);
                try eq(edge.operator == .directed and edge.from == node.id, flags.outgoing);
                try eq(edge.operator == .directed and edge.to == node.id, flags.incoming);
            }
            try expect(actual.next() == null);
            try expect(actual.next() == null);
            const n = node.edgeCount(.{ .direction = direction });
            if (partial) switch (n) {
                .known => |v| try eq(expected_count, v),
                .unknown => |u| try eq(expected_count, u.retained.?),
            } else try eq(expected_count, n);
        };
    }
    try eq(@as(u32, @intCast((if (partial) graph._data.nodes else graph.nodes).len)), count);
    try std.testing.expectError(error.InvalidHandle, materialized.nodeView(@fromBackingInt(count)));
    var edges = materialized.edgeIterator();
    while (edges.next()) |edge| {
        try expect(@TypeOf(edge.from()) == @TypeOf(nodes.next().?));
        if (partial) {
            const retained: @TypeOf(graph.*).EdgeView = .{ .graph = graph, .edge = edge.edge, .stored = {} };
            try eq(retained.orientation(), edge.orientation());
            try eq(retained.firstConnection(), edge.firstConnection());
        }
    }
}
fn check(comptime selection: Selection, graph: anytype) !void {
    var plain = try graph.materialize(.{ .attributes = selection.attributes });
    defer plain.deinit();
    var result = try graph.materialize(selection);
    defer result.deinit();
    try @import("ir_sessions.zig").compareResults(selection.attributes, &plain, &result);
    try verify(selection, graph, &result);
    var total: ?u64 = null;
    for ([_]u32{ 1, 7, 4096 }) |budget| {
        var session = try graph.materializationSession(selection);
        defer session.deinit();
        try std.testing.expectError(error.NotReady, session.takeResult());
        var used: u64 = 0;
        while (true) {
            try eq(@as(u32, 0), session.advance(0).work_used);
            const p = session.advance(budget);
            try expect(p.work_used <= budget);
            used += p.work_used;
            try eq(used, p.total_work);
            if (p.outcome) |outcome| {
                try eq(dot.ir.MaterializationOutcome.success, outcome);
                break;
            }
        }
        if (total) |n| try eq(n, used) else total = used;
        var resumed = try session.takeResult();
        defer resumed.deinit();
        try std.testing.expectError(error.AlreadyTaken, session.takeResult());
        session.cancel();
        try eq(@as(u32, 0), session.advance(1).work_used);
        try eq(result.edges, resumed.edges);
        try eq(result.capacities(), resumed.capacities());
        try verify(selection, graph, &resumed);
    }
}

fn Buffers(comptime selection: Selection) type {
    return struct {
        output: []align(16) u8,
        scratch: []align(16) u8,
        memory: IR.MaterializationMemory(selection),
        fn init(graph: anytype, counts: dot.ir.MaterializedCapacities, scratch: dot.ir.MaterializationScratchCapacities) !@This() {
            const layout = try IR.materializationLayout(graph, counts, scratch, selection);
            const out = try a.alignedAlloc(u8, .@"16", layout.output_bytes + 16);
            errdefer a.free(out);
            const temp = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
            errdefer a.free(temp);
            @memset(out, 0xcd);
            @memset(temp, 0xcd);
            return .{ .output = out, .scratch = temp, .memory = try layout.bind(out, temp) };
        }
        fn deinit(self: @This()) void {
            a.free(self.output);
            a.free(self.scratch);
        }
        fn canaries(self: @This()) !void {
            for (self.output[self.memory.output.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
            for (self.scratch[self.memory.scratch.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
        }
    };
}
fn checkFixed(comptime selection: Selection, graph: anytype) !void {
    var expected = try graph.materialize(selection);
    defer expected.deinit();
    const bounds = try IR.scanMaterializationBounds(graph, selection);
    const memory = try Buffers(selection).init(graph, expected.capacities(), bounds.scratch);
    defer memory.deinit();
    var direct = graph.materializeIn(memory.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, direct.outcome);
    try eq(expected.edges, direct.materialized.?.edges);
    try verify(selection, graph, &direct.materialized.?);
    try eq(memory.memory.output.bytes.len, direct.materialized.?.retainedBytes());
    try eq(memory.memory.output.bytes.len + memory.memory.scratch.bytes.len, direct.materialized.?.peak_bytes);
    direct.materialized.?.deinit();
    var total: ?u64 = null;
    for ([_]u32{ 1, 7, 4096 }) |budget| {
        var session = try graph.materializationSessionIn(memory.memory, .{});
        var consumed: u64 = 0;
        while (true) {
            const p = session.advance(budget);
            try expect(p.work_used <= budget);
            consumed += p.work_used;
            try eq(consumed, p.total_work);
            if (p.outcome) |outcome| {
                try eq(dot.ir.MaterializationOutcome.success, outcome);
                break;
            }
        }
        if (total) |value| try eq(value, consumed) else total = consumed;
        var result = try session.takeResult();
        session.deinit();
        defer result.deinit();
        @memset(memory.memory.scratch.bytes, 0x9f);
        try eq(expected.edges, result.edges);
        try eq(expected.capacities(), result.capacities());
        try verify(selection, graph, &result);
        try memory.canaries();
    }
    inline for (.{ "adjacency_offsets", "adjacency_entries" }) |field| short_pool: {
        var counts = expected.capacities();
        if (@field(counts, field) == 0) break :short_pool;
        @field(counts, field) -= 1;
        const short = try Buffers(selection).init(graph, counts, bounds.scratch);
        defer short.deinit();
        const failed = graph.materializeIn(short.memory, .{});
        try eq(error.PoolExhausted, failed.outcome.failure);
        try expect(failed.materialized == null);
        try eq(@field(dot.ir.Resource, field), failed.shortfall.?.resource);
        try eq(@field(counts, field), failed.shortfall.?.limit);
        try eq(@field(expected.capacities(), field), failed.shortfall.?.required_at_least);
        var session = try graph.materializationSessionIn(short.memory, .{});
        defer session.deinit();
        try eq(failed.outcome, session.run().outcome.?);
        try eq(failed.shortfall, session.shortfall());
        try std.testing.expectError(error.PoolExhausted, session.takeResult());
        try eq(@as(u32, 0), session.advance(1).work_used);
        try short.canaries();
    }
    const metadata = try IR.materializationBounds(graph, selection);
    const bounded = try Buffers(selection).init(graph, metadata.output, metadata.scratch);
    defer bounded.deinit();
    var from_bounds = graph.materializeIn(bounded.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, from_bounds.outcome);
    defer from_bounds.materialized.?.deinit();
    try verify(selection, graph, &from_bounds.materialized.?);
}
test "adjacency fixed exact pools, shortfalls and explicit bounds preserve complete and partial output" {
    inline for (.{ IR, Topology }) |Profile| for ([_][]const u8{
        "digraph {isolated}",
        "strict graph {edge[color=red];{a b}--{c d};a:p--c:q[label=new];b--b}",
    }) |source| {
        var parsed = try Profile.parse(a, source, .{});
        defer parsed.deinit();
        var partial = try Profile.parsePartial(a, source, .{});
        defer partial.deinit();
        inline for (.{ .forward, .backward, .all }) |direction| inline for (.{ parsed.ir().?, partial.ir().? }) |graph| {
            try checkFixed(.{ .attributes = false, .adjacency = direction }, graph);
            if (Profile.capabilities.attributes) try checkFixed(.{ .attributes = true, .adjacency = direction }, graph);
        };
    };
}
test "adjacency mixed operators keep disjoint categories and loop identity" {
    const P = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
    var parsed = P.parseAndValidate(a, "graph {a->b;b--c;c->b;b->b;b--b;a->b;isolated}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    var graph = try IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
    defer graph.deinit();
    inline for (.{ .forward, .backward, .all }) |direction| inline for (.{ false, true }) |attributes| {
        try check(.{ .attributes = attributes, .adjacency = direction }, &graph);
        try checkFixed(.{ .attributes = attributes, .adjacency = direction }, &graph);
    };
}
test "adjacency filters preserve edges, loops, parallel occurrences and order across direct and session paths" {
    const fixtures = [_][]const u8{
        "digraph {}",                                        "digraph {a;b;c}",
        "digraph {a->{b c}->{d e};x->b;a->b;b->b;isolated}", "strict digraph {a->b[color=red];a->b[label=new];b->a;b->b}",
        "graph {a--b;b--a;a--a;isolated}",                   "strict graph {a:p--b:q[color=red];b:r--a:s[label=new];a--a}",
    };
    inline for (.{ IR, Topology }) |Profile| for (fixtures) |source| {
        var parsed = try Profile.parse(a, source, .{});
        defer parsed.deinit();
        inline for (.{ .forward, .backward, .all }) |direction| {
            try check(.{ .attributes = false, .adjacency = direction }, parsed.ir().?);
            if (Profile.capabilities.attributes) try check(.{ .attributes = true, .adjacency = direction }, parsed.ir().?);
        }
    };
}
test "adjacency preserves partial uncertainty and later retained edges" {
    inline for (.{ IR, Topology }) |Profile| {
        var parsed = try Profile.parsePartial(a, "digraph {a->b; broken -> ; b->c;isolated}", .{});
        defer parsed.deinit();
        const graph = parsed.ir().?;
        try eq(.partial, graph.state());
        inline for (.{ .forward, .backward, .all }) |direction| {
            try check(.{ .attributes = false, .adjacency = direction }, graph);
            try checkFixed(.{ .attributes = false, .adjacency = direction }, graph);
            if (Profile.capabilities.attributes) try check(.{ .attributes = true, .adjacency = direction }, graph);
        }
        var result = try graph.materialize(.{ .attributes = false, .adjacency = .all });
        defer result.deinit();
        var nodes = result.nodeIterator();
        while (nodes.next()) |node| try expect(node.edgeCount(.{}) == .unknown);
    }
}

const Stop = struct {
    polls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.polls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};
test "adjacency session credits and cancellation include every row construction phase" {
    var parsed = try IR.parse(a, "strict graph {a:p--b:q[color=red];b--b;isolated}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    const selection: Selection = .{ .attributes = true, .adjacency = .all };
    var result = try graph.materialize(selection);
    defer result.deinit();
    const sizing = try IR.scanMaterializationBounds(graph, selection);
    const buffers = try Buffers(selection).init(graph, result.capacities(), sizing.scratch);
    defer buffers.deinit();
    inline for (.{ false, true }) |fixed| {
        var polls: Stop = .{};
        var finished = if (fixed) try graph.materializationSessionIn(buffers.memory, .{ .cancellation = polls.token() }) else try graph.materializationSession(.{ .adjacency = .all, .cancellation = polls.token() });
        defer finished.deinit();
        const done = finished.run();
        try eq(dot.ir.MaterializationOutcome.success, done.outcome.?);
        try eq(done.total_work + 1, polls.polls);
        // Explicit cancellation from a predicate must latch even when the
        // predicate returns false, including the final row transition.
        const Session = @TypeOf(finished);
        const CancelFalse = struct {
            session: ?*Session = null,
            polls: u64 = 0,
            at: u64,
            fn requested(context: ?*anyopaque) bool {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                self.polls += 1;
                if (self.polls == self.at) self.session.?.cancel();
                return false;
            }
        };
        for ([_]u64{ 2, done.total_work, done.total_work + 1 }) |at| {
            var stop: CancelFalse = .{ .at = at };
            const token: dot.ir.Cancellation = .{ .context = &stop, .is_requested = CancelFalse.requested };
            var session = if (fixed) try graph.materializationSessionIn(buffers.memory, .{ .cancellation = token }) else try graph.materializationSession(.{ .adjacency = .all, .cancellation = token });
            defer session.deinit();
            stop.session = &session;
            try eq(error.Cancelled, session.run().outcome.?.failure);
            try eq(at, stop.polls);
            try std.testing.expectError(error.Cancelled, session.takeResult());
            try eq(@as(u32, 0), session.advance(7).work_used);
        }
        for ([_]u32{ 1, 7, 4096 }) |budget| {
            for (1..polls.polls + 1) |at| {
                var stop: Stop = .{ .at = at };
                var session = (if (fixed) graph.materializationSessionIn(buffers.memory, .{ .cancellation = stop.token() }) else graph.materializationSession(.{ .adjacency = .all, .cancellation = stop.token() })) catch |err| {
                    try eq(error.Cancelled, err);
                    try eq(@as(usize, 1), at);
                    continue;
                };
                defer session.deinit();
                var p = session.advance(budget);
                while (p.outcome == null) p = session.advance(budget);
                try eq(error.Cancelled, p.outcome.?.failure);
                try eq(at, stop.polls);
                try std.testing.expectError(error.Cancelled, session.takeResult());
                try eq(@as(u32, 0), session.advance(0).work_used);
                try eq(at, stop.polls);
            }
        }
        var counter: Stop = .{};
        var session = if (fixed) try graph.materializationSessionIn(buffers.memory, .{ .cancellation = counter.token() }) else try graph.materializationSession(.{ .adjacency = .all, .cancellation = counter.token() });
        defer session.deinit();
        var zeros: u64 = 0;
        var turn: usize = 0;
        while (true) : (turn += 1) {
            const grant = ([_]u32{ 0, 1, 7, 64 })[turn % 4];
            const p = session.advance(grant);
            if (grant == 0) zeros += 1;
            try expect(p.work_used <= grant);
            try eq(p.total_work + zeros + 1, counter.polls);
            if (p.outcome != null) {
                try eq(dot.ir.MaterializationOutcome.success, p.outcome.?);
                break;
            }
        }
        var limited = if (fixed) try graph.materializationSessionIn(buffers.memory, .{ .limits = .{ .max_work = done.total_work - 1 } }) else try graph.materializationSession(.{ .adjacency = .all, .limits = .{ .max_work = done.total_work - 1 } });
        defer limited.deinit();
        const failed = limited.run();
        try eq(error.WorkLimit, failed.outcome.?.failure);
        try eq(done.total_work - 1, failed.total_work);
        try std.testing.expectError(error.WorkLimit, limited.takeResult());
    }
    try std.testing.expectError(error.MemoryLimit, graph.materialize(.{ .adjacency = .all, .limits = .{ .max_bytes = result.peak_bytes - 1 } }));
    const fixed_failed = graph.materializeIn(buffers.memory, .{ .limits = .{ .max_bytes = buffers.memory.output.bytes.len + buffers.memory.scratch.bytes.len - 1 } });
    try eq(error.MemoryLimit, fixed_failed.outcome.failure);
    try expect(fixed_failed.materialized == null);
    try buffers.canaries();
}
fn allocationCase(allocator: std.mem.Allocator, graph: *const IR.Graph) !void {
    var snapshot = graph.*;
    snapshot.allocator = allocator;
    var direct = try snapshot.materialize(.{ .adjacency = .all });
    defer direct.deinit();
    var session = try snapshot.materializationSession(.{ .adjacency = .all });
    defer session.deinit();
    const p = session.run();
    if (p.outcome.? == .failure) return p.outcome.?.failure;
    var result = try session.takeResult();
    defer result.deinit();
}
test "adjacency allocation failures free rows and materialized output" {
    var parsed = try IR.parse(a, "strict graph {{a b}--{c d}[color=red];a:p--c:q[label=x];b--b}", .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{parsed.ir().?});
}
test "adjacency named fixed helpers carry selection and reject aliases before writes" {
    const selection: Selection = .{ .attributes = false, .adjacency = .all };
    const Retained = IR.FixedGraphStorage(.{ .nodes = 8 });
    const Output = IR.FixedMaterializedStorage(.{ .edges = 8, .adjacency_offsets = 36, .adjacency_entries = 16 }, selection);
    const Scratch = IR.FixedMaterializationScratch(Retained, Output, .{ .members = 8 }, .{});
    var output: Output = .{};
    var scratch: Scratch = .{};
    const memory: IR.MaterializationMemory(selection) = .{ .output = output.storage(), .scratch = scratch.storage() };
    try expect(@TypeOf(memory.scratch) == IR.MaterializationScratch(selection));
    var parsed = try IR.parse(a, "graph {a--b;a--a}", .{});
    defer parsed.deinit();
    var graph = parsed.ir().?.*;
    graph.allocator = std.testing.failing_allocator;
    var result = graph.materializeIn(memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, result.outcome);
    try verify(selection, &graph, &result.materialized.?);
    result.materialized.?.deinit();
    var session = try graph.materializationSessionIn(memory, .{});
    defer session.deinit();
    try eq(dot.ir.MaterializationOutcome.success, session.run().outcome.?);
    var built = try session.takeResult();
    try verify(selection, &graph, &built);
    // An attribute session must reject all reserved adjacency bytes, including
    // unused row capacity, before its scratch can overwrite the result.
    const Metered = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    const alias_layout = try Metered.attributeScratchLayout(.{ .winners = 1 });
    const alias_memory = try alias_layout.bind(memory.output.bytes[memory.output.bytes.len - 16 ..]);
    var nodes = built.nodeIterator();
    const node = nodes.next().?;
    try std.testing.expectError(error.InvalidStorage, Metered.attributesSessionIn(node, alias_memory, .{}));
    try std.testing.expectError(error.InvalidStorage, node.attributesIn(alias_memory, .{}));
    built.deinit();
    @memset(&output.bytes, 0xcd);
    @memset(&scratch.bytes, 0xcd);
    var bad = memory;
    bad.scratch.bytes = &output.bytes;
    const rejected = graph.materializeIn(bad, .{});
    try eq(error.InvalidStorage, rejected.outcome.failure);
    try expect(rejected.materialized == null);
    try std.testing.expectError(error.InvalidStorage, graph.materializationSessionIn(bad, .{}));
    for (output.bytes) |b| try eq(@as(u8, 0xcd), b);
    try std.testing.expectError(error.InvalidStorage, IR.materializationLayout(&graph, .{ .adjacency_entries = 1 }, .{}, .{ .attributes = false }));
    try expect(IR.Graph.Materialized == IR.Graph.MaterializedFor(.{ .attributes = true }));
    try expect(dot.ir.MaterializedTopology == IR.Graph.MaterializedFor(.{ .attributes = false }));
}

test "adjacency views reuse complete and partial attribute sessions and ports" {
    const Profile = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    var parsed = try Profile.parse(a, "strict graph {node[color=red];a:p--b:q[color=red];b:r--a:s[label=updated];a--a}", .{});
    defer parsed.deinit();
    var partial = try Profile.parsePartial(a, "strict graph {node[color=red];a:p--b:q;color=green;bad->;b:r--a:s[label=updated]}", .{});
    defer partial.deinit();
    inline for (.{ parsed.ir().?, partial.ir().? }) |graph| inline for (.{ false, true }) |attributes| {
        var result = try graph.materialize(.{ .attributes = attributes, .adjacency = .all });
        defer result.deinit();
        var edges = result.edgeIterator();
        while (edges.next()) |edge| {
            var lookup = try Profile.attributeSession(edge, "tailport", .{});
            defer lookup.deinit();
            var p = lookup.advance(1);
            while (p.outcome == null) p = lookup.advance(1);
            const expected = try edge.attributeWith("tailport", .{});
            try eq(expected, p.outcome.?.success);
            try eq(try edge.tailPortWith(.{}), if (attributes) edge.tailPort() else try edge.tailPort());
            try eq(try edge.headPortWith(.{}), if (attributes) edge.headPort() else try edge.headPort());
            var source = try Profile.attributeSession(edge.from(), "color", .{});
            defer source.deinit();
            try eq(edge.from().attribute("color"), source.run().outcome.?.success);
            var direct = try edge.attributesWith(.{});
            defer if (!attributes) direct.deinit();
            var all = try Profile.attributesSession(edge, .{});
            defer all.deinit();
            while (true) {
                const progress = all.run();
                if (progress.attribute) |value| try eq((try direct.next()).?, value);
                if (progress.outcome) |outcome| {
                    try eq(.success, outcome);
                    break;
                }
            }
            try expect(try direct.next() == null);
        }
    };
}
test "adjacency retains native encoded names and borrowed value views" {
    inline for (.{ .utf16, .utf32 }) |family| {
        const P = dot.Profile(.{ .source_encodings = &.{family} });
        const Native = dot.ir.Lowering(.{ .source_encodings = &.{family} });
        var encoded: std.Io.Writer.Allocating = .init(a);
        defer encoded.deinit();
        for ("strict digraph {node[color=red];a:p->b:q[label=hello];a->a;isolated}") |byte|
            try encoded.writer.writeInt(if (family == .utf16) u16 else u32, byte, .little);
        var parsed = try P.parseAndValidate(a, encoded.written(), dot.diagnostic.discard, .{ .encoding = if (family == .utf16) .utf16le else .utf32le });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        var graph = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer graph.deinit();
        try check(.{ .attributes = true, .adjacency = .all }, &graph);
        try checkFixed(.{ .attributes = true, .adjacency = .all }, &graph);
    }
}
