//! One-command comparison of direct and policy-bound resumable lowering.
//! Parsing, source construction, consuming output and explicit deinit are not
//! timed. Direct lowering's internal scratch cleanup happens before it returns.
const std = @import("std");
const dot = @import("dot_parser");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});
const Scheduled = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const Metered = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const Cancellable = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .cancellation = true } } });
const Runtime = dot.ir.Lowering(.{ .runtime_policy = true });
pub const Case = enum { edges, attributes, reopened, nested, long_name, symbolic_product, sparse_ports, dense_ports, port_chains };
const routes = [_]struct { name: []const u8, budget: ?u32, cancellation: bool = false, direct: enum { plain, metered, cancellable, runtime_off, runtime_on } = .plain }{
    .{ .name = "direct", .budget = null },
    .{ .name = "direct-metered", .budget = null, .direct = .metered },
    .{ .name = "direct-cancellable", .budget = null, .direct = .cancellable },
    .{ .name = "direct-runtime-off", .budget = null, .direct = .runtime_off },
    .{ .name = "direct-runtime-on", .budget = null, .direct = .runtime_on },
    .{ .name = "session-run", .budget = 0 },
    .{ .name = "session-4096", .budget = 4096 },
    .{ .name = "session-1", .budget = 1 },
    .{ .name = "cancel-4096", .budget = 4096, .cancellation = true },
};
const Polls = struct {
    count: u64 = 0,
    fn requested(context: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(context.?));
        self.count += 1;
        return false;
    }
};
pub fn fixture(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll("digraph {");
    switch (case) {
        .edges => for (0..2000) |i| {
            try out.print("n{d}->n{d};", .{ i, i + 1 });
        },
        .sparse_ports, .dense_ports => for (0..2000) |i| {
            if (case == .dense_ports or i % 100 == 0)
                try out.print("n{d}:p:n->n{d}:q;", .{ i, i + 1 })
            else
                try out.print("n{d}->n{d};", .{ i, i + 1 });
        },
        .port_chains => for (0..1000) |i| {
            try out.print("n{d}:p:n", .{i * 8});
            for (1..8) |k| try out.print("->n{d}:p:n", .{i * 8 + k});
            try out.writeAll(";");
        },
        .attributes => for (0..2000) |i| {
            try out.print("n{d}[color=red shape=box weight={d}];", .{ i, i });
        },
        .reopened => for (0..400) |i| {
            try out.print("node[color=v{d}];subgraph s{{node[shape=box];n{d}}}->x;", .{ i, i });
        },
        .nested => {
            try out.writeAll("node[color=red];");
            for (0..2000) |_| try out.writeAll("{");
            try out.writeAll("a->b");
            for (0..2000) |_| try out.writeAll("}");
        },
        .long_name => {
            try out.writeAll("\"a\"/*");
            try out.splatByteAll('x', 65536);
            try out.writeAll("*/+\"b\"->c");
        },
        .symbolic_product => {
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
    try out.print("lowering_session_bytes,{d}\n", .{@sizeOf(Scheduled.LoweringSession)});
    try out.writeAll("case,route,ms,credits,polls,nodes,connections,retained_bytes,peak_bytes\n");
    for (std.meta.tags(Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixture(&source.writer, case);
        var parsed = Dot.parseAndValidate(init.gpa, source.written(), dot.diagnostic.discard, .{});
        defer parsed.deinit(init.gpa);
        if (!parsed.documentValid()) return error.InvalidFixture;
        const doc = &parsed.document.?;
        const interpretation = Dot.interpretation(doc, .{});
        var times: [routes.len][11]u64 = undefined;
        var credits: [routes.len]u64 = @splat(0);
        var polls: [routes.len]u64 = @splat(0);
        var retained: [routes.len]usize = undefined;
        var peaks: [routes.len]usize = undefined;
        var nodes: usize = 0;
        var connections: usize = 0;
        for (0..15) |round| for (0..routes.len) |offset| {
            const index = (round + offset) % routes.len;
            const route = routes[index];
            var counter: Polls = .{};
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            var session: ?Scheduled.LoweringSession = null;
            var result = if (route.budget) |budget| blk: {
                session = try Scheduled.loweringSession(init.gpa, doc, .{ .interpretation = interpretation, .cancellation = if (route.cancellation) dot.ir.Cancellation{ .context = &counter, .is_requested = Polls.requested } else null });
                var progress = if (budget == 0) session.?.run() else session.?.advance(budget);
                while (progress.outcome == null) progress = session.?.advance(budget);
                credits[index] = progress.total_work;
                break :blk try session.?.takeResult();
            } else switch (route.direct) {
                .plain => try IR.lowerComplete(init.gpa, doc, .{ .interpretation = interpretation }),
                .metered => try Metered.lowerComplete(init.gpa, doc, .{ .interpretation = interpretation }),
                .cancellable => try Cancellable.lowerComplete(init.gpa, doc, .{ .interpretation = interpretation, .cancellation = dot.ir.Cancellation{ .context = &counter, .is_requested = Polls.requested } }),
                .runtime_off, .runtime_on => try Runtime.lowerComplete(init.gpa, doc, .{
                    .interpretation = interpretation,
                    .policy = .{ .execution = .{ .metering = route.direct == .runtime_on } },
                }),
            };
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            defer result.deinit();
            if (session) |*operation| operation.deinit();
            if (round >= 4) times[index][round - 4] = @intCast(start.durationTo(end).raw.nanoseconds);
            polls[index] = counter.count;
            retained[index] = result.retainedBytes();
            peaks[index] = result.peak_bytes;
            if (round == 0 and offset == 0) {
                nodes = result.nodes.len;
                connections = result.connections.len;
            }
            if (nodes != result.nodes.len or connections != result.connections.len) return error.ResultMismatch;
            std.mem.doNotOptimizeAway(result.nodes);
        };
        for (routes, 0..) |route, index| {
            std.mem.sort(u64, &times[index], {}, std.sort.asc(u64));
            try out.print("{t},{s},{d:.4},", .{ case, route.name, @as(f64, @floatFromInt(times[index][5])) / 1e6 });
            if (route.budget == null) try out.writeAll("not_reported") else try out.print("{d}", .{credits[index]});
            try out.print(",{d},{d},{d},{d},{d}\n", .{ polls[index], nodes, connections, retained[index], peaks[index] });
        }
    }
    try out.flush();
}
