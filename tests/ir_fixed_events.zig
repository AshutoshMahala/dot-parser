const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const config: dot.ir.Config = .{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } };
const IR = dot.ir.Lowering(config);
const Dot = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const E = IR.FromEvents(Dot);
const graph_capacities: dot.ir.GraphCapacities = .{ .nodes = 16, .scopes = 16, .occurrences = 16, .mentions = 64, .connections = 32, .endpoint_ports = 16, .attributes = 32, .attribute_keys = 16, .attribute_states = 128, .declarations = 32, .coverage_gaps = 32 };
const scratch_capacities: E.ParseScratchCapacities = .{ .nesting = 16, .stage_statements = 64, .stage_scopes = 16, .stage_attributes = 32, .stage_links = 32, .stage_ports = 16, .replay_frames = 64, .pending_endpoints = 32, .validation_keys = 32, .partial_bookkeeping = true };
const Retained = IR.FixedGraphStorage(graph_capacities);
const Scratch = E.FixedParseScratch(Retained, scratch_capacities);
const source = "digraph {node[color=red]; a:p -> {b c}; subgraph s{x}; subgraph s{y}; z[label=hello]}";

test "fixed event smoke direct and session" {
    var retained: Retained = .{};
    var scratch: Scratch = .{};
    const memory: E.ParseMemory = .{ .graph = retained.storage(), .scratch = scratch.storage() };
    const result = E.parseIn(source, memory, .{});
    try equal(.success, result.outcome);
    try expect(result.checking.?.validation.?.documentValid());
    try equal(@as(usize, 6), result.graph.?.nodes.len);
    try equal(@as(u32, 1), result.scratch_peak.nesting);
    var session = try E.FixedSession.init(source, memory, .{});
    defer session.deinit();
    while (session.advance(1).outcome == null) {}
    const resumable = try session.takeResult();
    try equal(.success, resumable.outcome);
    try equal(result.graph.?.nodes.len, resumable.graph.?.nodes.len);
}

