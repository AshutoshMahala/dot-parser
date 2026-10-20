//! Graphviz label content models. One direct-child walk per container, with
//! bounded lookahead into a font wrapper. No recursion, stack or allocation.
//! Grammar: https://graphviz.org/doc/info/shapes.html#html (Q10).
const syntax = @import("syntax.zig");
const vocabulary = @import("graphviz.zig");
const support = @import("parser_support");
const Span = support.location.Span;

pub const Problem = enum {
    expected_rows,
    expected_cells,
    misplaced_separator,
    invalid_child,
    mixed_table_text,
    wrapped_table_space,
    image_only_cell,
    empty_text,
    expected_empty,
};

pub fn message(problem: Problem) []const u8 {
    return switch (problem) {
        .expected_rows => "TABLE requires one or more TR children, with optional HR separators",
        .expected_cells => "TR requires one or more TD children, with optional VR separators",
        .misplaced_separator => "place HR between rows and VR between cells, not first, last or consecutively",
        .invalid_child => "this element is not allowed in this Graphviz content position",
        .mixed_table_text => "a table label cannot mix a table with text or another table",
        .wrapped_table_space => "remove spaces outside the font wrapper around a table",
        .image_only_cell => "IMG must be the sole content of a TD cell",
        .empty_text => "provide text or BR inside the label or text-style element",
        .expected_empty => "BR, HR, VR and IMG must not contain child content",
    };
}

