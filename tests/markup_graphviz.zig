//! Standalone vocabulary slice; intentionally no DOT dependency.
const std = @import("std");
const markup = @import("markup_parser");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const strings = std.testing.expectEqualStrings;
const discard = markup.diagnostic.discard;
const Graphviz = markup.Profile(.{ .policy = .{ .mode = .graphviz } });

test "Graphviz vocabulary covers every documented element and per-element attribute" {
    const table = "ALIGN BGCOLOR BORDER CELLBORDER CELLPADDING CELLSPACING COLOR COLUMNS FIXEDSIZE GRADIENTANGLE HEIGHT HREF ID PORT ROWS SIDES STYLE TARGET TITLE TOOLTIP VALIGN WIDTH";
    const cell = "ALIGN BALIGN BGCOLOR BORDER CELLPADDING CELLSPACING COLOR COLSPAN FIXEDSIZE GRADIENTANGLE HEIGHT HREF ID PORT ROWSPAN SIDES STYLE TARGET TITLE TOOLTIP VALIGN WIDTH";
    const all_attributes = table ++ " BALIGN COLSPAN ROWSPAN FACE POINT-SIZE SCALE SRC CLASS xmlns bad";
    for ([_]struct { tag: []const u8, attributes: []const u8 }{
        .{ .tag = "TABLE", .attributes = table },                  .{ .tag = "TD", .attributes = cell },
        .{ .tag = "FONT", .attributes = "COLOR FACE POINT-SIZE" }, .{ .tag = "BR", .attributes = "ALIGN" },
        .{ .tag = "IMG", .attributes = "SCALE SRC" },              .{ .tag = "TR", .attributes = "" },
        .{ .tag = "I", .attributes = "" },                         .{ .tag = "B", .attributes = "" },
        .{ .tag = "U", .attributes = "" },                         .{ .tag = "O", .attributes = "" },
        .{ .tag = "SUB", .attributes = "" },                       .{ .tag = "SUP", .attributes = "" },
        .{ .tag = "S", .attributes = "" },                         .{ .tag = "HR", .attributes = "" },
        .{ .tag = "VR", .attributes = "" },
    }) |case| {
        var attributes = std.mem.tokenizeScalar(u8, all_attributes, ' ');
        while (attributes.next()) |name| {
            var storage: [256]u8 = undefined;
            const source = try std.fmt.bufPrint(&storage, "<{s} {s}=\"unvalidated\"/>", .{ case.tag, name });
            var pool: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 1 }) = .{};
            const parsed = Graphviz.parseBorrowedIn(source, .{ .document = pool.storage() }, discard, .{});
            try equal(markup.Outcome.success, parsed.outcome);
            var bag: markup.FixedDiagnosticBag(8) = .{};
            const checked = Graphviz.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
            var allowed = false;
            var allowed_names = std.mem.tokenizeScalar(u8, case.attributes, ' ');
            while (allowed_names.next()) |item| if (std.mem.eql(u8, item, name)) {
                allowed = true;
            };
            try equal(@as(u64, if (allowed) 0 else 1), checked.errors);
            try equal(.complete, checked.checks.graphviz_elements);
            try equal(.complete, checked.checks.graphviz_attributes);
            if (!allowed) {
                try equal(markup.diagnostic.Code.invalid_attribute, bag.items()[0].code);
                try strings(name, bag.items()[0].span.slice(source));
                try strings(case.tag, bag.items()[0].related.?.slice(source));
            }
            // Local source validation produces the same findings as the tree.
            var scratch: markup.FixedSourceValidationScratch(1) = .{};
            var local: markup.FixedDiagnosticBag(8) = .{};
            try equal(checked, Graphviz.validateSourceIn(source, scratch.storage(), local.sink(), .{}));
            try std.testing.expectEqualDeep(bag.items(), local.items());
        }
    }
}