fn Memory(comptime Event: type) type {
    return struct {
        graph: []align(16) u8,
        scratch: []align(16) u8,
        bound: Event.ParseMemory,
        fn init(g: dot.ir.GraphCapacities, s: Event.ParseScratchCapacities) !@This() {
            const layout = try Event.parseLayout(g, s);
            const graph = try a.alignedAlloc(u8, .@"16", layout.graph_bytes + 16);
            errdefer a.free(graph);
            const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
            errdefer a.free(scratch);
            @memset(graph, 0xcd);
            @memset(scratch, 0xcd);
            return .{ .graph = graph, .scratch = scratch, .bound = try layout.bind(graph, scratch) };
        }
        fn deinit(self: @This()) void {
            a.free(self.graph);
            a.free(self.scratch);
        }
        fn canaries(self: @This()) !void {
            for (self.graph[self.bound.graph.bytes.len..]) |v| try equal(@as(u8, 0xcd), v);
            for (self.scratch[self.bound.scratch.bytes.len..]) |v| try equal(@as(u8, 0xcd), v);
        }
    };
}
const fixtures = [_][]const u8{
    "digraph {}",
    "digraph {a;b;c;a->b;b->c}",
    "digraph {a -> {node[color=red];a;}}",
    "digraph {node[color=red];a;node[color=blue];b;a[shape=box];a->b[weight=2]}",
    "digraph {a:p:n -> b:q -> c:r; a[label=\"x\"+\"y\"];b[label=<<b>x</b>>]}",
    "strict graph {edge[color=red];a:p--b:q;edge[color=blue];b:r--a:s[label=updated];a--c[color=green]}",
    "digraph {subgraph s{a}->subgraph s{b}; x->subgraph s{};subgraph s{c}->x}",
    "digraph {node[color=red];subgraph s{a;node[shape=box];{b}}node[color=blue];subgraph s{c}}",
    "digraph {a->{b c}->{d e}->f; {g}->h->{i}->j}",
    "digraph {x=one;subgraph s{x=two;a} x=three;subgraph s{b} graph[label=last]}",
    "digraph {a;{b;{c;{d}}} a->a;\"a\"->a}",
    "digraph {a->b;b->c;c->d;d->e;e->f;f->g;g->h;h->i;i->j;j->a}",
};
fn compareComplete(expected: anytype, actual: anytype) !void {
    try @import("ir_events.zig").sameGraphs(expected, actual);
}
fn exercise(comptime attributes: bool, comptime backend: dot.ScannerBackend) !void {
    const D = dot.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .metering = true }, .validation = .{ .repeated_attribute = .warning } } });
    const L = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes }, .indexes = .{ .connections = true, .scope_memberships = true }, .policy = .{ .execution = .{ .metering = true } } });
    const Event = L.FromEvents(D);
    for (fixtures) |input| {
        var parsed = D.parseAndValidate(a, input, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        var expected = try L.lowerComplete(a, &parsed.document.?, .{ .interpretation = D.interpretation(&parsed.document.?, .{}) });
        defer expected.deinit();
        const bounds = try Event.parseBounds(parsed.document.?.capacities(), .{});
        try expect(!bounds.scratch.partial_bookkeeping);
        var memory = try Memory(Event).init(bounds.graph, bounds.scratch);
        defer memory.deinit();
        const direct = Event.parseIn(input, memory.bound, .{ .lowering = .{ .query_allocator = a } });
        try equal(.success, direct.outcome);
        try compareComplete(@as(*const L.Graph, &expected), &direct.graph.?);
        try memory.canaries();
        // The same envelope with exact measured scratch, then no scratch lifetime.
        var exact = try Memory(Event).init(direct.graph.?.capacities(), direct.scratch_peak);
        defer exact.deinit();
        const second = Event.parseIn(input, exact.bound, .{ .lowering = .{ .query_allocator = a } });
        try equal(.success, second.outcome);
        @memset(exact.bound.scratch.bytes, 0xaa);
        try compareComplete(@as(*const L.Graph, &expected), &second.graph.?);
        try exact.canaries();
        var expected_work: ?u64 = null;
        for ([_]u32{ 1, 7, 65536 }) |grant| {
            var session = try Event.FixedSession.init(input, memory.bound, .{ .lowering = .{ .query_allocator = a } });
            defer session.deinit();
            try equal(@as(u32, 0), session.advance(0).work_used);
            try std.testing.expectError(error.NotReady, session.takeResult());
            while (true) {
                const progress = session.advance(grant);
                try expect(progress.work_used <= grant);
                if (progress.outcome != null) break;
            }
            const result = try session.takeResult();
            try equal(.success, result.outcome);
            if (expected_work) |work| try equal(work, session.total_work) else expected_work = session.total_work;
            try equal(@as(u32, 0), session.advance(grant).work_used);
            try std.testing.expectError(error.AlreadyTaken, session.takeResult());
            try std.testing.expectEqualDeep(direct.checking, result.checking);
            try compareComplete(@as(*const L.Graph, &expected), &result.graph.?);
            try memory.canaries();
            if (grant == 65536) {
                var fitted = try Memory(Event).init(result.graph.?.capacities(), result.scratch_peak);
                defer fitted.deinit();
                var exact_session = try Event.FixedSession.init(input, fitted.bound, .{ .lowering = .{ .query_allocator = a } });
                defer exact_session.deinit();
                try equal(.success, exact_session.run().outcome.?);
                const exact_result = try exact_session.takeResult();
                try compareComplete(@as(*const L.Graph, &expected), &exact_result.graph.?);
                try fitted.canaries();
            }
        }
    }
}
test "fixed event complete bounds, exact fit, sessions and Document parity" {
    inline for (.{ true, false }) |attributes| inline for (.{ dot.ScannerBackend.scalar, dot.ScannerBackend.block }) |backend| try exercise(attributes, backend);
}

