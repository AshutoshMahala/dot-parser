//! Optional editor coordinates. Never used by the scanner or retained pools.
const std = @import("std");
const encoding = @import("encoding.zig");

/// LSP column encodings. UTF-32 counts Unicode scalar values, not graphemes
/// or terminal cells. UTF-8 counts encoded UTF-8 bytes even for native sources.
pub const ColumnEncoding = enum { utf8, utf16, utf32 };
pub const TextPosition = struct { line: u32, character: u32 };
pub const TextPositionOptions = struct {
    source_encoding: encoding.Actual = .utf8,
    column_encoding: ColumnEncoding = .utf16,
    /// Byte-oriented diagnostics may select only part of a scalar. Editors can
    /// round starts before and ends after it, without changing parser spans.
    boundary: enum { strict, before, after } = .strict,
};
pub const PositionError = error{ SourceTooLarge, InvalidOffset, InvalidBoundary, PositionOverflow };

/// Resolve an original byte offset to zero-based line/column coordinates.
/// O(offset), allocation-free, and independent of parsing/validation. LF, CRLF
/// and standalone CR follow the byte-location policy. Tabs and a source BOM
/// count as ordinary scalars; no display-width expansion or BOM removal.
/// Invalid code units (including a truncated final unit) each count as U+FFFD
/// for coordinates only. The source is never repaired. An offset inside a
/// valid scalar or an invalid/truncated unit is InvalidBoundary by default;
/// boundary = before/after rounds it for editor ranges without changing bytes.
pub fn textPosition(source: []const u8, offset: u32, options: TextPositionOptions) PositionError!TextPosition {
    if (source.len > std.math.maxInt(u32)) return error.SourceTooLarge;
    if (offset > source.len) return error.InvalidOffset;
    switch (options.source_encoding) {
        inline else => |actual| return resolve(actual, source, offset, options),
    }
}

fn resolve(comptime actual: encoding.Actual, source: []const u8, offset: u32, options: TextPositionOptions) PositionError!TextPosition {
    const E = encoding.Reader(actual);
    var result: TextPosition = .{ .line = 0, .character = 0 };
    var at: usize = 0;
    var after_cr = false;
    // Earlier lines may exceed u32 converted columns even though the queried
    // line fits. At most four UTF-8 column bytes per source byte fit in u64.
    var column: u64 = 0;
    while (at < offset) {
        const decoded = E.decode(source, at) catch encoding.Decoded{
            .scalar = 0xfffd,
            .len = @intCast(@min(E.width, source.len - at)),
        };
        if (decoded.len > offset - at) switch (options.boundary) {
            .strict => return error.InvalidBoundary,
            .before => break,
            .after => {},
        };
        at += decoded.len;
        switch (decoded.scalar) {
            '\r' => {
                result.line += 1; // At most one line per source byte; zero-based.
                column = 0;
                after_cr = true;
            },
            '\n' => {
                if (!after_cr) result.line += 1;
                column = 0;
                after_cr = false;
            },
            else => {
                const count: u32 = switch (options.column_encoding) {
                    .utf8 => std.unicode.utf8CodepointSequenceLength(decoded.scalar) catch unreachable,
                    .utf16 => if (decoded.scalar > 0xffff) 2 else 1,
                    .utf32 => 1,
                };
                column += count;
                after_cr = false;
            },
        }
    }
    result.character = std.math.cast(u32, column) orelse return error.PositionOverflow;
    return result;
}

test "editor columns are independent of byte columns and display widths" {
    const source = "a😀e\u{0301}\t中文\r\nx\ry\nz";
    const end: u32 = @intCast(std.mem.indexOf(u8, source, "\r").?);
    inline for (.{ .{ ColumnEncoding.utf8, 15 }, .{ ColumnEncoding.utf16, 8 }, .{ ColumnEncoding.utf32, 7 } }) |case| {
        try std.testing.expectEqual(TextPosition{ .line = 0, .character = case[1] }, try textPosition(source, end, .{ .column_encoding = case[0] }));
    }
    try std.testing.expectEqual(TextPosition{ .line = 3, .character = 1 }, try textPosition(source, source.len, .{}));
    try std.testing.expectError(error.InvalidBoundary, textPosition(source, 2, .{}));
    try std.testing.expectError(error.InvalidOffset, textPosition(source, source.len + 1, .{}));
}

