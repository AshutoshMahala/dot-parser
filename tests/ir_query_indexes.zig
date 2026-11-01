const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const Dot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
const base_source =
    "strict graph { edge[color=red]; a:p--b:q;edge[color=blue];b:r--a:s[label=updated];" ++
    "a--c;c--d;d--e;e--f;f--g;g--h;h--i;i--j;j--k;k--l;" ++
    "subgraph s{x}--a;subgraph s{y}--b;{c d}--{e f};{}--x;isolated;";

fn data(graph: anytype) @TypeOf(if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph) {
    return if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph;
}
fn same(expected: anytype, actual: anytype) !void {
    const x = data(expected);
    const y = data(actual);
    inline for (.{ "nodes", "scopes", "occurrences", "mentions", "connections", "endpoint_ports", "bodies", "posting_offsets", "posting_positions" }) |field| try eq(@field(x, field), @field(y, field));
    if (@TypeOf(x.*).capabilities.attributes) {
        try eq(x.attributes, y.attributes);
        try eq(x.declarations, y.declarations);
    }
    for (x.scopes, 0..) |_, i| {
        const scope: dot.ir.ScopeId = @fromBackingInt(@as(u32, @intCast(i)));
        try eq(try x.scopeMembership(scope), try y.scopeMembership(scope));
    }
    for (x.nodes, 0..) |_, i| for (x.nodes, 0..) |_, j| {
        const from: dot.ir.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
        const to: dot.ir.NodeId = @fromBackingInt(@as(u32, @intCast(j)));
        try eq(try expected.hasEdge(from, to), try actual.hasEdge(from, to));
    };
    var edges = try x.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |edge| {
        if (@TypeOf(x.*).capabilities.attributes) {
            inline for (.{ "color", "label", "tailport", "headport", "absent" }) |key| try eq(try x.edgeAttribute(edge.edge, key), try y.edgeAttribute(edge.edge, key));
            const view = try y.edgeView(edge.edge);
            var left = try edge.attributes(.{});
            defer left.deinit();
            var right = try view.attributes(.{});
            defer right.deinit();
            while (try left.next()) |value| try eq(value.resolved, (try right.next()).?.resolved);
            try eq(null, try right.next());
        }
    }
}

test "indexes are optional representation choices independent of execution" {
    const Off = dot.ir.Lowering(.{});
    const Explicit = dot.ir.Lowering(.{ .indexes = .{} });
    const On = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true } });
    const Session = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true } } });
    try expect(Off.Graph == Explicit.Graph);
    try expect(On.Graph == Session.Graph);
    try expect(On.Graph != Off.Graph);
    try expect(@FieldType(Off.Graph, "_storage") == usize);
    try std.testing.expectError(error.InvalidStorage, Off.loweringLayout(.{ .left_entries = 1 }, .{}));
    try std.testing.expectError(error.InvalidStorage, Off.loweringLayout(.{ .scope_memberships = 1 }, .{}));
}

test "complete partial full topology and independent indexes agree with scans" {
    inline for (.{ true, false }) |attributes| inline for (.{ false, true }) |partial| inline for (.{
        dot.ir.Indexes{ .connections = true },
        dot.ir.Indexes{ .scope_memberships = true },
        dot.ir.Indexes{ .connections = true, .scope_memberships = true },
    }) |indexes| {
        const Base = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes } });
        const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes }, .indexes = indexes, .policy = .{ .execution = .{ .metering = true } } });
        var parsed = Dot.parseAndValidate(a, base_source ++ (if (partial) "broken--;after--last;" else "") ++ "}", dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
        var baseline = if (partial) try Base.lowerPartial(a, doc, options) else try Base.lowerComplete(a, doc, options);
        defer baseline.deinit();
        var direct = if (partial) try IR.lowerPartial(a, doc, options) else try IR.lowerComplete(a, doc, options);
        defer direct.deinit();
        try same(&baseline, &direct);
        const indexed = data(&direct);
        if (indexes.connections) {
            try expect(indexed.queryIndexes().*.left_entries.len == indexed.connections.len);
            try expect(indexed.queryIndexes().*.right_entries.len == indexed.connections.len);
        }
        if (indexes.scope_memberships) try eq(indexed.scopes.len, indexed.queryIndexes().*.scope_memberships.len);

        var total: ?u64 = null;
        for ([_]u32{ 1, 7, 4096 }) |budget| {
            var session = if (partial) try IR.partialLoweringSession(a, doc, options) else try IR.loweringSession(a, doc, options);
            defer session.deinit();
            var used: u64 = 0;
            while (true) {
                const zero = session.advance(0);
                try eq(@as(u32, 0), zero.work_used);
                try eq(used, zero.total_work);
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                used += progress.work_used;
                try eq(used, progress.total_work);
                if (progress.outcome) |outcome| {
                    try eq(dot.ir.LoweringOutcome.success, outcome);
                    break;
                }
            }
            if (total) |previous| try eq(previous, used) else total = used;
            var graph = try session.takeResult();
            defer graph.deinit();
            try same(&direct, &graph);
            try eq(indexed.queryIndexes().*, data(&graph).queryIndexes().*);
        }
    };
}

