//! Vocabulary shared by both scanner implementations (`lexer_scalar.zig`,
//! `lexer_block.zig`): tokens, results, the latched terminal kinds, and the
//! byte classes and keyword table the DOT lexical grammar is built from.
//! `lexer.zig` selects the implementation and re-exports the public types.

const std = @import("std");
const location = @import("location.zig");

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
        colon,
        eof,
        left_bracket,
        right_bracket,
        equals,
        comma,
    };
};

/// The outcome of one `next` call. Failures and EOF are latched: repeated
/// calls return the same terminal result without rescanning input. A
/// failure carries no payload here — `failureDiagnostic` builds the typed
/// diagnostic on request — so the value returned on every token stays small
/// (a `Diagnostic` is several times the size of a `Token`).
pub const Result = union(enum) {
    token: Token,
    failure,
};

/// One bounded scan call: the completed result, if any, and the credits used.
pub const Advance = struct {
    result: ?Result,
    work_used: usize,
};

/// The latched terminal condition of a scanner. `none` is not terminal.
pub const Terminal = enum {
    none,
    eof,
    /// A byte that cannot start or continue any token here.
    invalid,
    /// A lone '-' that did not become an operator.
    operator,
    /// `-->` or `---`.
    operator_long,
    /// `- >` or `- -`: whitespace inside an operator.
    operator_spaced,
    /// '.' or '-.' without the required digit.
    numeral,
    /// Unterminated block comment.
    block,
    /// Unterminated quoted identifier.
    quote,
    /// '+' not followed by a quoted identifier.
    concat,
    /// A bare identifier containing non-ASCII bytes (deferred feature).
    non_ascii,
    /// An HTML-like identifier introducer (deferred feature).
    html,
    /// The source exceeds the 32-bit position domain.
    oversize,
};

pub fn isIdentifierByte(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', 0x80...0xff => true,
        else => false,
    };
}

/// Keyword classification over up to eight folded bytes (bit 5 cleared, so
/// keywords match case-independently). Longer words are never keywords.
pub fn keywordTag(word: u64, len: usize) Token.Tag {
    if (len > 8) return .identifier;
    const keywords = .{
        .{ "graph", Token.Tag.keyword_graph },   .{ "digraph", Token.Tag.keyword_digraph },
        .{ "strict", Token.Tag.keyword_strict }, .{ "subgraph", Token.Tag.keyword_subgraph },
        .{ "node", Token.Tag.keyword_node },     .{ "edge", Token.Tag.keyword_edge },
    };
    inline for (keywords) |entry| {
        const encoded = comptime blk: {
            var value: u64 = 0;
            for (entry[0]) |byte| value = (value << 8) | byte;
            break :blk value;
        };
        if (len == entry[0].len and word == encoded) return entry[1];
    }
    return .identifier;
}

/// Fold one identifier byte into the keyword word: bit 5 cleared changes
/// '_' as well, but cannot turn a non-letter into a keyword letter.
pub fn foldKeywordByte(word: u64, byte: u8) u64 {
    return (word << 8) | (byte | 0x20);
}

test "keyword table is case-independent and length-bounded" {
    var word: u64 = 0;
    for ("DiGraph") |b| word = foldKeywordByte(word, b);
    try std.testing.expectEqual(Token.Tag.keyword_digraph, keywordTag(word, 7));
    try std.testing.expectEqual(Token.Tag.identifier, keywordTag(word, 9));
}
