//! One-command production topology benchmark. Parsing and source construction
//! are outside lowering timing. Exact allocator-requested peaks are not RSS.
const std = @import("std");
const dot = @import("dot_parser");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});
const Case = enum { singletons, small_sets, reopened, strict_reopened, nested, symbolic_product };
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("case,source_bytes,nodes,connections,lower_ms,lower_MB_s,retained_bytes,peak_requested_bytes,arena_capacity_bytes,materialize_ms,edges,materialize_peak_bytes,stream_ms,stream_edges,stream_peak_bytes\n");
    inline for (std.meta.tags(Case)) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try source.writer.writeAll(if (case == .strict_reopened) "strict digraph {" else "digraph {");
        switch (case) {
            .singletons => for (0..10_000) |i| {
                try source.writer.print("n{d}->n{d};", .{ i, i + 1 });
            },
            .small_sets => for (0..10_000) |i| {
                try source.writer.print("n{d}->{{a b c}};", .{i});
            },
            .reopened, .strict_reopened => for (0..1000) |i| {
                try source.writer.print("subgraph s{{n{d}}} -> x;", .{i});
            },
            .nested => {
                for (0..10_000) |_| try source.writer.writeAll("{");
                try source.writer.writeAll("a");
                for (0..10_000) |_| try source.writer.writeAll("}");
                try source.writer.writeAll("->b;");
            },
            .symbolic_product => {
                try source.writer.writeAll("{");
                for (0..50_000) |i| try source.writer.print("n{d};", .{i});
                try source.writer.writeAll("}->{");
                for (50_000..100_000) |i| try source.writer.print("n{d};", .{i});
                try source.writer.writeAll("}");
            },
        }
        try source.writer.writeAll("}");
        var parsed = Dot.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(init.gpa);
        if (!parsed.documentValid()) return error.InvalidFixture;
        const doc = &parsed.document.?;
        const interpretation = Dot.interpretation(doc, .{});
        var times: [9]u64 = undefined;
        for (0..11) |round| {
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            var ir = try IR.lowerComplete(init.gpa, doc, .{ .interpretation = interpretation });
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            defer ir.deinit();
            if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
            std.mem.doNotOptimizeAway(ir.connections);
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        var ir = try IR.lowerComplete(init.gpa, doc, .{ .interpretation = interpretation });
        defer ir.deinit();
        const ns: f64 = @floatFromInt(times[times.len / 2]);
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        var arena_ir = try IR.lowerComplete(arena.allocator(), doc, .{ .interpretation = interpretation });
        defer arena_ir.deinit();
        try w.print("{s},{d},{d},{d},{d:.3},{d:.1},{d},{d},{d},", .{ @tagName(case), source.written().len, ir.nodes.len, ir.connections.len, ns / 1e6, @as(f64, @floatFromInt(source.written().len)) * 1e3 / ns, ir.retainedBytes(), ir.peak_bytes, arena.queryCapacity() });
        if (case == .symbolic_product) {
            if (ir.connections.len != 1 or ir.nodes.len != 100_000) return error.ExpandedUnexpectedly;
            try w.writeAll("not_requested,not_requested,not_requested,");
        } else {
            for (0..11) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var graph = try ir.materialize(.{ .attributes = false });
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                defer graph.deinit();
                if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
                std.mem.doNotOptimizeAway(graph.edges);
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            var graph = try ir.materialize(.{ .attributes = false });
            defer graph.deinit();
            try w.print("{d:.3},{d},{d},", .{ @as(f64, @floatFromInt(times[times.len / 2])) / 1e6, graph.edges.len, graph.peak_bytes });
        }
        var stream_count: u32 = 0;
        var stream_peak: usize = 0;
        for (0..11) |round| {
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            // For the 2.5-billion-pair product, consume only a 1,000-edge
            // prefix. Other cases run to exhaustion, with ordinary limits.
            var stream = try ir.edgeIterator(.{});
            defer stream.deinit();
            stream_count = 0;
            while (try stream.next()) |view| {
                const edge = view.edge;
                std.mem.doNotOptimizeAway(edge);
                stream_count += 1;
                if (case == .symbolic_product and stream_count == 1000) break;
            }
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            stream_peak = stream.peakBytes();
            if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        try w.print("{d:.3},{d},{d}\n", .{ @as(f64, @floatFromInt(times[times.len / 2])) / 1e6, stream_count, stream_peak });
        try w.flush();
    }
}
