const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const source = @embedFile("corpus/valid/attributes.dot");
const capacities: dot.DocumentCapacities = .{
    .statements = 7,
    .nodes = 2,
    .edges = 1,
    .attributes = 9,
    .assignments = 1,
    .attribute_statements = 3,
};

fn sameDocument(a: *const dot.Document, b: *const dot.Document) !void {
    try std.testing.expectEqualSlices(dot.StatementId, a.order, b.order);
    try std.testing.expectEqualSlices(dot.NodeStatement, a.nodes, b.nodes);
    try std.testing.expectEqualSlices(dot.EdgeStatement, a.edges, b.edges);
    try std.testing.expectEqualSlices(dot.Attribute, a.attributes, b.attributes);
    try std.testing.expectEqualSlices(dot.Assignment, a.assignments, b.assignments);
    try std.testing.expectEqualSlices(dot.AttributeStatement, a.attribute_statements, b.attribute_statements);
}

test "attributes preserve written order, duplicates, raw IDs and scope across both storage paths" {
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var parsed = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.documentValid());
    const doc = &parsed.document.?;
    var pools: dot.FixedDocumentStorage(capacities) = .{};
    const fixed = dot.parseBorrowedIn(source, .{ .document = pools.storage() }, bag.sink(), .{});
    try expect(fixed.outcome == .success);
    try sameDocument(doc, &fixed.document.?);
    try equal(@as(usize, 7), doc.statementCount());
    try strings("rankdir", doc.text(doc.statementAt(0).?.assignment.key));
    try strings("LR", doc.text(doc.assignments[0].value));
    inline for (.{ dot.AttributeTarget.graph, .node, .edge }, 0..) |target, i| {
        try equal(target, doc.statementAt(i + 1).?.attribute_statement.target);
    }
    const defaults = doc.attributeSlice(doc.attribute_statements[1].attributes).?;
    try equal(@as(usize, 3), defaults.len);
    try strings("red", doc.text(defaults[1].value));
    try strings("blue", doc.text(defaults[2].value));
    try strings("color", doc.text(defaults[1].key));
    try strings("color", doc.text(defaults[2].key));
    try equal(@as(usize, 0), doc.attributeSlice(doc.attribute_statements[2].attributes).?.len);
    const attrs = doc.attributeSlice(doc.nodes[0].attributes).?;
    try equal(@as(usize, 3), attrs.len);
    try strings("-0.5", doc.text(attrs[1].value));
    var output: [16]u8 = undefined;
    try strings("", try doc.decodeIdentifier(attrs[2].key, &output));
    try strings("XY", try doc.decodeIdentifier(doc.attributes[0].value, &output));
    try equal(@as(usize, 2), doc.attributeSlice(doc.edges[0].attributes).?.len);
    // No default propagation or synthesized attributes on the bare node.
    try equal(@as(usize, 0), doc.attributeSlice(doc.nodes[1].attributes).?.len);
    try expect(doc.statement(.{ .assignment = 1 }) == null);
    try expect(doc.statement(.{ .attribute_statement = 3 }) == null);
    try expect(doc.attributeSlice(.{ .start = 10, .len = 0 }) == null);
    try expect(doc.attributeSlice(.{ .start = 9, .len = 1 }) == null);
    try expect(doc.attributeSlice(.{ .start = 0, .len = std.math.maxInt(u32) }) == null);
}

test "empty adjacent lists and all supported identifier forms compose with attributes" {
    inline for (.{
        "graph { a[][]; graph [][]; node []; edge [] }",
        "graph { a [x=1 y=2,z=3;][k=4,] b }",
        "digraph { 1=\"one\"; \"node\" [\"ke\"+\"y\"=-.5]; 1 -> 2 [3=4.] }",
        "graph { a [/* key */x/* eq */=/* value */1 // end\n] }",
    }) |input| {
        var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        try expect(parsed.outcome == .success);
        var pools: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8, .attributes = 16, .assignments = 8, .attribute_statements = 8 }) = .{};
        const fixed = dot.parseBorrowedIn(input, .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
        try expect(fixed.outcome == .success);
        try sameDocument(&parsed.document.?, &fixed.document.?);
    }
}

test "the facade honors hints when only a new pool is requested" {
    inline for ([_]dot.DocumentCapacities{
        .{ .attributes = 2 }, .{ .assignments = 2 }, .{ .attribute_statements = 2 },
    }) |hint| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var parsed = dot.parseBorrowed(failing.allocator(), "graph {}", dot.diagnostic.discard, .{ .document_capacities = hint });
        defer parsed.deinit(failing.allocator());
        try expect(parsed.outcome == .storage_failure);
        try equal(dot.StorageFailure.out_of_memory, parsed.outcome.storage_failure);
    }
}

