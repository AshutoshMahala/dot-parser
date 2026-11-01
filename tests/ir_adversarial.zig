const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const eq = std.testing.expectEqualDeep;
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

test "adversarial symbolic product is bounded before expansion or adjacency publication" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {{");
    for (0..1024) |i| try source.writer.print("a{d};", .{i});
    try source.writer.writeAll("}->{");
    for (0..1024) |i| try source.writer.print("b{d};", .{i});
    try source.writer.writeAll("}}");
    var parsed = try IR.parse(a, source.written(), .{});
    defer parsed.deinit();
    const graph = parsed.ir().?;
    try eq(@as(usize, 1), graph.connections.len);
    try eq(@as(usize, 2048), graph.nodes.len);
    const limits: dot.ir.Limits = .{ .max_pairs = 100, .max_work = 1_000_000, .max_bytes = 128 * 1024 };
    inline for (.{ .none, .forward, .backward, .all }) |adjacency| {
        try std.testing.expectError(error.PairLimit, graph.materialize(.{ .attributes = false, .adjacency = adjacency, .limits = limits }));
        var session = try graph.materializationSession(.{ .attributes = false, .adjacency = adjacency, .limits = limits });
        defer session.deinit();
        const outcome = session.run();
        try eq(error.PairLimit, outcome.outcome.?.failure);
        try expect(outcome.total_work <= limits.max_work);
        try expect(session.peakBytes() <= limits.max_bytes);
        try std.testing.expectError(error.PairLimit, session.takeResult());
        try eq(@as(u32, 0), session.advance(1).work_used);
    }
}

test "adversarial repeated loops preserve occurrence counts and bounded strict folding" {
    inline for (.{ false, true }) |strict| {
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        try source.writer.print("{s}digraph {{", .{if (strict) "strict " else ""});
        for (0..2048) |i| try source.writer.print("a->a[label=\"{d}\"];", .{i});
        try source.writer.writeAll("}");
        var parsed = try IR.parse(a, source.written(), .{});
        defer parsed.deinit();
        const graph = parsed.ir().?;
        var materialized = try graph.materialize(.{ .adjacency = .all });
        defer materialized.deinit();
        const count: u32 = if (strict) 1 else 2048;
        try eq(@as(usize, count), materialized.edges.len);
        var nodes = materialized.nodeIterator();
        const node = nodes.next().?;
        try expect(nodes.next() == null);
        inline for (.{ .all, .incoming, .outgoing, .forward, .backward }) |direction| {
            try eq(count, node.edgeCount(.{ .direction = direction }));
            var entries = node.edges(.{ .direction = direction });
            var n: u32 = 0;
            while (entries.next()) |entry| {
                try eq(node.id, entry.neighbor().id);
                try expect(entry.directions().incoming and entry.directions().outgoing);
                n += 1;
                try expect(n <= count);
            }
            try eq(count, n);
        }
        try eq(@as(u32, 0), node.edgeCount(.{ .direction = .undirected }));
        if (strict) {
            var edges = materialized.edgeIterator();
            var buffer: [32]u8 = undefined;
            var out = std.Io.Writer.fixed(&buffer);
            try out.print("{f}", .{edges.next().?.attribute("label").?.value()});
            try std.testing.expectEqualStrings("2047", out.buffered());
        }
    }
}

test "adversarial nesting limit retains a bounded prefix without recursive IR traversal" {
    const Parser = dot.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 64 }, .retention = .{ .partial = true } } });
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {a;");
    for (0..16384) |_| try source.writer.writeAll("{a;");
    for (0..16384) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("}");
    var parsed = Parser.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(!parsed.documentValid());
    const document = &parsed.document.?;
    try expect(!document.scopeComplete());
    var graph = try IR.lowerPartial(a, document, .{ .interpretation = Parser.interpretation(document, .{}) });
    defer graph.deinit();
    try eq(.partial, graph.state());
    try expect(graph.nodeCount() <= 1);
    try expect(graph.scopeCount() <= 65);
    var result = try graph.materialize(.{ .adjacency = .all });
    defer result.deinit();
    try eq(@as(usize, 0), result.edges.len);
}