test "symbolic and tiny graphs do not allocate connection index arrays" {
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true } });
    for ([_][]const u8{ "digraph{}", "digraph{a->b}", "digraph{{a b}->{c d};{a b}->{c d};{a b}->{c d};{a b}->{c d};{a b}->{c d};{a b}->{c d};{a b}->{c d};{a b}->{c d}}" }) |source| {
        var result = try IR.parse(a, source, .{});
        defer result.deinit();
        const graph = result.ir().?;
        try eq(@as(usize, 0), graph.queryIndexes().*.left_offsets.len);
        try eq(@as(usize, 0), graph.queryIndexes().*.right_offsets.len);
        try eq(@as(usize, 0), graph.queryIndexes().*.left_entries.len);
        try eq(@as(usize, 0), graph.queryIndexes().*.right_entries.len);
    }
}

fn Storage(comptime IR: type) type {
    return struct {
        retained: []align(16) u8,
        scratch: []align(16) u8,
        bound: IR.LoweringMemory,
        fn init(counts: dot.ir.GraphCapacities, temporary: dot.ir.LoweringScratchCapacities) !@This() {
            const layout = try IR.loweringLayout(counts, temporary);
            const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes + 16);
            errdefer a.free(retained);
            const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
            @memset(retained, 0xcd);
            @memset(scratch, 0xcd);
            return .{ .retained = retained, .scratch = scratch, .bound = try layout.bind(retained, scratch) };
        }
        fn canaries(self: @This()) !void {
            for (self.retained[self.bound.graph.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
            for (self.scratch[self.bound.scratch.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
        }
        fn deinit(self: @This()) void {
            a.free(self.retained);
            a.free(self.scratch);
        }
    };
}
fn done(session: anytype, budget: u32) !u64 {
    var used: u64 = 0;
    while (true) {
        const zero = session.advance(0);
        try eq(@as(u32, 0), zero.work_used);
        try eq(used, zero.total_work);
        const p = session.advance(budget);
        try expect(p.work_used <= budget);
        used += p.work_used;
        try eq(used, p.total_work);
        if (p.outcome) |o| {
            if (o == .failure) return o.failure;
            break;
        }
    }
    try eq(@as(u32, 0), session.run().work_used);
    return used;
}

test "indexed fixed lowering exact fits bounds and each pool shortfall" {
    inline for (.{ true, false }) |attributes| inline for (.{ false, true }) |partial| {
        const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes }, .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true } } });
        var parsed = Dot.parseAndValidate(a, base_source ++ (if (partial) "broken--;after--last;" else "") ++ "}", dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
        var direct = if (partial) try IR.lowerPartial(a, doc, options) else try IR.lowerComplete(a, doc, options);
        defer direct.deinit();
        const counts = direct.capacities();
        const fixed_options = .{ .interpretation = options.interpretation, .query_allocator = a };
        const bounds = if (partial) try IR.partialLoweringBounds(doc.capacities(), options) else try IR.loweringBounds(doc.capacities(), options);
        const exact = try Storage(IR).init(counts, bounds.scratch);
        defer exact.deinit();
        const fixed = if (partial) IR.lowerPartialIn(doc, exact.bound, fixed_options) else IR.lowerCompleteIn(doc, exact.bound, fixed_options);
        try eq(dot.ir.LoweringOutcome.success, fixed.outcome);
        try same(&direct, &fixed.graph.?);
        try eq(data(&direct).queryIndexes().*, data(&fixed.graph.?).queryIndexes().*);
        try exact.canaries();

        for ([_]u32{ 1, 17 }) |budget| {
            var session = if (partial) try IR.partialLoweringSessionIn(doc, exact.bound, fixed_options) else try IR.loweringSessionIn(doc, exact.bound, fixed_options);
            defer session.deinit();
            _ = try done(&session, budget);
            var graph = try session.takeResult();
            defer graph.deinit();
            try same(&direct, &graph);
            try eq(data(&direct).queryIndexes().*, data(&graph).queryIndexes().*);
            try exact.canaries();
        }
        const bounded = try Storage(IR).init(bounds.graph, bounds.scratch);
        defer bounded.deinit();
        const result = if (partial) IR.lowerPartialIn(doc, bounded.bound, options) else IR.lowerCompleteIn(doc, bounded.bound, options);
        try eq(dot.ir.LoweringOutcome.success, result.outcome);
        try eq(counts, result.graph.?.capacities());
        inline for (.{ "left_offsets", "right_offsets", "left_entries", "right_entries", "scope_memberships" }) |field| {
            var reduced = counts;
            try expect(@field(counts, field) > 0);
            @field(reduced, field) -= 1;
            const memory = try Storage(IR).init(reduced, bounds.scratch);
            defer memory.deinit();
            const short = if (partial) IR.lowerPartialIn(doc, memory.bound, options) else IR.lowerCompleteIn(doc, memory.bound, options);
            try eq(dot.ir.LoweringOutcome{ .failure = error.PoolExhausted }, short.outcome);
            try expect(short.graph == null);
            try eq(@field(dot.ir.Resource, field), short.shortfall.?.resource);
            try eq(@field(counts, field), short.shortfall.?.required_at_least);
            try eq(@field(reduced, field), short.shortfall.?.limit);
            var session = if (partial) try IR.partialLoweringSessionIn(doc, memory.bound, options) else try IR.loweringSessionIn(doc, memory.bound, options);
            defer session.deinit();
            try std.testing.expectError(error.PoolExhausted, done(&session, 1));
            try eq(short.shortfall, session.shortfall());
            try std.testing.expectError(error.PoolExhausted, session.takeResult());
            try memory.canaries();
        }
    };
}

