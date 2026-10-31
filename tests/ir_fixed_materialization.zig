const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const compare = @import("ir_sessions.zig").compareResults;
const IR = dot.ir.Lowering(.{});
const Topology = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });

fn Buffers(comptime attributes: bool) type {
    return struct {
        output: []align(16) u8,
        scratch: []align(16) u8,
        memory: IR.MaterializationMemory(attributes),
        fn init(graph: anytype, output: dot.ir.MaterializedCapacities, scratch: dot.ir.MaterializationScratchCapacities) !@This() {
            const layout = try IR.materializationLayout(graph, output, scratch, .{ .attributes = attributes });
            const retained = try a.alignedAlloc(u8, .@"16", layout.output_bytes + 16);
            errdefer a.free(retained);
            const temporary = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
            errdefer a.free(temporary);
            @memset(retained, 0xcd);
            @memset(temporary, 0xcd);
            return .{ .output = retained, .scratch = temporary, .memory = try layout.bind(retained, temporary) };
        }
        fn deinit(self: @This()) void {
            a.free(self.output);
            a.free(self.scratch);
        }
        fn canaries(self: @This()) !void {
            for (self.output[self.memory.output.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
            for (self.scratch[self.memory.scratch.bytes.len..]) |b| try eq(@as(u8, 0xcd), b);
        }
    };
}
fn check(comptime attributes: bool, graph: anytype) !void {
    var expected = try graph.materialize(.{ .attributes = attributes });
    defer expected.deinit();
    var options: dot.ir.Options = .{};
    _ = &options; // Bounds/layout accept runtime limits and hooks.
    const bounds = try IR.scanMaterializationBounds(graph, .{ .attributes = attributes, .limits = options.limits, .cancellation = options.cancellation });
    const metadata = try IR.materializationBounds(graph, .{ .attributes = attributes });
    const counts = expected.capacities();
    inline for (comptime @typeInfo(dot.ir.MaterializedCapacities).@"struct".field_names) |field| {
        try expect(@field(bounds.output, field) >= @field(counts, field));
        try expect(@field(metadata.output, field) >= @field(bounds.output, field));
    }
    try expect(metadata.scratch.members >= bounds.scratch.members);
    const memory = try Buffers(attributes).init(graph, counts, bounds.scratch);
    defer memory.deinit();
    var result = graph.materializeIn(memory.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, result.outcome);
    try expect(result.shortfall == null);
    try compare(attributes, &expected, &result.materialized.?);
    try eq(counts, result.materialized.?.capacities());
    try eq(memory.memory.output.bytes.len, result.materialized.?.retainedBytes());
    try eq(memory.memory.output.bytes.len + memory.memory.scratch.bytes.len, result.materialized.?.peak_bytes);
    const peak = result.scratch_peak;
    @memset(memory.memory.scratch.bytes, 0xcd);
    try compare(attributes, &expected, &result.materialized.?);
    result.materialized.?.deinit();
    const exact = try Buffers(attributes).init(graph, counts, peak);
    defer exact.deinit();
    var total: ?u64 = null;
    for ([_]u32{ 1, 7, 64, 4096 }) |budget| {
        var operation = try graph.materializationSessionIn(exact.memory, .{});
        try std.testing.expectError(error.NotReady, operation.takeResult());
        var used: u64 = 0;
        while (true) {
            try eq(@as(u32, 0), operation.advance(0).work_used);
            const p = operation.advance(budget);
            try expect(p.work_used <= budget);
            used += p.work_used;
            try eq(used, p.total_work);
            if (p.outcome) |outcome| {
                try eq(dot.ir.MaterializationOutcome.success, outcome);
                break;
            }
        }
        if (total) |n| try eq(n, used) else total = used;
        try eq(peak, operation.scratchPeak());
        var actual = try operation.takeResult();
        try std.testing.expectError(error.AlreadyTaken, operation.takeResult());
        operation.cancel();
        try eq(@as(u32, 0), operation.advance(1).work_used);
        operation.deinit();
        @memset(exact.memory.scratch.bytes, 0xcd);
        try compare(attributes, &expected, &actual);
        if (@hasField(@TypeOf(graph.*), "_coverage")) try eq(graph.state(), actual.state());
        actual.deinit();
        try exact.canaries();
    }
    const bounded = try Buffers(attributes).init(graph, bounds.output, bounds.scratch);
    defer bounded.deinit();
    const b = graph.materializeIn(bounded.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, b.outcome);
    try compare(attributes, &expected, &b.materialized.?);
    try bounded.canaries();
    try memory.canaries();
}
test "fixed materialization matches allocator output with exact pools and every grant size" {
    const fixtures = [_][]const u8{
        "digraph {}",
        "digraph {a->b;a->b;x->{};{}->{y z}}",
        "digraph {edge[color=red];{a b}->{x y};edge[color=blue];a->x}",
        "strict digraph {edge[color=red];{a b}->{x y}[label=old];edge[color=blue];a->x[label=new];x->x}",
        "strict graph {a:p:n--b:q[color=red];b:r--a:s[tailport=override label=\"a\"+<<B>b</B>>];a--b[tailport=\"\"]}",
        "digraph {subgraph s{a;subgraph inner{b}};x->subgraph s{c};subgraph s{d};x->subgraph s{}}",
        "digraph {a->b[a=1 b=2 c=3 d=4 e=5];a->b[c=last];{a a b}->{x y y}[a=2 c=3 b=4]}",
    };
    inline for (.{ IR, Topology }) |Profile| {
        for (fixtures) |source| {
            var result = try Profile.parse(a, source, .{});
            defer result.deinit();
            try check(false, result.ir().?);
            if (Profile.capabilities.attributes) try check(true, result.ir().?);
            var partial = try Profile.parsePartial(a, source, .{});
            defer partial.deinit();
            try check(false, partial.ir().?);
            if (Profile.capabilities.attributes) try check(true, partial.ir().?);
        }
        for ([_][]const u8{ "digraph {a:p->b:q;bad->;{a c}->b[x=1]}", "graph {a--b;bad->;c->d", "digraph {subgraph s{a;bad->;b};x->subgraph s{}" }) |source| {
            var result = try Profile.parsePartial(a, source, .{});
            defer result.deinit();
            try check(false, result.ir().?);
            if (Profile.capabilities.attributes) try check(true, result.ir().?);
        }
    }
}

test "every materialization pool shortfall is terminal and publishes no prefix" {
    var parsed = try IR.parse(a, "strict graph {edge[color=red];{a b}--{x y}[label=old];a--x[label=new];a:p--b:q}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    var expected = try graph.materialize(.{});
    defer expected.deinit();
    const counts = expected.capacities();
    const bounds = try IR.scanMaterializationBounds(graph, .{});
    const full = try Buffers(true).init(graph, counts, bounds.scratch);
    defer full.deinit();
    const first = graph.materializeIn(full.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, first.outcome);
    const peak = first.scratch_peak;
    inline for (.{ "edges", "attribute_states", "attribute_keys", "members" }, .{ dot.ir.Resource.materialized_edges, .materialized_attribute_states, .materialized_attribute_keys, .members }) |field, resource| {
        var reduced = counts;
        var scratch = peak;
        const amount = if (comptime std.mem.eql(u8, field, "members")) &scratch.members else &@field(reduced, field);
        try expect(amount.* != 0);
        amount.* -= 1;
        const memory = try Buffers(true).init(graph, reduced, scratch);
        defer memory.deinit();
        const direct = graph.materializeIn(memory.memory, .{});
        try eq(dot.ir.MaterializationOutcome{ .failure = error.PoolExhausted }, direct.outcome);
        try expect(direct.materialized == null);
        try eq(resource, direct.shortfall.?.resource);
        try eq(amount.*, direct.shortfall.?.limit);
        try eq(amount.* + 1, direct.shortfall.?.required_at_least);
        var operation = try graph.materializationSessionIn(memory.memory, .{});
        defer operation.deinit();
        while (operation.advance(1).outcome == null) {}
        try eq(direct.outcome, operation.run().outcome.?);
        try eq(direct.shortfall, operation.shortfall());
        try std.testing.expectError(error.PoolExhausted, operation.takeResult());
        try eq(@as(u32, 0), operation.advance(99).work_used);
        try memory.canaries();
    }
    // Restart, including after a late catalog shortfall, uses the same buffers.
    const restarted = graph.materializeIn(full.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, restarted.outcome);
    try compare(true, &expected, &restarted.materialized.?);
}

test "zero-cell defaults, duplicate updates and semantic limits before fixed capacity" {
    inline for (.{ false, true }) |stepped| {
        var parsed = try IR.parse(a, "strict digraph {edge[color=red];a->b;edge[color=blue];a->b}", .{});
        defer parsed.deinit();
        const graph = parsed.ir().?;
        const memory = try Buffers(true).init(graph, .{ .edges = 1, .attribute_keys = 1 }, .{});
        defer memory.deinit();
        if (stepped) {
            var operation = try graph.materializationSessionIn(memory.memory, .{ .limits = .{ .max_attribute_states = 0 } });
            defer operation.deinit();
            try eq(dot.ir.MaterializationOutcome.success, operation.run().outcome.?);
            var result = try operation.takeResult();
            defer result.deinit();
            try eq(@as(u32, 0), result.capacities().attribute_states);
        } else try eq(dot.ir.MaterializationOutcome.success, graph.materializeIn(memory.memory, .{ .limits = .{ .max_attribute_states = 0 } }).outcome);
    }
    var parsed = try IR.parse(a, "strict digraph {a->b[x=1];a->b[x=2];a->b[x=3]}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    const exact = try Buffers(true).init(graph, .{ .edges = 1, .attribute_states = 1, .attribute_keys = 1 }, .{});
    defer exact.deinit();
    try eq(dot.ir.MaterializationOutcome.success, graph.materializeIn(exact.memory, .{}).outcome);
    const zero = try Buffers(true).init(graph, .{ .edges = 1, .attribute_keys = 1 }, .{});
    defer zero.deinit();
    const options = .{ .limits = .{ .max_attribute_states = 0 } };
    const direct = graph.materializeIn(zero.memory, options);
    try eq(dot.ir.MaterializationOutcome{ .failure = error.AttributeStateLimit }, direct.outcome);
    try expect(direct.shortfall == null);
    var operation = try graph.materializationSessionIn(zero.memory, options);
    defer operation.deinit();
    try eq(direct.outcome, operation.run().outcome.?);
    try eq(dot.ir.Resource.materialized_attribute_states, graph.materializeIn(zero.memory, .{}).shortfall.?.resource);
    const empty = try Buffers(false).init(graph, .{}, .{});
    defer empty.deinit();
    const edge_limit = graph.materializeIn(empty.memory, .{ .limits = .{ .max_edges = 0 } });
    try eq(dot.ir.MaterializationOutcome{ .failure = error.EdgeLimit }, edge_limit.outcome);
    try expect(edge_limit.shortfall == null);
    try eq(dot.ir.MaterializationOutcome{ .failure = error.PairLimit }, graph.materializeIn(empty.memory, .{ .limits = .{ .max_pairs = 0 } }).outcome);
}

const Stop = struct {
    polls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(ctx.?));
        self.polls += 1;
        return self.polls >= self.at;
    }
    fn hook(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};
test "fixed materialization cancellation and work stops cannot transfer output or allocate" {
    var parsed = try IR.parse(a, "strict graph {{a b}--{x y}[longkey=1 z=2];a:p:n--x:q[longkey=3]}", .{});
    defer parsed.deinit();
    const graph = @constCast(parsed.ir().?);
    const counts = try IR.scanMaterializationBounds(graph, .{});
    const memory = try Buffers(true).init(graph, counts.output, counts.scratch);
    defer memory.deinit();
    const saved = graph.allocator;
    var trap = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    graph.allocator = trap.allocator();
    defer graph.allocator = saved;
    var stop: Stop = .{};
    const metadata = try IR.materializationBounds(graph, .{ .cancellation = stop.hook() });
    _ = metadata;
    try eq(@as(u64, 0), stop.polls); // Metadata/layout never call hooks.
    _ = try IR.materializationLayout(graph, counts.output, counts.scratch, .{ .cancellation = stop.hook() });
    try eq(@as(u64, 0), stop.polls);
    var first = try graph.materializationSessionIn(memory.memory, .{ .cancellation = stop.hook() });
    try eq(@as(u64, 1), stop.polls);
    for (memory.memory.output.bytes) |byte| try eq(@as(u8, 0xcd), byte);
    for (memory.memory.scratch.bytes) |byte| try eq(@as(u8, 0xcd), byte);
    const p = first.run();
    try eq(dot.ir.MaterializationOutcome.success, p.outcome.?);
    try eq(1 + p.total_work, stop.polls);
    first.deinit();
    for (2..stop.polls + 1) |at| {
        var cancel: Stop = .{ .at = at };
        var operation = try graph.materializationSessionIn(memory.memory, .{ .cancellation = cancel.hook() });
        defer operation.deinit();
        try eq(dot.ir.MaterializationOutcome{ .failure = error.Cancelled }, operation.run().outcome.?);
        try std.testing.expectError(error.Cancelled, operation.takeResult());
        try eq(@as(u32, 0), operation.advance(1).work_used);
    }
    var zero: Stop = .{ .at = 2 };
    var operation = try graph.materializationSessionIn(memory.memory, .{ .cancellation = zero.hook() });
    defer operation.deinit();
    const stopped = operation.advance(0);
    try eq(@as(u32, 0), stopped.work_used);
    try eq(dot.ir.MaterializationOutcome{ .failure = error.Cancelled }, stopped.outcome.?);
    var limited = try graph.materializationSessionIn(memory.memory, .{ .limits = .{ .max_work = p.total_work - 1 } });
    defer limited.deinit();
    try eq(dot.ir.MaterializationOutcome{ .failure = error.WorkLimit }, limited.run().outcome.?);
    try expect(limited.shortfall() == null);
    var direct_stop: Stop = .{ .at = 3 };
    try eq(dot.ir.MaterializationOutcome{ .failure = error.Cancelled }, graph.materializeIn(memory.memory, .{ .cancellation = direct_stop.hook() }).outcome);
    var direct = graph.materializeIn(memory.memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, direct.outcome);
    direct.materialized.?.deinit();
    try eq(@as(usize, 0), trap.alloc_index);
    try eq(@as(usize, 0), trap.freed_bytes);
    try memory.canaries();
}

fn invalid(graph: anytype, memory: anytype, err: dot.ir.Error) !void {
    const result = graph.materializeIn(memory, .{});
    try eq(dot.ir.MaterializationOutcome{ .failure = err }, result.outcome);
    try expect(result.materialized == null and result.shortfall == null);
    try std.testing.expectError(err, graph.materializationSessionIn(memory, .{}));
}
test "materialization validates descriptors alignment aliases and full reservations before writing" {
    var parsed = try IR.parse(a, "strict digraph {{a b}->{c d}[x=1]}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    const layout = try IR.materializationLayout(graph, .{ .edges = 4, .attribute_states = 4, .attribute_keys = 1 }, .{ .members = 4 }, .{});
    var output: [2048]u8 align(16) = @splat(0xcd);
    var scratch: [2048]u8 align(16) = @splat(0xcd);
    try std.testing.expectError(error.BufferTooSmall, layout.bind(output[0 .. layout.output_bytes - 1], &scratch));
    try std.testing.expectError(error.BufferTooSmall, layout.bind(&output, scratch[0 .. layout.scratch_bytes - 1]));
    try std.testing.expectError(error.InvalidStorage, layout.bind(output[1..], &scratch));
    try std.testing.expectError(error.InvalidStorage, layout.bind(&output, scratch[1..]));
    try std.testing.expectError(error.InvalidStorage, layout.bind(&output, &output));
    var forged = layout;
    forged.retained.cells += 4;
    try std.testing.expectError(error.InvalidStorage, forged.bind(&output, &scratch));
    const memory = try layout.bind(&output, &scratch);
    var bad = memory;
    bad.output.capacities.edges += 1;
    try invalid(graph, bad, error.InvalidStorage);
    bad = memory;
    bad.scratch.node_capacity = 1;
    try invalid(graph, bad, error.InvalidStorage);
    bad = memory;
    bad.scratch.bytes = bad.output.bytes;
    try invalid(graph, bad, error.InvalidStorage);
    const short = graph.materializeIn(memory, .{ .limits = .{ .max_bytes = layout.output_bytes + layout.scratch_bytes - 1 } });
    try eq(dot.ir.MaterializationOutcome{ .failure = error.MemoryLimit }, short.outcome);
    try std.testing.expectError(error.MemoryLimit, graph.materializationSessionIn(memory, .{ .limits = .{ .max_bytes = layout.output_bytes + layout.scratch_bytes - 1 } }));
    // Forged output can overlap live IR records; reject before touching them.
    bad = memory;
    bad.output.capacities = .{ .edges = 1 };
    bad.scratch.output_capacities = bad.output.capacities;
    bad.output.bytes = @constCast(std.mem.sliceAsBytes(graph.nodes));
    try invalid(graph, bad, error.InvalidStorage);
    for (output) |b| try eq(@as(u8, 0xcd), b);
    for (scratch) |b| try eq(@as(u8, 0xcd), b);
    try std.testing.expectError(error.InvalidStorage, IR.materializationLayout(graph, .{ .attribute_states = 1 }, .{}, .{ .attributes = false }));
    try std.testing.expectError(error.IndexLimit, IR.materializationLayout(graph, .{ .edges = std.math.maxInt(u32) }, .{}, .{}));
}

test "inline output helpers infer attributes and omit unused strict tables" {
    const Retained = IR.FixedGraphStorage(.{ .nodes = 8 });
    inline for (.{ false, true }) |attributes| {
        const Output = IR.FixedMaterializedStorage(.{ .edges = 4 }, .{ .attributes = attributes });
        const Scratch = IR.FixedMaterializationScratch(Retained, Output, .{}, .{});
        const NonStrict = IR.FixedMaterializationScratch(Retained, Output, .{}, .{ .strict = false });
        try expect(NonStrict.byte_size == 0 and Scratch.byte_size > 0);
        var output: Output = .{};
        var scratch: Scratch = .{};
        @memset(&scratch.bytes, 0xcd);
        var compact: NonStrict = .{};
        for ([_][]const u8{ "digraph {a->b;a->b}", "strict digraph {}", "strict digraph {a->b;a->b}" }) |source| {
            var parsed = try IR.parse(a, source, .{});
            defer parsed.deinit();
            const graph = parsed.ir().?;
            const memory: IR.MaterializationMemory(attributes) = .{ .output = output.storage(), .scratch = scratch.storage() };
            var direct = graph.materializeIn(memory, .{});
            try eq(dot.ir.MaterializationOutcome.success, direct.outcome);
            direct.materialized.?.deinit();
            var operation = try graph.materializationSessionIn(memory, .{});
            defer operation.deinit();
            try eq(dot.ir.MaterializationOutcome.success, operation.run().outcome.?);
            var result = try operation.takeResult();
            defer result.deinit();
            const small: IR.MaterializationMemory(attributes) = .{ .output = output.storage(), .scratch = compact.storage() };
            if (graph.strict) try invalid(graph, small, error.InvalidStorage) else {
                for (scratch.bytes) |b| try eq(@as(u8, 0xcd), b);
                try eq(dot.ir.MaterializationOutcome.success, graph.materializeIn(small, .{}).outcome);
            }
        }
    }
}

test "explicit bounds count written bodies not products and include empty endpoint demand" {
    var parsed = try IR.parse(a, "strict digraph {node[node_key=1];graph[graph_key=2];a:p->b:q[x=1];a->b[x=2];a->{};{}->{a b}}", .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    const b = try IR.scanMaterializationBounds(graph, .{});
    try eq(dot.ir.MaterializedCapacities{ .edges = 2, .attribute_states = 4, .attribute_keys = 5 }, b.output);
    try eq(@as(u32, 2), b.scratch.members);
    const m = try IR.materializationBounds(graph, .{});
    try eq(@as(u32, 4), m.output.edges); // Strict universe, not the million-edge default.
    const clipped = try IR.scanMaterializationBounds(graph, .{ .limits = .{ .max_pairs = 1, .max_edges = 1, .max_attribute_states = 1 } });
    try eq(@as(u32, 1), clipped.output.edges);
    try eq(@as(u32, 1), clipped.output.attribute_states);
    var stop: Stop = .{ .at = 1 };
    try std.testing.expectError(error.Cancelled, IR.scanMaterializationBounds(graph, .{ .cancellation = stop.hook() }));
    try std.testing.expectError(error.WorkLimit, IR.scanMaterializationBounds(graph, .{ .limits = .{ .max_work = 0 } }));
    // Many repeated memberships and deep scopes stay symbolic in sizing.
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    for (0..300) |_| try source.writer.writeAll("{");
    for (0..200) |i| try source.writer.print("subgraph s{{n{d}}}->subgraph s{{}};", .{i});
    for (0..300) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("}");
    var large = try IR.parse(a, source.written(), .{});
    defer large.deinit();
    const g = large.ir().?;
    const bounds = try IR.scanMaterializationBounds(g, .{ .limits = .{ .max_pairs = 100, .max_edges = 20 } });
    try eq(@as(u32, 20), bounds.output.edges);
    try expect(bounds.scratch.members <= 2 * g.nodes.len);
    try expect(g.connections.len == 200); // No Cartesian expansion to size.
}

test "native encodings share fixed folding and bounded port-name comparisons" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const source = "strict graph {edge[café=初];a:\"埠😀\":n--b:q[label=\"😀\"+<<b>中文&amp;</b>>];b:<終>--a:p[\"head\"+<>+\"port\"=override]}";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var encoded: std.Io.Writer.Allocating = .init(a);
        defer encoded.deinit();
        var chars = (try std.unicode.Utf8View.init(source)).iterator();
        while (chars.nextCodepoint()) |cp| {
            if (E.width == 2) {
                if (cp <= 0xffff) try encoded.writer.writeInt(u16, @intCast(cp), E.endian) else {
                    try encoded.writer.writeInt(u16, @intCast(0xd800 + ((cp - 0x10000) >> 10)), E.endian);
                    try encoded.writer.writeInt(u16, @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff)), E.endian);
                }
            } else try encoded.writer.writeInt(u32, cp, E.endian);
        }
        var parsed = try P.parseAndValidate(a, encoded.written(), dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        var graph = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer graph.deinit();
        try check(true, &graph);
    }
}

test "fixed input IR reservation and partial coverage cannot be overwritten by materialization" {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
    var parsed = P.parseAndValidate(a, "digraph {a->b[x=1];bad->;c->d}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const Retained = IR.FixedGraphStorage(.{ .nodes = 16, .scopes = 4, .occurrences = 4, .mentions = 32, .connections = 16, .declarations = 16, .attributes = 16, .attribute_keys = 8, .attribute_states = 64, .coverage_gaps = 8 });
    var retained: Retained = .{};
    var scratch: IR.FixedLoweringScratch(Retained, .{ .nesting = 8, .edge_nesting = 4, .pending_endpoints = 16 }) = .{};
    const lowered = IR.lowerPartialIn(doc, .{ .graph = retained.storage(), .scratch = scratch.storage() }, .{ .interpretation = P.interpretation(doc, .{}) });
    try eq(dot.ir.LoweringOutcome.success, lowered.outcome);
    const graph = &lowered.graph.?;
    const Output = IR.FixedMaterializedStorage(.{ .edges = 8, .attribute_states = 16, .attribute_keys = 8 }, .{});
    var output: Output = .{};
    var temporary: IR.FixedMaterializationScratch(Retained, Output, .{ .members = 32 }, .{}) = .{};
    const memory: IR.MaterializationMemory(true) = .{ .output = output.storage(), .scratch = temporary.storage() };
    var result = graph.materializeIn(memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, result.outcome);
    try eq(graph.state(), result.materialized.?.state());
    result.materialized.?.deinit();
    var bad = memory;
    bad.output.bytes = retained.bytes[retained.bytes.len - output.bytes.len ..];
    try invalid(graph, bad, error.InvalidStorage);
    bad = memory;
    bad.scratch.bytes = retained.bytes[retained.bytes.len - temporary.bytes.len ..];
    try invalid(graph, bad, error.InvalidStorage);
    var session = try graph.materializationSessionIn(memory, .{});
    while (session.advance(1).outcome == null) {}
    var completed = try session.takeResult();
    session.deinit();
    defer completed.deinit();
    @memset(&temporary.bytes, 0xcd);
    var edges = completed.edgeIterator();
    try expect(edges.next() != null);
    // Reusing even the unused part of live fixed output as query scratch is invalid.
    const query_layout = try IR.attributeScratchLayout(.{ .winners = 1 });
    const borrowed = try query_layout.bind(output.bytes[output.bytes.len - query_layout.byte_size ..]);
    try std.testing.expectError(error.InvalidStorage, IR.attributesSessionIn(edges.next().?, borrowed, .{}));
}

test "borrowed ownership does not enlarge the materialized handle" {
    // Previously: used edges, allocated edges, allocator and peak bytes.
    try eq(7 * @sizeOf(usize), @sizeOf(dot.ir.MaterializedTopology));
    const Previous = struct {
        edges: []const dot.ir.Edge,
        peak_bytes: usize,
        graph: *const IR.Graph,
        allocator: std.mem.Allocator,
        storage: []dot.ir.Edge,
        folded: @FieldType(IR.Graph.Materialized, "folded"),
    };
    try eq(@sizeOf(Previous), @sizeOf(IR.Graph.Materialized));
}