test "Graphviz lookup and tag matching ignore ASCII case without changing source storage" {
    const source = "<TaBlE BoRdEr='0'><Tr><tD PoRt='p'><b>text</B><bR aLiGn='LEFT'/></Td></tR></TABLE>";
    var result = try Graphviz.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, discard, .{});
    defer result.deinit();
    try expect(result.documentValid());
    const document = result.parse.document.?;
    try expect(document.source.ptr == source.ptr);
    try strings(source, document.source);
    var roots = document.roots();
    try strings("TaBlE", roots.next().?.name().?);
    var mismatch = markup.parseBorrowed(std.testing.allocator, "<b></B>", discard, .{});
    defer mismatch.deinit();
    try equal(markup.Outcome.invalid_syntax, mismatch.outcome);
    try equal(@as(usize, 20), @sizeOf(markup.Node));
    try equal(@as(usize, 20), @sizeOf(markup.Attribute));
    try equal(@as(usize, 36), @sizeOf(markup.Diagnostic));
    try equal(@as(usize, 32), @sizeOf(markup.ValidationResult));
    try equal(@sizeOf(markup.Profile(.{}).Session), @sizeOf(Graphviz.Session));
}

test "Graphviz duplicate checking is case-insensitive with original first occurrence" {
    const source = "<TABLE BORDER='0' border='1' Border='2'/>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    var scratch: markup.FixedValidationScratch(3) = .{};
    try equal(.valid, markup.validateIn(&parsed.document.?, scratch.storage(), discard, .{}).validity);
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const result = Graphviz.validateIn(&parsed.document.?, scratch.storage(), bag.sink(), .{});
    try equal(@as(u64, 2), result.errors);
    for (bag.items()) |finding| {
        try equal(markup.diagnostic.Code.duplicate_attribute, finding.code);
        try strings("BORDER", finding.related.?.slice(source));
    }
}

test "Graphviz matching is selected once across execution variants and session resets" {
    const source = "<TaBlE><TR><td><B>x</b></TD></tr></TABLE>";
    const Runtime = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .graphviz } });
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        const p: markup.Policy = .{ .mode = .graphviz, .scanner = backend, .execution = .{ .metering = metering, .cancellation = cancellation } };
        const P = markup.Profile(.{ .policy = p });
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 5 }) = .{};
        var frames: markup.FixedParseScratch(4) = .{};
        const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
        var fixed = P.Session.init(source, memory, discard, .{});
        defer fixed.deinit();
        var fixed_work: u32 = 0;
        if (metering) {
            try equal(@as(u32, 0), fixed.advance(0).work_used);
            while (fixed.result() == null) {
                const step = fixed.advance(1);
                try expect(step.work_used <= 1);
                fixed_work += step.work_used;
            }
        } else _ = fixed.run();
        const expected = fixed.result().?;
        try equal(markup.Outcome.success, expected.outcome);
        try strings(source, expected.document.?.source);
        var dynamic = Runtime.Session.init(source, memory, discard, .{ .policy = p });
        defer dynamic.deinit();
        var runtime_work: u32 = 0;
        if (metering) {
            while (dynamic.result() == null) runtime_work += (try dynamic.advance(1)).work_used;
            try equal(fixed_work, runtime_work);
        } else {
            try std.testing.expectError(error.MeteringDisabled, dynamic.advance(1));
            _ = dynamic.run();
        }
        try equal(expected.outcome, dynamic.result().?.outcome);
        try equal(expected.counts, dynamic.result().?.counts);
        const measured = P.measureIn(source, frames.storage(), discard, .{});
        try equal(expected.outcome, measured.outcome);
        try equal(expected.counts, measured.counts);
        try equal(measured, Runtime.measureIn(source, frames.storage(), discard, .{ .policy = p }));
        dynamic.reset(source, discard, .{ .policy = .{ .mode = .structural } });
        try equal(markup.Outcome.invalid_syntax, dynamic.run().outcome);
        dynamic.reset(source, discard, .{}); // inherit baseline again, not previous override
        try equal(markup.Outcome.success, dynamic.run().outcome);
    };
    // Folding is ASCII-only, not Unicode normalization or typo correction.
    for ([_][]const u8{ "<B></I>", "<é></É>", "<LONG></longer>" }) |source_bytes| {
        var result = Graphviz.parseBorrowed(std.testing.allocator, source_bytes, discard, .{});
        defer result.deinit();
        try equal(markup.Outcome.invalid_syntax, result.outcome);
    }
}