fn compareQuery(comptime IR: type, graph: anytype, from: dot.ir.NodeId, to: dot.ir.NodeId) !void {
    const expected = try graph.hasEdge(from, to);
    var total: ?u64 = null;
    for ([_]u32{ 1, 2, 7, 4096 }) |budget| {
        var session = try IR.hasEdgeSession(graph, from, to, .{});
        defer session.deinit();
        const used = try done(&session, budget);
        try eq(expected, session.run().outcome.?.success);
        if (total) |n| try eq(n, used) else total = used;
    }
}
test "indexed query and attribute sessions preserve budgets answers and partial uncertainty" {
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true } } });
    inline for (.{ false, true }) |partial| {
        var parsed = if (partial) try IR.parsePartial(a, base_source ++ "broken--;after--last;}", .{}) else try IR.parse(a, base_source ++ "}", .{});
        defer parsed.deinit();
        const graph = parsed.ir().?;
        const g = data(graph);
        for (g.nodes, 0..) |_, i| for (g.nodes, 0..) |_, j| try compareQuery(IR, graph, @fromBackingInt(@as(u32, @intCast(i))), @fromBackingInt(@as(u32, @intCast(j))));
        var edges = try graph.edgeIterator(.{});
        defer edges.deinit();
        while (try edges.next()) |entry| {
            const edge = entry;
            inline for (.{ "color", "label", "tailport", "headport", "absent" }) |key| {
                const expected = try edge.attribute(key);
                var total: ?u64 = null;
                for ([_]u32{ 1, 7, 4096 }) |budget| {
                    var session = try IR.attributeSession(edge, key, .{});
                    defer session.deinit();
                    const used = try done(&session, budget);
                    const got = session.run().outcome.?.success;
                    if (partial) {
                        try eq(std.meta.activeTag(expected), std.meta.activeTag(got));
                        if (expected == .unknown) try eq(expected.unknown.uncertainty, got.unknown.uncertainty);
                        const x = switch (expected) {
                            .known => |v| v,
                            .unknown => |v| v.retained,
                        };
                        const y = switch (got) {
                            .known => |v| v,
                            .unknown => |v| v.retained,
                        };
                        try eq(if (x) |v| v.resolved else null, if (y) |v| v.resolved else null);
                    } else try eq(if (expected) |v| v.resolved else null, if (got) |v| v.resolved else null);
                    if (total) |n| try eq(n, used) else total = used;
                }
            }
        }
    }
}

