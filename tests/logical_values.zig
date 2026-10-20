const std = @import("std");
test {
    _ = @import("string_integration.zig");
}
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const strings = @import("string_processor");
const t = std.testing;
const logical = strings.logical;

test {
    _ = @import("logical_validation.zig");
}

fn collect(reader: anytype, output: []u8) ![]const u8 {
    var used: usize = 0;
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > 100_000) return error.NoProgress;
        switch (reader.step()) {
            .pending => {},
            .scalar => |item| {
                var bytes: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(item.codepoint, &bytes);
                if (output.len - used < len) return error.NoSpaceLeft;
                @memcpy(output[used..][0..len], bytes[0..len]);
                used += len;
            },
            .end => return output[0..used],
            .failure => return error.LogicalFailure,
        }
    }
}
fn scalar(reader: anytype) !logical.Scalar {
    for (0..100_000) |_| switch (reader.step()) {
        .pending => {},
        .scalar => |item| return item,
        else => return error.ExpectedScalar,
    };
    return error.NoProgress;
}
fn failure(reader: anytype) !logical.Failure {
    for (0..100_000) |_| switch (reader.step()) {
        .pending, .scalar => {},
        .failure => |f| {
            try t.expectEqualDeep(f, reader.step().failure);
            return f;
        },
        .end => return error.ExpectedFailure,
    };
    return error.NoProgress;
}
fn encode(comptime actual: dot.InputEncoding, text: []const u8, buffer: []u8) ![]const u8 {
    const E = dot.encoding.Reader(actual);
    var source: usize = 0;
    var dest: usize = 0;
    while (source < text.len) {
        const cp = try dot.encoding.Reader(.utf8).decode(text, source);
        source += cp.len;
        if (E.width == 1) {
            @memcpy(buffer[dest..][0..cp.len], text[source - cp.len .. source]);
            dest += cp.len;
        } else if (E.width == 2) {
            if (cp.scalar <= 0xffff) {
                std.mem.writeInt(u16, buffer[dest..][0..2], @intCast(cp.scalar), E.endian);
                dest += 2;
            } else {
                const v: u32 = cp.scalar - 0x10000;
                std.mem.writeInt(u16, buffer[dest..][0..2], @intCast(0xd800 + (v >> 10)), E.endian);
                std.mem.writeInt(u16, buffer[dest + 2 ..][0..2], @intCast(0xdc00 + (v & 1023)), E.endian);
                dest += 4;
            }
        } else {
            std.mem.writeInt(u32, buffer[dest..][0..4], cp.scalar, E.endian);
            dest += 4;
        }
    }
    return buffer[0..dest];
}

test "shared types and standalone borrowed fast path preserve contents and BOM" {
    try t.expect(dot.logical.Step == markup.logical.Step and markup.logical.Step == logical.Step);
    const bytes = "\u{feff}A&amp;B";
    var reader = try strings.LogicalReader(.utf8).init(.{ .bytes = bytes, .origin = 10 });
    try t.expect(reader.contiguous().?.bytes.ptr == bytes.ptr);
    try t.expectEqual(.utf8, reader.contiguous().?.encoding);
    try t.expectEqual(.exact, reader.location().mapping);
    var buffer: [64]u8 = undefined;
    try t.expectEqualStrings(bytes, try collect(&reader, &buffer));
    try t.expectEqual(.end, reader.step());
    var empty = try strings.LogicalReader(.utf8).init(.{ .bytes = "", .origin = 50 });
    try t.expectEqualDeep(dot.location.Span{ .start = 50, .len = 0 }, empty.location().span);
    try t.expectEqual(.end, empty.step());
    try t.expectError(error.InvalidFragment, strings.LogicalReader(.utf8).init(.{ .bytes = "abc", .origin = std.math.maxInt(u32) - 1 }));
}

test "markup references produce logical scalars with exact original spelling spans" {
    var reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "A&amp;B&#x1F600;", .origin = 90 }, .{});
    try t.expect(reader.contiguous() == null);
    try t.expectEqual(.enclosing, reader.location().mapping);
    const a = try scalar(&reader);
    try t.expectEqual('A', a.codepoint);
    try t.expectEqualDeep(dot.location.Span{ .start = 90, .len = 1 }, a.location.span);
    const amp = try scalar(&reader);
    try t.expectEqual('&', amp.codepoint);
    try t.expectEqualDeep(dot.location.Span{ .start = 91, .len = 5 }, amp.location.span);
    try t.expectEqual('B', (try scalar(&reader)).codepoint);
    const emoji = try scalar(&reader);
    try t.expectEqual(0x1f600, emoji.codepoint);
    try t.expectEqualDeep(dot.location.Span{ .start = 97, .len = 9 }, emoji.location.span);
    try t.expectEqual(.end, reader.step());
}

