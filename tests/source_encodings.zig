const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const gpa = std.testing.allocator;

test "composed options retain child identity and native facade exports selection errors" {
    inline for (.{ false, true }) |runtime| {
        const Child = markup.Profile(.{ .runtime_policy = runtime });
        const P = dot.Profile(.{ .processors = .{ .markup = Child } });
        const N = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16 }, .processors = .{ .markup = Child } });
        try std.testing.expect(@FieldType(P.CheckOptions, "markup") == Child.Options);
        try std.testing.expect(@FieldType(P.MarkupOptions, "markup") == Child.Options);
        try std.testing.expect(N.SelectionError == P.SelectionError);
        const options: Child.Options = .{};
        var bag: P.FixedDiagnosticBag(8) = .{};
        var result = try P.parseAndValidate(gpa, "graph { a [label=<<B>x</B>>] }", bag.sink(), .{ .markup = options });
        defer result.deinit(gpa);
        try std.testing.expect(result.documentValid());
    }
}

test "public native helpers handle incomplete units and identifier ranges safely" {
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        try std.testing.expectEqual(std.mem.order(u8, "a", "ab"), E.orderUnits("a", "ab", false));
        try std.testing.expect(E.indexAscii("a", 'a') == null);
        const D = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
        var source_buffer: [128]u8 = undefined;
        const source = encode(actual, "graph { ab }", &source_buffer, false);
        var parsed = try D.parseBorrowed(gpa, source, dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(gpa);
        const doc = parsed.document.?;
        var output: [16]u8 = @splat(0xaa);
        try std.testing.expectError(error.InvalidIdentifier, doc.decodeIdentifier(.{ .start = 8 * E.width + 1, .len = E.width }, &output));
        try std.testing.expectError(error.InvalidIdentifier, doc.decodeIdentifier(.{ .start = @intCast(source.len + 1), .len = 0 }, &output));
        for (output) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
        var writer = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidIdentifier, doc.writeIdentifier(.{ .start = 1, .len = E.width }, &writer));
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

test "binding hooks expose only the admitted processor contract not unchecked parsers" {
    const P = markup.Profile(.{ .policy = .{ .mode = .structural } });
    inline for (.{ .ascii, .utf8, .utf16le, .utf32be }) |actual| {
        const Bound = P.forSourceEncoding(actual);
        try std.testing.expect(@hasDecl(Bound, "Prepared") and @hasDecl(Bound, "Workspace"));
        try std.testing.expect(!@hasDecl(Bound, "parseBorrowed") and !@hasDecl(Bound, "parseAndValidate") and !@hasDecl(Bound, "Session"));
    }
    const Native = markup.Profile(.{ .source_encodings = &.{.utf16} });
    try std.testing.expectError(error.InvalidEncoding, Native.parseBorrowed(gpa, "\x00\xd8", markup.diagnostic.discard, .{ .encoding = .utf16le }));
    try std.testing.expectError(error.TruncatedCodeUnit, Native.parseBorrowed(gpa, "x\x00y", markup.diagnostic.discard, .{ .encoding = .utf16le }));
}

test "default byte validators accept documents admitted by an ASCII profile" {
    const D = dot.Profile(.{ .source_encodings = &.{} });
    var parsed = try D.parseBorrowed(gpa, "graph { a -- b }", dot.diagnostic.discard, .{});
    defer parsed.deinit(gpa);
    try std.testing.expect(dot.validate(&parsed.document.?, dot.diagnostic.discard, .{}).documentValid());
    const M = markup.Profile(.{ .source_encodings = &.{} });
    var m = try M.parseBorrowed(gpa, "<B>x</B>", markup.diagnostic.discard, .{});
    defer m.deinit();
    try std.testing.expectEqual(.valid, markup.validate(gpa, &m.document.?, markup.diagnostic.discard, .{}).validity);
}

test "scope cancellation precedes malformed header metadata through source facade" {
    const Stop = struct {
        fn requested(_: ?*anyopaque) bool {
            return true;
        }
    };
    const P = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16 }, .policy = .{ .execution = .{ .cancellation = true } } });
    const result = try P.validateScope(gpa, "<a x='1'>", .{ .opening_header = .{ .span = .{ .start = 0, .len = 9 }, .name = .{ .start = 1, .len = 0 } } }, markup.diagnostic.discard, .{ .cancellation = .{ .context = null, .is_requested = Stop.requested } });
    try std.testing.expectEqual(.cancelled, result.completion);
}

