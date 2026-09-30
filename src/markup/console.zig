//! Markup-specific wording bound to the shared, allocation-free console engine.
//! The parser never imports this module. Rendering is explicitly caller-driven.
const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const common = @import("parser_support").console;
const Diagnostic = diagnostic.Diagnostic;
const Positions = common.Positions;

pub const RenderOptions = common.RenderOptions;
const Bound = common.Renderer(Adapter);
pub const render = Bound.render;
pub const renderBoxed = Bound.renderBoxed;
pub const renderBoxedList = Bound.renderBoxedList;

pub const Adapter = struct {
    pub const Item = Diagnostic;
    pub const registry = diagnostic;
    pub const Role = enum { opener, first_attribute };
    pub const Annotations = common.Annotations(Role, 1);

    pub fn headline(d: Diagnostic, writer: anytype) !void {
        try writer.writeAll(d.code.info().summary);
    }
    pub fn hasDetails(d: Diagnostic) bool {
        return d.details != .none or switch (d.code) {
            .mismatched_tag, .unexpected_close, .unclosed_element, .duplicate_attribute, .duplicate_attribute_tolerated, .unknown_reference, .unknown_reference_tolerated => true,
            else => false,
        };
    }
    pub fn detail(d: Diagnostic, positions: *Positions, writer: anytype) !void {
        if (d.code == .mismatched_tag and try writeMismatch(d, positions, writer)) return;
        switch (d.details) {
            .none => try writer.writeAll(d.code.info().summary),
            .byte => |byte| {
                if (std.ascii.isPrint(byte)) try writer.print("offending byte 0x{X:0>2} ('{c}')", .{ byte, byte }) else try writer.print("offending byte 0x{X:0>2}", .{byte});
            },
            .expected => |expected| if (expected == .attribute_value)
                try writer.writeAll("'<' is not allowed in attribute values; write '&lt;'")
            else
                try writer.print("expected {s}", .{expectedText(expected)}),
            .feature => |feature| try writer.writeAll(switch (feature) {
                .processing_instructions => "processing instructions are not supported",
                .declarations => "declarations are not supported",
                .encoding => "UTF-16/32 input is not supported",
            }),
            .capacity => |capacity| try writer.print("{s} capacity of {d} exhausted", .{ resourceText(capacity.resource), capacity.limit }),
            .reference => |problem| try writer.writeAll(switch (problem) {
                .missing_name => "a named reference needs a name after '&'",
                .missing_digits => "a numeric reference needs digits after '&#' or '&#x'",
                .missing_semicolon => "the reference is missing its terminating ';'",
                .invalid_character => "invalid character or scalar value in a reference",
            }),
            .name => |problem| try writer.print("{s} name: {s}", .{
                @tagName(problem.context),
                switch (problem.problem) {
                    .invalid_start => "invalid initial character under the selected name rule",
                    .invalid_character => "invalid character under the selected name rule",
                    .invalid_utf8 => "invalid UTF-8 under the selected name rule",
                },
            }),
        }
    }
    pub fn hasNote(d: Diagnostic) bool {
        return d.related != null;
    }
    pub fn note(d: Diagnostic, positions: *Positions, writer: anytype) !void {
        try writer.writeAll(if (isDuplicate(d)) "first attribute with this name at " else "related opening element at ");
        try positions.writeColonForm(d.related.?.start, writer);
    }
    pub fn hint(d: Diagnostic, positions: *Positions, writer: anytype) !void {
        if (d.details == .expected) {
            switch (d.details.expected) {
                .attribute_value => try writer.writeAll("write '&lt;' for a literal '<' inside the attribute value"),
                .opening_quote => try writer.writeAll("enclose the entire attribute value in single or double quotes"),
                .closing_quote => try writer.writeAll("close the attribute value with the same quote that opened it"),
                else => try writer.print("complete the construct with {s}", .{expectedText(d.details.expected)}),
            }
        } else if (d.details == .reference and d.details.reference == .missing_semicolon) {
            try writer.writeAll("write '&amp;' for a literal '&'; otherwise use a valid reference ending in ';'");
        } else if (d.details == .reference and d.details.reference == .invalid_character) {
            try writer.writeAll("use a permitted character value, such as '&#32;' for a space");
        } else if (d.code == .unknown_reference or d.code == .unknown_reference_tolerated) {
            if (positions.slice(d.span)) |name| {
                const suggestion: ?[]const u8 = if (std.mem.eql(u8, name, "&nbsp;")) "&#160;" else if (std.mem.eql(u8, name, "&copy;")) "&#169;" else if (std.mem.eql(u8, name, "&mdash;")) "&#8212;" else null;
                if (suggestion) |replacement| {
                    try writer.print("use '{s}' instead of '{s}', or select a catalog that defines this name", .{ replacement, name });
                    return;
                }
            }
            try writer.writeAll(d.code.info().hint);
        } else try writer.writeAll(d.code.info().hint);
    }
    pub fn fix(d: Diagnostic) ?diagnostic.Fix {
        return d.suggestedFix();
    }
    pub fn annotations(d: Diagnostic) Annotations {
        var list: Annotations = .{};
        if (d.related) |span| list.add(.{ .span = span, .primary = false, .role = if (isDuplicate(d)) .first_attribute else .opener });
        return list;
    }
    pub fn primaryLabel(d: Diagnostic, positions: *Positions, writer: anytype) !void {
        switch (d.code) {
            .mismatched_tag => if (!try writeMismatch(d, positions, writer)) try writer.writeAll("expected the currently open element's name"),
            .unexpected_close => try writer.writeAll("no element is open here"),
            .unclosed_element => try writer.writeAll("expected a matching closing tag before end of input"),
            .duplicate_attribute, .duplicate_attribute_tolerated => try writer.writeAll("same name as the earlier attribute"),
            .unknown_reference, .unknown_reference_tolerated => try writer.writeAll("not in the selected reference catalog"),
            else => try detail(d, positions, writer),
        }
    }
    pub fn secondaryLabel(_: Diagnostic, role: Role, writer: anytype) !void {
        try writer.writeAll(switch (role) {
            .opener => "element opened here",
            .first_attribute => "first attribute with this name",
        });
    }
};

