//! Private traversal of already validated identifier expressions.
//! Public decoding validates first; syntax analysis uses committed spans.
const std = @import("std");

/// Internal analysis helpers for identifier spans from a committed Document.
/// No rescanning, decoded strings or normalization; callers guarantee validity.
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

/// Traverses a validated expression only. Comments between quoted parts are
/// discarded along with '+' and whitespace; comment-like content inside a
/// quoted part is emitted unchanged. This is decoding, not a second validator.
pub const Chunks = struct {
    raw: []const u8,
    offset: usize = 0,

    pub fn next(self: *Chunks) ?[]const u8 {
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
