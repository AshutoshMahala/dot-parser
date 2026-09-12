//! Raw-byte lexer for the currently supported DOT subset.
//!
//! Recognizes the current subset: every DOT keyword (`graph` maps to the
//! `undigraph` kind at reading time, `digraph`, `strict`, plus the deferred
//! `subgraph`/`node`/`edge`); bare ASCII, numeral, and quoted identifiers;
//! `{`, `}`, `;`; the
//! edge operators `--` and `->`; whitespace (space, tab, LF, CRLF, CR);
//! and comments (`//`, `/* ... */`, and `#` through the physical line end).
//! Comments are skipped without retention. See docs/SUPPORTED_SYNTAX.md for
//! the comment and physical-location compatibility policy.
//!
//! Guarantees:
//! - Spans borrow from the caller's source; no allocation ever (R-MEM-001).
//! - State is instance-owned (R-ROB-003); no OS or filesystem access.
//! - Every `next` call either consumes input or returns a terminal result
//!   (`eof` or a failure); the lexer cannot loop forever.
//! - Every keyword tokenizes, including keywords of deferred constructs:
//!   whether `subgraph` legally introduces a subgraph or sits in an illegal
//!   grammar position is the parser's decision, which the lexer cannot
//!   make. Only *lexical* deferred constructs — HTML/non-ASCII identifiers,
//!   attribute punctuation, ports — are
//!   reported here as structured `profile_unsupported_feature` failures,
//!   distinct from bytes that are invalid in any DOT document (R-MOD-006).
//!   Detection stops at the introducer: neither the construct's body nor
//!   the remaining input is checked, so an unsupported result makes no
//!   whole-input validity claim.

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");

pub const Token = struct {
    tag: Tag,
    span: location.Span,

    pub const Tag = enum {
        keyword_graph,
        keyword_digraph,
        keyword_strict,
        keyword_subgraph,
        keyword_node,
        keyword_edge,
        identifier,
        edge_undirected,
        edge_directed,
        left_brace,
        right_brace,
        semicolon,
        eof,
    };
};

/// The outcome of one `Lexer.next` call. A failure is terminal: the lexer
/// does not advance past the offending bytes, so calling `next` again
/// returns the same failure.
pub const Result = union(enum) {
    token: Token,
    failure: diagnostic.Diagnostic,
};

