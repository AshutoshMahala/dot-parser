const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const capacities: dot.DocumentCapacities = .{ .statements = 64, .subgraphs = 32, .nodes = 32, .edges = 16, .edge_chains = 16, .edge_links = 32, .scoped_edges = 16, .scoped_edge_links = 32, .ported_references = 16, .attributes = 32, .assignments = 16, .attribute_statements = 16 };
const Pools = dot.FixedDocumentStorage(capacities);
const Scratch = dot.FixedParseScratch(.{ .nesting = 16 });
const source = "digraph { a:p->b->c->{ x:q->subgraph s { y->z[k=inner] }->w }->d->{ e; f }->g[k=outer] {h}->i->j; {}->{} }";

test "empty endpoints count as scopes not statements and cannot carry ports" {
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .subgraphs = 3, .scoped_edges = 1, .scoped_edge_links = 1, .attributes = 1 }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    const memory: dot.ParseMemory = .{ .document = pools.storage(), .scratch = scratch.storage() };
    const result = dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 1, .max_nesting = 1 } } }).parseBorrowedIn("graph {subgraph s {}--subgraph s {}--{}[k=v]}", memory, dot.diagnostic.discard, .{});
    try expect(result.outcome == .success);
    const doc = &result.document.?;
    try equal(@as(usize, 1), doc.statementCount());
    try equal(@as(usize, 3), doc.subgraph_records.len);
    try equal(@as(usize, 0), count(doc.scope(.root).?.nodeReferences(.recursive)));
    try equal(@as(usize, 2), count(doc.edgeIterator()));
    try expect(doc.statement(.{ .scoped_edge = 1 }) == null);
    inline for (.{ "graph {{}:p--a}", "graph {a--{}:p}", "graph {a--b--{}:p}", "graph {{}[k=v]}", "graph {a--subgraph s;}", "graph {{}--}", "graph {a--{}[x=1]--b}" }) |input| {
        var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        try expect(parsed.outcome == .invalid_syntax);
        try expect(parsed.document == null);
    }
    try expect(dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 1 } } }).parseBorrowedIn("graph {a--{b}}", memory, dot.diagnostic.discard, .{}).outcome == .resource_exhausted);
}
fn count(value: anytype) usize {
    var it = value;
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

test "endpoint scopes retain syntax without expansion and preserve nested ownership" {
    var result = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .success);
    const doc = &result.document.?;
    try equal(@as(usize, 8), doc.statementCount());
    try equal(@as(usize, 6), count(doc.subgraphs()));
    const root = doc.scope(.root).?;
    try equal(@as(usize, 3), count(root.statements(.direct)));
    try equal(@as(usize, 5), count(root.subgraphs(.direct)));
    try equal(@as(usize, 12), count(doc.edgeIterator()));
    try equal(@as(usize, 9), count(root.edges(.direct)));
    const chain = doc.statementAt(0).?.edge_chain;
    try equal(@as(usize, 5), doc.edgeLinkCount(chain));
    try equal(@as(usize, 5), count(doc.edgeLinks(chain)));
    const attrs = doc.attributeSlice(chain.first.attributes).?;
    try std.testing.expectEqualStrings("outer", doc.text(attrs[0].value));
    var links = doc.edgeLinks(chain);
    try expect(links.next().?.right == .node);
    const group = links.next().?.right.subgraph;
    try equal(@as(usize, 1), count(doc.scope(group).?.statements(.direct)));
    try equal(@as(usize, 2), count(doc.scope(group).?.statements(.recursive)));
    try equal(@as(usize, 3), count(doc.scope(group).?.edges(.recursive)));
    var edges = doc.edgeIterator();
    var previous: usize = 0;
    while (edges.next()) |edge| {
        try expect(edge.operator_range.start > previous);
        previous = edge.operator_range.start;
    }
    const scopes = [_]u32{ 0, 1, 2, 3, 3, 0, 4, 0 };
    // Statement traversal is owner-first, while operators use lexical order.
    var statements = doc.statements();
    for (scopes) |scope| try equal(scope, @intFromEnum(statements.nextScoped().?.scope));
    try expect(statements.next() == null);
    try equal(@as(usize, 36), @sizeOf(dot.EdgeStatement));
    try equal(@as(usize, 20), @sizeOf(dot.EdgeLink));
    try equal(@as(usize, 44), @sizeOf(dot.EdgeChainStatement));
}

