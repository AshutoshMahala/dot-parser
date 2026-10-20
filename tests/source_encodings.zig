const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const gpa = std.testing.allocator;

test "native DOT Graphviz catalog compares logical case-sensitive keys" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .validation = .{ .graphviz = .{ .unknown_attribute = .warning } } } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var buffer: [512]u8 = undefined;
        const source = encode(actual, "digraph { a [\"co\"+\"lor\"=red, shpe=box]; rankdir=LR }", &buffer, true);
        var bag: dot.FixedDiagnosticBag(4) = .{};
        var result = try P.parseAndValidate(gpa, source, bag.sink(), .{});
        defer result.deinit(gpa);
        try std.testing.expect(result.documentValid());
        try std.testing.expectEqual(@as(u64, 1), result.warnings);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        var key: [16]u8 = undefined;
        try std.testing.expectEqualSlices(u8, encode(actual, "shpe", &key, false), bag.items()[0].span.slice(source));
    }
}

test "profile source inspection reports native framing and bound capabilities" {
    const N = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const M = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const C = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{ .source_encodings = &.{.utf16} }) } });
    try std.testing.expectEqual(dot.InputEncoding.utf16le, C.inspectSource("\xff\xfe", null).selected.encoding);
    try std.testing.expectEqual(error.UnsupportedEncoding, markup.inspectSource("\xff\xfe", null).failure.reason);
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var buffer: [64]u8 = undefined;
        const source = encode(actual, "abc", &buffer, true);
        try std.testing.expectEqual(actual, N.inspectSource(source, null).selected.encoding);
        for (1..E.width) |tail| {
            const truncated = source[0 .. source.len - tail];
            const failure = N.inspectSource(truncated, actual).failure;
            try std.testing.expectEqual(error.TruncatedCodeUnit, failure.reason);
            try std.testing.expectEqual(actual, failure.encoding.?);
            try std.testing.expectEqual(dot.Span{ .start = @intCast(source.len - E.width), .len = @intCast(E.width - tail) }, failure.span.?);
            try std.testing.expectEqualDeep(failure, M.inspectSource(truncated, actual).failure);
            try std.testing.expectError(error.TruncatedCodeUnit, N.inspectSource(truncated, actual).require());
        }
    }
    // Explicit selection wins even over a conflicting/longer leading BOM.
    try std.testing.expectEqual(dot.InputEncoding.utf8, N.inspectSource("\xff\xfe\x00\x00", .utf8).selected.encoding);
    try std.testing.expectEqual(dot.InputEncoding.utf16le, N.inspectSource("\xff\xfe\x00\x00", .utf16le).selected.encoding);
    const Only = dot.Profile(.{ .source_encodings = &.{.utf32} });
    try std.testing.expectEqual(error.EncodingRequired, Only.inspectSource("", null).failure.reason);
    try std.testing.expect(Only.inspectSource("", null).failure.span == null);
    try std.testing.expect(Only.inspectSource("", .utf8).failure.span == null);
}