pub const Lexer = struct {
    source: []const u8,
    tracker: location.Tracker = .{},

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Result {
        if (!self.skipTrivia()) return self.unterminatedComment();
        const start = self.here();
        const byte = self.peek(0) orelse return .{ .token = .{
            .tag = .eof,
            .span = .{ .start = start, .byte_len = 0 },
        } };

        return switch (byte) {
            '{' => self.single(.left_brace),
            '}' => self.single(.right_brace),
            ';' => self.single(.semicolon),
            'A'...'Z', 'a'...'z', '_' => self.identifierOrKeyword(),
            '-' => self.dash(),
            '0'...'9' => self.numeral(),
            // A leading '.' is a DOT numeral only when a digit follows
            // (grammar: `-?(.[0-9]+ | [0-9]+(.[0-9]*)?)`); a bare '.' is
            // invalid in any DOT document.
            '.' => if (self.peek(1)) |after| switch (after) {
                '0'...'9' => self.numeral(),
                else => self.invalidByte(),
            } else self.invalidByte(),
            '"' => self.quotedIdentifier(),
            // Valid DOT, deferred to later slices (R-MOD-006 detectors).
            '<' => unsupported(start, 1, .html_identifier),
            '[', ']', ',' => unsupported(start, 1, .attribute_list),
            '=' => unsupported(start, 1, .attribute_assignment),
            ':' => unsupported(start, 1, .port_or_compass),
            // DOT permits bytes 0x80–0xFF in unquoted identifiers
            // ([a-zA-Z\200-\377]); milestone 1 is ASCII-only, so this is a
            // deferred feature, not malformed input.
            0x80...0xFF => self.nonAsciiIdentifier(start, 0),
            else => self.invalidByte(),
        };
    }

    /// Location of the next unconsumed byte.
    fn here(self: *const Lexer) location.Location {
        return self.tracker.location;
    }

    fn peek(self: *const Lexer, ahead: usize) ?u8 {
        const offset = self.tracker.location.byte_offset;
        if (ahead >= self.source.len - offset) return null;
        return self.source[offset + ahead];
    }

    fn consume(self: *Lexer, count: usize) void {
        for (0..count) |_| {
            self.tracker.advance(self.source[self.tracker.location.byte_offset]);
        }
    }

    /// Returns false only for an unterminated block comment. Comment bodies
    /// are opaque bytes: no decoding, nesting, directives, or allocations.
    fn skipTrivia(self: *Lexer) bool {
        while (self.peek(0)) |byte| {
            switch (byte) {
                ' ', '\t', '\n', '\r' => self.consume(1),
                '#' => self.skipLineComment(),
                '/' => {
                    const after = self.peek(1) orelse return true;
                    switch (after) {
                        '/' => self.skipLineComment(),
                        '*' => {
                            // Look ahead like identifier scanning: advance
                            // positions only after the construct is complete.
                            // On failure, the tracker remains at the opener.
                            var len: usize = 2;
                            while (self.peek(len)) |body| : (len += 1) {
                                if (body == '*' and self.peek(len + 1) == '/') {
                                    self.consume(len + 2);
                                    break;
                                }
                            } else {
                                return false;
                            }
                        },
                        else => return true,
                    }
                },
                else => return true,
            }
        }
        return true;
    }

    fn skipLineComment(self: *Lexer) void {
        while (self.peek(0)) |byte| {
            if (byte == '\n' or byte == '\r') return;
            self.consume(1);
        }
    }

    fn unterminatedComment(self: *const Lexer) Result {
        return .{ .failure = .{
            .code = .lexer_unterminated_construct,
            .span = .{ .start = self.here(), .byte_len = 2 },
            .details = .{ .unterminated = .block_comment },
        } };
    }

    fn single(self: *Lexer, tag: Token.Tag) Result {
        const start = self.here();
        self.consume(1);
        return .{ .token = .{ .tag = tag, .span = .{ .start = start, .byte_len = 1 } } };
    }

    /// DOT numerals are textual IDs, not floating-point values. Maximal
    /// matching follows -?(.[0-9]+ | [0-9]+(.[0-9]*)?); exponent notation
    /// and a leading '+' are not part of the grammar.
    fn numeral(self: *Lexer) Result {
        const start = self.here();
        var len: usize = if (self.peek(0) == '-') 1 else 0;
        while (self.peek(len)) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            len += 1;
        }
        if (self.peek(len) == '.') {
            len += 1;
            while (self.peek(len)) |byte| {
                if (!std.ascii.isDigit(byte)) break;
                len += 1;
            }
        }
        self.consume(len);
        return .{ .token = .{ .tag = .identifier, .span = .{ .start = start, .byte_len = len } } };
    }

    /// One lexical identifier expression, including quoted '+' components.
    /// Retain one raw range, not an allocated list of string parts. Trailing
    /// trivia is inspected for '+' but excluded from the returned span.
    /// A local cursor keeps failures repeatable without rewinding live state.
    fn quotedIdentifier(self: *Lexer) Result {
        const start = self.here();
        var cursor = self.*;
        while (true) {
            const opener = cursor.here();
            cursor.consume(1); // opening quote
            while (cursor.peek(0)) |byte| {
                if (byte == 0) return cursor.invalidByte();
                if (byte == '"') {
                    cursor.consume(1);
                    break;
                }
                if (byte == '\\') {
                    // Escaped quotes do not end the segment. A double
                    // backslash is consumed as a pair but preserved on
                    // decoding; other escape spellings are also preserved.
                    cursor.consume(1);
                    if (cursor.peek(0)) |after| {
                        if (after == 0) return cursor.invalidByte();
                        cursor.consume(1);
                        if (after == '\r' and cursor.peek(0) == '\n') cursor.consume(1);
                    }
                } else {
                    cursor.consume(1);
                }
            } else {
                return .{ .failure = .{
                    .code = .lexer_unterminated_construct,
                    .span = .{ .start = opener, .byte_len = 1 },
                    .details = .{ .unterminated = .quoted_identifier },
                } };
            }

            const end = cursor;
            // With no '+', leave trailing trivia for the next token,
            // including any malformed block comment that it contains.
            if (!cursor.skipTrivia() or cursor.peek(0) != '+') {
                self.* = end;
                return .{ .token = .{
                    .tag = .identifier,
                    .span = .{ .start = start, .byte_len = end.here().byte_offset - start.byte_offset },
                } };
            }
            cursor.consume(1);
            if (!cursor.skipTrivia()) return cursor.unterminatedComment();
            if (cursor.peek(0) != '"') {
                return .{ .failure = .{
                    .code = .lexer_invalid_concatenation,
                    .span = .{ .start = cursor.here(), .byte_len = if (cursor.peek(0) == null) 0 else 1 },
                    .details = .{ .expected_quote = cursor.peek(0) },
                } };
            }
        }
    }

    fn identifierOrKeyword(self: *Lexer) Result {
        const start = self.here();
        var len: usize = 1;
        while (self.peek(len)) |byte| : (len += 1) {
            switch (byte) {
                'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
                else => break,
            }
        }
        // An ASCII identifier running directly into a 0x80–0xFF byte is one
        // DOT identifier using the deferred non-ASCII range — report it as
        // such rather than splitting it into a token plus an error.
        if (self.peek(len)) |after| {
            if (after >= 0x80) {
                return self.nonAsciiIdentifier(start, len);
            }
        }

        const word = self.source[start.byte_offset..][0..len];

        // DOT keywords are case-independent (graphviz.org/doc/info/lang.html).
        // Keywords of deferred constructs tokenize too: only the parser
        // knows whether they introduce the construct or are misplaced.
        const keywords = [_]struct { word: []const u8, tag: Token.Tag }{
            .{ .word = "graph", .tag = .keyword_graph },
            .{ .word = "digraph", .tag = .keyword_digraph },
            .{ .word = "strict", .tag = .keyword_strict },
            .{ .word = "subgraph", .tag = .keyword_subgraph },
            .{ .word = "node", .tag = .keyword_node },
            .{ .word = "edge", .tag = .keyword_edge },
        };
        for (keywords) |keyword| {
            if (std.ascii.eqlIgnoreCase(word, keyword.word)) {
                self.consume(len);
                return .{ .token = .{
                    .tag = keyword.tag,
                    .span = .{ .start = start, .byte_len = len },
                } };
            }
        }

        self.consume(len);
        return .{ .token = .{
            .tag = .identifier,
            .span = .{ .start = start, .byte_len = len },
        } };
    }

    fn dash(self: *Lexer) Result {
        const start = self.here();
        if (self.peek(1)) |after| switch (after) {
            '-' => {
                self.consume(2);
                return .{ .token = .{
                    .tag = .edge_undirected,
                    .span = .{ .start = start, .byte_len = 2 },
                } };
            },
            '>' => {
                self.consume(2);
                return .{ .token = .{
                    .tag = .edge_directed,
                    .span = .{ .start = start, .byte_len = 2 },
                } };
            },
            // A '-' introducing a digit is a negative DOT numeral; `-.` is
            // one only when a digit follows the '.'.
            '0'...'9' => return self.numeral(),
            '.' => if (self.peek(2)) |third| switch (third) {
                '0'...'9' => return self.numeral(),
                else => {},
            },
            else => {},
        };
        return self.invalidByte();
    }

    /// Span the complete identifier run (ASCII identifier bytes and the
    /// deferred 0x80–0xFF range) so a renderer underlines the whole
    /// construct, not just its first non-ASCII byte.
    fn nonAsciiIdentifier(self: *const Lexer, start: location.Location, prefix_len: usize) Result {
        var len = prefix_len + 1;
        while (self.peek(len)) |byte| : (len += 1) {
            switch (byte) {
                'A'...'Z', 'a'...'z', '0'...'9', '_', 0x80...0xFF => {},
                else => break,
            }
        }
        return unsupported(start, len, .non_ascii_identifier);
    }

    fn invalidByte(self: *Lexer) Result {
        const start = self.here();
        return .{ .failure = .{
            .code = .lexer_invalid_byte,
            .span = .{ .start = start, .byte_len = 1 },
            .details = .{ .invalid_byte = self.source[start.byte_offset] },
        } };
    }

    fn unsupported(start: location.Location, byte_len: usize, feature: diagnostic.Feature) Result {
        return .{ .failure = .{
            .code = .profile_unsupported_feature,
            .span = .{ .start = start, .byte_len = byte_len },
            .details = .{ .unsupported_feature = feature },
        } };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectToken(lexer: *Lexer, tag: Token.Tag, text: []const u8) !void {
    const result = lexer.next();
    try expect(result == .token);
    try expectEqual(tag, result.token.tag);
    try expectEqualStrings(text, result.token.span.slice(lexer.source));
}

fn expectUnsupported(lexer: *Lexer, feature: diagnostic.Feature) !void {
    const result = lexer.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Code.profile_unsupported_feature, result.failure.code);
    try expectEqual(feature, result.failure.details.unsupported_feature);
}