test "scope metadata audits poll before reaching a malformed late attribute" {
    const source = "<a" ++ " x='1'" ** 130 ++ ">";
    var attributes: [130]markup.ScopeAttribute = undefined;
    for (&attributes, 0..) |*attribute, i| attribute.* = .{
        .name = .{ .start = @intCast(3 + 6 * i), .len = 1 },
        .value = .{ .start = @intCast(5 + 6 * i), .len = 3 },
    };
    attributes[129].value.len = 2;
    const Stop = struct {
        fn requested(context: ?*anyopaque) bool {
            const calls: *u32 = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return calls.* >= 2;
        }
    };
    const P = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16 }, .policy = .{ .execution = .{ .cancellation = true } } });
    var calls: u32 = 0;
    const result = try P.validateScope(gpa, source, .{ .opening_header = .{ .span = .{ .start = 0, .len = source.len }, .name = .{ .start = 1, .len = 1 }, .attributes = &attributes } }, markup.diagnostic.discard, .{ .cancellation = .{ .context = &calls, .is_requested = Stop.requested } });
    try std.testing.expectEqual(.cancelled, result.completion);
    try std.testing.expectEqual(@as(u32, 2), calls);
}

test "native diagnostics quote code units and retain fixes and reference hints" {
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const D = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
        var buffer: [2048]u8 = undefined;
        var output: [4096]u8 = undefined;
        var bag: dot.FixedDiagnosticBag(16) = .{};
        const source = encode(actual, "graph { a [k x] }", &buffer, false);
        var r = try D.parseBorrowed(gpa, source, bag.sink(), .{ .encoding = actual });
        defer r.deinit(gpa);
        var writer = std.Io.Writer.fixed(&output);
        try dot.console.render(bag.items()[0], .{ .source = source, .source_encoding = actual }, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "insert '=' after 'k'") != null);

        bag = .{};
        const non_ascii = encode(actual, "graph { a [慢 x] }", &buffer, false);
        var n = try D.parseBorrowed(gpa, non_ascii, bag.sink(), .{ .encoding = actual });
        defer n.deinit(gpa);
        writer = std.Io.Writer.fixed(&output);
        try dot.console.render(bag.items()[0], .{ .source = non_ascii, .source_encoding = actual }, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "after 'ba'") == null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "after 'ab'") == null);

        bag = .{};
        const typo = encode(actual, "grap {}", &buffer, false);
        var h = try D.parseBorrowed(gpa, typo, bag.sink(), .{ .encoding = actual });
        defer h.deinit(gpa);
        try std.testing.expect(bag.items()[0].suggestedFix() != null);

        bag = .{};
        const numeral = encode(actual, "graph { a -- . }", &buffer, false);
        var number = try D.parseBorrowed(gpa, numeral, bag.sink(), .{ .encoding = actual });
        defer number.deinit(gpa);
        writer = std.Io.Writer.fixed(&output);
        try dot.console.render(bag.items()[0], .{ .source = numeral, .source_encoding = actual }, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "'.' must be followed") != null);

        const M = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .mode = .structural, .validation = .{ .references = .{ .severity = .err } } } });
        var mbag: markup.FixedDiagnosticBag(16) = .{};
        const reference = encode(actual, "<p>&nbsp;</p>", &buffer, false);
        var m = try M.parseAndValidate(gpa, try markup.Fragment.init(reference, 0), mbag.sink(), .{ .encoding = actual });
        defer m.deinit();
        writer = std.Io.Writer.fixed(&output);
        try markup.console.render(mbag.items()[0], .{ .source = reference, .source_encoding = actual }, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "use '&#160;' instead of '&nbsp;'") != null);
    }
}

