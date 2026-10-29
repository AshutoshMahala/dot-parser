//! Regression cases shared by the direct, fixed and resumable IR paths.
const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });

test "ASCII-only IR retains parser-accepted name bytes in direct fixed and session paths" {
    const P = dot.Profile(.{ .source_encodings = &.{} });
    const I = dot.ir.Lowering(.{ .source_encodings = &.{}, .policy = .{ .execution = .{ .metering = true } } });
    var parsed = try P.parseAndValidate(a, "digraph { subgraph \"\xff\" { \"\xfe\"[\"\xfd\"=x] }; \"\xfe\"->b }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = P.interpretation(doc, .{}) };
    const bounds = try I.loweringBounds(doc.capacities(), options);
    const layout = try I.loweringLayout(bounds.graph, bounds.scratch);
    const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
    defer a.free(retained);
    const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
    defer a.free(scratch);
    const memory = try layout.bind(retained, scratch);
    var direct = try I.lowerComplete(a, doc, options);
    defer direct.deinit();
    const fixed = I.lowerCompleteIn(doc, memory, options);
    try eq(dot.ir.LoweringOutcome.success, fixed.outcome);
    var session = try I.loweringSession(a, doc, options);
    defer session.deinit();
    while (session.advance(1).outcome == null) {}
    var resumed = try session.takeResult();
    defer resumed.deinit();
    for ([_]*const I.Graph{ &direct, &fixed.graph.?, &resumed }) |graph| {
        const id = (try graph.findNode("\xfe")).?;
        const node = try graph.nodeView(id);
        try expect(node.attribute("\xfd") != null);
        try eq(@as(u32, 2), graph.capacities().nodes);
    }
}

test "fixed and allocator lowering sessions normalize anonymous and absent hooks alike" {
    var parsed = Dot.parseAndValidate(a, "digraph {a->b}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    const bounds = try IR.loweringBounds(doc.capacities(), options);
    const layout = try IR.loweringLayout(bounds.graph, bounds.scratch);
    const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
    defer a.free(retained);
    const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
    defer a.free(scratch);
    const memory = try layout.bind(retained, scratch);
    const Hook = struct {
        fn poll(_: ?*anyopaque) bool {
            return false;
        }
    };
    inline for (.{ {}, null, .{ .context = @as(?*anyopaque, null), .is_requested = Hook.poll } }) |hook| {
        const opts = .{ .interpretation = options.interpretation, .cancellation = hook };
        var ordinary = try IR.loweringSession(a, doc, opts);
        defer ordinary.deinit();
        var fixed = try IR.loweringSessionIn(doc, memory, opts);
        defer fixed.deinit();
        try eq(dot.ir.LoweringOutcome.success, ordinary.run().outcome.?);
        try eq(dot.ir.LoweringOutcome.success, fixed.run().outcome.?);
    }
}

test "ASCII-admitted documents use the shared IR reader during materialization" {
    const Ascii = dot.Profile(.{ .source_encodings = &.{} });
    var parsed = try Ascii.parseAndValidate(a, "digraph {a:p->b[\"tail\"+\"port\"=x headport=y]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    try eq(.ascii, doc.source_info.encoding);
    inline for (.{ false, true }) |partial| {
        var graph = if (partial) try IR.lowerPartial(a, doc, .{ .interpretation = Ascii.interpretation(doc, .{}) }) else try IR.lowerComplete(a, doc, .{ .interpretation = Ascii.interpretation(doc, .{}) });
        defer graph.deinit();
        var expected = try graph.materialize(.{});
        defer expected.deinit();
        for ([_]u32{ 1, 7, 4096 }) |budget| {
            var session = try graph.materializationSession(.{});
            defer session.deinit();
            while (true) {
                const p = session.advance(budget);
                try expect(p.work_used <= budget);
                if (p.outcome != null) break;
            }
            var actual = try session.takeResult();
            defer actual.deinit();
            var before = expected.edgeIterator();
            var after = actual.edgeIterator();
            const x = before.next().?;
            const y = after.next().?;
            try eq(x.edge, y.edge);
            try eq(x.attribute("tailport"), y.attribute("tailport"));
            try eq(x.attribute("headport"), y.attribute("headport"));
        }
    }
}

test "native root names are decoded before publication in every lowering route" {
    const P = dot.Profile(.{ .source_encodings = &.{.utf16} });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{.utf16}, .policy = .{ .execution = .{ .metering = true } } });
    const text = "graph X {a}";
    var source: [text.len * 2]u8 = undefined;
    for (text, 0..) |byte, i| std.mem.writeInt(u16, source[i * 2 ..][0..2], if (byte == 'X') 0xd800 else byte, .little);
    var parsed = try P.parseAndValidate(a, &source, dot.diagnostic.discard, .{ .encoding = .utf16le });
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = P.interpretation(doc, .{}) };
    const bounds = try Native.loweringBounds(doc.capacities(), options);
    const layout = try Native.loweringLayout(bounds.graph, bounds.scratch);
    const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
    defer a.free(retained);
    const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
    defer a.free(scratch);
    const memory = try layout.bind(retained, scratch);
    inline for (.{ false, true }) |partial| {
        try std.testing.expectError(error.InvalidIdentifier, if (partial) Native.lowerPartial(a, doc, options) else Native.lowerComplete(a, doc, options));
        const fixed = if (partial) Native.lowerPartialIn(doc, memory, options) else Native.lowerCompleteIn(doc, memory, options);
        try eq(error.InvalidIdentifier, fixed.outcome.failure);
        for ([_]u32{ 1, 64 }) |grant| inline for (.{ false, true }) |in| {
            var session = if (in) (if (partial) try Native.partialLoweringSessionIn(doc, memory, options) else try Native.loweringSessionIn(doc, memory, options)) else (if (partial) try Native.partialLoweringSession(a, doc, options) else try Native.loweringSession(a, doc, options));
            defer session.deinit();
            while (true) {
                const p = session.advance(grant);
                try expect(p.work_used <= grant);
                if (p.outcome) |o| {
                    try eq(error.InvalidIdentifier, o.failure);
                    break;
                }
            }
            try std.testing.expectError(error.InvalidIdentifier, session.takeResult());
        };
    }
}

