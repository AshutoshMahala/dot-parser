//! Direct materialization versus opt-in bounded sessions. Parse/lower, output
//! consumption and destruction are outside build timing. Runs are serial.
const std = @import("std");
const dot = @import("dot_parser");
const fixtures = @import("ir_materialized_attributes.zig");
const Graph = dot.ir.Lowering(.{}).Graph;
const budgets = [_]?u32{ null, 0, 1, 64, 4096 };

fn build(ir: *const Graph, budget: ?u32, work: *u64) !Graph.Materialized {
    const amount = budget orelse return ir.materialize(.{});
    var session = try ir.materializationSession(.{});
    defer session.deinit();
    var p = if (amount == 0) session.run() else session.advance(amount);
    while (p.outcome == null) p = session.advance(amount);
    work.* = p.total_work;
    return session.takeResult();
}
fn consume(graph: *const Graph.Materialized) u64 {
    var sum: u64 = 0;
    var iterator = graph.edgeIterator();
    while (iterator.next()) |edge| {
        sum +%= @as(u64, @backingInt(edge.edge.from)) + @backingInt(edge.edge.to);
        var attributes = edge.attributes();
        while (attributes.next()) |attribute| sum +%= attribute.resolved.attribute orelse 0;
    }
    return sum;
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("session_state_bytes,topology={d},attributes={d}\n", .{ @sizeOf(Graph.MaterializationSession(false)), @sizeOf(Graph.MaterializationSession(true)) });
    try out.writeAll("case,mode,median_ms,credits,edges,retained_bytes,peak_bytes,outcome\n");
    for (std.meta.tags(fixtures.Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixtures.sourceFor(&source.writer, case);
        var parsed = try dot.ir.parse(init.gpa, source.written(), .{});
        defer parsed.deinit();
        const ir = parsed.ir() orelse return error.BadFixture;
        var samples: [budgets.len][9]u64 = undefined;
        var credits: [budgets.len]u64 = @splat(0);
        var retained: [budgets.len]usize = @splat(0);
        var peak: [budgets.len]?usize = @splat(null);
        var count: usize = 0;
        var expected: ?u64 = null;
        // Rotate starting mode, with two warmup rounds for each.
        for (0..11) |round| for (0..budgets.len) |offset| {
            const index = (offset + round) % budgets.len;
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            var graph = build(ir, budgets[index], &credits[index]) catch |err| {
                if (case != .rejected_product or err != error.PairLimit) return err;
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (round >= 2) samples[index][round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
                continue;
            };
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            defer graph.deinit();
            if (round >= 2) samples[index][round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
            const checksum = consume(&graph);
            if (expected) |value| {
                if (value != checksum) return error.ResultMismatch;
            } else expected = checksum;
            std.mem.doNotOptimizeAway(checksum);
            count = graph.edges.len;
            retained[index] = graph.retainedBytes();
            peak[index] = graph.peak_bytes;
        };
        for (budgets, 0..) |budget, index| {
            std.mem.sort(u64, &samples[index], {}, std.sort.asc(u64));
            const name: []const u8 = if (budget == null) "direct" else switch (budget.?) {
                0 => "run",
                1 => "budget_1",
                64 => "budget_64",
                else => "budget_4096",
            };
            try out.print("{t},{s},{d:.4},{d},{d},{d},{?d},{s}\n", .{ case, name, @as(f64, @floatFromInt(samples[index][4])) / 1e6, credits[index], count, retained[index], peak[index], if (case == .rejected_product) "PairLimit" else "success" });
        }
        try out.flush();
    }
}
