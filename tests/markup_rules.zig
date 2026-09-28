//! Optional name rules and reference catalogs must not define the base grammar.
const std = @import("std");
const markup = @import("markup_parser");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const discard = markup.diagnostic.discard;
const Names = markup.Profile(.{ .policy = .{ .validation = .{
    .duplicate_attribute = .off,
    .names = .{ .rule = .xml_1_0, .severity = .err },
} } });
const References = markup.Profile(.{ .policy = .{ .validation = .{
    .duplicate_attribute = .off,
    .references = .{ .catalog = .xml_predefined, .severity = .err },
} } });

test "name rules and catalogs are independent, opt-in, and do not change retained storage" {
    const source = "<\xff custom='&nbsp;'>\xff</\xff>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    const doc = parsed.document.?;
    const bytes = parsed.retainedBytes();
    const ordinary = markup.validateIn(&doc, .{}, discard, .{});
    try equal(.valid, ordinary.validity);
    try equal(.not_run, ordinary.checks.names);
    try equal(.not_run, ordinary.checks.references);
    const names = Names.validate(std.testing.failing_allocator, &doc, discard, .{});
    try equal(.complete, names.completion);
    try equal(@as(u64, 1), names.errors); // Opening/closing name is checked once.
    try equal(.not_run, names.checks.references);
    try equal(.not_run, names.checks.invalid_utf8);
    const refs = References.validate(std.testing.failing_allocator, &doc, discard, .{});
    try equal(.complete, refs.completion);
    try equal(@as(u64, 1), refs.errors);
    try equal(.not_run, refs.checks.names);
    try expect(doc.source.ptr == source.ptr);
    try std.testing.expectEqualStrings(source, doc.source);
    try equal(bytes, parsed.retainedBytes());
    try equal(@as(usize, 20), @sizeOf(markup.Node));
    try equal(@as(usize, 20), @sizeOf(markup.Attribute));
    try equal(@as(usize, 36), @sizeOf(markup.Diagnostic));
    try equal(@sizeOf(markup.Profile(.{}).Session), @sizeOf(Names.Session));
}

test "XML names accept Unicode ranges and literal colons without normalization or namespaces" {
    const source = "<東京 café='yes' a:b:c='yes' a·='yes' a\u{0300}='yes'><\u{10000}/><\u{effff}/></東京>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    const checked = Names.validateIn(&parsed.document.?, .{}, discard, .{});
    try equal(.complete, checked.completion);
    try equal(.valid, checked.validity);
    try equal(@as(u64, 0), checked.errors);
    // No normalization makes canonically equivalent attribute spellings duplicates.
    var distinct = markup.parseBorrowed(std.testing.allocator, "<x é='1' e\u{0301}='2'/>", discard, .{});
    defer distinct.deinit();
    var keys: markup.FixedValidationScratch(2) = .{};
    const All = markup.Profile(.{ .policy = .{ .validation = .{ .names = .{ .severity = .err } } } });
    try equal(.valid, All.validateIn(&distinct.document.?, keys.storage(), discard, .{}).validity);
}

test "invalid names report only their first bad code point with whole-name context" {
    for ([_]struct { name: []const u8, offset: u32, len: u32, reason: markup.diagnostic.NameProblem }{
        .{ .name = "·", .offset = 0, .len = 2, .reason = .invalid_start },
        .{ .name = "\u{0300}a", .offset = 0, .len = 2, .reason = .invalid_start },
        .{ .name = "a\u{037e}", .offset = 1, .len = 2, .reason = .invalid_character },
        .{ .name = "\u{f0000}", .offset = 0, .len = 4, .reason = .invalid_start },
        .{ .name = "a\u{ffff}", .offset = 1, .len = 3, .reason = .invalid_character },
        .{ .name = "\xff\xff", .offset = 0, .len = 1, .reason = .invalid_utf8 },
        .{ .name = "a\xf0\x90", .offset = 1, .len = 1, .reason = .invalid_utf8 },
        .{ .name = "a\xed\xa0\x80", .offset = 1, .len = 1, .reason = .invalid_utf8 },
    }) |case| {
        var source: [64]u8 = undefined;
        const input = try std.fmt.bufPrint(&source, "<{s}/>", .{case.name});
        var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
        const parsed = markup.parseBorrowedIn(input, .{ .document = output.storage() }, discard, .{});
        try equal(markup.Outcome.success, parsed.outcome);
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const checked = Names.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
        try equal(.complete, checked.completion);
        try equal(@as(u64, 1), checked.errors);
        const finding = bag.items()[0];
        try equal(markup.diagnostic.Code.invalid_name, finding.code);
        try equal(markup.location.Span{ .start = 1 + case.offset, .len = case.len }, finding.span);
        try std.testing.expectEqualStrings(case.name, finding.related.?.slice(input));
        try equal(case.reason, finding.details.name.problem);
        try equal(.element, finding.details.name.context);
    }
}