test "caller capacity envelopes fail with IndexLimit rather than arithmetic overflow" {
    inline for (.{ "nodes", "attributes", "assignments", "subgraphs", "edges", "edge_chains", "scoped_edges", "edge_links", "scoped_edge_links", "attribute_statements" }) |field| {
        var counts: dot.DocumentCapacities = .{ .attributes = 1, .assignments = 1, .edges = 1, .edge_links = 1 };
        @field(counts, field) = std.math.maxInt(@FieldType(dot.DocumentCapacities, field));
        try std.testing.expectError(error.IndexLimit, IR.loweringBounds(counts, .{}));
        try std.testing.expectError(error.IndexLimit, IR.partialLoweringBounds(counts, .{}));
    }
    try std.testing.expectError(error.IndexLimit, IR.loweringBounds(.{ .attributes = std.math.maxInt(u32) - 1, .assignments = 2 }, .{}));
}

test "direct lowering normalizes optional limits and honors enabled cancellation for either storage" {
    var parsed = Dot.parseAndValidate(a, "digraph {a->b}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const AlwaysStop = struct {
        fn requested(_: ?*anyopaque) bool {
            return true;
        }
    };
    const token: dot.ir.Cancellation = .{ .context = null, .is_requested = AlwaysStop.requested };
    inline for (.{ false, true }) |runtime| {
        const P = dot.ir.Lowering(.{ .runtime_policy = runtime, .policy = .{ .execution = .{ .cancellation = true } } });
        const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
        const bounds = try P.loweringBounds(doc.capacities(), options);
        const layout = try P.loweringLayout(bounds.graph, bounds.scratch);
        const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
        defer a.free(retained);
        const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
        defer a.free(scratch);
        const memory = try layout.bind(retained, scratch);
        inline for (.{ false, true }) |partial| {
            const cancelled = .{ .interpretation = options.interpretation, .cancellation = token };
            try std.testing.expectError(error.Cancelled, if (partial) P.lowerPartial(a, doc, cancelled) else P.lowerComplete(a, doc, cancelled));
            const pending = if (partial) P.lowerPartialIn(doc, memory, cancelled) else P.lowerCompleteIn(doc, memory, cancelled);
            const result = if (runtime) try pending else pending;
            try eq(error.Cancelled, result.outcome.failure);
            inline for (.{ null, @as(?dot.ir.Limits, null), dot.ir.Limits{}, @as(?dot.ir.Limits, .{}), .{ .max_work = 100000 } }) |limits| {
                const opts = .{ .interpretation = options.interpretation, .limits = limits };
                var graph = if (partial) try P.lowerPartial(a, doc, opts) else try P.lowerComplete(a, doc, opts);
                defer graph.deinit();
                try eq(@as(u32, 2), graph.capacities().nodes);
            }
        }
    }
}

