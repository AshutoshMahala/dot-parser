const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const Pools = dot.FixedDocumentStorage(.{
    .statements = 64,
    .subgraphs = 32,
    .nodes = 16,
    .edges = 16,
    .edge_chains = 8,
    .edge_links = 32,
    .ported_references = 16,
    .attributes = 32,
    .assignments = 16,
    .attribute_statements = 16,
});
const Scratch = dot.FixedParseScratch(.{ .nesting = 16 });
fn count(iterator: anytype) usize {
    var it = iterator;
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}
fn allocated(allocator: std.mem.Allocator, hinted: bool) !void {
    var result = dot.parseBorrowed(allocator, "digraph { subgraph s { a:p->b->c[x=1] {node[y=2] z=3} } subgraph s {} }", dot.diagnostic.discard, .{
        .document_capacities = if (hinted) .{ .statements = 7, .subgraphs = 3, .edge_chains = 1, .edge_links = 1, .ported_references = 1, .attributes = 2, .attribute_statements = 1, .assignments = 1 } else .{},
    });
    defer result.deinit(allocator);
    if (result.outcome == .storage_failure and result.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    try expect(result.outcome == .success);
}
test "subgraph allocation and ownership transfer failures release all pools and scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocated, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocated, .{true});
}
test "scopes retain occurrences and source order with direct and recursive views" {
    const source = "digraph G { x subgraph s { a:p->b->c[k=v] {c->d} rank=same } subgraph s {} subgraph {} subgraph \"\" {} subgraph -1 {} y }";
    var result = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .success);
    const doc = &result.document.?;
    const root = doc.scope(.root).?;
    try expect(root.parent() == null);
    try std.testing.expectEqualStrings("G", doc.text(root.name().?));
    try equal(@as(usize, 6), count(doc.subgraphs()));
    try equal(@as(usize, 7), count(root.statements(.direct)));
    try equal(@as(usize, 11), count(root.statements(.recursive)));
    try equal(@as(usize, 5), count(root.subgraphs(.direct)));
    try equal(@as(usize, 6), count(root.subgraphs(.recursive)));
    try equal(@as(usize, 0), count(root.edges(.direct)));
    try equal(@as(usize, 3), count(root.edges(.recursive)));
    try equal(@as(usize, 7), count(root.nodeReferences(.recursive)));
    try expect(doc.scope(@enumFromInt(7)) == null);
    var scopes = doc.subgraphs();
    const first = scopes.next().?;
    try equal(dot.ScopeId.root, first.parent().?);
    try std.testing.expectEqualStrings("subgraph s { a:p->b->c[k=v] {c->d} rank=same }", doc.text(first.sourceRange().?));
    try equal(@as(usize, 3), count(first.statements(.direct)));
    try equal(@as(usize, 4), count(first.statements(.recursive)));
    try equal(@as(usize, 2), count(first.edges(.direct)));
    try equal(@as(usize, 3), count(first.nodeReferences(.direct)));
    const child = scopes.next().?;
    try equal(first.id, child.parent().?);
    try expect(child.name() == null);
    const repeated = scopes.next().?;
    try expect(repeated.id != first.id);
    try std.testing.expectEqualStrings("s", doc.text(repeated.name().?));
    try equal(@as(usize, 0), count(repeated.statements(.direct)));
    try expect(scopes.next().?.name() == null);
    try std.testing.expectEqualStrings("\"\"", doc.text(scopes.next().?.name().?));
    try std.testing.expectEqualStrings("-1", doc.text(scopes.next().?.name().?));
    const expected_scopes = [_]u32{ 0, 0, 1, 1, 2, 1, 0, 0, 0, 0, 0 };
    var statements = doc.statements();
    for (expected_scopes) |id| {
        const item = statements.nextScoped().?;
        try equal(id, @intFromEnum(item.scope));
        try deep(doc.statement(item.id).?, item.statement);
    }
    try expect(statements.nextScoped() == null);
    try equal(@as(usize, 36), @sizeOf(dot.Subgraph));
    try equal(@as(usize, 8), @sizeOf(dot.StatementId));
    try expect(dot.FixedParseScratch(.{ .nesting = 1 }).byte_size > 32);
}
test "all input prefixes agree across allocated fixed and one-credit parsing" {
    const source = "digraph { subgraph \"s\"+\"t\" { a:p->b->c[x=1] {node[y=2] z=3} } {q} }";
    for (0..source.len + 1) |end| {
        var a: dot.FixedDiagnosticBag(2) = .{};
        var b: dot.FixedDiagnosticBag(2) = .{};
        var c: dot.FixedDiagnosticBag(2) = .{};
        var owned = dot.parseBorrowed(std.testing.allocator, source[0..end], a.sink(), .{});
        defer owned.deinit(std.testing.allocator);
        var pools: Pools = .{};
        var scratch: Scratch = .{};
        const fixed = dot.parseBorrowedIn(source[0..end], .{ .document = pools.storage(), .scratch = scratch.storage() }, b.sink(), .{});
        var session_pools: Pools = .{};
        var session_scratch: Scratch = .{};
        var session = dot.BoundedSession.init(source[0..end], .{ .document = session_pools.storage(), .scratch = session_scratch.storage() }, c.sink(), .{});
        defer session.deinit();
        var calls: usize = 0;
        while (session.advance(1).outcome == null) : (calls += 1) try expect(calls < 16 * source.len);
        try deep(owned.document, fixed.document);
        try deep(owned.outcome, fixed.outcome);
        try deep(fixed, session.result().?);
        try deep(a.items(), b.items());
        try deep(b.items(), c.items());
    }
}
test "nesting policy scratch capacity and retained subgraph capacity are distinct" {
    var pools: Pools = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    var bag: dot.FixedDiagnosticBag(2) = .{};
    const source = "graph {{ {a} }}";
    const memory: dot.ParseMemory = .{ .document = pools.storage(), .scratch = scratch.storage() };
    const policy = dot.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 1 } } }).parseBorrowedIn(source, memory, bag.sink(), .{});
    try expect(policy.outcome == .resource_exhausted);
    try equal(dot.diagnostic.Capacity.Resource.nesting_depth, bag.items()[0].details.capacity.resource);
    bag = .{};
    const capacity = dot.parseBorrowedIn(source, memory, bag.sink(), .{});
    try expect(capacity.outcome == .storage_failure);
    try equal(dot.diagnostic.Capacity.Resource.nesting_frames, bag.items()[0].details.capacity.resource);
    try expect(capacity.document == null);
    bag = .{};
    var no_scopes: dot.FixedDocumentStorage(.{ .statements = 1 }) = .{};
    const retained = dot.parseBorrowedIn("graph {{}}", .{ .document = no_scopes.storage(), .scratch = scratch.storage() }, bag.sink(), .{});
    try expect(retained.outcome == .storage_failure);
    try equal(dot.diagnostic.Capacity.Resource.subgraph_pool, bag.items()[0].details.capacity.resource);
    try expect(dot.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 0 } } }).parseBorrowedIn("graph {}", .{ .document = pools.storage() }, dot.diagnostic.discard, .{}).outcome == .success);
    try expect(dot.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 0 } } }).parseBorrowedIn("graph {{}}", memory, dot.diagnostic.discard, .{}).outcome == .resource_exhausted);
    try expect(dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 1 } } }).parseBorrowedIn("graph {{a}}", memory, dot.diagnostic.discard, .{}).outcome == .resource_exhausted);
    try expect(dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 2 } } }).parseBorrowedIn("graph {{a}}", memory, dot.diagnostic.discard, .{}).outcome == .success);
}
test "many sibling scopes reuse one scratch frame" {
    var bytes: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writer.writeAll("graph {");
    for (0..1000) |_| try writer.writeAll("{}");
    try writer.writeAll("}");
    var pools: dot.FixedDocumentStorage(.{ .statements = 1000, .subgraphs = 1000 }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    const result = dot.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 1 } } }).parseBorrowedIn(writer.buffered(), .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{});
    try expect(result.outcome == .success);
    try equal(@as(usize, 1000), result.document.?.subgraph_records.len);
}
test "deep nesting uses explicit frames and one-credit execution without recursion" {
    const depth = 2048;
    var bytes: [2 * depth + 16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writer.writeAll("graph {");
    for (0..depth) |_| try writer.writeAll("{");
    try writer.writeAll("a");
    for (0..depth) |_| try writer.writeAll("}");
    try writer.writeAll("}");
    var pools: dot.FixedDocumentStorage(.{ .statements = depth + 1, .subgraphs = depth, .nodes = 1 }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = depth }) = .{};
    var session = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true }, .limits = .{ .max_nesting = depth } } }).Session.init(writer.buffered(), .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{});
    defer session.deinit();
    var progress = session.advance(1);
    while (progress.outcome == null) {
        try expect(progress.work_used <= 1);
        progress = session.advance(1);
    }
    try expect(progress.outcome.? == .success);
    try equal(@as(usize, depth + 1), progress.completed_statements);
    const doc = session.result().?.document.?;
    try equal(@as(usize, depth), count(doc.subgraphs()));
    try equal(@as(usize, depth + 1), count(doc.statements()));
    try equal(@as(usize, 1), count(doc.scope(.root).?.statements(.direct)));
    try equal(@as(usize, depth), count(doc.scope(.root).?.subgraphs(.recursive)));
}
test "subgraph endpoints parse while malformed standalone headers are syntax errors" {
    inline for (.{ "graph {a--{b}}", "digraph {subgraph s {a}->b}", "graph {{}--{}}", "graph {a--subgraph s {b}}" }) |source| {
        var bag: dot.FixedDiagnosticBag(2) = .{};
        var result = dot.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
        defer result.deinit(std.testing.allocator);
        try expect(result.outcome == .success);
        try expect(result.document != null);
        try equal(@as(usize, 0), bag.items().len);
    }
    inline for (.{ "graph {subgraph;}", "graph {subgraph s;}", "graph {subgraph s {a}[x=1]}" }) |source| {
        var result = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
        defer result.deinit(std.testing.allocator);
        try expect(result.outcome == .invalid_syntax);
    }
}
test "validation sees nested edges in source order without resolving scope semantics" {
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var result = dot.parseAndValidate(std.testing.allocator, "graph {{a->b} c->d {e->f->g}}", bag.sink(), .{});
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .success);
    try expect(!result.documentValid());
    try equal(@as(usize, 4), bag.items().len);
    for (bag.items()[1..], bag.items()[0..3]) |current, previous| try expect(current.span.start > previous.span.start);
}