test "reference lookup is case-sensitive and confined to actual named references" {
    const source = "<!--&unknown;&\xff;--><![CDATA[&unknown;&\xff;]]>" ++
        "<arbitrary x='&amp;&lt;&gt;&quot;&apos;&#160;&#x1f600;&amp;nbsp;' y='&AMP;'/>" ++
        "&nbsp;&custom;&東京;";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    var bag: markup.FixedDiagnosticBag(16) = .{};
    const checked = References.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
    try equal(.complete, checked.completion);
    try equal(@as(u64, 4), checked.errors);
    for (bag.items(), [_][]const u8{ "&AMP;", "&nbsp;", "&custom;", "&東京;" }) |finding, text| {
        try equal(markup.diagnostic.Code.unknown_reference, finding.code);
        try std.testing.expectEqualStrings(text, finding.span.slice(source));
    }
    try equal(.valid, Names.validateIn(&parsed.document.?, .{}, discard, .{}).validity);
}

test "accepted malformed reference candidates stay literal during later name and catalog checks" {
    const Tolerant = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept }, .validation = .{
        .duplicate_attribute = .off,
        .names = .{ .severity = .err },
        .references = .{ .severity = .warning },
    } } });
    for ([_]struct { body: []const u8, refs: u64, names: u64 }{
        .{ .body = "&missing &\xff &1; &#; &#x; &#0; &#x110000; &amp;nbsp;", .refs = 0, .names = 0 },
        .{ .body = "&bad&missing;", .refs = 1, .names = 0 },
        .{ .body = "&#x&missing;&&missing;", .refs = 2, .names = 0 },
        .{ .body = "&\xff;&\xff &amp;", .refs = 1, .names = 1 },
        .{ .body = "&\u{0300}; &\u{0300}", .refs = 1, .names = 1 },
    }) |case| {
        inline for (.{ false, true }) |attribute| {
            var buffer: [512]u8 = undefined;
            const source = if (attribute) try std.fmt.bufPrint(&buffer, "<a x='{s}'/>", .{case.body}) else case.body;
            var parsed = Tolerant.parseBorrowed(std.testing.allocator, source, discard, .{});
            defer parsed.deinit();
            try equal(markup.Outcome.success, parsed.outcome);
            const checked = Tolerant.validateIn(&parsed.document.?, .{}, discard, .{});
            try equal(.complete, checked.completion);
            try equal(case.refs, checked.warnings);
            try equal(case.names, checked.errors);
        }
    }
}

test "name catalog encoding and duplicate policies compose with source-order and fixed-runtime parity" {
    const source = "\xff<\xff \xff='&\xff;' \xff='&missing;' a\u{037e}='&amp;'/>&nope;\xff";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    const doc = parsed.document.?;
    var scratch: markup.FixedValidationScratch(3) = .{};
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    inline for (.{ .off, .warning, .err }) |names| {
        inline for (.{ .off, .warning, .err }) |refs| {
            const patch: markup.Policy = .{ .validation = .{
                .invalid_utf8 = .warning,
                .names = .{ .severity = names },
                .references = .{ .severity = refs },
            } };
            const Fixed = markup.Profile(.{ .policy = patch });
            var bag: markup.FixedDiagnosticBag(32) = .{};
            var runtime_bag: markup.FixedDiagnosticBag(32) = .{};
            const checked = Fixed.validateIn(&doc, scratch.storage(), bag.sink(), .{});
            try equal(.complete, checked.completion);
            try equal(@as(u64, 1 + (if (names == .err) @as(u64, 5) else 0) + (if (refs == .err) @as(u64, 3) else 0)), checked.errors);
            try equal(@as(u64, 6 + (if (names == .warning) @as(u64, 5) else 0) + (if (refs == .warning) @as(u64, 3) else 0)), checked.warnings);
            try equal(if (names == .off) .not_run else .complete, checked.checks.names);
            try equal(if (refs == .off) .not_run else .complete, checked.checks.references);
            try equal(checked, Dynamic.validateIn(&doc, scratch.storage(), runtime_bag.sink(), .{ .policy = patch }));
            try std.testing.expectEqualDeep(bag.items(), runtime_bag.items());
            try equal(checked, Fixed.validate(std.testing.allocator, &doc, discard, .{}));
            var omit: markup.reporting.FixedBag(markup.Diagnostic, 0, .omit) = .{};
            try equal(checked, Fixed.validateIn(&doc, scratch.storage(), omit.sink(), .{}));
            for (bag.items(), 0..) |finding, i| {
                if (i == 0) continue;
                const previous = bag.items()[i - 1];
                try expect(previous.span.start <= finding.span.start);
                if (previous.span.start == finding.span.start) try expect(order(previous.code) < order(finding.code));
            }
        }
    }
}

