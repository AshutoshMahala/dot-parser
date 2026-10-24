//! Shared fixtures, complete vs partial edge APIs. Parse/lower outside timings.
const std = @import("std");
const dot = @import("dot_parser");
const fixture = @import("ir_materialized_attributes.zig");
const IR = dot.ir.Lowering(.{});
const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });

fn consume(comptime partial: bool, graph: anytype) u64 {
    var sum: u64 = 0;
    var edges = graph.edgeIterator();
    while (edges.next()) |edge| {
        sum +%= @as(u64, @backingInt(edge.edge.from)) + @backingInt(edge.edge.to);
        var attributes = edge.attributes();
        while (attributes.next()) |answer| {
            const value = if (partial) switch (answer) {
                .known => |v| v,
                .unknown => |u| u.retained.?,
            } else answer;
            sum +%= value.resolved.attribute orelse 1;
        }
    }
    return sum;
}
fn measure(comptime partial: bool, graph: anytype, io: std.Io) ![4]u64 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var checksum: u64 = 0;
    {
        var edges = try graph.edgeIterator(.{});
        defer edges.deinit();
        while (try edges.next()) |edge| checksum +%= @as(u64, @backingInt(edge.edge.from)) + @backingInt(edge.edge.to);
    }
    std.mem.doNotOptimizeAway(checksum);
    const streamed = std.Io.Clock.Timestamp.now(io, .awake);
    {
        var topology = try graph.materialize(.{ .attributes = false });
        defer topology.deinit();
        std.mem.doNotOptimizeAway(topology.edges);
    }
    const topology = std.Io.Clock.Timestamp.now(io, .awake);
    var folded = try graph.materialize(.{});
    defer folded.deinit();
    const built = std.Io.Clock.Timestamp.now(io, .awake);
    std.mem.doNotOptimizeAway(consume(partial, &folded));
    const read = std.Io.Clock.Timestamp.now(io, .awake);
    return .{
        @intCast(start.durationTo(streamed).raw.nanoseconds),
        @intCast(streamed.durationTo(topology).raw.nanoseconds),
        @intCast(topology.durationTo(built).raw.nanoseconds),
        @intCast(built.durationTo(read).raw.nanoseconds),
    };
}
fn run(comptime partial: bool, init: std.process.Init, out: *std.Io.Writer, case: fixture.Case, broken: bool) !void {
    var original = std.Io.Writer.Allocating.init(init.gpa);
    defer original.deinit();
    try fixture.sourceFor(&original.writer, case);
    var source = std.Io.Writer.Allocating.init(init.gpa);
    defer source.deinit();
    const opening = std.mem.indexOfScalar(u8, original.written(), '{').? + 1;
    try source.writer.writeAll(original.written()[0..opening]);
    if (broken) try source.writer.writeAll("bad -> ;");
    try source.writer.writeAll(original.written()[opening .. original.written().len - 1]);
    if (broken) try source.writer.writeAll("bad -> ;");
    try source.writer.writeByte('}');
    var parsed = P.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
    defer parsed.deinit(init.gpa);
    const doc = &parsed.document.?;
    var graph = try (if (partial) IR.lowerPartial else IR.lowerComplete)(init.gpa, doc, .{ .interpretation = P.interpretation(doc, .{}) });
    defer graph.deinit();
    const path = if (!partial) "complete" else if (!broken) "partial_on_complete" else "partial_with_gaps";
    if (case == .rejected_product) {
        var edges = try graph.edgeIterator(.{ .limits = .{ .max_pairs = 1000 } });
        defer edges.deinit();
        for (0..1000) |_| _ = (try edges.next()).?;
        if (graph.materialize(.{})) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedPairLimit;
        } else |err| if (err != error.PairLimit) return err;
        try out.print("{t},{s},streamed_1000,materialization_PairLimit,stream_peak={d}\n", .{ case, path, edges.peakBytes() });
        return;
    }
    const warm = std.Io.Clock.Timestamp.now(init.io, .awake);
    while (warm.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds < 100 * std.time.ns_per_ms)
        _ = try measure(partial, &graph, init.io);
    var samples: [4][9]u64 = undefined;
    for (0..9) |round| {
        const times = try measure(partial, &graph, init.io);
        for (times, 0..) |time, i| samples[i][round] = time;
    }
    var topology = try graph.materialize(.{ .attributes = false });
    defer topology.deinit();
    var folded = try graph.materialize(.{});
    defer folded.deinit();
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var arena_graph = try (if (partial) IR.lowerPartial else IR.lowerComplete)(arena.allocator(), doc, .{ .interpretation = P.interpretation(doc, .{}) });
    defer arena_graph.deinit();
    var arena_folded = try arena_graph.materialize(.{});
    defer arena_folded.deinit();
    try out.print("{t},{s},{d}", .{ case, path, folded.edges.len });
    for (&samples) |*values| {
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        try out.print(",{d:.4}", .{@as(f64, @floatFromInt(values[4])) / 1e6});
    }
    try out.print(",{d},{d},{d},{d},{d},{d}\n", .{
        graph.retainedBytes(),  if (partial) topology.retainedBytes() else topology.storage.len * @sizeOf(dot.ir.Edge),
        folded.retainedBytes(), topology.peak_bytes,
        folded.peak_bytes,      arena.queryCapacity(),
    });
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buf);
    const out = &output.interface;
    try out.print("# sizes: edge={d},partial_edge={d},folded_edge={d},partial_folded_edge={d}\n", .{
        @sizeOf(IR.Graph.EdgeView), @sizeOf(IR.PartialGraph.EdgeView), @sizeOf(IR.Graph.Materialized.EdgeView), @sizeOf(IR.PartialGraph.Materialized.EdgeView),
    });
    try out.writeAll("case,path,edges,stream_ms,topology_ms,fold_ms,read_ms,ir_retained,topology_retained,folded_retained,topology_peak,folded_peak,total_arena\n");
    for (std.meta.tags(fixture.Case)) |case| {
        try run(false, init, out, case, false);
        try run(true, init, out, case, false);
        try run(true, init, out, case, true);
        try out.flush();
    }
}
