//! Structural slice 3, through the standalone consumer API only.
const std = @import("std");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const strings = std.testing.expectEqualStrings;
const discard = markup.diagnostic.discard;
const Storage = markup.FixedDocumentStorage(.{ .nodes = 32, .attributes = 16 });
const Scratch = markup.FixedParseScratch(8);

test "references stay in contiguous text and attribute spans without expansion or lookup" {
    const source = "&unknown;&amp;&#65;&#x1F600;<a x='&lt;&#x22;&custom;'/>&tail;";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    try equal(markup.Counts{ .nodes = 3, .elements = 1, .attributes = 1, .max_depth = 1 }, parsed.counts);
    try equal(@as(u32, 0), parsed.accepted_deviations);
    var roots = parsed.document.?.roots();
    const text = roots.next().?;
    try equal(markup.NodeKind.text, text.kind());
    try strings("&unknown;&amp;&#65;&#x1F600;", text.content().?);
    const element = roots.next().?;
    try expect(element.content() == null);
    var attributes = element.attributes();
    try strings("&lt;&#x22;&custom;", attributes.next().?.value());
    try strings("&tail;", roots.next().?.raw());

    for ([_][]const u8{
        "&#9;&#10;&#13;&#32;&#55295;&#57344;&#65533;&#65536;&#1114111;",
        "&#x9;&#xA;&#xd;&#x20;&#xD7FF;&#xE000;&#xFFFD;&#x10000;&#x10FFFF;",
        "&#000000000000000000000000065;&#x000000000000000000000041;",
        "&_:name-1.2;&東京;&\xff;",
    }) |source_case| {
        try equal(markup.Outcome.success, markup.measureIn(source_case, .{}, discard, .{}).outcome);
    }
}

test "comments and CDATA retain leaf identity, raw delimiters and exact bodies" {
    const source = "<!----><a>text<!-- <x>&bad --> <![CDATA[<x>&bad]]]>tail</a><![CDATA[]]><b x='1' x='2'/>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    try equal(@as(usize, 20), @sizeOf(markup.Node));
    try equal(markup.Counts{ .nodes = 9, .elements = 2, .attributes = 2, .max_depth = 1 }, parsed.counts);
    var roots = parsed.document.?.roots();
    const empty_comment = roots.next().?;
    try equal(markup.NodeKind.comment, empty_comment.kind());
    try strings("<!---->", empty_comment.raw());
    try strings("", empty_comment.content().?);
    try expect(empty_comment.name() == null);
    var children = roots.next().?.children();
    try strings("text", children.next().?.content().?);
    const comment = children.next().?;
    try equal(markup.NodeKind.comment, comment.kind());
    try strings(" <x>&bad ", comment.content().?);
    try strings(" ", children.next().?.raw());
    const cdata = children.next().?;
    try equal(markup.NodeKind.cdata, cdata.kind());
    try strings("<x>&bad]", cdata.content().?);
    var cdata_children = cdata.children();
    try expect(cdata_children.next() == null);
    try strings("tail", children.next().?.content().?);
    try expect(children.next() == null);
    try strings("", roots.next().?.content().?);
    const element = roots.next().?;
    var attributes = element.attributes();
    try strings("1", attributes.next().?.value());
    try strings("2", attributes.next().?.value());
    try expect(roots.next() == null);
    var keys: markup.FixedValidationScratch(2) = .{};
    var doc = parsed.document.?;
    const checked = markup.validateIn(&doc, keys.storage(), discard, .{});
    try equal(@as(u32, 1), checked.errors);
}