test "native name helpers match decoded UTF-8 hashes and check both ranges" {
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
        var buffer: [512]u8 = undefined;
        const source = encode(actual, "graph { café😀; \"café\"+\"😀\"; café; }", &buffer, true);
        var parsed = try P.parseBorrowed(gpa, source, dot.diagnostic.discard, .{});
        defer parsed.deinit(gpa);
        const document = &parsed.document.?;
        const a = document.nodeReference(document.nodes[0].reference).?.identifier;
        const b = document.nodeReference(document.nodes[1].reference).?.identifier;
        const c = document.nodeReference(document.nodes[2].reference).?.identifier;
        try std.testing.expect(try document.identifiersEqual(a, b));
        try std.testing.expect(!try document.identifiersEqual(a, c));
        try std.testing.expectEqual(try dot.identifier.hash("café😀"), try document.hashIdentifier(a));
        try std.testing.expectEqual(try document.hashIdentifier(a), try document.hashIdentifier(b));
        const bad: dot.Span = .{ .start = a.start + 1, .len = E.width };
        try std.testing.expectError(error.InvalidIdentifier, document.hashIdentifier(bad));
        try std.testing.expectError(error.InvalidIdentifier, document.identifiersEqual(a, bad));
        try std.testing.expectEqual(@as(usize, 3), document.capacities().nodes);
        // Framed but malformed native text cannot be decoded to a logical value.
        const H = dot.identifier.ForEncoding(actual);
        const parsed_a = H.assumeParsed(document.text(a));
        const parsed_b = H.assumeParsed(document.text(b));
        const parsed_c = H.assumeParsed(document.text(c));
        try std.testing.expect(try parsed_a.eql(parsed_b));
        try std.testing.expect(!try parsed_a.eql(parsed_c));
        try std.testing.expectEqual(try document.hashIdentifier(a), try parsed_a.hash());
        try std.testing.expectEqual(try parsed_a.hash(), try parsed_b.hash());
        var raw: [4]u8 = undefined;
        if (E.width == 2) std.mem.writeInt(u16, raw[0..2], 0xd800, E.endian) else std.mem.writeInt(u32, &raw, 0x110000, E.endian);
        try std.testing.expectError(error.InvalidIdentifier, H.hash(raw[0..E.width]));
        try std.testing.expectError(error.InvalidIdentifier, H.eql(document.text(c), raw[0..E.width]));
        // The parser accepts framed malformed native characters with encoding
        // validation off. The trusted syntax path must not assume valid Unicode.
        var malformed_buffer: [128]u8 = undefined;
        const malformed_source = encode(actual, "graph { x; }", &malformed_buffer, false);
        @memcpy(malformed_buffer[8 * E.width ..][0..E.width], raw[0..E.width]);
        var malformed_parse = try P.parseBorrowed(gpa, malformed_source, dot.diagnostic.discard, .{ .encoding = actual });
        defer malformed_parse.deinit(gpa);
        try std.testing.expect(malformed_parse.outcome == .success);
        const malformed_document = &malformed_parse.document.?;
        const malformed_range = malformed_document.nodeReference(malformed_document.nodes[0].reference).?.identifier;
        const malformed = H.assumeParsed(malformed_document.text(malformed_range));
        try std.testing.expectError(error.InvalidIdentifier, malformed.hash());
        try std.testing.expectError(error.InvalidIdentifier, parsed_c.eql(malformed));
        try std.testing.expectError(error.InvalidIdentifier, malformed.eql(parsed_c));
        const position = try dot.location.textPosition(source, a.start + a.len, .{ .source_encoding = actual });
        try std.testing.expectEqual(@as(u32, 15), position.character); // BOM + "graph { " + café + emoji pair.
    }
}

test "parser-certified names preserve escape and concatenation semantics across encodings" {
    inline for (.{ .ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const H = dot.identifier.ForEncoding(actual);
        const P = dot.Profile(.{ .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 } });
        const spellings = [_][]const u8{
            "\"a\"/*gap*/+\"\"",
            "a",
            "\"a\\\r\nb\"",
            "<ab>",
            "\"a\"+<>+\"b\"",
            "\"a\\\"b\"",
            "\"a\\nb\"",
            "\"\"",
            "<>",
            "-01.50",
        };
        for (spellings) |a| for (spellings) |b| {
            var text: [256]u8 = undefined;
            const raw = try std.fmt.bufPrint(&text, "graph {{ {s}; {s}; }}", .{ a, b });
            var buffer: [1024]u8 = undefined;
            const source = encode(actual, raw, &buffer, false);
            var parsed = try P.parseBorrowed(gpa, source, dot.diagnostic.discard, .{ .encoding = actual });
            defer parsed.deinit(gpa);
            try std.testing.expect(parsed.outcome == .success);
            const document = &parsed.document.?;
            const left = document.text(document.nodeReference(document.nodes[0].reference).?.identifier);
            const right = document.text(document.nodeReference(document.nodes[1].reference).?.identifier);
            const trusted_left = H.assumeParsed(left);
            const trusted_right = H.assumeParsed(right);
            try std.testing.expectEqual(try H.hash(left), try trusted_left.hash());
            try std.testing.expectEqual(try dot.identifier.hash(a), try trusted_left.hash());
            try std.testing.expectEqual(try H.eql(left, right), try trusted_left.eql(trusted_right));
        };
    }
}

