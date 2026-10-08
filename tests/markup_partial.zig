const std = @import("std");
const markup = @import("markup_parser");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const strings = std.testing.expectEqualStrings;
const deep = std.testing.expectEqualDeep;
const allocator = std.testing.allocator;
const discard = markup.diagnostic.discard;
const Keep = markup.Profile(.{ .policy = .{ .mode = .structural, .retention = .{ .partial = true } } });
const Plain = markup.Profile(.{ .policy = .{ .mode = .structural } });

fn audit(document: markup.Document) !void {
    try expect(document.retained_end <= document.source.len);
    for (0..document.records.len) |index| {
        const node = document.node(@enumFromInt(index)).?;
        const record = node.record();
        try expect(record.span.len != 0);
        try expect(record.span.endOffset() <= document.source.len);
        try expect(record.subtree_end > index and record.subtree_end <= document.records.len);
        if (node.state() == .partial) {
            try equal(markup.Completeness.partial, document.state);
            try equal(markup.NodeKind.element, node.kind());
            try equal(document.retained_end, @as(u32, @intCast(record.span.endOffset())));
        }
        if (node.content()) |body| try expect(body.len <= node.raw().len);
        var attributes = node.attributes();
        while (attributes.next()) |a| {
            try expect(a.span().start >= record.span.start);
            try expect(a.span().endOffset() <= record.span.endOffset());
            _ = a.value();
        }
        var children = node.children();
        var count: usize = 0;
        while (children.next()) |child| {
            count += 1;
            try expect(count <= document.records.len);
            try expect(@intFromEnum(child.id) > index);
            try expect(child.record().subtree_end <= record.subtree_end);
        }
    }
    var roots = document.roots();
    var end: u32 = 0;
    while (roots.next()) |root| {
        try equal(end, @intFromEnum(root.id));
        end = root.record().subtree_end;
    }
    try equal(document.nodeCount(), end);
}

test "partial markup keeps completed children and attributes in unfinished containers" {
    const source = "<root a='1'><done/>text<child x='ok' y=\"unfinished";
    var parsed = Keep.parseBorrowed(allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.invalid_syntax, parsed.outcome);
    const doc = parsed.document.?;
    try equal(markup.Completeness.partial, doc.state);
    try expect(!doc.scopeComplete() and !doc.subtreeComplete());
    try audit(doc);
    try equal(@as(u32, 4), doc.nodeCount());
    const root = doc.node(@enumFromInt(0)).?;
    try expect(!root.scopeComplete() and root.headerComplete().?);
    try expect(doc.node(@enumFromInt(1)).?.subtreeComplete());
    try expect(doc.node(@enumFromInt(2)).?.scopeComplete());
    const child = doc.node(@enumFromInt(3)).?;
    try expect(!child.scopeComplete() and !child.headerComplete().?);
    var attrs = child.attributes();
    try strings("ok", attrs.next().?.value());
    try expect(attrs.next() == null);
    try strings(" y=\"unfinished", doc.unrepresented().?.slice(source));
    try equal(@as(usize, 20), @sizeOf(markup.Node));
    try equal(@as(usize, 20), @sizeOf(markup.Attribute));
}

test "unterminated markup comments CDATA and quotes leave the ambiguous tail raw" {
    for ([_][]const u8{ "<!-- <fake/>", "<![CDATA[<fake/>", "<child x='text <fake/>" }) |tail| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, "<root><done/>");
        try source.appendSlice(allocator, tail);
        var parsed = Keep.parseBorrowed(allocator, source.items, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try audit(parsed.document.?);
        for (parsed.document.?.records) |record| try expect(!std.mem.eql(u8, "fake", record.name.slice(source.items)));
        try expect(parsed.document.?.unrepresented().?.len != 0);
    }
}