fn expectInvalidByte(lexer: *Lexer, byte: u8) !void {
    const result = lexer.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Code.lexer_invalid_byte, result.failure.code);
    try expectEqual(byte, result.failure.details.invalid_byte);
}

test "empty input yields eof forever" {
    var lexer = Lexer.init("");
    try expectToken(&lexer, .eof, "");
    try expectToken(&lexer, .eof, "");
    try expectEqual(location.Location.start, lexer.here());
}

test "comments separate tokens without joining identifiers or operators" {
    var lexer = Lexer.init("/* header */graph// line\n{a/**/b/* /* not nested */--c;}// eof");
    try expectToken(&lexer, .keyword_graph, "graph");
    try expectToken(&lexer, .left_brace, "{");
    try expectToken(&lexer, .identifier, "a");
    try expectToken(&lexer, .identifier, "b");
    try expectToken(&lexer, .edge_undirected, "--");
    try expectToken(&lexer, .identifier, "c");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .right_brace, "}");
    try expectToken(&lexer, .eof, "");
    try expectToken(&lexer, .eof, "");

    var split_operator = Lexer.init("-/**/-");
    try expectInvalidByte(&split_operator, '-');
    var split_keyword = Lexer.init("gr/**/aph");
    try expectToken(&split_keyword, .identifier, "gr");
    try expectToken(&split_keyword, .identifier, "aph");
}

