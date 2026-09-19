//! Source positions.
//!
//! The scanners, the parser, the events and the diagnostics carry byte
//! offsets only: a `Span` is an offset and a length, eight bytes. Physical
//! line and byte column are derived from the source when something shows
//! them — `locate` for one position, `PositionCursor` for many — and never
//! tracked per byte while scanning (R-MEM-008).
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
//! - Positions are 32-bit. A source is at most `max_source_len` bytes; the
//!   scanner refuses longer input before reading it.
//!
//! This module performs no allocation and does not interpret Unicode.

const std = @import("std");

/// The longest source the library scans: positions are `u32`.
pub const max_source_len: usize = std.math.maxInt(u32);

/// A contiguous byte range of the source: zero-based start offset and byte
/// length. It is the only position the library stores — in tokens, events,
/// diagnostics and retained records alike (the retained records call it
/// `Range`). Spans borrow nothing themselves; they are only meaningful
/// together with the source bytes the caller keeps alive.
pub const Span = struct {
    start: u32,
    len: u32,

    /// Zero-based offset one past the last byte. Computed in u64, so it
    /// cannot overflow even for hand-constructed spans on 32-bit targets.
    pub fn endOffset(self: Span) u64 {
        return @as(u64, self.start) + self.len;
    }

    /// The source bytes this span covers. `source` must be the buffer the
    /// span was produced from; safe builds assert the span lies within it
    /// (overflow-free bounds check) rather than slicing out of bounds.
    pub fn slice(self: Span, source: []const u8) []const u8 {
        const end = self.endOffset();
        std.debug.assert(end <= source.len);
        return source[self.start..@intCast(end)];
    }

    /// The full position of the span's first byte, derived by scanning
    /// `source` from its start: O(start). For many spans, or spans that
    /// arrive in source order, use a `PositionCursor`.
    pub fn locate(self: Span, source: []const u8) Location {
        return resolve(source, self.start);
    }
};

/// The retained-record name for the same type (R-MEM-008).
pub const Range = Span;

/// A resolved position, immediately before the byte at `byte_offset`:
/// derived from the source on demand, never stored by the parser.
pub const Location = struct {
    /// Zero-based byte offset from the start of the source.
    byte_offset: u32,
    /// One-based physical line number.
    line: u32,
    /// One-based byte column within the current line.
    byte_column: u32,

    /// The position of the first byte of any source, including empty sources.
    pub const start: Location = .{ .byte_offset = 0, .line = 1, .byte_column = 1 };
};

/// The full position of `byte_offset`, scanning `source` from the start:
/// O(byte_offset). The deliberate trade of storing offsets only: positions
/// cost nothing until a diagnostic or a tool actually shows one.
pub fn locate(source: []const u8, byte_offset: usize) Location {
    return resolve(source, byte_offset);
}

fn resolve(source: []const u8, byte_offset: usize) Location {
    std.debug.assert(byte_offset <= source.len and byte_offset <= max_source_len);
    var tracker: Tracker = .{};
    tracker.advanceSlice(source[0..byte_offset]);
    return tracker.location;
}

/// Derives full positions for many offsets with one shared scan. Queries
/// at or past the scan advance it, so a source-ordered pass pays O(source)
/// in total however many positions it asks for. A query behind the scan is
/// answered from whichever end is nearer — the start of the source or the
/// scan's own position — so a related span that points back a little
/// (an opener, a declaration near the top) costs a little.
pub const PositionCursor = struct {
    tracker: Tracker = .{},

    pub fn locate(self: *PositionCursor, source: []const u8, byte_offset: u32) Location {
        std.debug.assert(byte_offset <= source.len);
        const high = self.tracker.location.byte_offset;
        if (byte_offset >= high) {
            self.tracker.advanceSlice(source[high..byte_offset]);
            return self.tracker.location;
        }
        if (byte_offset < high - byte_offset) return resolve(source, byte_offset);
        return behind(source, self.tracker.location, byte_offset);
    }
};

/// The position of `byte_offset` given the position `high` of a later
/// offset: lines are counted back over `source[byte_offset..high]` and the
/// column from the line start. Same terminator policy as `Tracker`: LF,
/// CRLF and standalone CR each end one line.
fn behind(source: []const u8, high: Location, byte_offset: u32) Location {
    var lines: u32 = 0;
    var i: usize = byte_offset;
    while (i < high.byte_offset) : (i += 1) {
        switch (source[i]) {
            '\r' => lines += 1,
            '\n' => if (i == 0 or source[i - 1] != '\r') {
                lines += 1;
            },
            else => {},
        }
    }
    var line_start: usize = byte_offset;
    while (line_start > 0 and source[line_start - 1] != '\n' and source[line_start - 1] != '\r') line_start -= 1;
    return .{
        .byte_offset = byte_offset,
        .line = high.line - lines,
        .byte_column = @intCast(byte_offset - line_start + 1),
    };
}

/// Constant-size newline-aware position tracker: the scan behind `locate`
/// and `PositionCursor`. Nothing in the parser runs one per byte.
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

test "span end offset, slicing and locating" {
    const source = "graph {\n  a -- b;\n}";
    const span: Span = .{ .start = 10, .len = 1 };
    try expectEqual(@as(u64, 11), span.endOffset());
    try std.testing.expectEqualStrings("a", span.slice(source));
    try expectEqual(Location{ .byte_offset = 10, .line = 2, .byte_column = 3 }, span.locate(source));
    // Ranges are spans: the retained records store the same eight bytes.
    const range: Range = span;
    try expectEqual(span, range);
}

test "positions are 32-bit and the boundary span still fits" {
    try expectEqual(@as(usize, std.math.maxInt(u32)), max_source_len);
    try expectEqual(@as(usize, 12), @sizeOf(Location));
    try expectEqual(@as(usize, 8), @sizeOf(Span));
    // The last representable byte: end == maxInt(u32).
    const boundary: Span = .{ .start = std.math.maxInt(u32) - 1, .len = 1 };
    try expectEqual(@as(u64, std.math.maxInt(u32)), boundary.endOffset());
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
    for ([_]u32{ 0, 12, 23, 23, 30 }) |offset| {
        try expectEqual(locate(source, offset), cursor.locate(source, offset));
    }
}

test "position cursor matches locate for queries in any order" {
    // Every newline style, including a CRLF split by a query, and queries
    // that jump back both near the scan and near the start.
    const source = "ab\r\ncd\r\n\n\ref\rg\n\nhi\r\n\r\njk";
    var cursor: PositionCursor = .{};
    var prng = std.Random.DefaultPrng.init(0x706f73);
    for (0..2000) |_| {
        const offset = prng.random().uintAtMost(u32, @intCast(source.len));
        try expectEqual(locate(source, offset), cursor.locate(source, offset));
    }
    // Every position after the scan sits at the end.
    _ = cursor.locate(source, @intCast(source.len));
    for (0..source.len + 1) |offset| {
        try expectEqual(locate(source, offset), cursor.locate(source, @intCast(offset)));
    }
}