test "fixed event partial bookkeeping is optional and partial sessions retain recovered statements" {
    const D = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .execution = .{ .metering = true } } });
    inline for (.{ true, false }) |attributes| {
        const L = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes }, .policy = .{ .execution = .{ .metering = true } } });
        const Event = L.FromEvents(D);
        var caps = graph_capacities;
        if (!attributes) {
            caps.attributes = 0;
            caps.attribute_keys = 0;
            caps.attribute_states = 0;
            caps.declarations = 0;
        }
        var memory = try Memory(Event).init(caps, scratch_capacities);
        defer memory.deinit();
        for ([_][]const u8{
            "digraph {a[label=; b;c}",
            "digraph {a; subgraph s{b;c} d[label=;e; f}",
            "digraph {a-> {b; c[label=;d} -> e; f}",
            "digraph {a; {b; {c; d[label=\"unfinished",
            "digraph {a->b;{c->d}",
            "digraph {a}",
            "",
            "digraph {a; /* unfinished",
        }) |input| {
            var expected = try Event.parsePartial(a, input, .{});
            defer expected.deinit();
            const result = Event.parsePartialIn(input, memory.bound, .{ .lowering = .{ .query_allocator = a } });
            try expect(result.outcome != .failure);
            try std.testing.expectEqualDeep(expected.checking, result.checking.?);
            try equal(expected.ir() == null, result.graph == null);
            if (result.graph) |*graph| try @import("ir_event_partial.zig").graphs(expected.ir().?, graph);
            var session = try Event.FixedPartialSession.init(input, memory.bound, .{ .lowering = .{ .query_allocator = a } });
            defer session.deinit();
            while (session.advance(1).outcome == null) {}
            const resumed = try session.takeResult();
            try equal(result.outcome, resumed.outcome);
            try std.testing.expectEqualDeep(result.checking, resumed.checking);
            if (resumed.graph) |*graph| try @import("ir_event_partial.zig").graphs(expected.ir().?, graph);
            try memory.canaries();
        }
        var plain = scratch_capacities;
        plain.partial_bookkeeping = false;
        var complete_only = try Memory(Event).init(caps, plain);
        defer complete_only.deinit();
        try expect(complete_only.bound.scratch.bytes.len < memory.bound.scratch.bytes.len);
        const rejected = Event.parsePartialIn("digraph{}", complete_only.bound, .{});
        try equal(error.InvalidStorage, rejected.outcome.failure);
        for (complete_only.bound.graph.bytes) |v| try equal(@as(u8, 0xcd), v);
        try std.testing.expectError(error.InvalidStorage, Event.FixedPartialSession.init("digraph{}", complete_only.bound, .{}));
    }
}