test "malformed reference policy has fixed runtime measured and bounded parity" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    const invalid = [_][]const u8{
        "&",          "&;",                            "&name", "&#",    "&#;",   "&#x",      "&#x;",     "&#X41;",   "&#-1;",
        "&#0;",       "&#8;",                          "&#11;", "&#12;", "&#31;", "&#xD800;", "&#xDFFF;", "&#xFFFE;", "&#xFFFF;",
        "&#x110000;", "&#99999999999999999999999999;",
    };
    inline for (.{ .reject, .warn, .accept }) |acceptance| {
        const input: markup.Policy = .{ .syntax = .{ .malformed_reference = acceptance }, .execution = .{ .metering = true } };
        const Fixed = markup.Profile(.{ .policy = input });
        try equal(markup.PolicyValidation.valid, Fixed.validatePolicy(.{}));
        for (invalid) |fragment| {
            // A following tag / matching attribute quote must retain its meaning.
            inline for (.{ false, true }) |attribute| {
                const wrapped = try std.fmt.allocPrint(std.testing.allocator, if (attribute) "<a x='{s}'/>" else "{s}<b/>", .{fragment});
                defer std.testing.allocator.free(wrapped);
                var a: markup.FixedDiagnosticBag(8) = .{};
                var b: markup.FixedDiagnosticBag(8) = .{};
                var parsed = Fixed.parseBorrowed(std.testing.allocator, wrapped, a.sink(), .{});
                defer parsed.deinit();
                var storage: Storage = .{};
                var scratch: Scratch = .{};
                var session = Dynamic.Session.init(wrapped, .{ .document = storage.storage(), .scratch = scratch.storage() }, b.sink(), .{ .policy = input });
                defer session.deinit();
                var work: u64 = 0;
                while (session.result() == null) {
                    const progress = try session.advance(1);
                    work += progress.work_used;
                    try expect(work <= wrapped.len * 12 + 32);
                    try equal(@as(u32, 1), progress.work_used);
                }
                const got = session.result().?;
                const expected: markup.Outcome = if (acceptance == .reject) .invalid_syntax else .success;
                try equal(expected, parsed.outcome);
                try equal(expected, got.outcome);
                try equal(parsed.counts, got.counts);
                try equal(@as(u32, if (acceptance == .reject) 0 else 1), got.accepted_deviations);
                try equal(@as(u32, if (acceptance == .warn) 1 else 0), got.warnings);
                try equal(parsed.accepted_deviations, got.accepted_deviations);
                try equal(parsed.warnings, got.warnings);
                try deep(a.items(), b.items());
                try equal(@as(usize, if (acceptance == .accept) 0 else 1), b.items().len);
                if (got.document) |doc| {
                    try deep(parsed.document.?.records, doc.records);
                    try deep(parsed.document.?.attributes, doc.attributes);
                    try strings(wrapped, doc.source);
                }
                const measured = Fixed.measureIn(wrapped, scratch.storage(), discard, .{});
                try equal(got.outcome, measured.outcome);
                try equal(got.counts, measured.counts);
                try equal(got.accepted_deviations, measured.accepted_deviations);
                try equal(got.warnings, measured.warnings);
            }
        }
    }
}

test "reference findings have exact candidate spans and do not consume boundaries" {
    const Warn = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn } } });
    const source = "&bad<a x='&#x'/> &; &amp &other; &#xD800;";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    var parsed = Warn.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    try equal(@as(u32, 5), parsed.accepted_deviations);
    try equal(@as(u32, 5), parsed.warnings);
    const spans = [_][]const u8{ "&bad", "&#x", "&", "&amp", "&#xD800;" };
    const reasons = [_]markup.diagnostic.ReferenceProblem{ .missing_semicolon, .missing_digits, .missing_name, .missing_semicolon, .invalid_character };
    for (bag.items(), spans, reasons) |finding, expected, reason| {
        try strings(expected, finding.span.slice(source));
        try equal(reason, finding.details.reference);
        try equal(markup.diagnostic.Code.malformed_reference_tolerated, finding.code);
    }
    // Every '&' is its own finding; the second one starts a real named reference.
    try equal(@as(u32, 1), Warn.measureIn("&&valid;", .{}, discard, .{}).warnings);
    try equal(@as(u32, 3), Warn.measureIn("&&&", .{}, discard, .{}).warnings);
    try equal(@as(u32, 1), Warn.measureIn("&unterminated", .{}, discard, .{}).warnings);
    var strict = markup.lexer.Lexer.init("&broken<a/>");
    const first = strict.next();
    try equal(markup.diagnostic.Code.malformed_reference, first.problem.diagnostic.code);
    try deep(first, strict.next());
}

