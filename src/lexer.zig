//! Raw-byte lexer (milestone 1, step 3; extended by slice 2).
//!
//! Recognizes the current subset: every DOT keyword (`graph` maps to the
//! `undigraph` kind at reading time, `digraph`, `strict`, plus the deferred
//! `subgraph`/`node`/`edge`); bare ASCII identifiers; `{`, `}`, `;`; the
//! edge operators `--` and `->`; and whitespace (space, tab, LF, CRLF, CR).
//!
//! Guarantees:
//! - Spans borrow from the caller's source; no allocation ever (R-MEM-001).
//! - State is instance-owned (R-ROB-003); no OS or filesystem access.
//! - Every `next` call either consumes input or returns a terminal result
//!   (`eof` or a failure); the lexer cannot loop forever.
//! - Every keyword tokenizes, including keywords of deferred constructs:
//!   whether `subgraph` legally introduces a subgraph or sits in an illegal
//!   grammar position is the parser's decision, which the lexer cannot
//!   make. Only *lexical* deferred constructs — comments, quoted/numeral/
//!   HTML/non-ASCII identifiers, attribute punctuation, ports — are
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
        self.skipWhitespace();
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
            // Valid DOT, deferred to later slices (R-MOD-006 detectors).
            '0'...'9' => unsupported(start, 1, .numeral_identifier),
            // A leading '.' is a DOT numeral only when a digit follows
            // (grammar: `-?(.[0-9]+ | [0-9]+(.[0-9]*)?)`); a bare '.' is
            // invalid in any DOT document.
            '.' => if (self.peek(1)) |after| switch (after) {
                '0'...'9' => unsupported(start, 2, .numeral_identifier),
                else => self.invalidByte(),
            } else self.invalidByte(),
            '"' => unsupported(start, 1, .quoted_identifier),
            '<' => unsupported(start, 1, .html_identifier),
            '[', ']', ',' => unsupported(start, 1, .attribute_list),
            '=' => unsupported(start, 1, .attribute_assignment),
            ':' => unsupported(start, 1, .port_or_compass),
            '#' => unsupported(start, 1, .comment),
            '/' => if (self.peek(1)) |after| switch (after) {
                '/', '*' => unsupported(start, 2, .comment),
                else => self.invalidByte(),
            } else self.invalidByte(),
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
        const index = self.tracker.location.byte_offset + ahead;
        if (index >= self.source.len) return null;
        return self.source[index];
    }

    fn consume(self: *Lexer, count: usize) void {
        for (0..count) |_| {
            self.tracker.advance(self.source[self.tracker.location.byte_offset]);
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peek(0)) |byte| {
            switch (byte) {
                ' ', '\t', '\n', '\r' => self.consume(1),
                else => return,
            }
        }
    }

    fn single(self: *Lexer, tag: Token.Tag) Result {
        const start = self.here();
        self.consume(1);
        return .{ .token = .{ .tag = tag, .span = .{ .start = start, .byte_len = 1 } } };
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
            '0'...'9' => return unsupported(start, 2, .numeral_identifier),
            '.' => if (self.peek(2)) |third| switch (third) {
                '0'...'9' => return unsupported(start, 3, .numeral_identifier),
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
        .{ "\"quoted\"", diagnostic.Feature.quoted_identifier },
        .{ "<html>", diagnostic.Feature.html_identifier },
        .{ "[color=red]", diagnostic.Feature.attribute_list },
        .{ "]", diagnostic.Feature.attribute_list },
        .{ ",", diagnostic.Feature.attribute_list },
        .{ "=", diagnostic.Feature.attribute_assignment },
        .{ ":n", diagnostic.Feature.port_or_compass },
        .{ "# comment", diagnostic.Feature.comment },
        .{ "// comment", diagnostic.Feature.comment },
        .{ "/* comment */", diagnostic.Feature.comment },
        .{ "123", diagnostic.Feature.numeral_identifier },
        .{ ".5", diagnostic.Feature.numeral_identifier },
        .{ "-1", diagnostic.Feature.numeral_identifier },
        .{ "-.5", diagnostic.Feature.numeral_identifier },
    }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectUnsupported(&lexer, case[1]);
    }
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
