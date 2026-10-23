//! Effective-attribute cost, separate from parser and output I/O. The same
//! fixtures can be run against a topology-only IR; query columns then say n/a.
const std = @import("std");
const dot = @import("dot_parser");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});
const Case = enum { shared_defaults, node_updates, reopened_defaults, strict_updates, deep_defaults, symbolic_defaults };

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("attribute_case,source_bytes,nodes,connections,lower_ms,retained_bytes,peak_requested_bytes,arena_capacity_bytes,node_query_ns,edge_query_ns,node_view_ns,edge_view_ns,node_attributes_ns,edge_attributes_ns,attribute_scratch_bytes\n");
    inline for (std.meta.tags(Case)) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        const out = &source.writer;
        try out.writeAll(if (case == .reopened_defaults or case == .strict_updates) "strict digraph {" else "digraph {");
        switch (case) {
            .shared_defaults => {
                try out.writeAll("node[color=red");
                for (0..63) |k| try out.print(" k{d}=v{d}", .{ k, k });
                try out.writeAll("];");
                for (0..10_000) |i| try out.print("n{d};", .{i});
                try out.writeAll("n0->n9999[weight=1]");
            },
            .node_updates => {
                for (0..10_000) |i| try out.print("n{d}[color=red shape=box];", .{i});
                for (0..10_000) |i| try out.print("n{d}[color=blue];", .{i});
                try out.writeAll("n0->n9999[weight=1]");
            },
            .reopened_defaults => {
                try out.writeAll("subgraph s{node[shape=box]}");
                for (0..1000) |i| try out.print("node[color=v{d}]; edge[weight={d}]; subgraph s{{n{d}}}->x;", .{ i, i, i });
            },
            .strict_updates => {
                try out.writeAll("node[color=red]; edge[weight=1];");
                for (0..1000) |i| try out.print("a->b[k{d}=v{d}];", .{ i % 32, i });
            },
            .deep_defaults => {
                try out.writeAll("node[color=red]; edge[weight=1];");
                for (0..10_000) |_| try out.writeAll("{");
                try out.writeAll("a->b;");
                for (0..10_000) |_| try out.writeAll("}");
            },
            .symbolic_defaults => {
                try out.writeAll("node[color=red]; edge[weight=2]; {");
                for (0..50_000) |i| try out.print("n{d};", .{i});
                try out.writeAll("}->{");
                for (50_000..100_000) |i| try out.print("n{d};", .{i});
                try out.writeAll("}[label=group]");
            },
        }
        try out.writeAll("}");
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
            std.mem.doNotOptimizeAway(ir.nodes);
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        var ir = try IR.lowerComplete(init.gpa, doc, .{ .interpretation = interpretation });
        defer ir.deinit();
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        var arena_ir = try IR.lowerComplete(arena.allocator(), doc, .{ .interpretation = interpretation });
        defer arena_ir.deinit();
        try w.print("{s},{d},{d},{d},{d:.3},{d},{d},{d},", .{ @tagName(case), source.written().len, ir.nodes.len, ir.connections.len, @as(f64, @floatFromInt(times[times.len / 2])) / 1e6, ir.retainedBytes(), ir.peak_bytes, arena.queryCapacity() });
        if (@hasDecl(IR.Graph, "nodeAttribute")) {
            // Query costs exclude name lookup, expansion and rendering. Reuse
            // real handles; the product case expands only the first edge.
            var stream = try ir.edgeIterator(.{});
            defer stream.deinit();
            const edge = (try stream.next()).?.edge;
            inline for (.{ false, true }) |edge_query| {
                const count = if (edge_query) 100 else 10_000;
                for (0..11) |round| {
                    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                    for (0..count) |_| {
                        const result = if (edge_query) try ir.edgeAttribute(edge, "weight") else try ir.nodeAttribute(edge.from, "color");
                        if (result == null) return error.MissingAttribute;
                        std.mem.doNotOptimizeAway(result);
                    }
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
                }
                std.mem.sort(u64, &times, {}, std.sort.asc(u64));
                try w.print("{d:.1},", .{@as(f64, @floatFromInt(times[times.len / 2])) / count});
            }
            if (@hasDecl(IR.Graph, "nodeView")) {
                const node = try ir.nodeView(edge.from);
                const view = try ir.edgeView(edge);
                var scratch: usize = 0;
                inline for (.{ false, true }) |all_attributes| {
                    inline for (.{ false, true }) |edge_query| {
                        const count = if (edge_query) 100 else 10_000;
                        for (0..11) |round| {
                            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                            for (0..count) |_| {
                                if (all_attributes) {
                                    var attributes = try (if (edge_query) view.attributes(.{}) else node.attributes(.{}));
                                    defer attributes.deinit();
                                    while (try attributes.next()) |entry| std.mem.doNotOptimizeAway(entry.resolved);
                                    scratch = @max(scratch, attributes.peakBytes());
                                } else {
                                    const result = if (edge_query) try view.attribute("weight") else node.attribute("color");
                                    if (result == null) return error.MissingAttribute;
                                    std.mem.doNotOptimizeAway(result);
                                }
                            }
                            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                            if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
                        }
                        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
                        try w.print("{d:.1},", .{@as(f64, @floatFromInt(times[times.len / 2])) / count});
                    }
                }
                try w.print("{d}\n", .{scratch});
            } else try w.writeAll("not_available,not_available,not_available,not_available,not_available\n");
        } else try w.writeAll("not_available,not_available,not_available,not_available,not_available,not_available,not_available\n");
        try w.flush();
    }
}
