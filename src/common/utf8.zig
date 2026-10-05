//! Encoding only: no language syntax, normalization, replacement or allocation.
const std = @import("std");

// One word of transient data, not a pair of padded return slots per scalar.
pub const Decoded = packed struct { len: u3, scalar: u21 };

/// Decode one valid UTF-8 scalar at the start of bytes, or null. Callers
/// choose diagnostics/recovery; invalid input is never consumed implicitly.
/// Inline so length-only consumers discard the scalar without a per-byte call.
pub inline fn decode(bytes: []const u8) ?Decoded {
    if (bytes.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (len > bytes.len) return null;
    const scalar = std.unicode.utf8Decode(bytes[0..len]) catch return null;
    return .{ .len = len, .scalar = scalar };
}

/// Encoding-only callers need not retain the decoded scalar.
pub inline fn sequenceLength(bytes: []const u8) ?u3 {
    return if (decode(bytes)) |value| value.len else null;
}

test "UTF-8 sequence bounds, truncation and invalid scalar encodings" {
    inline for (.{ "a", "\x00", "\xc2\x80", "\xdf\xbf", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xef\xbf\xbf", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf" }) |valid| {
        try std.testing.expectEqual(@as(?u3, valid.len), sequenceLength(valid));
        try std.testing.expectEqual(try std.unicode.utf8Decode(valid), decode(valid).?.scalar);
        for (0..valid.len) |len| try std.testing.expectEqual(@as(?u3, null), sequenceLength(valid[0..len]));
    }
    inline for (.{ "\x80", "\xc0\xaf", "\xc1\xbf", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", "\xe2x\xa1" }) |invalid| {
        try std.testing.expectEqual(@as(?u3, null), sequenceLength(invalid));
    }
}

test "UTF-8 decode consumes only the leading scalar" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Decoded));
    try std.testing.expectEqual(Decoded{ .len = 1, .scalar = 'a' }, decode("a\xff").?);
    try std.testing.expectEqual(Decoded{ .len = 3, .scalar = '東' }, decode("東京").?);
    try std.testing.expectEqual(Decoded{ .len = 4, .scalar = 0x1f600 }, decode("😀x").?);
}
