//! Direct pull iteration versus bounded streaming. Source generation/lowering,
//! attribute queries and explicit destruction are outside timed traversal.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const Case = enum { edges, sets, strict_overlap, reopened, nested, ports, product_prefix };
const routes = [_]struct { name: []const u8, budget: ?u32, hook: bool = false }{
    .{ .name = "direct", .budget = null },
    .{ .name = "run", .budget = 0 },
    .{ .name = "4096", .budget = 4096 },
    .{ .name = "64", .budget = 64 },
    .{ .name = "1", .budget = 1 },
    .{ .name = "cancel-4096", .budget = 4096, .hook = true },
};
const Polls = struct {
    count: u64 = 0,
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        return false;
    }
};
fn fixture(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll(if (case == .strict_overlap) "strict graph {" else "digraph {");
    switch (case) {
        .edges, .ports => for (0..2000) |i| {
            if (case == .ports)
                try out.print("n{d}:p->n{d}:q;", .{ i, i + 1 })
            else
                try out.print("n{d}->n{d};", .{ i, i + 1 });
        },
        .sets => for (0..1000) |i| {
            try out.print("n{d}->{{a b c}};", .{i});
        },
        .reopened => for (0..200) |i| {
            try out.print("subgraph s{{n{d}}}->x;", .{i});
        },
        .strict_overlap => for (0..400) |_| {
            try out.writeAll("{a b c d}--{a b c d};");
        },
        .nested => {
            for (0..2000) |_| try out.writeAll("{");
            try out.writeAll("a b");
            for (0..2000) |_| try out.writeAll("}");
            try out.writeAll("->c;");
        },
        .product_prefix => {
            try out.writeAll("{");
            for (0..5000) |i| try out.print("n{d};", .{i});
            try out.writeAll("}->{");
            for (5000..10000) |i| try out.print("n{d};", .{i});
            try out.writeAll("}");
        },
    }
    try out.writeAll("}");
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("session_bytes,{d}\ncase,route,ms,credits,polls,edges,peak_bytes\n", .{@sizeOf(IR.EdgeSession)});
    for (std.meta.tags(Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixture(&source.writer, case);
        var result = try dot.ir.parse(init.gpa, source.written(), .{});
        defer result.deinit();
        const graph = result.ir() orelse return error.InvalidFixture;
        var samples: [routes.len][11]u64 = undefined;
        var credits: [routes.len]u64 = @splat(0);
        var polls: [routes.len]u64 = @splat(0);
        var peaks: [routes.len]usize = undefined;
        var counts: [routes.len]u32 = undefined;
        var expected: ?u64 = null;
        // Tiny fixtures otherwise finish before this machine settles into its
        // sustained clock state. Keep at least four full, rotated warmups and
        // 50 ms of untimed warmup per fixture, then take eleven timed rounds.
        const warmup = std.Io.Clock.Timestamp.now(init.io, .awake);
        var round: usize = 0;
        var sample: usize = 0;
        while (sample < 11) : (round += 1) {
            const measured = round >= 4 and warmup.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds >= 50_000_000;
            for (0..routes.len) |offset| {
                const index = (round + offset) % routes.len;
                const route = routes[index];
                var counter: Polls = .{};
                var checksum: u64 = 0;
                var count: u32 = 0;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var direct: ?IR.Graph.EdgeIterator = null;
                var session: ?IR.EdgeSession = null;
                if (route.budget) |budget| {
                    session = try IR.edgeSession(graph, .{ .cancellation = if (route.hook) dot.ir.Cancellation{ .context = &counter, .is_requested = Polls.requested } else null });
                    while (true) {
                        const p = if (budget == 0) session.?.run() else session.?.advance(budget);
                        credits[index] = p.total_work;
                        if (p.edge) |view| {
                            checksum +%= @as(u64, @backingInt(view.edge.from)) + @backingInt(view.edge.to) + @backingInt(view.edge.first_connection);
                            count += 1;
                            if (case == .product_prefix and count == 1000) break;
                        }
                        if (p.outcome) |outcome| switch (outcome) {
                            .success => break,
                            .failure => |err| return err,
                        };
                    }
                } else {
                    direct = try graph.edgeIterator(.{});
                    while (try direct.?.next()) |view| {
                        checksum +%= @as(u64, @backingInt(view.edge.from)) + @backingInt(view.edge.to) + @backingInt(view.edge.first_connection);
                        count += 1;
                        if (case == .product_prefix and count == 1000) break;
                    }
                }
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (session) |*s| {
                    peaks[index] = s.peakBytes();
                    s.deinit();
                }
                if (direct) |*d| {
                    peaks[index] = d.peakBytes();
                    d.deinit();
                }
                if (expected) |n| {
                    if (n != checksum) return error.ResultMismatch;
                } else expected = checksum;
                counts[index] = count;
                polls[index] = counter.count;
                if (measured) samples[index][sample] = @intCast(start.durationTo(end).raw.nanoseconds);
                std.mem.doNotOptimizeAway(checksum);
            }
            if (measured) sample += 1;
        }
        for (routes, 0..) |route, i| {
            std.mem.sort(u64, &samples[i], {}, std.sort.asc(u64));
            try out.print("{t},{s},{d:.4},{d},{d},{d},{d}\n", .{ case, route.name, @as(f64, @floatFromInt(samples[i][5])) / 1e6, credits[i], polls[i], counts[i], peaks[i] });
        }
    }
    try out.flush();
}
