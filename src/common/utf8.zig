//! Encoding only: no language syntax, normalization, replacement or allocation.
const std = @import("std");

/// Length of a valid UTF-8 sequence at the start of bytes, or null. Callers
/// choose diagnostics/recovery; invalid input is never consumed implicitly.
pub fn sequenceLength(bytes: []const u8) ?u3 {
    if (bytes.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (len > bytes.len) return null;
    _ = std.unicode.utf8Decode(bytes[0..len]) catch return null;
    return len;
}

test "UTF-8 sequence bounds, truncation and invalid scalar encodings" {
    inline for (.{ "a", "\x00", "\xc2\x80", "\xdf\xbf", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xef\xbf\xbf", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf" }) |valid| {
        try std.testing.expectEqual(@as(?u3, valid.len), sequenceLength(valid));
        for (0..valid.len) |len| try std.testing.expectEqual(@as(?u3, null), sequenceLength(valid[0..len]));
    }
    inline for (.{ "\x80", "\xc0\xaf", "\xc1\xbf", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", "\xe2x\xa1" }) |invalid| {
        try std.testing.expectEqual(@as(?u3, null), sequenceLength(invalid));
    }
}