test "documented markup session sizes include default typo recovery" {
    if (@import("builtin").cpu.arch != .aarch64 or @import("builtin").os.tag != .macos) return error.SkipZigTest;
    // Zig 0.17 adds one SafetyLock to each of the builder's two ArrayLists.
    const safety_bytes: usize = if (@import("builtin").mode.runtimeSafety()) 16 else 0;
    try std.testing.expectEqual(@as(usize, 440) + safety_bytes, @sizeOf(markup.Profile(.{}).Session));
    try std.testing.expectEqual(@as(usize, 448) + safety_bytes, @sizeOf(markup.BoundedSession));
    try std.testing.expectEqual(@as(usize, 528) + safety_bytes, @sizeOf(markup.Profile(.{ .runtime_policy = true }).Session));
    const Exact = markup.Profile(.{ .policy = .{ .closing_tag_recovery = .exact } });
    const ExactBounded = markup.Profile(.{ .policy = .{ .closing_tag_recovery = .exact, .execution = .{ .metering = true } } });
    try std.testing.expectEqual(@as(usize, 432) + safety_bytes, @sizeOf(Exact.Session));
    try std.testing.expectEqual(@as(usize, 440) + safety_bytes, @sizeOf(ExactBounded.Session));
}

test "native partial validation checks retained scoped operators at physical offsets" {
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| inline for (.{ .scalar, .block }) |scanner| {
        const E = dot.encoding.Reader(actual);
        const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .scanner = scanner, .retention = .{ .partial = true } } });
        for ([_][]const u8{ "graph { a -> {b} [x=1", "graph { a -> subgraph s { c } -> d", "graph { {a} -> b [x=1" }) |text| {
            inline for (.{ false, true }) |bom| {
                var input: [256]u8 = undefined;
                const bytes = encode(actual, text, &input, bom);
                var bag: dot.FixedDiagnosticBag(16) = .{};
                var parsed = try P.parseAndValidate(gpa, bytes, bag.sink(), .{ .encoding = actual });
                defer parsed.deinit(gpa);
                const document = &parsed.document.?;
                const framing: u32 = if (!bom) 0 else if (E.width == 2) 2 else 4;
                const expected_end: u32 = framing + @as(u32, @intCast(std.mem.lastIndexOf(u8, text, "}").? + 1)) * E.width;
                try std.testing.expectEqual(expected_end, document.retained_end);
                try std.testing.expectEqual(expected_end, parsed.validation.?.coverage.incomplete);
                const left_scope = std.mem.startsWith(u8, text, "graph { {");
                try std.testing.expectEqual(@as(u64, if (left_scope) 0 else 1), parsed.validation.?.outcome.completed.violations);
                for (bag.items()) |d| if (d.code == .validation_operator_mismatch) {
                    try std.testing.expectEqual(framing + 10 * E.width, d.span.start);
                    try std.testing.expectEqual(@as(u32, 2 * E.width), d.span.len);
                };
                try std.testing.expectEqual(@as(usize, 1), document.statementCount());
                try std.testing.expectEqual(@as(usize, 0), document.rootStatementCount());
                var statements = document.statements();
                try std.testing.expect(statements.next().? == .node);
                try std.testing.expect(statements.next() == null);
                try std.testing.expect(!parsed.documentValid());
            }
        }
    };
}

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
    var unchecked = try Native.parseBorrowed(gpa, "\x00\xd8", markup.diagnostic.discard, .{ .encoding = .utf16le });
    defer unchecked.deinit();
    try std.testing.expectEqual(.success, unchecked.outcome);
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
    const source = "<a" ++ std.mem.asBytes(&@as([130][" x='1'".len]u8, @splat(" x='1'".*))) ++ ">";
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
        const bytes = encode(actual, "<" ++ &@as([100]u8, @splat('x')) ++ "></y>", &buffer, false);
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

fn corrupt(comptime actual: dot.InputEncoding, buffer: []u8, at: usize, unit: u32) void {
    const E = dot.encoding.Reader(actual);
    switch (E.width) {
        1 => buffer[at] = @intCast(unit),
        2 => std.mem.writeInt(u16, buffer[at..][0..2], @intCast(unit), E.endian),
        4 => std.mem.writeInt(u32, buffer[at..][0..4], unit, E.endian),
        else => unreachable,
    }
}