test "Graphviz recovery uses the same folded ancestor matching without publishing a repaired tree" {
    const source = "<TABLE><TR><TD></tr></table><B>later</b>";
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| {
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = .{ .mode = .graphviz, .scanner = backend, .execution = .{ .metering = true } } });
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 5 }) = .{};
        var frames: markup.FixedParseScratch(3) = .{};
        var bag: markup.FixedDiagnosticBag(8) = .{};
        var session = P.Session.init(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, bag.sink(), .{});
        defer session.deinit();
        while (session.result() == null) {
            const step = if (runtime) try session.advance(1) else session.advance(1);
            try expect(step.work_used <= 1);
        }
        const result = session.result().?;
        try equal(markup.Outcome.invalid_syntax, result.outcome);
        try equal(.complete, result.completion);
        try expect(result.document == null);
        try equal(@as(u32, 1), result.syntax_errors);
        try equal(@as(usize, 1), bag.items().len);
        try equal(markup.diagnostic.Code.mismatched_tag, bag.items()[0].code);
        try strings("tr", bag.items()[0].span.slice(source));
        try strings("TD", bag.items()[0].related.?.slice(source));
    };
}

test "unknown owner attributes retain incomplete coverage across scopes fragments and workspaces" {
    const source = "<DIV onclick='x'>t</DIV>";
    const p: markup.Policy = .{ .mode = .graphviz, .validation = .{
        .invalid_utf8 = .err,
        .names = .{ .severity = .err },
        .references = .{ .severity = .err },
        .graphviz = .{ .unknown_element = .off },
    } };
    const P = markup.Profile(.{ .policy = p });
    const Runtime = markup.Profile(.{ .runtime_policy = true });
    const input: markup.Fragment = .{ .bytes = source, .origin = 20 };
    var zero: markup.FixedDiagnosticBag(0) = .{};
    var owned = try P.parseAndValidate(std.testing.allocator, input, zero.sink(), .{});
    defer owned.deinit();
    try equal(markup.Outcome.success, owned.parse.outcome);
    try expect(!owned.documentValid());
    try expect(!owned.has_errors and !owned.stopped() and !owned.shouldStop(.fail_fast));
    try equal(@as(u32, 25), owned.validation.?.completion.incomplete);
    var pool: markup.FixedDocumentStorage(.{ .nodes = 2, .attributes = 1 }) = .{};
    var frames: markup.FixedParseScratch(1) = .{};
    const memory: markup.ParseMemory = .{ .document = pool.storage(), .scratch = frames.storage() };
    const fixed = try P.parseAndValidateIn(input, memory, .{}, zero.sink(), .{});
    try equal(owned.validation.?, fixed.validation.?);
    var workspace = Runtime.prepare(.{ .policy = p }).initWorkspace(std.testing.allocator, .{});
    defer workspace.deinit();
    const reused = try workspace.parseAndValidate(input, zero.sink());
    try equal(owned.validation.?, reused.validation.?);
    const clean = try workspace.parseAndValidate(.{ .bytes = "<BR/>", .origin = 0 }, zero.sink());
    try expect(clean.documentValid());

    const checked = P.validateIn(&owned.parse.document.?, .{}, zero.sink(), .{});
    try equal(@as(u32, 5), checked.completion.incomplete);
    try equal(.unknown, checked.validity);
    try equal(@as(u64, 0), checked.errors);
    try equal(@as(u64, 0), checked.warnings);
    try equal(.incomplete, checked.checks.graphviz_attributes);
    try equal(.not_run, checked.checks.graphviz_elements);
    try equal(.complete, checked.checks.duplicate_attribute);
    try equal(.complete, checked.checks.invalid_utf8);
    try equal(.complete, checked.checks.names);
    try equal(.complete, checked.checks.references);
    const header: markup.ValidationScope = .{ .opening_header = .{
        .span = .{ .start = 0, .len = 17 },
        .name = .{ .start = 1, .len = 3 },
        .attributes = &.{.{ .name = .{ .start = 5, .len = 7 }, .value = .{ .start = 13, .len = 3 } }},
    } };
    try equal(checked, P.validateScopeIn(source, header, .{}, zero.sink(), .{}));
    try equal(checked, Runtime.validateScope(std.testing.failing_allocator, source, header, zero.sink(), .{ .policy = p }));
    inline for (.{ .scalar, .block }) |backend| inline for (.{ .off, .err }) |duplicates| inline for (.{ .collect, .fail_fast }) |on_error| {
        var patch = p;
        patch.scanner = backend;
        patch.validation.duplicate_attribute = duplicates;
        patch.on_error = on_error;
        const expected = Runtime.validate(std.testing.failing_allocator, &owned.parse.document.?, zero.sink(), .{ .policy = patch });
        var scratch: markup.FixedSourceValidationScratch(1) = .{};
        try equal(expected, Runtime.validateSourceIn(source, scratch.storage(), zero.sink(), .{ .policy = patch }));
        try equal(expected, Runtime.validateSource(std.testing.allocator, source, zero.sink(), .{ .policy = patch }));
        try equal(@as(u32, 5), expected.completion.incomplete);
    };
    // An empty attribute list has no unchecked attributes; an off check makes
    // no claim and introduces no gap. Neither case constructs a diagnostic.
    try equal(.complete, P.validateSourceIn("<DIV/>", .{}, zero.sink(), .{}).completion);
    var disabled = p;
    disabled.validation.graphviz.invalid_attribute = .off;
    const skipped = Runtime.validateIn(&owned.parse.document.?, .{}, zero.sink(), .{ .policy = disabled });
    try equal(.complete, skipped.completion);
    try equal(.valid, skipped.validity);
    try equal(.not_run, skipped.checks.graphviz_attributes);
}

