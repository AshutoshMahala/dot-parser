//! Fixed materialization reservations versus growable output. Parsing/lowering
//! and caller allocation are untimed; initialization and construction are timed.
const std = @import("std");
const dot = @import("dot_parser");
const suite = @import("ir_materialized_attributes.zig");
const IR = dot.ir.Lowering(.{});
const Route = enum { growable, fixed_observed, fixed_scanned, session_4096, session_1 };
const Observation = struct { ns: u64, peak: usize, retained: usize, work: u64 = 0, checksum: u64 };
fn sample(comptime attributes: bool, comptime route: Route, graph: *const IR.Graph, memory: IR.MaterializationMemory(attributes), io: std.Io) !Observation {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var work: u64 = 0;
    var result = if (route == .growable) try graph.materialize(.{ .attributes = attributes }) else value: {
        if (route == .session_1 or route == .session_4096) {
            var operation = try graph.materializationSessionIn(memory, .{});
            defer operation.deinit();
            while (true) {
                const p = operation.advance(if (route == .session_1) 1 else 4096);
                if (p.outcome) |o| {
                    if (o == .failure) return o.failure;
                    work = p.total_work;
                    break;
                }
            }
            break :value try operation.takeResult();
        }
        const built = graph.materializeIn(memory, .{});
        if (built.outcome == .failure) return built.outcome.failure;
        break :value built.materialized.?;
    };
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    defer result.deinit();
    var checksum: u64 = 0;
    for (result.edges) |edge| checksum +%= @as(u64, @backingInt(edge.from)) + @backingInt(edge.to) + @backingInt(edge.first_connection);
    if (attributes) {
        var edges = result.edgeIterator();
        while (edges.next()) |edge| {
            var attrs = edge.attributes();
            while (attrs.next()) |attr| checksum +%= attr.resolved.attribute orelse 1;
        }
    }
    return .{ .ns = @intCast(start.durationTo(end).raw.nanoseconds), .peak = result.peak_bytes, .retained = result.retainedBytes(), .work = work, .checksum = checksum };
}
fn measure(comptime attributes: bool, graph: *const IR.Graph, case: suite.Case, init: std.process.Init, out: *std.Io.Writer) !void {
    var original = try graph.materialize(.{ .attributes = attributes });
    defer original.deinit();
    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    const scanned = try IR.scanMaterializationBounds(graph, .{ .attributes = attributes });
    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
    const sizing_ms = @as(f64, @floatFromInt(start.durationTo(end).raw.nanoseconds)) / 1e6;
    const layout = try IR.materializationLayout(graph, original.capacities(), scanned.scratch, .{ .attributes = attributes });
    const output = try init.gpa.alignedAlloc(u8, .@"16", layout.output_bytes);
    defer init.gpa.free(output);
    const scratch = try init.gpa.alignedAlloc(u8, .@"16", layout.scratch_bytes);
    defer init.gpa.free(scratch);
    const observed = try layout.bind(output, scratch);
    const first = graph.materializeIn(observed, .{});
    if (first.outcome == .failure) return first.outcome.failure;
    const exact_layout = try IR.materializationLayout(graph, original.capacities(), first.scratch_peak, .{ .attributes = attributes });
    const exact = try exact_layout.bind(output, scratch);
    const scan_layout = try IR.materializationLayout(graph, scanned.output, scanned.scratch, .{ .attributes = attributes });
    const scan_output = try init.gpa.alignedAlloc(u8, .@"16", scan_layout.output_bytes);
    defer init.gpa.free(scan_output);
    const scan_scratch = try init.gpa.alignedAlloc(u8, .@"16", scan_layout.scratch_bytes);
    defer init.gpa.free(scan_scratch);
    const scan_memory = try scan_layout.bind(scan_output, scan_scratch);
    var expected: ?u64 = null;
    inline for (comptime std.meta.tags(Route)) |route| {
        const memory = if (route == .fixed_scanned) scan_memory else exact;
        // Short first cases otherwise measure CPU ramp-up more than parsing.
        const warm = std.Io.Clock.Timestamp.now(init.io, .awake);
        while (warm.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds < 150_000_000) {
            const value = try sample(attributes, route, graph, memory, init.io);
            std.mem.doNotOptimizeAway(value.checksum);
        }
        var samples: [9]u64 = undefined;
        var last: Observation = undefined;
        for (0..12) |round| {
            last = try sample(attributes, route, graph, memory, init.io);
            if (expected) |value| {
                if (last.checksum != value) return error.DifferentResult;
            } else expected = last.checksum;
            if (round >= 3) samples[round - 3] = last.ns;
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        try out.print("{t},{},{t},{d:.6},{d},{d},{d},{d},{d:.6}\n", .{ case, attributes, route, @as(f64, @floatFromInt(samples[4])) / 1e6, last.retained, last.peak, original.edges.len, last.work, sizing_ms });
    }
}
pub fn main(init: std.process.Init) !void {
    var bytes: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &bytes);
    const out = &stdout.interface;
    try out.writeAll("case,attributes,route,ms,retained_bytes,peak_bytes,edges,work,sizing_ms\n");
    for (std.meta.tags(suite.Case)) |case| {
        if (case == .rejected_product) continue;
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try suite.sourceFor(&source.writer, case);
        var parsed = try IR.parse(init.gpa, source.written(), .{});
        defer parsed.deinit();
        const graph = parsed.ir() orelse return error.InvalidFixture;
        try measure(false, graph, case, init, out);
        try measure(true, graph, case, init, out);
    }
    try out.flush();
}