test "encoding findings cover all readers with fixed runtime and storage parity" {
    const caps = &.{ .ascii, .utf8, .utf16, .utf32 };
    const RuntimeDot = dot.Profile(.{ .source_encodings = caps, .runtime_policy = true });
    const RuntimeMarkup = markup.Profile(.{ .source_encodings = caps, .runtime_policy = true });
    inline for (.{ .ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| inline for (.{ .err, .warning, .off }) |severity| {
        const E = dot.encoding.Reader(actual);
        const bad: u32 = if (E.width == 1) 0xff else if (E.width == 2) 0xd800 else 0x110000;
        const D = dot.Profile(.{ .source_encodings = caps, .policy = .{ .validation = .{ .invalid_encoding = severity } } });
        const M = markup.Profile(.{ .source_encodings = caps, .policy = .{ .mode = .structural, .validation = .{ .invalid_encoding = severity } } });
        var buffer: [256]u8 = undefined;
        const text = "graph { X [x=\"Y\"] } //Z";
        const source = encode(actual, text, &buffer, false);
        inline for (.{ 'X', 'Y', 'Z' }) |marker| corrupt(actual, &buffer, std.mem.indexOfScalar(u8, text, marker).? * E.width, bad);
        var bag: dot.FixedDiagnosticBag(16) = .{};
        var dynamic_bag: dot.FixedDiagnosticBag(16) = .{};
        var checked = try D.parseAndValidate(gpa, source, bag.sink(), .{ .encoding = actual });
        defer checked.deinit(gpa);
        var dynamic = try RuntimeDot.parseAndValidate(gpa, source, dynamic_bag.sink(), .{ .encoding = actual, .policy = .{ .validation = .{ .invalid_encoding = severity } } });
        defer dynamic.deinit(gpa);
        try std.testing.expectEqual(.success, checked.outcome);
        try std.testing.expectEqual(severity != .err, checked.documentValid());
        try std.testing.expectEqual(@as(u64, if (severity == .err) 3 else 0), checked.validation.?.outcome.completed.violations);
        try std.testing.expectEqual(@as(u64, if (severity == .warning) 3 else 0), checked.warnings);
        try std.testing.expectEqualDeep(checked.validation, dynamic.validation);
        try std.testing.expectEqualDeep(bag.items(), dynamic_bag.items());
        const rechecked = try D.validate(&checked.document.?, dot.diagnostic.discard, .{});
        try std.testing.expectEqualDeep(checked.validation.?, rechecked);
        for (bag.items()) |finding| {
            try std.testing.expectEqual(@as(u32, E.width), finding.span.len);
            try std.testing.expectEqual(actual, finding.details.invalid_encoding.encoding);
            try std.testing.expectEqual(bad, finding.details.invalid_encoding.unit);
        }

        const mt = "<X a='Y'>Z<!--W--><![CDATA[V]]></X>";
        var markup_buffer: [256]u8 = undefined;
        const ms = encode(actual, mt, &markup_buffer, false);
        for (mt, 0..) |byte, index| if (byte >= 'V' and byte <= 'Z') corrupt(actual, &markup_buffer, index * E.width, bad);
        var mbag: markup.FixedDiagnosticBag(16) = .{};
        var mdbag: markup.FixedDiagnosticBag(16) = .{};
        var mc = try M.parseAndValidate(gpa, try markup.Fragment.init(ms, 20), mbag.sink(), .{ .encoding = actual });
        defer mc.deinit();
        var md = try RuntimeMarkup.parseAndValidate(gpa, try markup.Fragment.init(ms, 20), mdbag.sink(), .{ .encoding = actual, .policy = .{ .mode = .structural, .validation = .{ .invalid_encoding = severity } } });
        defer md.deinit();
        try std.testing.expectEqual(.success, mc.parse.outcome);
        try std.testing.expectEqual(severity != .err, mc.documentValid());
        try std.testing.expectEqual(if (severity == .off) .not_run else .complete, mc.validation.?.checks.invalid_encoding);
        try std.testing.expectEqual(@as(u64, if (severity == .err) 6 else 0), mc.validation.?.errors);
        try std.testing.expectEqual(@as(u64, if (severity == .warning) 6 else 0), mc.validation.?.warnings);
        try std.testing.expectEqualDeep(mc.validation, md.validation);
        try std.testing.expectEqualDeep(mbag.items(), mdbag.items());
        // The fixed standalone source pass shares the same kernel and origin
        // rebasing remains a fragment adapter responsibility.
        var local_bag: markup.FixedDiagnosticBag(16) = .{};
        var scratch: markup.FixedSourceValidationScratch(1) = .{};
        const local = try M.validateSourceIn(ms, scratch.storage(), local_bag.sink(), .{ .encoding = actual });
        try std.testing.expectEqualDeep(mc.validation.?, local);
        for (local_bag.items(), mbag.items()) |local_finding, original| {
            try std.testing.expectEqual(local_finding.span.start + 20, original.span.start);
            try std.testing.expectEqual(@as(u32, E.width), original.span.len);
            try std.testing.expectEqual(actual, original.details.invalid_encoding.encoding);
        }
        var storage: markup.FixedDocumentStorage(.{ .nodes = 8, .attributes = 1 }) = .{};
        var frames: markup.FixedParseScratch(2) = .{};
        var fixed_bag: markup.FixedDiagnosticBag(16) = .{};
        const fixed = try M.parseAndValidateIn(try markup.Fragment.init(ms, 20), .{ .document = storage.storage(), .scratch = frames.storage() }, scratch.storage(), fixed_bag.sink(), .{ .encoding = actual });
        try std.testing.expectEqualDeep(mc.validation, fixed.validation);
        try std.testing.expectEqualDeep(mbag.items(), fixed_bag.items());
    };
}

test "DOT and markup encoding severities are independent in proactive composition" {
    const Child = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .structural } });
    const P = dot.Profile(.{ .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 }, .runtime_policy = true, .processors = .{ .markup = Child } });
    inline for (.{ .ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        const bad: u32 = if (E.width == 1) 0xff else 0xd800;
        var buffer: [512]u8 = undefined;
        const text = "graph { a[label=<<b>X</b>>+\"Y\"] } //Z";
        const source = encode(actual, text, &buffer, false);
        inline for (.{ 'X', 'Y', 'Z' }) |marker| corrupt(actual, &buffer, std.mem.indexOfScalar(u8, text, marker).? * E.width, bad);
        inline for (.{ .err, .warning, .off }) |outer| inline for (.{ .err, .warning, .off }) |inner| {
            var bag: P.FixedDiagnosticBag(16) = .{};
            var result = try P.parseAndValidate(gpa, source, bag.sink(), .{
                .encoding = actual,
                .dot = .{ .policy = .{ .validation = .{ .invalid_encoding = outer } } },
                .markup = .{ .policy = .{ .validation = .{ .invalid_encoding = inner } } },
            });
            defer result.deinit(gpa);
            try std.testing.expect(result.scopeComplete());
            try std.testing.expectEqual(outer != .err, result.dot.documentValid());
            try std.testing.expectEqual(inner != .err, result.markup.allValid());
            try std.testing.expectEqual(outer != .err and inner != .err, result.documentValid());
            var dot_count: usize = 0;
            var markup_count: usize = 0;
            for (bag.items()) |finding| switch (finding) {
                .dot => |d| {
                    dot_count += 1;
                    try std.testing.expectEqual(actual, d.details.invalid_encoding.encoding);
                    try std.testing.expect(d.span.start != std.mem.indexOfScalar(u8, text, 'X').? * E.width);
                },
                .markup => |m| {
                    markup_count += 1;
                    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOfScalar(u8, text, 'X').? * E.width)), m.span.start);
                    try std.testing.expectEqual(actual, m.details.invalid_encoding.encoding);
                },
            };
            try std.testing.expectEqual(@as(usize, if (outer == .off) 0 else 2), dot_count);
            try std.testing.expectEqual(@as(usize, if (inner == .off) 0 else 1), markup_count);
        };
    }
}