test "unknown owner gaps preserve independent findings and merge with lexical gaps" {
    const P = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .graphviz, .validation = .{ .graphviz = .{ .unknown_element = .off } } } });
    inline for (.{ .scalar, .block }) |backend| inline for (.{ .off, .err }) |duplicates| {
        var storage: markup.FixedSourceValidationScratch(2) = .{};
        for ([_][]const u8{
            "<DIV a='x'><BR BAD='y'/></DIV><SPAN b='z'/>",
            "<DIV a='x'/><BR BAD=0/><SPAN b='z'/>",
        }) |source| {
            var bag: markup.FixedDiagnosticBag(8) = .{};
            const checked = P.validateSourceIn(source, storage.storage(), bag.sink(), .{ .policy = .{ .scanner = backend, .validation = .{ .duplicate_attribute = duplicates } } });
            try equal(@as(u32, 5), checked.completion.incomplete);
            try equal(.invalid, checked.validity);
            try equal(@as(u64, 1), checked.errors);
            try equal(.incomplete, checked.checks.graphviz_attributes);
            try equal(@as(usize, 1), bag.items().len);
            try equal(markup.diagnostic.Code.invalid_attribute, bag.items()[0].code);
        }
        const source = "<BR ALIGN=0/><DIV a='x'/>";
        const checked = P.validateSourceIn(source, storage.storage(), discard, .{ .policy = .{ .scanner = backend, .validation = .{ .duplicate_attribute = duplicates } } });
        try equal(@as(u32, 10), checked.completion.incomplete);
    };
    var bag: markup.FixedDiagnosticBag(8) = .{};
    var scratch: markup.FixedSourceValidationScratch(2) = .{};
    const duplicates = P.validateSourceIn("<DIV x='1' X='2'/>", scratch.storage(), bag.sink(), .{});
    try equal(@as(u32, 5), duplicates.completion.incomplete);
    try equal(.complete, duplicates.checks.duplicate_attribute);
    try equal(.invalid, duplicates.validity);
    try equal(@as(u64, 1), duplicates.errors);
    try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[0].code);
}