test "warnings stop on sink request or delivery failure without publishing a document" {
    const Warn = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn } } });
    const Accept = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept } } });
    var bag: markup.FixedDiagnosticBag(1) = .{};
    var storage: Storage = .{};
    const memory: markup.ParseMemory = .{ .document = storage.storage() };
    const stopped = Warn.parseBorrowedIn("&; &;", memory, bag.sink(), .{});
    try equal(markup.Outcome{ .diagnostic_stopped = .requested }, stopped.outcome);
    try expect(stopped.document == null);
    try equal(markup.reporting.Delivery.complete, stopped.diagnostic_delivery);
    try equal(@as(u32, 1), stopped.warnings);
    try equal(@as(u32, 1), stopped.accepted_deviations);
    var empty: markup.FixedDiagnosticBag(0) = .{};
    const failed = Warn.parseBorrowedIn("&;", memory, empty.sink(), .{});
    try equal(markup.Outcome{ .diagnostic_stopped = .capacity }, failed.outcome);
    try equal(markup.reporting.Delivery.failed, failed.diagnostic_delivery);
    try equal(@as(u32, 1), failed.warnings);
    try expect(failed.document == null);
    const silent = Accept.parseBorrowedIn("&; &;", memory, empty.sink(), .{});
    try equal(markup.Outcome.success, silent.outcome);
    try equal(@as(u32, 2), silent.accepted_deviations);
    try equal(@as(u32, 0), silent.warnings);
    const rejected = markup.parseBorrowedIn("&;", memory, empty.sink(), .{});
    try equal(markup.Outcome.invalid_syntax, rejected.outcome);
    try equal(markup.reporting.Delivery.failed, rejected.diagnostic_delivery);
    const Reject = struct {
        cause: markup.reporting.SinkError,
        calls: u32 = 0,
        fn emit(context: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return self.cause;
        }
    };
    for ([_]markup.reporting.SinkError{ error.DiagnosticSinkFailure, error.OutOfMemory, error.DiagnosticCapacityExceeded }) |cause| {
        var sink: Reject = .{ .cause = cause };
        var session = Warn.Session.init("&; &;", memory, .{ .context = &sink, .emit_fn = Reject.emit }, .{});
        const result = session.run();
        try equal(markup.Outcome{ .diagnostic_stopped = .fromError(cause) }, result.outcome);
        try equal(markup.reporting.Delivery.failed, result.diagnostic_delivery);
        try equal(@as(u32, 1), result.warnings);
        try equal(@as(u32, 1), result.accepted_deviations);
        try expect(result.document == null);
        try deep(result, session.run());
        try deep(result, session.cancel());
        try equal(@as(u32, 1), sink.calls);
    }
    // A tolerated ampersand cannot repair an unfinished value or a literal '<'.
    for ([_][]const u8{ "<a x='&bad", "<a x='&bad<b/>'/>", "&bad\x00", "<!--&;--x>", "<![CDATA[&;" }) |source| {
        const parsed = Warn.parseBorrowedIn(source, memory, discard, .{});
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try expect(parsed.document == null);
    }
}

test "one tolerated reference distinguishes full-bag stopping from continuing sinks" {
    const Warn = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn } } });
    var fixed: markup.FixedDiagnosticBag(1) = .{};
    const stopped = Warn.measureIn("a & b", .{}, fixed.sink(), .{});
    try equal(markup.Outcome{ .diagnostic_stopped = .requested }, stopped.outcome);
    try equal(markup.reporting.Delivery.complete, stopped.diagnostic_delivery);
    try equal(@as(usize, 1), fixed.items().len);
    try equal(@as(u32, 1), stopped.warnings);
    var growing = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer growing.deinit();
    var omitted: markup.reporting.FixedBag(markup.Diagnostic, 1, .omit) = .{};
    for ([_]markup.DiagnosticSink{ growing.sink(), omitted.sink(), discard }) |sink| {
        const complete = Warn.measureIn("a & b", .{}, sink, .{});
        try equal(markup.Outcome.success, complete.outcome);
        try equal(@as(u32, 1), complete.counts.nodes);
        try equal(@as(u32, 1), complete.accepted_deviations);
        try equal(@as(u32, 1), complete.warnings);
    }
    try equal(@as(u64, 0), omitted.omitted);
}

test "fixed reference policy omits unused settings and counter state" {
    const Strict = @FieldType(@FieldType(markup.Profile(.{}).Session, "inner"), "machine");
    const Silent = @FieldType(@FieldType(markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept } } }).Session, "inner"), "machine");
    const Warning = @FieldType(@FieldType(markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn } } }).Session, "inner"), "machine");
    try expect(@FieldType(Strict, "settings") == void);
    try expect(@FieldType(Strict, "deviations") == void);
    try expect(@FieldType(Strict, "warnings") == void);
    try expect(@FieldType(Silent, "deviations") == u32);
    try expect(@FieldType(Silent, "warnings") == void);
    try expect(@FieldType(Warning, "deviations") == u32);
    try expect(@FieldType(Warning, "warnings") == u32);
}