fn order(code: markup.diagnostic.Code) u8 {
    return switch (code) {
        .invalid_utf8, .invalid_utf8_tolerated => 0,
        .duplicate_attribute, .duplicate_attribute_tolerated => 1,
        .invalid_name, .invalid_name_tolerated => 2,
        .unknown_reference, .unknown_reference_tolerated => 3,
        else => unreachable,
    };
}

test "name errors do not inherit encoding severity; whole-source encoding still checks closing names" {
    var parsed = markup.parseBorrowed(std.testing.allocator, "<\xff></\xff>\xff", discard, .{});
    defer parsed.deinit();
    const P = markup.Profile(.{ .policy = .{ .validation = .{
        .duplicate_attribute = .off,
        .names = .{ .severity = .err },
        .invalid_utf8 = .warning,
    } } });
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const checked = P.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
    try equal(.invalid, checked.validity);
    try equal(@as(u64, 1), checked.errors);
    try equal(@as(u64, 3), checked.warnings);
    try equal(markup.diagnostic.Code.invalid_utf8_tolerated, bag.items()[0].code);
    try equal(markup.diagnostic.Code.invalid_name, bag.items()[1].code);
}

test "nested patches inherit independently and complete presets reset the new checks" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{
        .names = .{ .rule = .xml_1_0, .severity = .err },
        .references = .{ .catalog = .xml_predefined, .severity = .warning },
    } } });
    const inherited = try Dynamic.Policies.prepare(.{ .policy = .{ .validation = .{ .names = .{ .rule = .xml_1_0 } } } });
    try equal(.err, inherited.validation.names.severity);
    try equal(.warning, inherited.validation.references.severity);
    const changed = try Dynamic.Policies.prepare(.{ .policy = .{ .validation = .{ .names = .{ .severity = .off } } } });
    try equal(.off, changed.validation.names.severity);
    try equal(.warning, changed.validation.references.severity);
    inline for (.{ markup.presets.standard, markup.presets.untrusted }) |preset| {
        const reset = try Dynamic.Policies.prepare(.{ .policy = preset });
        try equal(.off, reset.validation.names.severity);
        try equal(.off, reset.validation.references.severity);
    }
    try equal(.valid, Dynamic.validatePolicy(.{ .validation = .{ .names = .{ .severity = .warning }, .references = .{ .severity = .err } } }));
    var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    var session = Dynamic.Session.init("<\xff/>", .{ .document = output.storage() }, discard, .{ .policy = .{ .validation = .{ .names = .{ .severity = .off } } } });
    try equal(markup.Outcome.success, session.run().outcome);
    session.reset("<\xff/>", discard, .{});
    try equal(markup.Outcome.success, session.run().outcome); // Validation never runs inside parsing.
    try equal(@as(u64, 1), Dynamic.validateIn(&session.result().?.document.?, .{}, discard, .{}).errors);
}

