//! One resumable scalar scanner. Each step examines at most one source byte
//! (or EOF); completing cached state may examine none. No AST or DOT dependency.
const support = @import("parser_support");
const Span = support.location.Span;
const diagnostic = @import("diagnostic.zig");
const result = @import("result.zig");
pub const Token = struct {
    /// Attribute-free tags remain whole tokens. A tag with attributes yields
    /// open_head, attribute*, then head_end/empty_end. No header buffering.
    kind: enum { text, comment, cdata, open, close, empty, open_head, attribute, head_end, empty_end, eof },
    /// Whole token except attribute: there it is the quoted value span.
    span: Span,
    name: Span = .{ .start = 0, .len = 0 },
};
pub const Result = union(enum) { token: Token, problem: result.Problem };
/// Recoverable lexical finding, interpreted only by the policy-bound parser.
const ScanResult = union(enum) { token: Token, problem: result.Problem, malformed_reference: diagnostic.Diagnostic };

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
fn digit(byte: u8, radix: u8) ?u32 {
    const value: u32 = switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => return null,
    };
    return if (value < radix) value else null;
}
fn referenceCharacter(value: u32) bool {
    // XML 1.0 Char range, without decoding or emitting replacement bytes.
    return value == 9 or value == 10 or value == 13 or
        (value >= 0x20 and value <= 0xd7ff) or
        (value >= 0xe000 and value <= 0xfffd) or
        (value >= 0x10000 and value <= 0x10ffff);
}

