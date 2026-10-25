const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const equal = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

fn check(initial: anytype, expected: @TypeOf(initial).Answer) !void {
    var total: ?u64 = null;
    for ([_]u32{ 0, 1, 2, 7, 64, 4096, std.math.maxInt(u32) }) |budget| {
        var s = initial;
        defer s.deinit();
        var consumed: u64 = 0;
        var turn: usize = 0;
        while (true) : (turn += 1) {
            const zero = s.advance(0);
            try equal(@as(u32, 0), zero.work_used);
            try equal(consumed, zero.total_work);
            try expect(zero.outcome == null);
            const grant = if (budget == 0) ([_]u32{ 1, 7, 2, 64 })[turn % 4] else budget;
            const p = s.advance(grant);
            try expect(p.work_used > 0 and p.work_used <= grant);
            consumed += p.work_used;
            try equal(consumed, p.total_work);
            if (p.outcome) |o| {
                try equal(expected, o.success);
                break;
            }
        }
        if (total) |n| try equal(n, consumed) else total = consumed;
        try equal(@as(usize, 0), s.peakBytes());
        s.cancel(); // Success cannot turn into cancellation or repeat work.
        try equal(s.outcome, s.advance(0).outcome);
        try equal(@as(u32, 0), s.run().work_used);
    }
    var running = initial;
    defer running.deinit();
    try equal(expected, running.run().outcome.?.success);
    try equal(total.?, running.total_work);
}

fn checkGraph(graph: anytype) !void {
    const data = if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph;
    var nodes = graph.nodeIterator();
    while (nodes.next()) |from| {
        var targets = graph.nodeIterator();
        while (targets.next()) |to| {
            try check(try IR.hasEdgeSession(graph, from.id, to.id, .{}), try graph.hasEdge(from.id, to.id));
        }
        // All body versions, including empty/reopened sets, not just those
        // selected by connections. Singleton membership shares the same API.
        for (0..data.bodies.len) |i| {
            const members: dot.ir.Membership = @fromBackingInt(@as(u32, @intCast(i)));
            try check(try IR.containsSession(graph, members, from.id, .{}), try graph.contains(members, from.id));
        }
        for (0..data.nodes.len) |i| {
            const members: dot.ir.Membership = @fromBackingInt(@as(u32, 1 << 31) | @as(u32, @intCast(i)));
            try check(try IR.containsSession(graph, members, from.id, .{}), try graph.contains(members, from.id));
        }
    }
}

