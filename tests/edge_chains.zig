const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const deep = std.testing.expectEqualDeep;
const source = @embedFile("corpus/valid/edge_chain.dot");
const capacities: dot.DocumentCapacities = .{
    .statements = 5,
    .nodes = 1,
    .edges = 1,
    .edge_chains = 2,
    .edge_links = 3,
    .attributes = 3,
    .assignments = 1,
};

test "chain hints consume only exact pool bytes with a fixed-buffer allocator" {
    var bytes: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&bytes);
    var parsed = dot.parseBorrowed(fba.allocator(), source, dot.diagnostic.discard, .{ .document_capacities = capacities });
    defer parsed.deinit(fba.allocator());
    try expect(parsed.outcome == .success);
    const expected = 5 * @sizeOf(dot.StatementId) + @sizeOf(dot.NodeStatement) +
        @sizeOf(dot.EdgeStatement) + 2 * @sizeOf(dot.EdgeChainStatement) +
        3 * @sizeOf(dot.EdgeLink) + 3 * @sizeOf(dot.Attribute) + @sizeOf(dot.Assignment);
    try equal(@as(usize, expected), fba.end_index);
}

test "long chains yield without exposing partially built statements" {
    var bytes: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("digraph {a");
    for (0..4096) |_| try writer.writeAll("->a");
    try writer.writeAll("}");
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 4095 }) = .{};
    var session = dot.BoundedSession.init(writer.buffered(), pools.storage(), dot.diagnostic.discard, .{ .max_statements = 1 });
    defer session.deinit();
    var total: usize = 0;
    while (true) {
        const progress = session.advance(17);
        try expect(progress.work_used <= 17);
        total += progress.work_used;
        if (progress.outcome != null) {
            try expect(progress.outcome.? == .success);
            break;
        }
        try expect(session.result() == null);
    }
    try expect(total > writer.buffered().len);
    try equal(@as(usize, 4095), session.result().?.document.?.edge_links.len);
}

test "fuzz: chains preserve every written endpoint across storage policies" {
    try std.testing.fuzz({}, fuzzChains, .{});
}

fn fuzzChains(_: void, smith: *std.testing.Smith) !void {
    const count: usize = @as(usize, smith.value(u6)) + 2;
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("digraph {0");
    for (1..count + 1) |i| try writer.print("-> {d}", .{i});
    try writer.writeAll("[k=v]}");
    var parsed = dot.parseBorrowed(std.testing.allocator, writer.buffered(), dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 64, .attributes = 1 }) = .{};
    const fixed = dot.parseBorrowedIn(writer.buffered(), pools.storage(), dot.diagnostic.discard, .{});
    try expect(fixed.outcome == .success);
    try deep(parsed.document.?, fixed.document.?);
    var edges = parsed.document.?.edgeIterator();
    for (0..count) |i| {
        const edge = edges.next().?;
        try equal(i, try std.fmt.parseInt(usize, parsed.document.?.text(edge.left), 10));
        try equal(i + 1, try std.fmt.parseInt(usize, parsed.document.?.text(edge.right), 10));
    }
    try expect(edges.next() == null);
}

test "chains retain one source statement and share attributes without expanding storage" {
    var parsed = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    const doc = &parsed.document.?;
    var pools: dot.FixedDocumentStorage(capacities) = .{};
    const fixed = dot.parseBorrowedIn(source, pools.storage(), dot.diagnostic.discard, .{});
    try expect(fixed.outcome == .success);
    try deep(doc.*, fixed.document.?);
    try equal(@as(usize, 5), doc.statementCount());
    try equal(@as(usize, 1), doc.edges.len);
    try equal(@as(usize, 2), doc.edge_chains.len);
    try equal(@as(usize, 3), doc.edge_links.len);
    try equal(@as(usize, 1), doc.nodes.len); // No implicit nodes.
    const chain = doc.statementAt(1).?.edge_chain;
    try strings("a", doc.text(chain.first.left));
    try strings("\"b\"+\"B\"", doc.text(chain.first.right));
    const links = doc.edgeLinkSlice(chain.links).?;
    try equal(@as(usize, 2), links.len);
    try strings("-.5", doc.text(links[0].right));
    try strings("d", doc.text(links[1].right));
    const attrs = doc.attributeSlice(chain.first.attributes).?;
    try equal(@as(usize, 2), attrs.len);
    try strings("red", doc.text(attrs[0].value));
    try strings("blue", doc.text(attrs[1].value));
    var edges = doc.edgeIterator();
    const left = [_][]const u8{ "a", "\"b\"+\"B\"", "-.5", "x", "p", "q" };
    const right = [_][]const u8{ "\"b\"+\"B\"", "-.5", "d", "y", "q", "r" };
    for (left, right, 0..) |l, r, i| {
        const edge = edges.next().?;
        try strings(l, doc.text(edge.left));
        try strings(r, doc.text(edge.right));
        try equal(@as(u32, if (i < 3) 2 else if (i == 3) 0 else 1), edge.attributes.len);
    }
    try expect(edges.next() == null);
    try expect(edges.next() == null);
    try expect(doc.statement(.{ .edge_chain = 2 }) == null);
    try expect(doc.edgeLinkSlice(.{ .start = 4 }) == null);
    try expect(doc.edgeLinkSlice(.{ .start = 3, .len = 1 }) == null);
    try expect(doc.edgeLinkSlice(.{ .len = std.math.maxInt(u32) }) == null);
    try equal(@as(usize, 0), doc.edgeLinkSlice(.{ .start = 3 }).?.len);
}

