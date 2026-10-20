const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const equalStrings = std.testing.expectEqualStrings;
const deep = std.testing.expectEqualDeep;
const allocator = std.testing.allocator;
const discard = dot.diagnostic.discard;
const Keep = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true, .comments = true } } });
const capacities: dot.DocumentCapacities = .{ .comments = 16, .statements = 64, .nodes = 32, .edges = 16, .edge_chains = 16, .edge_links = 32, .scoped_edges = 16, .scoped_edge_links = 32, .ported_references = 16, .subgraphs = 16, .attributes = 32, .assignments = 16, .attribute_statements = 16 };
const Pools = dot.FixedDocumentStorage(capacities);
const source = "/* lead */ digraph G { a:p:n -> b -> c; subgraph s { x [k=v]; {y} -> z -> {q} -> r; } n [a=1 b=2]; graph [rank=same]; k=v; }";

test "comment retention remains capped when partial collection resumes" {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true, .comments = true }, .limits = .{ .max_comments = 1 } } });
    var result = P.parseBorrowed(allocator, "graph { a -> ; /* x */ /* y */ }", discard, .{});
    defer result.deinit(allocator);
    try equal(dot.ParseOutcome.resource_exhausted, result.outcome);
    try equal(@as(usize, 1), result.document.?.comments.?.len);
}

test "terminal partial validation never reads unattached attribute or port staging" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true }, .execution = .{ .metering = true }, .validation = .{
            .graphviz = .{ .unknown_attribute = .warning },
            .restrictions = .{ .ports = .warning },
        } } });
        const bytes = "graph { ok [color=red]; bad:p [colr=blue x=1]; }";
        for (0..200) |stop| {
            var pools: Pools = .{};
            var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
            var session = P.Session.init(bytes, .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
            defer session.deinit();
            for (0..stop) |_| _ = session.advance(1);
            const result = session.cancel();
            if (result.document) |*document| {
                const validation = P.validate(document, discard, .{});
                try equal(@as(u64, if (document.nodes.len == 2) 3 else 0), validation.warningCount());
            }
        }
    }
}

test "partial validation excludes abandoned attributes ports and late operators" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| {
        const p: dot.Policy = .{ .scanner = scanner, .retention = .{ .partial = true }, .validation = .{
            .graphviz = .{ .unknown_attribute = .warning },
            .restrictions = .{ .ports = .warning },
        } };
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else p });
        for ([_][]const u8{
            "graph { a [color=red",  "graph { a [colr=red x=]; b; }",
            "graph { a:p -> ; b; }", "graph { a -- { b } -> c [x= ; d; }",
        }) |input| {
            var bag: dot.FixedDiagnosticBag(32) = .{};
            var r = if (runtime) try P.parseAndValidate(allocator, input, bag.sink(), .{ .policy = p }) else P.parseAndValidate(allocator, input, bag.sink(), .{});
            defer r.deinit(allocator);
            try equal(dot.ParseOutcome.invalid_syntax, r.outcome);
            try equal(@as(u64, 0), r.validation.?.warningCount());
            try equal(@as(u64, 0), r.validation.?.outcome.completed.violations);
            try audit(&r.document.?);
            var pools: Pools = .{};
            var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
            const fixed = if (runtime) try P.parseBorrowedIn(input, .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{ .policy = p }) else P.parseBorrowedIn(input, .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
            try deep(r.document.?, fixed.document.?);
        }
        var bag: dot.FixedDiagnosticBag(32) = .{};
        const nested = "graph { a:p -> { b:q [colr=red]; } -> c:r [bad=1 x=]; d:s [colr=blue]; }";
        var r = if (runtime) try P.parseAndValidate(allocator, nested, bag.sink(), .{ .policy = p }) else P.parseAndValidate(allocator, nested, bag.sink(), .{});
        defer r.deinit(allocator);
        try equal(@as(u64, 1), r.validation.?.outcome.completed.violations);
        try equal(@as(u64, 5), r.validation.?.warningCount());
        var previous: u32 = 0;
        for (bag.items()[1..]) |d| {
            try expect(d.span.start >= previous);
            previous = d.span.start;
        }
    };
}