test "markup catalog and malformed-reference behavior are explicit and not guessed" {
    var out: [128]u8 = undefined;
    inline for (.{ .reject, .warn, .accept }) |acceptance| {
        inline for (.{ "&", "&a#b;", "&#x;", "&#5;", "&#x110000;", "&#999999999999999999999999999;", "&amp" }) |raw| {
            var reader = try markup.LogicalReader(.utf8).init(.{ .bytes = raw, .origin = 7 }, .{ .malformed_reference = acceptance });
            if (acceptance == .reject) {
                try t.expectEqual(.invalid_syntax, (try failure(&reader)).reason);
            } else try t.expectEqualStrings(raw, try collect(&reader, &out));
        }
    }
    var unknown = try markup.LogicalReader(.utf8).init(.{ .bytes = "&nbsp;", .origin = 8 }, .{ .malformed_reference = .accept });
    const f = try failure(&unknown);
    try t.expectEqual(.unresolved_reference, f.reason);
    try t.expectEqualDeep(dot.location.Span{ .start = 8, .len = 6 }, f.location.span);
    var known = try markup.LogicalReader(.utf8).init(.{ .bytes = "&nbsp;&amp;&apos;&#160;&#xA0;", .origin = 8 }, .{ .references = .graphviz });
    try t.expectEqualStrings("\u{a0}&'\u{a0}\u{a0}", try collect(&known, &out));
    var case = try markup.LogicalReader(.utf8).init(.{ .bytes = "&AMP;", .origin = 0 }, .{ .references = .graphviz });
    try t.expectEqual(.unresolved_reference, (try failure(&case)).reason);
    // A decoded '&' is never reparsed as the start of another reference.
    var once = try markup.LogicalReader(.utf8).init(.{ .bytes = "&amp;amp;", .origin = 0 }, .{});
    try t.expectEqualStrings("&amp;", try collect(&once, &out));
}

test "markup normalization follows host options and never normalizes referenced whitespace" {
    var buffer: [64]u8 = undefined;
    inline for (.{ false, true }) |normalize| {
        var reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "a\t\r\n&#9;&#10;&#13;b", .origin = 0 }, .{ .normalize_attribute_whitespace = normalize });
        try t.expectEqualStrings(if (normalize) "a   \t\n\rb" else "a\t\r\n\t\n\rb", try collect(&reader, &buffer));
    }
}

test "DOT lexical decoding parity without losing operand or escape provenance" {
    const cases = .{
        "bare",                   "-0.50",            "\"\"",                                               "\"S\" + \"F\"",            "\"a\\\"b\"", "\"a\\nb\\\\c\\q\"",
        "\"a\\\nb\\\r\nc\\\rd\"", "\"a\nb\r\nc\rd\"", "\"a\" /* \" */ + // \"\r\n # \"\r \"b\"+\"\"+\"c\"", "\"a\" /* \xff */ + \"b\"",
        "\"é\\😀\"",
        "\"a\\\\\"",
    };
    inline for (cases) |raw| {
        var reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = raw, .origin = 14 });
        var actual: [256]u8 = undefined;
        var expected: [256]u8 = undefined;
        try t.expectEqualStrings(try dot.identifier.decodeInto(raw, &expected), try collect(&reader, &actual));
    }
    var reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"S\" + \"F\\\"\"", .origin = 100 });
    try t.expect(reader.contiguous() == null);
    const s = try scalar(&reader);
    const f = try scalar(&reader);
    const quote = try scalar(&reader);
    try t.expectEqual(@as(u32, 100), s.location.segment_start);
    try t.expectEqual(@as(u32, 106), f.location.segment_start);
    try t.expectEqualDeep(dot.location.Span{ .start = 108, .len = 2 }, quote.location.span);
    try t.expectEqual(@as(u32, 106), quote.location.segment_start);
}

test "DOT unsupported markup and broken framing terminate explicitly" {
    inline for (.{ "<b>", "\"S\" + <<b>F</b>>" }) |raw| {
        var reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = raw, .origin = 0 });
        try t.expectEqual(.unsupported_form, (try failure(&reader)).reason);
    }
    inline for (.{ "", "\"a", "\"a\\", "\"a\"+", "\"a\"+b", "\"a\" \"b\"", "\"a\" /*", "\"a\" /x", "\"a\x00\"" }) |raw| {
        var reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = raw, .origin = 0 });
        try t.expectEqual(.invalid_syntax, (try failure(&reader)).reason);
    }
}