test "endpoint prefixes agree across allocated fixed bounded and cancellation profiles" {
    for (0..source.len + 1) |end| {
        var bag: dot.FixedDiagnosticBag(2) = .{};
        var owned = dot.parseBorrowed(std.testing.allocator, source[0..end], bag.sink(), .{});
        defer owned.deinit(std.testing.allocator);
        inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
            var pools: Pools = .{};
            var scratch: Scratch = .{};
            var other: dot.FixedDiagnosticBag(2) = .{};
            var session = dot.Profile(.{ .policy = .{ .execution = .{ .metering = metering, .cancellation = cancellation } } }).Session.init(source[0..end], .{ .document = pools.storage(), .scratch = scratch.storage() }, other.sink(), .{});
            defer session.deinit();
            if (metering) {
                var calls: usize = 0;
                while (session.advance(1).outcome == null) : (calls += 1) try expect(calls < 32 * source.len);
            } else _ = session.run();
            try deep(owned.outcome, session.result().?.outcome);
            try deep(owned.document, session.result().?.document);
            try deep(bag.items(), other.items());
        };
    }
}

test "late promotion retains a long node-only prefix without copying or unbounded work" {
    var bytes: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writer.writeAll("digraph {a");
    for (0..2048) |_| try writer.writeAll("->a");
    try writer.writeAll("->{b->c}->d}");
    var pools: dot.FixedDocumentStorage(.{ .statements = 2, .edges = 1, .subgraphs = 1, .edge_links = 2047, .scoped_edges = 1, .scoped_edge_links = 2 }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    var session = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true }, .limits = .{ .max_statements = 2 } } }).Session.init(writer.buffered(), .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{});
    defer session.deinit();
    while (true) {
        const progress = session.advance(1);
        try expect(progress.work_used <= 1);
        if (progress.outcome) |outcome| {
            try expect(outcome == .success);
            break;
        }
    }
    const doc = &session.result().?.document.?;
    try equal(@as(usize, 2047), doc.edge_links.len);
    try equal(@as(usize, 2), doc.scoped_edge_links.len);
    try equal(@as(usize, 2051), count(doc.edgeIterator()));
}

fn allocations(allocator: std.mem.Allocator, hinted: bool) !void {
    var result = dot.parseBorrowed(allocator, source, dot.diagnostic.discard, .{ .document_capacities = if (hinted) capacities else .{} });
    defer result.deinit(allocator);
    if (result.outcome == .storage_failure and result.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    try expect(result.outcome == .success);
}
test "generalized pool allocation and handoff failures release all storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{true});
}

test "new fixed pools report exact exhaustion and never publish partial output" {
    inline for (.{ false, true }) |links| {
        var pools: dot.FixedDocumentStorage(.{ .statements = 1, .subgraphs = 2, .scoped_edges = if (links) 1 else 0 }) = .{};
        var scratch: Scratch = .{};
        var bag: dot.FixedDiagnosticBag(1) = .{};
        const result = dot.parseBorrowedIn("digraph {a->{}->{}}", .{ .document = pools.storage(), .scratch = scratch.storage() }, bag.sink(), .{});
        try expect(result.outcome == .storage_failure);
        try expect(result.document == null);
        try equal(if (links) dot.diagnostic.Capacity.Resource.scoped_edge_link_pool else .scoped_edge_pool, bag.items()[0].details.capacity.resource);
    }
}

test "validation visits mismatched operators around nested endpoints in lexical order" {
    const input = "graph { a -> { b -> {c -> d} -> e } -> f; {g -> h} -> i }";
    var bag: dot.FixedDiagnosticBag(8) = .{};
    var result = dot.parseAndValidate(std.testing.allocator, input, bag.sink(), .{});
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .success);
    try equal(@as(usize, 7), bag.items().len);
    var previous: usize = 0;
    for (bag.items()) |item| {
        try expect(item.span.start > previous);
        previous = item.span.start;
        try std.testing.expectEqualStrings("->", item.span.slice(input));
    }
}

test "cancellation at every boundary discards suspended endpoint owners and reset reuses pools" {
    var pools: Pools = .{};
    var scratch: Scratch = .{};
    var session = dot.BoundedSession.init(source, .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{});
    defer session.deinit();
    var total: usize = 0;
    while (true) {
        const progress = session.advance(1);
        total += progress.work_used;
        if (progress.outcome != null) break;
    }
    for (0..total) |boundary| {
        session.reset(source, dot.diagnostic.discard, .{});
        for (0..boundary) |_| _ = session.advance(1);
        try expect(session.cancel().outcome == .cancelled);
        try expect(session.result().?.document == null);
    }
    session.reset(source, dot.diagnostic.discard, .{});
    try expect(session.run().outcome == .success);
}
