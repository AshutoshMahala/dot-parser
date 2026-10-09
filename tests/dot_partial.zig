const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const allocator = std.testing.allocator;
const discard = dot.diagnostic.discard;
const Keep = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true, .comments = true } } });
const capacities: dot.DocumentCapacities = .{ .comments = 16, .statements = 64, .nodes = 32, .edges = 16, .edge_chains = 16, .edge_links = 32, .scoped_edges = 16, .scoped_edge_links = 32, .ported_references = 16, .subgraphs = 16, .attributes = 32, .assignments = 16, .attribute_statements = 16 };
const Pools = dot.FixedDocumentStorage(capacities);
const source = "/* lead */ digraph G { a:p:n -> b -> c; subgraph s { x [k=v]; {y} -> z -> {q} -> r; } n [a=1 b=2]; graph [rank=same]; k=v; }";

fn audit(doc: *const dot.Document) !void {
    try expect(doc.retained_end <= doc.source.len);
    if (doc.unrepresented()) |tail| try equal(doc.source.len, tail.endOffset());
    if (doc.comments) |comments| {
        for (comments) |comment| _ = comment.raw(doc.source);
    }
    for (doc.attributes) |a| {
        _ = doc.text(a.key);
        _ = doc.text(a.value);
    }
    for (doc.order) |id| try expect(doc.statement(id) != null);
    for (0..doc.subgraph_records.len + 1) |index| {
        const scope = doc.scope(@enumFromInt(index)).?;
        try expect(scope.sourceRange().?.endOffset() <= doc.source.len);
        if (scope.name()) |name| _ = doc.text(name);
        inline for (.{ .direct, .recursive }) |traversal| {
            var children = scope.subgraphs(traversal);
            var count: usize = 0;
            while (children.next()) |child| {
                count += 1;
                try expect(count <= doc.subgraph_records.len);
                try expect(@intFromEnum(child.id) > index);
            }
            var statements = scope.statements(traversal);
            count = 0;
            while (statements.next()) |_| {
                count += 1;
                try expect(count <= doc.order.len);
            }
            var edges = scope.edges(traversal);
            count = 0;
            while (edges.next()) |edge| {
                count += 1;
                try expect(count <= doc.edges.len + doc.edge_chains.len + doc.edge_links.len + doc.scoped_edges.len + doc.scoped_edge_links.len);
                _ = doc.text(edge.operator_range);
                try expect(doc.attributeSlice(edge.attributes) != null);
                inline for (.{ edge.left, edge.right }) |endpoint| switch (endpoint) {
                    .node => |n| try expect(doc.nodeReference(n) != null),
                    .subgraph => |s| try expect(doc.scope(s) != null),
                };
            }
        }
    }
    var statements = doc.statements();
    var count: usize = 0;
    while (statements.next()) |_| {
        count += 1;
        try expect(count <= doc.order.len);
    }
    try expect(doc.rootStatementCount() <= doc.statementCount());
}

test "DOT partial retention preserves safe scopes without claiming syntax success" {
    var parsed = Keep.parseBorrowed(allocator, "digraph { done; { closed; } subgraph open { a -> b; broken [x=", discard, .{});
    defer parsed.deinit(allocator);
    try equal(dot.ParseOutcome.invalid_syntax, parsed.outcome);
    const doc = &parsed.document.?;
    try equal(dot.Completeness.partial, doc.state);
    try expect(!doc.scopeComplete() and !doc.subtreeComplete());
    try expect(doc.scope(@enumFromInt(1)).?.scopeComplete());
    try expect(!doc.scope(@enumFromInt(2)).?.scopeComplete());
    try equal(@as(usize, 2), doc.nodes.len);
    try equal(@as(usize, 1), doc.edges.len);
    try audit(doc);
    var complete = Keep.parseBorrowed(allocator, "graph {}", discard, .{});
    defer complete.deinit(allocator);
    try expect(complete.document.?.scopeComplete());
    try expect(complete.document.?.unrepresented() == null);
    var header = Keep.parseBorrowed(allocator, "digraph", discard, .{});
    defer header.deinit(allocator);
    try expect(header.document == null);
}

test "DOT partial retention freezes before recovery and leaves ambiguous text raw" {
    const cases = [_][]const u8{
        "graph { first; n [x=]; later; }",
        "graph { first; \"unterminated; fake }",
        "graph { first; /* unterminated; fake }",
    };
    for (cases) |bytes| {
        var kept = Keep.parseBorrowed(allocator, bytes, discard, .{});
        defer kept.deinit(allocator);
        var plain = dot.parseBorrowed(allocator, bytes, discard, .{});
        defer plain.deinit(allocator);
        try deep(plain.outcome, kept.outcome);
        try equal(plain.completion, kept.completion);
        try equal(plain.syntax_errors, kept.syntax_errors);
        try expect(plain.document == null);
        try equal(@as(usize, 1), kept.document.?.nodes.len);
        try expect(kept.document.?.unrepresented().?.len != 0);
        try audit(&kept.document.?);
    }
}

test "DOT partial prefixes agree for every truncation scanner and binding time" {
    const Runtime = dot.Profile(.{ .runtime_policy = true });
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .collect, .fail_fast }) |on_error| {
        const settings: dot.Policy = .{ .scanner = scanner, .on_error = on_error, .retention = .{ .partial = true, .comments = true } };
        const P = dot.Profile(.{ .policy = settings });
        for (0..source.len + 1) |length| {
            const bytes = source[0..length];
            var owned = P.parseBorrowed(allocator, bytes, discard, .{});
            defer owned.deinit(allocator);
            var pools: Pools = .{};
            var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
            const fixed = try Runtime.parseBorrowedIn(bytes, .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{ .policy = settings });
            try deep(owned.outcome, fixed.outcome);
            try deep(owned.document, fixed.document);
            if (owned.document) |*doc| try audit(doc);
        }
    };
}

