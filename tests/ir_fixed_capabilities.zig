const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
const Full = dot.ir.Lowering(.{});

test "fixed storage identity includes capabilities and encodings but not execution or limits" {
    const Scheduled = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .runtime_policy = true, .policy = .{ .execution = .{ .metering = true, .cancellation = true } }, .limits = .{ .max_nodes = 8 } });
    const Native = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    inline for (.{ "GraphStorage", "LoweringScratch", "LoweringMemory" }) |field| {
        try expect(@field(IR, field) == @field(Scheduled, field));
        try expect(@field(IR, field) != @field(Full, field));
        try expect(@field(IR, field) != @field(Native, field));
    }
    const G = IR.FixedGraphStorage(.{ .nodes = 3 });
    try expect(G == Scheduled.FixedGraphStorage(.{ .nodes = 3 }));
    try expect(IR.FixedLoweringScratch(G, .{}) == Scheduled.FixedLoweringScratch(G, .{}));
    try expect(@sizeOf(Scheduled.FixedLoweringSession) < @sizeOf(Full.FixedLoweringSession));
    // Omitting pools also omits their layout descriptors in fixed sessions.
    const topology = try IR.loweringLayout(.{ .connections = 10 }, .{});
    const full = try Full.loweringLayout(.{ .connections = 10 }, .{});
    try expect(topology.graph_bytes < full.graph_bytes);
    try expect(@sizeOf(@TypeOf(topology)) < @sizeOf(@TypeOf(full)));
}

test "disabled fixed pools reject reservations and forged metadata before any write" {
    const counts: dot.ir.GraphCapacities = .{ .nodes = 2, .scopes = 1, .occurrences = 1, .mentions = 2, .connections = 1 };
    const scratch: dot.ir.LoweringScratchCapacities = .{ .nesting = 2, .edge_nesting = 1, .pending_endpoints = 2 };
    const layout = try IR.loweringLayout(counts, scratch);
    const retained = try a.alignedAlloc(u8, .@"16", layout.graph_bytes);
    defer a.free(retained);
    const temporary = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes);
    defer a.free(temporary);
    @memset(retained, 0xcd);
    @memset(temporary, 0xcd);
    var parsed = dot.parseAndValidate(a, "digraph {a->b}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    inline for (.{ "declarations", "attributes", "attribute_keys", "attribute_states" }) |field| {
        var invalid = counts;
        @field(invalid, field) = 1;
        try std.testing.expectError(error.InvalidStorage, IR.loweringLayout(invalid, scratch));
        var forged = layout;
        forged.graph_capacities = invalid;
        try std.testing.expectError(error.InvalidStorage, forged.bind(retained, temporary));
        var memory = try layout.bind(retained, temporary);
        memory.graph.capacities = invalid;
        memory.scratch.graph_capacities = invalid;
        const result = IR.lowerCompleteIn(doc, memory, options);
        try eq(dot.ir.LoweringOutcome{ .failure = error.InvalidStorage }, result.outcome);
        try expect(result.graph == null and result.shortfall == null);
        try std.testing.expectError(error.InvalidStorage, IR.loweringSessionIn(doc, memory, options));
    }
    for (retained) |byte| try eq(@as(u8, 0xcd), byte);
    for (temporary) |byte| try eq(@as(u8, 0xcd), byte);
}

