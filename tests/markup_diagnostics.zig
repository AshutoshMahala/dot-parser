//! Public standalone diagnostics: no DOT dependency, allocator or OS in rendering.
const std = @import("std");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

fn contains(text: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing '{s}' in:\n{s}\n", .{ needle, text });
    try expect(std.mem.indexOf(u8, text, needle) != null);
}

test "markup decomposed registry preserves every existing structured identity" {
    const expected = [_][]const u8{
        "E.Syntax.Byte.003",          "E.Syntax.Grammar.003",       "E.Syntax.Grammar.031",
        "E.Syntax.Tag.002",           "E.Syntax.Tag.003",           "E.Syntax.Tag.032",
        "E.Profile.Feature.009",      "E.Resource.Capacity.026",    "E.Resource.Memory.026",
        "E.Validation.Attribute.006", "W.Validation.Attribute.006", "E.Syntax.Reference.003",
        "W.Syntax.Reference.003",     "E.Validation.Encoding.003",  "W.Validation.Encoding.003",
        "E.Validation.Name.003",      "W.Validation.Name.003",      "E.Validation.Reference.003",
        "W.Validation.Reference.003",
    };
    const codes = std.enums.values(markup.diagnostic.Code);
    try equal(expected.len, codes.len);
    for (codes, expected) |code, identity| {
        try strings(identity, code.structured());
        const info = code.info();
        try equal(code.severity(), info.severity);
        try expect(info.summary.len != 0 and info.hint.len != 0 and info.alias.len != 0);
        try expect(info.sequence > 0 and info.sequence <= 999);
        var storage: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        const finding: markup.Diagnostic = .{ .code = code, .span = .{ .start = 0, .len = 0 } };
        try markup.console.render(finding, .{}, &writer);
        try markup.console.renderBoxed(finding, 1, .{ .source = "", .verbose = true }, &writer);
        try contains(writer.buffered(), identity);
        try contains(writer.buffered(), info.summary);
        try contains(writer.buffered(), info.alias);
        try contains(writer.buffered(), &code.qualifiedCompactId());
    }
}

test "markup boxed diagnostics annotate the opener and closing name in the shared style" {
    const source = "<a>\n</b>";
    var bag: markup.FixedDiagnosticBag(4) = .{};
    var parsed = markup.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit();
    try equal(markup.Outcome.invalid_syntax, parsed.outcome);
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try markup.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "input", .verbose = true }, &writer);
    const text = writer.buffered();
    try contains(text, "┌─ Error 1:");
    try contains(text, "input:2:3");
    try contains(text, "element opened here");
    try contains(text, "expected the currently open element's name");
    try contains(text, "Hint:");
    try contains(text, "markup_parser:E.Syntax.Tag.002 (MISMATCH)");
    try expect(std.mem.indexOf(u8, text, "dot_parser") == null);
}

test "markup duplicate attributes have primary and related labels on one line" {
    const source = "<a x='1' x='2'/>";
    var bag: markup.FixedDiagnosticBag(4) = .{};
    var parsed = markup.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit();
    const result = markup.validate(std.testing.allocator, &parsed.document.?, bag.sink(), .{});
    try equal(@as(u64, 1), result.errors);
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try markup.console.renderBoxed(bag.items()[0], 1, .{ .source = source }, &writer);
    try contains(writer.buffered(), "first attribute with this name");
    try contains(writer.buffered(), "same name as the earlier attribute");
    try expect(bag.items()[0].fix == null); // no arbitrary winner chosen
}