test "partial validation checks retained operators of unfinished scoped owners" {
    const cases = .{
        .{ "graph { a -> {b} [x=1", 1 },
        .{ "graph { a -> {b}", 1 },
        .{ "graph { a -> subgraph s { c } -> d", 1 },
        .{ "graph { a -> b -> {c} -> d -> { e -> f } [x=1", 5 },
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| {
        const policy: dot.Policy = .{ .scanner = scanner, .retention = .{ .partial = true } };
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else policy });
        inline for (cases) |case| {
            var bag: dot.FixedDiagnosticBag(16) = .{};
            var r = if (runtime) try P.parseAndValidate(allocator, case[0], bag.sink(), .{ .policy = policy }) else P.parseAndValidate(allocator, case[0], bag.sink(), .{});
            defer r.deinit(allocator);
            try equal(dot.ParseOutcome.invalid_syntax, r.outcome);
            const end: u32 = @intCast(std.mem.lastIndexOf(u8, case[0], "}").? + 1);
            try equal(end, r.validation.?.coverage.incomplete);
            try equal(@as(u64, case[1]), r.validation.?.outcome.completed.violations);
            var found: u32 = 0;
            var previous: u32 = 0;
            for (bag.items()) |d| if (d.code == .validation_operator_mismatch) {
                try expect(d.span.start >= previous and d.span.endOffset() <= r.document.?.retained_end);
                try equal("->".len, d.span.len);
                previous = d.span.start;
                found += 1;
            };
            try equal(@as(u32, case[1]), found);
            try expect(!r.documentValid());
            try audit(&r.document.?);

            var pools: Pools = .{};
            var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
            const fixed = if (runtime) try P.parseBorrowedIn(case[0], .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{ .policy = policy }) else P.parseBorrowedIn(case[0], .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
            try deep(r.document.?, fixed.document.?);
            const checked = if (runtime) try P.validate(&fixed.document.?, discard, .{ .policy = policy }) else P.validate(&fixed.document.?, discard, .{});
            try equal(@as(u64, case[1]), checked.outcome.completed.violations);
        }
    };
}

test "unclassified left scopes never publish fabricated standalone statements" {
    const cases = .{
        .{ "graph { {a} ->", 1, 1 },
        .{ "graph { {a} -> b [x=1", 1, 1 },
        .{ "graph { x; {a} -> {b} -> ", 3, 2 },
    };
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true } } });
        inline for (cases) |case| {
            var r = P.parseBorrowed(allocator, case[0], discard, .{});
            defer r.deinit(allocator);
            const doc = &r.document.?;
            try equal(@as(usize, case[1]), doc.statementCount());
            try equal(@as(usize, if (case[1] == 3) 1 else 0), doc.rootStatementCount());
            var statements = doc.statements();
            while (statements.next()) |statement| try expect(statement == .node);
            var scopes = doc.subgraphs();
            var count: usize = 0;
            while (scopes.next()) |scope| {
                try expect(scope.scopeComplete());
                var children = scope.statements(.direct);
                try expect(children.next().? == .node);
                try expect(children.next() == null);
                count += 1;
            }
            try equal(@as(usize, case[2]), count);
            try audit(doc);
        }
        var complete = P.parseBorrowed(allocator, "graph { {a}; {b} -> c; }", discard, .{});
        defer complete.deinit(allocator);
        try equal(@as(usize, 4), complete.document.?.statementCount());
        var statements = complete.document.?.statements();
        try expect(statements.next().? == .subgraph);
        try expect(statements.next().? == .node);
        try expect(statements.next().? == .edge);
        try expect(statements.next().? == .node);
    }
}