test "malformed attributes fail without partial documents and with matching typed diagnostics" {
    inline for (.{
        "graph { a [x] }",            "graph { a [x=] }",            "graph { a [=1] }",
        "graph { a [,x=1] }",         "graph { a [x=1,,y=2] }",      "graph { a [;] }",
        "graph { a [x=1;;] }",        "graph { node }",              "graph { a= }",
        "graph { a=1[x=2] }",         "graph { a[x=1] -- b }",       "graph { a[x=node] }",
        "graph { a[x=1 }",            "graph { a[x=1",               "graph { a[x=",
        "graph { a[x",                "graph { a[",                  "graph { a=",
        "graph { a[x=\"unterminated", "graph { a[x=1 /* unfinished",
    }) |input| {
        var a: dot.FixedDiagnosticBag(2) = .{};
        var b: dot.FixedDiagnosticBag(2) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, input, a.sink(), .{});
        defer parsed.deinit(std.testing.allocator);
        var pools: dot.FixedDocumentStorage(.{ .statements = 4, .nodes = 4, .edges = 4, .attributes = 8, .assignments = 4, .attribute_statements = 4 }) = .{};
        const fixed = dot.parseBorrowedIn(input, .{ .document = pools.storage() }, b.sink(), .{});
        try expect(parsed.outcome == .invalid_syntax);
        try expect(fixed.outcome == .invalid_syntax);
        try expect(parsed.document == null and fixed.document == null);
        try std.testing.expectEqualSlices(dot.Diagnostic, a.items(), b.items());
        try equal(@as(usize, 1), a.items().len);
    }
}

test "EOF in a later attribute group points at its own opener" {
    const input = "graph { a[x=1][y=";
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var parsed = dot.parseBorrowed(std.testing.allocator, input, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .invalid_syntax);
    const failure = bag.items()[0];
    try equal(dot.Code.parser_unexpected_end, failure.code);
    try equal(dot.diagnostic.ParseContext.attribute_value, failure.details.unexpected.context);
    try expect(failure.details.unexpected.expected.contains(.identifier));
    try equal(@as(usize, 14), failure.details.unexpected.related.?.span.start.byte_offset);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxedList(bag.items(), 0, .{ .source = input }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "opened") != null);
    var compact = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxedList(bag.items(), 0, .{}, &compact);
    try expect(std.mem.indexOf(u8, compact.buffered(), "attribute value") != null);
}

test "each fixed pool exhaustion has an exact resource and storage is reusable" {
    const Case = struct { input: []const u8, cap: dot.DocumentCapacities, resource: dot.diagnostic.Capacity.Resource };
    inline for ([_]Case{
        .{ .input = "graph { a[x=1] }", .cap = .{ .statements = 1, .nodes = 1 }, .resource = .attribute_pool },
        .{ .input = "graph { a[x=1] }", .cap = .{ .statements = 1, .attributes = 1 }, .resource = .node_pool },
        .{ .input = "graph { a[x=1] }", .cap = .{ .nodes = 1, .attributes = 1 }, .resource = .statement_pool },
        .{ .input = "graph { a--b[x=1] }", .cap = .{ .statements = 1, .attributes = 1 }, .resource = .edge_pool },
        .{ .input = "graph { node[x=1] }", .cap = .{ .statements = 1, .attributes = 1 }, .resource = .attribute_statement_pool },
        .{ .input = "graph { x=1 }", .cap = .{ .statements = 1 }, .resource = .assignment_pool },
        .{ .input = "graph { x=1 }", .cap = .{ .assignments = 1 }, .resource = .statement_pool },
        .{ .input = "graph { node[x=1] }", .cap = .{ .attribute_statements = 1, .attributes = 1 }, .resource = .statement_pool },
    }) |case| {
        var pools: dot.FixedDocumentStorage(case.cap) = .{};
        var bag: dot.FixedDiagnosticBag(1) = .{};
        const failed = dot.parseBorrowedIn(case.input, .{ .document = pools.storage() }, bag.sink(), .{});
        try expect(failed.outcome == .storage_failure);
        try equal(dot.StorageFailure.pool_exhausted, failed.outcome.storage_failure);
        try expect(failed.document == null);
        try equal(case.resource, bag.items()[0].details.capacity.resource);
        try equal(@as(usize, 0), bag.items()[0].details.capacity.limit);
        const reused = dot.parseBorrowedIn("graph {}", .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
        try expect(reused.outcome == .success);
        try equal(@as(usize, 0), reused.document.?.attributes.len);
    }
}

test "attribute budgets include assignments but not empty groups, independently of statements" {
    inline for (.{ @as(usize, 0), 9, 10 }) |limit| {
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, source, bag.sink(), .{ .max_attributes = limit });
        defer parsed.deinit(std.testing.allocator);
        var pools: dot.FixedDocumentStorage(capacities) = .{};
        const fixed = dot.parseBorrowedIn(source, .{ .document = pools.storage() }, dot.diagnostic.discard, .{ .max_attributes = limit });
        try equal(std.meta.activeTag(parsed.outcome), std.meta.activeTag(fixed.outcome));
        if (limit < 10) {
            try expect(parsed.outcome == .resource_exhausted);
            try equal(dot.diagnostic.Capacity.Resource.attributes, bag.items()[0].details.capacity.resource);
            try equal(limit, bag.items()[0].details.capacity.limit);
        } else try expect(parsed.outcome == .success);
    }
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .attribute_statements = 1 }) = .{};
    try expect(dot.parseBorrowedIn("graph { node[][] }", .{ .document = pools.storage() }, dot.diagnostic.discard, .{ .max_attributes = 0 }).outcome == .success);
    try expect(dot.parseBorrowedIn("graph { node[] }", .{ .document = pools.storage() }, dot.diagnostic.discard, .{ .max_statements = 0 }).outcome == .resource_exhausted);
}

