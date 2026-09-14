const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const strings = std.testing.expectEqualStrings;
const capacities: dot.DocumentCapacities = .{ .statements = 16, .nodes = 16, .edges = 16, .edge_chains = 8, .edge_links = 32, .ported_references = 40, .attributes = 16, .assignments = 8, .attribute_statements = 8 };
const Storage = dot.FixedDocumentStorage(capacities);
const source = "digraph {a; a:n; a:out:e->b:in->c:other:unknown[headport=x tailport=y]; a:out->b; a:out}";

test "ports preserve source occurrences and chain endpoints without interpreting attachments" {
    var parsed = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    const doc = &parsed.document.?;
    var pools: Storage = .{};
    const fixed = dot.parseBorrowedIn(source, .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
    try deep(doc.*, fixed.document.?);
    try equal(@as(usize, 6), doc.ported_references.len);
    try equal(@as(usize, 3), doc.nodes.len);
    try equal(@as(usize, 5), doc.statementCount());
    try expect(doc.nodeReference(doc.nodes[0].reference).?.port == null);
    try strings("n", doc.text(doc.nodeReference(doc.nodes[1].reference).?.port.?.first));
    var edges = doc.edgeIterator();
    const first = edges.next().?;
    const second = edges.next().?;
    try deep(first.right, second.left);
    try strings("a", doc.text(doc.nodeReference(first.left.node).?.identifier));
    try strings("out", doc.text(doc.nodeReference(first.left.node).?.port.?.first));
    try strings("e", doc.text(doc.nodeReference(first.left.node).?.port.?.second.?));
    try strings("unknown", doc.text(doc.nodeReference(second.right.node).?.port.?.second.?));
    try equal(@as(usize, 2), doc.attributeSlice(second.attributes).?.len);
    const third = edges.next().?;
    try expect(doc.nodeReference(third.right.node).?.port == null);
    try expect(!std.meta.eql(third.left.node, doc.nodes[2].reference)); // Repeated spelling, separate occurrence.
    try expect(edges.next() == null);
}

test "port components accept existing identifier forms and trivia without classifying compass names" {
    const input = "graph {\"a:b\" : /*x*/ \"\" : \"n\"+\"e\"; -.5:0; a:n; a:made_up; a:\"graph\"; a:graphical}";
    var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    const doc = &parsed.document.?;
    const ref = doc.nodeReference(doc.nodes[0].reference).?;
    var bytes: [32]u8 = undefined;
    try strings("a:b", try doc.decodeIdentifier(ref.identifier, &bytes));
    try strings("", try doc.decodeIdentifier(ref.port.?.first, &bytes));
    try strings("ne", try doc.decodeIdentifier(ref.port.?.second.?, &bytes));
    try strings("0", doc.text(doc.nodeReference(doc.nodes[1].reference).?.port.?.first));
    for (doc.nodes[1..]) |node| try expect(doc.nodeReference(node.reference).?.port.?.second == null);
}

test "malformed ports and ports outside node references are syntax errors" {
    inline for (.{ "graph {a:}", "graph {a:p:}", "graph {a:p:q:r}", "graph {a--b:}", "graph {a--b--c:p:q:r}", "graph {a:p=v}", "graph {a=v:p}", "graph g:p {}", "graph {a[k:p=v]}", "graph {a[k=v:p]}", "graph {a:graph}", "graph {a:p:" }) |input| {
        var a: dot.FixedDiagnosticBag(2) = .{};
        var b: dot.FixedDiagnosticBag(2) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, input, a.sink(), .{});
        defer parsed.deinit(std.testing.allocator);
        var pools: Storage = .{};
        const fixed = dot.parseBorrowedIn(input, .{ .document = pools.storage() }, b.sink(), .{});
        try expect(parsed.outcome == .invalid_syntax and fixed.outcome == .invalid_syntax);
        try expect(parsed.document == null and fixed.document == null);
        try deep(a.items(), b.items());
    }
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var pools: Storage = .{};
    _ = dot.parseBorrowedIn("graph {a:p:", .{ .document = pools.storage() }, bag.sink(), .{});
    try equal(dot.diagnostic.ParseContext.port_component, bag.items()[0].details.unexpected.context);
    try equal(@as(usize, 10), bag.items()[0].details.unexpected.related.?.span.start.byte_offset);
    try equal(dot.diagnostic.Related.Role.suffix_started_here, bag.items()[0].details.unexpected.related.?.role);
    var bytes: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try dot.console.render(bag.items()[0], &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "port suffix component") != null);
}