test "fixed event every scratch shortfall is terminal and exact fit succeeds" {
    const D = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true }, .validation = .{ .repeated_attribute = .warning } } });
    const Event = IR.FromEvents(D);
    const input = "digraph {a:p->subgraph s{b[x=1 x=2];{c}}->d:q->e:r;subgraph s{f}}";
    var memory = try Memory(Event).init(graph_capacities, scratch_capacities);
    defer memory.deinit();
    const ok = Event.parseIn(input, memory.bound, .{});
    try equal(.success, ok.outcome);
    inline for (comptime std.meta.fieldNames(Event.ParseScratchCapacities)) |field| {
        if (comptime !std.mem.eql(u8, field, "partial_bookkeeping")) {
            const peak = @field(ok.scratch_peak, field);
            if (peak != 0) {
                inline for (.{ false, true }) |zero| {
                    var caps = ok.scratch_peak;
                    @field(caps, field) = if (zero) 0 else peak - 1;
                    var small = try Memory(Event).init(graph_capacities, caps);
                    defer small.deinit();
                    const report = Event.parseIn(input, small.bound, .{});
                    try equal(error.PoolExhausted, report.outcome.failure);
                    try expect(report.graph == null);
                    const resource = comptime if (std.mem.eql(u8, field, "nesting")) dot.ir.Resource.nesting_frames else @field(dot.ir.Resource, field);
                    try equal(resource, report.shortfall.?.resource);
                    try expect(report.shortfall.?.required_at_least > @field(caps, field));
                    try expect(report.shortfall.?.required_at_least <= peak);
                    var session = try Event.FixedSession.init(input, small.bound, .{});
                    defer session.deinit();
                    const progress = session.run();
                    try equal(error.PoolExhausted, progress.outcome.?.failure);
                    try equal(resource, session.shortfall().?.resource);
                    try equal(@as(u32, 0), session.run().work_used);
                    try std.testing.expectError(error.PoolExhausted, session.takeResult());
                    try small.canaries();
                }
            }
        }
    }
    inline for (comptime std.meta.fieldNames(dot.ir.GraphCapacities)) |field| {
        const used = @field(ok.graph.?.capacities(), field);
        if (used != 0) {
            var caps = ok.graph.?.capacities();
            @field(caps, field) = used - 1;
            var small = try Memory(Event).init(caps, scratch_capacities);
            defer small.deinit();
            const result = Event.parseIn(input, small.bound, .{});
            try equal(error.PoolExhausted, result.outcome.failure);
            try expect(result.shortfall != null);
            try expect(result.graph == null);
            var session = try Event.FixedSession.init(input, small.bound, .{});
            defer session.deinit();
            try equal(error.PoolExhausted, session.run().outcome.?.failure);
            try expect(session.shortfall() != null);
            try small.canaries();
        }
    }
}

test "fixed event validates descriptors and limits before writing and has no heap fallback" {
    var memory = try Memory(E).init(graph_capacities, scratch_capacities);
    defer memory.deinit();
    const info = try E.parseLayout(graph_capacities, scratch_capacities);
    var forged = info;
    forged.scratch_bytes -= 1;
    try std.testing.expectError(error.InvalidStorage, forged.bind(memory.graph, memory.scratch));
    try std.testing.expectError(error.InvalidStorage, info.bind(memory.scratch, memory.scratch));
    try std.testing.expectError(error.InvalidStorage, info.bind(memory.graph[1..], memory.scratch));
    try std.testing.expectError(error.BufferTooSmall, info.bind(memory.graph[0 .. info.graph_bytes - 1], memory.scratch));
    var descriptor = memory.bound;
    descriptor.scratch.graph_capacities.nodes -= 1;
    try equal(error.InvalidStorage, E.parseIn(source, descriptor, .{}).outcome.failure);
    @memcpy(memory.bound.graph.bytes[0..source.len], source);
    try equal(error.InvalidStorage, E.parseIn(memory.bound.graph.bytes[0..source.len], memory.bound, .{}).outcome.failure);
    try equal(error.MemoryLimit, E.parseIn(source, memory.bound, .{ .lowering = .{ .limits = .{ .max_bytes = info.graph_bytes + info.scratch_bytes - 1 } } }).outcome.failure);
    try equal(error.WorkLimit, E.parseIn(source, memory.bound, .{ .lowering = .{ .limits = .{ .max_work = 1 } } }).outcome.failure);
    var no_nodes = graph_capacities;
    no_nodes.nodes = 0;
    var empty = try Memory(E).init(no_nodes, scratch_capacities);
    defer empty.deinit();
    const limit = E.parseIn("digraph{a}", empty.bound, .{ .lowering = .{ .limits = .{ .max_nodes = 0 } } });
    try equal(error.NodeLimit, limit.outcome.failure);
    try expect(limit.shortfall == null);
    var allocator = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const result = E.parseIn(source, memory.bound, .{ .lowering = .{ .query_allocator = allocator.allocator() } });
    try equal(.success, result.outcome);
    try equal(@as(usize, 0), allocator.alloc_index);
    var session = try E.FixedSession.init(source, memory.bound, .{ .lowering = .{ .limits = .{ .max_work = 1 } } });
    defer session.deinit();
    try equal(error.WorkLimit, session.run().outcome.?.failure);
}

