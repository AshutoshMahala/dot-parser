//! A complete DOT identifier spelling, issued by parsing or identifier.check.
//! A check validates spelling, not its role in the surrounding document. Not a
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
        // Keep this guard in every build mode. It catches an out-of-bounds
        // stale handle, not same-size source mutation or a forged spelling.
        if (self.endOffset() > source.len) @panic("dot.Name lies outside this source");
        return source[self.start..][0..self.len];
    }
    pub fn endOffset(self: Name) u64 {
        return self.span().endOffset();
    }
};

/// Internal boundary: caller has already recognized a whole identifier.
/// Not exported by the public module; arbitrary spans use identifier.check.
pub inline fn recognized(span: location.Span) Name {
    // Avoid aggregate ABI conversions at speed-optimized event boundaries.
    // Size builds may share the conversion instead of expanding each use.
    return @call(if (@import("builtin").mode == .small) .auto else .always_inline, convert, .{span});
}

fn convert(span: location.Span) Name {
    return .{ .start = span.start, .len = span.len };
}
