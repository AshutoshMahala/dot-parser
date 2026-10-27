//! Explicit, allocation-free decoding of supported identifier expressions.
//!
//! Raw spelling stays in the document. These helpers validate one complete
//! identifier (no leading/trailing trivia), then decode on demand. `fromName`
//! skips syntax validation for complete typed names from parsing/check. Helpers do
//! not cache results, interpret layout escapes, normalize encoding, or convert
//! numerals. Repeated calls repeat linear work. Output memory is caller-owned.

const std = @import("std");
/// Incremental logical contents with shared original-source locations.
pub const LogicalReader = @import("logical.zig").Reader;
const lex = @import("lexer/lexer.zig");
const Chunks = @import("identifier_value.zig").Chunks;
const encoding = @import("parser_support").encoding;
const names = @import("name.zig");
const ParsedForEncoding = @import("parsed_name.zig").ForEncoding;

pub const DecodeError = error{ InvalidIdentifier, NoSpaceLeft, OverlappingBuffers };
pub const Form = enum { bare, numeral, quoted, html, concatenation };
pub const Part = @import("identifier_parts.zig").Part;
pub const Parts = @import("identifier_parts.zig").Parts;

/// Explicit delayed operand traversal. Validates only the selected expression,
/// not the DOT document; a second linear walk exposes original raw/inner spans.
/// No decoding, allocation, markup processing or parser-session work credits.
pub fn parts(source: []const u8, range: @import("parser_support").location.Span) error{ InvalidSpan, InvalidIdentifier }!Parts {
    const Fragment = @import("parser_support").processor.Fragment;
    const input = Fragment.fromSource(source, range) catch return error.InvalidSpan;
    const token = try validate(input.bytes);
    return .{ .input = input, .compound = token.flags.concatenated };
}

/// Validate one complete spelling and classify it. Concatenations are not
/// classified by their first operand. No decoding or allocation is performed.
pub fn form(raw: []const u8) error{InvalidIdentifier}!Form {
    const token = try validate(raw);
    if (token.flags.concatenated) return .concatenation;
    return switch (raw[0]) {
        '<' => .html,
        '"' => .quoted,
        '-', '.', '0'...'9' => .numeral,
        else => .bare,
    };
}

/// Required bytes for the logical identifier value. No allocation or output.
pub fn decodedLen(raw: []const u8) error{InvalidIdentifier}!usize {
    _ = try validate(raw);
    var chunks: Chunks = .{ .raw = raw };
    var len: usize = 0;
    while (chunks.next()) |chunk| len += chunk.len;
    // Decoding only removes bytes, so the sum is bounded by raw.len.
    return len;
}

/// Decode into caller memory. On any error, output is unchanged. The written
/// output region must not overlap raw; overlapping buffers are rejected.
/// The returned slice borrows output, not the source. This low-level byte
/// transformation uses local errors, not parse/validation diagnostic delivery.
pub fn decodeInto(raw: []const u8, output: []u8) DecodeError![]const u8 {
    const len = try decodedLen(raw);
    if (output.len < len) return error.NoSpaceLeft;
    if (len != 0) {
        // Compare addresses without computing either one-past-end pointer.
        // Subtraction is ordered, so it cannot underflow; no pointer is cast
        // back or dereferenced through this check.
        const input_start = @intFromPtr(raw.ptr);
        const output_start = @intFromPtr(output.ptr);
        const overlaps = if (input_start <= output_start)
            output_start - input_start < raw.len
        else
            input_start - output_start < len;
        if (overlaps) return error.OverlappingBuffers;
    }
    var chunks: Chunks = .{ .raw = raw };
    var offset: usize = 0;
    while (chunks.next()) |chunk| {
        @memcpy(output[offset..][0..chunk.len], chunk);
        offset += chunk.len;
    }
    return output[0..len];
}

/// Stream the logical value to a writer with writeAll. Invalid input is
/// rejected before any writes. Writer failures propagate unchanged and may
/// leave partial output; atomic destinations must stage on the caller side.
pub fn writeDecoded(raw: []const u8, writer: anytype) !void {
    _ = try validate(raw);
    var chunks: Chunks = .{ .raw = raw };
    while (chunks.next()) |chunk| try writer.writeAll(chunk);
}