test "markup rendering supports ASCII ANSI summaries and escaped source bytes" {
    const source = "a\x1b\xff\x00\r\nb";
    const finding: markup.Diagnostic = .{ .code = .invalid_utf8_tolerated, .span = .{ .start = 1, .len = 3 }, .details = .{ .byte = 0xff } };
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try markup.console.renderBoxedList(&.{ finding, finding }, 3, .{ .source = source, .style = .ascii }, &writer);
    for (writer.buffered()) |byte| try expect(byte < 128 and byte != '\r' and byte != 0x1b);
    try contains(writer.buffered(), "\\x1B\\xFF\\x00");
    try contains(writer.buffered(), "2 warnings (3 more omitted");
    writer.end = 0;
    try markup.console.renderBoxed(finding, 1, .{ .color = .ansi }, &writer);
    try contains(writer.buffered(), "\x1b[33m");
    try contains(writer.buffered(), "\x1b[0m");
}

test "markup render falls back safely for mismatched primary and related spans" {
    var storage: [4096]u8 = undefined;
    for ([_]markup.Diagnostic{
        .{ .code = .mismatched_tag, .span = .{ .start = 99, .len = 2 }, .related = .{ .start = 0, .len = 1 } },
        .{ .code = .mismatched_tag, .span = .{ .start = 0, .len = 1 }, .related = .{ .start = 99, .len = 2 } },
    }) |finding| {
        var writer = std.Io.Writer.fixed(&storage);
        try markup.console.renderBoxed(finding, 1, .{ .source = "x" }, &writer);
        try contains(writer.buffered(), "offset 99");
    }
    var writer = std.Io.Writer.fixed(&storage);
    try markup.console.renderBoxedList(&.{}, 0, .{}, &writer);
    try equal(@as(usize, 0), writer.buffered().len);
    var full = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, markup.console.render(.{ .code = .out_of_memory, .span = .{ .start = 0, .len = 0 } }, .{}, &full));
}

test "markup every typed detail is renderable without source or allocation" {
    var storage: [4096]u8 = undefined;
    inline for (.{ markup.diagnostic.Expected, markup.diagnostic.Feature, markup.diagnostic.Resource, markup.diagnostic.ReferenceProblem }) |T| {
        for (std.enums.values(T)) |value| {
            const details: markup.diagnostic.Details = if (T == markup.diagnostic.Expected) .{ .expected = value } else if (T == markup.diagnostic.Feature) .{ .feature = value } else if (T == markup.diagnostic.Resource) .{ .capacity = .{ .resource = value, .limit = 42 } } else .{ .reference = value };
            var writer = std.Io.Writer.fixed(&storage);
            try markup.console.render(.{ .code = .unexpected_byte, .span = .{ .start = 0, .len = 1 }, .details = details }, .{}, &writer);
            try expect(writer.buffered().len > 0);
        }
    }
    for (std.enums.values(markup.diagnostic.NameContext)) |context| {
        for (std.enums.values(markup.diagnostic.NameProblem)) |problem| {
            var writer = std.Io.Writer.fixed(&storage);
            try markup.console.render(.{ .code = .invalid_name, .span = .{ .start = 0, .len = 1 }, .details = .{ .name = .{ .context = context, .problem = problem } } }, .{}, &writer);
            try contains(writer.buffered(), @tagName(context));
        }
    }
}

