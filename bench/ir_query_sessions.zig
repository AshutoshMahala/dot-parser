//! Direct symbolic queries versus policy-bound sessions. Source construction,
//! lowering and name lookup are outside timings; initialization is included.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const C = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const R = dot.ir.Lowering(.{ .runtime_policy = true });
const Case = enum { singletons, sets, undirected, reopened, nested, product };
const Route = enum { direct, run, budget_4096, budget_64, budget_1, cancel_4096, runtime_4096 };
const Operation = enum { edge, membership };
const repetitions = 32;
const Polls = struct {
    count: u64 = 0,
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        return false;
    }
};
fn fixture(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll(if (case == .undirected) "graph {" else "digraph {");
    switch (case) {
        .singletons, .sets, .undirected => for (0..2000) |i| {
            switch (case) {
                .sets => try out.print("n{d}->{{a b c}};", .{i}),
                .undirected => try out.print("n{d}--n{d};", .{ i, i + 1 }),
                else => try out.print("n{d}->n{d};", .{ i, i + 1 }),
            }
        },
        .reopened => for (0..1000) |i| {
            try out.print("subgraph s{{a n{d}}}->x;", .{i});
        },
        .nested => {
            for (0..2000) |_| try out.writeAll("{");
            try out.writeAll("a b");
            for (0..2000) |_| try out.writeAll("}");
            try out.writeAll("->c;");
        },
        .product => {
            try out.writeAll("{");
            for (0..50000) |i| try out.print("n{d};", .{i});
            try out.writeAll("}->{");
            for (50000..100000) |i| try out.print("n{d};", .{i});
            try out.writeAll("};");
        },
    }
    try out.writeAll("z}");
}
fn answer(session: anytype, budget: u32, credits: *u64) !bool {
    while (true) {
        const result = if (budget == 0) session.run() else switch (@typeInfo(@TypeOf(session.advance(budget)))) {
            .error_union => try session.advance(budget),
            else => session.advance(budget),
        };
        if (result.outcome) |outcome| {
            credits.* += result.total_work;
            return switch (outcome) {
                .success => |found| found,
                .failure => |err| err,
            };
        }
    }
}
fn query(comptime operation: Operation, graph: *const IR.Graph, first: dot.ir.NodeId, last: dot.ir.NodeId, members: dot.ir.Membership, route: Route, counter: *Polls, credits: *u64) !bool {
    if (route == .direct) return if (operation == .edge) graph.hasEdge(first, last) else graph.contains(members, last);
    if (route == .cancel_4096) {
        const options = .{ .cancellation = dot.ir.Cancellation{ .context = counter, .is_requested = Polls.requested } };
        var s = if (operation == .edge) try C.hasEdgeSession(graph, first, last, options) else try C.containsSession(graph, members, last, options);
        defer s.deinit();
        return answer(&s, 4096, credits);
    }
    if (route == .runtime_4096) {
        const options = .{ .policy = .{ .execution = .{ .metering = true } } };
        var s = if (operation == .edge) try R.hasEdgeSession(graph, first, last, options) else try R.containsSession(graph, members, last, options);
        defer s.deinit();
        return answer(&s, 4096, credits);
    }
    var s = if (operation == .edge) try IR.hasEdgeSession(graph, first, last, .{}) else try IR.containsSession(graph, members, last, .{});
    defer s.deinit();
    return answer(&s, switch (route) {
        .run => 0,
        .budget_1 => 1,
        .budget_64 => 64,
        else => 4096,
    }, credits);
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("has_edge_state_bytes,{d}\ncontains_state_bytes,{d}\ncase,operation,route,queries,ms,credits,polls,answers,peak_bytes\n", .{ @sizeOf(IR.HasEdgeSession), @sizeOf(IR.ContainsSession) });
    for (std.meta.tags(Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixture(&source.writer, case);
        var result = try dot.ir.parse(init.gpa, source.written(), .{});
        defer result.deinit();
        const graph = result.ir() orelse return error.InvalidFixture;
        const first = (try graph.findNode(switch (case) {
            .singletons, .sets => "n1999",
            .undirected => "n2000",
            .reopened => "n999",
            .nested => "a",
            .product => "n49999",
        })).?;
        const last: dot.ir.NodeId = @fromBackingInt(@as(u32, @intCast(graph.nodes.len - 1)));
        const inside = (try graph.findNode(switch (case) {
            .singletons => "n2000",
            .sets, .nested => "c",
            .undirected => "n1999",
            .reopened => "x",
            .product => "n99999",
        })).?;
        const connection = graph.connections[graph.connections.len - 1];
        const members = if (case == .sets) connection.right.members else connection.left.members;
        inline for (.{ .edge, .membership }) |operation| {
            const routes = std.meta.tags(Route);
            var samples: [routes.len][11]u64 = undefined;
            var credits: [routes.len]u64 = undefined;
            var polls: [routes.len]u64 = undefined;
            var counts: [routes.len]u32 = undefined;
            var expected: ?u32 = null;
            const warmup = std.Io.Clock.Timestamp.now(init.io, .awake);
            var round: usize = 0;
            var sample: usize = 0;
            while (sample < 11) : (round += 1) {
                const measured = round >= 4 and warmup.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds >= 50_000_000;
                for (0..routes.len) |offset| {
                    const index = (round + offset) % routes.len;
                    var counter: Polls = .{};
                    var count: u32 = 0;
                    credits[index] = 0;
                    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                    for (0..repetitions) |i| {
                        const target = if (i % 2 == 0) last else if (operation == .membership and case != .sets) first else inside;
                        count += @intFromBool(try query(operation, graph, first, target, members, routes[index], &counter, &credits[index]));
                    }
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (expected) |n| {
                        if (n != count) return error.ResultMismatch;
                    } else expected = count;
                    counts[index] = count;
                    polls[index] = counter.count;
                    if (measured) samples[index][sample] = @intCast(start.durationTo(end).raw.nanoseconds);
                    std.mem.doNotOptimizeAway(count);
                }
                if (measured) sample += 1;
            }
            for (routes, 0..) |route, i| {
                std.mem.sort(u64, &samples[i], {}, std.sort.asc(u64));
                try out.print("{t},{t},{t},{d},{d:.5},{d},{d},{d},0\n", .{ case, operation, route, repetitions, @as(f64, @floatFromInt(samples[i][5])) / 1e6, credits[i], polls[i], counts[i] });
            }
        }
    }
    try out.flush();
}
