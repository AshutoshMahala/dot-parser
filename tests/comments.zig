const std = @import("std");
const dot = @import("dot_parser");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const deep = std.testing.expectEqualDeep;
const strings = std.testing.expectEqualStrings;
const allocator = std.testing.allocator;
const discard = dot.diagnostic.discard;
const Retained = dot.Profile(.{ .policy = .{ .retention = .{ .comments = true } } });

const source = "// before\r\n# hash\rgraph /* header */ G { \"a\" /* one */ + // two\n\"b\" /* trailing */; c [x=\"/* literal */\"]; d [label=<<B>//not DOT</B>>]; /* body */ } // after";
const raw_comments = [_][]const u8{ "// before", "# hash", "/* header */", "/* one */", "// two", "/* trailing */", "/* body */", "// after" };
const capacities: dot.DocumentCapacities = .{ .comments = 8, .statements = 3, .nodes = 3, .attributes = 2 };

fn checkComments(comments: []const dot.Comment, bytes: []const u8) !void {
    try equal(raw_comments.len, comments.len);
    for (comments, raw_comments) |comment, raw| {
        try strings(raw, comment.raw(bytes));
        try equal(@as(u32, @intCast(std.mem.indexOf(u8, bytes, raw).?)), comment.span.start);
        try equal(@as(u32, @intCast(raw.len)), comment.span.len);
        const kind: dot.CommentKind = if (raw[0] == '#') .hash_line else if (raw[1] == '/') .slash_line else .block;
        try equal(kind, comment.kind);
        const body = switch (kind) {
            .hash_line => raw[1..],
            .slash_line => raw[2..],
            .block => raw[2 .. raw.len - 2],
        };
        try strings(body, comment.body(bytes));
    }
}

test "opt-in comments preserve kinds, bytes and locations without changing statements" {
    var plain = dot.parseBorrowed(allocator, source, discard, .{});
    defer plain.deinit(allocator);
    var kept = Retained.parseBorrowed(allocator, source, discard, .{});
    defer kept.deinit(allocator);
    try equal(dot.ParseOutcome.success, kept.outcome);
    try expect(plain.document.?.comments == null);
    const document = &kept.document.?;
    try expect(document.source.ptr == source.ptr);
    try checkComments(document.comments.?, source);
    try deep(plain.document.?.order, document.order);
    try deep(plain.document.?.nodes, document.nodes);
    try deep(plain.document.?.attributes, document.attributes);
    try equal(@as(u32, 1), document.comments.?[0].span.locate(source).line);
    try equal(@as(u32, 2), document.comments.?[1].span.locate(source).line);
    try equal(@as(u32, 3), document.comments.?[2].span.locate(source).line);
    var empty = Retained.parseBorrowed(allocator, "graph{}", discard, .{});
    defer empty.deinit(allocator);
    try equal(@as(usize, 0), empty.document.?.comments.?.len);
    try equal(@as(usize, 12), @sizeOf(dot.Comment));
    try equal(@as(usize, 12), @sizeOf(dot.lexer.Token));
}

fn lexicalParity(bytes: []const u8) !void {
    var scalar = dot.lexer.WithComments(.scalar).init(bytes);
    var block = dot.lexer.WithComments(.block).init(bytes);
    var plain = dot.lexer.Lexer.init(bytes);
    var frontier: u64 = 0;
    var count: usize = 0;
    while (true) {
        count += 1;
        try expect(count <= bytes.len * 2 + 2);
        const a = scalar.next();
        const b = block.next();
        try deep(a, b);
        const warning = scalar.takeWarning();
        try deep(warning, block.takeWarning());
        if (a == .token) if (a.token.comment()) |comment| {
            try expect(comment.span.len >= 1);
            try expect(comment.span.start >= frontier);
            frontier = comment.span.endOffset();
            try expect(frontier <= bytes.len);
            try expect(warning == null);
            _ = comment.body(bytes);
            continue;
        };
        try deep(plain.next(), a);
        try deep(plain.takeWarning(), warning);
        if (a == .failure) {
            try deep(scalar.failureDiagnostic(), block.failureDiagnostic());
            try deep(plain.failureDiagnostic(), scalar.failureDiagnostic());
            try deep(a, scalar.next());
            try deep(a, block.next());
            scalar.resumeAfterFailure();
            block.resumeAfterFailure();
            plain.resumeAfterFailure();
        } else if (a.token.tag == .eof) {
            try deep(a, scalar.next());
            try deep(a, block.next());
            return;
        }
    }
}