test "line comments accept EOF and all physical line endings" {
    inline for (.{ "//", "#" }) |prefix| {
        var eof = Lexer.init(prefix ++ " opaque /* \" @ \x00\xff");
        try expectToken(&eof, .eof, "");
        inline for (.{ "\n", "\r\n", "\r" }) |newline| {
            const source = prefix ++ " ignored" ++ newline ++ "x";
            var lexer = Lexer.init(source);
            const token = lexer.next().token;
            try expectEqual(Token.Tag.identifier, token.tag);
            try expectEqual(location.Location{
                .byte_offset = source.len - 1,
                .line = 2,
                .byte_column = 1,
            }, token.span.start);
        }
    }
}

test "hash comments match Graphviz token-boundary behavior without remapping lines" {
    var lexer = Lexer.init("  # 42 \"elsewhere.dot\"\na# inline\nb");
    const a = lexer.next().token;
    try expectEqualStrings("a", a.span.slice(lexer.source));
    try expectEqual(@as(usize, 2), a.span.start.line);
    const b = lexer.next().token;
    try expectEqualStrings("b", b.span.slice(lexer.source));
    try expectEqual(@as(usize, 3), b.span.start.line);
}

test "block comments preserve mixed physical positions and opaque contents" {
    const source = "/*\r\n\r\n\n# // \" \x00\xff*/x";
    var lexer = Lexer.init(source);
    const token = lexer.next().token;
    try expectEqualStrings("x", token.span.slice(source));
    try expectEqual(location.locate(source, source.len - 1), token.span.start);
    try expectEqual(@as(usize, 4), token.span.start.line);
}

test "block comment truncation reports the opener on repeated calls" {
    const body = "/* body **/";
    for (2..body.len) |end| {
        var lexer = Lexer.init(body[0..end]);
        const first = lexer.next();
        try expect(first == .failure);
        try expectEqual(diagnostic.Code.lexer_unterminated_construct, first.failure.code);
        try expectEqual(location.Location.start, first.failure.span.start);
        try expectEqual(@as(usize, 2), first.failure.span.byte_len);
        try expectEqual(diagnostic.UnterminatedConstruct.block_comment, first.failure.details.unterminated);
        try expectEqual(first, lexer.next());
        try expectEqual(first, lexer.next());
    }
    var complete = Lexer.init(body);
    try expectToken(&complete, .eof, "");
    var slash = Lexer.init("/");
    try expectInvalidByte(&slash, '/');
    var ordinary_slash = Lexer.init("/x");
    try expectInvalidByte(&ordinary_slash, '/');
}

