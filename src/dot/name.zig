//! A complete, parser-recognized DOT identifier expression. This is not a
//! semantic node identity, a decoded value, or a certificate of Unicode validity.
const location = @import("parser_support").location;

/// Borrowed source coordinates, just like Span, but not interchangeable with
/// arbitrary spans or unfinished previews. Use only with the unchanged source
/// and encoding that produced it. Deliberately constructing/forging this value
/// or supplying a different source violates that contract.
pub const Name = struct {
    start: u32,
    len: u32,

    pub fn span(self: Name) location.Span {
        return .{ .start = self.start, .len = self.len };
    }
    pub fn slice(self: Name, source: []const u8) []const u8 {
        return self.span().slice(source);
    }
    pub fn endOffset(self: Name) u64 {
        return self.span().endOffset();
    }
};

/// Internal boundary: caller has already recognized a whole identifier.
/// Not exported by the public module; arbitrary spans use identifier.check.
pub fn recognized(span: location.Span) Name {
    return .{ .start = span.start, .len = span.len };
}
