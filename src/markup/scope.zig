//! Borrowed, local validation inputs. These are not tree nodes or parser instances.
//! Spans use the original source coordinates; no decoding or ownership transfer.
//! Public scope validation checks bounds/order/value framing in every build mode.
const Span = @import("parser_support").location.Span;
const max_source_len = @import("parser_support").location.max_source_len;
const std = @import("std");

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

/// Shared internal metadata audit. `progress` is either void for a debug-only
/// invariant check, or a statically bound cancellable public-call context.
/// It runs once per attribute; no source-content scan or allocation is added.
pub fn metadataValid(source: []const u8, scope: Scope, progress: anytype) bool {
    const range = scope.span();
    if (source.len > max_source_len or range.endOffset() > source.len) return false;
    switch (scope) {
        .opening_header => |h| {
            if (h.attributes.len > std.math.maxInt(u32) or h.name.len == 0 or
                h.name.start < range.start or h.name.endOffset() > range.endOffset()) return false;
            var previous = h.name.endOffset();
            for (h.attributes) |a| {
                if (@TypeOf(progress) != void) if (!progress.proceed()) return false;
                if (a.name.len == 0 or a.name.start < previous or a.name.endOffset() > range.endOffset() or
                    a.value.endOffset() > source.len) return false;
                if (a.value.len == 0) {
                    if (h.complete) return false;
                    previous = a.name.endOffset();
                    continue;
                }
                if (a.value.len < 2 or a.value.start < a.name.endOffset() or
                    a.value.endOffset() > range.endOffset()) return false;
                const value = a.value.slice(source); // Bounds checked before either read.
                if ((value[0] != '\'' and value[0] != '"') or value[value.len - 1] != value[0]) return false;
                previous = a.value.endOffset();
            }
        },
        .opening_name, .closing_name, .attribute_name => |name| if (name.len == 0) return false,
        else => {},
    }
    return true;
}