test "comment tokens agree across scanners, truncations, recovery and block boundaries" {
    for ([_][]const u8{
        source,                           "",           "#",                 "//",                       "/**/",              "/*/",               "//\r\n#\r/**/",
        "\"a\"/*x*//*y*/+//z\n\"b\"#end", "\"a\"/**/;", "\"a\"/*ok*/ /*bad", "\"a\"+/*ok*/ @ //next\nx", "1e3/**/1.2.3#tail", "@/*ok*/-->/x#tail", "<// # /* */>/*dot*/",
        "//\x00\xff\r/*\x00\xff*/#\xff",
    }) |item| {
        for (0..item.len + 1) |end| try lexicalParity(item[0..end]);
        var shifted: [512]u8 = undefined;
        for (0..130) |shift| {
            @memset(shifted[0..shift], ' ');
            @memcpy(shifted[shift..][0..item.len], item);
            try lexicalParity(shifted[0 .. shift + item.len]);
        }
    }
    var random = std.Random.DefaultPrng.init(0xc011e17);
    const alphabet = "abc012 /#*\r\n\"+<>-;{}\\\x00\xff";
    var bytes: [128]u8 = undefined;
    for (0..10_000) |_| {
        const len = random.random().uintLessThan(usize, bytes.len);
        for (bytes[0..len]) |*b| b.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        try lexicalParity(bytes[0..len]);
    }
}

test "retention has fixed runtime sizing storage and budget parity" {
    const Runtime = dot.Profile(.{ .runtime_policy = true });
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        const policy: dot.Policy = .{ .retention = .{ .comments = true }, .scanner = scanner, .execution = .{ .metering = metering, .cancellation = cancellation } };
        const P = dot.Profile(.{ .policy = policy });
        const measured = P.measureIn(source, .{}, discard, .{});
        try equal(dot.ParseOutcome.success, measured.outcome);
        try deep(capacities, measured.capacities.?);
        try deep(measured.capacities, (try Runtime.measureIn(source, .{}, discard, .{ .policy = policy })).capacities);
        for ([_]usize{ 1, 7, 64 }) |budget| {
            var pools: dot.FixedDocumentStorage(capacities) = .{};
            const memory: dot.ParseMemory = .{ .document = pools.storage() };
            var session = P.Session.init(source, memory, discard, .{});
            defer session.deinit();
            if (metering) {
                try equal(@as(usize, 0), session.advance(0).work_used);
                var total: usize = 0;
                while (session.result() == null) {
                    const step = session.advance(budget);
                    try expect(step.work_used <= budget);
                    total += step.work_used;
                    try expect(total < 5000);
                }
            } else _ = session.run();
            const fixed = session.result().?;
            try equal(dot.ParseOutcome.success, fixed.outcome);
            try checkComments(fixed.document.?.comments.?, source);
            var dynamic = try Runtime.Session.init(source, memory, discard, .{ .policy = policy });
            defer dynamic.deinit();
            if (metering) {
                while (dynamic.result() == null) try expect((try dynamic.advance(budget)).work_used <= budget);
            } else _ = dynamic.run();
            try equal(dot.ParseOutcome.success, dynamic.result().?.outcome);
            try checkComments(dynamic.result().?.document.?.comments.?, source);
            try dynamic.reset("graph{}", discard, .{});
            try expect(dynamic.run().document.?.comments == null);
            try dynamic.reset(source, discard, .{ .policy = policy });
            try checkComments(dynamic.run().document.?.comments.?, source);
        }
    };
}