const AttributeFact = struct { value: ?dot.ir.ResolvedAttribute, uncertainty: ?dot.ir.Uncertainty = null };
fn fact(entry: anytype) AttributeFact {
    if (@hasField(@TypeOf(entry), "resolved")) return .{ .value = entry.resolved };
    return switch (entry) {
        .known => |v| .{ .value = v.resolved },
        .unknown => |v| .{ .value = if (v.retained) |retained| retained.resolved else null, .uncertainty = v.uncertainty },
    };
}
fn enumeration(session: anytype, budget: u32, expected: []const AttributeFact) !u64 {
    var used: u64 = 0;
    var count: usize = 0;
    while (true) {
        const p = session.advance(budget);
        try expect(p.work_used <= budget);
        used += p.work_used;
        try eq(used, p.total_work);
        if (p.attribute) |entry| {
            try expect(count < expected.len);
            try eq(expected[count], fact(entry));
            count += 1;
        }
        if (p.outcome) |outcome| {
            if (outcome == .failure) return outcome.failure;
            break;
        }
    }
    try eq(expected.len, count);
    try eq(@as(u32, 0), session.run().work_used);
    return used;
}
test "all-attribute and fixed-scratch sessions use the same indexed history" {
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true }, .policy = .{ .execution = .{ .metering = true } } });
    inline for (.{ false, true }) |partial| {
        var result = if (partial) try IR.parsePartial(a, base_source ++ "broken--;after--last;}", .{}) else try IR.parse(a, base_source ++ "}", .{});
        defer result.deinit();
        const graph = result.ir().?;
        const layout = try IR.attributeScratchLayout(IR.attributeScratchBounds(graph));
        const bytes = try a.alignedAlloc(u8, .@"16", layout.byte_size);
        defer a.free(bytes);
        const memory = try layout.bind(bytes);
        var edges = try graph.edgeIterator(.{});
        defer edges.deinit();
        while (try edges.next()) |edge| {
            var expected: std.ArrayList(AttributeFact) = .empty;
            defer expected.deinit(a);
            var iterator = try edge.attributes(.{});
            defer iterator.deinit();
            while (try iterator.next()) |entry| try expected.append(a, fact(entry));
            var total: ?u64 = null;
            for ([_]u32{ 1, 7, 4096 }) |budget| {
                var heap = try IR.attributesSession(edge, .{});
                defer heap.deinit();
                const used = try enumeration(&heap, budget, expected.items);
                if (total) |n| try eq(n, used) else total = used;
                var fixed = try IR.attributesSessionIn(edge, memory, .{});
                defer fixed.deinit();
                _ = try enumeration(&fixed, budget, expected.items);
            }
        }
    }
}

const Stop = struct {
    calls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    work: ?*const u64 = null,
    previous: u64 = 0,
    max_gap: u64 = 0,
    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.work) |w| {
            self.max_gap = @max(self.max_gap, w.* - self.previous);
            self.previous = w.*;
        }
        return self.calls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};