test "new checks preserve stop failure scratch preflight and incomplete statuses" {
    const P = markup.Profile(.{ .policy = .{ .validation = .{
        .names = .{ .severity = .err },
        .references = .{ .severity = .warning },
    } } });
    var parsed = markup.parseBorrowed(std.testing.allocator, "<\xff x='&unknown;' x='2'/>", discard, .{});
    defer parsed.deinit();
    const doc = parsed.document.?;
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const no_scratch = P.validateIn(&doc, .{}, bag.sink(), .{});
    try equal(@as(u32, 2), no_scratch.completion.storage_exhausted);
    try equal(.unknown, no_scratch.validity);
    try equal(.incomplete, no_scratch.checks.names);
    try equal(.incomplete, no_scratch.checks.references);
    try equal(@as(u64, 0), no_scratch.errors);
    var keys: markup.FixedValidationScratch(2) = .{};
    var one: markup.FixedDiagnosticBag(1) = .{};
    const stopped = P.validateIn(&doc, keys.storage(), one.sink(), .{});
    try equal(markup.reporting.StopReason.requested, stopped.completion.diagnostic_stopped);
    try equal(.invalid, stopped.validity);
    try equal(.incomplete, stopped.checks.names);
    try equal(.incomplete, stopped.checks.references);
    try equal(@as(u64, 1), stopped.errors);
    var zero: markup.FixedDiagnosticBag(0) = .{};
    const rejected = P.validateIn(&doc, keys.storage(), zero.sink(), .{});
    try equal(markup.reporting.StopReason.capacity, rejected.completion.diagnostic_stopped);
    try equal(.failed, rejected.diagnostic_delivery);
    try equal(@as(u64, 1), rejected.errors);
    var oom = markup.GrowableDiagnosticBag.init(std.testing.failing_allocator, .{});
    defer oom.deinit();
    try equal(markup.reporting.StopReason.out_of_memory, P.validateIn(&doc, keys.storage(), oom.sink(), .{}).completion.diagnostic_stopped);
    const complete = P.validateIn(&doc, keys.storage(), discard, .{});
    try equal(.complete, complete.completion);
    try equal(@as(u64, 2), complete.errors);
    try equal(@as(u64, 1), complete.warnings);
}