test "comment pool and policy limits fail explicitly including before the header" {
    for ([_][]const u8{ "/*first*/graph{}", "graph/*header*/{}", "graph{/*body*/}", "graph{}/*tail*/" }) |bytes| {
        var bag: dot.FixedDiagnosticBag(8) = .{};
        const full = Retained.parseBorrowedIn(bytes, .{ .document = .{} }, bag.sink(), .{});
        try equal(dot.ParseOutcome{ .storage_failure = .pool_exhausted }, full.outcome);
        try equal(dot.diagnostic.Capacity.Resource.comment_pool, bag.items()[0].details.capacity.resource);
        const Limited = dot.Profile(.{ .policy = .{ .retention = .{ .comments = true }, .limits = .{ .max_comments = 0 } } });
        const limited = Limited.measureIn(bytes, .{}, discard, .{});
        try equal(dot.ParseOutcome.resource_exhausted, limited.outcome);
        try expect(limited.capacities == null);
        const Off = dot.Profile(.{ .policy = .{ .limits = .{ .max_comments = 0 } } });
        try equal(dot.ParseOutcome.success, Off.parseBorrowedIn(bytes, .{ .document = .{} }, discard, .{}).outcome);
    }
    const Exact = dot.Profile(.{ .policy = .{ .retention = .{ .comments = true }, .limits = .{ .max_comments = 8 } } });
    try equal(dot.ParseOutcome.success, Exact.measureIn(source, .{}, discard, .{}).outcome);
    try equal(dot.ParseOutcome.resource_exhausted, Exact.measureIn(source ++ "\n#extra", .{}, discard, .{}).outcome);
}

fn allocationCase(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var result = Retained.parseBorrowed(gpa, bytes, discard, .{});
    defer result.deinit(gpa);
    if (result.outcome == .storage_failure and result.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    if (std.mem.eql(u8, bytes, source)) {
        try equal(dot.ParseOutcome.success, result.outcome);
        try checkComments(result.document.?.comments.?, bytes);
    } else {
        try equal(dot.ParseOutcome.invalid_syntax, result.outcome);
        try expect(result.document == null);
    }
}

test "retained comments release on allocation failure and syntax abort before or after header" {
    for ([_][]const u8{ source, "/*prefix*/wat", "graph{/*before*/a->;/*after*/b}", "graph{}/*unterminated" }) |bytes| {
        try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{bytes});
    }
}

test "default retention is allocation free for comments and presets explicitly reset it" {
    var tracked = std.testing.FailingAllocator.init(allocator, .{});
    var result = dot.parseBorrowed(tracked.allocator(), "/*before*/graph{}//after", discard, .{});
    defer result.deinit(tracked.allocator());
    try equal(dot.ParseOutcome.success, result.outcome);
    try equal(@as(usize, 0), tracked.allocated_bytes);
    const Runtime = dot.Profile(.{ .runtime_policy = true, .policy = .{ .retention = .{ .comments = true } } });
    inline for (.{ dot.presets.standard, dot.presets.lenient }) |preset| {
        const measured = try Runtime.measureIn(source, .{}, discard, .{ .policy = preset });
        try equal(@as(u32, 0), measured.capacities.?.comments);
    }
}