/// Hash the logical value without allocating or materializing decoded text.
/// Validates the whole spelling first. Equal values have equal hashes; hashes
/// can collide and are not a stable serialization format or a security boundary.
pub fn hash(raw: []const u8) error{InvalidIdentifier}!u64 {
    _ = try validate(raw);
    return @import("identifier_value.zig").hashAssumeValid(raw);
}

/// Compare logical values, not quoting, concatenation boundaries or numerals'
/// numeric meanings. Both spellings are checked, even when their values differ.
/// No allocation, Unicode normalization or layout-escape interpretation.
pub fn eql(a: []const u8, b: []const u8) error{InvalidIdentifier}!bool {
    _ = try validate(a);
    _ = try validate(b);
    return @import("identifier_value.zig").orderAssumeValid(a, b) == .eq;
}

/// A borrowed complete name spelling, not a cached/decoded string. Use
/// fromName/check; constructing Parsed fields manually is caller-trusted.
pub const Parsed = ParsedForEncoding(.utf8);

/// Bind a recognized name to its unchanged source, without lexing it again.
/// Raw spans (including previews) are deliberately not accepted. This guards
/// accidental misuse, not forged names or mixing buffers/encodings. No allocation.
pub fn fromName(source: []const u8, name: names.Name) Parsed {
    return .{ .raw = name.slice(source) };
}

/// Checked boundary for caller-supplied spans. Parser-issued Names need no check.
pub fn check(source: []const u8, span: @import("parser_support").location.Span) error{InvalidIdentifier}!names.Name {
    if (span.endOffset() > source.len) return error.InvalidIdentifier;
    _ = try validate(span.slice(source));
    return names.recognized(span);
}

fn validate(raw: []const u8) error{InvalidIdentifier}!lex.Token {
    var lexer = lex.Lexer.initRaw(raw);
    // Keep standalone checking from forcing the parser's shared scanner into
    // an out-of-line call merely because both entry points are linked.
    const result = @call(.always_inline, lex.Lexer.drive, .{ &lexer, false, 0 }).result.?;
    if (result != .token or result.token.tag != .identifier or
        result.token.span.start != 0 or result.token.span.len != raw.len)
        return error.InvalidIdentifier;
    return result.token;
}