test "independent severity controls have compile-time runtime and source-walk parity" {
    @setEvalBranchQuota(20_000);
    const source = "<custom arbitrary='1'><BR SRC='image'/><TD CLASS='x'/></custom>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    const Runtime = markup.Profile(.{ .runtime_policy = true });
    inline for (.{ .err, .warning, .off }) |element| inline for (.{ .err, .warning, .off }) |attribute| inline for (.{ .scalar, .block }) |backend| inline for (.{ .off, .err }) |duplicates| {
        const p: markup.Policy = .{ .mode = .graphviz, .scanner = backend, .validation = .{
            .duplicate_attribute = duplicates,
            .graphviz = .{ .unknown_element = element, .invalid_attribute = attribute },
        } };
        const P = markup.Profile(.{ .policy = p });
        var fixed_bag: markup.FixedDiagnosticBag(16) = .{};
        var runtime_bag: markup.FixedDiagnosticBag(16) = .{};
        const fixed = P.validateIn(&parsed.document.?, .{}, fixed_bag.sink(), .{});
        const runtime = Runtime.validateIn(&parsed.document.?, .{}, runtime_bag.sink(), .{ .policy = p });
        try equal(fixed, runtime);
        try std.testing.expectEqualDeep(fixed_bag.items(), runtime_bag.items());
        try equal(@as(u64, if (element == .err) 1 else 0) + @as(u64, if (attribute == .err) 2 else 0), fixed.errors);
        try equal(@as(u64, if (element == .warning) 1 else 0) + @as(u64, if (attribute == .warning) 2 else 0), fixed.warnings);
        try equal(if (element == .off) .not_run else .complete, fixed.checks.graphviz_elements);
        try equal(if (attribute == .off) .not_run else .incomplete, fixed.checks.graphviz_attributes);
        if (attribute != .off) try equal(@as(u32, 8), fixed.completion.incomplete);
        var local_bag: markup.FixedDiagnosticBag(16) = .{};
        var scratch: markup.FixedSourceValidationScratch(1) = .{};
        try equal(fixed, P.validateSourceIn(source, scratch.storage(), local_bag.sink(), .{}));
        try std.testing.expectEqualDeep(fixed_bag.items(), local_bag.items());
        try equal(fixed, P.validate(std.testing.failing_allocator, &parsed.document.?, discard, .{}));
    };
}

test "mode and nested patches inherit independently and complete presets reset them" {
    const Runtime = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .graphviz, .validation = .{ .graphviz = .{ .unknown_element = .warning } } } });
    const inherited = try Runtime.Policies.prepare(.{ .policy = .{ .validation = .{ .graphviz = .{ .invalid_attribute = .off } } } });
    try equal(.graphviz, inherited.mode);
    try equal(.warning, inherited.validation.graphviz.unknown_element);
    try equal(.off, inherited.validation.graphviz.invalid_attribute);
    inline for (.{ markup.presets.standard, markup.presets.untrusted }) |preset| {
        const reset = try Runtime.Policies.prepare(.{ .policy = preset });
        try equal(.structural, reset.mode);
        try equal(.err, reset.validation.graphviz.unknown_element);
        try equal(.err, reset.validation.graphviz.invalid_attribute);
    }
    try equal(.valid, Runtime.validatePolicy(.{ .mode = .graphviz }));
    const Structural = markup.Profile(.{ .policy = .{ .validation = .{ .graphviz = .{ .unknown_element = .err, .invalid_attribute = .err } } } });
    const checked = Structural.validateSourceIn("<custom/>", .{}, discard, .{});
    try equal(.valid, checked.validity);
    try equal(.not_run, checked.checks.graphviz_elements);
    try equal(.not_run, checked.checks.graphviz_attributes);
}

