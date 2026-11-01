//! Explicit materialization/adjacency construction and traversal. Run serially;
//! parse/lower and result destruction are outside construction timing.
const std = @import("std");
const dot = @import("dot_parser");
const P = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
const IR = dot.ir.Lowering(.{});
const Case = enum { chain, star, isolated, undirected, mixed, loops, attributes, sets };
const Observation = struct { ns: u64, walk_ns: u64, retained: usize, peak: usize, arena_bytes: usize, work: u64, checksum: u64 };
fn sourceFor(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll("graph {");
    switch (case) {
        .sets => {
            try out.writeAll("{");
            for (0..500) |i| try out.print("a{d};", .{i});
            try out.writeAll("}->{");
            for (0..500) |i| try out.print("b{d};", .{i});
            try out.writeAll("};");
        },
        else => for (0..100_000) |i| switch (case) {
            .chain => try out.print("n{d}->n{d};", .{ i, i + 1 }),
            .star => try out.print("root->n{d};", .{i}),
            .isolated => {
                try out.print("n{d};", .{i});
                if (i == 0) try out.writeAll("a->b;");
            },
            .undirected => try out.print("n{d}--n{d};", .{ i, i + 1 }),
            .mixed => try out.print("n{d}{s}n{d};", .{ i, if (i % 2 == 0) "->" else "--", i + 1 }),
            .loops => try out.print("n{d}{s}n{d};", .{ i, if (i % 2 == 0) "->" else "--", i }),
            .attributes => try out.print("n{d}->n{d}[color=red label=example weight=1];", .{ i, i + 1 }),
            .sets => unreachable,
        },
    }
    try out.writeAll("}");
}
fn sample(comptime attributes: bool, comptime adjacency: dot.ir.Adjacency, comptime session: bool, comptime use_arena: bool, graph: *const IR.Graph, init: std.process.Init) !Observation {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var input = graph.*;
    input.allocator = if (use_arena) arena.allocator() else init.gpa;
    var work: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var result = if (!session) try input.materialize(.{ .attributes = attributes, .adjacency = adjacency }) else blk: {
        var operation = try input.materializationSession(.{ .attributes = attributes, .adjacency = adjacency });
        defer operation.deinit();
        var p = operation.advance(4096);
        while (p.outcome == null) p = operation.advance(4096);
        work = p.total_work;
        break :blk try operation.takeResult();
    };
    const built = std.Io.Clock.Timestamp.now(init.io, .awake);
    defer result.deinit();
    var sum: u64 = 0;
    if (adjacency != .none) {
        var nodes = result.nodeIterator();
        while (nodes.next()) |node| {
            var edges = node.edges(.{ .direction = if (adjacency == .all) .all else .forward });
            while (edges.next()) |entry| sum +%= @as(u64, @backingInt(entry.neighbor().id)) + entry.index;
        }
    }
    std.mem.doNotOptimizeAway(sum);
    const walked = std.Io.Clock.Timestamp.now(init.io, .awake);
    var checksum: u64 = 0;
    for (result.edges) |edge| checksum +%= @as(u64, @backingInt(edge.from)) + @backingInt(edge.to);
    return .{
        .ns = @intCast(start.durationTo(built).raw.nanoseconds),
        .walk_ns = if (adjacency == .none) 0 else @intCast(built.durationTo(walked).raw.nanoseconds),
        .retained = result.retainedBytes(),
        .peak = result.peak_bytes,
        .arena_bytes = if (use_arena) arena.queryCapacity() else 0,
        .work = work,
        .checksum = checksum,
    };
}
fn measure(comptime attributes: bool, comptime adjacency: dot.ir.Adjacency, comptime session: bool, graph: *const IR.Graph, case: Case, init: std.process.Init, out: *std.Io.Writer, expected: *?u64) !void {
    var samples: [9]u64 = undefined;
    var walks: [9]u64 = undefined;
    var last: Observation = undefined;
    for (0..12) |round| {
        last = try sample(attributes, adjacency, session, false, graph, init);
        if (expected.*) |value| {
            if (last.checksum != value) return error.DifferentEdges;
        } else expected.* = last.checksum;
        if (round >= 3) {
            samples[round - 3] = last.ns;
            walks[round - 3] = last.walk_ns;
        }
    }
    const arena = try sample(attributes, adjacency, session, true, graph, init);
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, &walks, {}, std.sort.asc(u64));
    try out.print("{t},{},{t},{s},{d:.6},{d:.6},{d},{d},{d},{d},{d}\n", .{ case, attributes, adjacency, if (session) "session_4096" else "direct", @as(f64, @floatFromInt(samples[4])) / 1e6, @as(f64, @floatFromInt(walks[4])) / 1e6, graph.nodes.len, last.retained, last.peak, arena.arena_bytes, last.work });
    try out.flush();
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.writeAll("case,attributes,adjacency,route,build_ms,walk_ms,nodes,retained_bytes,peak_bytes,arena_bytes,work\n");
    for (std.meta.tags(Case)) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try sourceFor(&source.writer, case);
        var parsed = P.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(init.gpa);
        if (!parsed.documentValid()) return error.BadFixture;
        var graph = try IR.lowerComplete(init.gpa, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer graph.deinit();
        var expected: ?u64 = null;
        inline for (.{ false, true }) |attributes| {
            inline for (.{ .none, .forward, .all }) |adjacency| try measure(attributes, adjacency, false, &graph, case, init, out, &expected);
            try measure(attributes, .all, true, &graph, case, init, out, &expected);
        }
    }
}