test "query sessions agree with direct answers for complete and partial snapshots" {
    for ([_][]const u8{
        "digraph {a;b}",
        "digraph {a->a;a->b;b->c;a->b;z}",
        "graph {a:p--b:q;{a b}--{c d};z}",
        "strict graph {a--b;b--a;{a b}--{a b};z}",
        "digraph {a->{};{}->b;subgraph s{a a}->x;subgraph s{}->y;subgraph s{b}->x;subgraph s{a}->z;w}",
        "digraph {subgraph s{a;subgraph t{b->c}}->d;subgraph t{a};subgraph s{e}->f;z}",
    }) |source| {
        var result = try dot.ir.parse(a, source, .{});
        defer result.deinit();
        try checkGraph(result.ir().?);
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        try checkGraph(partial.ir().?);
    }
    for ([_][]const u8{
        "digraph {a->b;broken->;b->c;z}",
        "graph {a--b;subgraph s{b c;bad--",
        "digraph {a;b;",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        try checkGraph(result.ir().?);
    }
}

test "query pauses and lifetime exhaustion never publish absent answers" {
    var result = try dot.ir.parse(a, "graph {subgraph s{a b}--c;subgraph s{d}--e;z}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const x = (try graph.findNode("z")).?;
    var complete = try IR.hasEdgeSession(graph, x, x, .{});
    defer complete.deinit();
    const count = complete.run().total_work;
    for (0..count + 1) |limit| {
        var reference = try IR.hasEdgeSession(graph, x, x, .{ .limits = .{ .max_work = limit } });
        defer reference.deinit();
        const expected = reference.run();
        for ([_]u32{ 1, 2, 7, 4096 }) |budget| {
            var s = try IR.hasEdgeSession(graph, x, x, .{ .limits = .{ .max_work = limit } });
            defer s.deinit();
            while (s.advance(budget).outcome == null) {}
            try equal(expected.outcome, s.outcome);
            try equal(expected.total_work, s.total_work);
            try equal(reference.cursor, s.cursor);
            try equal(reference.stage, s.stage);
            try equal(reference.connection, s.connection);
            if (limit < count) try equal(error.WorkLimit, s.outcome.?.failure) else try equal(false, s.outcome.?.success);
            s.cancel();
            try equal(expected.outcome, s.run().outcome);
        }
    }
    var s = try IR.hasEdgeSession(graph, x, x, .{ .limits = .{ .max_work = 0 } });
    defer s.deinit();
    try expect(s.advance(0).outcome == null);
    try equal(error.WorkLimit, s.advance(1).outcome.?.failure);
}

const Stop = struct {
    calls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    work: ?*const u64 = null,
    previous: u64 = 0,
    max_gap: u64 = 0,
    fn requested(ctx: ?*anyopaque) bool {
        const s: *Stop = @ptrCast(@alignCast(ctx.?));
        s.calls += 1;
        if (s.work) |work| {
            s.max_gap = @max(s.max_gap, work.* - s.previous);
            s.previous = work.*;
        }
        return s.calls >= s.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "query hooks poll at entry zero grants resumes and configured intervals" {
    var result = try dot.ir.parse(a, "graph {a--b;{a b c}--{d e f};z}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const z = (try graph.findNode("z")).?;
    inline for (.{ 1, 4, 64 }) |interval| {
        const P = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } });
        var stop: Stop = .{};
        var s = try P.hasEdgeSession(graph, z, z, .{ .cancellation = stop.token() });
        defer s.deinit();
        stop.work = &s.total_work;
        while (true) {
            const calls = stop.calls;
            _ = s.advance(0);
            try equal(calls + 1, stop.calls);
            if (s.advance(7).outcome != null) break;
        }
        try expect(stop.max_gap <= interval);
        const calls = stop.calls;
        for (0..calls) |i| {
            stop = .{ .at = i + 1 };
            var current = P.hasEdgeSession(graph, z, z, .{ .cancellation = stop.token() }) catch |err| {
                try equal(@as(usize, 0), i);
                try equal(error.Cancelled, err);
                continue;
            };
            defer current.deinit();
            while (current.outcome == null) {
                _ = current.advance(0);
                _ = current.advance(7);
            }
            try equal(error.Cancelled, current.outcome.?.failure);
            const terminal_calls = stop.calls;
            _ = current.run();
            try equal(terminal_calls, stop.calls);
        }
    }
}

test "query runtime policies validate once and disabled execution stays disabled" {
    const R = dot.ir.Lowering(.{ .runtime_policy = true });
    var result = try dot.ir.parse(a, "digraph {a->b}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const from = (try graph.findNode("a")).?;
    const to = (try graph.findNode("b")).?;
    var stop: Stop = .{ .at = 1 };
    var s = try R.hasEdgeSession(graph, from, to, .{ .cancellation = stop.token() });
    defer s.deinit();
    try std.testing.expectError(error.MeteringDisabled, s.advance(1));
    try equal(@as(u64, 0), s.total_work);
    try equal(true, s.run().outcome.?.success);
    try equal(@as(u64, 0), stop.calls);
    stop = .{};
    var enabled = try R.hasEdgeSession(graph, from, to, .{ .cancellation = stop.token(), .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = 4 } } });
    defer enabled.deinit();
    try expect((try enabled.advance(0)).outcome == null);
    while ((try enabled.advance(1)).outcome == null) {}
    try equal(true, enabled.outcome.?.success);
    try expect(stop.calls > 1);
    try std.testing.expectError(error.InvalidCancellationInterval, R.hasEdgeSession(graph, from, to, .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    var plain = try dot.ir.Lowering(.{}).hasEdgeSession(graph, from, to, .{});
    defer plain.deinit();
    try equal(true, plain.run().outcome.?.success);
    const typed: IR.HasEdgeSession.Options = .{};
    try expect(IR.HasEdgeSession.Options == IR.ContainsSession.Options);
    try expect(IR.HasEdgeSession.Options == IR.PartialHasEdgeSession.Options);
    var typed_session = try IR.hasEdgeSession(graph, from, to, typed);
    defer typed_session.deinit();
    try equal(true, typed_session.run().outcome.?.success);
    const typed_runtime: R.ContainsSession.Options = .{ .policy = .{ .execution = .{ .metering = true } } };
    var typed_member = try R.containsSession(graph, graph.connections[0].left.members, from, typed_runtime);
    defer typed_member.deinit();
    try equal(true, (try typed_member.advance(1)).outcome.?.success);
    var manual = try IR.hasEdgeSession(graph, from, to, .{});
    defer manual.deinit();
    manual.cancel();
    try equal(error.Cancelled, manual.advance(0).outcome.?.failure);
}

test "query constructors check supplied handles and borrow without allocating" {
    var result = try dot.ir.parse(a, "digraph {{a b}->{c d};z}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const node = (try graph.findNode("a")).?;
    const bad: dot.ir.NodeId = @fromBackingInt(@as(u32, @intCast(graph.nodes.len)));
    try std.testing.expectError(error.InvalidHandle, IR.hasEdgeSession(graph, node, bad, .{}));
    try std.testing.expectError(error.InvalidHandle, IR.hasEdgeSession(graph, bad, node, .{}));
    try std.testing.expectError(error.InvalidHandle, IR.containsSession(graph, @fromBackingInt(@as(u32, @intCast(graph.bodies.len))), node, .{}));
    try std.testing.expectError(error.InvalidHandle, IR.containsSession(graph, @fromBackingInt(@as(u32, 1 << 31) | @backingInt(bad)), node, .{}));
    var s = try IR.hasEdgeSession(graph, node, (try graph.findNode("d")).?, .{ .limits = .{ .max_bytes = 0, .max_edges = 0, .max_pairs = 0 } });
    defer s.deinit();
    try equal(true, s.run().outcome.?.success);
    try equal(@as(usize, 0), s.peakBytes());
    // Even a graph backed by an allocator that refuses any new allocation is
    // queryable. The query has no allocator argument or scratch reservation.
    var memory = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var borrowed = graph.*;
    borrowed.allocator = memory.allocator();
    try checkGraph(&borrowed);
    try equal(@as(usize, 0), memory.allocations);
}

test "membership search pauses within reopened and deep scopes with exact limits" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    for (0..128) |_| try source.writer.writeAll("{");
    try source.writer.writeAll("a");
    for (0..128) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("->x;");
    for (0..128) |_| try source.writer.writeAll("subgraph s{a}->x;");
    try source.writer.writeAll("subgraph s{b}->y;z}");
    var result = try dot.ir.parse(a, source.written(), .{});
    defer result.deinit();
    const graph = result.ir().?;
    const members = graph.connections[graph.connections.len - 1].left.members;
    for ([_][]const u8{ "a", "b", "x", "z" }) |name| {
        const node = (try graph.findNode(name)).?;
        var initial = try IR.containsSession(graph, members, node, .{});
        defer initial.deinit();
        try check(initial, try graph.contains(members, node));
        var reference = initial;
        const count = reference.run().total_work;
        // Check both sides of completion, including a shortfall inside a
        // binary search. A zero-byte allowance is sufficient for every query.
        for ([_]u64{ 0, 1, 2, 3, count / 2, count - 1, count }) |limit| {
            var expected = initial;
            expected.max_work = limit;
            _ = expected.run();
            for ([_]u32{ 1, 3, 64, 4096 }) |budget| {
                var s = initial;
                s.max_work = limit;
                while (s.advance(budget).outcome == null) {}
                try equal(expected.outcome, s.outcome);
                try equal(expected.total_work, s.total_work);
                try equal(expected.cursor, s.cursor);
            }
        }
    }
    // Explicit and inherited limits are both lifetime limits, not per-resume.
    var borrowed = graph.*;
    borrowed.limits.max_work = 0;
    var stopped = try IR.containsSession(&borrowed, members, (try graph.findNode("a")).?, .{});
    defer stopped.deinit();
    try equal(error.WorkLimit, stopped.run().outcome.?.failure);
}

test "generic and native encoded query sessions preserve interpreted operators" {
    inline for (.{ .utf8, .utf16, .utf32 }) |encoding| {
        const P = dot.Profile(.{ .source_encodings = &.{encoding}, .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
        const Native = dot.ir.Lowering(.{ .source_encodings = &.{encoding}, .policy = .{ .execution = .{ .metering = true } } });
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        for ("graph {a->b;{b c}--d;subgraph s{a}->d;subgraph s{b}->c;z}") |byte| switch (encoding) {
            .utf8 => try source.writer.writeByte(byte),
            .utf16 => try source.writer.writeInt(u16, byte, .little),
            .utf32 => try source.writer.writeInt(u32, byte, .big),
            else => unreachable,
        };
        var parsed = if (encoding == .utf8) P.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{}) else try P.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{ .encoding = switch (encoding) {
            .utf16 => .utf16le,
            .utf32 => .utf32be,
            else => unreachable,
        } });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        var graph = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer graph.deinit();
        var nodes = graph.nodeIterator();
        while (nodes.next()) |from| {
            var targets = graph.nodeIterator();
            while (targets.next()) |to| try check(try Native.hasEdgeSession(&graph, from.id, to.id, .{}), try graph.hasEdge(from.id, to.id));
            for (graph.connections) |connection| try check(try Native.containsSession(&graph, connection.left.members, from.id, .{}), try graph.contains(connection.left.members, from.id));
        }
    }
}

// Independent, deliberately one-credit model of the original query machine.
// This is not a second production driver: it checks the batched implementation
// at intermediate pauses, not just its eventual answer or total work.
fn referenceMember(cursor: anytype, graph: anytype) ?bool {
    const node_bit: u32 = 1 << 31;
    if (cursor.phase == .start) {
        if (cursor.members & node_bit != 0) return cursor.members & ~node_bit == cursor.node;
        cursor.body = graph.bodies[cursor.members].first;
        cursor.phase = .body;
    }
    const positions = graph.posting_positions[graph.posting_offsets[cursor.node]..graph.posting_offsets[cursor.node + 1]];
    const body = graph.bodies[cursor.body];
    if (cursor.phase == .body) {
        cursor.lo = 0;
        cursor.hi = @intCast(positions.len);
        cursor.phase = .search;
    } else {
        const mid = cursor.lo + (cursor.hi - cursor.lo) / 2;
        if (positions[mid] < body.start) cursor.lo = mid + 1 else cursor.hi = mid;
    }
    if (cursor.lo < cursor.hi) return null;
    if (cursor.lo < positions.len and positions[cursor.lo] < body.end) return true;
    if (cursor.body == cursor.members) return false;
    cursor.body += 1;
    cursor.phase = .body;
    return null;
}

fn referenceStep(s: anytype, graph: anytype) void {
    if (@TypeOf(s.from) == void) {
        if (referenceMember(&s.cursor, graph)) |found| s.outcome = .{ .success = found };
        return;
    }
    if (s.stage == .connection) {
        if (s.connection == graph.connections.len) {
            s.outcome = .{ .success = false };
            return;
        }
        s.cursor = .{ .members = @backingInt(graph.connections[s.connection].left.members), .node = @backingInt(s.from) };
        s.stage = .left;
        return;
    }
    const found = referenceMember(&s.cursor, graph) orelse return;
    const connection = graph.connections[s.connection];
    switch (s.stage) {
        .connection => unreachable,
        .left, .reverse_left => if (found) {
            s.cursor = .{ .members = @backingInt(connection.right.members), .node = @backingInt(if (s.stage == .left) s.to else s.from) };
            s.stage = if (s.stage == .left) .right else .reverse_right;
            return;
        },
        .right, .reverse_right => if (found) {
            s.outcome = .{ .success = true };
            return;
        },
    }
    if ((s.stage == .left or s.stage == .right) and connection.effective_operator == .undirected) {
        s.cursor = .{ .members = @backingInt(connection.left.members), .node = @backingInt(s.to) };
        s.stage = .reverse_left;
    } else {
        s.connection += 1;
        s.stage = .connection;
    }
}

fn referenceAdvance(s: anytype, graph: anytype, budget: u32, stop: ?*Stop, interval: u32) u32 {
    if (s.outcome != null) return 0;
    if (stop) |hook| if (hook.token().requested()) {
        s.cancel();
        return 0;
    };
    var used: u32 = 0;
    while (used < budget and s.outcome == null) {
        if (stop) |hook| if (used != 0 and used % interval == 0 and hook.token().requested()) {
            s.cancel();
            break;
        };
        if (s.total_work == s.max_work) {
            s.outcome = .{ .failure = error.WorkLimit };
            break;
        }
        used += 1;
        s.total_work += 1;
        referenceStep(s, graph);
    }
    return used;
}

fn sameCursor(expected: anytype, actual: @TypeOf(expected)) !void {
    try equal(expected.total_work, actual.total_work);
    try equal(expected.outcome, actual.outcome);
    try equal(expected.cursor, actual.cursor);
    try equal(expected.stage, actual.stage);
    try equal(expected.connection, actual.connection);
}

fn comparePauses(initial: anytype, graph: anytype) !void {
    var full = initial;
    _ = referenceAdvance(&full, graph, std.math.maxInt(u32), null, 1);
    for (0..full.total_work + 1) |limit| {
        for ([_]u32{ 1, 2, 3, 7, 64, 4096 }) |budget| {
            var expected = initial;
            var actual = initial;
            expected.max_work = limit;
            actual.max_work = limit;
            while (true) {
                const zero = actual.advance(0);
                try equal(referenceAdvance(&expected, graph, 0, null, 1), zero.work_used);
                try sameCursor(expected, actual);
                const p = actual.advance(budget);
                try equal(referenceAdvance(&expected, graph, budget, null, 1), p.work_used);
                try sameCursor(expected, actual);
                if (p.outcome != null) break;
            }
        }
    }
}

test "batched queries preserve the original cursor at every credit and lifetime boundary" {
    var result = try dot.ir.parse(a, "graph {a--b;subgraph s{a b}--c;subgraph s{d}--e;subgraph s{a b}--f;{}--{a b};z}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    for ([_][]const u8{ "a", "d", "e", "z" }) |name| {
        const node = (try graph.findNode(name)).?;
        try comparePauses(try IR.hasEdgeSession(graph, node, (try graph.findNode("f")).?, .{}), graph);
        for (graph.connections) |connection| try comparePauses(try IR.containsSession(graph, connection.left.members, node, .{}), graph);
    }
}

test "batched queries preserve every cancellation poll and its precedence over exhaustion" {
    var result = try dot.ir.parse(a, "graph {a--b;subgraph s{a b}--c;subgraph s{d}--e;z}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const z = (try graph.findNode("z")).?;
    inline for (.{ false, true }) |runtime| inline for (.{ 1, 4, 64 }) |interval| {
        const P = dot.ir.Lowering(.{ .runtime_policy = runtime, .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } });
        inline for (.{ false, true }) |membership| {
            var initial = if (membership) try P.containsSession(graph, graph.connections[2].left.members, z, .{}) else try P.hasEdgeSession(graph, z, z, .{});
            _ = initial.run();
            for ([_]u64{ 0, 1, 4, initial.total_work - 1, initial.total_work }) |limit| {
                for ([_]u32{ 1, 3, 7, 64 }) |budget| {
                    for (2..initial.total_work * 2 + 4) |at| {
                        var stop: Stop = .{ .at = at };
                        var actual = if (membership) try P.containsSession(graph, graph.connections[2].left.members, z, .{ .cancellation = stop.token() }) else try P.hasEdgeSession(graph, z, z, .{ .cancellation = stop.token() });
                        actual.max_work = limit;
                        var expected = actual;
                        var reference_stop = stop; // init has already polled once
                        stop.work = &actual.total_work;
                        reference_stop.work = &expected.total_work;
                        while (true) {
                            const zero = if (runtime) try actual.advance(0) else actual.advance(0);
                            try equal(referenceAdvance(&expected, graph, 0, &reference_stop, interval), zero.work_used);
                            const p = if (runtime) try actual.advance(budget) else actual.advance(budget);
                            try equal(referenceAdvance(&expected, graph, budget, &reference_stop, interval), p.work_used);
                            try sameCursor(expected, actual);
                            try equal(reference_stop.calls, stop.calls);
                            try equal(reference_stop.previous, stop.previous);
                            try equal(reference_stop.max_gap, stop.max_gap);
                            if (p.outcome != null) break;
                        }
                    }
                }
            }
        }
    };
}