test "EOF points to the innermost still-open scope and restores the parent" {
    inline for (.{ .{ "graph { {a", @as(usize, 8) }, .{ "graph { {a}", @as(usize, 6) } }) |case| {
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var result = dot.parseBorrowed(std.testing.allocator, case[0], bag.sink(), .{});
        defer result.deinit(std.testing.allocator);
        try expect(result.outcome == .invalid_syntax);
        try equal(case[1], bag.items()[0].details.unexpected.related.?.span.start);
    }
}
test "separate temporary allocator fails independently and is not retained" {
    var empty: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&empty);
    var flat = dot.parseBorrowed(std.testing.allocator, "graph {a}", dot.diagnostic.discard, .{ .scratch_allocator = fixed.allocator() });
    defer flat.deinit(std.testing.allocator);
    try expect(flat.outcome == .success);
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const nested = dot.parseBorrowed(std.testing.allocator, "graph {{a}}", bag.sink(), .{ .scratch_allocator = fixed.allocator() });
    try expect(nested.outcome == .storage_failure);
    try equal(dot.StorageFailure.out_of_memory, nested.outcome.storage_failure);
    try equal(dot.Code.resource_memory_exhausted, bag.items()[0].code);
    try expect(nested.document == null);
    var temporary: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var result = dot.parseBorrowed(std.testing.allocator, "graph {{a}}", dot.diagnostic.discard, .{ .scratch_allocator = temporary.allocator() });
    temporary.deinit(); // No document or scope references point into this arena.
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .success);
    try equal(@as(usize, 2), count(result.document.?.statements()));
}
test "scratch failure delivery is latched and reset reuses nesting frames" {
    const Reject = struct {
        calls: usize = 0,
        fn emit(context: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return error.DiagnosticSinkFailure;
        }
    };
    var pools: Pools = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
    var reporter: Reject = .{};
    var session = dot.BoundedSession.init("graph {{{a}}}", .{ .document = pools.storage(), .scratch = scratch.storage() }, .{ .context = &reporter, .emit_fn = Reject.emit }, .{});
    defer session.deinit();
    while (session.advance(1).outcome == null) {}
    const failed = session.result().?;
    try expect(failed.outcome == .storage_failure);
    try equal(dot.diagnostic.Delivery.failed, failed.diagnostic_delivery);
    try deep(failed, session.cancel());
    try equal(@as(usize, 1), reporter.calls);
    session.reset("graph {{a} {b}}", dot.diagnostic.discard, .{});
    try expect(session.run().outcome == .success);
    session.reset("graph {{a} {b}}", dot.diagnostic.discard, .{});
    while (session.advance(1).completed_statements == 0) {}
    var moved = session;
    session = undefined;
    try expect(moved.cancel().outcome == .cancelled);
    moved.reset("graph {{}}", dot.diagnostic.discard, .{});
    try expect(moved.run().outcome == .success);
    // Restore ownership for the deferred cleanup.
    session = moved;
}
test "all execution profiles accept nested standalone scopes" {
    inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        var pools: Pools = .{};
        var scratch: Scratch = .{};
        var session = dot.Profile(.{ .policy = .{ .execution = .{ .metering = metering, .cancellation = cancellation } } }).Session.init(
            "digraph {{a:p->b->c[k=v]} subgraph s {{z}}}",
            .{ .document = pools.storage(), .scratch = scratch.storage() },
            dot.diagnostic.discard,
            .{},
        );
        defer session.deinit();
        try expect(session.run().outcome == .success);
        try equal(@as(usize, 3), session.result().?.document.?.subgraph_records.len);
    };
}

