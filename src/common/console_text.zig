//! Bounded, allocation-free source presentation; not part of a parser's path.
const std = @import("std");
const utf8 = @import("utf8.zig");
const widths = @import("console_widths.zig");

pub const Style = enum { unicode, ascii };
pub const max_bytes = 64;

fn contains(ranges: []const [2]u21, scalar: u21) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (scalar < ranges[mid][0]) high = mid else if (scalar > ranges[mid][1]) low = mid + 1 else return true;
    }
    return false;
}

const Unit = struct { len: u3, cells: u5, escaped: bool = false, tab: bool = false };

fn unit(bytes: []const u8, style: Style, column: usize, anchored: bool) Unit {
    const byte = bytes[0];
    if (byte == '\t') return .{ .len = 1, .cells = @intCast(8 - column % 8), .tab = true };
    if (std.ascii.isPrint(byte)) return .{ .len = 1, .cells = 1 };
    const decoded = if (style == .unicode) utf8.decode(bytes) else null;
    if (decoded) |d| {
        if (!contains(&widths.control, d.scalar) and
            !(d.scalar >= 0xfdd0 and d.scalar <= 0xfdef) and d.scalar & 0xffff < 0xfffe)
        {
            const zero = contains(&widths.zero, d.scalar);
            if (!zero or anchored) return .{ .len = d.len, .cells = if (zero) 0 else if (contains(&widths.wide, d.scalar)) 2 else 1 };
        }
        return .{ .len = d.len, .cells = @as(u5, d.len) * 4, .escaped = true };
    }
    return .{ .len = 1, .cells = 4, .escaped = true };
}

fn writeUnit(bytes: []const u8, u: Unit, writer: anytype) !void {
    if (u.escaped) {
        for (bytes) |byte| try writer.print("\\x{X:0>2}", .{byte});
    } else if (u.tab) {
        try writer.writeAll("        "[0..u.cells]);
    } else try writer.writeAll(bytes);
}

/// Presentation width is deterministic: wide/fullwidth scalars occupy two cells,
/// nonspacing/enclosing marks and trailing Hangul Jamo zero, others one. Controls,
/// formatting characters and invalid bytes are escaped. This is not shaping or
/// a promise about every terminal's emoji/grapheme rendering. ASCII escapes all
/// non-ASCII bytes. Tabs expand to eight-cell stops relative to the excerpt.
/// Per-byte maps keep partial scalar spans safe and point combining marks at
/// their base; locations themselves always remain byte-based.
pub const Layout = struct {
    starts: [max_bytes + 1]u16 = undefined,
    ends: [max_bytes + 1]u16 = undefined,

    pub fn write(self: *Layout, bytes: []const u8, style: Style, writer: anytype) !void {
        std.debug.assert(bytes.len <= max_bytes);
        var offset: usize = 0;
        var column: u16 = 0;
        var base: u16 = 0;
        var anchored = false;
        while (offset < bytes.len) {
            const u = unit(bytes[offset..], style, column, anchored);
            const start = if (u.cells == 0) base else column;
            column += u.cells;
            for (offset..offset + u.len) |i| {
                self.starts[i] = start;
                self.ends[i] = column;
            }
            try writeUnit(bytes[offset..][0..u.len], u, writer);
            if (u.cells != 0) {
                base = start;
                anchored = !u.escaped and !u.tab;
            }
            offset += u.len;
        }
        self.starts[bytes.len] = column;
        self.ends[bytes.len] = column;
    }
};

/// Bounded inline source names: no tabs/newlines/escape sequences may affect the
/// surrounding message. Long names are clipped on scalar boundaries.
pub fn writeInline(bytes: []const u8, style: Style, writer: anytype) !void {
    var offset: usize = 0;
    var anchored = false;
    while (offset < bytes.len and offset < 32) {
        var u = unit(bytes[offset..], style, 0, anchored);
        if (u.tab) u = .{ .len = 1, .cells = 4, .escaped = true };
        try writeUnit(bytes[offset..][0..u.len], u, writer);
        if (u.cells != 0) anchored = !u.escaped;
        offset += u.len;
    }
    if (offset < bytes.len) try writer.writeAll("...");
}

/// Include a scalar crossing the left window edge, without swallowing malformed
/// continuation bytes. At most three earlier bytes need examination.
pub fn scalarStart(source: []const u8, offset: usize) usize {
    var candidate = offset;
    while (candidate > 0 and offset - candidate < 3) {
        candidate -= 1;
        if (utf8.decode(source[candidate..])) |d| {
            if (candidate + d.len > offset) return candidate;
        }
    }
    return offset;
}

test "console Unicode tables are sorted non-overlapping ranges" {
    inline for (.{ widths.wide, widths.zero, widths.control }) |ranges| {
        for (ranges, 0..) |range, i| {
            try std.testing.expect(range[0] <= range[1]);
            if (i > 0) try std.testing.expect(ranges[i - 1][1] < range[0]);
        }
    }
}

test "console display cells map whole scalars combining marks tabs and escapes" {
    try std.testing.expectEqual(@as(usize, 260), @sizeOf(Layout));
    const input = "café 中文 e\u{301}\t\xff\x1b\u{202e}";
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var layout: Layout = .{};
    try layout.write(input, .unicode, &writer);
    try std.testing.expectEqualStrings("café 中文 e\u{301}     \\xFF\\x1B\\xE2\\x80\\xAE", writer.buffered());
    try std.testing.expectEqual(@as(u16, 3), layout.starts[3]); // both bytes of é
    try std.testing.expectEqual(@as(u16, 3), layout.starts[4]);
    try std.testing.expectEqual(@as(u16, 4), layout.ends[4]);
    for (6..9) |i| { // 中
        try std.testing.expectEqual(@as(u16, 5), layout.starts[i]);
        try std.testing.expectEqual(@as(u16, 7), layout.ends[i]);
    }
    for (13..16) |i| { // base e and both combining-mark bytes
        try std.testing.expectEqual(@as(u16, 10), layout.starts[i]);
        try std.testing.expectEqual(@as(u16, 11), layout.ends[i]);
    }
    try std.testing.expectEqual(@as(u16, 16), layout.ends[16]); // tab
    try std.testing.expectEqual(@as(u16, 36), layout.starts[input.len]);
}

test "console clipping only moves offsets inside valid scalars" {
    const bytes = "aé中😀\xff\x80";
    const starts = [_]usize{ 0, 1, 1, 3, 3, 3, 6, 6, 6, 6, 10, 11, 12 };
    for (starts, 0..) |expected, offset| try std.testing.expectEqual(expected, scalarStart(bytes, offset));
}

test "console escapes controls leading combining marks and every non-ASCII byte in ASCII mode" {
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var layout: Layout = .{};
    try layout.write("\u{301}é\u{85}\u{200d}\u{2028}\u{ffff}\xe2\x82", .unicode, &writer);
    try std.testing.expectEqualStrings("\\xCC\\x81é\\xC2\\x85\\xE2\\x80\\x8D\\xE2\\x80\\xA8\\xEF\\xBF\\xBF\\xE2\\x82", writer.buffered());
    writer.end = 0;
    try layout.write("é中", .ascii, &writer);
    try std.testing.expectEqualStrings("\\xC3\\xA9\\xE4\\xB8\\xAD", writer.buffered());
    try std.testing.expectEqual(@as(u16, 20), layout.starts[5]);
}