test "all attribute corpus prefixes terminate identically without exposing partial storage" {
    for (0..source.len + 1) |length| {
        var parsed = dot.parseBorrowed(std.testing.allocator, source[0..length], dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        var pools: dot.FixedDocumentStorage(capacities) = .{};
        const fixed = dot.parseBorrowedIn(source[0..length], .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
        try equal(std.meta.activeTag(parsed.outcome), std.meta.activeTag(fixed.outcome));
        if (parsed.outcome == .success) {
            try sameDocument(&parsed.document.?, &fixed.document.?);
        } else try expect(parsed.document == null and fixed.document == null);
    }
}

test "capacity hints cover all six pools without allocation during parse or handoff" {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var parsed = dot.parseBorrowed(fba.allocator(), source, dot.diagnostic.discard, .{ .document_capacities = capacities });
    defer parsed.deinit(fba.allocator());
    try expect(parsed.outcome == .success);
    try equal(@as(usize, 7), parsed.document.?.order.len);
    // Exact byte budget: every pool's element alignment is four bytes.
    try equal(@as(usize, 7 * @sizeOf(dot.StatementId) + 2 * @sizeOf(dot.NodeStatement) + @sizeOf(dot.EdgeStatement) + 9 * @sizeOf(dot.Attribute) + @sizeOf(dot.Assignment) + 3 * @sizeOf(dot.AttributeStatement)), fba.end_index);
}

test "attribute errors preserve outcome when diagnostics are rejected or omitted" {
    const Reject = struct {
        fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
            return error.DiagnosticSinkFailure;
        }
    };
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .nodes = 1, .attributes = 2 }) = .{};
    const input = "graph { a[x=1 y=] }";
    const rejected = dot.parseBorrowedIn(input, .{ .document = pools.storage() }, .{ .context = null, .emit_fn = Reject.emit }, .{});
    try expect(rejected.outcome == .invalid_syntax);
    try equal(dot.diagnostic.Delivery.failed, rejected.diagnostic_delivery);
    var bag: dot.FixedDiagnosticBag(0) = .{};
    const omitted = dot.parseBorrowedIn(input, .{ .document = pools.storage() }, bag.sink(), .{});
    try expect(omitted.outcome == .invalid_syntax);
    try equal(@as(usize, 1), bag.omitted);
}

test "fuzz: generated attribute values and duplicate ordering agree across storage paths" {
    try std.testing.fuzz({}, fuzzAttributes, .{});
}

fn fuzzAttributes(_: void, smith: *std.testing.Smith) !void {
    const count = smith.value(u6);
    var input: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    try writer.writeAll("graph { a[]");
    var expected: [63]u8 = undefined;
    for (expected[0..count]) |*value| {
        value.* = smith.value(u8);
        try writer.print("[x={d}]", .{value.*});
    }
    try writer.writeAll(" }");
    const bytes = writer.buffered();
    var parsed = dot.parseBorrowed(std.testing.allocator, bytes, dot.diagnostic.discard, .{ .max_attributes = count });
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    var pools: dot.FixedDocumentStorage(.{ .statements = 1, .nodes = 1, .attributes = 63 }) = .{};
    const fixed = dot.parseBorrowedIn(bytes, .{ .document = pools.storage() }, dot.diagnostic.discard, .{ .max_attributes = count });
    try expect(fixed.outcome == .success);
    try sameDocument(&parsed.document.?, &fixed.document.?);
    const doc = &parsed.document.?;
    try equal(@as(usize, count), doc.attributeSlice(doc.nodes[0].attributes).?.len);
    for (doc.attributes, expected[0..count]) |attribute, value| {
        try strings("x", doc.text(attribute.key));
        try equal(value, try std.fmt.parseInt(u8, doc.text(attribute.value), 10));
    }
}
