//! Borrowed, local validation inputs. These are not tree nodes or parser instances.
//! Spans use the original source coordinates; no decoding or ownership transfer.
//! Public scope validation checks bounds/order/value framing in every build mode.
const Span = @import("parser_support").location.Span;

pub const Attribute = struct {
    name: Span,
    /// Includes both quotes, like a retained markup Attribute. A zero length
    /// means no complete value was recognized (only in an incomplete Header).
    /// Empty quoted values still have length two; no extra per-attribute tag.
    value: Span = .{ .start = 0, .len = 0 },
};
pub const Header = struct {
    span: Span,
    name: Span,
    /// Recognized attributes, in written order, including duplicates.
    attributes: []const Attribute = &.{},
    /// False for a trustworthy prefix of an unfinished/skipped header. Findings
    /// remain real, but absence of findings cannot certify the unseen remainder.
    /// Incomplete coverage starts after the first name with an unavailable value,
    /// or at span.endOffset() if all supplied attributes have complete values.
    complete: bool = true,
};
pub const Scope = union(enum) {
    opening_header: Header,
    opening_name: Span,
    closing_name: Span,
    attribute_name: Span,
    /// Content only, without quotes. Markup reference/name/UTF-8 policies apply;
    /// this does not introduce a generic string dialect or decode the bytes.
    attribute_value: Span,
    text: Span,
    /// Encoding only: useful for comments, CDATA, or an independent raw region.
    bytes: Span,

    pub fn span(self: Scope) Span {
        return switch (self) {
            .opening_header => |h| h.span,
            inline else => |s| s,
        };
    }
};
