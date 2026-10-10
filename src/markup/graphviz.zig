//! Documented Graphviz HTML-like label vocabulary, specification-first (Q10).
//! https://graphviz.org/doc/info/shapes.html#html
//! No rendering, decoding, allocation, content models or value validation.
const std = @import("std");

pub const Element = enum(u4) { TABLE, TR, TD, FONT, BR, IMG, I, B, U, O, SUB, SUP, S, HR, VR };

/// Bounded ASCII comparisons: even an arbitrarily long input name takes no
/// byte walk. Names are borrowed, never case-normalized in retained storage.
pub fn element(name: []const u8) ?Element {
    if (name.len > 5) return null;
    inline for (std.meta.fields(Element)) |field| {
        if (std.ascii.eqlIgnoreCase(name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn elementEncoded(comptime actual: @import("parser_support").encoding.Actual, name: []const u8) ?Element {
    const enc = @import("parser_support").encoding.Reader(actual);
    if (enc.width == 1) return element(name);
    if (name.len > 5 * enc.width) return null;
    inline for (std.meta.fields(Element)) |field| {
        if (enc.asciiEqual(name, field.name, true)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn allowsAttributeEncoded(comptime actual: @import("parser_support").encoding.Actual, owner: Element, name: []const u8) bool {
    const enc = @import("parser_support").encoding.Reader(actual);
    if (enc.width == 1) return allowsAttribute(owner, name);
    if (name.len % enc.width != 0 or name.len > 13 * enc.width) return false;
    // Vocabulary names are bounded ASCII; no source-wide conversion or buffer.
    var ascii: [13]u8 = undefined;
    for (0..name.len / enc.width) |i| {
        const unit = enc.unit(name, i * enc.width);
        if (unit >= 128) return false;
        ascii[i] = @intCast(unit);
    }
    return allowsAttribute(owner, ascii[0 .. name.len / enc.width]);
}

pub fn allowsAttribute(owner: Element, name: []const u8) bool {
    // Longest documented attribute is GRADIENTANGLE. No unbounded name scans.
    if (name.len > 13) return false;
    return switch (owner) {
        .TABLE => matches(name, .{ "ALIGN", "BGCOLOR", "BORDER", "CELLBORDER", "CELLPADDING", "CELLSPACING", "COLOR", "COLUMNS", "FIXEDSIZE", "GRADIENTANGLE", "HEIGHT", "HREF", "ID", "PORT", "ROWS", "SIDES", "STYLE", "TARGET", "TITLE", "TOOLTIP", "VALIGN", "WIDTH" }),
        .TD => matches(name, .{ "ALIGN", "BALIGN", "BGCOLOR", "BORDER", "CELLPADDING", "CELLSPACING", "COLOR", "COLSPAN", "FIXEDSIZE", "GRADIENTANGLE", "HEIGHT", "HREF", "ID", "PORT", "ROWSPAN", "SIDES", "STYLE", "TARGET", "TITLE", "TOOLTIP", "VALIGN", "WIDTH" }),
        .FONT => matches(name, .{ "COLOR", "FACE", "POINT-SIZE" }),
        .BR => matches(name, .{"ALIGN"}),
        .IMG => matches(name, .{ "SCALE", "SRC" }),
        .TR, .I, .B, .U, .O, .SUB, .SUP, .S, .HR, .VR => false,
    };
}

fn matches(name: []const u8, comptime names: anytype) bool {
    inline for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}
