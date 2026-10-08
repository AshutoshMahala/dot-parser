//! Borrowed DOT trivia. Comments have no graph semantics or decoded value.
const location = @import("parser_support").location;

pub const Kind = enum { slash_line, block, hash_line };

pub const Comment = struct {
    kind: Kind,
    /// Includes delimiters; excludes CR/LF terminating a line comment.
    span: location.Span,

    pub fn raw(self: Comment, source: []const u8) []const u8 {
        return self.span.slice(source);
    }

    /// No trimming, newline normalization, decoding or allocation.
    pub fn body(self: Comment, source: []const u8) []const u8 {
        const bytes = self.raw(source);
        return switch (self.kind) {
            .slash_line => bytes[2..],
            .block => bytes[2 .. bytes.len - 2],
            .hash_line => bytes[1..],
        };
    }
};
