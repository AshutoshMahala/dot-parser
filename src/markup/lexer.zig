//! One state machine with scalar and vector run scanning. Bounded scalar steps
//! examine one byte; bounded block steps use <=64-byte windows. Plain runs have no cap.
const runs = @import("lexer_runs.zig");
const policy = @import("policy.zig");
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

pub fn Scanner(comptime backend: policy.ScannerBackend, comptime metered: bool, comptime bounded: bool) type {
    return struct {
        const Self = @This();
        source: []const u8,
        offset: u32 = 0,
        frontier: if (metered) u32 else void = if (metered) 0 else {},
        state: enum { prefix, prefix_done, content, text, after_lt, end_start, name, after_name, slash, bang, attribute_name, before_equal, before_value, value, after_value, attributes, attribute_slash, comment_start, comment, comment_dash, comment_end, cdata_start, cdata, cdata_bracket, cdata_end, reference_start, reference_name, reference_number_start, reference_hex_start, reference_decimal, reference_hex } = .prefix,
        prefix: [4]u8 = .{0} ** 4,
        /// Shared progress for mutually exclusive markers: initial BOM probe
        /// (0..4), then "CDATA[" (0..6), reset when entering .cdata_start.
        /// Neither value is retained encoding metadata; both fit u3.
        marker_index: u3 = 0,
        start: u32 = 0,
        name_start: u32 = 0,
        name_end: u32 = 0,
        closing: bool = false,
        quote: u8 = 0,
        reference_start: u32 = 0,
        reference_value: u32 = 0,
        reference_context: enum { text, value } = .text,
        ready: ScanResult = undefined,
        done: bool = false,

        pub fn init(source: []const u8) Self {
            var scanner: Self = .{ .source = source };
            // Source is immutable. Guard the descriptor once, before any byte
            // examination, including when the standalone lexer is used.
            if (source.len > support.location.max_source_len) {
                scanner.done = true;
                scanner.ready = .{ .problem = .{
                    .outcome = .{ .resource_limit = .{ .resource = .source_bytes, .limit = @intCast(support.location.max_source_len) } },
                    .diagnostic = .{ .code = .capacity_exhausted, .span = .{ .start = 0, .len = 0 }, .details = .{ .capacity = .{ .resource = .source_bytes, .limit = @intCast(support.location.max_source_len) } } },
                } };
            }
            return scanner;
        }
        fn problem(self: *Self, code: diagnostic.Code, at: u32, details: diagnostic.Details) bool {
            const r: ScanResult = .{ .problem = .{
                .outcome = if (details == .feature) .{ .unsupported_feature = details.feature } else .invalid_syntax,
                .diagnostic = .{ .code = code, .span = .{ .start = at, .len = if (at < self.source.len) 1 else 0 }, .details = details },
            } };
            self.done = true;
            self.ready = r;
            return true;
        }
        fn unsupported(self: *Self, feature: diagnostic.Feature, at: u32) bool {
            return self.problem(.unsupported_feature, at, .{ .feature = feature });
        }
        fn token(self: *Self, kind: @FieldType(Token, "kind")) bool {
            const t: Token = .{ .kind = kind, .span = .{ .start = self.start, .len = self.offset - self.start }, .name = if (kind == .text or kind == .comment or kind == .cdata or kind == .head_end or kind == .empty_end) .{ .start = 0, .len = 0 } else .{ .start = self.name_start, .len = self.name_end - self.name_start } };
            self.state = .content;
            self.ready = .{ .token = t };
            return true;
        }

        fn beginReference(self: *Self, context: @FieldType(Self, "reference_context")) void {
            self.reference_start = self.offset;
            self.reference_context = context;
            self.offset += 1; // '&'
            self.state = .reference_start;
        }
        fn endReference(self: *Self) void {
            self.state = switch (self.reference_context) {
                .text => .text,
                .value => .value,
            };
        }
        fn malformedReference(self: *Self, reason: diagnostic.ReferenceProblem) bool {
            self.endReference();
            // Consumed candidate bytes are already literal-safe in this context.
            // Do not rewind/rescan them or consume the byte that stopped recognition.
            self.ready = .{ .malformed_reference = .{
                .code = .malformed_reference,
                .span = .{ .start = self.reference_start, .len = self.offset - self.reference_start },
                .details = .{ .reference = reason },
            } };
            return true;
        }

        /// Readiness only: the token/finding stays in scanner-owned storage.
        pub fn stepReady(self: *Self) bool {
            if (self.done) return true;
            if (bounded) {
                if (backend == .block and self.skipRun()) return false;
                return self.stepByte();
            }
            while (true) {
                _ = self.skipRun();
                if (self.stepByte()) return true;
            }
        }

        fn skipRun(self: *Self) bool {
            const run = switch (self.state) {
                .text => runs.prefix(backend, bounded, .text, self.source, self.offset),
                .name, .attribute_name, .reference_name => runs.prefix(backend, bounded, .name, self.source, self.offset),
                .value => if (self.quote == '"') runs.prefix(backend, bounded, .double_value, self.source, self.offset) else runs.prefix(backend, bounded, .single_value, self.source, self.offset),
                .after_name, .before_equal, .before_value, .attributes => runs.prefix(backend, bounded, .space, self.source, self.offset),
                .comment => runs.prefix(backend, bounded, .comment, self.source, self.offset),
                .cdata => runs.prefix(backend, bounded, .cdata, self.source, self.offset),
                else => return false,
            };
            if (metered) self.frontier = @max(self.frontier, self.offset + run.examined);
            self.offset += run.consumed;
            return run.consumed != 0;
        }

        fn stepByte(self: *Self) bool {
            if (self.state == .prefix) {
                if (self.marker_index < 4 and self.marker_index < self.source.len) {
                    self.prefix[self.marker_index] = self.source[self.marker_index];
                    self.marker_index += 1;
                    if (metered) self.frontier = self.marker_index;
                } else self.state = .prefix_done;
                return false;
            }
            if (self.state == .prefix_done) {
                const p = self.prefix;
                if ((self.marker_index >= 2 and ((p[0] == 0xff and p[1] == 0xfe) or (p[0] == 0xfe and p[1] == 0xff))) or
                    (self.marker_index == 4 and p[0] == 0 and p[1] == 0 and p[2] == 0xfe and p[3] == 0xff))
                    return self.unsupported(.encoding, 0);
                // A leading UTF-8 signature is not fragment text. Other occurrences
                // are ordinary bytes. Borrowed source and physical offsets stay intact.
                if (self.marker_index >= 3 and p[0] == 0xef and p[1] == 0xbb and p[2] == 0xbf) self.offset = 3;
                self.state = .content;
                return false;
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
                        self.done = true;
                        self.ready = r;
                        return true;
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
                return false;
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
                        return false;
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
                        return false;
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
                        return false;
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
                        return false;
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
                        self.marker_index = 0;
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
                    if (byte != "CDATA["[self.marker_index]) return self.problem(.unexpected_byte, at, .{ .expected = .cdata_start });
                    self.offset += 1;
                    self.marker_index += 1;
                    if (self.marker_index == 6) self.state = .cdata;
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
            return false;
        }
    };
}

/// Strict lexical cursor without a tree or allocation.
pub fn For(comptime backend: policy.ScannerBackend) type {
    return struct {
        const Self = @This();
        scanner: Scanner(backend, false, false),
        pub fn init(source: []const u8) Self {
            return .{ .scanner = .init(source) };
        }
        pub fn next(self: *Self) Result {
            _ = self.scanner.stepReady();
            return switch (self.scanner.ready) {
                .token => |t| .{ .token = t },
                .problem => |p| .{ .problem = p },
                .malformed_reference => |d| blk: {
                    const p: result.Problem = .{ .outcome = .invalid_syntax, .diagnostic = d };
                    self.scanner.ready = .{ .problem = p };
                    self.scanner.done = true;
                    break :blk .{ .problem = p };
                },
            };
        }
    };
}
pub const Lexer = For(policy.defaults.scanner);

test "opening header preserves its spans while consuming the first attribute byte once" {
    const std = @import("std");
    const source = "<long-name x='1'/>";
    var scanner = Scanner(.scalar, true, true).init(source);
    var head: ScanResult = undefined;
    while (true) {
        if (scanner.stepReady()) {
            head = scanner.ready;
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
    try std.testing.expect(!scanner.stepReady()); // reads '=', not 'x' again
    try std.testing.expectEqual(name_start + 2, scanner.offset);
    try std.testing.expectEqual(.before_value, scanner.state);
}

test "block runs add no scanner state or source-sized storage" {
    const std = @import("std");
    inline for (.{ false, true }) |metered| {
        try std.testing.expectEqual(@sizeOf(Scanner(.scalar, metered, true)), @sizeOf(Scanner(.block, metered, true)));
    }
}