pub fn ScannerFor(comptime metered: bool) type {
    return struct {
        const Scanner = @This();
        source: []const u8,
        offset: u32 = 0,
        frontier: if (metered) u32 else void = if (metered) 0 else {},
        state: enum { prefix, prefix_done, content, text, after_lt, end_start, name, after_name, slash, bang, attribute_name, before_equal, before_value, value, after_value, attributes, attribute_slash, comment_start, comment, comment_dash, comment_end, cdata_start, cdata, cdata_bracket, cdata_end, reference_start, reference_name, reference_number_start, reference_hex_start, reference_decimal, reference_hex } = .prefix,
        prefix: [4]u8 = .{0} ** 4,
        prefix_len: u3 = 0,
        start: u32 = 0,
        name_start: u32 = 0,
        name_end: u32 = 0,
        closing: bool = false,
        quote: u8 = 0,
        reference_start: u32 = 0,
        reference_value: u32 = 0,
        reference_context: enum { text, value } = .text,
        terminal: ?ScanResult = null,

        pub fn init(source: []const u8) Scanner {
            var scanner: Scanner = .{ .source = source };
            // Source is immutable. Guard the descriptor once, before any byte
            // examination, including when the standalone lexer is used.
            if (source.len > support.location.max_source_len) scanner.terminal = .{ .problem = .{
                .outcome = .{ .resource_limit = .{ .resource = .source_bytes, .limit = @intCast(support.location.max_source_len) } },
                .diagnostic = .{ .code = .capacity_exhausted, .span = .{ .start = 0, .len = 0 }, .details = .{ .capacity = .{ .resource = .source_bytes, .limit = @intCast(support.location.max_source_len) } } },
            } };
            return scanner;
        }
        fn problem(self: *Scanner, code: diagnostic.Code, at: u32, details: diagnostic.Details) ScanResult {
            const r: ScanResult = .{ .problem = .{
                .outcome = if (details == .feature) .{ .unsupported_feature = details.feature } else .invalid_syntax,
                .diagnostic = .{ .code = code, .span = .{ .start = at, .len = if (at < self.source.len) 1 else 0 }, .details = details },
            } };
            self.terminal = r;
            return r;
        }
        fn unsupported(self: *Scanner, feature: diagnostic.Feature, at: u32) ScanResult {
            return self.problem(.unsupported_feature, at, .{ .feature = feature });
        }
        fn token(self: *Scanner, kind: @FieldType(Token, "kind")) ScanResult {
            const t: Token = .{ .kind = kind, .span = .{ .start = self.start, .len = self.offset - self.start }, .name = if (kind == .text or kind == .comment or kind == .cdata or kind == .head_end or kind == .empty_end) .{ .start = 0, .len = 0 } else .{ .start = self.name_start, .len = self.name_end - self.name_start } };
            self.state = .content;
            return .{ .token = t };
        }

        fn beginReference(self: *Scanner, context: @FieldType(Scanner, "reference_context")) void {
            self.reference_start = self.offset;
            self.reference_context = context;
            self.offset += 1; // '&'
            self.state = .reference_start;
        }
        fn endReference(self: *Scanner) void {
            self.state = switch (self.reference_context) {
                .text => .text,
                .value => .value,
            };
        }
        fn malformedReference(self: *Scanner, reason: diagnostic.ReferenceProblem) ScanResult {
            self.endReference();
            // Consumed candidate bytes are already literal-safe in this context.
            // Do not rewind/rescan them or consume the byte that stopped recognition.
            return .{ .malformed_reference = .{
                .code = .malformed_reference,
                .span = .{ .start = self.reference_start, .len = self.offset - self.reference_start },
                .details = .{ .reference = reason },
            } };
        }

        pub fn step(self: *Scanner) ?ScanResult {
            if (self.terminal) |r| return r;
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
                    .reference_start => return self.malformedReference(.missing_name),
                    .reference_number_start, .reference_hex_start => return self.malformedReference(.missing_digits),
                    .reference_name, .reference_decimal, .reference_hex => return self.malformedReference(.missing_semicolon),
                    .text => return self.token(.text),
                    .content => {
                        const r: ScanResult = .{ .token = .{ .kind = .eof, .span = .{ .start = at, .len = 0 } } };
                        self.terminal = r;
                        return r;
                    },
                    else => return self.problem(.unexpected_end, at, .{ .expected = switch (self.state) {
                        .after_lt, .end_start => .name,
                        .slash => .closing_angle,
                        .attribute_slash => .closing_angle,
                        .attribute_name, .before_equal => .equal_sign,
                        .before_value, .value => .quote,
                        .after_value => .attribute_separator,
                        .bang => .declaration_start,
                        .comment_start => .comment_start,
                        .comment, .comment_dash, .comment_end => .comment_end,
                        .cdata_start => .cdata_start,
                        .cdata, .cdata_bracket, .cdata_end => .cdata_end,
                        else => .tag_end,
                    } }),
                }
            }
            const byte = self.source[at];
            if (metered) self.frontier = @max(self.frontier, at + 1);
            if (byte < 0x20 and !whitespace(byte)) return self.problem(.invalid_byte, at, .{ .byte = byte });
            // Text runs need no dispatch through tag/reference continuation
            // states. Keep one-byte stepping, including boundary lookahead.
            if (self.state == .text) {
                if (byte == '<') return self.token(.text);
                if (byte == '&') self.beginReference(.text) else self.offset += 1;
                return null;
            }
            switch (self.state) {
                .content => {
                    self.start = at;
                    if (byte == '<') {
                        self.offset += 1;
                        self.state = .after_lt;
                        self.closing = false;
                    } else if (byte == '&') self.beginReference(.text) else {
                        self.offset += 1;
                        self.state = .text;
                    }
                },
                .text => unreachable,
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
                    } else if (!self.closing and isNameStart(byte)) {
                        const head = self.token(.open_head);
                        // Save the header's original span/name before consuming
                        // the attribute byte already examined by this step.
                        self.name_start = at;
                        self.offset += 1;
                        self.state = .attribute_name;
                        return head;
                    } else return self.problem(.unexpected_byte, at, .{ .expected = .tag_end });
                },
                .slash => {
                    if (byte != '>') return self.problem(.unexpected_byte, at, .{ .expected = .closing_angle });
                    self.offset += 1;
                    return self.token(.empty);
                },
                .attribute_name => {
                    if (isNameContinue(byte)) {
                        self.offset += 1;
                        return null;
                    }
                    self.name_end = at;
                    if (byte == '=') {
                        self.offset += 1;
                        self.state = .before_value;
                    } else if (whitespace(byte)) {
                        self.offset += 1;
                        self.state = .before_equal;
                    } else return self.problem(.unexpected_byte, at, .{ .expected = .equal_sign });
                },
                .before_equal => {
                    if (whitespace(byte)) {
                        self.offset += 1;
                    } else if (byte == '=') {
                        self.offset += 1;
                        self.state = .before_value;
                    } else return self.problem(.unexpected_byte, at, .{ .expected = .equal_sign });
                },
                .before_value => {
                    if (whitespace(byte)) {
                        self.offset += 1;
                    } else if (byte == '\'' or byte == '"') {
                        self.start = at;
                        self.quote = byte;
                        self.offset += 1;
                        self.state = .value;
                    } else return self.problem(.unexpected_byte, at, .{ .expected = .quote });
                },
                .value => {
                    if (byte == '&') {
                        self.beginReference(.value);
                        return null;
                    }
                    if (byte == '<') return self.problem(.unexpected_byte, at, .{ .expected = .attribute_value });
                    self.offset += 1;
                    if (byte == self.quote) {
                        const attribute = self.token(.attribute);
                        self.state = .after_value;
                        return attribute;
                    }
                },
                .after_value, .attributes => {
                    if (whitespace(byte)) {
                        self.offset += 1;
                        self.state = .attributes;
                    } else if (byte == '>') {
                        self.start = at;
                        self.offset += 1;
                        return self.token(.head_end);
                    } else if (byte == '/') {
                        self.start = at;
                        self.offset += 1;
                        self.state = .attribute_slash;
                    } else if (self.state == .attributes and isNameStart(byte)) {
                        self.name_start = at;
                        self.offset += 1;
                        self.state = .attribute_name;
                    } else return self.problem(.unexpected_byte, at, .{ .expected = .attribute_separator });
                },
                .attribute_slash => {
                    if (byte != '>') return self.problem(.unexpected_byte, at, .{ .expected = .closing_angle });
                    self.offset += 1;
                    return self.token(.empty_end);
                },
                .bang => switch (byte) {
                    '-' => {
                        self.offset += 1;
                        self.state = .comment_start;
                    },
                    '[' => {
                        self.offset += 1;
                        self.prefix_len = 0;
                        self.state = .cdata_start;
                    },
                    else => return self.unsupported(.declarations, self.start),
                },
                .comment_start => {
                    if (byte != '-') return self.problem(.unexpected_byte, at, .{ .expected = .comment_start });
                    self.offset += 1;
                    self.state = .comment;
                },
                .comment => {
                    self.offset += 1;
                    if (byte == '-') self.state = .comment_dash;
                },
                .comment_dash => {
                    self.offset += 1;
                    self.state = if (byte == '-') .comment_end else .comment;
                },
                .comment_end => {
                    if (byte != '>') return self.problem(.unexpected_byte, at, .{ .expected = .comment_end });
                    self.offset += 1;
                    return self.token(.comment);
                },
                .cdata_start => {
                    if (byte != "CDATA["[self.prefix_len]) return self.problem(.unexpected_byte, at, .{ .expected = .cdata_start });
                    self.offset += 1;
                    self.prefix_len += 1;
                    if (self.prefix_len == 6) self.state = .cdata;
                },
                .cdata => {
                    self.offset += 1;
                    if (byte == ']') self.state = .cdata_bracket;
                },
                .cdata_bracket => {
                    self.offset += 1;
                    self.state = if (byte == ']') .cdata_end else .cdata;
                },
                .cdata_end => {
                    self.offset += 1;
                    if (byte == '>') return self.token(.cdata);
                    if (byte != ']') self.state = .cdata;
                },
                .reference_start => {
                    if (byte == '#') {
                        self.reference_value = 0;
                        self.offset += 1;
                        self.state = .reference_number_start;
                    } else if (isNameStart(byte)) {
                        self.offset += 1;
                        self.state = .reference_name;
                    } else return self.malformedReference(.missing_name);
                },
                .reference_name => {
                    if (byte == ';') {
                        self.offset += 1;
                        self.endReference();
                    } else if (isNameContinue(byte)) {
                        self.offset += 1;
                    } else return self.malformedReference(.missing_semicolon);
                },
                .reference_number_start, .reference_hex_start => {
                    if (self.state == .reference_number_start and byte == 'x') {
                        self.offset += 1;
                        self.state = .reference_hex_start;
                    } else if (digit(byte, if (self.state == .reference_hex_start) 16 else 10)) |value| {
                        self.reference_value = value;
                        self.offset += 1;
                        self.state = if (self.state == .reference_hex_start) .reference_hex else .reference_decimal;
                    } else return self.malformedReference(.missing_digits);
                },
                .reference_decimal, .reference_hex => {
                    if (byte == ';') {
                        self.offset += 1;
                        if (!referenceCharacter(self.reference_value)) return self.malformedReference(.invalid_character);
                        self.endReference();
                    } else if (digit(byte, if (self.state == .reference_hex) 16 else 10)) |value| {
                        // Saturation avoids overflow for arbitrarily many digits,
                        // while consuming the full candidate in linear time.
                        const radix: u32 = if (self.state == .reference_hex) 16 else 10;
                        self.reference_value = @min(0x110000, self.reference_value * radix + value);
                        self.offset += 1;
                    } else return self.malformedReference(.missing_semicolon);
                },
                .prefix, .prefix_done => unreachable,
            }
            return null;
        }
    };
}