test "Graphviz headers remain independently checkable after syntax errors" {
    const source = "<TABLE BOGUS=0/><custom><BR SRC='x'/></wrong>";
    inline for (.{ .scalar, .block }) |backend| inline for (.{ .off, .err }) |duplicates| {
        const P = markup.Profile(.{ .policy = .{ .mode = .graphviz, .scanner = backend, .validation = .{ .duplicate_attribute = duplicates } } });
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var result = try P.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 20 }, bag.sink(), .{});
        defer result.deinit();
        try equal(markup.Outcome.invalid_syntax, result.parse.outcome);
        try expect(result.parse.document == null);
        try equal(@as(u64, 3), result.validation.?.errors);
        try expect(result.validation.?.completion == .incomplete);
        var count: u32 = 0;
        for (bag.items()) |finding| switch (finding.code) {
            .unknown_element, .invalid_attribute => {
                count += 1;
                try expect(finding.span.start >= 20);
                if (finding.related) |span| try expect(span.start >= 20);
            },
            else => {},
        };
        try equal(@as(u32, 3), count);
    };
}

test "standalone scope vocabulary requires owner context for attributes and checks bounds" {
    const source = "<BR SRC='x'>";
    const name: markup.location.Span = .{ .start = 4, .len = 3 };
    const header: markup.ValidationScope = .{ .opening_header = .{
        .span = .{ .start = 0, .len = source.len },
        .name = .{ .start = 1, .len = 2 },
        .attributes = &.{.{ .name = name, .value = .{ .start = 8, .len = 3 } }},
    } };
    const checked = Graphviz.validateScopeIn(source, header, .{}, discard, .{});
    try equal(@as(u64, 1), checked.errors);
    const no_owner = Graphviz.validateScopeIn(source, .{ .attribute_name = name }, .{}, discard, .{});
    try equal(.not_run, no_owner.checks.graphviz_attributes);
    try equal(.not_run, no_owner.checks.graphviz_elements);
    const invalid = Graphviz.validateScopeIn(source, .{ .opening_name = .{ .start = source.len, .len = 1 } }, .{}, discard, .{});
    try equal(.invalid_scope, invalid.completion);
}

test "vocabulary findings honor fail-fast sink stops and cancellation" {
    const source = "<custom/><BR SRC='x'/>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    const Fast = markup.Profile(.{ .policy = .{ .mode = .graphviz, .on_error = .fail_fast } });
    const stopped = Fast.validateIn(&parsed.document.?, .{}, discard, .{});
    try equal(.error_stopped, stopped.completion);
    try equal(@as(u64, 1), stopped.errors);
    try equal(.incomplete, stopped.checks.graphviz_elements);
    var one: markup.FixedDiagnosticBag(1) = .{};
    try equal(markup.reporting.StopReason.requested, Graphviz.validateIn(&parsed.document.?, .{}, one.sink(), .{}).completion.diagnostic_stopped);
    var zero: markup.FixedDiagnosticBag(0) = .{};
    try equal(markup.reporting.StopReason.capacity, Graphviz.validateIn(&parsed.document.?, .{}, zero.sink(), .{}).completion.diagnostic_stopped);
    const Probe = struct {
        count: u32 = 0,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.count += 1;
            return self.count == 5;
        }
    };
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| {
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = .{ .mode = .graphviz, .scanner = backend, .execution = .{ .cancellation = true }, .validation = .{ .duplicate_attribute = .off } } });
        var probe: Probe = .{};
        const cancelled = P.validateSourceIn("<BR SRC='x'/>" ** 1024, .{}, discard, .{ .cancellation = .{ .context = &probe, .is_requested = Probe.poll } });
        try equal(.cancelled, cancelled.completion);
        try equal(@as(u32, 5), probe.count);
        try equal(.incomplete, cancelled.checks.graphviz_attributes);
    };
}