test "fixed event native one-shot and independently resolved runtime policies" {
    const D = dot.Profile(.{ .runtime_policy = true, .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const L = dot.ir.Lowering(.{ .runtime_policy = true, .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const Event = L.FromEvents(D);
    const text = "graph G {a:p->subgraph s{b};subgraph s{c};a[label=\"x\"+\"y\"]}";
    var memory = try Memory(Event).init(graph_capacities, scratch_capacities);
    defer memory.deinit();
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width = switch (actual) {
            .utf8 => 1,
            .utf16le, .utf16be => 2,
            else => 4,
        };
        const endian: std.builtin.Endian = if (actual == .utf16be or actual == .utf32be) .big else .little;
        var input: [text.len * width]u8 = undefined;
        for (text, 0..) |ch, i| std.mem.writeInt(if (width == 1) u8 else if (width == 2) u16 else u32, input[i * width ..][0..width], ch, endian);
        const options: Event.FixedOptions = .{
            .dot = .{ .encoding = actual, .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } }, .execution = .{ .metering = true } } },
            .lowering = .{ .query_allocator = a, .policy = .{ .execution = .{ .metering = true } } },
        };
        const result = try Event.parseIn(&input, memory.bound, options);
        try equal(.success, result.outcome);
        try equal(.generic, result.graph.?.kind);
        var expected = try Event.parse(a, &input, .{ .dot = options.dot, .lowering = .{ .policy = options.lowering.policy } });
        defer expected.deinit();
        try compareComplete(expected.ir().?, &result.graph.?);
        try std.testing.expectEqualDeep(expected.checking, result.checking.?);
        if (width == 1) {
            var session = try Event.FixedSession.init(&input, memory.bound, options);
            defer session.deinit();
            while ((try session.advance(1)).outcome == null) {}
            const resumed = try session.takeResult();
            try compareComplete(expected.ir().?, &resumed.graph.?);
        } else try std.testing.expectError(error.UnsupportedEncoding, Event.FixedSession.init(&input, memory.bound, options));
    }
    try std.testing.expectError(error.InvalidCancellationInterval, Event.parseIn(text, memory.bound, .{ .lowering = .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } } }));
    try std.testing.expectError(error.InvalidCancellationInterval, Event.parseBounds(.{}, .{ .dot = .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } } }));
    var session = try Event.FixedSession.init("digraph{}", memory.bound, .{});
    defer session.deinit();
    try std.testing.expectError(error.MeteringDisabled, session.advance(1));
    try equal(.success, session.run().outcome.?);
}