test "comment retention preserves recovery diagnostics and never publishes failed partial trees" {
    const Dynamic = dot.Profile(.{ .runtime_policy = true });
    for (0..source.len + 1) |end| {
        const bytes = source[0..end];
        var plain_bag: dot.FixedDiagnosticBag(32) = .{};
        var plain = dot.parseBorrowed(allocator, bytes, plain_bag.sink(), .{});
        defer plain.deinit(allocator);
        inline for (.{ .scalar, .block }) |backend| {
            var pools: dot.FixedDocumentStorage(capacities) = .{};
            var bag: dot.FixedDiagnosticBag(32) = .{};
            var session = try Dynamic.Session.init(bytes, .{ .document = pools.storage() }, bag.sink(), .{ .policy = .{
                .retention = .{ .comments = true },
                .scanner = backend,
                .execution = .{ .metering = true },
            } });
            defer session.deinit();
            while (session.result() == null) try expect((try session.advance(1)).work_used <= 1);
            const retained = session.result().?;
            try equal(plain.outcome, retained.outcome);
            try equal(plain.completion, retained.completion);
            try equal(plain.syntax_errors, retained.syntax_errors);
            try deep(plain_bag.items(), bag.items());
            try equal(plain.document == null, retained.document == null);
        }
    }
}

test "cancelling inside a large comment stops promptly and reset clears retained comments" {
    const Stop = struct {
        calls: usize = 0,
        fn poll(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return self.calls >= 32;
        }
    };
    inline for (.{ .scalar, .block }) |backend| {
        const P = dot.Profile(.{ .policy = .{ .retention = .{ .comments = true }, .scanner = backend, .execution = .{ .cancellation = true, .metering = true } } });
        var stop: Stop = .{};
        var pools: dot.FixedDocumentStorage(.{ .comments = 2 }) = .{};
        var session = P.Session.init("//lead\n/*" ++ "x" ** 8192 ++ "*/graph{}", .{ .document = pools.storage() }, discard, .{ .cancellation = .{ .context = &stop, .is_requested = Stop.poll } });
        defer session.deinit();
        var frontier: usize = 0;
        while (session.result() == null) {
            const progress = session.advance(7);
            try expect(progress.work_used <= 7);
            frontier = progress.source_frontier;
        }
        try equal(dot.ParseOutcome.cancelled, session.result().?.outcome);
        try expect(session.result().?.document == null and frontier < 8192);
        const calls = stop.calls;
        try equal(@as(usize, 0), session.advance(100).work_used);
        try equal(calls, stop.calls);
        session.reset("graph{}#new", discard, .{});
        const reset = session.run();
        try equal(dot.ParseOutcome.success, reset.outcome);
        try equal(@as(usize, 1), reset.document.?.comments.?.len);
        try strings("#new", reset.document.?.comments.?[0].raw(reset.document.?.source));
    }
}

test "exact comment hints reserve only record payload and runtime limits override the baseline" {
    var bytes: [512]u8 align(@alignOf(dot.FixedDocumentStorage(capacities))) = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&bytes);
    var kept = Retained.parseBorrowed(fba.allocator(), source, discard, .{ .document_capacities = capacities });
    defer kept.deinit(fba.allocator());
    try equal(dot.ParseOutcome.success, kept.outcome);
    try equal(@as(usize, 8 * @sizeOf(dot.Comment) + 3 * @sizeOf(dot.StatementId) + 3 * @sizeOf(dot.NodeStatement) + 2 * @sizeOf(dot.Attribute)), fba.end_index);
    const Dynamic = dot.Profile(.{ .runtime_policy = true, .policy = .{ .retention = .{ .comments = true }, .limits = .{ .max_comments = 7 } } });
    try equal(dot.ParseOutcome.resource_exhausted, (try Dynamic.measureIn(source, .{}, discard, .{})).outcome);
    try equal(dot.ParseOutcome.success, (try Dynamic.measureIn(source, .{}, discard, .{ .policy = .{ .limits = .{ .max_comments = 8 } } })).outcome);
    // Unused reservation must be freed too, including when retention is off.
    var unused = dot.parseBorrowed(allocator, "graph{}", discard, .{ .document_capacities = .{ .comments = 4 } });
    defer unused.deinit(allocator);
    try expect(unused.document.?.comments == null);
}