test "native inline rendering clips long names only once" {
    inline for (.{ .utf16le, .utf32be }) |actual| {
        const M = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .mode = .structural } });
        var buffer: [512]u8 = undefined;
        const bytes = encode(actual, "<" ++ "x" ** 100 ++ "></y>", &buffer, false);
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var parsed = try M.parseBorrowed(gpa, bytes, bag.sink(), .{ .encoding = actual });
        defer parsed.deinit();
        var output: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try markup.console.render(bag.items()[0], .{ .source = bytes, .source_encoding = actual }, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "...") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "......") == null);
    }
}

fn encode(comptime actual: dot.InputEncoding, text: []const u8, buffer: []u8, bom: bool) []const u8 {
    const E = dot.encoding.Reader(actual);
    var at: usize = 0;
    if (bom) {
        const signature = switch (actual) {
            .utf16le => "\xff\xfe",
            .utf16be => "\xfe\xff",
            .utf32le => "\xff\xfe\x00\x00",
            .utf32be => "\x00\x00\xfe\xff",
            .utf8 => "\xef\xbb\xbf",
            .ascii => "",
        };
        @memcpy(buffer[0..signature.len], signature);
        at = signature.len;
    }
    var i: usize = 0;
    while (i < text.len) {
        const scalar = dot.encoding.Reader(.utf8).decode(text, i) catch unreachable;
        i += scalar.len;
        if (E.width == 2) {
            if (scalar.scalar > 0xffff) {
                const code: u32 = scalar.scalar - 0x10000;
                std.mem.writeInt(u16, buffer[at..][0..2], @intCast(0xd800 + (code >> 10)), E.endian);
                at += 2;
                std.mem.writeInt(u16, buffer[at..][0..2], @intCast(0xdc00 + (code & 1023)), E.endian);
            } else std.mem.writeInt(u16, buffer[at..][0..2], @intCast(scalar.scalar), E.endian);
            at += 2;
        } else if (E.width == 4) {
            std.mem.writeInt(u32, buffer[at..][0..4], scalar.scalar, E.endian);
            at += 4;
        } else {
            @memcpy(buffer[at..][0..scalar.len], text[i - scalar.len .. i]);
            at += scalar.len;
        }
    }
    return buffer[0..at];
}

test "native DOT and markup preserve source bytes, offsets and encoding" {
    inline for (.{ .scalar, .block }) |scanner| {
        const D = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .scanner = scanner } });
        const M = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .mode = .structural, .scanner = scanner } });
        inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
            var buffer: [1024]u8 = undefined;
            const source = encode(actual, "digraph { café -> 東京 [label=\"😀\"]; }", &buffer, true);
            var bag: dot.FixedDiagnosticBag(16) = .{};
            var parsed = try D.parseAndValidate(gpa, source, bag.sink(), .{});
            defer parsed.deinit(gpa);
            try std.testing.expect(parsed.documentValid());
            try std.testing.expectEqual(actual, parsed.document.?.source_info.encoding);
            try std.testing.expectEqual(.bom, parsed.document.?.source_info.provenance);
            try std.testing.expectEqual(source.ptr, parsed.document.?.source.ptr);
            const input = encode(actual, "<a x='😀'><!--c--><![CDATA[東京]]><b>café</b></a>", &buffer, true);
            var mbag: markup.FixedDiagnosticBag(16) = .{};
            var result = try M.parseAndValidate(gpa, try markup.Fragment.init(input, 12), mbag.sink(), .{});
            defer result.deinit();
            try std.testing.expect(result.documentValid());
            try std.testing.expectEqual(actual, result.parse.document.?.source_info.encoding);
            try std.testing.expectEqual(@as(u32, 5), result.parse.counts.nodes);
        }
    }
}