/// Strict lexical cursor over the same scanner. No tree or allocation.
pub const Lexer = struct {
    scanner: ScannerFor(false),
    pub fn init(source: []const u8) Lexer {
        return .{ .scanner = .init(source) };
    }
    pub fn next(self: *Lexer) Result {
        while (true) {
            if (self.scanner.step()) |r| return switch (r) {
                .token => |t| .{ .token = t },
                .problem => |p| .{ .problem = p },
                .malformed_reference => |d| blk: {
                    const p: result.Problem = .{ .outcome = .invalid_syntax, .diagnostic = d };
                    self.scanner.terminal = .{ .problem = p };
                    break :blk .{ .problem = p };
                },
            };
        }
    }
};

test "opening header preserves its spans while consuming the first attribute byte once" {
    const std = @import("std");
    const source = "<long-name x='1'/>";
    var scanner = ScannerFor(true).init(source);
    var head: ScanResult = undefined;
    while (true) {
        if (scanner.step()) |r| {
            head = r;
            break;
        }
    }
    try std.testing.expectEqual(.open_head, head.token.kind);
    try std.testing.expectEqualStrings("<long-name ", head.token.span.slice(source));
    try std.testing.expectEqualStrings("long-name", head.token.name.slice(source));
    const name_start: u32 = @intCast(std.mem.indexOfScalar(u8, source, 'x').?);
    try std.testing.expectEqual(name_start + 1, scanner.offset);
    try std.testing.expectEqual(scanner.offset, scanner.frontier);
    try std.testing.expectEqual(name_start, scanner.name_start);
    try std.testing.expect(scanner.step() == null); // reads '=', not 'x' again
    try std.testing.expectEqual(name_start + 2, scanner.offset);
    try std.testing.expectEqual(.before_value, scanner.state);
}
