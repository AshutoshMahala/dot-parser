const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const execution = .{ .metering = true, .cancellation = true };
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;
const fixtures = [_][]const u8{
    "digraph {}",
    "digraph G { a -> { b c }; \"a\" -> d; subgraph s{x} }",
    "strict graph {node[color=red];edge[weight=2];a:p--subgraph s{b;c};subgraph s{d};b:q--a:r[label=x];a[label=\"x\"+\"y\"]}",
    "digraph {a->b->c->d[x=1];node[x=2];subgraph s{a[x=3];edge[color=red];b->c}; a -> subgraph s{d} -> {e;f}[label=x]; subgraph s{g}; a->b}",
    "digraph {a[label=<<b>x</b>>]; b[x=1,x=2]; subgraph s {node[color=red]; c}; subgraph s{d}}",
    "digraph {a[label=;b;c->d;}",
    "digraph {a -> {b;c} -> ;d[e=f];}",
    "digraph {a;subgraph s{b;c[label=] d; e}",
    "graph {a;b->c; bad[;d;}",
    "digraph {a[shpe=x,x=1,x=2,\"x\"=3,z=4,a=5,b=6,c=7,d=8]; b:p->c:q}",
    "digraph {a; \"unterminated",
    "wrong {a}",
    "\xef\xbb\xbfdigraph { café [label=\"fish\"]; a }",
};
fn pair(comptime attributes: bool, comptime partial: bool, comptime backend: anytype, source: []const u8, budget: u32) !void {
    const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes }, .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    const Dot = dot.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .metering = true, .cancellation = true }, .validation = .{ .repeated_attribute = .warning, .graphviz = .{ .unknown_attribute = .warning } } } });
    const E = IR.FromEvents(Dot);
    const S = if (partial) E.PartialSession else E.Session;
    var direct_bag = dot.FixedDiagnosticBag(128){};
    var session_bag = dot.FixedDiagnosticBag(128){};
    var direct = if (partial) try E.parsePartial(a, source, .{ .diagnostics = direct_bag.sink() }) else try E.parse(a, source, .{ .diagnostics = direct_bag.sink() });
    defer direct.deinit();
    var session = try S.init(a, source, .{ .diagnostics = session_bag.sink() });
    defer session.deinit();
    try std.testing.expectError(error.NotReady, session.takeResult());
    try equal(@as(u32, 0), session.advance(0).work_used);
    var total: u64 = 0;
    var frontier: u32 = 0;
    while (true) {
        const p = session.advance(budget);
        try expect(p.work_used <= budget);
        total += p.work_used;
        try equal(total, p.total_work);
        try expect(p.source_frontier >= frontier and p.source_frontier <= source.len);
        frontier = p.source_frontier;
        if (p.outcome) |outcome| {
            if (outcome == .failure) return outcome.failure;
            break;
        }
        try expect(p.work_used != 0);
        if (total > 2_000_000) return error.InfiniteLoop;
    }
    try equal(@as(u32, 0), session.advance(1).work_used);
    var result = try session.takeResult();
    defer result.deinit();
    try std.testing.expectError(error.AlreadyTaken, session.takeResult());
    try equal(direct.checking, result.checking);
    try equal(direct_bag.items(), session_bag.items());
    try equal(direct.ir() == null, result.ir() == null);
    if (direct.ir()) |graph| {
        if (partial) try @import("ir_event_partial.zig").graphs(graph, result.ir().?) else try @import("ir_events.zig").sameGraphs(graph, result.ir().?);
    }
}
test "event sessions match direct complete and partial semantics at every grant" {
    inline for (.{ true, false }) |attributes| inline for (.{ true, false }) |partial| inline for (.{ .scalar, .block }) |backend| {
        for (fixtures) |source| for ([_]u32{ 1, 7, 256 }) |budget| {
            pair(attributes, partial, backend, source, budget) catch |err| {
                std.debug.print("parity attrs={} partial={} backend={t} budget={d}: {s}\n", .{ attributes, partial, backend, budget, source });
                return err;
            };
        };
    };
}
test "event sessions preserve standalone observer traces and independent recovery" {
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    const Dot = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true }, .retention = .{ .comments = true } } });
    inline for (.{ true, false }) |recovery| {
        const Observer = @import("ir_event_observer.zig").Recorder(.{ .recovery = recovery, .observations = blk: {
            var o = dot.events.Observations.all;
            o.token_preview = false;
            break :blk o;
        } });
        const E = IR.FromEvents(Dot).Observe(Observer);
        inline for (.{ true, false }) |partial| {
            const S = if (partial) E.PartialSession else E.Session;
            for (fixtures) |source| {
                var expected: Observer = .{};
                _ = Dot.Events(Observer).parse(a, source, &expected, dot.diagnostic.discard, .{});
                var actual_observer: Observer = .{};
                var session = try S.init(a, source, .{ .observer = &actual_observer });
                defer session.deinit();
                while (session.advance(1).outcome == null) {}
                var result = try session.takeResult();
                defer result.deinit();
                try equal(expected.items(), actual_observer.items());
            }
        }
    }
}
test "event sessions preserve observer stop and typed failures" {
    const Observer = @import("ir_event_observer.zig").Recorder(.{});
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{})).Observe(Observer);
    const source = "digraph G {a; subgraph s{b->c} a:p->d[x=y]}";
    for (1..18) |at| {
        inline for (.{ true, false }) |stop| {
            var expected: Observer = .{ .stop_at = if (stop) @intCast(at) else null, .fail_at = if (stop) null else @intCast(at) };
            _ = dot.Profile(.{}).Events(Observer).parse(a, source, &expected, dot.diagnostic.discard, .{});
            var observer: Observer = .{ .stop_at = if (stop) @intCast(at) else null, .fail_at = if (stop) null else @intCast(at) };
            var session = try E.Session.init(a, source, .{ .observer = &observer });
            defer session.deinit();
            const outcome = session.run().outcome.?;
            try equal(@as(E.Error, if (stop) error.ObserverStopped else error.ObserverFailure), outcome.failure);
            try equal(expected.items(), observer.items());
            try std.testing.expectError(if (stop) error.ObserverStopped else error.ObserverFailure, session.takeResult());
        }
    }
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    const E = dot.ir.Lowering(.{ .indexes = .{ .connections = true, .scope_memberships = true } }).FromEvents(dot.Profile(.{}));
    var session = try E.PartialSession.init(allocator, "digraph {node[color=red]; a:p->{b;subgraph s{c}}->;subgraph s{d}; d->e[x=1,y=2]; tail->", .{});
    defer session.deinit();
    const outcome = session.run().outcome.?;
    if (outcome == .failure) return outcome.failure;
    var result = try session.takeResult();
    defer result.deinit();
    try expect(result.ir() != null);
}
test "event sessions clean every allocation failure" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}
test "event sessions cancellation latches at every resumable boundary and zero grant" {
    const E = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } }).FromEvents(dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } }));
    const S = E.PartialSession;
    const source = "digraph {node[color=red]; a:p->{b;subgraph s{c}}->;subgraph s{d}; d->e[x=1,y=2]}";
    var counter = try S.init(a, source, .{});
    defer counter.deinit();
    const steps = counter.run().total_work;
    for (0..steps) |at| {
        var session = try S.init(a, source, .{});
        defer session.deinit();
        _ = session.advance(@intCast(at));
        session.cancel();
        try equal(@as(E.Error, error.Cancelled), session.run().outcome.?.failure);
        try equal(@as(u32, 0), session.advance(1).work_used);
        try std.testing.expectError(error.Cancelled, session.takeResult());
    }
    const Request = struct {
        session: ?*S = null,
        fn check(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.session.?.cancel();
            return false;
        }
    };
    inline for (.{ true, false }) |outer| {
        var request: Request = .{};
        const hook: dot.Cancellation = .{ .context = &request, .is_requested = Request.check };
        var session = try S.init(a, source, .{ .dot = .{ .cancellation = if (outer) hook else null }, .lowering = .{ .cancellation = if (outer) null else hook } });
        defer session.deinit();
        request.session = &session;
        const p = session.advance(0);
        try equal(@as(u32, 0), p.work_used);
        try equal(@as(E.Error, error.Cancelled), p.outcome.?.failure);
    }
}
test "event sessions resolve runtime policies once and require both metering selections" {
    const E = dot.ir.Lowering(.{ .runtime_policy = true }).FromEvents(dot.Profile(.{ .runtime_policy = true }));
    inline for (.{ true, false }) |outer| inline for (.{ true, false }) |inner| {
        var session = try E.Session.init(a, "digraph {a->b}", .{ .dot = .{ .policy = .{ .scanner = .block, .execution = .{ .metering = outer } } }, .lowering = .{ .policy = .{ .execution = .{ .metering = inner } } } });
        defer session.deinit();
        if (outer and inner) {
            while ((try session.advance(1)).outcome == null) {}
        } else {
            try std.testing.expectError(error.MeteringDisabled, session.advance(0));
            try equal(@as(u64, 0), session.total_work);
            _ = session.run();
        }
        var result = try session.takeResult();
        defer result.deinit();
        try expect(result.ir() != null);
    };
}
test "event sessions encoding checks, fail-fast and diagnostic stops match direct checking" {
    const sources = [_][]const u8{ "digraph {a [label=\"\xff\"];b}", "digraph {a[label=<\xff>]; b[bad=one,bad=two]}", "digraph {a:p--b:q[shpe=x,x=1,x=2]; subgraph s{c}}" };
    inline for (.{ true, false }) |ascii| inline for (.{ .collect, .fail_fast }) |on_error| {
        const E = dot.ir.Lowering(.{ .source_encodings = if (ascii) &.{} else &.{.utf8} }).FromEvents(dot.Profile(.{ .source_encodings = if (ascii) &.{} else &.{.utf8}, .policy = .{ .on_error = on_error, .validation = .{ .invalid_encoding = .err, .repeated_attribute = .warning, .restrictions = .{ .ports = .warning, .subgraphs = .warning }, .graphviz = .{ .unknown_attribute = .warning } } } }));
        for (sources) |source| {
            var expected_bag = dot.FixedDiagnosticBag(64){};
            var actual_bag = dot.FixedDiagnosticBag(64){};
            var direct = try E.parse(a, source, .{ .diagnostics = expected_bag.sink() });
            defer direct.deinit();
            var session = try E.Session.init(a, source, .{ .diagnostics = actual_bag.sink() });
            defer session.deinit();
            _ = session.run();
            var result = try session.takeResult();
            defer result.deinit();
            try equal(direct.checking, result.checking);
            try equal(expected_bag.items(), actual_bag.items());
        }
    };
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning } } }));
    var expected_bag = dot.FixedDiagnosticBag(1){};
    var actual_bag = dot.FixedDiagnosticBag(1){};
    const source = "digraph{a[x=1,x=2,x=3];b}";
    var direct = try E.parse(a, source, .{ .diagnostics = expected_bag.sink() });
    defer direct.deinit();
    var session = try E.Session.init(a, source, .{ .diagnostics = actual_bag.sink() });
    defer session.deinit();
    _ = session.run();
    var result = try session.takeResult();
    defer result.deinit();
    try equal(direct.checking, result.checking);
}
test "event sessions enforce memory and work limits before extra work" {
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{}));
    inline for (.{ dot.ir.Limits{ .max_bytes = 0 }, dot.ir.Limits{ .max_work = 0 }, dot.ir.Limits{ .max_nodes = 0 }, dot.ir.Limits{ .max_connections = 0 } }) |limits| {
        var session = try E.Session.init(a, "digraph{a->b}", .{ .lowering = .{ .limits = limits } });
        defer session.deinit();
        const expected = if (limits.max_bytes == 0) error.MemoryLimit else if (limits.max_work == 0) error.WorkLimit else if (limits.max_nodes == 0) error.NodeLimit else error.ConnectionLimit;
        try equal(@as(E.Error, expected), session.run().outcome.?.failure);
        try std.testing.expectError(expected, session.takeResult());
    }
}
test "event sessions grow nesting and table storage under one-credit grants" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {node[color=red];");
    for (0..1000) |_| try source.writer.writeAll("{");
    try source.writer.writeAll("a->b");
    for (0..1000) |_| try source.writer.writeAll("}");
    for (0..128) |i| try source.writer.print("subgraph s{{ n{d}->a[x={d},x=two,y=three] }};", .{ i, i });
    try source.writer.writeAll("}");
    try pair(true, true, .block, source.written(), 1);
}
test "event sessions reject native readers without affecting one-shot support" {
    const E = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } }).FromEvents(dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } }));
    try std.testing.expectError(error.UnsupportedEncoding, E.Session.init(a, "\xff\xfed\x00i\x00g\x00r\x00a\x00p\x00h\x00{\x00}\x00", .{}));
}
test "event sessions preview only real pauses and charge delivery on resume" {
    const Observer = @import("ir_event_observer.zig").Recorder(.{});
    const E = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } }).FromEvents(dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } })).Observe(Observer);
    const source = "digraph {very_long_node_name [label=\"some string\"]}";
    var observer: Observer = .{};
    var session = try E.Session.init(a, source, .{ .observer = &observer });
    defer session.deinit();
    _ = session.advance(3);
    try equal(@as(u32, 0), observer.len);
    try equal(@as(u32, 0), session.advance(0).work_used);
    try equal(@as(u32, 0), observer.len);
    try equal(@as(u32, 1), session.advance(1).work_used);
    try expect(observer.items()[0].event == .token_preview);
    try equal(.pause, observer.items()[0].event.token_preview.reason);
    _ = session.run();
    var result = try session.takeResult();
    defer result.deinit();
    try expect(result.ir() != null);
}
test "event sessions partial mutation parity" {
    const original = "digraph G{node[color=red]; a:p->{subgraph s{b;x=one};c}->d[label=x]; subgraph s{e};f->g;}";
    var bytes: [original.len]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x3f20261106);
    for (0..256) |_| {
        bytes = original.*;
        const count = random.random().uintLessThan(usize, 4) + 1;
        for (0..count) |_| bytes[random.random().uintLessThan(usize, bytes.len)] = ";{}[]=\"<>- abc"[random.random().uintLessThan(usize, 14)];
        const length = random.random().uintLessThan(usize, bytes.len + 1);
        try pair(true, true, .scalar, bytes[0..length], 7);
    }
}
test "event sessions strict unresolved partial kind is rejected without an operational error" {
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } } }));
    for ([_][]const u8{ "strict graph {a;", "strict graph {a->b}" }) |source| {
        var direct = try E.parsePartial(a, source, .{});
        defer direct.deinit();
        var session = try E.PartialSession.init(a, source, .{});
        defer session.deinit();
        try equal(.rejected, session.run().outcome.?);
        var result = try session.takeResult();
        defer result.deinit();
        try equal(direct.checking, result.checking);
        try expect(result.ir() == null);
    }
}
test "event session total work is independent of grant partition" {
    const E = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } }).FromEvents(dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }));
    var allocator: @import("ir_lowering_sessions.zig").NoResize = .{ .backing = a };
    var total: ?u64 = null;
    for ([_]u32{ 1, 2, 7, 64, 4096, std.math.maxInt(u32) }) |budget| {
        var session = try E.PartialSession.init(allocator.allocator(), fixtures[3], .{});
        defer session.deinit();
        try equal(@as(usize, 0), session.peakBytes());
        var last: E.PartialSession.Progress = undefined;
        while (true) {
            last = session.advance(budget);
            if (last.outcome != null) break;
        }
        if (total) |expected| try equal(expected, last.total_work) else total = last.total_work;
        var result = try session.takeResult();
        defer result.deinit();
        try expect(result.ir() != null);
    }
}
test "event session construction failures abort as sink failures rather than cancellation" {
    const Observer = @import("ir_event_observer.zig").Recorder(.{});
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{})).Observe(Observer);
    var observer: Observer = .{};
    var session = try E.Session.init(a, "digraph{a;b}", .{ .observer = &observer, .lowering = .{ .limits = .{ .max_nodes = 0 } } });
    defer session.deinit();
    try equal(@as(E.Error, error.NodeLimit), session.run().outcome.?.failure);
    try equal(.sink_failure, observer.items()[observer.len - 1].abort.document);
}