test "partial convenience retains checking when strict interpretation is unsupported" {
    for ([_][]const u8{ "strict graph {a->b}", "strict digraph {a--b}" }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        try expect(result.ir() == null);
        try expect(result.checking.validation != null);
        try expect(!result.checking.validation.?.documentValid());
        var limited = try dot.ir.parsePartial(a, source, .{ .lowering = .{ .limits = .{ .max_work = 0, .max_bytes = 0 } } });
        defer limited.deinit();
        try expect(limited.ir() == null);
        try expect(limited.checking.validation != null);
    }
}

fn Stop(comptime S: type) type {
    return struct {
        polls: u32 = 0,
        at: u32,
        session: ?*S = null,
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.polls += 1;
            if (self.polls == self.at) if (self.session) |session| session.cancel();
            return false;
        }
        fn token(self: *@This()) dot.ir.Cancellation {
            return .{ .context = self, .is_requested = requested };
        }
    };
}
const Operation = enum { lowering, materialization, has_edge, attribute, attributes };
fn Session(comptime operation: Operation) type {
    return switch (operation) {
        .lowering => IR.LoweringSession,
        .materialization => IR.Graph.MaterializationSession(true),
        .has_edge => IR.HasEdgeSession,
        .attribute => IR.AttributeSession,
        .attributes => IR.AttributesSession,
    };
}
fn start(comptime op: Operation, doc: *const dot.Document, graph: *const IR.Graph, hook: dot.ir.Cancellation) !Session(op) {
    return switch (op) {
        .lowering => IR.loweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}), .cancellation = hook }),
        .materialization => graph.materializationSession(.{ .cancellation = hook }),
        .has_edge => IR.hasEdgeSession(graph, @fromBackingInt(0), @fromBackingInt(1), .{ .cancellation = hook }),
        .attribute => IR.attributeSession(try graph.nodeView(@fromBackingInt(0)), "color", .{ .cancellation = hook }),
        .attributes => IR.attributesSession(try graph.nodeView(@fromBackingInt(0)), .{ .cancellation = hook }),
    };
}
test "explicit cancellation inside a hook stays terminal even when the hook returns false" {
    var parsed = Dot.parseAndValidate(a, "digraph {a[color=red];a:p->b[tailport=x]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    var graph = try IR.lowerComplete(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer graph.deinit();
    inline for (comptime std.meta.tags(Operation)) |op| {
        var counter: Stop(Session(op)) = .{ .at = std.math.maxInt(u32) };
        var baseline = try start(op, doc, &graph, counter.token());
        defer baseline.deinit();
        while (baseline.run().outcome == null) {}
        // Constructor poll precedes the returned session and cannot cancel it.
        for (2..counter.polls + 1) |at| {
            var stop: Stop(Session(op)) = .{ .at = @intCast(at) };
            var session = try start(op, doc, &graph, stop.token());
            defer session.deinit();
            stop.session = &session;
            while (true) {
                const p = session.run();
                if (p.outcome) |o| {
                    try eq(error.Cancelled, o.failure);
                    const terminal = session.advance(1);
                    try eq(@as(u32, 0), terminal.work_used);
                    try eq(o, terminal.outcome.?);
                    if (@hasDecl(Session(op), "takeResult")) try std.testing.expectError(error.Cancelled, session.takeResult());
                    break;
                }
            }
        }
    }
}

test "query and attribute sessions poll cancellation at a lifetime stop inside an interval" {
    const P = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = 64 } } });
    const Counter = struct {
        polls: u32 = 0,
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.polls += 1;
            return self.polls == 3; // constructor, resume, lifetime stop
        }
    };
    var parsed = try dot.ir.parse(a, "digraph {a[color=red];a->b}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    const node = try graph.nodeView(@fromBackingInt(0));
    inline for (.{ .has_edge, .attribute, .attributes }) |op| {
        var counter: Counter = .{};
        const options = .{ .limits = .{ .max_work = 1 }, .cancellation = dot.ir.Cancellation{ .context = &counter, .is_requested = Counter.requested } };
        var session = switch (@as(Operation, op)) {
            .has_edge => try P.hasEdgeSession(graph, @fromBackingInt(1), @fromBackingInt(0), options),
            .attribute => try P.attributeSession(node, "color", options),
            .attributes => try P.attributesSession(node, options),
            else => unreachable,
        };
        defer session.deinit();
        const progress = session.advance(64);
        try eq(@as(u32, 1), progress.work_used);
        try eq(error.Cancelled, progress.outcome.?.failure);
        try eq(@as(u32, 3), counter.polls);
    }
}
