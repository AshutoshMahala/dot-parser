//! `measure` / `measureIn` report exactly what a retained parse stores, and
//! `rootStatementCount` separates root statements from nested ones.

const std = @import("std");
const dot = @import("dot_parser");

const sources = [_][]const u8{
    "graph { }",
    "digraph G { a; b; a -> b; }",
    "graph { a -- b -- c -- d; e -- f [x=1] [y=2]; }",
    "digraph { a:p:n -> b:q; c:s -> d -> e:w:e; }",
    "digraph { subgraph s { a -> b; subgraph { c } } d; }",
    "digraph { a -> { b c } -> d; { e } -> f; g -> subgraph h { i -> j }; }",
    "digraph { a -> { b -> { c } } -> d [k=v]; subgraph s { e -> f -> g } }",
    "digraph { rankdir = LR; node [shape=box, color=red]; edge [w=1]; graph [pad=1]; a [x=1;y=2] }",
    "digraph { a -> b -> c [x=1]; d -> e; { f g } -> { h } -> i -> j; }",
    "graph { { a -- b } { c } subgraph { d -- { e -- f } } }",
    @embedFile("corpus/valid/attributes.dot"),
    @embedFile("corpus/valid/nested_subgraphs.dot"),
    @embedFile("corpus/valid/edge_chain.dot"),
    @embedFile("corpus/valid/mixed.dot"),
    @embedFile("corpus/valid/non_ascii_identifiers.dot"),
};

fn poolCounts(document: *const dot.Document) dot.DocumentCapacities {
    return .{
        .statements = document.order.len,
        .nodes = document.nodes.len,
        .edge_chains = document.edge_chains.len,
        .scoped_edges = document.scoped_edges.len,
        .scoped_edge_links = document.scoped_edge_links.len,
        .edge_links = document.edge_links.len,
        .ported_references = document.ported_references.len,
        .subgraphs = document.subgraph_records.len,
        .edges = document.edges.len,
        .attributes = document.attributes.len,
        .assignments = document.assignments.len,
        .attribute_statements = document.attribute_statements.len,
    };
}

test "measure reports exactly the pool sizes a retained parse uses" {
    const allocator = std.testing.allocator;
    for (sources) |source| {
        errdefer std.debug.print("source: {s}\n", .{source});
        var bag: dot.FixedDiagnosticBag(4) = .{};
        const measured = dot.measure(allocator, source, bag.sink(), .{});
        try std.testing.expect(measured.outcome == .success);
        try std.testing.expectEqual(@as(usize, 0), bag.items().len);

        var parsed = dot.parseBorrowed(allocator, source, bag.sink(), .{});
        defer parsed.deinit(allocator);
        try std.testing.expect(parsed.outcome == .success);
        try std.testing.expectEqualDeep(poolCounts(&parsed.document.?), measured.capacities.?);

        // The hint makes the retained parse allocation-exact: no growth.
        var hinted = dot.parseBorrowed(allocator, source, bag.sink(), .{ .document_capacities = measured.capacities.? });
        defer hinted.deinit(allocator);
        try std.testing.expect(hinted.outcome == .success);
    }
}