const Stop = struct {
    polls: u32 = 0,
    after: u32,
    fn requested(raw: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.polls += 1;
        return self.polls > self.after;
    }
    fn hook(self: *@This()) markup.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "new checks poll inside long names and reference scans with fixed-runtime cancellation parity" {
    const patch: markup.Policy = .{ .syntax = .{ .malformed_reference = .accept }, .validation = .{
        .duplicate_attribute = .off,
        .names = .{ .severity = .err },
        .references = .{ .severity = .err },
    }, .execution = .{ .cancellation = true } };
    const P = markup.Profile(.{ .policy = patch });
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    for ([_][]const u8{
        "<" ++ "東京" ** 1000 ++ "/>",
        "<\xff/>" ++ "x" ** 10_000,
        "&" ++ "x" ** 10_000 ++ ";",
        "&" ++ "x" ** 10_000,
    }) |source| {
        var parsed = P.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        for ([_]u32{ 0, 1, 3, 10, 500 }) |after| {
            var stop: Stop = .{ .after = after };
            const checked = P.validateIn(&parsed.document.?, .{}, discard, .{ .cancellation = stop.hook() });
            try equal(.cancelled, checked.completion);
            try equal(after + 1, stop.polls);
            try equal(.incomplete, checked.checks.names);
            try equal(.incomplete, checked.checks.references);
            var dynamic_stop: Stop = .{ .after = after };
            try equal(checked, Dynamic.validateIn(&parsed.document.?, .{}, discard, .{ .policy = patch, .cancellation = dynamic_stop.hook() }));
        }
    }
}

test "bounded scalar and block parses produce identical later name and reference findings" {
    const source = "<!--&unknown;--><\xff x='&amp;&unknown;' y='&\xff;'>&bad&next;<![CDATA[&no;]]></\xff>";
    const patch: markup.Policy = .{ .syntax = .{ .malformed_reference = .warn }, .validation = .{
        .names = .{ .severity = .err },
        .references = .{ .severity = .warning },
        .invalid_utf8 = .err,
    }, .execution = .{ .metering = true } };
    var expected: ?markup.ValidationResult = null;
    inline for (.{ .scalar, .block }) |backend| {
        const P = markup.Profile(.{ .policy = blk: {
            var p = patch;
            p.scanner = backend;
            break :blk p;
        } });
        for ([_]u32{ 1, 7, 64 }) |budget| {
            var output: markup.FixedDocumentStorage(.{ .nodes = 8, .attributes = 4 }) = .{};
            var frames: markup.FixedParseScratch(4) = .{};
            var keys: markup.FixedValidationScratch(4) = .{};
            var session = P.Session.init(source, .{ .document = output.storage(), .scratch = frames.storage() }, discard, .{});
            while (session.result() == null) _ = session.advance(budget);
            const parsed = session.result().?;
            try equal(markup.Outcome.success, parsed.outcome);
            const checked = P.validateIn(&parsed.document.?, keys.storage(), discard, .{});
            if (expected) |e| try equal(e, checked) else expected = checked;
            try equal(.complete, checked.completion);
        }
    }
}

test "new checks finish empty input and preserve completed checks when trailing encoding stops" {
    const P = markup.Profile(.{ .policy = .{ .validation = .{
        .names = .{ .severity = .err },
        .references = .{ .severity = .err },
        .invalid_utf8 = .err,
    } } });
    for ([_][]const u8{ "", "\xef\xbb\xbf" }) |source| {
        var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        const result = P.validateIn(&parsed.document.?, .{}, discard, .{});
        try equal(.complete, result.completion);
        inline for (std.meta.fields(@TypeOf(result.checks))) |field| try equal(.complete, @field(result.checks, field.name));
    }
    var parsed = markup.parseBorrowed(std.testing.allocator, "<a/>\xff", discard, .{});
    defer parsed.deinit();
    var bag: markup.FixedDiagnosticBag(1) = .{};
    const checked = P.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
    try equal(markup.reporting.StopReason.requested, checked.completion.diagnostic_stopped);
    try equal(.complete, checked.checks.names);
    try equal(.complete, checked.checks.references);
    try equal(.complete, checked.checks.duplicate_attribute);
    try equal(.incomplete, checked.checks.invalid_utf8);
}

test "new validation floods obey the default diagnostic cap without allocating scratch" {
    const source = "&missing;" ** 2048;
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    const checked = References.validate(std.testing.failing_allocator, &parsed.document.?, bag.sink(), .{});
    try equal(markup.reporting.StopReason.requested, checked.completion.diagnostic_stopped);
    try equal(.incomplete, checked.checks.references);
    try equal(@as(u64, 1024), checked.errors);
    try equal(@as(usize, 1024), bag.items().len);
    try equal(@as(u64, 2048), References.validateIn(&parsed.document.?, .{}, discard, .{}).errors);
}

test "random mixed reference contexts have predictable findings and immutable source" {
    const P = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept }, .validation = .{
        .duplicate_attribute = .off,
        .names = .{ .severity = .err },
        .references = .{ .severity = .warning },
    } } });
    const parts = [_]struct { bytes: []const u8, errors: u64 = 0, warnings: u64 = 0 }{
        .{ .bytes = "&amp; " },
        .{ .bytes = "&amp;unknown; " },
        .{ .bytes = "&nbsp; ", .warnings = 1 },
        .{ .bytes = "&\xff; ", .errors = 1, .warnings = 1 },
        .{ .bytes = "&\xff " },
        .{ .bytes = "&bad&unknown; ", .warnings = 1 },
        .{ .bytes = "&#999999999999999999999999999999; " },
        .{ .bytes = "<x attr='&missing;'/> ", .warnings = 1 },
        .{ .bytes = "<\xff/> ", .errors = 1 },
        .{ .bytes = "<!--&missing;&\xff;--> " },
        .{ .bytes = "<![CDATA[&missing;&\xff;]]> " },
    };
    var random = std.Random.DefaultPrng.init(0x4b_4d41524b5550);
    for (0..100) |_| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        var errors: u64 = 0;
        var warnings: u64 = 0;
        for (0..32) |_| {
            const item = parts[random.random().uintLessThan(usize, parts.len)];
            try source.appendSlice(std.testing.allocator, item.bytes);
            errors += item.errors;
            warnings += item.warnings;
        }
        const before = std.hash.Wyhash.hash(0, source.items);
        var parsed = P.parseBorrowed(std.testing.allocator, source.items, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome.success, parsed.outcome);
        var bag: markup.FixedDiagnosticBag(128) = .{};
        const checked = P.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
        try equal(.complete, checked.completion);
        try equal(errors, checked.errors);
        try equal(warnings, checked.warnings);
        try equal(before, std.hash.Wyhash.hash(0, source.items));
        for (bag.items(), 0..) |finding, i| if (i != 0) {
            try expect(bag.items()[i - 1].span.start <= finding.span.start);
        };
    }
}