test "passthrough skips inner encoding and delayed processing reports it once" {
    const Child = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .invalid_encoding = .err } } });
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .processors = .{ .markup = Child }, .policy = .{ .markup = .passthrough, .retention = .{ .markup = true }, .validation = .{ .invalid_encoding = .err } } });
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var buffer: [512]u8 = undefined;
        const text = "graph { a[label=<<b>X</b>>] }";
        const source = encode(actual, text, &buffer, true);
        const at = std.mem.indexOfScalar(u8, text, 'X').? * E.width + E.bomLength(source);
        corrupt(actual, &buffer, at, if (E.width == 1) 0xff else 0xd800);
        var bag: P.FixedDiagnosticBag(16) = .{};
        var result = try P.parseAndValidate(gpa, source, bag.sink(), .{});
        defer result.deinit(gpa);
        try std.testing.expect(result.dot.documentValid());
        try std.testing.expect(!result.markup.requested);
        try std.testing.expectEqual(@as(usize, 0), bag.items().len);
        try result.requestMarkup(gpa, result.dot.document.?.attributes[0].value);
        try std.testing.expectEqual(.not_processed, result.state());
        try P.processPendingMarkup(gpa, &result, bag.sink(), .{});
        try std.testing.expect(result.dot.documentValid());
        try std.testing.expect(!result.documentValid());
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        try std.testing.expectEqual(@as(u32, @intCast(at)), bag.items()[0].markup.span.start);
        try std.testing.expectEqual(.complete, result.markupResults().?[0].result.validation.?.checks.invalid_encoding);
    }
}

