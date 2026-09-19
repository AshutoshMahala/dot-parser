//! Byte-oriented identifiers through the public API: spelling, decoding,
//! storage policies, grammar positions and diagnostics.
const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const strings = std.testing.expectEqualStrings;

fn identifier(document: *const dot.Document, range: dot.Range, expected: []const u8) !void {
    try strings(expected, document.text(range));
    var bytes: [64]u8 = undefined;
    try strings(expected, try document.decodeIdentifier(range, &bytes));
    var writer = std.Io.Writer.fixed(&bytes);
    try document.writeIdentifier(range, &writer);
    try strings(expected, writer.buffered());
}

test "non-ASCII identifiers work in every ID position across storage policies" {
    const source =
        \\digraph 名 {
        \\  subgraph 群 {
        \\    café:出口:北 [色=青];
        \\    café:出口 -> 東京:入口 -> 大阪 [説明=経路];
        \\    node [形=箱];
        \\    edge [太さ=細];
        \\    graph [向き=右];
        \\    方角=右;
        \\  }
        \\  subgraph 端 { 終点; } -> café;
        \\}
    ;
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try expect(checked.documentValid());
    const document = &checked.document.?;
    var pools: dot.FixedDocumentStorage(.{
        .statements = 12,
        .nodes = 2,
        .edge_chains = 1,
        .edge_links = 1,
        .scoped_edges = 1,
        .subgraphs = 2,
        .ported_references = 3,
        .attributes = 5,
        .attribute_statements = 3,
        .assignments = 1,
    }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    const fixed = dot.parseBorrowedIn(source, .{ .document = pools.storage(), .scratch = scratch.storage() }, bag.sink(), .{});
    try expect(fixed.outcome == .success);
    try deep(document.*, fixed.document.?);
    try equal(@as(usize, 0), bag.items().len);

    try identifier(document, document.name.?, "名");
    var scopes = document.subgraphs();
    try identifier(document, scopes.next().?.name().?, "群");
    try identifier(document, scopes.next().?.name().?, "端");
    try expect(scopes.next() == null);

    const node = document.nodeReference(document.nodes[0].reference).?;
    try identifier(document, node.identifier, "café");
    try identifier(document, node.port.?.first, "出口");
    try identifier(document, node.port.?.second.?, "北");
    try identifier(document, document.nodeReference(document.nodes[1].reference).?.identifier, "終点");
    var edges = document.edgeIterator();
    const first = edges.next().?;
    try identifier(document, document.nodeReference(first.left.node).?.identifier, "café");
    const right = document.nodeReference(first.right.node).?;
    try identifier(document, right.identifier, "東京");
    try identifier(document, right.port.?.first, "入口");
    try identifier(document, document.nodeReference(edges.next().?.right.node).?.identifier, "大阪");
    const last = edges.next().?;
    try identifier(document, document.scope(last.left.subgraph).?.name().?, "端");
    try identifier(document, document.nodeReference(last.right.node).?.identifier, "café");
    try expect(edges.next() == null);

    const pairs = [_][2][]const u8{ .{ "色", "青" }, .{ "説明", "経路" }, .{ "形", "箱" }, .{ "太さ", "細" }, .{ "向き", "右" } };
    try equal(pairs.len, document.attributes.len);
    for (document.attributes, pairs) |attribute, pair| {
        try identifier(document, attribute.key, pair[0]);
        try identifier(document, attribute.value, pair[1]);
    }
    try identifier(document, document.assignments[0].key, "方角");
    try identifier(document, document.assignments[0].value, "右");
}

test "bare identifiers preserve invalid UTF-8 normalization differences and interior BOM bytes" {
    const source = "\xEF\xBB\xBFgraph \xEF\xBB\xBFgraph { graphé; \x80\xff; caf\xe9; \xc0\xaf; é; e\xcc\x81; \xEF\xBB\xBF; \xc3; \xEF\xBB; }";
    const names = [_][]const u8{ "graphé", "\x80\xff", "caf\xe9", "\xc0\xaf", "é", "e\xcc\x81", "\xEF\xBB\xBF", "\xc3", "\xEF\xBB" };
    var pools: dot.FixedDocumentStorage(.{ .statements = names.len, .nodes = names.len }) = .{};
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const parsed = dot.parseBorrowedIn(source, .{ .document = pools.storage() }, bag.sink(), .{});
    try expect(parsed.outcome == .success);
    const document = &parsed.document.?;
    try equal(@as(u32, 3), document.keyword.start);
    try identifier(document, document.name.?, "\xEF\xBB\xBFgraph");
    try equal(names.len, document.nodes.len);
    for (document.nodes, names) |node, name| try identifier(document, document.nodeReference(node.reference).?.identifier, name);
    try equal(@as(usize, 0), bag.items().len);
}

test "diagnostics after non-ASCII identifiers retain byte positions and safe excerpts" {
    const source = "graph {\r\n  café -> 東京;\r\n}";
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try expect(checked.outcome == .success);
    try expect(!checked.documentValid());
    const failure = bag.items()[0];
    try equal(dot.Code.validation_operator_mismatch, failure.code);
    try equal(@as(u32, 17), failure.span.start);
    const position = failure.span.locate(source);
    try equal(@as(usize, 2), position.line);
    try equal(@as(usize, 9), position.byte_column);
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try dot.console.renderBoxed(failure, 1, .{ .source = source, .style = .ascii }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "caf\\xC3\\xA9") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "^^ expected '--'") != null);

    // Malformed bytes after an accepted ID are still errors at their own span.
    const invalid = "digraph { café\x00; 東京 }";
    bag = .{};
    var parsed = dot.parseBorrowed(std.testing.allocator, invalid, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .invalid_syntax);
    try expect(parsed.document == null);
    try equal(dot.Code.syntax_invalid_byte, bag.items()[0].code);
    try equal(@as(u32, 15), bag.items()[0].span.start);
    try equal(@as(u8, 0), bag.items()[0].details.invalid_byte);
}
