//! Explicit, allocation-free decoding of supported identifier expressions.
//!
//! Raw spelling stays in the document. These helpers validate one complete
//! identifier (no leading/trailing trivia), then decode on demand. They do
//! not cache results, interpret layout escapes, normalize encoding, or convert
//! numerals. Repeated calls repeat linear work. Output memory is caller-owned.

const std = @import("std");
const lex = @import("lexer/lexer.zig");

pub const DecodeError = error{ InvalidIdentifier, NoSpaceLeft, OverlappingBuffers };

/// Required bytes for the logical identifier value. No allocation or output.
pub fn decodedLen(raw: []const u8) error{InvalidIdentifier}!usize {
    try validate(raw);
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
    try validate(raw);
    var chunks: Chunks = .{ .raw = raw };
    while (chunks.next()) |chunk| try writer.writeAll(chunk);
}

fn validate(raw: []const u8) error{InvalidIdentifier}!void {
    var lexer = lex.Lexer.init(raw);
    const result = lexer.next();
    if (result != .token or result.token.tag != .identifier or
        result.token.span.start != 0 or result.token.span.len != raw.len)
        return error.InvalidIdentifier;
}

/// Traverses a validated expression only. Comments between quoted parts are
/// discarded along with '+' and whitespace; comment-like content inside a
/// quoted part is emitted unchanged. This is decoding, not a second validator.
const Chunks = struct {
    raw: []const u8,
    offset: usize = 0,

    fn next(self: *Chunks) ?[]const u8 {
        if (self.offset == self.raw.len) return null;
        if (self.raw[0] != '"') {
            self.offset = self.raw.len;
            return self.raw;
        }
        if (self.offset == 0) self.offset = 1;
        while (self.offset < self.raw.len) {
            const start = self.offset;
            switch (self.raw[start]) {
                '"' => {
                    self.offset += 1;
                    self.skipGlue();
                },
                '\\' => {
                    const after = self.raw[start + 1]; // validated escape pair
                    self.offset += 2;
                    switch (after) {
                        '"' => return self.raw[start + 1 .. self.offset],
                        '\n' => {},
                        '\r' => {
                            if (self.offset < self.raw.len and self.raw[self.offset] == '\n') self.offset += 1;
                        },
                        else => return self.raw[start..self.offset],
                    }
                },
                else => {
                    self.offset += 1;
                    while (self.offset < self.raw.len and self.raw[self.offset] != '"' and self.raw[self.offset] != '\\') self.offset += 1;
                    return self.raw[start..self.offset];
                },
            }
        }
        return null;
    }

    fn skipGlue(self: *Chunks) void {
        while (self.offset < self.raw.len) {
            switch (self.raw[self.offset]) {
                '"' => {
                    self.offset += 1;
                    return;
                },
                '#' => self.skipLine(),
                '/' => {
                    if (self.raw[self.offset + 1] == '/') {
                        self.skipLine();
                    } else {
                        self.offset += 2;
                        while (!(self.raw[self.offset] == '*' and self.raw[self.offset + 1] == '/')) self.offset += 1;
                        self.offset += 2;
                    }
                },
                else => self.offset += 1, // validated whitespace or '+'
            }
        }
    }

    fn skipLine(self: *Chunks) void {
        while (self.offset < self.raw.len and self.raw[self.offset] != '\r' and self.raw[self.offset] != '\n') self.offset += 1;
    }
};

test "decode preserves numeral identity and only removes DOT lexical escapes" {
    const cases = .{
        .{ "abc_2", "abc_2" },
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
        var output = [_]u8{0x55} ** 16;
        try std.testing.expectError(error.InvalidIdentifier, decodeInto(raw, &output));
        try std.testing.expectEqualSlices(u8, &([_]u8{0x55} ** 16), &output);
        var writer = std.Io.Writer.fixed(&output);
        try std.testing.expectError(error.InvalidIdentifier, writeDecoded(raw, &writer));
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

test "output capacity and aliasing are explicit and failure atomic" {
    var output = [_]u8{0x55} ** 4;
    try std.testing.expectError(error.NoSpaceLeft, decodeInto("\"hello\"", &output));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x55} ** 4), &output);
    try std.testing.expectEqualStrings("abcd", try decodeInto("\"ab\"+\"cd\"", &output));
    try std.testing.expectEqualStrings("", try decodeInto("\"\"", &.{}));
    var source = "\"abc\"".*;
    try std.testing.expectError(error.OverlappingBuffers, decodeInto(&source, source[1..]));
    try std.testing.expectEqualStrings("\"abc\"", &source);
    var writer = std.Io.Writer.fixed(output[0..1]);
    try std.testing.expectError(error.WriteFailed, writeDecoded("\"abc\"", &writer));
}

test "long quoted identifiers use caller storage without token-size buffers" {
    var raw = [_]u8{'a'} ** 65538;
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