test "native fixed storage count passes decoding scopes and workspace reuse" {
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const M = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .mode = .structural, .validation = .{ .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
        const D = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
        var buffer: [2048]u8 = undefined;
        const source = encode(actual, "graph { \"café\" + \"\\😀\" [a=1 a=2] }", &buffer, false);
        var bag: dot.FixedDiagnosticBag(32) = .{};
        const counts = try D.measure(gpa, source, bag.sink(), .{ .encoding = actual });
        try std.testing.expect(counts.outcome == .success);
        var pools: dot.FixedDocumentStorage(.{ .nodes = 2, .attributes = 2, .statements = 2 }) = .{};
        var frames: dot.FixedParseScratch(.{ .nesting = 8 }) = .{};
        const fixed = try D.parseBorrowedIn(source, .{ .document = pools.storage(), .scratch = frames.storage() }, bag.sink(), .{ .encoding = actual });
        try std.testing.expect(fixed.outcome == .success);
        const doc = fixed.document.?;
        try std.testing.expectEqual(actual, doc.source_info.encoding);
        var output: [128]u8 = undefined;
        try std.testing.expectEqualStrings("café\\😀", try doc.decodeIdentifier(doc.nodeReference(doc.nodes[0].reference).?.identifier, &output));
        const rejected = dot.validate(&doc, bag.sink(), .{});
        try std.testing.expect(rejected.outcome == .unsupported_encoding);
        const input = encode(actual, "<a x='1' x='2'>&bogus;</a>", &buffer, false);
        var mbag: markup.FixedDiagnosticBag(32) = .{};
        const ready = M.prepare(.{ .encoding = actual });
        var workspace = ready.initWorkspace(gpa, .{});
        defer workspace.deinit();
        const checked = try workspace.parseAndValidate(try markup.Fragment.init(input, 24), mbag.sink());
        try std.testing.expectEqual(@as(u64, 2), checked.validation.?.errors);
        try std.testing.expectEqual(@as(u32, 24 + 9 * dot.encoding.Reader(actual).width), mbag.items()[0].span.start);
        const invalid_scope = try M.validateScope(gpa, input, .{ .text = .{ .start = 1, .len = 2 } }, mbag.sink(), .{ .encoding = actual });
        try std.testing.expect(invalid_scope.completion == .invalid_scope);
        const source_checked = try M.validateSource(gpa, input, mbag.sink(), .{ .encoding = actual });
        try std.testing.expectEqual(@as(u64, 2), source_checked.errors);
    }
}

test "native retained and delayed markup preserve one source encoding" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .processors = .{ .markup = markup.Profile(.{}) }, .policy = .{ .markup = .passthrough, .retention = .{ .markup = true } } });
    inline for (.{ .utf16be, .utf32le }) |actual| {
        var buffer: [1024]u8 = undefined;
        const source = encode(actual, "graph { a [label=<<B>東京</b>>] }", &buffer, true);
        var bag: P.FixedDiagnosticBag(16) = .{};
        var result = try P.parseAndValidate(gpa, source, bag.sink(), .{});
        defer result.deinit(gpa);
        const attribute = result.dot.document.?.attributes[0];
        try result.requestMarkup(gpa, attribute.value);
        try P.processPendingMarkup(gpa, &result, bag.sink(), .{});
        try std.testing.expect(result.documentValid());
        try std.testing.expectEqual(actual, result.markupResults().?[0].result.parse.document.?.source_info.encoding);
    }
}

