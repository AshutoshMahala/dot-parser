//! Interleaved whole-route comparison; no edge expansion or timing allocator.
const std = @import("std");
const dot = @import("dot_parser");
const cases = @import("ir_pipeline.zig");
const memory = @import("phase_memory.zig");
const IR = dot.ir.Lowering(.{});
const Events = IR.FromEvents(dot.Profile(.{}));
const Route = enum { document, events };
const Storage = enum { gpa, arena };
const samples = 9;
fn run(comptime route: Route, a: std.mem.Allocator, source: []const u8) !if (route == .events) Events.Result else IR.ParseResult {
    return if (route == .events) Events.parse(a, source, .{}) else IR.parse(a, source, .{});
}
fn timed(comptime route: Route, comptime storage: Storage, source: []const u8, io: std.Io) !u64 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = if (storage == .arena) arena.allocator() else std.heap.smp_allocator;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var result = try run(route, a, source);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    defer result.deinit();
    const graph = result.ir() orelse return error.InvalidFixture;
    std.mem.doNotOptimizeAway(graph.nodes);
    return @intCast(start.durationTo(end).raw.nanoseconds);
}
const Observation = struct { peak: usize, bound: usize, retained: usize, arena_capacity: usize, arena_peak: usize, nodes: usize, connections: usize, allocations: usize };
fn probe(comptime route: Route, comptime storage: Storage, source: []const u8) !Observation {
    var backing: memory.Tracker = .{ .backing = std.heap.smp_allocator };
    var arena: std.heap.ArenaAllocator = .init(backing.allocator());
    defer arena.deinit();
    var tracker: memory.Tracker = .{ .backing = if (storage == .arena) arena.allocator() else std.heap.smp_allocator };
    var result = try run(route, tracker.allocator(), source);
    const graph = result.ir() orelse return error.InvalidFixture;
    const observation: Observation = .{ .peak = tracker.peak, .bound = tracker.peakBound(), .retained = graph.retainedBytes(), .arena_capacity = arena.queryCapacity(), .arena_peak = backing.peak, .nodes = graph.nodes.len, .connections = graph.connections.len, .allocations = tracker.stats[0].allocations };
    if (graph.retainedBytes() != tracker.live) return error.RetainedAccounting;
    result.deinit();
    if (tracker.live != 0) return error.LeakedMemory;
    return observation;
}
fn report(init: std.process.Init, w: *std.Io.Writer, name: []const u8, source: []const u8) !void {
    var times: [2][2][samples]u64 = undefined;
    for (0..3 + samples) |round| inline for (comptime std.meta.tags(Storage), 0..) |storage, si| {
        // Opposite call order each round, same allocator and source.
        inline for (0..2) |turn| {
            if ((round + turn) % 2 == 0) {
                const ns = try timed(.document, storage, source, init.io);
                if (round >= 3) times[si][0][round - 3] = ns;
            } else {
                const ns = try timed(.events, storage, source, init.io);
                if (round >= 3) times[si][1][round - 3] = ns;
            }
        }
    };
    inline for (comptime std.meta.tags(Storage), 0..) |storage, si| inline for (comptime std.meta.tags(Route), 0..) |route, ri| {
        var value = try probe(route, storage, source);
        for (0..2) |_| {
            const next = try probe(route, storage, source);
            if (next.peak > value.peak) value = next;
        }
        try w.print("{t},{s},{t},{t},{d},{x},{d:.6},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{ @import("builtin").mode, name, storage, route, source.len, std.hash.Wyhash.hash(0, source), @as(f64, @floatFromInt(cases.median(&times[si][ri]))) / 1e6, value.peak, value.bound, value.retained, value.arena_capacity, value.arena_peak, value.nodes, value.connections, value.allocations });
        try w.flush();
    };
}
pub fn main(init: std.process.Init) !void {
    const options = try cases.Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("build,case,allocator,route,source_bytes,source_hash,total_ms,peak_bytes,peak_bound_bytes,retained_bytes,arena_capacity,arena_backing_peak,nodes,connections,allocations\n");
    var count: usize = 0;
    if (options.corpus) |directory| for (cases.corpus_cases) |case| {
        if (!options.selected(case)) continue;
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}_M.dot", .{ directory, case });
        defer init.gpa.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(128 * 1024 * 1024));
        defer init.gpa.free(source);
        try report(init, w, case, source);
        count += 1;
    };
    for (std.meta.tags(cases.Shape)) |shape| {
        if (!options.selected(@tagName(shape))) continue;
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try cases.fixture(&source.writer, shape);
        try report(init, w, @tagName(shape), source.written());
        count += 1;
    }
    if (count == 0) return error.NoMatchingCases;
    try w.flush();
}