test "public encoding scopes ignore malformed content outside their bounds" {
    const P = markup.Profile(.{ .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 }, .policy = .{ .mode = .structural, .validation = .{ .invalid_encoding = .err, .duplicate_attribute = .off } } });
    inline for (.{ .ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var buffer: [64]u8 = undefined;
        const source = encode(actual, "XokY", &buffer, false);
        corrupt(actual, &buffer, 0, if (E.width == 1) 0xff else 0xd800);
        corrupt(actual, &buffer, 3 * E.width, if (E.width == 1) 0xff else 0xd800);
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const scoped = try P.validateScopeIn(source, .{ .bytes = .{ .start = E.width, .len = 2 * E.width } }, .{}, bag.sink(), .{ .encoding = actual });
        try std.testing.expectEqual(.complete, scoped.checks.invalid_encoding);
        try std.testing.expectEqual(.valid, scoped.validity);
        try std.testing.expectEqual(@as(usize, 0), bag.items().len);
        const outside = try P.validateScope(gpa, source, .{ .bytes = .{ .start = 0, .len = E.width } }, bag.sink(), .{ .encoding = actual });
        try std.testing.expectEqual(.invalid, outside.validity);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        try std.testing.expectEqual(@as(u32, E.width), bag.items()[0].span.len);
    }
    // A UTF-16 pair is valid only when both units are inside the checked scope.
    const pair = "\x00\xd8\x00\xdc";
    const whole = try P.validateScopeIn(pair, .{ .bytes = .{ .start = 0, .len = 4 } }, .{}, markup.diagnostic.discard, .{ .encoding = .utf16le });
    try std.testing.expectEqual(.valid, whole.validity);
    const half = try P.validateScopeIn(pair, .{ .bytes = .{ .start = 0, .len = 2 } }, .{}, markup.diagnostic.discard, .{ .encoding = .utf16le });
    try std.testing.expectEqual(.invalid, half.validity);
}

test "UTF-8 byte validators respect ASCII provenance even when validity was not checked" {
    const A = dot.Profile(.{ .source_encodings = &.{} });
    const D = dot.Profile(.{ .policy = .{ .validation = .{ .invalid_encoding = .err } } });
    var doc = try A.parseBorrowed(gpa, "graph { é }", dot.diagnostic.discard, .{});
    defer doc.deinit(gpa);
    const checked = D.validate(&doc.document.?, dot.diagnostic.discard, .{});
    try std.testing.expectEqual(@as(u64, 2), checked.outcome.completed.violations);
    const AM = markup.Profile(.{ .source_encodings = &.{}, .policy = .{ .mode = .structural } });
    const M = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .invalid_encoding = .err } } });
    var mdoc = try AM.parseBorrowed(gpa, "é", markup.diagnostic.discard, .{});
    defer mdoc.deinit();
    try std.testing.expectEqual(@as(u64, 2), M.validateIn(&mdoc.document.?, .{}, markup.diagnostic.discard, .{}).errors);
    try std.testing.expectEqual(@as(u64, 2), M.validate(gpa, &mdoc.document.?, markup.diagnostic.discard, .{}).errors);
}