test "only the outer source BOM is framing and native comment views trim code units" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .processors = .{ .markup = markup.Profile(.{}) }, .policy = .{ .retention = .{ .markup = true, .comments = true } } });
    inline for (.{ .utf8, .utf16le, .utf32be }) |actual| {
        var buffer: [1024]u8 = undefined;
        const source = encode(actual, "graph { /* kept */ a [label=<\u{feff}text>] }", &buffer, true);
        var bag: P.FixedDiagnosticBag(16) = .{};
        var result = try P.parseAndValidate(gpa, source, bag.sink(), .{});
        defer result.deinit(gpa);
        try std.testing.expect(result.documentValid());
        const outer = result.dot.document.?;
        try std.testing.expect(dot.encoding.Reader(actual).asciiEqual(outer.commentBody(outer.comments.?[0]), " kept ", false));
        const child = result.markupResults().?[0].result.parse.document.?;
        try std.testing.expect(!child.source_info.has_bom);
        try std.testing.expectEqual(.inherited, child.source_info.provenance);
        var roots = child.roots();
        const content = roots.next().?.content().?;
        try std.testing.expectEqual(@as(u21, 0xfeff), (try dot.encoding.Reader(actual).decode(content, 0)).scalar);
    }
}

test "native diagnostics retain original line and physical byte column" {
    const M = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .mode = .structural } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var buffer: [1024]u8 = undefined;
        const source = encode(actual, "<a>\r\n  <server></servr>\r\n</a>", &buffer, true);
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var result = try M.parseBorrowed(gpa, source, bag.sink(), .{});
        defer result.deinit();
        try std.testing.expect(result.outcome == .invalid_syntax);
        const finding = bag.items()[0];
        const position = dot.location.locateEncoded(source, finding.span.start, actual);
        try std.testing.expectEqual(@as(u32, 2), position.line);
        var out: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try markup.console.renderBoxed(finding, 1, .{ .source = source, .source_name = "input.xml", .source_encoding = actual }, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "</server>") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "</servr>") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "input.xml:2:") != null);
    }
}

test "ASCII-only is enforced inside strings comments and markup" {
    const D = dot.Profile(.{ .source_encodings = &.{} });
    const M = markup.Profile(.{ .source_encodings = &.{}, .policy = .{ .mode = .structural } });
    var bag: dot.FixedDiagnosticBag(8) = .{};
    var okay = try D.parseBorrowed(gpa, "graph { a }", bag.sink(), .{});
    defer okay.deinit(gpa);
    try std.testing.expect(okay.outcome == .success);
    inline for (.{ "graph { a [x=\"é\"] }", "graph { //é\n a }", "graph { /*é*/ a }", "graph { #é\n a }", "graph { <é> }" }) |source| {
        try std.testing.expectError(error.InvalidEncoding, D.parseBorrowed(gpa, source, bag.sink(), .{}));
    }
    var mbag: markup.FixedDiagnosticBag(8) = .{};
    try std.testing.expectError(error.InvalidEncoding, M.parseBorrowed(gpa, "<!--é-->", mbag.sink(), .{}));
}

test "bound markup inherits and explicit child capabilities form a union" {
    const D = dot.Profile(.{ .source_encodings = &.{.utf16}, .processors = .{ .markup = markup.Profile(.{}) }, .policy = .{ .markup = .process } });
    const U = dot.Profile(.{ .source_encodings = &.{.utf16}, .processors = .{ .markup = markup.Profile(.{ .source_encodings = &.{.utf32} }) }, .policy = .{ .markup = .process } });
    try std.testing.expect(!D.source_capabilities.utf8);
    try std.testing.expect(U.source_capabilities.utf16 and U.source_capabilities.utf32 and !U.source_capabilities.utf8);
    inline for (.{ .utf16le, .utf32be }) |actual| {
        var buffer: [1024]u8 = undefined;
        const source = encode(actual, "digraph { a [label=<<b>café 😀</B>>] }", &buffer, true);
        var bag: U.FixedDiagnosticBag(16) = .{};
        var result = try U.parseAndValidate(gpa, source, bag.sink(), .{});
        defer result.deinit(gpa);
        try std.testing.expect(result.documentValid());
        try std.testing.expectEqual(@as(u32, 1), result.markup.visited);
    }
}