test "staged-operator checks retain severity fixes and validation fail-fast" {
    var parsed = Keep.parseBorrowed(allocator, "graph { a -> {b} -> {c} [x=1", discard, .{});
    defer parsed.deinit(allocator);
    const doc = &parsed.document.?;
    const Warn = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind } } } });
    var bag: dot.FixedDiagnosticBag(8) = .{};
    const warning = Warn.validate(doc, bag.sink(), .{});
    try equal(@as(u64, 2), warning.outcome.completed.warnings);
    try equal(@as(u64, 0), warning.outcome.completed.violations);
    for (bag.items()) |d| {
        try equal(dot.Code.validation_operator_tolerated, d.code);
        try equal(.machine_applicable, d.fix.?.applicability);
    }
    const Off = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .operator_mismatch = .off } } } });
    try equal(@as(u64, 0), Off.validate(doc, discard, .{}).outcome.completed.violations);
    const Fast = dot.Profile(.{ .policy = .{ .on_error = .fail_fast } });
    var stop: dot.FixedDiagnosticBag(8) = .{};
    try expect(Fast.validate(doc, stop.sink(), .{}).outcome == .error_stopped);
    try equal(@as(usize, 1), stop.items().len);
    try equalStrings("->", doc.text(stop.items()[0].span));
    var edges = doc.edgeIterator();
    try expect(edges.next() == null);
}

test "pending pairs links ports and trivia do not advance the represented frontier" {
    const inputs = [_][]const u8{
        "graph { a -> b -> c",           "graph { a -> b [x=1", "graph { a:p", "graph { a /* c */",
        "graph { \"a\" /* c */ + \"b\"",
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |comments| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true, .comments = comments } } });
        for (inputs) |bytes| {
            var r = P.parseAndValidate(allocator, bytes, discard, .{});
            defer r.deinit(allocator);
            const doc = r.document.?;
            try equal(@as(usize, 0), doc.statementCount());
            try equal(@as(u32, 7), doc.retained_end);
            try equal(@as(u32, 7), r.validation.?.coverage.incomplete);
            try expect(doc.unrepresented().?.len != 0);
            try audit(&doc);
        }
        var r = P.parseBorrowed(allocator, "digraph { x; a -> /* c */ }", discard, .{});
        defer r.deinit(allocator);
        try equal(@as(u32, @intCast(r.document.?.source.len)), r.document.?.retained_end);
    };
}

test "pending scoped edges remain raw staging records not completed statements" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true } } });
        var r = P.parseAndValidate(allocator, "graph { a -- subgraph { x } [color=red", discard, .{});
        defer r.deinit(allocator);
        const doc = &r.document.?;
        try equal(@as(usize, 1), doc.statementCount()); // Only the endpoint's x.
        try equal(@as(usize, 0), doc.rootStatementCount());
        try expect(!doc.scoped_edges[0].complete());
        var edges = doc.edgeIterator();
        try expect(edges.next() == null);
        var statements = doc.statements();
        try expect(statements.next().? == .node);
        try expect(statements.next() == null);
        try audit(doc);

        var nested = P.parseBorrowed(allocator, "graph { a -- subgraph { x -- { y } -- z; } [color=red", discard, .{});
        defer nested.deinit(allocator);
        const child = &nested.document.?;
        try equal(@as(usize, 2), child.statementCount()); // Finished inner edge and y.
        try equal(@as(usize, 0), child.rootStatementCount());
        var child_edges = child.edgeIterator();
        var count: u32 = 0;
        while (child_edges.next() != null) count += 1;
        try equal(@as(u32, 2), count);
        try audit(child);
    }
}