test "unterminated comments preserve nonzero physical locations on repeated calls" {
    inline for (.{ "\n", "\r\n", "\r" }) |newline| {
        const source = "// ignored" ++ newline ++ "  /* x";
        var lexer = Lexer.init(source);
        const expected = location.locate(source, source.len - 4);
        const first = lexer.next();
        try expect(first == .failure);
        try expectEqual(expected, first.failure.span.start);
        try expectEqual(@as(usize, 2), first.failure.span.start.line);
        try expectEqual(@as(usize, 3), first.failure.span.start.byte_column);
        try expectEqual(first, lexer.next());
        try expectEqual(expected, lexer.here());
    }
}

test "each milestone token lexes on its own" {
    inline for (.{
        .{ "graph", Token.Tag.keyword_graph },
        .{ "digraph", Token.Tag.keyword_digraph },
        .{ "strict", Token.Tag.keyword_strict },
        .{ "abc", Token.Tag.identifier },
        .{ "--", Token.Tag.edge_undirected },
        .{ "->", Token.Tag.edge_directed },
        .{ "{", Token.Tag.left_brace },
        .{ "}", Token.Tag.right_brace },
        .{ ";", Token.Tag.semicolon },
    }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectToken(&lexer, case[1], case[0]);
        try expectToken(&lexer, .eof, "");
    }
}

test "keyword boundary: graphical is one identifier, not graph + ical" {
    var lexer = Lexer.init("graphical");
    try expectToken(&lexer, .identifier, "graphical");
    try expectToken(&lexer, .eof, "");

    var digraphs = Lexer.init("digraphs stricter");
    try expectToken(&digraphs, .identifier, "digraphs");
    try expectToken(&digraphs, .identifier, "stricter");
}

test "DOT keywords are case-independent" {
    var upper = Lexer.init("GRAPH");
    try expectToken(&upper, .keyword_graph, "GRAPH");

    var mixed = Lexer.init("Graph");
    try expectToken(&mixed, .keyword_graph, "Graph");

    var directed = Lexer.init("DiGraph STRICT");
    try expectToken(&directed, .keyword_digraph, "DiGraph");
    try expectToken(&directed, .keyword_strict, "STRICT");

    var deferred = Lexer.init("SubGraph Node EDGE");
    try expectToken(&deferred, .keyword_subgraph, "SubGraph");
    try expectToken(&deferred, .keyword_node, "Node");
    try expectToken(&deferred, .keyword_edge, "EDGE");
}

test "identifiers may contain underscores and digits after the first byte" {
    var lexer = Lexer.init("_a1B x9_");
    try expectToken(&lexer, .identifier, "_a1B");
    try expectToken(&lexer, .identifier, "x9_");
    try expectToken(&lexer, .eof, "");
}

test "every whitespace and newline combination separates tokens" {
    var lexer = Lexer.init("graph\t{\r\na ;\rb\n}  ");
    try expectToken(&lexer, .keyword_graph, "graph");
    try expectToken(&lexer, .left_brace, "{");

    const a = lexer.next();
    try expectEqual(Token.Tag.identifier, a.token.tag);
    try expectEqual(@as(usize, 2), a.token.span.start.line);
    try expectEqual(@as(usize, 1), a.token.span.start.byte_column);

    try expectToken(&lexer, .semicolon, ";");

    const b = lexer.next();
    try expectEqual(Token.Tag.identifier, b.token.tag);
    try expectEqual(@as(usize, 3), b.token.span.start.line);
    try expectEqual(@as(usize, 1), b.token.span.start.byte_column);

    const brace = lexer.next();
    try expectEqual(Token.Tag.right_brace, brace.token.tag);
    try expectEqual(@as(usize, 4), brace.token.span.start.line);

    try expectToken(&lexer, .eof, "");
}

test "truncated operators fail; keyword prefixes are identifiers" {
    // '-' alone, or followed by anything but '-', '>', digit, '.', is
    // invalid in any DOT document.
    var lone = Lexer.init("-");
    try expectInvalidByte(&lone, '-');

    var stray = Lexer.init("-x");
    try expectInvalidByte(&stray, '-');

    // Every proper prefix of "graph" is just a shorter identifier.
    inline for (.{ "g", "gr", "gra", "grap" }) |prefix| {
        var lexer = Lexer.init(prefix);
        try expectToken(&lexer, .identifier, prefix);
        try expectToken(&lexer, .eof, "");
    }
}

test "invalid leading bytes are reported with the byte itself" {
    inline for (.{ "@", "\x01", "\\", ")", "/x", "/" }) |source| {
        var lexer = Lexer.init(source);
        try expectInvalidByte(&lexer, source[0]);
    }
}