pub fn Checker(comptime actual: support.encoding.Actual) type {
    const enc = support.encoding.Reader(actual);
    return struct {
        const Text = enum { ignored, spaces, visible, unknown };

        fn textKind(bytes: []const u8, decode: bool, context: anytype) ?Text {
            var kind: Text = .ignored;
            if (decode) {
                var reader: @import("graphviz_value.zig").Reader(actual) = .{ .bytes = bytes };
                while (reader.next(context)) |ch| {
                    if (ch == 0xffffffff) return .unknown;
                    if (ch == ' ') kind = .spaces else if (ch >= 32) return .visible;
                }
                return if (reader.failed) null else kind;
            }
            var i: usize = 0;
            while (i < bytes.len) : (i += enc.width) {
                if (!context.unit()) return null;
                const ch = enc.unit(bytes, i);
                if (ch == ' ') kind = .spaces else if (ch >= 32) return .visible;
            }
            return kind;
        }
        fn tag(view: syntax.NodeView) ?vocabulary.Element {
            return if (view.kind() == .element) vocabulary.elementEncoded(actual, view.name().?) else null;
        }
        fn wrapsTable(document: *const syntax.Document, view: syntax.NodeView, context: anytype) ?bool {
            const owner = tag(view) orelse return false;
            switch (owner) {
                .FONT, .I, .B, .U, .O => {},
                else => return false,
            }
            var children = view.children();
            while (children.next()) |child| {
                if (!context.step()) return null;
                switch (child.kind()) {
                    .comment => {},
                    .text, .cdata => switch (textKind(child.content().?, child.kind() == .text, context) orelse return null) {
                        .visible, .unknown => return false,
                        else => {},
                    },
                    .element => return tag(child) == .TABLE,
                }
            }
            _ = document;
            return false;
        }

        /// Context provides step(), unit(), finding(span, related, problem), gap(at).
        /// Unknown vocabulary and unfinished containers are unavailable, not
        /// invented contracts. Known independent descendants are still checked.
        pub fn check(document: *const syntax.Document, owner: ?syntax.NodeId, context: anytype) bool {
            const parent = if (owner) |id| document.node(id).? else null;
            const name: ?Span = if (parent) |p| p.record().name else null;
            const parent_tag: ?vocabulary.Element = if (parent) |p| tag(p) orelse {
                context.gap(p.record().name.start);
                return true;
            } else null;
            const complete = if (parent) |p| p.scopeComplete() else document.scopeComplete();
            var children = if (parent) |p| p.children() else document.roots();
            var seen: u32 = 0;
            var separator: ?Span = null;
            var separator_reported = false;
            var table: ?Span = null;
            var text: ?Span = null;
            var spaces: ?Span = null;
            var wrapped = false;
            var image: ?Span = null;
            var unavailable = !complete;
            while (children.next()) |child| {
                if (!context.step()) return false;
                const span = child.span();
                if (child.kind() == .comment) continue;
                const kind: ?vocabulary.Element = if (child.kind() == .element) tag(child) orelse {
                    context.gap(child.record().name.start);
                    unavailable = true;
                    continue;
                } else null;
                const text_kind: Text = if (kind == null) textKind(child.content().?, child.kind() == .text, context) orelse return false else .ignored;
                if (text_kind == .unknown) {
                    context.gap(span.start);
                    unavailable = true;
                    continue;
                }
                if (kind == null and text_kind == .ignored) continue;

                if (parent_tag == .TABLE or parent_tag == .TR) {
                    if (kind == null and text_kind == .spaces) continue;
                    const expected: vocabulary.Element = if (parent_tag == .TABLE) .TR else .TD;
                    const rule: vocabulary.Element = if (parent_tag == .TABLE) .HR else .VR;
                    if (kind == expected) {
                        seen += 1;
                        separator = null;
                    } else if (kind == rule) {
                        separator_reported = seen == 0 or separator != null;
                        if (separator_reported) {
                            if (!context.finding(span, name, .misplaced_separator)) return false;
                        }
                        separator = span;
                    } else if (!context.finding(span, name, if (parent_tag == .TABLE) .expected_rows else .expected_cells)) return false;
                    continue;
                }

                if (parent_tag == .BR or parent_tag == .HR or parent_tag == .VR or parent_tag == .IMG) {
                    if ((parent_tag == .HR or parent_tag == .VR) and kind == null and text_kind == .spaces) continue;
                    if (!context.finding(span, name, .expected_empty)) return false;
                    continue;
                }
                seen += 1;
                if (kind == .IMG) {
                    if (parent_tag != .TD or image != null or text != null or table != null or spaces != null) {
                        if (!context.finding(span, name, .image_only_cell)) return false;
                    }
                    image = span;
                    continue;
                }
                if (image != null and !context.finding(span, name, .image_only_cell)) return false;
                const is_wrapped = if (kind != null) wrapsTable(document, child, context) orelse return false else false;
                if (kind == .TABLE or is_wrapped) {
                    const accepts_table = parent_tag == null or parent_tag == .TD or
                        (!is_wrapped and (parent_tag == .FONT or parent_tag == .I or parent_tag == .B or parent_tag == .U or parent_tag == .O));
                    if (!accepts_table) {
                        if (!context.finding(span, name, .invalid_child)) return false;
                    } else if (table != null or text != null) {
                        if (!context.finding(span, name, .mixed_table_text)) return false;
                    }
                    if (is_wrapped and spaces != null and !context.finding(spaces.?, name, .wrapped_table_space)) return false;
                    table = span;
                    wrapped = is_wrapped;
                } else if (kind == .TR or kind == .TD or kind == .HR or kind == .VR) {
                    if (!context.finding(span, name, .invalid_child)) return false;
                } else if (kind == null and text_kind == .spaces) {
                    spaces = span;
                    if (wrapped and !context.finding(span, name, .wrapped_table_space)) return false;
                } else {
                    text = span;
                    if (table != null and !context.finding(span, name, .mixed_table_text)) return false;
                }
            }
            if (unavailable) {
                context.gap(if (parent) |p| p.record().name.start else document.retained_end);
                return true;
            }
            if (!separator_reported) if (separator) |span| if (!context.finding(span, name, .misplaced_separator)) return false;
            if (seen == 0) {
                const span = name orelse Span{ .start = 0, .len = 0 };
                if (parent_tag == .TABLE or parent_tag == .TR)
                    return context.finding(span, null, if (parent_tag == .TABLE) .expected_rows else .expected_cells);
                if (parent_tag == null or parent_tag == .FONT or parent_tag == .I or parent_tag == .B or parent_tag == .U or parent_tag == .O or parent_tag == .SUB or parent_tag == .SUP or parent_tag == .S)
                    return context.finding(span, null, .empty_text);
            }
            return true;
        }
    };
}
