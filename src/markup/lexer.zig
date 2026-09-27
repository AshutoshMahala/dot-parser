//! One resumable scalar scanner. Each step examines at most one source byte
//! (or EOF); completing cached state may examine none. No AST or DOT dependency.
const support = @import("parser_support");
const Span = support.location.Span;
const diagnostic = @import("diagnostic.zig");
const result = @import("result.zig");
pub const Token = struct {
    kind: enum { text, open, close, empty, eof },
    span: Span,
    name: Span = .{ .start = 0, .len = 0 },
};
pub const Result = union(enum) { token: Token, problem: result.Problem };

pub fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_', ':', 0x80...0xff => true,
        else => false,
    };
}
pub fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or switch (byte) {
        '0'...'9', '-', '.' => true,
        else => false,
    };
}
fn whitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

pub fn ScannerFor(comptime metered: bool) type {
    return struct {
        const Scanner = @This();
        source: []const u8,
        offset: u32 = 0,
        frontier: if (metered) u32 else void = if (metered) 0 else {},
        state: enum { prefix, prefix_done, content, text, after_lt, end_start, name, after_name, slash, bang } = .prefix,
        prefix: [4]u8 = .{0} ** 4,
        prefix_len: u3 = 0,
        start: u32 = 0,
        name_start: u32 = 0,
        name_end: u32 = 0,
        closing: bool = false,
        terminal: ?Result = null,

        pub fn init(source: []const u8) Scanner {
            return .{ .source = source };
        }
        fn problem(self: *Scanner, code: diagnostic.Code, at: u32, details: diagnostic.Details) Result {
            const r: Result = .{ .problem = .{
                .outcome = if (details == .feature) .{ .unsupported_feature = details.feature } else .invalid_syntax,
                .diagnostic = .{ .code = code, .span = .{ .start = at, .len = if (at < self.source.len) 1 else 0 }, .details = details },
            } };
            self.terminal = r;
            return r;
        }
        fn unsupported(self: *Scanner, feature: diagnostic.Feature, at: u32) Result {
            return self.problem(.unsupported_feature, at, .{ .feature = feature });
        }
        fn token(self: *Scanner, kind: @FieldType(Token, "kind")) Result {
            const t: Token = .{ .kind = kind, .span = .{ .start = self.start, .len = self.offset - self.start }, .name = if (kind == .text) .{ .start = 0, .len = 0 } else .{ .start = self.name_start, .len = self.name_end - self.name_start } };
            self.state = .content;
            return .{ .token = t };
        }

        pub fn step(self: *Scanner) ?Result {
            if (self.terminal) |r| return r;
            if (self.source.len > support.location.max_source_len) {
                const r: Result = .{ .problem = .{
                    .outcome = .{ .resource_limit = .{ .resource = .source_bytes, .limit = @intCast(support.location.max_source_len) } },
                    .diagnostic = .{ .code = .capacity_exhausted, .span = .{ .start = 0, .len = 0 }, .details = .{ .capacity = .{ .resource = .source_bytes, .limit = @intCast(support.location.max_source_len) } } },
                } };
                self.terminal = r;
                return r;
            }
            if (self.state == .prefix) {
                if (self.prefix_len < 4 and self.prefix_len < self.source.len) {
                    self.prefix[self.prefix_len] = self.source[self.prefix_len];
                    self.prefix_len += 1;
                    if (metered) self.frontier = self.prefix_len;
                } else self.state = .prefix_done;
                return null;
            }
            if (self.state == .prefix_done) {
                const p = self.prefix;
                if ((self.prefix_len >= 2 and ((p[0] == 0xff and p[1] == 0xfe) or (p[0] == 0xfe and p[1] == 0xff))) or
                    (self.prefix_len == 4 and p[0] == 0 and p[1] == 0 and p[2] == 0xfe and p[3] == 0xff))
                    return self.unsupported(.encoding, 0);
                // A leading UTF-8 signature is not fragment text. Other occurrences
                // are ordinary bytes. Borrowed source and physical offsets stay intact.
                if (self.prefix_len >= 3 and p[0] == 0xef and p[1] == 0xbb and p[2] == 0xbf) self.offset = 3;
                self.state = .content;
                return null;
            }
            const at = self.offset;
            if (at == self.source.len) {
                switch (self.state) {
                    .text => return self.token(.text),
                    .content => {
                        const r: Result = .{ .token = .{ .kind = .eof, .span = .{ .start = at, .len = 0 } } };
                        self.terminal = r;
                        return r;
                    },
                    else => return self.problem(.unexpected_end, at, .{ .expected = switch (self.state) {
                        .after_lt, .end_start => .name,
                        else => .tag_end,
                    } }),
                }
            }
            const byte = self.source[at];
            if (metered) self.frontier = @max(self.frontier, at + 1);
            if (byte < 0x20 and !whitespace(byte)) return self.problem(.invalid_byte, at, .{ .byte = byte });
            switch (self.state) {
                .content => {
                    self.start = at;
                    if (byte == '<') {
                        self.offset += 1;
                        self.state = .after_lt;
                        self.closing = false;
                    } else if (byte == '&') return self.unsupported(.references, at) else {
                        self.offset += 1;
                        self.state = .text;
                    }
                },
                .text => {
                    if (byte == '<' or byte == '&') return self.token(.text);
                    self.offset += 1;
                },
                .after_lt => {
                    switch (byte) {
                        '/' => {
                            self.closing = true;
                            self.offset += 1;
                            self.state = .end_start;
                        },
                        '!' => {
                            self.offset += 1;
                            self.state = .bang;
                        },
                        '?' => return self.unsupported(.processing_instructions, self.start),
                        else => {
                            if (!isNameStart(byte)) return self.problem(.unexpected_byte, at, .{ .expected = .name });
                            self.name_start = at;
                            self.offset += 1;
                            self.state = .name;
                        },
                    }
                },
                .end_start => {
                    if (!isNameStart(byte)) return self.problem(.unexpected_byte, at, .{ .expected = .name });
                    self.name_start = at;
                    self.offset += 1;
                    self.state = .name;
                },
                .name => {
                    if (isNameContinue(byte)) {
                        self.offset += 1;
                        return null;
                    }
                    self.name_end = at;
                    if (byte == '>') {
                        self.offset += 1;
                        return self.token(if (self.closing) .close else .open);
                    }
                    if (whitespace(byte)) {
                        self.offset += 1;
                        self.state = .after_name;
                    } else if (byte == '/' and !self.closing) {
                        self.offset += 1;
                        self.state = .slash;
                    } else return self.problem(.unexpected_byte, at, .{ .expected = .tag_end });
                },
                .after_name => {
                    if (whitespace(byte)) {
                        self.offset += 1;
                        return null;
                    }
                    if (byte == '>') {
                        self.offset += 1;
                        return self.token(if (self.closing) .close else .open);
                    }
                    if (byte == '/' and !self.closing) {
                        self.offset += 1;
                        self.state = .slash;
                    } else if (!self.closing and isNameStart(byte)) return self.unsupported(.attributes, at) else return self.problem(.unexpected_byte, at, .{ .expected = .tag_end });
                },
                .slash => {
                    if (byte != '>') return self.problem(.unexpected_byte, at, .{ .expected = .closing_angle });
                    self.offset += 1;
                    return self.token(.empty);
                },
                .bang => return self.unsupported(switch (byte) {
                    '-' => .comments,
                    '[' => .cdata,
                    else => .declarations,
                }, self.start),
                .prefix, .prefix_done => unreachable,
            }
            return null;
        }
    };
}

/// Ordinary lexical cursor over the same scanner. No policy, tree or allocation.
pub const Lexer = struct {
    scanner: ScannerFor(false),
    pub fn init(source: []const u8) Lexer {
        return .{ .scanner = .init(source) };
    }
    pub fn next(self: *Lexer) Result {
        while (true) {
            if (self.scanner.step()) |r| return r;
        }
    }
};