test "native selection requires byte order and rejects malformed units" {
    const D = dot.Profile(.{ .source_encodings = &.{.utf32} });
    var bag: dot.FixedDiagnosticBag(8) = .{};
    try std.testing.expectError(error.EncodingRequired, D.parseBorrowed(gpa, "graph {}", bag.sink(), .{}));
    try std.testing.expectError(error.UnsupportedEncoding, D.parseBorrowed(gpa, "graph {}", bag.sink(), .{ .encoding = .utf8 }));
    try std.testing.expectError(error.TruncatedCodeUnit, D.parseBorrowed(gpa, "\xff\xfe\x00\x00x", bag.sink(), .{}));
    try std.testing.expectError(error.InvalidEncoding, D.parseBorrowed(gpa, "\xff\xfe\x00\x00\x00\xd8\x00\x00", bag.sink(), .{}));
    const U = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    // Explicit UTF-16LE sees its own two-byte BOM followed by NUL, not a
    // conflicting UTF-32LE signature. NUL is a grammar failure, not framing.
    var narrow = try U.parseBorrowed(gpa, "\xff\xfe\x00\x00", bag.sink(), .{ .encoding = .utf16le });
    defer narrow.deinit(gpa);
    try std.testing.expectEqual(dot.ParseOutcome.invalid_syntax, narrow.outcome);
    try std.testing.expectError(error.InvalidEncoding, U.parseBorrowed(gpa, "\xfe\xff\xd8\x00", bag.sink(), .{}));
}

test "explicit native markup preserves leading text that resembles another BOM" {
    inline for (.{ .scalar, .block }) |scanner| {
        const M = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .mode = .structural, .scanner = scanner } });
        inline for (.{
            .{ dot.InputEncoding.utf16le, "\u{bbef}\u{4ebf}<x/>" },
            .{ dot.InputEncoding.utf32le, "\u{ffeff}<x/>" },
        }) |case| {
            var buffer: [128]u8 = undefined;
            const source = encode(case[0], case[1], &buffer, false);
            var result = try M.parseAndValidate(gpa, try markup.Fragment.init(source, 0), markup.diagnostic.discard, .{ .encoding = case[0] });
            defer result.deinit();
            try std.testing.expect(result.documentValid());
            const document = result.parse.document.?;
            try std.testing.expectEqual(case[0], document.source_info.encoding);
            try std.testing.expectEqual(.explicit, document.source_info.provenance);
            try std.testing.expect(!document.source_info.has_bom);
            try std.testing.expectEqual(source.ptr, document.source.ptr);
            var roots = document.roots();
            const text = roots.next().?;
            try std.testing.expectEqual(@as(u32, 0), text.span().start);
            try std.testing.expectEqualSlices(u8, source[0..4], text.content().?);
        }
    }
}

test "native delayed markup proceeds independently of outer validation scratch" {
    const P = dot.Profile(.{
        .source_encodings = &.{ .utf16, .utf32 },
        .policy = .{ .markup = .passthrough, .retention = .{ .markup = true }, .validation = .{ .repeated_attribute = .warning } },
        .processors = .{ .markup = markup.Profile(.{}) },
    });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var buffer: [512]u8 = undefined;
        const source = encode(actual, "graph { a [label=<<B>ok</B>> color=red]; }", &buffer, true);
        var result = try P.parseAndValidate(gpa, source, P.DiagnosticSink.discard, .{});
        defer result.deinit(gpa);
        try std.testing.expect(result.scopeComplete() and !result.dot.documentValid());
        const outer_validation = result.dot.validation.?;
        try std.testing.expect(outer_validation.outcome == .insufficient_scratch);
        try result.requestMarkup(gpa, result.dot.document.?.attributes[0].value);
        try std.testing.expectEqual(dot.Completeness.not_processed, result.state());
        try P.processPendingMarkup(gpa, &result, P.DiagnosticSink.discard, .{});
        try std.testing.expect(result.subtreeComplete() and result.markup.allValid());
        try std.testing.expectEqual(dot.Completeness.complete, result.state());
        try std.testing.expect(!result.dot.documentValid() and !result.documentValid());
        try std.testing.expectEqualDeep(outer_validation, result.dot.validation.?);
        try std.testing.expectEqual(actual, result.markupResults().?[0].result.parse.document.?.source_info.encoding);
    }
}

