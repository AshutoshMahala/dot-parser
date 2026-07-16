//! Source positions (milestone 1, step 1).
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

    /// The source bytes this span covers. `source` must be the buffer the
    /// span was produced from; safe builds assert the span lies within it
    /// (overflow-free bounds check) rather than slicing out of bounds.
    pub fn slice(self: Span, source: []const u8) []const u8 {
        std.debug.assert(self.start.byte_offset <= source.len);
        std.debug.assert(self.byte_len <= source.len - self.start.byte_offset);
        return source[self.start.byte_offset..][0..self.byte_len];
    }
};

/// A compact borrowed source range: byte offset and length only, 8 bytes.
///
/// This is the retained-data representation (R-MEM-008): full positions —
/// line and column — are not stored per retained element; they are derived
/// on demand via `locate` (or, later, an optional source-index side table).
/// The u32 fields limit retained sources to 4 GiB; producers must use the
/// checked `fromSpan` narrowing.
pub const Range = struct {
    start: u32,
    len: u32,

    /// Zero-based offset one past the last byte of the range. Computed in
    /// u64, so it cannot overflow even for hand-constructed ranges on
    /// 32-bit targets.
    pub fn endOffset(self: Range) u64 {
        return @as(u64, self.start) + self.len;
    }

    /// The source bytes this range covers. `source` must be the buffer the
    /// range was produced from; safe builds assert the range lies within it
    /// (overflow-free bounds check) rather than slicing out of bounds.
    pub fn slice(self: Range, source: []const u8) []const u8 {
        const end = self.endOffset();
        std.debug.assert(end <= source.len);
        return source[self.start..@intCast(end)];
    }

    /// Checked narrowing from a full span; null unless the whole range —
    /// including its one-past-end offset — fits the 4 GiB retained domain,
    /// so `endOffset` of an accepted range can never leave u32.
    pub fn fromSpan(span: Span) ?Range {
        const end = std.math.add(usize, span.start.byte_offset, span.byte_len) catch return null;
        if (end > std.math.maxInt(u32)) return null;
        return .{
            .start = @intCast(span.start.byte_offset),
            .len = @intCast(span.byte_len),
        };
    }

    /// Rehydrate a full span, deriving line and column by scanning `source`
    /// (O(start); intended for diagnostic emission, where positions are
    /// needed rarely).
    pub fn toSpan(self: Range, source: []const u8) Span {
        return .{ .start = locate(source, self.start), .byte_len = self.len };
    }
};

/// Recompute the full location of `byte_offset` by scanning `source` from
/// the start. O(byte_offset) — the deliberate trade of the compact-range
/// policy: retained data stays small and positions are computed only when
/// a diagnostic or tool actually needs one (R-MEM-008).
pub fn locate(source: []const u8, byte_offset: usize) Location {
    std.debug.assert(byte_offset <= source.len);
    var tracker: Tracker = .{};
    tracker.advanceSlice(source[0..byte_offset]);
    return tracker.location;
}

/// Derives full positions for ascending ranges incrementally: one shared
/// scan instead of one scan per query, so a source-ordered pass (like
/// validation) pays O(source) total no matter how many diagnostics it
/// emits.
pub const PositionCursor = struct {
    tracker: Tracker = .{},

    /// The full span of `range`. Ranges must be requested in non-decreasing
    /// `start` order against the same `source` the ranges were produced from.
    pub fn spanFor(self: *PositionCursor, source: []const u8, range: Range) Span {
        std.debug.assert(range.start >= self.tracker.location.byte_offset);
        self.tracker.advanceSlice(source[self.tracker.location.byte_offset..range.start]);
        return .{ .start = self.tracker.location, .byte_len = range.len };
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

test "range slices and converts to and from spans" {
    const source = "graph {\n  a -- b;\n}";
    const span: Span = .{
        .start = .{ .byte_offset = 10, .line = 2, .byte_column = 3 },
        .byte_len = 1,
    };

    const range = Range.fromSpan(span).?;
    try expectEqual(@as(u32, 10), range.start);
    try expectEqual(@as(u64, 11), range.endOffset());
    try std.testing.expectEqualStrings("a", range.slice(source));

    // Rehydration derives the identical full position by scanning.
    try expectEqual(span, range.toSpan(source));
}

test "range narrowing is checked" {
    if (@sizeOf(usize) <= @sizeOf(u32)) return error.SkipZigTest;
    const too_far: Span = .{
        .start = .{
            .byte_offset = @as(usize, std.math.maxInt(u32)) + 1,
            .line = 1,
            .byte_column = 1,
        },
        .byte_len = 0,
    };
    try expectEqual(@as(?Range, null), Range.fromSpan(too_far));
}

test "range narrowing rejects ends beyond the retained domain" {
    // start and len each fit u32 on their own; their sum does not.
    const straddling: Span = .{
        .start = .{
            .byte_offset = std.math.maxInt(u32) - 1,
            .line = 1,
            .byte_column = 1,
        },
        .byte_len = 2,
    };
    try expectEqual(@as(?Range, null), Range.fromSpan(straddling));

    // The exact boundary is still accepted: end == maxInt(u32).
    const boundary: Span = .{
        .start = .{
            .byte_offset = std.math.maxInt(u32) - 1,
            .line = 1,
            .byte_column = 1,
        },
        .byte_len = 1,
    };
    try expectEqual(@as(u64, std.math.maxInt(u32)), Range.fromSpan(boundary).?.endOffset());
}

test "locate recomputes positions across newline styles" {
    const source = "a\r\nb\rc\nd";
    try expectEqual(Location.start, locate(source, 0));
    try expectEqual(Location{ .byte_offset = 3, .line = 2, .byte_column = 1 }, locate(source, 3));
    try expectEqual(Location{ .byte_offset = 7, .line = 4, .byte_column = 1 }, locate(source, 7));
    try expectEqual(Location{ .byte_offset = 8, .line = 4, .byte_column = 2 }, locate(source, 8));
}

test "position cursor matches locate for ascending queries" {
    const source = "graph {\n  a -> b;\r\n  c -> d;\n}";
    var cursor: PositionCursor = .{};
    for ([_]u32{ 0, 12, 23 }) |offset| {
        const range: Range = .{ .start = offset, .len = 2 };
        const span = cursor.spanFor(source, range);
        try expectEqual(locate(source, offset), span.start);
        try expectEqual(@as(usize, 2), span.byte_len);
    }
}