test "fixed event observers match standalone events before IR writes and preserve typed stops" {
    inline for (.{ true, false }) |recovery| {
        const Recorder = @import("ir_event_observer.zig").Recorder(.{ .recovery = recovery, .observations = blk: {
            var value = dot.events.Observations.all;
            value.token_preview = false;
            break :blk value;
        } });
        const Event = E.Observe(Recorder);
        var memory = try Memory(Event).init(graph_capacities, scratch_capacities);
        defer memory.deinit();
        for ([_][]const u8{ source, "digraph G{a[label=;b;subgraph s{c};d}", "digraph{a;{b[label=\"unfinished" }) |input| {
            var standalone: Recorder = .{};
            _ = Dot.Events(Recorder).parse(a, input, &standalone, dot.diagnostic.discard, .{});
            var direct: Recorder = .{};
            const result = Event.parsePartialIn(input, memory.bound, .{ .observer = &direct });
            try expect(result.outcome != .failure);
            try std.testing.expectEqualDeep(standalone.items(), direct.items());
            var resumed: Recorder = .{};
            var session = try Event.FixedPartialSession.init(input, memory.bound, .{ .observer = &resumed });
            defer session.deinit();
            while (session.advance(1).outcome == null) {}
            _ = try session.takeResult();
            try std.testing.expectEqualDeep(standalone.items(), resumed.items());
        }
        inline for (.{ false, true }) |failure| {
            var recorder: Recorder = if (failure) .{ .fail_at = 1, .failure = error.OutOfMemory } else .{ .stop_at = 1 };
            @memset(memory.bound.graph.bytes, 0xa5);
            const result = Event.parseIn(source, memory.bound, .{ .observer = &recorder });
            try equal(if (failure) error.OutOfMemory else error.ObserverStopped, result.outcome.failure);
            try expect(result.graph == null);
            for (memory.bound.graph.bytes) |v| try equal(@as(u8, 0xa5), v);
            recorder = if (failure) .{ .fail_at = 1, .failure = error.OutOfMemory } else .{ .stop_at = 1 };
            var session = try Event.FixedSession.init(source, memory.bound, .{ .observer = &recorder });
            defer session.deinit();
            const progress = session.run();
            try equal(if (failure) error.OutOfMemory else error.ObserverStopped, progress.outcome.?.failure);
            for (memory.bound.graph.bytes) |v| try equal(@as(u8, 0xa5), v);
        }
    }
}

test "fixed event metering and reentrant cancellation stop without publishing" {
    var memory = try Memory(E).init(graph_capacities, scratch_capacities);
    defer memory.deinit();
    const Hook = struct {
        session: ?*E.FixedSession = null,
        calls: usize = 0,
        stop: usize = std.math.maxInt(usize),
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.calls < self.stop) return false;
            if (self.session) |session| {
                session.cancel();
                return false;
            }
            return true;
        }
        fn token(self: *@This()) dot.Cancellation {
            return .{ .context = self, .is_requested = requested };
        }
    };
    var hook: Hook = .{};
    var warm = try E.FixedSession.init(source, memory.bound, .{ .dot = .{ .cancellation = hook.token() }, .lowering = .{ .cancellation = hook.token() } });
    try equal(@as(usize, 0), hook.calls);
    try equal(@as(u32, 0), warm.advance(0).work_used);
    try equal(@as(usize, 2), hook.calls);
    hook.calls = 0;
    const full = warm.run();
    try equal(.success, full.outcome.?);
    const total = hook.calls;
    warm.deinit();
    for ([_]usize{ 1, 8, total / 2, total - 2, total }) |stop| {
        hook = .{ .stop = stop };
        var session = try E.FixedSession.init(source, memory.bound, .{ .dot = .{ .cancellation = hook.token() }, .lowering = .{ .cancellation = hook.token() } });
        defer session.deinit();
        hook.session = &session;
        const progress = session.run();
        try equal(error.Cancelled, progress.outcome.?.failure);
        try equal(stop, hook.calls);
        try equal(@as(u32, 0), session.advance(1).work_used);
        try std.testing.expectError(error.Cancelled, session.takeResult());
        try equal(stop, hook.calls);
    }
    hook = .{ .stop = 1 };
    const stopped = E.parseIn(source, memory.bound, .{ .lowering = .{ .cancellation = hook.token() } });
    try equal(error.Cancelled, stopped.outcome.failure);
    try expect(stopped.graph == null);
}

test "fixed event budgets bound clearing oversized pools and limits precede capacity" {
    var bigger = graph_capacities;
    bigger.nodes = 4096;
    var memory = try Memory(E).init(bigger, scratch_capacities);
    defer memory.deinit();
    var session = try E.FixedSession.init("digraph{a}", memory.bound, .{});
    defer session.deinit();
    var last: u64 = 0;
    while (true) {
        const progress = session.advance(1);
        try expect(progress.work_used <= 1);
        try equal(last + progress.work_used, progress.total_work);
        last = progress.total_work;
        if (progress.outcome != null) break;
    }
    try expect(last > 512); // Clearing table slots is paid, even for one node.
    try equal(.success, (try session.takeResult()).outcome);
    var caps = graph_capacities;
    caps.nodes = 0;
    var empty = try Memory(E).init(caps, scratch_capacities);
    defer empty.deinit();
    var limited = try E.FixedSession.init("digraph{a}", empty.bound, .{ .lowering = .{ .limits = .{ .max_nodes = 0 } } });
    defer limited.deinit();
    try equal(error.NodeLimit, limited.run().outcome.?.failure);
    try expect(limited.shortfall() == null);
}

