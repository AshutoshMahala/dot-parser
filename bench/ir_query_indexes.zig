//! Explicit index construction cost and repeated symbolic-query savings.
//! Parsing, handle lookup and query preparation are outside timings.
const std = @import("std");
const dot = @import("dot_parser");
const Dot = dot.Profile(.{});
const Case = enum { chain, star, one_sided_sets, mixed_sets, reopened, same_pair, product, scopes };
const Query = struct { from: dot.ir.NodeId, to: dot.ir.NodeId, scope: dot.ir.ScopeId, edge: ?dot.ir.Edge };
const Operation = enum { has_edge, attribute, attributes, scope };

fn fixture(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll("strict digraph{edge[color=red];");
    switch (case) {
        .chain => for (0..8000) |i| try out.print("n{d}->n{d}[label=x];", .{ i, i + 1 }),
        .star => for (0..8000) |i| try out.print("a->n{d}[label=x];", .{i}),
        .one_sided_sets => for (0..2000) |i| try out.print("n{d}->{{a b c d}}[color=blue];", .{i}),
        .mixed_sets => for (0..8000) |i| {
            if (i % 20 == 0) try out.print("{{n{d} a}}->{{b c}}[color=blue];", .{i}) else try out.print("n{d}->n{d};", .{ i, i + 1 });
        },
        .reopened => for (0..1000) |i| try out.print("subgraph s{{a n{d}}}->x[color=c{d}];", .{ i, i }),
        .same_pair => for (0..4000) |i| try out.print("a->b[color=c{d}];", .{i}),
        .product => {
            try out.writeAll("{");
            for (0..50000) |i| try out.print("n{d};", .{i});
            try out.writeAll("}->{");
            for (50000..100000) |i| try out.print("n{d};", .{i});
            try out.writeAll("};");
        },
        .scopes => for (0..4000) |i| try out.print("subgraph s{d}{{n{d}}}", .{ i, i }),
    }
    try out.writeAll("absent}");
}
fn member(graph: anytype, members: dot.ir.Membership, position: usize) dot.ir.NodeId {
    const raw = @backingInt(members);
    const node_bit: u32 = 1 << 31;
    if (raw & node_bit != 0) return @fromBackingInt(raw & ~node_bit);
    const body = graph.bodies[raw];
    return graph.mentions[body.start + position % (body.end - body.start)].node;
}
fn queries(graph: anytype) ![96]Query {
    var result: [96]Query = undefined;
    for (&result, 0..) |*q, i| {
        q.* = .{ .from = @fromBackingInt(0), .to = @fromBackingInt(0), .edge = null, .scope = graph.occurrences[i * (graph.occurrences.len - 1) / 95].scope };
        if (graph.connections.len == 0) continue;
        const c = graph.connections[i * (graph.connections.len - 1) / 95];
        q.from = member(graph, c.left.members, i / 2);
        q.to = member(graph, c.right.members, i / 3);
        for (graph.connections, 0..) |contribution, id| {
            if (try graph.contains(contribution.left.members, q.from) and try graph.contains(contribution.right.members, q.to)) {
                q.edge = .{ .from = q.from, .to = q.to, .operator = .directed, .first_connection = @fromBackingInt(@as(u32, @intCast(id))) };
                break;
            }
        }
        if (q.edge == null) return error.BadQuery;
        if (i % 2 == 1) q.to = @fromBackingInt(@as(u32, @intCast(graph.nodes.len - 1)));
    }
    return result;
}
fn elapsed(io: std.Io, start: std.Io.Clock.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
}
fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}
fn query(comptime op: Operation, graph: anytype, q: Query) !u64 {
    return switch (op) {
        .has_edge => @intFromBool(try graph.hasEdge(q.from, q.to)),
        .scope => @backingInt(try graph.scopeMembership(q.scope)),
        .attribute => if (try graph.edgeAttribute(q.edge.?, "color")) |v| 1 + @as(u64, v.attribute orelse 0) else 0,
        .attributes => blk: {
            var values = try (try graph.edgeView(q.edge.?)).attributes(.{});
            defer values.deinit();
            var sum: u64 = 0;
            while (try values.next()) |v| sum +%= 1 + @as(u64, v.resolved.attribute orelse 0);
            break :blk sum;
        },
    };
}
fn timeQuery(comptime op: Operation, graph: anytype, qs: []const Query, io: std.Io, expected: *?u64) !f64 {
    var repeat: usize = 1;
    var samples: [9]u64 = undefined;
    const warm = std.Io.Clock.Timestamp.now(io, .awake);
    var sample: usize = 0;
    while (sample < samples.len) {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var sum: u64 = 0;
        for (0..repeat) |_| for (qs) |q| {
            // Each lookup is observable. Prevent the optimizer from hoisting
            // repeated read-only queries or folding a cached scope lookup.
            std.mem.doNotOptimizeAway(graph);
            sum +%= try query(op, graph, q);
        };
        const ns = elapsed(io, start);
        std.mem.doNotOptimizeAway(sum);
        if (expected.*) |value| {
            if (value * repeat != sum) return error.DifferentResult;
        } else expected.* = sum / repeat;
        if (ns < 1_000_000) {
            repeat *= 2;
            sample = 0;
            continue;
        }
        if (elapsed(io, warm) < 80_000_000) continue;
        samples[sample] = ns;
        sample += 1;
    }
    return @as(f64, @floatFromInt(median(&samples))) / @as(f64, @floatFromInt(repeat * qs.len));
}
pub fn main(init: std.process.Init) !void {
    var bytes: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), init.io, &bytes);
    const out = &stdout.interface;
    try out.writeAll("case,indexed,lower_ms,retained_bytes,peak_bytes,arena_bytes,has_edge_ns,attribute_ns,attributes_ns,scope_ns,has_edge_credits,graph_bytes,lowering_session_bytes,query_session_bytes,attribute_session_bytes\n");
    for (std.meta.tags(Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixture(&source.writer, case);
        var parsed = Dot.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(init.gpa);
        if (!parsed.documentValid()) return error.InvalidFixture;
        const doc = &parsed.document.?;
        var expected: [4]?u64 = @splat(null);
        inline for (.{ false, true }) |indexed| {
            const selection: dot.ir.Indexes = .{ .connections = indexed, .scope_memberships = indexed };
            const IR = dot.ir.Lowering(.{ .indexes = selection });
            const Metered = dot.ir.Lowering(.{ .indexes = selection, .policy = .{ .execution = .{ .metering = true } } });
            const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
            var samples: [11]u64 = undefined;
            const warm = std.Io.Clock.Timestamp.now(init.io, .awake);
            var sample: usize = 0;
            while (sample < samples.len) {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var graph = try IR.lowerComplete(init.gpa, doc, options);
                const ns = elapsed(init.io, start);
                std.mem.doNotOptimizeAway(graph.nodes);
                graph.deinit();
                if (elapsed(init.io, warm) < 100_000_000) continue;
                samples[sample] = ns;
                sample += 1;
            }
            var graph = try IR.lowerComplete(init.gpa, doc, options);
            defer graph.deinit();
            if (case == .product and graph.connections.len != 1) return error.ExpandedSymbolicProduct;
            const qs = try queries(&graph);
            const edge_ns = if (graph.connections.len == 0) 0 else try timeQuery(.has_edge, &graph, &qs, init.io, &expected[0]);
            const attr_ns = if (graph.connections.len == 0) 0 else try timeQuery(.attribute, &graph, &qs, init.io, &expected[1]);
            const attrs_ns = if (graph.connections.len == 0) 0 else try timeQuery(.attributes, &graph, &qs, init.io, &expected[2]);
            const scope_ns = try timeQuery(.scope, &graph, &qs, init.io, &expected[3]);
            var credits: u64 = 0;
            if (graph.connections.len != 0) for (qs) |q| {
                var session = try Metered.hasEdgeSession(&graph, q.from, q.to, .{});
                defer session.deinit();
                const p = session.run();
                if (p.outcome.? == .failure) return p.outcome.?.failure;
                if (p.outcome.?.success != (try graph.hasEdge(q.from, q.to))) return error.DifferentResult;
                credits += p.total_work;
            };
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            var in_arena = try IR.lowerComplete(arena.allocator(), doc, options);
            defer in_arena.deinit();
            try out.print("{t},{},{d:.6},{d},{d},{d},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d},{d},{d},{d}\n", .{ case, indexed, @as(f64, @floatFromInt(median(&samples))) / 1e6, graph.retainedBytes(), graph.peak_bytes, arena.queryCapacity(), edge_ns, attr_ns, attrs_ns, scope_ns, credits, @sizeOf(IR.Graph), @sizeOf(Metered.LoweringSession), @sizeOf(Metered.HasEdgeSession), @sizeOf(Metered.AttributeSession) });
        }
        try out.flush();
    }
}