test "vocabulary-only coverage makes no claim about placement values references or quoting" {
    for ([_][]const u8{
        "<TABLE><TD WIDTH='not-a-number'/></TABLE>", "<IMG/>",              "<BR></BR>", "&nbsp;",
        "<!--<custom/>--><![CDATA[<custom/>]]>",     "<TABLE WIDTH='-1'/>", "",
    }) |source| {
        var result = try Graphviz.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, discard, .{});
        defer result.deinit();
        try expect(result.documentValid()); // Valid under implemented checks only.
        try equal(.not_run, result.validation.?.checks.references);
        try equal(.not_run, result.validation.?.checks.names);
    }
}

test "Graphviz diagnostics render names safely with missing truncated or complete source" {
    const source = "<custom/><BR SRC='x'/>";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    var checked = try Graphviz.parseAndValidate(std.testing.allocator, .{ .bytes = source, .origin = 0 }, bag.sink(), .{});
    defer checked.deinit();
    for ([_]?[]const u8{ source, source[0..3], null }) |input| inline for (.{ .unicode, .ascii }) |style| {
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        for (bag.items()) |finding| {
            try markup.console.renderBoxed(finding, 1, .{ .source = input, .style = style }, &writer);
            try expect(finding.suggestedFix() == null);
        }
        if (input != null and input.?.len == source.len) {
            try expect(std.mem.indexOf(u8, writer.buffered(), "element 'custom'") != null);
            try expect(std.mem.indexOf(u8, writer.buffered(), "attribute 'SRC' is not allowed on Graphviz element 'BR'") != null);
        }
    };
}

test "Graphviz fixed fragment and reused workspace agree with owned results and origins" {
    const source = "<TABLE bad='x'><custom/></TABLE>";
    const input: markup.Fragment = .{ .bytes = source, .origin = 17 };
    var owned_bag: markup.FixedDiagnosticBag(8) = .{};
    var owned = try Graphviz.parseAndValidate(std.testing.allocator, input, owned_bag.sink(), .{});
    defer owned.deinit();
    var pool: markup.FixedDocumentStorage(.{ .nodes = 2, .attributes = 1 }) = .{};
    var frames: markup.FixedParseScratch(1) = .{};
    var fixed_bag: markup.FixedDiagnosticBag(8) = .{};
    const fixed = try Graphviz.parseAndValidateIn(input, .{ .document = pool.storage(), .scratch = frames.storage() }, .{}, fixed_bag.sink(), .{});
    try equal(owned.validation.?, fixed.validation.?);
    try std.testing.expectEqualDeep(owned_bag.items(), fixed_bag.items());
    try equal(@as(u32, 24), fixed_bag.items()[0].span.start);
    try equal(@as(u32, 18), fixed_bag.items()[0].related.?.start);
    var workspace = Graphviz.prepare(.{}).initWorkspace(std.testing.allocator, .{});
    defer workspace.deinit();
    for (0..3) |_| {
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const result = try workspace.parseAndValidate(input, bag.sink());
        try equal(owned.validation.?, result.validation.?);
        try std.testing.expectEqualDeep(owned_bag.items(), bag.items());
        const next = try workspace.parseAndValidate(.{ .bytes = "<BR/>", .origin = 0 }, discard);
        try expect(next.documentValid());
    }
}

test "vocabulary and XML name findings keep document order without source repair" {
    const source = "<TABLE a\xff='x'/><a\xff/>";
    const P = markup.Profile(.{ .policy = .{ .mode = .graphviz, .validation = .{ .names = .{ .severity = .err }, .invalid_utf8 = .warning } } });
    var parsed = P.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    var bag: markup.FixedDiagnosticBag(16) = .{};
    const checked = P.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
    try equal(@as(u64, 4), checked.errors);
    try equal(@as(u64, 2), checked.warnings);
    for (bag.items()[1..], bag.items()[0 .. bag.items().len - 1]) |finding, previous|
        try expect(finding.span.start >= previous.span.start);
    try strings(source, parsed.document.?.source);
}

