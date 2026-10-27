//! Public tooling helpers: no internal imports or hidden allocations.
const std = @import("std");
const dot = @import("dot_parser");

test "recognized names are distinct span-sized handles, never raw previews" {
    try std.testing.expect(dot.Name != dot.Span);
    try std.testing.expectEqual(@sizeOf(dot.Span), @sizeOf(dot.Name));
    try std.testing.expectEqual(@alignOf(dot.Span), @alignOf(dot.Name));
    try std.testing.expect(@FieldType(dot.events.TokenPreview, "span") == dot.Span);
    try std.testing.expect(@FieldType(dot.events.Identifier, "name") == dot.Name);
    const input = "graph G { a:p:n -> { b } [k=\"a\"+\"\"]; }";
    var result = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
    defer result.deinit(std.testing.allocator);
    const doc = &result.document.?;
    const graph_name = doc.scope(.root).?.recognizedName().?;
    try std.testing.expectEqualStrings("G", graph_name.slice(input));
    try std.testing.expectEqual(@as(u64, 7), graph_name.endOffset());
    const attr = doc.attributes[0];
    try std.testing.expectEqualStrings("k", attr.keyName().slice(input));
    try std.testing.expectEqual(try dot.identifier.hash("a"), try dot.identifier.fromName(input, attr.valueName()).hash());
    const port = doc.ported_references[0].port;
    try std.testing.expectEqualStrings("p", port.firstName().slice(input));
    try std.testing.expectEqualStrings("n", port.secondName().?.slice(input));
    try std.testing.expectError(error.InvalidIdentifier, dot.identifier.check(input, .{ .start = 0, .len = 5 }));
    try std.testing.expectError(error.InvalidIdentifier, dot.identifier.check(input, .{ .start = std.math.maxInt(u32), .len = 2 }));
    const scoped: dot.events.Edge = .{ .left = .{ .start = 0, .len = 1 }, .right = .{ .start = 2, .len = 1 }, .right_scope = 1, .operator = .directed, .operator_span = .{ .start = 1, .len = 2 } };
    try std.testing.expect(scoped.leftName() != null);
    try std.testing.expect(scoped.rightName() == null);
}

fn encodedNameHash(source: []const u8, name: dot.Name, actual: dot.InputEncoding) !u64 {
    return switch (actual) {
        inline else => |encoding| dot.identifier.ForEncoding(encoding).fromName(source, name).hash(),
    };
}

test "runtime encoding dispatch uses name source metadata rather than the UTF8 default" {
    const P = dot.Profile(.{ .source_encodings = &.{.utf16} });
    const text = "graph G {a}";
    var source: [text.len * 2]u8 = undefined;
    for (text, 0..) |byte, i| std.mem.writeInt(u16, source[i * 2 ..][0..2], byte, .little);
    var parsed = try P.parseBorrowed(std.testing.allocator, &source, dot.diagnostic.discard, .{ .encoding = .utf16le });
    defer parsed.deinit(std.testing.allocator);
    const doc = &parsed.document.?;
    const name = doc.scope(.root).?.recognizedName().?;
    try std.testing.expectEqual(try dot.identifier.hash("G"), try encodedNameHash(doc.source, name, doc.source_info.encoding));
}

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
    try std.testing.expectEqual(@sizeOf([]const u8), @sizeOf(dot.identifier.Parsed));
    for (spellings) |a| for (spellings) |b| {
        var left: [128]u8 = undefined;
        var right: [128]u8 = undefined;
        const expected = std.mem.eql(u8, try dot.identifier.decodeInto(a, &left), try dot.identifier.decodeInto(b, &right));
        try std.testing.expectEqual(expected, try dot.identifier.eql(a, b));
        const parsed_a = dot.identifier.fromName(a, try dot.identifier.check(a, .{ .start = 0, .len = @intCast(a.len) }));
        const parsed_b = dot.identifier.fromName(b, try dot.identifier.check(b, .{ .start = 0, .len = @intCast(b.len) }));
        try std.testing.expectEqual(expected, try parsed_a.eql(parsed_b));
        try std.testing.expectEqual(try dot.identifier.hash(a), try parsed_a.hash());
        if (expected) try std.testing.expectEqual(try dot.identifier.hash(a), try dot.identifier.hash(b));
    };
    for ([_][]const u8{ "", "graph", " a", "a ", "a b", "1e3", "\"a", "\"a\"+", "\"a\" /*" }) |bad| {
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.hash(bad));
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.eql("different", bad));
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.eql(bad, "different"));
    }
}

test "event consumers index parser-recognized names without a document" {
    const Consumer = struct {
        source: []const u8,
        names: [4]dot.identifier.Parsed = undefined,
        count: usize = 0,
        aborts: usize = 0,

        pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            switch (event) {
                .commit_node => |node| {
                    self.names[self.count] = dot.identifier.fromName(self.source, node.value.identifier);
                    self.count += 1;
                },
                else => {},
            }
            return .proceed;
        }
        pub fn onAbort(self: *@This(), _: dot.events.Abort) void {
            self.aborts += 1;
        }
    };
    const source = "graph { a; \"a\"+\"\"; broken[x=]; \"a\"; different; }";
    var consumer: Consumer = .{ .source = source };
    const P = dot.Events(Consumer);
    var scratch: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
    const result = P.parseIn(source, scratch.storage(), &consumer, dot.diagnostic.discard, .{});
    try std.testing.expect(result.outcome == .invalid_syntax);
    try std.testing.expect(consumer.aborts != 0);
    try std.testing.expectEqual(@as(usize, 4), consumer.count);
    for (consumer.names[0..3]) |name| {
        try std.testing.expect(try name.eql(consumer.names[0]));
        try std.testing.expectEqual(try consumer.names[0].hash(), try name.hash());
        try std.testing.expect(!try name.eql(consumer.names[3]));
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
