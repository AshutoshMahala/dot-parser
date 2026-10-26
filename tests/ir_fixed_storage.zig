const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;
const Dot = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .retention = .{ .partial = true } } });
const IR = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .execution = .{ .metering = true } } });

const Memory = struct {
    retained: []align(16) u8,
    temporary: []align(16) u8,
    bound: IR.LoweringMemory,
    fn init(graph: dot.ir.GraphCapacities, scratch: dot.ir.LoweringScratchCapacities) !Memory {
        const layout = try IR.storageLayout(graph, scratch);
        const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes + 16);
        errdefer a.free(retained);
        const temporary = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
        errdefer a.free(temporary);
        @memset(retained, 0xcd);
        @memset(temporary, 0xcd);
        return .{ .retained = retained, .temporary = temporary, .bound = try layout.bind(retained, temporary) };
    }
    fn deinit(self: Memory) void {
        a.free(self.retained);
        a.free(self.temporary);
    }
    fn canaries(self: Memory) !void {
        for (self.retained[self.bound.graph.bytes.len..]) |byte| try equal(@as(u8, 0xcd), byte);
        for (self.temporary[self.bound.scratch.bytes.len..]) |byte| try equal(@as(u8, 0xcd), byte);
    }
};
fn compare(expected: anytype, actual: anytype) !void {
    inline for (.{ "source_info", "declared_kind", "kind", "strict", "name", "has_ports", "nodes", "scopes", "declarations", "occurrences", "bodies", "mentions", "connections", "attributes", "posting_offsets", "posting_positions" }) |field|
        try equal(@field(expected, field), @field(actual, field));
    inline for (.{ "meta", "scopes", "connection_defaults" }) |field| try equal(@field(expected.attribute_data, field), @field(actual.attribute_data, field));
    inline for (.{ "keys", "cells" }) |field| try equal(@field(expected.attribute_data, field).items, @field(actual.attribute_data, field).items);
}
fn check(comptime partial: bool, source: []const u8) !void {
    var parsed = try Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var expected = if (partial) try IR.lowerPartial(a, doc, options) else try IR.lowerComplete(a, doc, options);
    defer expected.deinit();
    const bounds = if (partial) try IR.partialCapacityBounds(doc.capacities(), options) else try IR.capacityBounds(doc.capacities(), options);
    // Retained exact fit, scratch conservatively sized. Neither is automatic.
    const memory = try Memory.init(expected.capacities(), bounds.scratch);
    defer memory.deinit();
    var direct = if (partial) IR.lowerPartialIn(doc, memory.bound, options) else IR.lowerCompleteIn(doc, memory.bound, options);
    try equal(dot.ir.LoweringOutcome.success, direct.outcome);
    try expect(direct.shortfall == null);
    if (partial) {
        try compare(expected._data, direct.graph.?._data);
        try equal(expected._coverage.entries.items, direct.graph.?._coverage.entries.items);
    } else try compare(expected, direct.graph.?);
    try equal(expected.capacities(), direct.graph.?.capacities());
    try equal(memory.bound.graph.bytes.len, direct.graph.?.retainedBytes());
    const peak = direct.scratch_peak;
    direct.graph.?.deinit(); // Never free caller storage.

    var total: ?u64 = null;
    for ([_]u32{ 1, 7, 64, 4096 }) |budget| {
        var operation = if (partial) try IR.partialLoweringSessionIn(doc, memory.bound, options) else try IR.loweringSessionIn(doc, memory.bound, options);
        defer operation.deinit();
        try equal(memory.bound.graph.bytes.len + memory.bound.scratch.bytes.len, operation.peakBytes());
        try std.testing.expectError(error.NotReady, operation.takeResult());
        var used: u64 = 0;
        while (true) {
            const zero = operation.advance(0);
            try equal(@as(u32, 0), zero.work_used);
            try equal(used, zero.total_work);
            const progress = operation.advance(budget);
            try expect(progress.work_used <= budget);
            used += progress.work_used;
            try equal(used, progress.total_work);
            if (progress.outcome) |outcome| {
                try equal(dot.ir.LoweringOutcome.success, outcome);
                break;
            }
        }
        if (total) |previous| try equal(previous, used) else total = used;
        try equal(peak, operation.scratchPeak());
        var actual = try operation.takeResult();
        defer actual.deinit();
        if (partial) {
            try compare(expected._data, actual._data);
            try equal(expected._coverage.entries.items, actual._coverage.entries.items);
        } else try compare(expected, actual);
        try std.testing.expectError(error.AlreadyTaken, operation.takeResult());
        operation.cancel();
        try equal(@as(u32, 0), operation.advance(1).work_used);
        try equal(dot.ir.LoweringOutcome.success, operation.run().outcome.?);
        try memory.canaries();
    }
    // Verify the conservative retained bound too, not just scratch sizing.
    const bounded = try Memory.init(bounds.graph, bounds.scratch);
    defer bounded.deinit();
    const result = if (partial) IR.lowerPartialIn(doc, bounded.bound, options) else IR.lowerCompleteIn(doc, bounded.bound, options);
    try equal(dot.ir.LoweringOutcome.success, result.outcome);
    try equal(expected.capacities(), result.graph.?.capacities());
    try bounded.canaries();
}