test "DOT partial sessions safely freeze at every work boundary and reset" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true, .comments = true }, .execution = .{ .metering = true } } });
        for (0..600) |stop| {
            var pools: Pools = .{};
            var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
            var session = P.Session.init(source, .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
            defer session.deinit();
            for (0..stop) |_| _ = session.advance(1);
            const stopped = session.cancel();
            if (stopped.document) |*doc| try audit(doc);
            try deep(stopped, session.cancel());
            session.reset("graph { ok; }", discard, .{});
            try expect(session.run().document.?.scopeComplete());
        }
    }
}

test "DOT partial rollback handles exhaustion of every fixed pool" {
    inline for (@typeInfo(dot.DocumentCapacities).@"struct".fields) |field| {
        for ([_][]const u8{ source, "digraph { a:p -> b -> c -> {d} -> e -> {f} -> {g} -> h; }" }) |bytes| for (0..5) |limit| {
            var pools: Pools = .{};
            var storage = pools.storage();
            const name = comptime if (std.mem.eql(u8, field.name, "statements")) "statement_ids" else field.name;
            @field(storage, name) = @field(storage, name)[0..limit];
            var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
            const parsed = Keep.parseBorrowedIn(bytes, .{ .document = storage, .scratch = frames.storage() }, discard, .{});
            if (parsed.document) |*doc| try audit(doc);
        };
    }
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var parsed = Keep.parseAndValidate(a, source[0 .. source.len - 1], discard, .{});
    defer parsed.deinit(a);
    if (parsed.document) |*doc| try audit(doc);
    if (parsed.outcome == .storage_failure and parsed.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    try equal(dot.ParseOutcome.invalid_syntax, parsed.outcome);
    try expect(parsed.validation.?.coverage == .incomplete);
    try expect(!parsed.documentValid());
}

test "DOT partial ownership survives allocation failures without allocating to salvage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationProbe, .{});
}

test "DOT partial validation is explicit about coverage and honors terminal stops" {
    var kept = Keep.parseAndValidate(allocator, "digraph { a -- b; n [x=]; }", discard, .{});
    defer kept.deinit(allocator);
    try expect(kept.validation.?.coverage == .incomplete);
    try equal(@as(u64, 1), kept.validation.?.outcome.completed.violations);
    try expect(!kept.validation.?.documentValid());
    const Fast = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .on_error = .fail_fast } });
    var stopped = Fast.parseAndValidate(allocator, "digraph { a -- b; n [x=]; }", discard, .{});
    defer stopped.deinit(allocator);
    try expect(stopped.document != null and stopped.validation == null);
    var bag: dot.FixedDiagnosticBag(0) = .{};
    var sink_stop = Keep.parseAndValidate(allocator, "digraph { a -- b; n [x=]; }", bag.sink(), .{});
    defer sink_stop.deinit(allocator);
    try expect(sink_stop.document != null and sink_stop.validation == null);
}

test "runtime partial retention resets without stale ownership and requires bound child retention" {
    const R = dot.Profile(.{ .runtime_policy = true, .policy = .{ .retention = .{ .partial = true } } });
    var pools: Pools = .{};
    var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
    var session = try R.Session.init("graph { a;", .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
    defer session.deinit();
    try expect(session.run().document != null);
    try session.reset("graph { b;", discard, .{ .policy = .{ .retention = .{ .partial = false } } });
    try expect(session.run().document == null);
    var parsed = try R.parseBorrowed(allocator, "graph { b;", discard, .{ .policy = .{ .retention = .{ .partial = false } } });
    defer parsed.deinit(allocator);
    try expect(parsed.document == null and parsed._allocation_lengths == null);
    try std.testing.expectError(error.MarkupProcessorRequired, R.parseBorrowed(allocator, "graph {}", discard, .{ .policy = .{ .retention = .{ .markup = true } } }));
}

test "mutated DOT partial trees have safe references and scanner parity" {
    const Block = dot.Profile(.{ .policy = .{ .scanner = .block, .retention = .{ .partial = true, .comments = true } } });
    const alphabet = "{}[];:=><-/\"+ab /*\n";
    var random = std.Random.DefaultPrng.init(0x73910);
    for (0..2500) |_| {
        var input: [source.len]u8 = undefined;
        @memcpy(&input, source);
        for (0..1 + random.random().uintLessThan(u8, 6)) |_| {
            input[random.random().uintLessThan(usize, input.len)] = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        }
        var a: Pools = .{};
        var b: Pools = .{};
        var fa: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
        var fb: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
        var bag_a: dot.reporting.FixedBag(dot.Diagnostic, 64, .omit) = .{};
        var bag_b: dot.reporting.FixedBag(dot.Diagnostic, 64, .omit) = .{};
        const left = Keep.parseBorrowedIn(&input, .{ .document = a.storage(), .scratch = fa.storage() }, bag_a.sink(), .{});
        const right = Block.parseBorrowedIn(&input, .{ .document = b.storage(), .scratch = fb.storage() }, bag_b.sink(), .{});
        try deep(left, right);
        try deep(bag_a.items(), bag_b.items());
        if (left.document) |*doc| {
            try audit(doc);
            const checked = Keep.validate(doc, discard, .{});
            if (doc.state == .partial) try expect(!checked.documentValid());
        }
    }
}
