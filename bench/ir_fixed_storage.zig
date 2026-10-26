//! Explicit fixed capacities versus ordinary allocation. Source construction,
//! parsing, sizing and caller-buffer allocation are outside lowering timing.
//! Allocation counts come from a separate untimed run, not a timed wrapper.
const std = @import("std");
const dot = @import("dot_parser");
const suite = @import("ir_lowering_sessions.zig");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const Route = enum { growable, fixed_used, fixed_bounds, fixed_session };
const Buffers = struct {
    graph: []align(16) u8,
    scratch: []align(16) u8,
    bound: IR.LoweringMemory,
    fn init(allocator: std.mem.Allocator, counts: dot.ir.GraphCapacities, scratch: dot.ir.LoweringScratchCapacities) !Buffers {
        const layout = try IR.storageLayout(counts, scratch);
        const graph = try allocator.alignedAlloc(u8, .@"16", layout.graph_bytes);
        errdefer allocator.free(graph);
        const temporary = try allocator.alignedAlloc(u8, .@"16", layout.scratch_bytes);
        errdefer allocator.free(temporary);
        return .{ .graph = graph, .scratch = temporary, .bound = try layout.bind(graph, temporary) };
    }
    fn deinit(self: Buffers, allocator: std.mem.Allocator) void {
        allocator.free(self.graph);
        allocator.free(self.scratch);
    }
};
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("graph_bytes,{d}\nlowering_session_bytes,{d}\nfixed_lowering_session_bytes,{d}\n", .{ @sizeOf(IR.Graph), @sizeOf(IR.LoweringSession), @sizeOf(IR.FixedLoweringSession) });
    try out.writeAll("case,route,ms,allocation_calls,retained_bytes,peak_bytes,credits,nodes,connections\n");
    for (std.meta.tags(suite.Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try suite.fixture(&source.writer, case);
        var parsed = Dot.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(init.gpa);
        if (!parsed.documentValid()) return error.InvalidFixture;
        const doc = &parsed.document.?;
        const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
        var counted = std.testing.FailingAllocator.init(init.gpa, .{});
        var previous = try IR.lowerComplete(counted.allocator(), doc, options);
        defer previous.deinit();
        const counts = previous.capacities();
        const bounds = try IR.capacityBounds(doc.capacities(), options);
        // First allocator-backed run has no scratch peak: bounds supply scratch.
        // A fixed run records it; subsequent runs can use both observed counts.
        const scratch_counts = blk: {
            const probe = try Buffers.init(init.gpa, counts, bounds.scratch);
            defer probe.deinit(init.gpa);
            const result = IR.lowerCompleteIn(doc, probe.bound, options);
            if (result.outcome == .failure) return result.outcome.failure;
            break :blk result.scratch_peak;
        };
        const used = try Buffers.init(init.gpa, counts, scratch_counts);
        defer used.deinit(init.gpa);
        const bounded = try Buffers.init(init.gpa, bounds.graph, bounds.scratch);
        defer bounded.deinit(init.gpa);
        var times: [4][11]u64 = undefined;
        var allocations: [4]usize = undefined;
        var retained: [4]usize = undefined;
        var peak: [4]usize = undefined;
        var credits: [4]u64 = @splat(0);
        for (0..15) |round| for (0..4) |offset| {
            const i = (round + offset) % 4;
            const route: Route = @fromBackingInt(@intCast(i));
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            var session: ?IR.FixedLoweringSession = null;
            var graph = switch (route) {
                .growable => try IR.lowerComplete(init.gpa, doc, options),
                .fixed_used, .fixed_bounds => blk: {
                    const result = IR.lowerCompleteIn(doc, if (route == .fixed_used) used.bound else bounded.bound, options);
                    if (result.outcome == .failure) return result.outcome.failure;
                    break :blk result.graph.?;
                },
                .fixed_session => blk: {
                    session = try IR.loweringSessionIn(doc, used.bound, options);
                    const progress = session.?.run();
                    credits[i] = progress.total_work;
                    break :blk try session.?.takeResult();
                },
            };
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            defer graph.deinit();
            if (session) |*operation| operation.deinit();
            if (round >= 4) times[i][round - 4] = @intCast(start.durationTo(end).raw.nanoseconds);
            allocations[i] = if (route == .growable) counted.alloc_index else 0;
            retained[i] = graph.retainedBytes();
            peak[i] = graph.peak_bytes;
            if (!std.meta.eql(counts, graph.capacities())) return error.ResultMismatch;
            std.mem.doNotOptimizeAway(graph.nodes);
        };
        for (std.meta.tags(Route), 0..) |route, i| {
            std.mem.sort(u64, &times[i], {}, std.sort.asc(u64));
            try out.print("{t},{t},{d:.4},{d},{d},{d},{d},{d},{d}\n", .{ case, route, @as(f64, @floatFromInt(times[i][5])) / 1e6, allocations[i], retained[i], peak[i], credits[i], counts.nodes, counts.connections });
        }
    }
    try out.flush();
}