test "a dot without a following digit is invalid, not a numeral" {
    // DOT numerals require a digit after a leading '.'.
    inline for (.{ ".", ".x", ". " }) |source| {
        var lexer = Lexer.init(source);
        try expectInvalidByte(&lexer, '.');
    }
    // Same lookahead through a leading '-': `-.` needs a digit after '.'.
    inline for (.{ "-.", "-.x" }) |source| {
        var lexer = Lexer.init(source);
        try expectInvalidByte(&lexer, '-');
    }
}

test "non-ASCII bytes are the deferred identifier range, not invalid input" {
    // DOT unquoted identifiers may use bytes \200-\377.
    var leading = Lexer.init("\xC3\xA9");
    try expectUnsupported(&leading, .non_ascii_identifier);

    // One identifier running into the non-ASCII range is reported whole,
    // not split into an ASCII identifier plus an error — and the span
    // covers the complete run, not just the first non-ASCII byte.
    var mixed = Lexer.init("caf\xC3\xA9 x");
    const result = mixed.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Feature.non_ascii_identifier, result.failure.details.unsupported_feature);
    try expectEqual(@as(usize, 0), result.failure.span.start.byte_offset);
    try expectEqual(@as(usize, 5), result.failure.span.byte_len);

    // A leading multi-byte identifier is spanned whole as well.
    var leading_run = Lexer.init("\xC3\xA9tat;");
    const leading_result = leading_run.next();
    try expect(leading_result == .failure);
    try expectEqual(@as(usize, 5), leading_result.failure.span.byte_len);

    // Control bytes below 0x80 remain invalid, as before.
    var control = Lexer.init("\x7f");
    try expectInvalidByte(&control, 0x7f);
}

test "recognized lexical deferred features are unsupported, not invalid" {
    // Keyword-introduced deferred constructs (subgraph, node/edge attribute
    // statements) are the parser's call — the keywords tokenize above.
    inline for (.{
        .{ "<html>", diagnostic.Feature.html_identifier },
        .{ "[color=red]", diagnostic.Feature.attribute_list },
        .{ "]", diagnostic.Feature.attribute_list },
        .{ ",", diagnostic.Feature.attribute_list },
        .{ "=", diagnostic.Feature.attribute_assignment },
        .{ ":n", diagnostic.Feature.port_or_compass },
    }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectUnsupported(&lexer, case[1]);
    }
}

test "numerals are maximal textual IDs and preserve adjacent operators" {
    inline for (.{ "0", "-0", "123", "-12", ".5", "-.5", "12.", "-12.30", "000.00" }) |raw| {
        var lexer = Lexer.init(raw);
        try expectToken(&lexer, .identifier, raw);
        try expectToken(&lexer, .eof, "");
    }
    var lexer = Lexer.init("1->-2 3--4 1e3 1.2.3");
    try expectToken(&lexer, .identifier, "1");
    try expectToken(&lexer, .edge_directed, "->");
    try expectToken(&lexer, .identifier, "-2");
    try expectToken(&lexer, .identifier, "3");
    try expectToken(&lexer, .edge_undirected, "--");
    try expectToken(&lexer, .identifier, "4");
    try expectToken(&lexer, .identifier, "1");
    try expectToken(&lexer, .identifier, "e3");
    try expectToken(&lexer, .identifier, "1.2");
    try expectToken(&lexer, .identifier, ".3");
    try expectToken(&lexer, .eof, "");
    var positive = Lexer.init("+1");
    try expectInvalidByte(&positive, '+');
}

test "quoted identifiers include concatenations but exclude trailing trivia" {
    const raw = "\"gr\" /* \" */ + // \"\r\n \"aph\"";
    var lexer = Lexer.init(raw ++ " /* trailing */ -> \"b\"");
    try expectToken(&lexer, .identifier, raw);
    try expectEqual(@as(usize, raw.len), lexer.here().byte_offset);
    try expectToken(&lexer, .edge_directed, "->");
    try expectToken(&lexer, .identifier, "\"b\"");
    try expectToken(&lexer, .eof, "");
    var adjacent = Lexer.init("\"a\"\"b\"");
    try expectToken(&adjacent, .identifier, "\"a\"");
    try expectToken(&adjacent, .identifier, "\"b\"");
}