test "complete representation differs from validity and valid empty input" {
    var complete = try Keep.parseAndValidate(allocator, .{ .bytes = "<a x='1' x='2'/>", .origin = 0 }, discard, .{});
    defer complete.deinit();
    try equal(markup.Completeness.complete, complete.parse.document.?.state);
    try expect(complete.parse.document.?.subtreeComplete());
    try expect(!complete.documentValid());
    var empty = Keep.parseBorrowed(allocator, "", discard, .{});
    defer empty.deinit();
    try equal(markup.Completeness.complete, empty.document.?.state);
    try expect(empty.document.?.unrepresented() == null);
    var missing = Keep.parseBorrowed(allocator, "<a>", discard, .{});
    defer missing.deinit();
    try equal(@as(u32, 0), missing.document.?.unrepresented().?.len);
    try expect(!missing.document.?.node(@enumFromInt(0)).?.scopeComplete());
}

test "partial retention does not change recovery outcomes findings or counters" {
    const Runtime = markup.Profile(.{ .runtime_policy = true });
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .collect, .fail_fast }) |on_error| {
        const P = markup.Profile(.{ .policy = .{ .mode = .structural, .scanner = scanner, .on_error = on_error, .retention = .{ .partial = true } } });
        const Off = markup.Profile(.{ .policy = .{ .mode = .structural, .scanner = scanner, .on_error = on_error } });
        for ([_][]const u8{ "<a x='1' x='2'><b/></wrong><later/>", "<a x=0/><later/>", "<a>&bare </a>", "<!bad", "<a/><b>", "<a/>", "" }) |source| {
            var a: markup.FixedDiagnosticBag(32) = .{};
            var b: markup.FixedDiagnosticBag(32) = .{};
            var kept = P.parseBorrowed(allocator, source, a.sink(), .{});
            defer kept.deinit();
            var plain = Off.parseBorrowed(allocator, source, b.sink(), .{});
            defer plain.deinit();
            try deep(plain.outcome, kept.outcome);
            try equal(plain.completion, kept.completion);
            try deep(plain.counts, kept.counts);
            try equal(plain.syntax_errors, kept.syntax_errors);
            try deep(a.items(), b.items());
            if (kept.outcome != .success) try expect(plain.document == null);
            try audit(kept.document.?);
            var nodes: markup.FixedDocumentStorage(.{ .nodes = 32, .attributes = 16 }) = .{};
            var frames: markup.FixedParseScratch(16) = .{};
            const dynamic = Runtime.parseBorrowedIn(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, discard, .{ .policy = .{ .mode = .structural, .scanner = scanner, .on_error = on_error, .retention = .{ .partial = true } } });
            try deep(kept.document, dynamic.document);
        }
    };
    var recovered = Keep.parseBorrowed(allocator, "<a x=0/><later/>", discard, .{});
    defer recovered.deinit();
    try equal(markup.Completion.complete, recovered.completion);
    try equal(@as(u32, 1), recovered.document.?.nodeCount()); // Prefix only, even after recovery.
    try equal(markup.Completeness.partial, recovered.document.?.state);
}

test "every truncation is safe across scanners metering and cancellation" {
    const source = "<root a='1' b=\"2\"><a/>text<!--comment--><b><![CDATA[x]]></b></root>";
    inline for (.{ .scalar, .block }) |scanner| {
        const Bounded = markup.Profile(.{ .policy = .{ .mode = .structural, .scanner = scanner, .retention = .{ .partial = true }, .execution = .{ .metering = true } } });
        for (0..source.len + 1) |length| {
            const bytes = source[0..length];
            var parsed = Keep.parseBorrowed(allocator, bytes, discard, .{});
            defer parsed.deinit();
            try audit(parsed.document.?);
            var nodes: markup.FixedDocumentStorage(.{ .nodes = 32, .attributes = 8 }) = .{};
            var frames: markup.FixedParseScratch(16) = .{};
            const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
            var session = Bounded.Session.init(bytes, memory, discard, .{});
            defer session.deinit();
            var steps: u32 = 0;
            while (session.result() == null) {
                try expect(session.advance(1).work_used <= 1);
                steps += 1;
                try expect(steps < 1000);
            }
            try deep(parsed.outcome, session.result().?.outcome);
            try deep(parsed.document, session.result().?.document);
        }
        // Freeze at every work boundary, including between header events and
        // stack changes. Cancellation must not need a finalization walk.
        for (0..300) |stop| {
            var nodes: markup.FixedDocumentStorage(.{ .nodes = 32, .attributes = 8 }) = .{};
            var frames: markup.FixedParseScratch(16) = .{};
            var session = Bounded.Session.init(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, discard, .{});
            defer session.deinit();
            for (0..stop) |_| _ = session.advance(1);
            const stopped = session.cancel();
            if (stopped.document) |doc| try audit(doc);
            try deep(stopped, session.cancel());
            session.reset("<ok/>", discard, .{});
            try equal(markup.Completeness.complete, session.run().document.?.state);
        }
    }
}