test "markup recovery allowance uses source code units across native readers and policies" {
    const text = std.mem.asBytes(&@as([40]["<aa>".len]u8, @splat("<aa>".*))) ++ std.mem.asBytes(&@as([40]["</ab>".len]u8, @splat("</ab>".*)));
    inline for (.{ false, true }) |runtime| inline for (.{ .scalar, .block }) |scanner| {
        const M = markup.Profile(.{
            .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 },
            .runtime_policy = runtime,
            .policy = .{ .mode = .structural, .scanner = scanner, .on_error = if (runtime) .fail_fast else .collect },
        });
        inline for (.{ .ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
            const E = dot.encoding.Reader(actual);
            for ([_]bool{ false, true }) |with_bom| {
                var buffer: [text.len * 4 + 4]u8 = undefined;
                const source = encode(actual, text, &buffer, with_bom);
                var bag: markup.FixedDiagnosticBag(32) = .{};
                const options: M.ParseOptions = if (runtime)
                    .{ .encoding = actual, .policy = .{ .mode = .structural, .scanner = scanner, .on_error = .collect } }
                else
                    .{ .encoding = actual };
                var parsed = try M.parseBorrowed(gpa, source, bag.sink(), options);
                defer parsed.deinit();
                const credits: u32 = @intCast(E.units(source));
                try std.testing.expectEqual(markup.Outcome{ .resource_limit = .{ .resource = .recovery_work, .limit = credits } }, parsed.outcome);
                try std.testing.expectEqual(markup.Completion.incomplete, parsed.completion);
                // Four mismatches exhaust the same logical allowance in every
                // encoding. BOM code units count too, without altering this case.
                try std.testing.expectEqual(@as(u32, 4), parsed.syntax_errors);
                try std.testing.expectEqual(@as(u32, 40), parsed.counts.elements);
                try std.testing.expect(parsed.document == null);
                try std.testing.expectEqual(@as(usize, 5), bag.items().len);
                const exhausted = bag.items()[4];
                try std.testing.expectEqual(.recovery_work, exhausted.details.capacity.resource);
                try std.testing.expectEqual(credits, exhausted.details.capacity.limit);
                // Accounting units must not leak into physical-byte locations.
                const framing: u32 = if (with_bom) E.bomLength(source) else 0;
                try std.testing.expectEqual(@as(u32, @intCast(framing + (40 * 4 + 4 * 5) * E.width)), exhausted.span.start);
            }
        }
    };
}

test "native one-shot typo policies preserve physical spans and code-unit comparisons" {
    const Case = struct { text: []const u8, strategy: markup.ClosingTagRecovery, errors: u32 };
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| {
        const P = markup.Profile(.{ .runtime_policy = runtime, .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .mode = .structural, .scanner = scanner } });
        for ([_]Case{
            .{ .text = "<config><server></servr></config>", .strategy = .one_edit, .errors = 1 },
            .{ .text = "<config><configuration></ocnfiguratiom></config>", .strategy = .two_edits, .errors = 1 },
            // UTF-8 counts original bytes, not decoded Unicode characters.
            .{ .text = "<config><café></cafe></config>", .strategy = .one_edit, .errors = if (actual == .utf8) 2 else 1 },
        }) |case| {
            var buffer: [512]u8 = undefined;
            const source = encode(actual, case.text, &buffer, true);
            var bag: markup.FixedDiagnosticBag(8) = .{};
            const patch: markup.Policy = .{ .closing_tag_recovery = case.strategy };
            const Fixed = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .mode = .structural, .scanner = scanner, .closing_tag_recovery = .two_edits } });
            // Fixed comparison uses two edits only for the long-name case;
            // the short-name fallback retains identical one-edit behavior.
            var parsed = if (runtime)
                try P.parseBorrowed(gpa, source, bag.sink(), .{ .policy = patch })
            else
                try Fixed.parseBorrowed(gpa, source, bag.sink(), .{});
            defer parsed.deinit();
            try std.testing.expectEqual(markup.Outcome.invalid_syntax, parsed.outcome);
            try std.testing.expectEqual(markup.Completion.complete, parsed.completion);
            try std.testing.expectEqual(case.errors, parsed.syntax_errors);
            const first = bag.items()[0];
            try std.testing.expectEqual(markup.diagnostic.Code.mismatched_tag, first.code);
            try std.testing.expect(first.span.endOffset() <= source.len);
            try std.testing.expect(first.related.?.endOffset() <= source.len);
            const expected_name = if (case.strategy == .two_edits) "ocnfiguratiom" else if (std.mem.indexOf(u8, case.text, "café") != null) "cafe" else "servr";
            var expected_buffer: [128]u8 = undefined;
            try std.testing.expectEqualSlices(u8, encode(actual, expected_name, &expected_buffer, false), first.span.slice(source));
            var prefix_buffer: [256]u8 = undefined;
            const prefix_len = encode(actual, case.text[0 .. std.mem.indexOf(u8, case.text, "</").? + 2], &prefix_buffer, false).len;
            try std.testing.expectEqual(@as(u32, @intCast(prefix_len + markup.encoding.Reader(actual).bomLength(source))), first.span.start);
        }
    };
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

