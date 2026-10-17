//! Public tooling helpers: no internal imports or hidden allocations.
const std = @import("std");
const dot = @import("dot_parser");

test "logical name hashes and equality match decoding across operand boundaries" {
    const spellings = [_][]const u8{
        "a",              "\"a\"",        "\"a\"+\"\"",    "\"\"/**/+\"a\"", "<a>",
        "\"a\"+<>+\"b\"", "\"ab\"",       "<ab>",          "\"a\\\nb\"",     "\"a\\\"b\"",
        "\"a\\nb\"",      "-01.50",       "\"-01.50\"",    "1",              "01",
        "\"\"",           "<>+\"\"",
        "café",
        "\"café\"",
        "\xff",           "\"\xff\"",     "\"e\u{0301}\"",
        "\"é\"",
        "<<B>x</B>>",     "\"<B>x</B>\"",
    };
    for (spellings) |a| for (spellings) |b| {
        var left: [128]u8 = undefined;
        var right: [128]u8 = undefined;
        const expected = std.mem.eql(u8, try dot.identifier.decodeInto(a, &left), try dot.identifier.decodeInto(b, &right));
        try std.testing.expectEqual(expected, try dot.identifier.eql(a, b));
        if (expected) try std.testing.expectEqual(try dot.identifier.hash(a), try dot.identifier.hash(b));
    };
    for ([_][]const u8{ "", "graph", " a", "a ", "a b", "1e3", "\"a", "\"a\"+", "\"a\" /*" }) |bad| {
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.hash(bad));
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.eql("different", bad));
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.eql(bad, "different"));
    }
}

test "document value helpers check ranges and capacity hints allow growth" {
    const source = "graph { a; \"a\"+\"\"; }";
    var parsed = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    const document = &parsed.document.?;
    const a = document.nodeReference(document.nodes[0].reference).?.identifier;
    const b = document.nodeReference(document.nodes[1].reference).?.identifier;
    try std.testing.expect(try document.identifiersEqual(a, b));
    try std.testing.expectEqual(try document.hashIdentifier(a), try document.hashIdentifier(b));
    const bad: dot.Range = .{ .start = @intCast(source.len), .len = 1 };
    try std.testing.expectError(error.InvalidIdentifier, document.hashIdentifier(bad));
    try std.testing.expectError(error.InvalidIdentifier, document.identifiersEqual(a, bad));
    try std.testing.expectError(error.InvalidIdentifier, document.hashIdentifier(.{ .start = 0, .len = 5 }));
    var next = dot.parseBorrowed(std.testing.allocator, "graph { a; b; c; d; a -- b; }", dot.diagnostic.discard, .{ .document_capacities = document.capacities() });
    defer next.deinit(std.testing.allocator);
    try std.testing.expect(next.outcome == .success);
    try std.testing.expectEqual(@as(usize, 4), next.document.?.capacities().nodes);
}

test "capacity counts include comments and partial retained pools without measuring suffixes" {
    const Parser = dot.Profile(.{ .policy = .{ .retention = .{ .comments = true, .partial = true } } });
    const source = "graph { // first\n a; { b; } /* last */ }";
    var parsed = Parser.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    const measured = Parser.measure(std.testing.allocator, source, dot.diagnostic.discard, .{});
    try std.testing.expectEqualDeep(measured.capacities.?, parsed.document.?.capacities());
    try std.testing.expectEqual(@as(u32, 2), parsed.document.?.capacities().comments);
    var partial = Parser.parseBorrowed(std.testing.allocator, "graph { a; { b; c [x= } d; }", dot.diagnostic.discard, .{});
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(.partial, partial.document.?.state);
    try std.testing.expectEqual(partial.document.?.nodes.len, partial.document.?.capacities().nodes);
    try std.testing.expectEqual(partial.document.?.order.len, partial.document.?.capacities().statements);
}

test "default source inspection explains unsupported BOMs without changing raw parsing" {
    const admission = dot.inspectSource("\xff\xfe\x00\x00", null);
    try std.testing.expectEqual(error.UnsupportedEncoding, admission.failure.reason);
    try std.testing.expectEqual(dot.InputEncoding.utf32le, admission.failure.encoding.?);
    try std.testing.expectEqual(dot.Span{ .start = 0, .len = 4 }, admission.failure.span.?);
    try std.testing.expect(std.mem.indexOf(u8, admission.failure.message(), ".source_encodings") != null);
    try std.testing.expectEqual(dot.InputEncoding.utf8, dot.inspectSource("graph { caf\xe9 }", null).selected.encoding);
    const p = try dot.location.textPosition("a😀b", 5, .{});
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 3), p.character);
}