test "partial validation checks retained attributes but never certifies missing coverage" {
    const source = "<a x='1' x='2'><b/>";
    var parsed = Keep.parseBorrowed(allocator, source, discard, .{});
    defer parsed.deinit();
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const checked = Keep.validate(allocator, &parsed.document.?, bag.sink(), .{});
    try equal(@as(u64, 1), checked.errors);
    try equal(@as(u32, source.len), checked.completion.incomplete);
    try equal(.incomplete, checked.checks.duplicate_attribute);
    try equal(.invalid, checked.validity);
    const Off = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = .off } } });
    const skipped = Off.validateIn(&parsed.document.?, .{}, discard, .{});
    try equal(.unknown, skipped.validity);
    try expect(skipped.completion == .incomplete);
    const Encoding = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .invalid_utf8 = .err, .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
    var malformed = Keep.parseBorrowed(allocator, "<a x='1' x='2' y='\xff", discard, .{});
    defer malformed.deinit();
    const known = Encoding.validate(allocator, &malformed.document.?, discard, .{});
    try equal(@as(u64, 1), known.errors); // Unknown value's invalid byte wasn't visited.
    try equal(.incomplete, known.checks.invalid_utf8);
    var composed = try Keep.parseAndValidate(allocator, .{ .bytes = source, .origin = 100 }, discard, .{});
    defer composed.deinit();
    try expect(!composed.documentValid());
    try equal(@as(u64, 1), composed.validation.?.errors);
    try equal(markup.Completeness.partial, composed.parse.document.?.state);
}

fn allocationCase(gpa: std.mem.Allocator, source: []const u8) !void {
    var parsed = Keep.parseBorrowed(gpa, source, discard, .{});
    defer parsed.deinit();
    if (parsed.document) |doc| try audit(doc);
    if (parsed.outcome == .out_of_memory) return error.OutOfMemory;
}
test "allocation failure and exhausted fixed pools preserve only consistent records" {
    for ([_][]const u8{ "<a x='1'><b/>text<c y='2'/></a>", "<a x='1'><b/>text<c y='2' z='", "<a x='1' x='2'><b/></wrong>" }) |source| {
        try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{source});
        for (0..6) |capacity| for (0..3) |attrs| for (0..3) |depth| {
            var nodes: [6]markup.Node = undefined;
            var attributes: [3]markup.Attribute = undefined;
            var frames: markup.FixedParseScratch(3) = .{};
            const parsed = Keep.parseBorrowedIn(source, .{ .document = .{ .nodes = nodes[0..capacity], .attributes = attributes[0..attrs] }, .scratch = .{ .frames = frames.frames[0..depth] } }, discard, .{});
            if (parsed.document) |doc| try audit(doc);
        };
    }
}