/// Native spelling helpers. Values are explicitly decoded to UTF-8; raw tree
/// ranges and operand parts continue to refer to the original source bytes.
pub fn ForEncoding(comptime actual: encoding.Actual) type {
    if (actual == .utf8) return struct {
        pub const parts = @import("identifier.zig").parts;
        pub const form = @import("identifier.zig").form;
        pub const decodedLen = @import("identifier.zig").decodedLen;
        pub const decodeInto = @import("identifier.zig").decodeInto;
        pub const writeDecoded = @import("identifier.zig").writeDecoded;
        pub const hash = @import("identifier.zig").hash;
        pub const eql = @import("identifier.zig").eql;
        pub const Parsed = @import("identifier.zig").Parsed;
        pub const fromName = @import("identifier.zig").fromName;
        pub const check = @import("identifier.zig").check;
    };
    return struct {
        const E = encoding.Reader(actual);
        const Values = @import("identifier_value.zig").ForEncoding(actual);
        pub const Parts = @import("identifier_parts.zig").ForEncoding(actual).Parts;
        pub const Parsed = ParsedForEncoding(actual);
        /// The Name must belong to this unchanged source in this encoding.
        pub fn fromName(source: []const u8, name: names.Name) @This().Parsed {
            return .{ .raw = name.slice(source) };
        }
        pub fn check(source: []const u8, span: @import("parser_support").location.Span) error{InvalidIdentifier}!names.Name {
            if (span.endOffset() > source.len or span.start % E.width != 0) return error.InvalidIdentifier;
            _ = try checked(span.slice(source));
            return names.recognized(span);
        }
        fn checked(raw: []const u8) error{InvalidIdentifier}!lex.Token {
            if (raw.len % E.width != 0) return error.InvalidIdentifier;
            var scanner = lex.scalar.ScannerWithEncoding(actual, false, false, true, false).initRaw(raw);
            const result = @call(.always_inline, @TypeOf(scanner).drive, .{ &scanner, false, 0 }).result.?;
            if (result != .token or result.token.tag != .identifier or result.token.span.start != 0 or result.token.span.len != raw.len)
                return error.InvalidIdentifier;
            return result.token;
        }
        pub fn parts(source: []const u8, range: @import("parser_support").location.Span) error{ InvalidSpan, InvalidIdentifier }!@This().Parts {
            if (range.start % E.width != 0 or range.len % E.width != 0) return error.InvalidSpan;
            const input = @import("parser_support").processor.Fragment.fromSource(source, range) catch return error.InvalidSpan;
            const token = try checked(input.bytes);
            return .{ .input = input, .compound = token.flags.concatenated };
        }
        pub fn form(raw: []const u8) error{InvalidIdentifier}!Form {
            const token = try checked(raw);
            if (token.flags.concatenated) return .concatenation;
            return switch (E.byteAt(raw, 0)) {
                '<' => .html,
                '"' => .quoted,
                '-', '.', '0'...'9' => .numeral,
                else => .bare,
            };
        }
        pub fn decodedLen(raw: []const u8) error{InvalidIdentifier}!usize {
            _ = try checked(raw);
            var chunks: Values.Chunks = .{ .raw = raw };
            var len: usize = 0;
            while (chunks.next()) |chunk| {
                var at: usize = 0;
                while (at < chunk.len) {
                    const scalar = E.decode(chunk, at) catch return error.InvalidIdentifier;
                    at += scalar.len;
                    len += std.unicode.utf8CodepointSequenceLength(scalar.scalar) catch return error.InvalidIdentifier;
                }
            }
            return len;
        }
        pub fn decodeInto(raw: []const u8, output: []u8) DecodeError![]const u8 {
            const len = try @This().decodedLen(raw);
            if (len > output.len) return error.NoSpaceLeft;
            if (len != 0) {
                const a = @intFromPtr(raw.ptr);
                const b = @intFromPtr(output.ptr);
                if (if (a <= b) b - a < raw.len else a - b < len) return error.OverlappingBuffers;
            }
            var writer = std.Io.Writer.fixed(output[0..len]);
            @This().writeDecoded(raw, &writer) catch unreachable; // Sized and checked above.
            return output[0..len];
        }
        pub fn writeDecoded(raw: []const u8, writer: anytype) !void {
            _ = try @This().decodedLen(raw); // Validate before the first write.
            var chunks: Values.Chunks = .{ .raw = raw };
            var out: [4]u8 = undefined;
            while (chunks.next()) |chunk| {
                var at: usize = 0;
                while (at < chunk.len) {
                    const scalar = E.decode(chunk, at) catch unreachable;
                    at += scalar.len;
                    const len = std.unicode.utf8Encode(scalar.scalar, &out) catch unreachable;
                    try writer.writeAll(out[0..len]);
                }
            }
        }
        /// Hashes the UTF-8 logical value, matching the byte helper's hash for
        /// equivalent text. Malformed native encoding is InvalidIdentifier,
        /// just as for explicit decoding; no conversion buffer is allocated.
        pub fn hash(raw: []const u8) error{InvalidIdentifier}!u64 {
            const HashWriter = struct {
                state: std.hash.Wyhash = .init(0),
                pub fn writeAll(self: *@This(), bytes: []const u8) error{}!void {
                    self.state.update(bytes);
                }
            };
            var writer: HashWriter = .{};
            try @This().writeDecoded(raw, &writer);
            return writer.state.final();
        }
        pub fn eql(a: []const u8, b: []const u8) error{InvalidIdentifier}!bool {
            _ = try @This().decodedLen(a);
            _ = try @This().decodedLen(b);
            return Values.orderAssumeValid(a, b) == .eq;
        }
    };
}