test "all encodings share logical values and physical-byte locations" {
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width: u32 = dot.encoding.unitBytes(actual);
        var source: [512]u8 = undefined;
        var output: [128]u8 = undefined;
        const text = try encode(actual, "A&amp;😀é&#x4E2D;", &source);
        var reader = try markup.LogicalReader(actual).init(.{ .bytes = text, .origin = 13 }, .{});
        _ = try scalar(&reader);
        const amp = try scalar(&reader);
        try t.expectEqualDeep(dot.location.Span{ .start = 13 + width, .len = 5 * width }, amp.location.span);
        const emoji = try scalar(&reader);
        try t.expectEqual(@as(u21, 0x1f600), emoji.codepoint);
        try t.expectEqualDeep(dot.location.Span{ .start = 13 + 6 * width, .len = 4 }, emoji.location.span);
        try t.expectEqualStrings("é中", try collect(&reader, &output));
        const expression = try encode(actual, "\"😀\\\"\" /* x */ + \"中\"", &source);
        var dots = try dot.identifier.LogicalReader(actual).init(.{ .bytes = expression, .origin = 13 });
        try t.expectEqualStrings("😀\"中", try collect(&dots, &output));
    }
    var ascii = try markup.LogicalReader(.ascii).init(.{ .bytes = "A&#x1f600;", .origin = 0 }, .{});
    var output: [16]u8 = undefined;
    try t.expectEqualStrings("A😀", try collect(&ascii, &output));
}

test "bounded steps can pause and move inside scalars long references and glue" {
    const zeros = &@as([4096]u8, @splat('0'));
    var reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "&#" ++ zeros ++ "65;Z", .origin = 1 }, .{});
    for (0..2000) |_| {
        const before = reader.position();
        try t.expectEqual(.pending, reader.step());
        try t.expect(reader.position() - before <= 1);
    }
    var moved = reader;
    reader = undefined;
    try t.expectEqual('A', (try scalar(&moved)).codepoint);
    try t.expectEqual('Z', (try scalar(&moved)).codepoint);
    try t.expectEqual(.end, moved.step());
    var dot_reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"a\" /*" ++ (&@as([4096]u8, @splat('x'))) ++ "*/ + \"😀\"", .origin = 0 });
    _ = try scalar(&dot_reader);
    for (0..2000) |_| {
        const before = dot_reader.position();
        try t.expectEqual(.pending, dot_reader.step());
        try t.expect(dot_reader.position() - before <= 1);
    }
    var moved_dot = dot_reader;
    dot_reader = undefined;
    try t.expectEqual(0x1f600, (try scalar(&moved_dot)).codepoint);
    var raw = try strings.LogicalReader(.utf8).init(.{ .bytes = "😀", .origin = 8 });
    for (0..3) |_| try t.expectEqual(.pending, raw.step());
    var moved_raw = raw;
    raw = undefined;
    try t.expectEqualDeep(dot.location.Span{ .start = 8, .len = 4 }, moved_raw.step().scalar.location.span);
    try t.expect(@sizeOf(@TypeOf(moved_dot)) <= 160);
    try t.expect(@sizeOf(@TypeOf(moved)) <= 160);
}

test "nested fragment provenance is already original and is not rebased twice" {
    const outer = try strings.Fragment.init("xxxA&amp;Bxxx", 100);
    const inner = try outer.child(.{ .start = 3, .len = 7 });
    var reader = try markup.LogicalReader(.utf8).init(inner, .{});
    _ = try scalar(&reader);
    try t.expectEqualDeep(dot.location.Span{ .start = 104, .len = 5 }, (try scalar(&reader)).location.span);
}

test "invalid and truncated encodings fail safely with original coordinates" {
    inline for (.{ .utf8, .ascii, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var reader = try strings.LogicalReader(actual).init(.{ .bytes = "\xff", .origin = 99 });
        const f = try failure(&reader);
        try t.expectEqual(.invalid_encoding, f.reason);
        try t.expectEqualDeep(dot.location.Span{ .start = 99, .len = 1 }, f.location.span);
    }
    var surrogate = try strings.LogicalReader(.utf16le).init(.{ .bytes = "\x3d\xd8", .origin = 1 });
    try t.expectEqual(.pending, surrogate.step());
    try t.expectEqual(.invalid_encoding, (try failure(&surrogate)).reason);
    var dot_reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"\xff\"", .origin = 9 });
    try t.expectEqual(.invalid_encoding, (try failure(&dot_reader)).reason);
    var markup_reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "&x\xff;", .origin = 9 }, .{ .malformed_reference = .accept });
    try t.expectEqual(.invalid_encoding, (try failure(&markup_reader)).reason);
}