test "index construction and routing remain cancellable at every charged step" {
    const C = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var parsed = Dot.parseAndValidate(a, base_source ++ "}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const interpretation = Dot.interpretation(doc, .{});
    var reference = try C.loweringSession(a, doc, .{ .interpretation = interpretation });
    defer reference.deinit();
    const total = reference.run().total_work;
    for (2..@as(usize, @intCast(total + 2))) |at| {
        var stop: Stop = .{ .at = at };
        var session = try C.loweringSession(a, doc, .{ .interpretation = interpretation, .cancellation = stop.token() });
        defer session.deinit();
        const p = session.run();
        try eq(error.Cancelled, p.outcome.?.failure);
        try eq(@as(u64, at - 2), p.total_work);
        try std.testing.expectError(error.Cancelled, session.takeResult());
        try eq(@as(u32, 0), session.advance(0).work_used);
        try eq(@as(u64, at), stop.calls);
    }
    for ([_]u64{ 0, 1, total - 1, total }) |limit| {
        var session = try C.loweringSession(a, doc, .{ .interpretation = interpretation, .limits = .{ .max_work = limit } });
        defer session.deinit();
        const p = session.run();
        try eq(limit, p.total_work);
        if (limit == total) try eq(dot.ir.LoweringOutcome.success, p.outcome.?) else try eq(error.WorkLimit, p.outcome.?.failure);
    }
    var graph = try reference.takeResult();
    defer graph.deinit();
    const from = (try graph.findNode("a")).?;
    const to = (try graph.findNode("isolated")).?;
    var query = try C.hasEdgeSession(&graph, from, to, .{});
    defer query.deinit();
    const query_total = query.run().total_work;
    for (2..@as(usize, @intCast(query_total + 2))) |at| {
        var stop: Stop = .{ .at = at };
        var session = try C.hasEdgeSession(&graph, from, to, .{ .cancellation = stop.token() });
        defer session.deinit();
        try eq(error.Cancelled, session.run().outcome.?.failure);
        try eq(@as(u64, at - 2), session.total_work);
    }
    const R = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true }, .runtime_policy = true, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    for ([_]u32{ 1, 3, 64 }) |interval| for ([_]u32{ 1, 7, 4096 }) |budget| {
        var stop: Stop = .{};
        var session = try R.hasEdgeSession(&graph, from, to, .{ .policy = .{ .execution = .{ .cancellation_interval = interval } }, .cancellation = stop.token() });
        defer session.deinit();
        stop.work = &session.total_work;
        var total_used: u64 = 0;
        while (true) {
            const p = try session.advance(budget);
            try expect(p.work_used <= budget);
            total_used += p.work_used;
            if (p.outcome) |o| {
                try eq(false, o.success);
                break;
            }
        }
        try eq(query_total, total_used);
        try expect(stop.max_gap <= interval);
    };
}

fn allocationProbe(allocator: std.mem.Allocator, doc: *const dot.Document) !void {
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true } } });
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var direct = try IR.lowerComplete(allocator, doc, options);
    defer direct.deinit();
    var session = try IR.loweringSession(allocator, doc, options);
    defer session.deinit();
    if (session.run().outcome.? == .failure) return session.run().outcome.?.failure;
    var graph = try session.takeResult();
    defer graph.deinit();
}
test "index allocation failures publish no graph and leak no retained pools" {
    var parsed = Dot.parseAndValidate(a, base_source ++ "}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{&parsed.document.?});
}

test "native source encodings share index semantics" {
    const IR = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .indexes = .{ .connections = true, .scope_memberships = true } });
    const text = base_source ++ "}";
    var utf8 = try IR.parse(a, text, .{});
    defer utf8.deinit();
    inline for (.{ u16, u32 }) |Unit| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        try source.writer.writeInt(Unit, 0xfeff, .little);
        for (text) |byte| try source.writer.writeInt(Unit, byte, .little);
        var parsed = try IR.parse(a, source.written(), .{});
        defer parsed.deinit();
        const graph = parsed.ir().?;
        try eq(utf8.ir().?.queryIndexes().*, graph.queryIndexes().*);
        try expect(try graph.hasEdge((try graph.findNode("a")).?, (try graph.findNode("b")).?));
    }
}