test "quoted content preserves physical positions and accepts opaque non-NUL bytes" {
    inline for (.{ "\n", "\r\n", "\r" }) |newline| {
        const raw = "\"a\\" ++ newline ++ "b" ++ newline ++ "// /* # \x01\x7f\xff\"";
        var lexer = Lexer.init(raw ++ " x");
        try expectToken(&lexer, .identifier, raw);
        const next = lexer.next().token;
        try expectEqual(location.locate(lexer.source, raw.len + 1), next.span.start);
        try expectEqual(@as(usize, 3), next.span.start.line);
    }
    inline for (.{ "\"a\x00b\"", "\"a\\\x00b\"" }) |raw| {
        var lexer = Lexer.init(raw);
        const failure = lexer.next().failure;
        try expectEqual(diagnostic.Code.lexer_invalid_byte, failure.code);
        try expectEqual(@as(u8, 0), failure.details.invalid_byte);
        try expectEqualStrings("\x00", failure.span.slice(raw));
        try expectEqual(failure, lexer.next().failure);
    }
}

test "unterminated strings report their own opener including later concatenated parts" {
    const raw = "\"a\\\"b\\\\c\"";
    for (1..raw.len) |end| {
        var lexer = Lexer.init(raw[0..end]);
        const result = lexer.next();
        try expect(result == .failure);
        try expectEqual(diagnostic.UnterminatedConstruct.quoted_identifier, result.failure.details.unterminated);
        try expectEqual(@as(usize, 0), result.failure.span.start.byte_offset);
        try expectEqual(@as(usize, 1), result.failure.span.byte_len);
        try expectEqual(result, lexer.next());
    }
    var lexer = Lexer.init("\"a\" +\r\n \"bc");
    const first = lexer.next().failure;
    try expectEqual(@as(usize, 8), first.span.start.byte_offset);
    try expectEqual(@as(usize, 2), first.span.start.line);
    try expectEqual(@as(usize, 2), first.span.start.byte_column);
    try expectEqual(first, lexer.next().failure);
}

test "malformed concatenation distinguishes expected quote from unclosed comment" {
    inline for (.{ "\"a\"+", "\"a\"+b", "\"a\"+1", "\"a\"+}", "\"a\"++\"b\"", "\"a\"+<html>" }) |raw| {
        var lexer = Lexer.init(raw);
        const first = lexer.next().failure;
        try expectEqual(diagnostic.Code.lexer_invalid_concatenation, first.code);
        try expectEqual(@as(usize, 4), first.span.start.byte_offset);
        try expectEqual(if (raw.len == 4) @as(?u8, null) else raw[4], first.details.expected_quote);
        try expectEqual(first, lexer.next().failure);
    }
    var after_plus = Lexer.init("\"a\"+/*");
    const failure = after_plus.next().failure;
    try expectEqual(diagnostic.UnterminatedConstruct.block_comment, failure.details.unterminated);
    try expectEqual(@as(usize, 4), failure.span.start.byte_offset);
    var trailing = Lexer.init("\"a\" /*");
    try expectToken(&trailing, .identifier, "\"a\"");
    try expectEqual(diagnostic.UnterminatedConstruct.block_comment, trailing.next().failure.details.unterminated);
}

test "failures are terminal and idempotent" {
    var lexer = Lexer.init("graph @ x");
    try expectToken(&lexer, .keyword_graph, "graph");

    const first = lexer.next();
    const second = lexer.next();
    try expect(first == .failure);
    try expect(second == .failure);
    try expectEqual(first.failure.code, second.failure.code);
    try expectEqual(first.failure.span.start, second.failure.span.start);
    try expectEqual(
        first.failure.details.invalid_byte,
        second.failure.details.invalid_byte,
    );
}

test "full milestone document produces the expected token stream" {
    const source = "graph {\n    a;\n    b;\n    a -- b;\n}\n";
    var lexer = Lexer.init(source);

    try expectToken(&lexer, .keyword_graph, "graph");
    try expectToken(&lexer, .left_brace, "{");
    try expectToken(&lexer, .identifier, "a");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .identifier, "b");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .identifier, "a");

    const op = lexer.next();
    try expectEqual(Token.Tag.edge_undirected, op.token.tag);
    try expectEqual(@as(usize, 4), op.token.span.start.line);
    try expectEqual(@as(usize, 7), op.token.span.start.byte_column);

    try expectToken(&lexer, .identifier, "b");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .right_brace, "}");
    try expectToken(&lexer, .eof, "");
}