test "comment and CDATA boundaries reject malformed syntax and count against node limits" {
    for ([_][]const u8{ "<!", "<!-", "<!--", "<!--x-", "<!--x--", "<!--x--y-->", "<!--x--->", "<!--<!--x-->", "<![", "<![C", "<![cdata[x]]>", "<![CDATA[", "<![CDATA[x]]", "<!--\x00-->", "<![CDATA[\x01]]>" }) |source| {
        var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try expect(parsed.document == null);
    }
    const Limit = markup.Profile(.{ .policy = .{ .limits = .{ .max_nodes = 1, .max_nesting = 0 } } });
    var storage: Storage = .{};
    for ([_][]const u8{ "<!---->", "<![CDATA[]]>" }) |source| {
        const parsed = Limit.parseBorrowedIn(source, .{ .document = storage.storage() }, discard, .{});
        try equal(markup.Outcome.success, parsed.outcome);
        try equal(markup.Counts{ .nodes = 1 }, parsed.counts);
        try equal(markup.Outcome{ .storage_exhausted = .node_pool }, Limit.parseBorrowedIn(source, .{}, discard, .{}).outcome);
    }
    try equal(markup.Outcome{ .resource_limit = .{ .resource = .nodes, .limit = 1 } }, Limit.parseBorrowedIn("<!----><![CDATA[]]>", .{ .document = storage.storage() }, discard, .{}).outcome);
}

test "content lexer tokens and unfinished delimiters have precise spans and expectations" {
    const source = "&amp;<!--x--><![CDATA[y]]><a/>";
    var cursor = markup.lexer.Lexer.init(source);
    inline for (.{ .text, .comment, .cdata, .empty, .eof }) |kind| {
        const token = cursor.next().token;
        try equal(kind, token.kind);
        try expect(token.span.endOffset() <= source.len);
    }
    for ([_]struct { source: []const u8, expected: markup.diagnostic.Expected }{
        .{ .source = "<!", .expected = .declaration_start },
        .{ .source = "<!-", .expected = .comment_start },
        .{ .source = "<!--x-", .expected = .comment_end },
        .{ .source = "<!--x--", .expected = .comment_end },
        .{ .source = "<![C", .expected = .cdata_start },
        .{ .source = "<![CDATA[x]]", .expected = .cdata_end },
    }) |case| {
        var lexer = markup.lexer.Lexer.init(case.source);
        const item = lexer.next();
        try equal(markup.diagnostic.Code.unexpected_end, item.problem.diagnostic.code);
        try equal(case.expected, item.problem.diagnostic.details.expected);
        try equal(markup.location.Span{ .start = @intCast(case.source.len), .len = 0 }, item.problem.diagnostic.span);
        try deep(item, lexer.next());
    }
}

test "warning bag allocation failure releases partially built owned markup" {
    const Warn = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn } } });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var bag = markup.GrowableDiagnosticBag.init(failing.allocator(), .{});
    defer bag.deinit();
    var parsed = Warn.parseBorrowed(std.testing.allocator, "<a x='&;'/>tail", bag.sink(), .{});
    defer parsed.deinit();
    try equal(markup.Outcome{ .diagnostic_stopped = .out_of_memory }, parsed.outcome);
    try equal(markup.reporting.Delivery.failed, parsed.diagnostic_delivery);
    try expect(parsed.document == null);
    try equal(@as(usize, 0), parsed.retainedBytes());
    try equal(@as(u32, 1), parsed.counts.nodes); // Prefix event before warning failure.
    try equal(@as(u32, 1), parsed.accepted_deviations);
    try equal(@as(u32, 1), parsed.warnings);
}

fn partition(comptime acceptance: markup.Acceptance, source: []const u8) !void {
    const P = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = acceptance }, .execution = .{ .metering = true } } });
    var nodes: Storage = .{};
    var frames: Scratch = .{};
    var bag: markup.FixedDiagnosticBag(256) = .{};
    const reference = P.parseBorrowedIn(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, bag.sink(), .{});
    var total: ?u64 = null;
    for ([_]u32{ 1, 7, 128 }) |budget| {
        var other: Storage = .{};
        var other_frames: Scratch = .{};
        var other_bag: markup.FixedDiagnosticBag(256) = .{};
        var session = P.Session.init(source, .{ .document = other.storage(), .scratch = other_frames.storage() }, other_bag.sink(), .{});
        defer session.deinit();
        try equal(@as(u32, 0), session.advance(0).work_used);
        var work: u64 = 0;
        var frontier: u32 = 0;
        while (session.result() == null) {
            const progress = session.advance(budget);
            try expect(progress.work_used <= budget);
            try expect(progress.source_frontier >= frontier and progress.source_frontier <= source.len);
            frontier = progress.source_frontier;
            work += progress.work_used;
            try expect(work <= @as(u64, source.len) * 12 + 32);
        }
        if (total) |previous| try equal(previous, work) else total = work;
        const got = session.result().?;
        try equal(reference.outcome, got.outcome);
        try equal(reference.counts, got.counts);
        try equal(reference.accepted_deviations, got.accepted_deviations);
        try equal(reference.warnings, got.warnings);
        try deep(bag.items(), other_bag.items());
        if (reference.document) |document| {
            try deep(document.records, got.document.?.records);
            try deep(document.attributes, got.document.?.attributes);
        }
        try deep(got, session.cancel());
        try deep(got, session.run());
        try equal(@as(u32, 0), session.advance(1).work_used);
    }
}