test "decode preserves numeral identity and only removes DOT lexical escapes" {
    const cases = .{
        .{ "abc_2", "abc_2" },
        .{ "café", "café" },
        .{ "東京", "東京" },
        .{ "caf\xe9", "caf\xe9" },
        .{ "\x80\xff\xc0\xaf", "\x80\xff\xc0\xaf" },
        .{ "e\xcc\x81", "e\xcc\x81" },
        .{ "\xEF\xBB\xBF", "\xEF\xBB\xBF" },
        .{ "\xEF\xBB\xBFgraph", "\xEF\xBB\xBFgraph" },
        .{ "-00.50", "-00.50" },
        .{ "\"\"", "" },
        .{ "\"graph\"", "graph" },
        .{ "\"a\\\"b\"", "a\"b" },
        .{ "\"a\\nb\\\\c\\q\"", "a\\nb\\\\c\\q" },
        .{ "\"a\\\nb\\\r\nc\\\rd\"", "abcd" },
        .{ "\"a\nb\r\nc\rd\"", "a\nb\r\nc\rd" },
        .{ "\"// /* # + \\t\x01\x7f\xff\"", "// /* # + \\t\x01\x7f\xff" },
        .{ "\"a\" /* \" */ + // \"\r\n # \"\r \"b\"+\"\"+\"c\"", "abc" },
    };
    inline for (cases) |case| {
        var output: [128]u8 = undefined;
        try std.testing.expectEqual(case[1].len, try decodedLen(case[0]));
        try std.testing.expectEqualStrings(case[1], try decodeInto(case[0], &output));
        var writer = std.Io.Writer.fixed(&output);
        try writeDecoded(case[0], &writer);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "decoding rejects invalid expressions without changing output" {
    inline for (.{ "", "graph", " a", "a ", "a b", "1e3", "\"a", "\"a\"+", "\"a\"+b", "\"a\x00b\"", "\"a\" /*" }) |raw| {
        var output: [16]u8 = @splat(0x55);
        try std.testing.expectError(error.InvalidIdentifier, decodeInto(raw, &output));
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x55)), &output);
        var writer = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidIdentifier, writeDecoded(raw, &writer));
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

test "output capacity and aliasing are explicit and failure atomic" {
    var output: [4]u8 = @splat(0x55);
    try std.testing.expectError(error.NoSpaceLeft, decodeInto("\"hello\"", &output));
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0x55)), &output);
    try std.testing.expectEqualStrings("abcd", try decodeInto("\"ab\"+\"cd\"", &output));
    try std.testing.expectEqualStrings("", try decodeInto("\"\"", &.{}));
    var source = "\"abc\"".*;
    try std.testing.expectError(error.OverlappingBuffers, decodeInto(&source, source[1..]));
    try std.testing.expectEqualStrings("\"abc\"", &source);
    var writer = std.Io.Writer.fixed(output[0..1]);
    try std.testing.expectError(error.WriteFailed, writeDecoded("\"abc\"", &writer));
}

test "long quoted identifiers use caller storage without token-size buffers" {
    var raw: [65538]u8 = @splat('a');
    raw[0] = '"';
    raw[raw.len - 1] = '"';
    var output: [65536]u8 = undefined;
    const value = try decodeInto(&raw, &output);
    try std.testing.expectEqual(output.len, value.len);
    try std.testing.expect(std.mem.allEqual(u8, value, 'a'));
}

test "fuzz: arbitrary decoding input and constructed quoted values agree" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) !void {
    var input: [255]u8 = undefined;
    const len = smith.value(u8);
    smith.bytes(input[0..len]);
    var output: [512]u8 = undefined;
    // Arbitrary malformed input must not reach unchecked decoding state.
    if (decodeInto(input[0..len], &output)) |value| {
        try std.testing.expect(value.len <= len);
        var second: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&second);
        try writeDecoded(input[0..len], &writer);
        try std.testing.expectEqualSlices(u8, value, writer.buffered());
    } else |err| {
        try std.testing.expectEqual(error.InvalidIdentifier, err);
    }

    // Construct valid quoted concatenations from arbitrary bytes. Preserve
    // double backslashes as pairs, escape quotes, and avoid the excluded NUL.
    var raw: [4096]u8 = undefined;
    var expected: [512]u8 = undefined;
    var spelling = std.Io.Writer.fixed(&raw);
    var logical = std.Io.Writer.fixed(&expected);
    try spelling.writeAll("\"");
    for (input[0..len], 0..) |byte, i| {
        const content = if (byte == 0) @as(u8, 1) else byte;
        switch (content) {
            '"' => {
                try spelling.writeAll("\\\"");
                try logical.writeAll("\"");
            },
            '\\' => {
                try spelling.writeAll("\\\\");
                try logical.writeAll("\\\\");
            },
            else => {
                try spelling.writeAll(&.{content});
                try logical.writeAll(&.{content});
            },
        }
        if (i % 16 == 0) try spelling.writeAll("\"/* \" # */+\"");
    }
    try spelling.writeAll("\"");
    try std.testing.expectEqualSlices(u8, logical.buffered(), try decodeInto(spelling.buffered(), &output));
}