fn writeMismatch(d: Diagnostic, positions: *Positions, writer: anytype) !bool {
    const expected = positions.slice(d.related orelse return false) orelse return false;
    const found = positions.slice(d.span) orelse return false;
    if (expected.len == 0 or found.len == 0) return false;
    try writer.writeAll("expected '</");
    try positions.writeSource(expected, writer);
    try writer.writeAll(">', found '</");
    try positions.writeSource(found, writer);
    try writer.writeAll(">'");
    return true;
}

fn isDuplicate(d: Diagnostic) bool {
    return d.code == .duplicate_attribute or d.code == .duplicate_attribute_tolerated;
}
fn expectedText(expected: diagnostic.Expected) []const u8 {
    return switch (expected) {
        .name => "an element or attribute name",
        .tag_end => "'>' or '/>'",
        .closing_angle => "'>'",
        .equal_sign => "'=' after the attribute name",
        .opening_quote => "a quote (' or \") to open the attribute value",
        .closing_quote => "a matching closing quote",
        .attribute_separator => "whitespace before the next attribute",
        .attribute_value => "attribute content without a literal '<'",
        .declaration_start => "'<!--' or '<![CDATA['",
        .comment_start => "'<!--'",
        .comment_end => "'-->'",
        .cdata_start => "'<![CDATA['",
        .cdata_end => "']]>'",
    };
}
fn resourceText(resource: diagnostic.Resource) []const u8 {
    return switch (resource) {
        .source_bytes => "source bytes",
        .nesting_depth => "nesting depth",
        .nodes => "node count",
        .attributes => "attribute count",
        .nesting_frames => "nesting scratch",
        .node_pool => "node pool",
        .attribute_pool => "attribute pool",
        .attribute_keys => "attribute-key scratch",
    };
}