test "measureIn sizes fixed pools that then hold the document exactly" {
    const allocator = std.testing.allocator;
    for (sources) |source| {
        errdefer std.debug.print("source: {s}\n", .{source});
        var frames: dot.FixedParseScratch(.{ .nesting = 8 }) = .{};
        const measured = dot.measureIn(source, frames.storage(), dot.diagnostic.discard, .{});
        try std.testing.expect(measured.outcome == .success);
        const c = measured.capacities.?;

        const storage: dot.DocumentStorage = .{
            .statement_ids = try allocator.alloc(dot.StatementId, c.statements),
            .nodes = try allocator.alloc(dot.NodeStatement, c.nodes),
            .edge_chains = try allocator.alloc(dot.EdgeChainStatement, c.edge_chains),
            .scoped_edges = try allocator.alloc(dot.ScopedEdgeStatement, c.scoped_edges),
            .scoped_edge_links = try allocator.alloc(dot.ScopedEdgeLink, c.scoped_edge_links),
            .edge_links = try allocator.alloc(dot.EdgeLink, c.edge_links),
            .ported_references = try allocator.alloc(dot.PortedReference, c.ported_references),
            .subgraphs = try allocator.alloc(dot.Subgraph, c.subgraphs),
            .edges = try allocator.alloc(dot.EdgeStatement, c.edges),
            .attributes = try allocator.alloc(dot.Attribute, c.attributes),
            .assignments = try allocator.alloc(dot.Assignment, c.assignments),
            .attribute_statements = try allocator.alloc(dot.AttributeStatement, c.attribute_statements),
        };
        defer {
            allocator.free(storage.statement_ids);
            allocator.free(storage.nodes);
            allocator.free(storage.edge_chains);
            allocator.free(storage.scoped_edges);
            allocator.free(storage.scoped_edge_links);
            allocator.free(storage.edge_links);
            allocator.free(storage.ported_references);
            allocator.free(storage.subgraphs);
            allocator.free(storage.edges);
            allocator.free(storage.attributes);
            allocator.free(storage.assignments);
            allocator.free(storage.attribute_statements);
        }
        const parsed = dot.parseBorrowedIn(source, .{ .document = storage, .scratch = frames.storage() }, dot.diagnostic.discard, .{});
        try std.testing.expect(parsed.outcome == .success);
        try std.testing.expectEqualDeep(c, poolCounts(&parsed.document.?));
    }
}

test "measure reports failures the same way as parsing, with no capacities" {
    var bag: dot.FixedDiagnosticBag(4) = .{};
    const invalid = dot.measure(std.testing.allocator, "digraph { a -> ; }", bag.sink(), .{});
    try std.testing.expect(invalid.outcome == .invalid_syntax);
    try std.testing.expect(invalid.capacities == null);
    try std.testing.expectEqual(dot.Code.syntax_unexpected_token, bag.items()[0].code);

    const limited = dot.measure(std.testing.allocator, "digraph { a; b; c; }", dot.diagnostic.discard, .{ .max_statements = 2 });
    try std.testing.expect(limited.outcome == .resource_exhausted);

    // Nesting scratch is the only storage `measureIn` can run out of.
    var frames: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    const deep = dot.measureIn("digraph { subgraph a { subgraph b { c } } }", frames.storage(), dot.diagnostic.discard, .{});
    try std.testing.expect(deep.outcome == .storage_failure);
    try std.testing.expectEqual(dot.StorageFailure.pool_exhausted, deep.outcome.storage_failure);

    // A flat document needs no scratch at all.
    const flat = dot.measureIn("digraph { a -> b; }", .{}, dot.diagnostic.discard, .{});
    try std.testing.expectEqual(@as(usize, 1), flat.capacities.?.edges);
}

test "statementCount counts every scope; rootStatementCount only the root" {
    const allocator = std.testing.allocator;
    const source = "digraph { subgraph s { a; b; subgraph { c } } d; a -> { e f } g -> h }";
    var parsed = dot.parseBorrowed(allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(allocator);
    const document = &parsed.document.?;
    // s, a, b, anonymous, c, d, a -> {e f}, e, f, g -> h
    try std.testing.expectEqual(@as(usize, 10), document.statementCount());
    // s, d, a -> {e f}, g -> h
    try std.testing.expectEqual(@as(usize, 4), document.rootStatementCount());

    var flat = dot.parseBorrowed(allocator, "graph { a; b -- c; }", dot.diagnostic.discard, .{});
    defer flat.deinit(allocator);
    try std.testing.expectEqual(flat.document.?.statementCount(), flat.document.?.rootStatementCount());
}
