//! Complete versus partial-capable lowering; no parsing or output in timings.
//! Requested allocation payload/peak and arena capacity are not process RSS.
const std = @import("std");
const dot = @import("dot_parser");
const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
const IR = dot.ir.Lowering(.{});
const Case = enum { sparse, dense, defaults, ports, reopened, deep, many_gaps, symbolic_product };

fn sourceFor(w: *std.Io.Writer, case: Case, broken: bool) !void {
    try w.writeAll("digraph {");
    switch (case) {
        .sparse => for (0..10_000) |i| {
            try w.print("n{d};", .{i});
        },
        .dense => for (0..10_000) |i| {
            try w.print("n{d}->n{d};", .{ i % 100, i / 100 });
        },
        .defaults => {
            try w.writeAll("node[color=red shape=box];");
            for (0..10_000) |i| try w.print("n{d};n{d}[color=blue];", .{ i, i });
        },
        .ports => for (0..10_000) |i| {
            try w.print("n{d}:p:n->n{d}:q:s;", .{ i, i + 1 });
        },
        .reopened => for (0..1000) |i| {
            try w.print("subgraph s{{n{d}}}->x;", .{i});
        },
        .deep => {
            for (0..10_000) |_| try w.writeByte('{');
            try w.writeAll("a[color=red];");
            if (broken) try w.writeAll("bad -> ;");
            for (0..10_000) |_| try w.writeByte('}');
        },
        .many_gaps => for (0..10_000) |i| {
            try w.print("n{d}[color=red];", .{i});
            if (broken) try w.writeAll("bad -> ;");
        },
        .symbolic_product => {
            try w.writeByte('{');
            for (0..50_000) |i| try w.print("n{d};", .{i});
            try w.writeAll("}->{");
            for (50_000..100_000) |i| try w.print("n{d};", .{i});
            try w.writeByte('}');
        },
    }
    if (broken and case != .many_gaps and case != .deep) try w.writeAll("bad -> ;");
    try w.writeByte('}');
}

fn run(comptime partial: bool, init: std.process.Init, w: *std.Io.Writer, case: Case, broken: bool) !void {
    var source = std.Io.Writer.Allocating.init(init.gpa);
    defer source.deinit();
    try sourceFor(&source.writer, case, broken);
    var parsed = P.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
    defer parsed.deinit(init.gpa);
    const doc = &parsed.document.?;
    if (doc.scopeComplete() == broken) return error.BadFixture;
    const lower = if (partial) IR.lowerPartial else IR.lowerComplete;
    const options = .{ .interpretation = P.interpretation(doc, .{}) };
    // Warm each specialization by elapsed time, not just two short parses.
    const warming = std.Io.Clock.Timestamp.now(init.io, .awake);
    while (warming.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds < 100 * std.time.ns_per_ms) {
        var graph = try lower(init.gpa, doc, options);
        std.mem.doNotOptimizeAway(graph.retainedBytes());
        graph.deinit();
    }
    var times: [9]u64 = undefined;
    for (0..11) |round| {
        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
        var graph = try lower(init.gpa, doc, options);
        const end = std.Io.Clock.Timestamp.now(init.io, .awake);
        defer graph.deinit();
        if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
        std.mem.doNotOptimizeAway(graph.retainedBytes());
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    var graph = try lower(init.gpa, doc, options);
    defer graph.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var arena_graph = try lower(arena.allocator(), doc, options);
    defer arena_graph.deinit();
    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    var queries: u64 = 0;
    const node_count = if (partial) graph.nodeCount() else graph.nodes.len;
    for (0..@max(10, 100_000 / @max(node_count, 1))) |_| {
        var nodes = graph.nodeIterator();
        while (nodes.next()) |node| {
            std.mem.doNotOptimizeAway(node.attribute("color"));
            queries += 1;
        }
    }
    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
    var mention_ns: f64 = 0;
    var pair_ns: f64 = 0;
    if (partial) {
        const mstart = std.Io.Clock.Timestamp.now(init.io, .awake);
        var count: u64 = 0;
        var first: ?dot.ir.NodeId = null;
        var last: ?dot.ir.NodeId = null;
        for (0..@max(1, 10_000 / @max(node_count, 1))) |_| {
            var nodes = graph.nodeIterator();
            while (nodes.next()) |node| {
                if (first == null) first = node.id;
                last = node.id;
                var mentions = node.mentions();
                while (mentions.next()) |mention| {
                    std.mem.doNotOptimizeAway(mention);
                    count += 1;
                }
            }
        }
        const mend = std.Io.Clock.Timestamp.now(init.io, .awake);
        mention_ns = @as(f64, @floatFromInt(mstart.durationTo(mend).raw.nanoseconds)) / @as(f64, @floatFromInt(@max(count, 1)));
        const pstart = std.Io.Clock.Timestamp.now(init.io, .awake);
        for (0..100) |_| std.mem.doNotOptimizeAway(try graph.hasEdge(first.?, last.?));
        const pend = std.Io.Clock.Timestamp.now(init.io, .awake);
        pair_ns = @as(f64, @floatFromInt(pstart.durationTo(pend).raw.nanoseconds)) / 100;
    }
    try w.print("{t},{s},{d},{d:.3},{d},{d},{d},{d:.1},{d:.1},{d:.1}\n", .{
        case,                  if (!partial) "complete" else if (!broken) "partial_on_complete" else "partial_with_gaps",
        source.written().len,  @as(f64, @floatFromInt(times[4])) / 1e6,
        graph.retainedBytes(), if (partial) graph.peakBytes() else graph.peak_bytes,
        arena.queryCapacity(), @as(f64, @floatFromInt(begin.durationTo(end).raw.nanoseconds)) / @as(f64, @floatFromInt(queries)),
        mention_ns,            pair_ns,
    });
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    try output.interface.print("# bytes: complete_graph={d},partial_graph={d},attribute={d},qualified_attribute={d},public_gap={d},document={d}\n", .{
        @sizeOf(IR.Graph), @sizeOf(IR.PartialGraph), @sizeOf(IR.PartialGraph.AttributeView), @sizeOf(dot.ir.Knowledge(?IR.PartialGraph.AttributeView)), @sizeOf(@import("dot_parser").ir.CoverageGap), @sizeOf(dot.Document),
    });
    try output.interface.writeAll("case,path,source_bytes,lower_ms,retained_bytes,peak_requested_bytes,arena_capacity_bytes,attribute_ns,mention_ns,pair_ns\n");
    for (std.meta.tags(Case)) |case| {
        try run(false, init, &output.interface, case, false);
        try run(true, init, &output.interface, case, false);
        try run(true, init, &output.interface, case, true);
    }
    try output.interface.flush();
}