test "markup repair filtering has compile-time runtime and scanner parity" {
    inline for (.{ .scalar, .block }) |backend| {
        inline for (.{ .reject, .warn }) |acceptance| {
            inline for (.{ .all, .machine_applicable, .off }) |mode| {
                const policy: markup.Policy = .{ .scanner = backend, .syntax = .{ .malformed_reference = acceptance }, .diagnostics = .{ .fixes = mode } };
                const Fixed = markup.Profile(.{ .policy = policy });
                const Runtime = markup.Profile(.{ .runtime_policy = true, .policy = .{ .diagnostics = .{ .fixes = .off } } });
                var a: markup.FixedDiagnosticBag(4) = .{};
                var b: markup.FixedDiagnosticBag(4) = .{};
                const ra = Fixed.measure(std.testing.allocator, "&amp", a.sink(), .{});
                const rb = Runtime.measure(std.testing.allocator, "&amp", b.sink(), .{ .policy = policy });
                try std.testing.expectEqualDeep(ra, rb);
                try std.testing.expectEqualDeep(a.items(), b.items());
                try equal(@as(usize, 1), a.items().len);
                const d = a.items()[0];
                try equal(mode == .all, d.fix != null);
                try equal(mode == .all, d.suggestedFix() != null);
                if (d.suggestedFix()) |fix| {
                    try equal(markup.diagnostic.Applicability.maybe, fix.applicability);
                    try equal(markup.location.Span{ .start = 4, .len = 0 }, fix.span);
                    try strings(";", fix.edit.insert_before.text());
                    try equal(markup.Outcome.success, Fixed.measure(std.testing.allocator, "&amp;", markup.diagnostic.discard, .{}).outcome);
                    var storage: [4096]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&storage);
                    try markup.console.renderBoxed(d, 1, .{ .source = "&amp" }, &writer);
                    try contains(writer.buffered(), "insert ';' at end of input (one possible repair)");
                }
            }
        }
    }
}

test "markup fixes add no diagnostic layout cost and never guess unrelated repairs" {
    try equal(@as(usize, 36), @sizeOf(markup.Diagnostic));
    for ([_][]const u8{ "&", "&#", "&#x", "&#0;", "<a></b>", "<a>", "</a>" }) |source| {
        var bag: markup.FixedDiagnosticBag(4) = .{};
        _ = markup.measure(std.testing.allocator, source, bag.sink(), .{});
        try equal(@as(usize, 1), bag.items().len);
        try expect(bag.items()[0].suggestedFix() == null);
    }
    const overflow: markup.Diagnostic = .{ .code = .malformed_reference, .span = .{ .start = std.math.maxInt(u32), .len = 1 }, .details = .{ .reference = .missing_semicolon }, .fix = .terminate_reference };
    try expect(overflow.suggestedFix() == null);
}

test "markup repair filtering leaves sink stop and failure outcomes unchanged" {
    const Runtime = markup.Profile(.{ .runtime_policy = true, .policy = .{ .syntax = .{ .malformed_reference = .warn } } });
    for ([_]markup.reporting.Fixes{ .all, .machine_applicable, .off }) |mode| {
        var stopped: markup.FixedDiagnosticBag(1) = .{};
        const stopped_result = Runtime.measure(std.testing.allocator, "&amp<a/>", stopped.sink(), .{ .policy = .{ .diagnostics = .{ .fixes = mode } } });
        try equal(markup.Outcome{ .diagnostic_stopped = .requested }, stopped_result.outcome);
        try equal(markup.reporting.Delivery.complete, stopped_result.diagnostic_delivery);
        try equal(@as(u32, 1), stopped_result.warnings);
        try equal(@as(u32, 0), stopped_result.counts.nodes);
        var full: markup.FixedDiagnosticBag(0) = .{};
        const failed = Runtime.measure(std.testing.allocator, "&amp<a/>", full.sink(), .{ .policy = .{ .diagnostics = .{ .fixes = mode } } });
        try equal(markup.Outcome{ .diagnostic_stopped = .capacity }, failed.outcome);
        try equal(markup.reporting.Delivery.failed, failed.diagnostic_delivery);
        try equal(stopped_result.warnings, failed.warnings);
    }
}

test "low-level markup lexing exposes a possible repair without changing input" {
    const source = "<a x='&amp'/>";
    var scanner = markup.lexer.Lexer.init(source);
    while (true) {
        const result = scanner.next();
        if (result == .token) {
            try expect(result.token.kind != .eof);
            continue;
        }
        const d = result.problem.diagnostic;
        const fix = d.suggestedFix().?;
        try equal(@as(u32, 10), fix.span.start);
        try equal(markup.diagnostic.Applicability.maybe, fix.applicability);
        try strings("<a x='&amp'/>", source);
        break;
    }
}
