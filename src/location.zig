//! Source positions (IMPLEMENTATION_PLAN.md, milestone 1, step 1).
//!
//! Conventions, tested below:
//! - `byte_offset` is zero-based.
//! - `line` and `byte_column` are one-based (matching compiler-style
//!   human-facing diagnostics; presenters that need zero-based values
//!   convert at the edge).
//! - The byte column counts bytes, so a tab advances it by exactly one
//!   (R-PORT-006). Display-cell columns are a presentation
//!   concern outside this module.
//! - LF, CRLF, and standalone CR each terminate one physical line. CRLF
//!   advances the byte offset by two but the line counter by one.
//!
//! This module performs no allocation and does not interpret Unicode.

/// A position in the source, immediately before the byte at `byte_offset`.
pub const Location = struct {
    /// Zero-based byte offset from the start of the source.
    byte_offset: usize,
    /// One-based physical line number.
    line: usize,
    /// One-based byte column within the current line.
    byte_column: usize,

    /// The position of the first byte of any source, including empty sources.
    pub const start: Location = .{ .byte_offset = 0, .line = 1, .byte_column = 1 };
};

/// A contiguous byte range of the source, anchored at its starting location.
///
/// Spans borrow nothing themselves; they are only meaningful together with
/// the source bytes the caller keeps alive.
pub const Span = struct {
    start: Location,
    byte_len: usize,

    /// Zero-based offset one past the last byte of the span.
    pub fn endOffset(self: Span) usize {
        return self.start.byte_offset + self.byte_len;
    }

    /// The source bytes this span covers. `source` must be the same buffer
    /// the span was produced from.
    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start.byte_offset..self.endOffset()];
    }
};

/// Constant-size newline-aware position tracker (R-MEM-008:
/// tracking the current position needs only this struct, never a line index).
pub const Tracker = struct {
    location: Location = .start,
    /// True when the previous byte was CR, so a following LF is the second
    /// half of a CRLF pair rather than a new line terminator.
    after_cr: bool = false,

    pub fn advance(self: *Tracker, byte: u8) void {
        self.location.byte_offset += 1;
        switch (byte) {
            '\r' => {
                self.location.line += 1;
                self.location.byte_column = 1;
                self.after_cr = true;
            },
            '\n' => {
                if (!self.after_cr) {
                    self.location.line += 1;
                    self.location.byte_column = 1;
                }
                self.after_cr = false;
            },
            else => {
                self.location.byte_column += 1;
                self.after_cr = false;
            },
        }
    }

    pub fn advanceSlice(self: *Tracker, bytes: []const u8) void {
        for (bytes) |byte| self.advance(byte);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const expectEqual = std.testing.expectEqual;

fn expectLocation(tracker: Tracker, byte_offset: usize, line: usize, byte_column: usize) !void {
    try expectEqual(byte_offset, tracker.location.byte_offset);
    try expectEqual(line, tracker.location.line);
    try expectEqual(byte_column, tracker.location.byte_column);
}

test "empty source stays at the start location" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("");
    try expectLocation(tracker, 0, 1, 1);
    try expectEqual(Location.start, tracker.location);
}

test "plain bytes advance offset and column only" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("abc");
    try expectLocation(tracker, 3, 1, 4);
}

test "tab advances the byte column by exactly one" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("a\tb");
    try expectLocation(tracker, 3, 1, 4);
}

test "LF terminates a line" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("ab\nc");
    try expectLocation(tracker, 4, 2, 2);
}

test "CRLF is one physical newline but two bytes" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("ab\r\nc");
    try expectLocation(tracker, 5, 2, 2);
}

test "standalone CR terminates a line" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("ab\rc");
    try expectLocation(tracker, 4, 2, 2);
}

test "CR CR is two newlines" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("\r\r");
    try expectLocation(tracker, 2, 3, 1);
}

test "LF LF is two newlines" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("\n\n");
    try expectLocation(tracker, 2, 3, 1);
}

test "CRLF CRLF is two newlines" {
    var tracker: Tracker = .{};
    tracker.advanceSlice("\r\n\r\n");
    try expectLocation(tracker, 4, 3, 1);
}

test "LF directly after CRLF starts a new line" {
    // \r\n consumes the LF; the second \n is its own terminator.
    var tracker: Tracker = .{};
    tracker.advanceSlice("\r\n\n");
    try expectLocation(tracker, 3, 3, 1);
}

test "location after every byte boundary of a mixed input" {
    const source = "a\r\nb\rc\nd";
    // Expected location *after* consuming source[0..i + 1].
    const expected = [_]Location{
        .{ .byte_offset = 1, .line = 1, .byte_column = 2 }, // 'a'
        .{ .byte_offset = 2, .line = 2, .byte_column = 1 }, // '\r'
        .{ .byte_offset = 3, .line = 2, .byte_column = 1 }, // '\n' (CRLF pair)
        .{ .byte_offset = 4, .line = 2, .byte_column = 2 }, // 'b'
        .{ .byte_offset = 5, .line = 3, .byte_column = 1 }, // '\r'
        .{ .byte_offset = 6, .line = 3, .byte_column = 2 }, // 'c'
        .{ .byte_offset = 7, .line = 4, .byte_column = 1 }, // '\n'
        .{ .byte_offset = 8, .line = 4, .byte_column = 2 }, // 'd'
    };
    var tracker: Tracker = .{};
    for (source, 0..) |byte, i| {
        tracker.advance(byte);
        try expectEqual(expected[i], tracker.location);
    }
}

test "span end offset and slicing" {
    const source = "graph { a -- b; }";
    const span: Span = .{
        .start = .{ .byte_offset = 8, .line = 1, .byte_column = 9 },
        .byte_len = 1,
    };
    try expectEqual(@as(usize, 9), span.endOffset());
    try std.testing.expectEqualStrings("a", span.slice(source));
}