test "vocabulary floods stop at the diagnostic cap and skipping a check does not construct findings" {
    const source = "<custom/>" ** 2048;
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    const checked = Graphviz.validateSourceIn(source, .{}, bag.sink(), .{});
    try equal(markup.reporting.StopReason.requested, checked.completion.diagnostic_stopped);
    try equal(@as(u64, 1024), checked.errors);
    try equal(@as(usize, 1024), bag.items().len);
    var zero: markup.FixedDiagnosticBag(0) = .{};
    const Off = markup.Profile(.{ .policy = .{ .mode = .graphviz, .validation = .{ .graphviz = .{ .unknown_element = .off, .invalid_attribute = .off } } } });
    const skipped = Off.validateSourceIn(source, .{}, zero.sink(), .{});
    try equal(.complete, skipped.completion);
    try equal(@as(u64, 0), skipped.errors);
    try equal(.not_run, skipped.checks.graphviz_elements);
}

test "warnings do not trigger fail-fast and attribute checks continue on known children" {
    const P = markup.Profile(.{ .policy = .{ .mode = .graphviz, .on_error = .fail_fast, .validation = .{ .graphviz = .{ .unknown_element = .warning } } } });
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const checked = P.validateSourceIn("<custom/><BR BAD='x'/><unknown/>", .{}, bag.sink(), .{});
    // Header buffering for default duplicate checking needs an attribute slot.
    try equal(.storage_exhausted, std.meta.activeTag(checked.completion));
    var scratch: markup.FixedSourceValidationScratch(1) = .{};
    var findings: markup.FixedDiagnosticBag(8) = .{};
    const complete = P.validateSourceIn("<custom/><BR BAD='x'/><unknown/>", scratch.storage(), findings.sink(), .{});
    try equal(.error_stopped, complete.completion);
    try equal(@as(u64, 1), complete.warnings);
    try equal(@as(u64, 1), complete.errors);
    try equal(@as(usize, 2), findings.items().len);
}

test "generated vocabulary headers have scalar block document and source parity" {
    const tags = [_][]const u8{ "TABLE", "TaBlE", "TD", "td", "FONT", "br", "IMG", "B", "custom", "東京" };
    const names = [_][]const u8{ "WIDTH", "width", "Width", "ALIGN", "align", "CLASS", "FACE", "POINT-SIZE", "a\xff", "bogus" };
    const values = [_][]const u8{ "x", "&amp;", "&nbsp;", "&#65;" };
    const patch: markup.Policy = .{ .mode = .graphviz, .validation = .{ .names = .{ .severity = .err }, .references = .{ .severity = .warning } } };
    const P = markup.Profile(.{ .policy = patch });
    const Runtime = markup.Profile(.{ .runtime_policy = true });
    var rng = std.Random.DefaultPrng.init(0x6a76766f636162);
    const random = rng.random();
    for (0..1000) |_| {
        var buffer: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "<{s} {s}='{s}' {s}='{s}' {s}='{s}'/>", .{
            tags[random.uintLessThan(usize, tags.len)],
            names[random.uintLessThan(usize, names.len)],
            values[random.uintLessThan(usize, values.len)],
            names[random.uintLessThan(usize, names.len)],
            values[random.uintLessThan(usize, values.len)],
            names[random.uintLessThan(usize, names.len)],
            values[random.uintLessThan(usize, values.len)],
        });
        var pool: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 3 }) = .{};
        const parsed = P.parseBorrowedIn(source, .{ .document = pool.storage() }, discard, .{});
        try equal(markup.Outcome.success, parsed.outcome);
        var scratch: markup.FixedSourceValidationScratch(3) = .{};
        var expected: markup.FixedDiagnosticBag(32) = .{};
        const checked = P.validateIn(&parsed.document.?, .{ .attribute_keys = &scratch.keys }, expected.sink(), .{});
        inline for (.{ .scalar, .block }) |backend| {
            var selected = patch;
            selected.scanner = backend;
            var bag: markup.FixedDiagnosticBag(32) = .{};
            const actual = Runtime.validateSourceIn(source, scratch.storage(), bag.sink(), .{ .policy = selected });
            try equal(checked, actual);
            try std.testing.expectEqualDeep(expected.items(), bag.items());
        }
    }
}