test "workspace and runtime overrides reset partial state without retaining old source" {
    const Runtime = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .structural, .retention = .{ .partial = true } } });
    var workspace = Runtime.prepare(.{}).initWorkspace(allocator, .{});
    defer workspace.deinit();
    const bad = try workspace.parseAndValidate(.{ .bytes = "<a x='1' x='2'>", .origin = 0 }, discard);
    try equal(markup.Completeness.partial, bad.parse.document.?.state);
    try equal(@as(u64, 1), bad.validation.?.errors);
    const good = try workspace.parseAndValidate(.{ .bytes = "<ok/>", .origin = 0 }, discard);
    try expect(good.documentValid());
    try strings("<ok/>", good.parse.document.?.source);
    var off = Runtime.parseBorrowed(allocator, "<a>", discard, .{ .policy = .{ .retention = .{ .partial = false } } });
    defer off.deinit();
    try expect(off.document == null);
    inline for (.{ markup.presets.standard, markup.presets.untrusted }) |preset| {
        var reset = Runtime.parseBorrowed(allocator, "<a>", discard, .{ .policy = preset });
        defer reset.deinit();
        try expect(reset.document == null);
    }
    var pools: markup.FixedDocumentStorage(.{ .nodes = 4 }) = .{};
    var frames: markup.FixedParseScratch(4) = .{};
    var session = Runtime.Session.init("<a>", .{ .document = pools.storage(), .scratch = frames.storage() }, discard, .{});
    defer session.deinit();
    try equal(markup.Completeness.partial, session.run().document.?.state);
    session.reset("<b>", discard, .{ .policy = .{ .retention = .{ .partial = false } } });
    try expect(session.run().document == null);
}

test "partial prefixes survive sink stops and source limits never fabricate a started tree" {
    var bag: markup.FixedDiagnosticBag(1) = .{};
    var parsed = Keep.parseBorrowed(allocator, "<root><a/></wrong><later/>", bag.sink(), .{});
    defer parsed.deinit();
    try expect(parsed.diagnostic_stop != null);
    try equal(markup.Completeness.partial, parsed.document.?.state);
    try equal(@as(u32, 2), parsed.document.?.nodeCount());
    try audit(parsed.document.?);
    const Failure = struct {
        fn emit(_: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            return error.DiagnosticSinkFailure;
        }
    };
    var failed = try Keep.parseAndValidate(allocator, .{ .bytes = "<a x='1' x='2'></wrong>", .origin = 0 }, .{ .context = null, .emit_fn = Failure.emit }, .{});
    defer failed.deinit();
    try equal(markup.reporting.Delivery.failed, failed.parse.diagnostic_delivery);
    try expect(failed.validation == null);
    try audit(failed.parse.document.?);
    const Limited = markup.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .limits = .{ .max_source_bytes = 0 } } });
    var limited = Limited.parseBorrowed(allocator, "<a>", discard, .{});
    defer limited.deinit();
    try expect(limited.document == null);
}

test "partial parser and validation differential over generated byte inputs" {
    const Block = markup.Profile(.{ .policy = .{ .mode = .structural, .scanner = .block, .retention = .{ .partial = true } } });
    const Checks = markup.Profile(.{ .policy = .{ .validation = .{ .invalid_utf8 = .err, .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
    var rng = std.Random.DefaultPrng.init(0x7061727469616c);
    const alphabet = "abc01 <>&;/!?[]-='\"\r\n\x00\xff";
    var bytes: [96]u8 = undefined;
    for (0..10_000) |_| {
        const len = rng.random().uintLessThan(usize, bytes.len);
        for (bytes[0..len]) |*byte| byte.* = alphabet[rng.random().uintLessThan(usize, alphabet.len)];
        const source = bytes[0..len];
        var scalar = Keep.parseBorrowed(allocator, source, discard, .{});
        defer scalar.deinit();
        var block = Block.parseBorrowed(allocator, source, discard, .{});
        defer block.deinit();
        var plain = Plain.parseBorrowed(allocator, source, discard, .{});
        defer plain.deinit();
        try deep(scalar.outcome, block.outcome);
        try deep(scalar.outcome, plain.outcome);
        try deep(scalar.counts, plain.counts);
        try deep(scalar.document, block.document);
        if (scalar.document) |doc| {
            try audit(doc);
            var keys: markup.FixedValidationScratch(32) = .{};
            const checked = Checks.validateIn(&doc, keys.storage(), discard, .{});
            if (doc.state == .partial) {
                try expect(checked.completion == .incomplete);
                try expect(checked.validity != .valid);
            }
        }
    }
}