test "indexed histories agree with scans for varied sets ports and defaults" {
    const Base = dot.ir.Lowering(.{});
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true } });
    var random = std.Random.DefaultPrng.init(0x5011d);
    for (0..32) |round| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        const op = if (round % 2 == 0) "->" else "--";
        try source.writer.print("{s}{s}{{edge[color=red];", .{ if (round % 4 < 2) "strict " else "", if (round % 2 == 0) "digraph" else "graph" });
        for (0..48) |i| {
            const x = random.random().uintLessThan(u32, 12);
            const y = random.random().uintLessThan(u32, 12);
            switch (i % 6) {
                0 => try source.writer.print("n{d}:p{s}n{d}:q[color=c{d}];", .{ x, op, y, i }),
                1 => try source.writer.print("{{n{d} n{d}}}{s}n{d};", .{ x, y, op, y }),
                2 => try source.writer.print("subgraph s{{n{d}}}{s}{{n{d} n0}}[label=v{d}];", .{ x, op, y, i }),
                3 => try source.writer.print("edge[color=c{d}];n{d}{s}n{d}[tailport=\"t:n\"]", .{ i, y, op, x }),
                4 => try source.writer.print("{{}}{s}n{d};", .{ op, x }),
                else => try source.writer.print("n{d}{s}{{n{d} n0}}[headport=\"\"]", .{ x, op, y }),
            }
        }
        try source.writer.writeAll("isolated}");
        var parsed = Dot.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        const doc = &parsed.document.?;
        const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
        var baseline = try Base.lowerComplete(a, doc, options);
        defer baseline.deinit();
        var graph = try IR.lowerComplete(a, doc, options);
        defer graph.deinit();
        try same(&baseline, &graph);
    }
}

test "index payload is accounted and cannot be borrowed as query scratch" {
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true } } });
    const Base = dot.ir.Lowering(.{});
    var parsed = Dot.parseAndValidate(a, base_source ++ "}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var baseline = try Base.lowerComplete(a, doc, options);
    defer baseline.deinit();
    var graph = try IR.lowerComplete(a, doc, options);
    defer graph.deinit();
    const payload = 4 * (2 * (graph.nodes.len + 1 + graph.connections.len) + graph.scopes.len);
    try eq(baseline.retainedBytes() + payload, graph.retainedBytes());
    try std.testing.expectError(error.MemoryLimit, IR.lowerComplete(a, doc, .{ .interpretation = options.interpretation, .limits = .{ .max_bytes = graph.peak_bytes - 1 } }));
    var exact = try IR.lowerComplete(a, doc, .{ .interpretation = options.interpretation, .limits = .{ .max_bytes = graph.peak_bytes } });
    defer exact.deinit();
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    inline for (.{ "left_offsets", "right_offsets", "left_entries", "right_entries", "scope_memberships" }) |field| {
        const bytes = std.mem.sliceAsBytes(@field(graph.queryIndexes().*, field));
        const checksum = std.hash.Wyhash.hash(0, bytes);
        const scratch = try (try IR.attributeScratchLayout(.{ .winners = 1 })).bind(bytes);
        try std.testing.expectError(error.InvalidStorage, edge.attributesIn(scratch, .{}));
        try std.testing.expectError(error.InvalidStorage, IR.attributesSessionIn(edge, scratch, .{}));
        try eq(checksum, std.hash.Wyhash.hash(0, bytes));
    }
    // Contains uses membership postings, independently of connection routing.
    const node = (try graph.findNode("a")).?;
    const root = try graph.scopeMembership(@fromBackingInt(0));
    var contains = try IR.containsSession(&graph, root, node, .{});
    defer contains.deinit();
    _ = try done(&contains, 1);
    try eq(true, contains.run().outcome.?.success);
}

test "indexed generic graphs preserve directed orientation and reject forged edge handles" {
    const P = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
    const IR = dot.ir.Lowering(.{ .indexes = .{ .connections = true }, .policy = .{ .execution = .{ .metering = true } } });
    var parsed = P.parseAndValidate(a, "graph{a->b[x=1];b--c;c->d;d--e;e->f;f--g;g->h;h--i;a->b[x=2]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = P.interpretation(doc, .{}) };
    var baseline = try dot.ir.Lowering(.{}).lowerComplete(a, doc, options);
    defer baseline.deinit();
    var graph = try IR.lowerComplete(a, doc, options);
    defer graph.deinit();
    try same(&baseline, &graph);
    // A valid pair does not make a caller-supplied, unrelated contribution valid.
    const bad: dot.ir.Edge = .{ .from = (try graph.findNode("a")).?, .to = (try graph.findNode("b")).?, .operator = .directed, .first_connection = @fromBackingInt(4) };
    const view = try graph.edgeView(bad);
    try std.testing.expectError(error.InvalidHandle, view.attribute("absent"));
    var query = try IR.attributeSession(view, "absent", .{});
    defer query.deinit();
    try eq(error.InvalidHandle, query.run().outcome.?.failure);
}