test "exact port hints reserve only retained pool payload" {
    var bytes: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&bytes);
    var parsed = dot.parseBorrowed(fba.allocator(), "graph {a:p--b:q}", dot.diagnostic.discard, .{ .document_capacities = .{ .statements = 1, .edges = 1, .ported_references = 2 } });
    defer parsed.deinit(fba.allocator());
    try expect(parsed.outcome == .success);
    try equal(@as(usize, 8 + 36 + 2 * 28), fba.end_index);
}

test "fuzz: mixed inline and pooled chains preserve every endpoint across storage policies" {
    try std.testing.fuzz({}, fuzzPorts, .{});
}

fn fuzzPorts(_: void, smith: *std.testing.Smith) !void {
    const count: usize = @as(usize, smith.value(u5)) + 2;
    var qualified: [33]bool = undefined;
    var second: [33]bool = undefined;
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("digraph {");
    for (0..count) |i| {
        if (i != 0) try writer.writeAll("->");
        try writer.print("{d}", .{i});
        qualified[i] = smith.value(bool);
        second[i] = qualified[i] and smith.value(bool);
        if (qualified[i]) try writer.writeAll(":\"p\"/**/+\"ort\"");
        if (second[i]) try writer.writeAll(":e");
    }
    try writer.writeAll("}");
    const input = writer.buffered();
    var parsed = dot.parseBorrowed(std.testing.allocator, input, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    var pools: Storage = .{};
    const fixed = dot.parseBorrowedIn(input, .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
    try deep(parsed.document, fixed.document);
    const doc = &parsed.document.?;
    var edges = doc.edgeIterator();
    for (0..count - 1) |i| {
        const edge = edges.next().?;
        inline for (.{ "left", "right" }, 0..) |field, offset| {
            const index = i + offset;
            const view = doc.nodeReference(@field(edge, field).node).?;
            try equal(index, try std.fmt.parseInt(usize, doc.text(view.identifier), 10));
            try equal(qualified[index], view.port != null);
            if (view.port) |port| {
                try equal(second[index], port.second != null);
                var output: [8]u8 = undefined;
                try strings("port", try doc.decodeIdentifier(port.first, &output));
            }
        }
    }
    try expect(edges.next() == null);
}

test "ported pool exhaustion is typed and reset discards incomplete occurrences" {
    var pools: dot.FixedDocumentStorage(.{ .statements = 2, .nodes = 2, .edges = 1, .ported_references = 1 }) = .{};
    var bag: dot.FixedDiagnosticBag(2) = .{};
    var session = dot.BoundedSession.init("graph {a:p--b:q}", .{ .document = pools.storage() }, bag.sink(), .{});
    defer session.deinit();
    const failed = session.run();
    try expect(failed.outcome == .storage_failure and failed.document == null);
    try equal(dot.diagnostic.Capacity.Resource.ported_reference_pool, bag.items()[0].details.capacity.resource);
    session.reset("graph {c:r}", dot.diagnostic.discard, .{});
    const doc = session.run().document.?;
    try equal(@as(usize, 1), doc.ported_references.len);
    try strings("c", doc.text(doc.nodeReference(doc.nodes[0].reference).?.identifier));
    var empty: dot.FixedDocumentStorage(.{ .statements = 1, .nodes = 1 }) = .{};
    const bare = dot.parseBorrowedIn("graph {a}", .{ .document = empty.storage() }, dot.diagnostic.discard, .{});
    try expect(bare.outcome == .success);
    const qualified = dot.parseBorrowedIn("graph {a:p}", .{ .document = empty.storage() }, dot.diagnostic.discard, .{});
    try expect(qualified.outcome == .storage_failure);
}

fn allocations(allocator: std.mem.Allocator, hinted: bool) !void {
    var result = dot.parseBorrowed(allocator, source, dot.diagnostic.discard, .{ .document_capacities = if (hinted) capacities else .{} });
    defer result.deinit(allocator);
    if (result.outcome == .storage_failure and result.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    try expect(result.outcome == .success);
}

test "ported allocation and ownership transfer failures release all pools" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{true});
}

test "port storage remains compact and accessors reject out of bounds handles" {
    try equal(@as(usize, 8), @sizeOf(dot.NodeReference));
    try equal(@as(usize, 28), @sizeOf(dot.PortedReference));
    try equal(@as(usize, 16), @sizeOf(dot.NodeStatement));
    try equal(@as(usize, 36), @sizeOf(dot.EdgeStatement));
    try equal(@as(usize, 20), @sizeOf(dot.EdgeLink));
    try expect(dot.NodeReference.fromRange(.{ .start = 0, .len = 0 }) == null);
    var pools: Storage = .{};
    const doc = dot.parseBorrowedIn("graph {\"\"; a:p}", .{ .document = pools.storage() }, dot.diagnostic.discard, .{}).document.?;
    try expect(doc.nodeReference(doc.nodes[0].reference).?.port == null);
    try expect(doc.nodeReference(.{ .index_or_start = 1, .raw_len = 0 }) == null);
    try expect(doc.nodeReference(.{ .index_or_start = std.math.maxInt(u32), .raw_len = 1 }) == null);
    try expect(doc.nodeReference(.{ .index_or_start = 0, .raw_len = std.math.maxInt(u32) }) == null);
    const Sized = dot.FixedDocumentStorage(.{ .ported_references = 3 });
    try equal(@as(usize, 3 * 28), Sized.byte_size);
}

test "ports do not consume statement or attribute budgets and run in all execution profiles" {
    inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        var pools: Storage = .{};
        var session = dot.FixedSession(.{ .metering = metering, .cancellation = cancellation }).init("digraph {a:p->b:q->c:r[k=v]}", .{ .document = pools.storage() }, dot.diagnostic.discard, .{ .max_statements = 1, .max_attributes = 1 });
        defer session.deinit();
        const result = session.run();
        try expect(result.outcome == .success);
        try equal(@as(usize, 3), result.document.?.ported_references.len);
    };
}