test "topology bounds omit attribute arithmetic and preserve symbolic topology coverage" {
    const counts: dot.DocumentCapacities = .{ .attributes = std.math.maxInt(u32) - 1, .assignments = std.math.maxInt(u32) - 1, .attribute_statements = std.math.maxInt(u32) - 1, .nodes = 7, .subgraphs = 3, .edges = 2, .statements = 20 };
    const bounds = try IR.partialLoweringBounds(counts, .{ .limits = .{ .max_attributes = 0, .max_attribute_states = 0 } });
    inline for (.{ "declarations", "attributes", "attribute_keys", "attribute_states" }) |field| try eq(@as(u32, 0), @field(bounds.graph, field));
    try eq(@as(u32, 11), bounds.graph.nodes);
    try eq(@as(u32, 2), bounds.graph.connections);
    try eq(@as(u32, 11), bounds.graph.coverage_gaps);
    try std.testing.expectError(error.IndexLimit, Full.partialLoweringBounds(counts, .{}));
    // Removed attribute limits never prevent topology construction.
    var parsed = dot.parseAndValidate(a, "digraph {node[x=1];a[x=2];a:p->b:q[x=3]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const G = IR.FixedGraphStorage(.{ .nodes = 2, .scopes = 1, .occurrences = 1, .mentions = 3, .connections = 1, .endpoint_ports = 2 });
    var retained: G = .{};
    var scratch: IR.FixedLoweringScratch(G, .{ .nesting = 2, .edge_nesting = 1, .pending_endpoints = 2 }) = .{};
    const memory: IR.LoweringMemory = .{ .graph = retained.storage(), .scratch = scratch.storage() };
    const options = .{ .interpretation = Dot.interpretation(doc, .{}), .limits = .{ .max_attributes = 0, .max_attribute_states = 0 } };
    const result = IR.lowerCompleteIn(doc, memory, options);
    try eq(dot.ir.LoweringOutcome.success, result.outcome);
    try eq(@as(usize, 2), result.graph.?.endpoint_ports.len);
    var session = try IR.loweringSessionIn(doc, memory, options);
    defer session.deinit();
    try eq(dot.ir.LoweringOutcome.success, session.run().outcome.?);
}

test "topology fixed limits precede shortfalls and edge scratch uses borrowed reservation" {
    var parsed = dot.parseAndValidate(a, "digraph {a->{b c}}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    const G = IR.FixedGraphStorage(.{ .nodes = 8, .scopes = 2, .occurrences = 2, .mentions = 8, .connections = 4 });
    var retained: G = .{};
    var scratch: IR.FixedLoweringScratch(G, .{ .nesting = 4, .edge_nesting = 1, .pending_endpoints = 2 }) = .{};
    var memory: IR.LoweringMemory = .{ .graph = retained.storage(), .scratch = scratch.storage() };
    const full_memory = memory;
    memory.graph.capacities.nodes = 0;
    memory.scratch.graph_capacities.nodes = 0;
    const limited_options = .{ .interpretation = options.interpretation, .limits = .{ .max_nodes = 0 } };
    const limited = IR.lowerCompleteIn(doc, memory, limited_options);
    try eq(dot.ir.LoweringOutcome{ .failure = error.NodeLimit }, limited.outcome);
    try expect(limited.shortfall == null and limited.graph == null);
    var stopped = try IR.loweringSessionIn(doc, memory, limited_options);
    defer stopped.deinit();
    try eq(limited.outcome, stopped.run().outcome.?);
    const short = IR.lowerCompleteIn(doc, memory, options);
    try eq(dot.ir.Resource.node_pool, short.shortfall.?.resource);
    const result = IR.lowerCompleteIn(doc, full_memory, options);
    try eq(dot.ir.LoweringOutcome.success, result.outcome);
    const graph = &result.graph.?;
    const edge_layout = try IR.edgeScratchLayout(graph, .{ .members = 6 });
    // Even unused retained capacity belongs to this live graph.
    const alias = try edge_layout.bind(retained.bytes[retained.bytes.len - edge_layout.byte_size ..]);
    try std.testing.expectError(error.InvalidStorage, graph.edgeIteratorIn(alias, .{}));
    var edge_scratch: IR.FixedEdgeScratch(G, .{ .members = 6 }) = .{};
    @memset(&scratch.bytes, 0xcd); // Lowering scratch no longer belongs to the graph.
    var edges = try graph.edgeIteratorIn(edge_scratch.storage(), .{});
    defer edges.deinit();
    var count: usize = 0;
    while (try edges.next()) |_| count += 1;
    try eq(@as(usize, 2), count);
}
