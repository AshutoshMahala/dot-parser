//! End-to-end bulk folding versus the existing topology + attribute-query path.
//! Parsing/lowering and output IO are outside timings. No renderer or flattening.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
pub const Case = enum { plain, shared_defaults, explicit, strict_overlap, reopened, deep, ports, strict_ports, rejected_product };

pub fn sourceFor(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll(if (case == .strict_ports) "strict graph {" else if (case == .strict_overlap or case == .reopened) "strict digraph {" else "digraph {");
    switch (case) {
        .plain => for (0..2000) |i| try out.print("n{d}->n{d};", .{ i, i + 1 }),
        .shared_defaults => {
            try out.writeAll("edge[");
            for (0..64) |k| try out.print(" k{d}=v{d}", .{ k, k });
            try out.writeAll("];");
            for (0..2000) |i| try out.print("n{d}->n{d};", .{ i, i + 1 });
        },
        .explicit => for (0..2000) |i| {
            try out.print("n{d}->n{d}[", .{ i, i + 1 });
            for (0..8) |k| try out.print(" k{d}=v{d}", .{ k, i });
            try out.writeAll("];");
        },
        .strict_overlap => for (0..32) |round| {
            try out.writeAll("{");
            for (0..32) |i| try out.print("a{d};", .{i});
            try out.writeAll("}->{");
            for (0..32) |i| try out.print("b{d};", .{i});
            try out.writeAll("}[");
            for (0..8) |k| try out.print(" k{d}=v{d}", .{ k, round });
            try out.writeAll("];");
        },
        .reopened => for (0..250) |i| try out.print("edge[weight={d}];subgraph s{{n{d}}}->x[color=v{d}];", .{ i, i, i }),
        .deep => {
            try out.writeAll("edge[color=red weight=1];");
            for (0..5000) |_| try out.writeAll("{");
            try out.writeAll("a->b[label=deep];");
            for (0..5000) |_| try out.writeAll("}");
        },
        .ports => for (0..2000) |i| try out.print("n{d}:out:e->n{d}:in:w;", .{ i, i + 1 }),
        .strict_ports => for (0..32) |round| {
            for (0..100) |i| {
                if (round % 2 == 0) try out.print("a{d}:out:e--b{d}:in:w;", .{ i, i }) else try out.print("b{d}:next--a{d}:final[headport=override];", .{ i, i });
            }
        },
        .rejected_product => {
            try out.writeAll("{");
            for (0..2500) |i| try out.print("a{d};", .{i});
            try out.writeAll("}->{");
            for (0..2500) |i| try out.print("b{d};", .{i});
            try out.writeAll("}[label=large]");
        },
    }
    try out.writeAll("}");
}
fn compactConsume(ir: *const IR.Graph, edges: []const dot.ir.Edge) !u64 {
    var sum: u64 = 0;
    for (edges) |record| {
        sum +%= @as(u64, @backingInt(record.from)) + @backingInt(record.to);
        const edge = try ir.edgeView(record);
        var attributes = try edge.attributes(.{});
        defer attributes.deinit();
        while (try attributes.next()) |attribute| sum +%= attribute.resolved.attribute orelse 0;
    }
    return sum;
}
fn foldedConsume(graph: *const IR.Graph.Materialized) u64 {
    var sum: u64 = 0;
    var edges = graph.edgeIterator();
    while (edges.next()) |edge| {
        sum +%= @as(u64, @backingInt(edge.edge.from)) + @backingInt(edge.edge.to);
        var attributes = edge.attributes();
        while (attributes.next()) |attribute| sum +%= attribute.resolved.attribute orelse 0;
    }
    return sum;
}
fn milliseconds(samples: *[9]u64) f64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return @as(f64, @floatFromInt(samples[4])) / 1e6;
}
pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &output_buffer);
    const out = &output.interface;
    try out.writeAll("bulk_case,source_bytes,edges,topology_ms,fold_ms,compact_read_ms,folded_read_ms,compact_total_ms,folded_total_ms,topology_retained_bytes,folded_retained_bytes,topology_peak_bytes,folded_peak_bytes,topology_arena_bytes,folded_arena_bytes\n");
    for (std.meta.tags(Case)) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try sourceFor(&source.writer, case);
        var parsed = dot.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(init.gpa);
        if (!parsed.documentValid()) return error.InvalidFixture;
        const document = &parsed.document.?;
        const interpretation = dot.Profile(.{}).interpretation(document, .{});
        var ir = try IR.lowerComplete(init.gpa, document, .{ .interpretation = interpretation });
        defer ir.deinit();
        if (case == .rejected_product) {
            if (ir.materialize(.{})) |value| {
                var unexpected = value;
                unexpected.deinit();
                return error.ExpectedPairLimit;
            } else |err| if (err != error.PairLimit) return err;
            try out.print("{t},{d},rejected_PairLimit\n", .{ case, source.written().len });
            try out.flush();
            continue;
        }
        var samples: [4][9]u64 = undefined;
        var totals: [2][9]u64 = undefined;
        for (0..11) |round| {
            // Alternate within each round; no timed workloads run in parallel.
            for (0..2) |pass| {
                const bulk = (round + pass) % 2 != 0;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (bulk) {
                    var graph = try ir.materialize(.{});
                    const built = std.Io.Clock.Timestamp.now(init.io, .awake);
                    const checksum = foldedConsume(&graph);
                    std.mem.doNotOptimizeAway(checksum);
                    const read = std.Io.Clock.Timestamp.now(init.io, .awake);
                    graph.deinit();
                    const freed = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (round >= 2) {
                        samples[1][round - 2] = @intCast(start.durationTo(built).raw.nanoseconds);
                        samples[3][round - 2] = @intCast(built.durationTo(read).raw.nanoseconds);
                        totals[1][round - 2] = @intCast(start.durationTo(freed).raw.nanoseconds);
                    }
                } else {
                    var graph = try ir.materialize(.{ .attributes = false });
                    const built = std.Io.Clock.Timestamp.now(init.io, .awake);
                    const checksum = try compactConsume(&ir, graph.edges);
                    std.mem.doNotOptimizeAway(checksum);
                    const read = std.Io.Clock.Timestamp.now(init.io, .awake);
                    graph.deinit();
                    const freed = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (round >= 2) {
                        samples[0][round - 2] = @intCast(start.durationTo(built).raw.nanoseconds);
                        samples[2][round - 2] = @intCast(built.durationTo(read).raw.nanoseconds);
                        totals[0][round - 2] = @intCast(start.durationTo(freed).raw.nanoseconds);
                    }
                }
            }
        }
        var topology = try ir.materialize(.{ .attributes = false });
        defer topology.deinit();
        var folded = try ir.materialize(.{});
        defer folded.deinit();
        if (try compactConsume(&ir, topology.edges) != foldedConsume(&folded)) return error.AttributeMismatch;
        var arena_sizes: [2]usize = undefined;
        inline for (.{ false, true }, 0..) |bulk, i| {
            var arena: std.heap.ArenaAllocator = .init(init.gpa);
            defer arena.deinit();
            var arena_ir = try IR.lowerComplete(arena.allocator(), document, .{ .interpretation = interpretation });
            defer arena_ir.deinit();
            var graph = if (bulk) try arena_ir.materialize(.{}) else try arena_ir.materialize(.{ .attributes = false });
            defer graph.deinit();
            arena_sizes[i] = arena.queryCapacity();
        }
        try out.print("{t},{d},{d}", .{ case, source.written().len, folded.edges.len });
        for (&samples) |*values| try out.print(",{d:.4}", .{milliseconds(values)});
        for (&totals) |*values| try out.print(",{d:.4}", .{milliseconds(values)});
        try out.print(",{d},{d},{d},{d},{d},{d}\n", .{
            topology.storage.len * @sizeOf(dot.ir.Edge), folded.retainedBytes(),
            topology.peak_bytes,                         folded.peak_bytes,
            arena_sizes[0],                              arena_sizes[1],
        });
        try out.flush();
    }
}