test "fixed event admission, count envelopes and all truncation boundaries" {
    const input = "digraph G{node[x=y];a:p->{b;c[x=1]};subgraph s{d};subgraph s{e};f->g}";
    var memory = try Memory(E).init(graph_capacities, scratch_capacities);
    defer memory.deinit();
    var frames: dot.FixedParseScratch(.{ .nesting = 16 }) = .{};
    const counted = Dot.measureIn(input, frames.storage(), dot.diagnostic.discard, .{});
    const bounds = try E.parseBounds(counted.capacities.?, .{});
    var bounded = try Memory(E).init(bounds.graph, bounds.scratch);
    defer bounded.deinit();
    try equal(.success, E.parseIn(input, bounded.bound, .{}).outcome);
    try std.testing.expectError(error.IndexLimit, E.parseBounds(.{ .nodes = std.math.maxInt(u32) }, .{}));
    try std.testing.expectError(error.IndexLimit, E.parseLayout(.{}, .{ .stage_links = std.math.maxInt(u32) }));
    for (0..input.len + 1) |end| {
        const text = input[0..end];
        var expected = try E.parsePartial(a, text, .{});
        defer expected.deinit();
        const result = E.parsePartialIn(text, memory.bound, .{ .lowering = .{ .query_allocator = a } });
        try expect(result.outcome != .failure);
        try std.testing.expectEqualDeep(expected.checking, result.checking.?);
        try equal(expected.ir() == null, result.graph == null);
        if (result.graph) |*graph| try @import("ir_event_partial.zig").graphs(expected.ir().?, graph);
    }
}

test "fixed event small explicit example works without optional pools" {
    const Event = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{}));
    const Graph = dot.ir.Lowering(.{}).FixedGraphStorage(.{ .nodes = 8, .scopes = 1, .occurrences = 1, .mentions = 16, .connections = 8 });
    const Temp = Event.FixedParseScratch(Graph, .{ .stage_statements = 1, .stage_scopes = 1, .replay_frames = 1 });
    var graph: Graph = .{};
    var temp: Temp = .{};
    const result = Event.parseIn("digraph{a->b;b->c}", .{ .graph = graph.storage(), .scratch = temp.storage() }, .{});
    try equal(.success, result.outcome);
}

test "fixed event ASCII admission uses the DOT reader independently of IR capability" {
    const D = dot.Profile(.{ .source_encodings = &.{}, .policy = .{ .validation = .{ .invalid_encoding = .err }, .execution = .{ .metering = true } } });
    inline for (.{ true, false }) |utf8| {
        const L = dot.ir.Lowering(.{ .source_encodings = if (utf8) &.{.utf8} else &.{}, .policy = .{ .execution = .{ .metering = true } } });
        const Event = L.FromEvents(D);
        var memory = try Memory(Event).init(graph_capacities, scratch_capacities);
        defer memory.deinit();
        const result = Event.parseIn("digraph{a}", memory.bound, .{});
        try equal(.success, result.outcome);
        try equal(.ascii, result.graph.?.source_info.encoding);
        const invalid = Event.parseIn("digraph{café}", memory.bound, .{});
        try equal(.rejected, invalid.outcome);
        var session = try Event.FixedSession.init("digraph{café}", memory.bound, .{});
        defer session.deinit();
        try equal(.rejected, session.run().outcome.?);
    }
}