test "validation merges chains and ordinary edges in source order and reports every operator" {
    const input = "graph { a -> b -- c -> d; x -> y; p -- q -> r; }";
    var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    var bag: dot.FixedDiagnosticBag(8) = .{};
    const result = dot.validate(&parsed.document.?, bag.sink(), .{});
    try equal(@as(usize, 4), result.outcome.completed.violations);
    var previous: usize = 0;
    for (bag.items()) |diagnostic| {
        try expect(diagnostic.span.start.byte_offset > previous);
        previous = diagnostic.span.start.byte_offset;
        try strings("->", diagnostic.span.slice(input));
        try strings("graph", diagnostic.details.operator_mismatch.declaration.slice(input));
    }
}

test "chain failures name the exact fixed pool and discard all staged links" {
    const Case = struct { cap: dot.DocumentCapacities, resource: dot.diagnostic.Capacity.Resource };
    inline for ([_]Case{
        .{ .cap = .{ .statements = 1, .edge_chains = 1 }, .resource = .edge_link_pool },
        .{ .cap = .{ .statements = 1, .edge_links = 2 }, .resource = .edge_chain_pool },
        .{ .cap = .{ .edge_chains = 1, .edge_links = 2 }, .resource = .statement_pool },
    }) |case| {
        var pools: dot.FixedDocumentStorage(case.cap) = .{};
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var session = dot.BoundedSession.init("graph {a--b--c--d}", pools.storage(), bag.sink(), .{});
        defer session.deinit();
        while (session.advance(1).outcome == null) {}
        const result = session.result().?;
        try expect(result.outcome == .storage_failure);
        try equal(dot.StorageFailure.pool_exhausted, result.outcome.storage_failure);
        try expect(result.document == null);
        try equal(case.resource, bag.items()[0].details.capacity.resource);
        try equal(@as(usize, 0), bag.items()[0].details.capacity.limit);
        session.reset("graph {}", dot.diagnostic.discard, .{});
        const reused = session.run();
        try expect(reused.outcome == .success);
        try equal(@as(usize, 0), reused.document.?.edge_links.len);
    }
}

test "chains count as one statement and ordinary edges need no chain capacity" {
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 2 }) = .{};
    var session = dot.BoundedSession.init("digraph {a->b->c->d}", pools.storage(), dot.diagnostic.discard, .{ .max_statements = 1 });
    defer session.deinit();
    var progress = session.advance(1);
    while (progress.outcome == null) progress = session.advance(1);
    try expect(progress.outcome.? == .success);
    try equal(@as(usize, 1), progress.completed_statements);
    try equal(@as(usize, 0), progress.completed_pairs);
    try expect(dot.validate(&session.result().?.document.?, dot.diagnostic.discard, .{}).documentValid());
    var single: dot.FixedDocumentStorage(.{ .statements = 1, .edges = 1 }) = .{};
    try expect(dot.parseBorrowedIn("graph {a--b}", single.storage(), dot.diagnostic.discard, .{}).outcome == .success);
    try equal(@as(usize, 36), @sizeOf(dot.EdgeStatement));
    try equal(@as(usize, 44), @sizeOf(dot.EdgeChainStatement));
    try equal(@as(usize, 20), @sizeOf(dot.EdgeLink));
}

test "malformed chain suffixes are syntax errors and subgraph endpoints remain deferred" {
    inline for (.{ "graph {a--b--}", "graph {a--b--", "graph {a--b--c--}", "graph {a--b--c[x=]}", "graph {a--b--c[x=1]--d}" }) |input| {
        var a: dot.FixedDiagnosticBag(2) = .{};
        var b: dot.FixedDiagnosticBag(2) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, input, a.sink(), .{});
        defer parsed.deinit(std.testing.allocator);
        var pools: dot.FixedDocumentStorage(capacities) = .{};
        const fixed = dot.parseBorrowedIn(input, pools.storage(), b.sink(), .{});
        try expect(parsed.outcome == .invalid_syntax and fixed.outcome == .invalid_syntax);
        try expect(parsed.document == null and fixed.document == null);
        try deep(a.items(), b.items());
    }
    inline for (.{ "graph {a--b--{c}}", "graph {a--b--subgraph s {c}}", "graph {a--b--c:p}" }) |input| {
        var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        try expect(parsed.outcome == .unsupported_feature);
        try expect(parsed.document == null);
    }
}

fn allocations(allocator: std.mem.Allocator, hinted: bool) !void {
    var parsed = dot.parseBorrowed(allocator, source, dot.diagnostic.discard, .{ .document_capacities = if (hinted) capacities else .{} });
    defer parsed.deinit(allocator);
    if (parsed.outcome == .storage_failure and parsed.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    try expect(parsed.outcome == .success);
}

test "all chain allocation and transfer failure points clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{true});
}

test "all chain corpus prefixes agree across storage paths" {
    for (0..source.len + 1) |end| {
        var parsed = dot.parseBorrowed(std.testing.allocator, source[0..end], dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        var pools: dot.FixedDocumentStorage(capacities) = .{};
        const fixed = dot.parseBorrowedIn(source[0..end], pools.storage(), dot.diagnostic.discard, .{});
        try equal(std.meta.activeTag(parsed.outcome), std.meta.activeTag(fixed.outcome));
        if (parsed.outcome == .success) try deep(parsed.document.?, fixed.document.?) else try expect(parsed.document == null and fixed.document == null);
    }
}