test "ASCII validity is a scoped encoding policy not an admission failure" {
    const D = dot.Profile(.{ .source_encodings = &.{}, .policy = .{ .validation = .{ .invalid_encoding = .err } } });
    const M = markup.Profile(.{ .source_encodings = &.{}, .policy = .{ .mode = .structural, .validation = .{ .invalid_encoding = .err } } });
    var bag: dot.FixedDiagnosticBag(8) = .{};
    var okay = try D.parseBorrowed(gpa, "graph { a }", bag.sink(), .{});
    defer okay.deinit(gpa);
    try std.testing.expect(okay.outcome == .success);
    inline for (.{ "graph { a [x=\"é\"] }", "graph { //é\n a }", "graph { /*é*/ a }", "graph { #é\n a }", "graph { <é> }" }) |source| {
        bag.reset();
        var checked = try D.parseAndValidate(gpa, source, bag.sink(), .{});
        defer checked.deinit(gpa);
        try std.testing.expectEqual(.success, checked.outcome);
        const html = comptime std.mem.eql(u8, source, "graph { <é> }");
        try std.testing.expectEqual(html, checked.documentValid());
        try std.testing.expectEqual(@as(usize, if (html) 0 else 2), bag.items().len);
        for (bag.items()) |d| try std.testing.expectEqual(.ascii, d.details.invalid_encoding.encoding);
    }
    var mbag: markup.FixedDiagnosticBag(8) = .{};
    var checked = try M.parseAndValidate(gpa, try markup.Fragment.init("<!--é-->", 0), mbag.sink(), .{});
    defer checked.deinit();
    try std.testing.expect(!checked.documentValid());
    try std.testing.expectEqual(@as(usize, 2), mbag.items().len);
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

test "native selection requires byte order and complete unit framing" {
    const D = dot.Profile(.{ .source_encodings = &.{.utf32} });
    var bag: dot.FixedDiagnosticBag(8) = .{};
    try std.testing.expectError(error.EncodingRequired, D.parseBorrowed(gpa, "graph {}", bag.sink(), .{}));
    try std.testing.expectError(error.UnsupportedEncoding, D.parseBorrowed(gpa, "graph {}", bag.sink(), .{ .encoding = .utf8 }));
    try std.testing.expectError(error.TruncatedCodeUnit, D.parseBorrowed(gpa, "\xff\xfe\x00\x00x", bag.sink(), .{}));
    var malformed = try D.parseBorrowed(gpa, "\xff\xfe\x00\x00\x00\xd8\x00\x00", bag.sink(), .{});
    defer malformed.deinit(gpa);
    try std.testing.expectEqual(.invalid_syntax, malformed.outcome); // Missing DOT header, not admission.
    const U = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    // Explicit UTF-16LE sees its own two-byte BOM followed by NUL, not a
    // conflicting UTF-32LE signature. NUL is a grammar failure, not framing.
    var narrow = try U.parseBorrowed(gpa, "\xff\xfe\x00\x00", bag.sink(), .{ .encoding = .utf16le });
    defer narrow.deinit(gpa);
    try std.testing.expectEqual(dot.ParseOutcome.invalid_syntax, narrow.outcome);
    var surrogate = try U.parseBorrowed(gpa, "\xfe\xff\xd8\x00", bag.sink(), .{});
    defer surrogate.deinit(gpa);
    try std.testing.expectEqual(.invalid_syntax, surrogate.outcome);
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

test "explicit UTF-8 markup selection does not redetect a foreign BOM" {
    const P = markup.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .mode = .structural } });
    const source = "\xff\xfe<a/>";
    var result = try P.parseBorrowed(gpa, source, markup.diagnostic.discard, .{ .encoding = .utf8 });
    defer result.deinit();
    try std.testing.expectEqual(markup.Outcome.success, result.outcome);
    try std.testing.expectEqual(.explicit, result.document.?.source_info.provenance);
    try std.testing.expectEqual(.utf8, result.document.?.source_info.encoding);
    try std.testing.expect(!result.document.?.source_info.has_bom);
    const checked = try P.validateSource(gpa, source, markup.diagnostic.discard, .{ .encoding = .utf8 });
    try std.testing.expectEqual(.complete, checked.completion);
}