test "fixed IR exact-fit storage matches growable semantics and bounded sessions" {
    for ([_][]const u8{
        "digraph {}",
        "digraph {a->b->c;a->b;z}",
        "digraph {a;\"a\";\"a\"+<>+\"\";<a>}",
        "strict graph {node[color=red];edge[weight=1];a:p--b:q;b:r--a:s[label=last];a--c}",
        "digraph {graph[label=root];node[color=red];subgraph s{a;node[color=local]}node[color=blue shape=box];subgraph s{b};c}",
        "digraph {subgraph s{a}->x;subgraph s{b}->subgraph s{c};{x->{y z}}->q[label=outside];x->{};{}->z}",
        "digraph {a[a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8 i=9];a[d=last];subgraph s{node[x=1 y=2];b};node[z=3];subgraph s{c}}",
    }) |source| {
        try check(false, source);
        try check(true, source);
    }
    for ([_][]const u8{
        "digraph {a[color=red];broken->;b[color=blue]}",
        "digraph {a;subgraph s{b;c->;d}",
        "digraph {{a}->{b;subgraph s{c}}->;d->e;",
        "digraph {a;x[label=\"unfinished",
    }) |source| try check(true, source);
}

test "fixed helpers reserve explicit inline arrays without initializing the backing bytes" {
    const G = IR.FixedGraphStorage(.{ .nodes = 4, .scopes = 1, .occurrences = 1, .mentions = 8, .connections = 4, .declarations = 4 });
    const S = IR.FixedLoweringScratch(G, .{ .nesting = 4, .edge_nesting = 1, .pending_endpoints = 4 });
    var retained: G = .{};
    var scratch: S = .{};
    @memset(&retained.bytes, 0xcd);
    @memset(&scratch.bytes, 0xcd);
    const memory: IR.LoweringMemory = .{ .graph = retained.storage(), .scratch = scratch.storage() };
    try equal(@sizeOf(G), G.byte_size);
    try equal(@sizeOf(S), S.byte_size);
    for (retained.bytes) |byte| try equal(@as(u8, 0xcd), byte);
    var parsed = try Dot.parseAndValidate(a, "digraph {a->b}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const result = IR.lowerCompleteIn(doc, memory, .{ .interpretation = Dot.interpretation(doc, .{}) });
    try equal(dot.ir.LoweringOutcome.success, result.outcome);
    // No operation state, input pools or temporary storage survives in the IR.
    @memset(&scratch.bytes, 0xcd);
    try expect((try result.graph.?.findNode("a")) != null);
}

test "fixed IR bounds inherit profile limits and use distinct complete and partial helpers" {
    const Limited = dot.ir.Lowering(.{ .limits = .{ .max_attribute_states = 17 } });
    const counts: dot.DocumentCapacities = .{ .attributes = 48, .subgraphs = 13, .statements = 10 };
    const bounded = try IR.capacityBounds(counts, .{});
    try equal(@as(u32, 8640), bounded.graph.attribute_states);
    try equal(@as(u32, 0), bounded.graph.coverage_gaps);
    try equal(@as(u32, 6), (try IR.partialCapacityBounds(counts, .{})).graph.coverage_gaps);
    try equal(@as(u32, 17), (try Limited.capacityBounds(counts, .{})).graph.attribute_states);
    try equal(@as(u32, 8640), (try Limited.capacityBounds(counts, .{ .limits = dot.ir.Limits{} })).graph.attribute_states);
    try equal(@as(u32, 0), (try Limited.capacityBounds(.{}, .{})).graph.attribute_states);
    try std.testing.expectError(error.IndexLimit, IR.capacityBounds(.{ .nodes = std.math.maxInt(u32) }, .{}));
    try std.testing.expectError(error.IndexLimit, IR.storageLayout(.{ .nodes = std.math.maxInt(u32) }, .{}));
    const compile_bounds = comptime Limited.capacityBounds(.{ .attributes = 2 }, .{}) catch unreachable;
    try equal(@as(u32, 17), compile_bounds.graph.attribute_states);
}

test "every fixed retained and scratch pool reports an exact shortfall without a graph" {
    const source = "digraph {a[x=1 y=2 z=3];subgraph s{node[x=2];b};node[q=1];subgraph s{c}->{d->e};broken->;f}";
    var parsed = try Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var expected = try IR.lowerPartial(a, doc, options);
    defer expected.deinit();
    const counts = expected.capacities();
    const bounds = try IR.partialCapacityBounds(doc.capacities(), options);
    const first_memory = try Memory.init(counts, bounds.scratch);
    defer first_memory.deinit();
    const first = IR.lowerPartialIn(doc, first_memory.bound, options);
    try equal(dot.ir.LoweringOutcome.success, first.outcome);
    const peaks = first.scratch_peak;
    const resources = [_]dot.ir.Resource{ .node_pool, .scope_pool, .occurrence_pool, .mention_pool, .connection_pool, .declaration_pool, .attribute_pool, .attribute_key_pool, .attribute_state_pool, .coverage_gap_pool };
    inline for (comptime std.meta.fieldNames(dot.ir.GraphCapacities), resources) |field, resource| {
        var reduced = counts;
        try expect(@field(reduced, field) != 0);
        @field(reduced, field) -= 1;
        const memory = try Memory.init(reduced, peaks);
        defer memory.deinit();
        const direct = IR.lowerPartialIn(doc, memory.bound, options);
        try equal(dot.ir.LoweringOutcome{ .failure = error.PoolExhausted }, direct.outcome);
        try expect(direct.graph == null);
        try equal(resource, direct.shortfall.?.resource);
        try equal(@field(reduced, field), direct.shortfall.?.limit);
        try equal(@field(counts, field), direct.shortfall.?.required_at_least);
        var session = try IR.partialLoweringSessionIn(doc, memory.bound, options);
        defer session.deinit();
        while (session.advance(1).outcome == null) {}
        try equal(dot.ir.LoweringOutcome{ .failure = error.PoolExhausted }, session.run().outcome.?);
        try equal(direct.shortfall, session.shortfall());
        try std.testing.expectError(error.PoolExhausted, session.takeResult());
        try equal(@as(u32, 0), session.advance(100).work_used);
        try memory.canaries();
    }
    inline for (comptime std.meta.fieldNames(dot.ir.LoweringScratchCapacities), [_]dot.ir.Resource{ .nesting_frames, .edge_frames, .pending_endpoints }) |field, resource| {
        var reduced = peaks;
        try expect(@field(reduced, field) != 0);
        @field(reduced, field) -= 1;
        const memory = try Memory.init(counts, reduced);
        defer memory.deinit();
        const direct = IR.lowerPartialIn(doc, memory.bound, options);
        try equal(dot.ir.LoweringOutcome{ .failure = error.PoolExhausted }, direct.outcome);
        try expect(direct.graph == null);
        try equal(resource, direct.shortfall.?.resource);
        var session = try IR.partialLoweringSessionIn(doc, memory.bound, options);
        defer session.deinit();
        try equal(direct.outcome, session.run().outcome.?);
        try equal(direct.shortfall, session.shortfall());
        try memory.canaries();
    }
    // Exact observed counts work too, independent of budget partitioning.
    const exact = try Memory.init(counts, peaks);
    defer exact.deinit();
    var session = try IR.partialLoweringSessionIn(doc, exact.bound, options);
    defer session.deinit();
    try equal(dot.ir.LoweringOutcome.success, session.run().outcome.?);
}

test "fixed rotations check semantic limits before each pool write including intermediate failures" {
    var parsed = try Dot.parseAndValidate(a, "digraph {a[c=1 a=2 b=3];a[b=4]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const interpretation = Dot.interpretation(doc, .{});
    var expected = try IR.lowerComplete(a, doc, .{ .interpretation = interpretation });
    defer expected.deinit();
    const bounds = try IR.capacityBounds(doc.capacities(), .{});
    const counts = expected.capacities();
    for (0..counts.attribute_states) |limit| {
        var reduced = counts;
        reduced.attribute_states = @intCast(limit);
        const memory = try Memory.init(reduced, bounds.scratch);
        defer memory.deinit();
        const ordinary = IR.lowerCompleteIn(doc, memory.bound, .{ .interpretation = interpretation });
        try equal(dot.ir.LoweringOutcome{ .failure = error.PoolExhausted }, ordinary.outcome);
        const options = .{ .interpretation = interpretation, .limits = .{ .max_attribute_states = @as(u32, @intCast(limit)) } };
        const limited = IR.lowerCompleteIn(doc, memory.bound, options);
        try equal(dot.ir.LoweringOutcome{ .failure = error.AttributeStateLimit }, limited.outcome);
        try expect(limited.shortfall == null and limited.graph == null);
        var session = try IR.loweringSessionIn(doc, memory.bound, options);
        defer session.deinit();
        while (session.advance(1).outcome == null) {}
        try equal(limited.outcome, session.run().outcome.?);
        try expect(session.shortfall() == null);
        try memory.canaries();
    }
}

test "fixed layout rejects malformed regions, overlap and mismatched envelopes before writes" {
    const counts: dot.ir.GraphCapacities = .{ .nodes = 3, .scopes = 1, .occurrences = 1, .mentions = 4, .connections = 2 };
    const scratch: dot.ir.LoweringScratchCapacities = .{ .nesting = 2, .edge_nesting = 1, .pending_endpoints = 4 };
    const layout = try IR.storageLayout(counts, scratch);
    const memory = try Memory.init(counts, scratch);
    defer memory.deinit();
    try std.testing.expectError(error.BufferTooSmall, layout.bind(memory.retained[0 .. layout.graph_bytes - 1], memory.temporary));
    try std.testing.expectError(error.InvalidStorage, layout.bind(memory.retained[1..], memory.temporary));
    try std.testing.expectError(error.InvalidStorage, layout.bind(memory.retained, memory.retained));
    var forged = layout;
    forged.graph_bytes = 1;
    try std.testing.expectError(error.InvalidStorage, forged.bind(memory.retained, memory.temporary));
    var source: [8192]u8 align(16) = undefined;
    const text = "digraph {a->b}";
    @memcpy(source[0..text.len], text);
    var parsed = try Dot.parseAndValidate(a, source[0..text.len], dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var mixed = memory.bound;
    mixed.scratch.graph_capacities.nodes += 1;
    try equal(dot.ir.LoweringOutcome{ .failure = error.InvalidStorage }, IR.lowerCompleteIn(doc, mixed, options).outcome);
    const overlap = try layout.bind(&source, memory.temporary);
    try equal(dot.ir.LoweringOutcome{ .failure = error.InvalidStorage }, IR.lowerCompleteIn(doc, overlap, options).outcome);
    try std.testing.expectEqualStrings(text, source[0..text.len]);
    const bytes = layout.graph_bytes + layout.scratch_bytes;
    const limited = IR.lowerCompleteIn(doc, memory.bound, .{ .interpretation = options.interpretation, .limits = .{ .max_bytes = bytes - 1 } });
    try equal(dot.ir.LoweringOutcome{ .failure = error.MemoryLimit }, limited.outcome);
    for (memory.retained) |byte| try equal(@as(u8, 0xcd), byte);
    for (memory.temporary) |byte| try equal(@as(u8, 0xcd), byte);
    try equal(dot.ir.LoweringOutcome.success, IR.lowerCompleteIn(doc, memory.bound, .{ .interpretation = options.interpretation, .limits = .{ .max_bytes = bytes } }).outcome);
}

test "fixed construction never calls the optional query allocator and absent storage is explicit" {
    var parsed = try Dot.parseAndValidate(a, "digraph {a->b;a->{c d}}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    const bounds = try IR.capacityBounds(doc.capacities(), options);
    const memory = try Memory.init(bounds.graph, bounds.scratch);
    defer memory.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const trapped = IR.lowerCompleteIn(doc, memory.bound, .{ .interpretation = options.interpretation, .query_allocator = failing.allocator() });
    try equal(dot.ir.LoweringOutcome.success, trapped.outcome);
    try equal(@as(usize, 0), failing.alloc_index);
    var session = try IR.loweringSessionIn(doc, memory.bound, .{ .interpretation = options.interpretation, .query_allocator = failing.allocator() });
    try equal(dot.ir.LoweringOutcome.success, session.run().outcome.?);
    session.deinit();
    try equal(@as(usize, 0), failing.alloc_index);
    const plain = IR.lowerCompleteIn(doc, memory.bound, options);
    try equal(dot.ir.LoweringOutcome.success, plain.outcome);
    {
        var edges = try plain.graph.?.edgeIterator(.{});
        defer edges.deinit();
        try expect((try edges.next()) != null); // Singleton prefix needs no scratch.
        try std.testing.expectError(error.StorageRequired, edges.next());
    }
    try std.testing.expectError(error.StorageRequired, plain.graph.?.materialize(.{}));
    // End all borrows before rebuilding into the same storage.
    const supplied = IR.lowerCompleteIn(doc, memory.bound, .{ .interpretation = options.interpretation, .query_allocator = a });
    try equal(dot.ir.LoweringOutcome.success, supplied.outcome);
    var expanded = try supplied.graph.?.materialize(.{});
    defer expanded.deinit();
    try equal(@as(usize, 3), expanded.edges.len);
}

test "fixed graphs report missing storage in later streams attribute enumeration and materialization sessions" {
    for ([_][]const u8{ "digraph {a->{b c}[color=red]}", "strict digraph {a->b[color=red]}" }) |source| {
        var parsed = try Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
        const bounds = try IR.capacityBounds(doc.capacities(), options);
        const memory = try Memory.init(bounds.graph, bounds.scratch);
        defer memory.deinit();
        var lowered = IR.lowerCompleteIn(doc, memory.bound, options);
        try equal(dot.ir.LoweringOutcome.success, lowered.outcome);
        const graph = &lowered.graph.?;
        const from = (try graph.findNode("a")).?;
        const to = (try graph.findNode("b")).?;
        try expect(try graph.hasEdge(from, to));
        {
            var stream = try graph.edgeIterator(.{});
            defer stream.deinit();
            try std.testing.expectError(error.StorageRequired, stream.next());
            try std.testing.expectError(error.StorageRequired, stream.next());
            var stepped = try IR.edgeSession(graph, .{});
            defer stepped.deinit();
            try equal(error.StorageRequired, stepped.run().outcome.?.failure);
            try equal(@as(u32, 0), stepped.advance(1).work_used);
        }
        {
            var materialize = try graph.materializationSession(.{});
            defer materialize.deinit();
            try equal(error.StorageRequired, materialize.run().outcome.?.failure);
            try std.testing.expectError(error.StorageRequired, materialize.takeResult());
            // An explicit resource stop still takes precedence over unavailable storage.
            try std.testing.expectError(error.MemoryLimit, graph.materialize(.{ .limits = .{ .max_bytes = 0 } }));
        }
        if (graph.strict) {
            const edge = try graph.edgeView(.{ .from = from, .to = to, .operator = .directed, .first_connection = @fromBackingInt(0) });
            try expect((try edge.attribute("color")) != null);
            var single = try IR.attributeSession(edge, "color", .{});
            defer single.deinit();
            try expect(single.run().outcome.?.success != null);
            var all = try edge.attributes(.{});
            defer all.deinit();
            try std.testing.expectError(error.StorageRequired, all.next());
            var stepped = try IR.attributesSession(edge, .{});
            defer stepped.deinit();
            try equal(error.StorageRequired, stepped.run().outcome.?.failure);
        }
        try memory.canaries();
    }
}

const Stop = struct {
    polls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.polls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};
test "fixed sessions preserve work limits cancellation intervals zero grants and terminal latching" {
    const C = dot.ir.Lowering(.{ .runtime_policy = true, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var parsed = try Dot.parseAndValidate(a, "digraph {a[x=1 y=2];a->{b c}}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const interpretation = Dot.interpretation(doc, .{});
    const bounds = try C.capacityBounds(doc.capacities(), .{});
    const memory = try Memory.init(bounds.graph, bounds.scratch);
    defer memory.deinit();
    var total: u64 = 0;
    for ([_]u32{ 1, 4, 64 }) |interval| {
        var stop: Stop = .{};
        var session = try C.loweringSessionIn(doc, memory.bound, .{ .interpretation = interpretation, .policy = .{ .execution = .{ .cancellation_interval = interval } }, .cancellation = stop.token() });
        defer session.deinit();
        const progress = session.run();
        try equal(dot.ir.LoweringOutcome.success, progress.outcome.?);
        if (total != 0) try equal(total, progress.total_work) else total = progress.total_work;
        try equal(1 + (total + interval - 1) / interval, stop.polls);
    }
    // Stop at every possible credit in this fixture, including table clears,
    // native-independent metadata phases and multi-cell AVL updates.
    for (2..total + 2) |at| {
        var stop: Stop = .{ .at = at };
        var session = try C.loweringSessionIn(doc, memory.bound, .{ .interpretation = interpretation, .cancellation = stop.token() });
        defer session.deinit();
        try equal(dot.ir.LoweringOutcome{ .failure = error.Cancelled }, session.run().outcome.?);
        try std.testing.expectError(error.Cancelled, session.takeResult());
        try equal(@as(u32, 0), (try session.advance(100)).work_used);
    }
    var stopped: Stop = .{ .at = 2 };
    var zero = try C.loweringSessionIn(doc, memory.bound, .{ .interpretation = interpretation, .cancellation = stopped.token() });
    defer zero.deinit();
    const progress = try zero.advance(0);
    try equal(@as(u32, 0), progress.work_used);
    try equal(dot.ir.LoweringOutcome{ .failure = error.Cancelled }, progress.outcome.?);
    var limited = try C.loweringSessionIn(doc, memory.bound, .{ .interpretation = interpretation, .limits = .{ .max_work = total - 1 } });
    defer limited.deinit();
    try equal(dot.ir.LoweringOutcome{ .failure = error.WorkLimit }, limited.run().outcome.?);
    try expect(limited.shortfall() == null);
    try std.testing.expectError(error.InvalidCancellationInterval, C.lowerCompleteIn(doc, memory.bound, .{ .interpretation = interpretation, .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    var disabled = try C.loweringSessionIn(doc, memory.bound, .{ .interpretation = interpretation, .policy = .{ .execution = .{ .metering = false } } });
    defer disabled.deinit();
    try std.testing.expectError(error.MeteringDisabled, disabled.advance(1));
    try equal(dot.ir.LoweringOutcome.success, disabled.run().outcome.?);
    try memory.canaries();
}

test "fixed native lowering deep nesting reopened scopes and symbolic products" {
    const fixture = "digraph {node[color=red];subgraph s{a:p:n->b[label=\"a\"+<<B>bee</B>>]};node[color=blue];subgraph s{c};x->subgraph s{d}}";
    for ([_]usize{ 2, 4 }) |width| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        try source.appendSlice(a, if (width == 2) &.{ 0xff, 0xfe } else &.{ 0xff, 0xfe, 0, 0 });
        for (fixture) |byte| {
            try source.append(a, byte);
            for (1..width) |_| try source.append(a, 0);
        }
        try check(false, source.items);
        try check(true, source.items);
        try check(true, source.items[0 .. source.items.len - width]);
    }
    var deep = std.Io.Writer.Allocating.init(a);
    defer deep.deinit();
    try deep.writer.writeAll("digraph {");
    for (0..128) |_| try deep.writer.writeAll("a->{");
    try deep.writer.writeAll("z");
    for (0..128) |_| try deep.writer.writeAll("}");
    try deep.writer.writeAll("}");
    try check(false, deep.written());
    var product = std.Io.Writer.Allocating.init(a);
    defer product.deinit();
    try product.writer.writeAll("digraph {{");
    for (0..1000) |i| try product.writer.print("a{d};", .{i});
    try product.writer.writeAll("}->{");
    for (0..1000) |i| try product.writer.print("b{d};", .{i});
    try product.writer.writeAll("}}");
    try check(false, product.written());
    // Reopening copies default-map paths, never endpoint Cartesian products.
    var reopens = std.Io.Writer.Allocating.init(a);
    defer reopens.deinit();
    try reopens.writer.writeAll("digraph {subgraph s{node[");
    for (0..12) |i| try reopens.writer.print("k{d}=local;", .{i});
    try reopens.writer.writeAll("];edge[");
    for (0..12) |i| try reopens.writer.print("e{d}=local;", .{i});
    try reopens.writer.writeAll("];x}");
    for (0..12) |i| try reopens.writer.print("node[parent={d}];edge[parent={d}];subgraph s{{x->y}}", .{ i, i });
    try reopens.writer.writeAll("}");
    try check(false, reopens.written());
}

test "fixed name tables handle colliding hashes within declared capacity" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    var candidate: u32 = 0;
    var count: u32 = 0;
    while (count < 16) : (candidate += 1) {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "n{d}", .{candidate});
        if (std.hash.Wyhash.hash(0, name) & 31 != 0) continue;
        try source.writer.print("{s};{s};", .{ name, name });
        count += 1;
    }
    try source.writer.writeAll("}");
    try check(false, source.written());
}

test "zero fixed pools and complete admission fail explicitly without publishing" {
    const G = IR.FixedGraphStorage(.{});
    const S = IR.FixedLoweringScratch(G, .{});
    var g: G = .{};
    var s: S = .{};
    const memory: IR.LoweringMemory = .{ .graph = g.storage(), .scratch = s.storage() };
    var parsed = try Dot.parseAndValidate(a, "digraph {}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const result = IR.lowerCompleteIn(doc, memory, .{ .interpretation = Dot.interpretation(doc, .{}) });
    try equal(dot.ir.LoweringOutcome{ .failure = error.PoolExhausted }, result.outcome);
    try expect(result.graph == null);
    try equal(dot.ir.Resource.occurrence_pool, result.shortfall.?.resource);
    var partial = try Dot.parseAndValidate(a, "digraph {a", dot.diagnostic.discard, .{});
    defer partial.deinit(a);
    const incomplete = &partial.document.?;
    const invalid = IR.lowerCompleteIn(incomplete, memory, .{ .interpretation = Dot.interpretation(incomplete, .{}) });
    try equal(dot.ir.LoweringOutcome{ .failure = error.IncompleteDocument }, invalid.outcome);
    try expect(invalid.shortfall == null);
}

test "fixed graph outlives lowering scratch descriptors and Document pools" {
    const G = IR.FixedGraphStorage(.{ .nodes = 4, .scopes = 1, .occurrences = 1, .mentions = 8, .connections = 4, .declarations = 4, .attributes = 4, .attribute_keys = 4, .attribute_states = 32 });
    var retained: G = .{};
    const Build = struct {
        fn run(g: *G) !IR.Graph {
            var parsed = try Dot.parseAndValidate(a, "digraph {a[color=red];a:p->b:q}", dot.diagnostic.discard, .{});
            defer parsed.deinit(a);
            const doc = &parsed.document.?;
            const S = IR.FixedLoweringScratch(G, .{ .nesting = 2, .edge_nesting = 1, .pending_endpoints = 2 });
            var scratch: S = .{};
            var operation = try IR.loweringSessionIn(doc, .{ .graph = g.storage(), .scratch = scratch.storage() }, .{ .interpretation = Dot.interpretation(doc, .{}) });
            defer operation.deinit();
            try equal(dot.ir.LoweringOutcome.success, operation.run().outcome.?);
            const result = try operation.takeResult();
            @memset(&scratch.bytes, 0xcd);
            return result;
        }
    };
    var graph = try Build.run(&retained);
    defer graph.deinit();
    const node = try graph.nodeView((try graph.findNode("a")).?);
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{?f}", .{node.attribute("color")});
    try std.testing.expectEqualStrings("red", writer.buffered());
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    try expect((try edge.attribute("tailport")) != null);
}
