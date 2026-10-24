//! Direct materialization versus opt-in bounded sessions. Parse/lower, output
//! consumption and destruction are outside build timing. Runs are serial.
const std = @import("std");
const dot = @import("dot_parser");
const fixtures = @import("ir_materialized_attributes.zig");
const Graph = dot.ir.Lowering(.{}).Graph;
const budgets = [_]?u32{ null, 0, 1, 64, 4096 };
const warmups = 12;
const sample_count = 15;

const Polls = struct {
    count: u64 = 0,
    fn requested(context: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(context.?));
        self.count += 1;
        return false;
    }
    fn token(self: *Polls) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};
fn build(comptime attributes: bool, ir: *const Graph, budget: ?u32, cancellation: ?dot.ir.Cancellation, work: *u64) !Graph.MaterializationSession(attributes).Result {
    const amount = budget orelse return ir.materialize(.{ .attributes = attributes, .cancellation = cancellation });
    var session = try ir.materializationSession(.{ .attributes = attributes, .cancellation = cancellation });
    defer session.deinit();
    var p = if (amount == 0) session.run() else session.advance(amount);
    while (p.outcome == null) p = session.advance(amount);
    work.* = p.total_work;
    return session.takeResult();
}
fn consume(comptime attributes: bool, graph: anytype) u64 {
    var sum: u64 = 0;
    if (!attributes) {
        for (graph.edges) |edge| sum +%= @as(u64, @backingInt(edge.from)) + @backingInt(edge.to);
        return sum;
    }
    var iterator = graph.edgeIterator();
    while (iterator.next()) |edge| {
        sum +%= @as(u64, @backingInt(edge.edge.from)) + @backingInt(edge.edge.to);
        var values = edge.attributes();
        while (values.next()) |attribute| sum +%= attribute.resolved.attribute orelse 0;
    }
    return sum;
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("session_state_bytes,topology={d},attributes={d}\n", .{ @sizeOf(Graph.MaterializationSession(false)), @sizeOf(Graph.MaterializationSession(true)) });
    try out.writeAll("case,attributes,cancellation,mode,median_ms,credits,polls,edges,retained_bytes,peak_bytes,outcome\n");
    // One unreported folding traversal warms the process before measuring.
    // Otherwise CPU ramp-up dominates the first fixture, even with per-route
    // warmups. Keep the tiny plain/defaults builds after the larger cases.
    const cases = std.meta.tags(fixtures.Case);
    for (0..cases.len + 1) |case_index| {
        const case = cases[((case_index -| 1) + 2) % cases.len];
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixtures.sourceFor(&source.writer, case);
        var parsed = try dot.ir.parse(init.gpa, source.written(), .{});
        defer parsed.deinit();
        const ir = parsed.ir() orelse return error.BadFixture;
        inline for (.{ true, false }) |attributes| for ([_]bool{ false, true }) |cancellable| {
            var samples: [budgets.len][sample_count]u64 = undefined;
            var credits: [budgets.len]u64 = @splat(0);
            var polls: [budgets.len]u64 = @splat(0);
            var retained: [budgets.len]usize = @splat(0);
            var peak: [budgets.len]?usize = @splat(null);
            var count: usize = 0;
            var expected: ?u64 = null;
            // Rotate starting mode; warm every route before timing small fixtures.
            for (0..warmups + sample_count) |round| for (0..budgets.len) |offset| {
                const index = (offset + round) % budgets.len;
                var counter: Polls = .{};
                const cancellation: ?dot.ir.Cancellation = if (cancellable) counter.token() else null;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var graph = build(attributes, ir, budgets[index], cancellation, &credits[index]) catch |err| {
                    if (case != .rejected_product or err != error.PairLimit) return err;
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (round >= warmups) samples[index][round - warmups] = @intCast(start.durationTo(end).raw.nanoseconds);
                    polls[index] = counter.count;
                    continue;
                };
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                defer graph.deinit();
                if (round >= warmups) samples[index][round - warmups] = @intCast(start.durationTo(end).raw.nanoseconds);
                polls[index] = counter.count;
                const checksum = consume(attributes, &graph);
                if (expected) |value| {
                    if (value != checksum) return error.ResultMismatch;
                } else expected = checksum;
                std.mem.doNotOptimizeAway(checksum);
                count = graph.edges.len;
                retained[index] = if (attributes) graph.retainedBytes() else graph.storage.len * @sizeOf(dot.ir.Edge);
                peak[index] = graph.peak_bytes;
            };
            if (case_index == 0) continue;
            for (budgets, 0..) |budget, index| {
                std.mem.sort(u64, &samples[index], {}, std.sort.asc(u64));
                const name: []const u8 = if (budget == null) "direct" else switch (budget.?) {
                    0 => "run",
                    1 => "budget_1",
                    64 => "budget_64",
                    else => "budget_4096",
                };
                try out.print("{t},{},{},{s},{d:.4},{d},{d},{d},{d},{?d},{s}\n", .{ case, attributes, cancellable, name, @as(f64, @floatFromInt(samples[index][sample_count / 2])) / 1e6, credits[index], polls[index], count, retained[index], peak[index], if (case == .rejected_product) "PairLimit" else "success" });
            }
            try out.flush();
        };
    }
}
