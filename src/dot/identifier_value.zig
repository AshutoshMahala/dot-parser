//! Private traversal of already validated identifier expressions.
//! Public decoding validates first; syntax analysis uses committed spans.
const std = @import("std");
const cursor = @import("identifier_cursor.zig");

/// Internal analysis helpers for identifier spans from a committed Document.
/// No revalidation, decoded allocations or normalization; callers guarantee validity.
pub fn hashAssumeValid(raw: []const u8) u64 {
    var chunks: Chunks = .{ .raw = raw };
    var hash = std.hash.Wyhash.init(0);
    while (chunks.next()) |chunk| hash.update(chunk);
    return hash.final();
}

pub fn orderAssumeValid(a: []const u8, b: []const u8) std.math.Order {
    var left: Chunks = .{ .raw = a };
    var right: Chunks = .{ .raw = b };
    var l: []const u8 = &.{};
    var r: []const u8 = &.{};
    while (true) {
        if (l.len == 0) l = left.next() orelse &.{};
        if (r.len == 0) r = right.next() orelse &.{};
        if (l.len == 0 or r.len == 0) return std.math.order(l.len, r.len);
        const len = @min(l.len, r.len);
        const order = std.mem.order(u8, l[0..len], r[0..len]);
        if (order != .eq) return order;
        l = l[len..];
        r = r[len..];
    }
}

/// Traverses a validated expression only. Comments between string parts are
/// discarded along with '+' and whitespace; comment-like content inside a
/// quoted part is emitted unchanged. This is decoding, not a second validator.
pub const Chunks = struct {
    raw: []const u8,
    offset: usize = 0,
    quoted: bool = false,

    pub fn next(self: *Chunks) ?[]const u8 {
        if (self.offset == self.raw.len) return null;
        if (self.raw[0] != '"' and self.raw[0] != '<') {
            self.offset = self.raw.len;
            return self.raw;
        }
        while (self.offset < self.raw.len) {
            if (!self.quoted) {
                cursor.skipGlue(self.raw, &self.offset);
                if (self.offset == self.raw.len) return null;
                const open = self.raw[self.offset];
                self.offset += 1;
                if (open == '<') {
                    const body = self.offset;
                    self.offset = cursor.htmlEnd(self.raw, self.offset - 1);
                    const inner = self.raw[body .. self.offset - 1];
                    // Empty operands must not end logical key comparison.
                    if (inner.len != 0) return inner;
                    continue;
                }
                self.quoted = true;
                continue;
            }
            const start = self.offset;
            switch (self.raw[start]) {
                '"' => {
                    self.offset += 1;
                    self.quoted = false;
                },
                '\\' => {
                    const after = self.raw[start + 1]; // validated escape pair
                    self.offset = cursor.escapeEnd(self.raw, start);
                    switch (after) {
                        '"' => return self.raw[start + 1 .. self.offset],
                        '\n' => {},
                        '\r' => {},
                        else => return self.raw[start..self.offset],
                    }
                },
                else => {
                    self.offset = cursor.quotedRunEnd(self.raw, start + 1);
                    return self.raw[start..self.offset];
                },
            }
        }
        return null;
    }
};