test "every content prefix and arbitrary bytes preserve policy and budget partitions" {
    const source = "<!--a-b--><a x='&unknown;&#x41;&bad'><![CDATA[x]]]]>&bad<b/>text&#999999999999;&;</a>&";
    inline for (.{ .reject, .warn, .accept }) |acceptance| {
        for (0..source.len + 1) |end| try partition(acceptance, source[0..end]);
        var random = std.Random.DefaultPrng.init(0x5245464344415441);
        var bytes: [96]u8 = undefined;
        const alphabet = "<>/aAb: _.19-\r\n\t&!?=\"'[]#;xCDAT\xff\x00";
        for (0..500) |_| {
            const len = random.random().uintLessThan(usize, bytes.len + 1);
            for (bytes[0..len]) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            try partition(acceptance, bytes[0..len]);
        }
    }
}

test "long references comments and CDATA keep bounded linear work and constant storage" {
    const length = 32_768;
    const bytes = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(bytes);
    inline for (.{ "<!--{s}-->", "<![CDATA[{s}]]>", "&{s};", "&#{s};", "&#x{s};", "<a x='&#{s}'/>" }) |format| {
        @memset(bytes, if (comptime std.mem.startsWith(u8, format, "&{") or std.mem.startsWith(u8, format, "<!--")) 'a' else '9');
        const source = try std.fmt.allocPrint(std.testing.allocator, format, .{bytes});
        defer std.testing.allocator.free(source);
        inline for (.{ .reject, .warn, .accept }) |acceptance| try partition(acceptance, source);
    }
}

test "runtime reference policy is latched and reset inherits the compiled baseline" {
    const P = markup.Profile(.{ .runtime_policy = true, .policy = .{ .syntax = .{ .malformed_reference = .warn }, .execution = .{ .metering = true } } });
    var storage: Storage = .{};
    var options: P.Options = .{};
    var session = P.Session.init("&;", .{ .document = storage.storage() }, discard, options);
    defer session.deinit();
    _ = try session.advance(1);
    options.policy.syntax.malformed_reference = .reject;
    while ((try session.advance(1)).outcome == null) {}
    try equal(@as(u32, 1), session.result().?.warnings);
    session.reset("&;", discard, options);
    try equal(markup.Outcome.invalid_syntax, session.run().outcome);
    try equal(@as(u32, 0), session.result().?.warnings);
    session.reset("&;", discard, .{ .policy = .{ .syntax = .{ .malformed_reference = .accept }, .execution = .{ .metering = false } } });
    try equal(@as(u32, 1), session.run().accepted_deviations);
    try equal(@as(u32, 0), session.result().?.warnings);
    session.reset("&;", discard, .{});
    try equal(@as(u32, 1), session.run().warnings);
    session.reset("&;", discard, .{ .policy = markup.presets.standard });
    try equal(markup.Outcome.invalid_syntax, session.run().outcome);
}

test "cancellation and relocation work inside each new scanner state" {
    const Stop = struct {
        calls: u32 = 0,
        after: u32,
        fn requested(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return self.calls > self.after;
        }
    };
    const P = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn }, .execution = .{ .metering = true, .cancellation = true } } });
    const source = "<!--x-y--><![CDATA[a]]]]><a x='&#x41;&bad'>&amp;&#65;&;</a>";
    var reached_success = false;
    for (0..source.len * 12 + 32) |after| {
        var storage: Storage = .{};
        var scratch: Scratch = .{};
        var stop: Stop = .{ .after = @intCast(after) };
        var first = P.Session.init(source, .{ .document = storage.storage(), .scratch = scratch.storage() }, discard, .{ .cancellation = .{ .context = &stop, .is_requested = Stop.requested } });
        _ = first.advance(3);
        var moved = first;
        const got = moved.run();
        try expect(got.outcome == .success or got.outcome == .cancelled);
        if (got.outcome == .cancelled) try expect(got.document == null) else reached_success = true;
        const polls = stop.calls;
        try deep(got, moved.cancel());
        try deep(got, moved.run());
        try equal(@as(u32, 0), moved.advance(1).work_used);
        try equal(polls, stop.calls);
        if (reached_success) break;
    }
    try expect(reached_success);
}