test "every source prefix agrees across allocator and fixed port storage" {
    for (0..source.len + 1) |end| {
        var a: dot.FixedDiagnosticBag(2) = .{};
        var b: dot.FixedDiagnosticBag(2) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, source[0..end], a.sink(), .{});
        defer parsed.deinit(std.testing.allocator);
        var pools: Storage = .{};
        const fixed = dot.parseBorrowedIn(source[0..end], .{ .document = pools.storage() }, b.sink(), .{});
        try deep(parsed.outcome, fixed.outcome);
        try deep(parsed.document, fixed.document);
        try deep(a.items(), b.items());
    }
}

test "long qualified chains parse iteratively in ordinary and bounded drivers" {
    var bytes: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll("digraph {a:p");
    for (0..2000) |_| try writer.writeAll("->a:p");
    try writer.writeAll("}");
    const Pools = dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 1999, .ported_references = 2001 });
    var ordinary_storage: Pools = .{};
    const ordinary = dot.parseBorrowedIn(writer.buffered(), .{ .document = ordinary_storage.storage() }, dot.diagnostic.discard, .{});
    try expect(ordinary.outcome == .success);
    var bounded_storage: Pools = .{};
    var session = dot.BoundedSession.init(writer.buffered(), .{ .document = bounded_storage.storage() }, dot.diagnostic.discard, .{});
    defer session.deinit();
    while (true) {
        const progress = session.advance(17);
        try expect(progress.work_used <= 17);
        if (progress.outcome != null) break;
        try expect(session.result() == null);
    }
    try deep(ordinary, session.result().?);
    try equal(@as(usize, 2001), ordinary.document.?.ported_references.len);
}
