//! One-command attribute-session report. Parsing, lowering, materialization and
//! handle lookup are outside timings; session initialization/cleanup are inside.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const C = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const R = dot.ir.Lowering(.{ .runtime_policy = true });
const Route = enum { direct, run, budget_4096, budget_64, budget_1, cancel_4096, runtime_4096 };
const Case = enum { indexed, long_key, strict_updates, ports, reopened };
const repetitions = 32;
const Result = struct { checksum: u64 = 0, credits: u64 = 0, peak: usize = 0 };
const Polls = struct {
    count: u64 = 0,
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Polls = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        return false;
    }
};
fn consume(result: *Result, attribute: anytype) void {
    result.checksum +%= 1 + @as(u64, attribute.resolved.attribute orelse 0);
    std.mem.doNotOptimizeAway(attribute);
}
fn drain(comptime all: bool, session: anytype, budget: u32) !Result {
    var result: Result = .{};
    while (true) {
        const p = if (budget == 0) session.run() else switch (@typeInfo(@TypeOf(session.advance(budget)))) {
            .error_union => try session.advance(budget),
            else => session.advance(budget),
        };
        if (all) if (p.attribute) |attribute| consume(&result, attribute);
        if (p.outcome) |outcome| {
            switch (outcome) {
                .success => |answer| if (!all) {
                    if (answer) |attribute| consume(&result, attribute);
                },
                .failure => |err| return err,
            }
            result.credits = p.total_work;
            result.peak = session.peakBytes();
            return result;
        }
    }
}
fn query(comptime all: bool, comptime folded: bool, view: anytype, key: []const u8, route: Route, polls: *Polls) !Result {
    if (route == .direct) {
        var result: Result = .{};
        if (all) {
            var iterator = if (folded) try view.attributesWith(.{}) else try view.attributes(.{});
            defer if (!folded) iterator.deinit();
            while (try iterator.next()) |attribute| consume(&result, attribute);
            if (!folded) result.peak = iterator.peakBytes();
        } else if (try view.attributeWith(key, .{})) |attribute| consume(&result, attribute);
        return result;
    }
    if (route == .cancel_4096) {
        const options = .{ .cancellation = dot.ir.Cancellation{ .context = polls, .is_requested = Polls.requested } };
        var s = if (all) try C.attributesSession(view, options) else try C.attributeSession(view, key, options);
        defer s.deinit();
        return drain(all, &s, 4096);
    }
    if (route == .runtime_4096) {
        const options = .{ .policy = .{ .execution = .{ .metering = true } } };
        var s = if (all) try R.attributesSession(view, options) else try R.attributeSession(view, key, options);
        defer s.deinit();
        return drain(all, &s, 4096);
    }
    var s = if (all) try IR.attributesSession(view, .{}) else try IR.attributeSession(view, key, .{});
    defer s.deinit();
    return drain(all, &s, switch (route) {
        .run => 0,
        .budget_1 => 1,
        .budget_64 => 64,
        else => 4096,
    });
}
fn measure(init: std.process.Init, out: *std.Io.Writer, name: []const u8, comptime folded: bool, view: anytype, key: []const u8) !void {
    inline for (.{ false, true }) |all| {
        const routes = std.meta.tags(Route);
        var samples: [routes.len][11]u64 = undefined;
        var results: [routes.len]Result = undefined;
        var polls: [routes.len]u64 = undefined;
        var expected: ?u64 = null;
        var expected_credits: ?u64 = null;
        const warmup = std.Io.Clock.Timestamp.now(init.io, .awake);
        var round: usize = 0;
        var sample: usize = 0;
        while (sample < 11) : (round += 1) {
            const measured = round >= 4 and warmup.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds >= 50_000_000;
            for (0..routes.len) |offset| {
                const index = (round + offset) % routes.len;
                var counter: Polls = .{};
                var sum: Result = .{};
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                for (0..repetitions) |_| {
                    const value = try query(all, folded, view, key, routes[index], &counter);
                    sum.checksum +%= value.checksum;
                    sum.credits += value.credits;
                    sum.peak = @max(sum.peak, value.peak);
                }
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (expected) |n| {
                    if (n != sum.checksum) return error.ResultMismatch;
                } else expected = sum.checksum;
                if (routes[index] != .direct) {
                    if (expected_credits) |n| {
                        if (n != sum.credits) return error.CreditMismatch;
                    } else expected_credits = sum.credits;
                }
                results[index] = sum;
                polls[index] = counter.count;
                if (measured) samples[index][sample] = @intCast(start.durationTo(end).raw.nanoseconds);
                std.mem.doNotOptimizeAway(sum);
            }
            if (measured) sample += 1;
        }
        for (routes, 0..) |route, i| {
            std.mem.sort(u64, &samples[i], {}, std.sort.asc(u64));
            try out.print("{s},{s},{t},{d},{d:.5},{d},{d},{d},{d}\n", .{ name, if (all) "all" else "one", route, repetitions, @as(f64, @floatFromInt(samples[i][5])) / 1e6, results[i].credits, polls[i], results[i].checksum, results[i].peak });
        }
        try out.flush();
    }
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("attribute_state_bytes,{d}\nattributes_state_bytes,{d}\npartial_attribute_state_bytes,{d}\npartial_attributes_state_bytes,{d}\ncase,operation,route,queries,ms,credits,polls,checksum,peak_bytes\n", .{
        @sizeOf(IR.AttributeSession), @sizeOf(IR.AttributesSession), @sizeOf(IR.PartialAttributeSession), @sizeOf(IR.PartialAttributesSession),
    });
    const long_key: [2048]u8 = @splat('k');
    for (std.meta.tags(Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try source.writer.writeAll(if (case == .ports) "strict graph {" else "strict digraph {");
        switch (case) {
            .indexed => {
                try source.writer.writeAll("a[");
                for (0..128) |i| try source.writer.print("k{d}=v;", .{i});
                try source.writer.writeAll("color=red]; graph[color=blue];");
            },
            .long_key => try source.writer.print("a[\"{s}\"=v];", .{long_key}),
            .strict_updates => for (0..2000) |i| {
                try source.writer.print("a->b[color=c{d} label=v{d}];", .{ i, i });
            },
            .ports => {
                try source.writer.writeAll("a--b;");
                for (0..1000) |_| try source.writer.writeAll("b:q--a:p[label=x];");
            },
            .reopened => {
                try source.writer.writeAll("a;");
                for (0..1000) |i| try source.writer.print("a->subgraph s{{b n{d}}}[color=red];", .{i});
            },
        }
        try source.writer.writeAll("}");
        var result = try dot.ir.parse(init.gpa, source.written(), .{});
        defer result.deinit();
        const graph = result.ir() orelse return error.InvalidFixture;
        const node = try graph.nodeView((try graph.findNode("a")).?);
        if (case == .indexed or case == .long_key) {
            try measure(init, out, @tagName(case), false, node, if (case == .long_key) &long_key else "color");
            if (case == .indexed) try measure(init, out, "scope", false, try graph.scopeView(.root), "color");
        } else {
            const edge = try graph.edgeView(.{ .from = node.id, .to = (try graph.findNode("b")).?, .operator = if (case == .ports) .undirected else .directed, .first_connection = @fromBackingInt(0) });
            try measure(init, out, @tagName(case), false, edge, if (case == .ports) "tailport" else "color");
            if (case == .strict_updates) {
                var materialized = try graph.materialize(.{});
                defer materialized.deinit();
                var edges = materialized.edgeIterator();
                try measure(init, out, "folded", true, edges.next().?, "color");
            }
        }
    }
}