test "native scanner backends agree on malformed ASCII syntax and block boundaries" {
    const DS = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .scanner = .scalar, .retention = .{ .partial = true, .comments = true } } });
    const DB = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .scanner = .block, .retention = .{ .partial = true, .comments = true } } });
    const MS = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .scanner = .scalar, .mode = .structural, .retention = .{ .partial = true } } });
    const MB = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .scanner = .block, .mode = .structural, .retention = .{ .partial = true } } });
    var random = std.Random.DefaultPrng.init(0xfefe76543210);
    var text: [144]u8 = undefined;
    const alphabet = "abc 012<>/-*#\"'&;=[]{}+\r\n\t";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var buffer: [1024]u8 = undefined;
        for (0..1000) |_| {
            const len = random.random().uintLessThan(usize, text.len);
            for (text[0..len]) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            const source = encode(actual, text[0..len], &buffer, true);
            var a: dot.FixedDiagnosticBag(64) = .{};
            var b: dot.FixedDiagnosticBag(64) = .{};
            var sa = try DS.parseBorrowed(gpa, source, a.sink(), .{});
            defer sa.deinit(gpa);
            var sb = try DB.parseBorrowed(gpa, source, b.sink(), .{});
            defer sb.deinit(gpa);
            try std.testing.expectEqual(sa.outcome, sb.outcome);
            try std.testing.expectEqual(sa.completion, sb.completion);
            try std.testing.expectEqualDeep(a.items(), b.items());
            var ma: markup.FixedDiagnosticBag(64) = .{};
            var mb: markup.FixedDiagnosticBag(64) = .{};
            var ra = try MS.parseBorrowed(gpa, source, ma.sink(), .{});
            defer ra.deinit();
            var rb = try MB.parseBorrowed(gpa, source, mb.sink(), .{});
            defer rb.deinit();
            try std.testing.expectEqual(ra.outcome, rb.outcome);
            try std.testing.expectEqual(ra.completion, rb.completion);
            try std.testing.expectEqual(ra.counts, rb.counts);
            try std.testing.expectEqualDeep(ma.items(), mb.items());
        }
    }
}

test "native runtime policy variants and admission cancellation are explicit" {
    const D = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .runtime_policy = true });
    const M = markup.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .runtime_policy = true });
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |metered| {
        var buffer: [1024]u8 = undefined;
        const source = encode(.utf16be, "graph { a -> b; }", &buffer, true);
        var bag: dot.FixedDiagnosticBag(16) = .{};
        var parsed = try D.parseAndValidate(gpa, source, bag.sink(), .{ .policy = .{ .scanner = scanner, .execution = .{ .metering = metered }, .validation = .{ .graph = .{ .operator_mismatch = .warning } } } });
        defer parsed.deinit(gpa);
        try std.testing.expect(parsed.documentValid());
        const input = encode(.utf32le, "<custom x='1'/>", &buffer, true);
        var mbag: markup.FixedDiagnosticBag(16) = .{};
        var checked = try M.parseAndValidate(gpa, try markup.Fragment.init(input, 0), mbag.sink(), .{ .policy = .{ .mode = .structural, .scanner = scanner, .execution = .{ .metering = metered } } });
        defer checked.deinit();
        try std.testing.expect(checked.documentValid());
    };
    const Stop = struct {
        fn requested(_: ?*anyopaque) bool {
            return true;
        }
    };
    const hook: dot.Cancellation = .{ .context = null, .is_requested = Stop.requested };
    var buffer: [128]u8 = undefined;
    const source = encode(.utf16le, "graph {}", &buffer, true);
    var bag: dot.FixedDiagnosticBag(16) = .{};
    try std.testing.expectError(error.Cancelled, D.parseBorrowed(gpa, source, bag.sink(), .{ .policy = .{ .execution = .{ .cancellation = true } }, .cancellation = hook }));
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
}