test "generated scope trees match independent parent and direct-child accounting" {
    var prng: std.Random.DefaultPrng = .init(0x5c0fe);
    const random = prng.random();
    for (0..32) |_| {
        var bytes: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        try writer.writeAll("graph {");
        var stack: [8]u32 = undefined;
        var depth: usize = 0;
        var current: u32 = 0;
        var scope_count: u32 = 0;
        var parents: [129]u32 = undefined;
        parents[0] = 0;
        var expected_scopes: [128]u32 = undefined;
        var expected_children: [129]usize = @splat(0);
        var statements: usize = 0;
        for (0..128) |_| switch (random.uintLessThan(u8, 3)) {
            0 => {
                if (depth == stack.len) continue;
                expected_scopes[statements] = current;
                expected_children[current] += 1;
                statements += 1;
                try writer.writeAll("{");
                scope_count += 1;
                parents[scope_count] = current;
                stack[depth] = current;
                depth += 1;
                current = scope_count;
            },
            1 => {
                if (depth == 0) continue;
                try writer.writeAll("}");
                depth -= 1;
                current = stack[depth];
            },
            else => {
                try writer.writeAll("a;");
                expected_scopes[statements] = current;
                expected_children[current] += 1;
                statements += 1;
            },
        };
        while (depth != 0) : (depth -= 1) try writer.writeAll("}");
        try writer.writeAll("}");
        var parsed = dot.parseBorrowed(std.testing.allocator, writer.buffered(), dot.diagnostic.discard, .{});
        defer parsed.deinit(std.testing.allocator);
        try expect(parsed.outcome == .success);
        const doc = &parsed.document.?;
        try equal(statements, doc.statementCount());
        try equal(@as(usize, scope_count), doc.subgraph_records.len);
        var it = doc.statements();
        for (expected_scopes[0..statements]) |parent| try equal(parent, @intFromEnum(it.nextScoped().?.scope));
        try expect(it.nextScoped() == null);
        for (0..scope_count + 1) |id| {
            const scope = doc.scope(@enumFromInt(id)).?;
            if (id != 0) try equal(parents[id], @intFromEnum(scope.parent().?));
            try equal(expected_children[id], count(scope.statements(.direct)));
        }
    }
}