test "automatic graph kind remains unknown until a directed edge or completion" {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .validation = .{
        .graph = .{ .treated_as = .auto },
        .restrictions = .{ .graph_kinds = .{ .undigraph = .err } },
    } } });
    var bag: dot.FixedDiagnosticBag(16) = .{};
    var r = P.parseAndValidate(allocator, "graph { a -- b; x [y=; c -> d; }", bag.sink(), .{});
    defer r.deinit(allocator);
    try equal(dot.GraphKind.generic, r.document.?.effectiveKind(P.interpretation(&r.document.?, .{})));
    for (bag.items()) |d| try expect(d.code != .validation_restriction);
    var unknown = P.parseBorrowed(allocator, "graph { a -- b; x [y=", discard, .{});
    defer unknown.deinit(allocator);
    try expect(unknown.document.?.effectiveKind(P.interpretation(&unknown.document.?, .{})) == null);
    var directed = P.parseBorrowed(allocator, "graph { a -> b; x [y=", discard, .{});
    defer directed.deinit(allocator);
    try equal(dot.GraphKind.generic, directed.document.?.effectiveKind(P.interpretation(&directed.document.?, .{})));
}

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
    for (doc.order) |id| if (doc.statement(id) == null) {
        try expect(doc.state == .partial);
        switch (id) {
            .skipped_start, .skipped_end => {},
            .scoped_edge => |index| try expect(!doc.scoped_edges[index].complete()),
            .subgraph => |index| try equal(std.math.maxInt(u32), index),
            else => return error.UnexpectedStagedStatement,
        }
    };
    for (0..doc.subgraph_records.len + 1) |index| {
        const scope = doc.scope(@fromBackingInt(@intCast(index))).?;
        try expect(scope.sourceRange().?.endOffset() <= doc.source.len);
        if (scope.name()) |name| _ = doc.text(name);
        inline for (.{ .direct, .recursive }) |traversal| {
            var children = scope.subgraphs(traversal);
            var count: usize = 0;
            while (children.next()) |child| {
                count += 1;
                try expect(count <= doc.subgraph_records.len);
                try expect(@backingInt(child.id) > index);
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
    try expect(doc.scope(@fromBackingInt(@intCast(1))).?.scopeComplete());
    try expect(!doc.scope(@fromBackingInt(@intCast(2))).?.scopeComplete());
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

test "DOT partial retention continues safe recovery but leaves ambiguous text raw" {
    const cases = [_][]const u8{
        "graph { first; n [x=]; later; }",
        "graph { first; \"unterminated; fake }",
        "graph { first; /* unterminated; fake }",
    };
    for (cases, 0..) |bytes, i| {
        var kept = Keep.parseBorrowed(allocator, bytes, discard, .{});
        defer kept.deinit(allocator);
        var plain = dot.parseBorrowed(allocator, bytes, discard, .{});
        defer plain.deinit(allocator);
        try deep(plain.outcome, kept.outcome);
        try equal(plain.completion, kept.completion);
        try equal(plain.syntax_errors, kept.syntax_errors);
        try expect(plain.document == null);
        try equal(@as(usize, if (i == 0) 2 else 1), kept.document.?.nodes.len);
        if (i == 0) {
            try expect(kept.document.?.unrepresented() == null);
            var gaps = kept.document.?.skippedRanges();
            try equalStrings("n [x=];", kept.document.?.text(gaps.next().?.range));
            try expect(gaps.next() == null);
        } else try expect(kept.document.?.unrepresented().?.len != 0);
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

test "DOT partial failure-atomic events handle exhaustion of every fixed pool" {
    inline for (@typeInfo(dot.DocumentCapacities).@"struct".field_names) |field| {
        for ([_][]const u8{ source, "digraph { a:p -> b -> c -> {d} -> e -> {f} -> {g} -> h; }" }) |bytes| for (0..5) |limit| {
            var pools: Pools = .{};
            var storage = pools.storage();
            const name = comptime if (std.mem.eql(u8, field, "statements")) "statement_ids" else field;
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
    try @import("allocation_failures.zig").check(allocator, allocationProbe, .{});
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

test "recovered regions retain later scopes attributes and independent validation" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true }, .validation = .{ .repeated_attribute = .err } } });
        const bytes = "digraph { first; bad [old=value broken=]; subgraph s { a -> ; b [x=1 x=2]; } c; {d} -> ; e [fresh=ok]; }";
        var bag: dot.FixedDiagnosticBag(32) = .{};
        var keys: [32]dot.AttributeKeyScratch = undefined;
        var result = P.parseAndValidate(allocator, bytes, bag.sink(), .{ .validation = .{ .attribute_keys = &keys } });
        defer result.deinit(allocator);
        const doc = &result.document.?;
        try equal(dot.Completion.complete, result.completion);
        try equal(@as(u32, 3), result.syntax_errors);
        try expect(!result.documentValid());
        try equal(@as(usize, 5), doc.nodes.len);
        try equal(@as(u64, 1), result.validation.?.outcome.completed.violations);
        const last = doc.attributeSlice(doc.nodes[doc.nodes.len - 1].attributes).?;
        try equal(@as(usize, 1), last.len);
        try equalStrings("fresh", doc.text(last[0].key));
        var gaps = doc.skippedRanges();
        try equal(dot.ScopeId.root, gaps.next().?.scope);
        try equal(@as(u32, 1), @backingInt(gaps.next().?.scope));
        try equal(dot.ScopeId.root, gaps.next().?.scope);
        try expect(gaps.next() == null);
        // A failed surrounding edge must not make its independently completed
        // endpoint body partial. The first scope has an actual child gap.
        try expect(!doc.scope(@fromBackingInt(@intCast(1))).?.scopeComplete());
        try expect(doc.scope(@fromBackingInt(@intCast(2))).?.scopeComplete());
        try equal(@as(u32, @intCast(std.mem.indexOf(u8, bytes, "bad").?)), result.validation.?.coverage.incomplete);
        try audit(doc);
        var pools: Pools = .{};
        var frames: dot.FixedParseScratch(.{ .nesting = 32 }) = .{};
        const fixed = P.parseBorrowedIn(bytes, .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
        try deep(doc.*, fixed.document.?);
        // Default retention is still off even though recovery collects.
        var plain = dot.parseBorrowed(allocator, bytes, discard, .{});
        defer plain.deinit(allocator);
        try expect(plain.document == null);
    }
}

test "gap publication is failure atomic and lexical stops leave an uncovered suffix" {
    const bytes = "graph { a; bad [x=]; b; }";
    var slots: [2]dot.StatementId = undefined;
    var nodes: [2]dot.NodeStatement = undefined;
    const stopped = Keep.parseBorrowedIn(bytes, .{ .document = .{ .statement_ids = &slots, .nodes = &nodes } }, discard, .{});
    try equal(dot.StorageFailure.pool_exhausted, stopped.outcome.storage_failure);
    try equal(@as(usize, 1), stopped.document.?.order.len);
    var gaps = stopped.document.?.skippedRanges();
    try expect(gaps.next() == null);
    try expect(stopped.document.?.unrepresented() != null);
    var result = Keep.parseBorrowed(allocator, "graph { a; bad [x=]; b; \"unterminated; fake; }", discard, .{});
    defer result.deinit(allocator);
    try equal(@as(usize, 2), result.document.?.nodes.len);
    try equal(dot.Completion.incomplete, result.completion);
    try expect(result.document.?.unrepresented() != null);
}

fn recoveredAllocationProbe(memory: std.mem.Allocator) !void {
    var result = Keep.parseBorrowed(memory, "graph { a; bad [x=]; b; }", discard, .{});
    defer result.deinit(memory);
    if (result.document) |*doc| try audit(doc);
    if (result.outcome == .storage_failure and result.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    try equal(dot.Completion.complete, result.completion);
    try equal(@as(usize, 2), result.document.?.nodes.len);
}

test "growing recovery remains failure atomic at every allocation" {
    try @import("allocation_failures.zig").check(allocator, recoveredAllocationProbe, .{});
}

test "retention changes output not grammar recovery or diagnostic findings" {
    inline for (.{ .scalar, .block }) |scanner| {
        const Plain = dot.Profile(.{ .policy = .{ .scanner = scanner } });
        const Partial = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true } } });
        for ([_][]const u8{
            "digraph { a -> { bad [x=]; later; } -> b; c; }",
            "graph { bad [x= { @ ; nested; } ; after; }",
            "graph { subgraph s { bad [x= } after; }",
            "graph {\n  subgraph s {\n    bad [x=];\n}\n",
        }) |bytes| {
            var a: dot.FixedDiagnosticBag(32) = .{};
            var b: dot.FixedDiagnosticBag(32) = .{};
            var plain = Plain.parseBorrowed(allocator, bytes, a.sink(), .{});
            defer plain.deinit(allocator);
            var partial = Partial.parseBorrowed(allocator, bytes, b.sink(), .{});
            defer partial.deinit(allocator);
            try deep(plain.outcome, partial.outcome);
            try equal(plain.completion, partial.completion);
            try equal(plain.syntax_errors, partial.syntax_errors);
            try std.testing.expectEqualSlices(dot.Diagnostic, a.items(), b.items());
            try audit(&partial.document.?);
        }
    }
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