test "reference lookup handles XML and long Graphviz names in every encoding" {
    // Public behavior, including numeric fallback, across all actual encodings.
    const entries = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "amp", .text = "&" },  .{ .name = "quot", .text = "\"" },
        .{ .name = "apos", .text = "'" }, .{ .name = "lt", .text = "<" },
        .{ .name = "gt", .text = ">" },
        .{ .name = "thetasym", .text = "ϑ" },
        .{ .name = "upsilon", .text = "υ" },
        .{ .name = "Alpha", .text = "Α" },
    };
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        for (entries) |entry| {
            var spelling_buffer: [64]u8 = undefined;
            const spelling = try std.fmt.bufPrint(&spelling_buffer, "&{s};", .{entry.name});
            var encoded: [256]u8 = undefined;
            var output: [16]u8 = undefined;
            var reader = try markup.LogicalReader(actual).init(.{ .bytes = try encode(actual, spelling, &encoded), .origin = 7 }, .{ .references = .graphviz });
            try t.expectEqualStrings(entry.text, try collect(&reader, &output));
        }
    }
}

fn drainChecked(reader: anytype, len: usize, origin: u32) !void {
    // Applies even to hostile hand-built fragments, not just parser views.
    for (0..5 * len + 32) |_| {
        const result = reader.step();
        const loc = switch (result) {
            .pending => continue,
            .end => {
                try t.expectEqual(.end, reader.step());
                return;
            },
            .failure => |f| f.location,
            .scalar => |item| item.location,
        };
        try t.expect(loc.span.start >= origin);
        try t.expect(loc.span.endOffset() <= origin + len);
        try t.expect(loc.segment_start >= origin and loc.segment_start <= origin + len);
        if (result == .failure) {
            try t.expectEqualDeep(result, reader.step());
            return;
        }
    }
    return error.UnboundedReader;
}

test "arbitrary fragments terminate with bounded state and in-range locations" {
    var random = std.Random.DefaultPrng.init(0x7f8072);
    var bytes: [32]u8 = undefined;
    const alphabet = "&;#x0129ab+/-*\"\r\n\\ \x00\x80\xc2\xe0\xf0\xff";
    for (0..1500) |iteration| {
        const len = random.random().uintLessThan(usize, bytes.len + 1);
        for (bytes[0..len]) |*b| b.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        const origin: u32 = if (iteration % 2 == 0) 9 else std.math.maxInt(u32) - 32;
        inline for (.{ .ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
            var raw = try strings.LogicalReader(actual).init(.{ .bytes = bytes[0..len], .origin = origin });
            try drainChecked(&raw, len, origin);
            var d = try dot.identifier.LogicalReader(actual).init(.{ .bytes = bytes[0..len], .origin = origin });
            try drainChecked(&d, len, origin);
            inline for (.{ markup.Acceptance.reject, .accept }) |acceptance| {
                var m = try markup.LogicalReader(actual).init(.{ .bytes = bytes[0..len], .origin = origin }, .{ .malformed_reference = acceptance });
                try drainChecked(&m, len, origin);
            }
        }
    }
}

test "DOT generated valid quoted expressions agree with existing decoding" {
    var random = std.Random.DefaultPrng.init(0x12ab5678);
    const chunks = [_][]const u8{ "a", "é", "😀", "\\\"", "\\\\", "\\n", "\\\n", "\\\r\n", "&amp;", "/*", "//", "+", "\\😀" };
    for (0..400) |_| {
        var source: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&source);
        const count = 1 + random.random().uintLessThan(usize, 8);
        for (0..count) |part| {
            if (part != 0) try writer.writeAll(" /* comment */ + // comment\n");
            try writer.writeByte('"');
            for (0..random.random().uintLessThan(usize, 10)) |_| try writer.writeAll(chunks[random.random().uintLessThan(usize, chunks.len)]);
            try writer.writeByte('"');
        }
        const spelling = writer.buffered();
        var expected: [2048]u8 = undefined;
        var output: [2048]u8 = undefined;
        var reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = spelling, .origin = 123 });
        try t.expectEqualStrings(try dot.identifier.decodeInto(spelling, &expected), try collect(&reader, &output));
    }
}