test "malformed bytes count replacements and BOMs remain part of source coordinates" {
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 3 }, try textPosition("a\xff\xc3", 3, .{}));
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 7 }, try textPosition("a\xff\xc3", 3, .{ .column_encoding = .utf8 }));
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 2 }, try textPosition("\xef\xbb\xbfx", 4, .{}));
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 0 }, try textPosition("", 0, .{}));
}

test "native editor positions decode scalars but retain original byte boundaries" {
    inline for (.{ encoding.Actual.utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = encoding.Reader(actual);
        var bytes: [32]u8 = undefined;
        var used: usize = 0;
        for ([_]u21{ 'a', 0x1f600, '\r', '\n', 0x4e2d }) |scalar| {
            if (E.width == 2 and scalar > 0xffff) {
                std.mem.writeInt(u16, bytes[used..][0..2], @intCast(0xd800 + ((scalar - 0x10000) >> 10)), E.endian);
                std.mem.writeInt(u16, bytes[used + 2 ..][0..2], @intCast(0xdc00 + ((scalar - 0x10000) & 0x3ff)), E.endian);
                used += 4;
            } else {
                std.mem.writeInt(if (E.width == 2) u16 else u32, bytes[used..][0..E.width], @intCast(scalar), E.endian);
                used += E.width;
            }
        }
        const source = bytes[0..used];
        const face_end: u32 = E.width + 4;
        try std.testing.expectEqual(TextPosition{ .line = 0, .character = 3 }, try textPosition(source, face_end, .{ .source_encoding = actual }));
        try std.testing.expectEqual(TextPosition{ .line = 1, .character = 1 }, try textPosition(source, @intCast(used), .{ .source_encoding = actual }));
        try std.testing.expectError(error.InvalidBoundary, textPosition(source, 1, .{ .source_encoding = actual }));
    }
}

test "editor coordinates handle partial native units and physical CRLF boundaries" {
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 2 }, try textPosition("a\x00x", 3, .{ .source_encoding = .utf16le }));
    try std.testing.expectError(error.InvalidBoundary, textPosition("a\x00xy", 3, .{ .source_encoding = .utf16le }));
    // A valid pair cannot be split; an unmatched surrogate is one replacement.
    try std.testing.expectError(error.InvalidBoundary, textPosition("\x00\xd8\x00\xdc", 2, .{ .source_encoding = .utf16le }));
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 2 }, try textPosition("\x00\xd8a\x00", 4, .{ .source_encoding = .utf16le }));
    try std.testing.expectEqual(TextPosition{ .line = 0, .character = 1 }, try textPosition("\x00\x00\x00", 3, .{ .source_encoding = .utf32le }));
    try std.testing.expectError(error.InvalidBoundary, textPosition("\x00\x00\x00", 2, .{ .source_encoding = .utf32le }));
    for ([_]u32{ 2, 3 }) |offset| try std.testing.expectEqual(TextPosition{ .line = 1, .character = 0 }, try textPosition("a\r\nb", offset, .{}));
}

test "byte diagnostic endpoints can round outward for editor ranges" {
    const t = std.testing;
    inline for (.{
        .{ encoding.Actual.utf8, "aé", 2, 1, 2 },
        .{ encoding.Actual.utf16le, "a\x00\x00\xd8\x00\xdc", 3, 1, 3 },
        .{ encoding.Actual.utf32be, "\x00\x00\x00a\x00\x01\x00\x00", 5, 1, 3 },
        .{ encoding.Actual.utf32le, "\x00\x00\x00", 2, 0, 1 },
    }) |case| {
        try t.expectError(error.InvalidBoundary, textPosition(case[1], case[2], .{ .source_encoding = case[0] }));
        try t.expectEqual(@as(u32, case[3]), (try textPosition(case[1], case[2], .{ .source_encoding = case[0], .boundary = .before })).character);
        try t.expectEqual(@as(u32, case[4]), (try textPosition(case[1], case[2], .{ .source_encoding = case[0], .boundary = .after })).character);
    }
}
