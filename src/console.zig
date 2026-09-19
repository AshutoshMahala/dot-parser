//! Out-of-the-box console rendering for diagnostics.
//!
//! This module is ONE way to present diagnostics — a default that works in a
//! terminal. It is not the diagnostic interface. The library core only
//! produces structured `diagnostic.Diagnostic` values and hands them to a
//! caller-owned `diagnostic.Sink`; it never renders, prints, or formats.
//!
//! Consumers with their own reporting — a logging framework, LSP, JSON
//! output, a GUI — implement `diagnostic.Sink` (or read a retained bag) and
//! render however they want. Nothing in the core references this module, so
//! the linker drops it entirely when it is unused.
//!
//! The boxed renderer is message-first and shows annotated source excerpts
//! when the presenter passes the source bytes:
//!
//! ```text
//! ┌─ Error 1: edge operator does not match the graph kind
//! │ example.dot:2:7
//! │
//! │ 1 │ graph {
//! │   │ ───── the document is undirected because of this keyword
//! │ 2 │     a -> b;
//! │   │       ^^ expected '--', found '->'
//! │
//! │ Hint: change '->' to '--', or declare the document with 'digraph'
//! └─ E1 ─ [dot_parser:E.Validation.Operator.002]
//! ```
//!
//! Several annotations on one line share a single row of marks; the
//! rightmost label stays inline and the others hang below it, leftmost
//! lowest, so no connector ever crosses a label:
//!
//! ```text
//! │ 1 │ digraph { a -- b}
//! │   │ ───┬───     ^^ expected '->', found '--'
//! │   │    └──── the document is directed because of this keyword
//! ```
//!
//! Without source bytes the same box degrades to compact location lines.
//! The WDP structured code closes every box (searchable identity); the
//! sequence alias and qualified compact ID (WDP part 7 §5.2) appear only
//! with `verbose = true`. Colors follow the WDP presentation guidance
//! (part 10 §3.1) and are off by default; the presenter decides whether
//! the output is a terminal — this module never probes file descriptors.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const location = @import("location.zig");

const Diagnostic = diagnostic.Diagnostic;
const Details = diagnostic.Details;
const Severity = diagnostic.Severity;

/// Options for the boxed renderers.
pub const RenderOptions = struct {
    /// Name shown in the location line ("name:line:column"). The core never
    /// learns file names (R-MOD-003), so the presenter supplies one.
    source_name: []const u8 = "<input>",
    /// The source bytes the diagnostics' spans index. When present, boxes
    /// show annotated source excerpts; when null (or when a span does not
    /// fit the given bytes), boxes fall back to compact location lines.
    source: ?[]const u8 = null,
    /// Visual style. `.unicode` draws a box; `.ascii` is plain 7-bit output
    /// for terminals and logs that cannot render box-drawing characters.
    style: Style = .unicode,
    /// ANSI severity colors per WDP part 10 §3.1. Off by default: the
    /// presenter performs its own TTY detection and opts in.
    color: Color = .none,
    /// Also show the sequence alias and the fully qualified compact ID
    /// (`namespace_hash-code_hash`) in the closing line.
    verbose: bool = false,
    /// Number of fill characters in the summary block's closing rule.
    rule_width: usize = 54,

    pub const Style = enum { unicode, ascii };
    pub const Color = enum { none, ansi };
};

/// Render one diagnostic as compact log-style text, e.g.:
///
/// ```text
/// error[dot_parser:E.Validation.Operator.002]: edge operator does not match the graph kind
///   --> line 2, byte column 7 (offset 13, len 2)
///   detail: expected '--', found '->'
///   note: graph kind declared at 1:1
///   help: an undirected document ('graph') connects nodes with '--'; ...
/// ```
///
/// Columns are byte columns (a tab counts one; multi-byte characters count
/// per byte), which is what the location line says so editors expecting
/// character columns are not misled.
///
/// `writer` is anything with `print`, e.g. a `*std.Io.Writer`.
pub fn render(d: Diagnostic, writer: anytype) !void {
    const info = d.code.info();
    const loc = d.span.start;
    try writer.print("{s}[{s}:{s}]: ", .{
        severityWord(info.severity), diagnostic.namespace, d.code.structured(),
    });
    try writeHeadline(d, info, writer);
    try writer.writeAll("\n");
    try writer.print("  --> line {d}, byte column {d} (offset {d}, len {d})\n", .{
        loc.line, loc.byte_column, loc.byte_offset, d.span.byte_len,
    });
    if (d.details != .none) {
        try writer.writeAll("  detail: ");
        try writeDetailValue(d.details, writer);
        try writer.writeAll("\n");
    }
    if (hasNote(d.details)) {
        try writer.writeAll("  note: ");
        try writeNoteValue(d.details, writer);
        try writer.writeAll("\n");
    }
    try writer.writeAll("  help: ");
    try writeHint(d, info, writer);
    try writer.writeAll("\n");
    if (d.fix) |fix| {
        try writer.writeAll("  fix: ");
        try writeFix(fix, null, writer);
        try writer.writeAll("\n");
    }
}

/// Render one diagnostic as a numbered box: message-first header, location,
/// an annotated source excerpt (when `options.source` is set), a hint, and
/// a labeled closing line carrying the WDP structured code.
pub fn renderBoxed(
    d: Diagnostic,
    number: usize,
    options: RenderOptions,
    writer: anytype,
) !void {
    const info = d.code.info();
    const g = Glyphs.of(options.style);
    const pal = Palette.of(options.color, info.severity);

    // Header: the human-readable message is the first thing the eye lands
    // on; protocol identity waits at the closing line.
    try writer.print("{s}{s} {s} {d}:{s} ", .{
        pal.frame, g.open, severityTitle(info.severity), number, pal.reset,
    });
    try writeHeadline(d, info, writer);
    try writer.writeAll("\n");

    try writeRail(g, pal, writer);
    try writer.print("{s}:{d}:{d}\n", .{
        options.source_name, d.span.start.line, d.span.start.byte_column,
    });

    if (excerptSource(d, options)) |source| {
        try writeBlankRail(g, pal, writer);
        try writeExcerpt(d, source, g, pal, writer);
        try writeBlankRail(g, pal, writer);
    } else {
        // Compact fallback: the typed payload and the related location as
        // unlabeled lines — the header already says what kind of line each
        // one is.
        if (d.details != .none) {
            try writeRail(g, pal, writer);
            try writeDetailValue(d.details, writer);
            try writer.writeAll("\n");
        }
        if (hasNote(d.details)) {
            try writeRail(g, pal, writer);
            try writeNoteValue(d.details, writer);
            try writer.writeAll("\n");
        }
    }

    try writeRail(g, pal, writer);
    try writer.print("{s}Hint:{s} ", .{ pal.hint, pal.reset });
    try writeHint(d, info, writer);
    try writer.writeAll("\n");
    if (d.fix) |fix| {
        try writeRail(g, pal, writer);
        try writer.print("{s}Fix:{s} ", .{ pal.hint, pal.reset });
        try writeFix(fix, options.source, writer);
        try writer.writeAll("\n");
    }

    // Closing line: the box's number tag pairs the closer with its opener
    // (boxes grow tall with excerpts), followed by the searchable identity.
    try writer.print("{s}{s} {c}{d} {s}{s} [{s}:{s}", .{
        pal.frame, g.close,   info.severity.letter(), number,
        g.tick,    pal.reset, diagnostic.namespace,   d.code.structured(),
    });
    if (options.verbose) {
        const qualified_id = d.code.qualifiedCompactId();
        try writer.print(" ({s})] -> {s}\n", .{ info.alias, &qualified_id });
    } else {
        try writer.writeAll("]\n");
    }
}

/// Render a list of diagnostics as numbered boxes. When the list holds more
/// than one diagnostic — or when a `FixedBag` overflowed (`omitted` > 0) —
/// a summary block follows; a single complete diagnostic speaks for itself.
pub fn renderBoxedList(
    diagnostics: []const Diagnostic,
    omitted: usize,
    options: RenderOptions,
    writer: anytype,
) !void {
    var errors: usize = 0;
    var warnings: usize = 0;
    var worst: Severity = .trace;
    for (diagnostics, 0..) |d, index| {
        if (index != 0) try writer.writeAll("\n");
        try renderBoxed(d, index + 1, options, writer);
        const severity = d.code.severity();
        if (@intFromEnum(severity) > @intFromEnum(worst)) worst = severity;
        switch (severity) {
            .err, .blocked, .critical => errors += 1,
            .warning => warnings += 1,
            else => {},
        }
    }

    if (diagnostics.len <= 1 and omitted == 0) return;
    if (diagnostics.len != 0) try writer.writeAll("\n");

    const g = Glyphs.of(options.style);
    const pal = Palette.of(options.color, worst);
    try writer.print("{s}{s} Summary{s}\n", .{ pal.frame, g.summary_open, pal.reset });
    try writer.print("{s}{s}{s} ", .{ pal.frame, g.summary_rail, pal.reset });
    if (errors == 0 and warnings == 0) {
        try writer.print("{d} diagnostic{s}", .{ diagnostics.len, plural(diagnostics.len) });
    } else {
        if (errors > 0) try writer.print("{d} error{s}", .{ errors, plural(errors) });
        if (warnings > 0) {
            if (errors > 0) try writer.writeAll(", ");
            try writer.print("{d} warning{s}", .{ warnings, plural(warnings) });
        }
    }
    if (omitted > 0) {
        try writer.print(" ({d} more omitted: diagnostic bag is full)", .{omitted});
    }
    try writer.writeAll("\n");
    try writer.print("{s}{s}", .{ pal.frame, g.summary_close });
    try writeRepeat(writer, g.summary_fill, options.rule_width);
    try writer.print("{s}\n", .{pal.reset});
}

// ---------------------------------------------------------------------------
// Box building blocks
// ---------------------------------------------------------------------------

/// Frame characters for the two visual styles. ASCII output has no rail —
/// content is indented instead — so its "rail" is plain spaces.
const Glyphs = struct {
    open: []const u8,
    rail: []const u8,
    close: []const u8,
    tick: []const u8,
    gutter: []const u8,
    secondary_underline: []const u8,
    /// Junction in a mark row where a hanging label's connector starts.
    tee: []const u8,
    /// Connector continuation on the rows between marks and label.
    vertical: []const u8,
    /// Turn from the connector into the hanging label.
    corner: []const u8,
    /// The short run between the corner and the label text.
    hang: []const u8,
    gap: []const u8,
    clip: []const u8,
    /// Display width of `clip`, for underline alignment.
    clip_width: usize,
    summary_open: []const u8,
    summary_rail: []const u8,
    summary_close: []const u8,
    summary_fill: []const u8,

    fn of(style: RenderOptions.Style) Glyphs {
        return switch (style) {
            .unicode => .{
                .open = "┌─",
                .rail = "│",
                .close = "└─",
                .tick = "─",
                .gutter = "│",
                .secondary_underline = "─",
                .tee = "┬",
                .vertical = "│",
                .corner = "└",
                .hang = "────",
                .gap = "⋯",
                .clip = "…",
                .clip_width = 1,
                .summary_open = "╔═",
                .summary_rail = "║",
                .summary_close = "╚",
                .summary_fill = "═",
            },
            .ascii => .{
                .open = "--",
                .rail = "  ",
                .close = "--",
                .tick = "-",
                .gutter = "|",
                .secondary_underline = "-",
                .tee = "+",
                .vertical = "|",
                .corner = "`",
                .hang = "----",
                .gap = "...",
                .clip = "...",
                .clip_width = 3,
                .summary_open = "==",
                .summary_rail = "  ",
                .summary_close = "=",
                .summary_fill = "=",
            },
        };
    }
};

/// ANSI escape prefixes per element, empty when color is off. The severity
/// colors are the WDP presentation palette (part 10 §3.1); secondary
/// annotations use the Info color and the hint label uses the Help color.
const Palette = struct {
    frame: []const u8 = "",
    secondary: []const u8 = "",
    hint: []const u8 = "",
    reset: []const u8 = "",

    fn of(color: RenderOptions.Color, severity: Severity) Palette {
        return switch (color) {
            .none => .{},
            .ansi => .{
                .frame = severityAnsi(severity),
                .secondary = severityAnsi(.info),
                .hint = severityAnsi(.help),
                .reset = "\x1b[0m",
            },
        };
    }
};

/// WDP part 10 §3.1 terminal colors, verbatim.
fn severityAnsi(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "\x1b[1;31m",
        .blocked => "\x1b[31m",
        .critical => "\x1b[1;33m",
        .warning => "\x1b[33m",
        .help => "\x1b[32m",
        .success => "\x1b[1;32m",
        .completed => "\x1b[32m",
        .info => "\x1b[36m",
        .trace => "\x1b[2;34m",
    };
}

fn writeRail(g: Glyphs, pal: Palette, writer: anytype) !void {
    try writer.print("{s}{s}{s} ", .{ pal.frame, g.rail, pal.reset });
}

fn writeBlankRail(g: Glyphs, pal: Palette, writer: anytype) !void {
    try writer.print("{s}{s}{s}\n", .{ pal.frame, std.mem.trimEnd(u8, g.rail, " "), pal.reset });
}

fn writeRepeat(writer: anytype, glyph: []const u8, count: usize) !void {
    for (0..count) |_| try writer.writeAll(glyph);
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

/// The message shown in the header. Wording lives here, in the renderer;
/// most codes use their registry summary, a few are sharpened by the typed
/// payload.
fn writeHeadline(d: Diagnostic, info: diagnostic.Code.Info, writer: anytype) !void {
    switch (d.details) {
        .unterminated => |construct| {
            try writer.print("input ended inside a {s}", .{unterminatedName(construct)});
        },
        .unsupported_feature => |feature| {
            try writer.print("unsupported DOT construct: {s}", .{feature.name()});
        },
        .invalid_byte => |byte| {
            if (byte == 0) try writer.writeAll("NUL byte in the input") else try writer.writeAll(info.summary);
        },
        .invalid_operator => |operator| switch (operator.shape) {
            .lone => try writer.writeAll("'-' is not an edge operator"),
            .long => try writer.print("'{s}' is not an edge operator", .{if (operator.found == '>') "-->" else "---"}),
            .spaced => try writer.writeAll("whitespace inside an edge operator"),
        },
        .incomplete_numeral => {
            try writer.print("'{s}' must be followed by a digit", .{if (d.span.byte_len == 2) "-." else "."});
        },
        .reserved_keyword => |reserved| switch (reserved.context) {
            .attribute_list => try writer.print("keyword '{s}' is not followed by its attribute list", .{reserved.keyword.lexeme()}),
            else => try writer.print("reserved keyword '{s}' used as a name", .{reserved.keyword.lexeme()}),
        },
        else => try writer.writeAll(info.summary),
    }
}

/// The repair, as an instruction. With the source, the marked text is
/// quoted (when short and printable) so the line reads on its own.
fn writeFix(fix: diagnostic.Fix, source: ?[]const u8, writer: anytype) !void {
    const marked = markedText(fix.span, source);
    switch (fix.edit) {
        .delete => if (marked) |text| {
            try writer.print("delete '{s}'", .{text});
        } else {
            try writer.writeAll("delete the marked text");
        },
        .replace => |replacement| if (marked) |text| {
            try writer.print("replace '{s}' with '{s}'", .{ text, replacement.text() });
        } else {
            try writer.print("replace the marked text with '{s}'", .{replacement.text()});
        },
        .insert_before => |replacement| if (fix.span.byte_len == 0) {
            // A position rather than text: usually end of input.
            if (source != null and fix.span.start.byte_offset == source.?.len) {
                try writer.print("insert '{s}' at end of input", .{replacement.text()});
            } else {
                try writer.print("insert '{s}' at line {d}, byte column {d}", .{ replacement.text(), fix.span.start.line, fix.span.start.byte_column });
            }
        } else if (marked) |text| {
            try writer.print("insert '{s}' before '{s}'", .{ replacement.text(), text });
        } else {
            try writer.print("insert '{s}' before the marked text", .{replacement.text()});
        },
        .insert_after => |replacement| if (marked) |text| {
            try writer.print("insert '{s}' after '{s}'", .{ replacement.text(), text });
        } else {
            try writer.print("insert '{s}' after the marked text", .{replacement.text()});
        },
        .wrap_in_quotes => if (marked) |text| {
            try writer.print("write it as \"{s}\"", .{text});
        } else {
            try writer.writeAll("put the marked text in double quotes");
        },
    }
    switch (fix.applicability) {
        .machine_applicable => {},
        .maybe => try writer.writeAll(" (one possible repair)"),
    }
}

/// The span's text when it is short and printable, for quoting in a fix.
fn markedText(span: location.Span, source: ?[]const u8) ?[]const u8 {
    const bytes = source orelse return null;
    if (span.byte_len == 0 or span.byte_len > 24 or !spanFits(span, bytes)) return null;
    const text = span.slice(bytes);
    for (text) |byte| {
        if (!std.ascii.isPrint(byte)) return null;
    }
    return text;
}

/// The hint line: what to do about it, derived from the typed payload
/// (the grammar context, the token found, the related opener, the byte,
/// the attached fix). The registry's static hint is the fallback that
/// keeps every code covered.
fn writeHint(d: Diagnostic, info: diagnostic.Code.Info, writer: anytype) !void {
    switch (d.details) {
        .unterminated => |construct| switch (construct) {
            .block_comment => try writer.writeAll("close the block comment opened here with '*/'; block comments do not nest"),
            .quoted_identifier => try writer.writeAll("close the quoted identifier opened here with a double quote"),
        },
        .operator_mismatch => |mismatch| switch (mismatch.expected) {
            .directed => try writer.writeAll(
                "change '--' to '->', or declare the document with 'graph'",
            ),
            .undirected => try writer.writeAll(
                "change '->' to '--', or declare the document with 'digraph'",
            ),
        },
        .invalid_byte => |byte| switch (byte) {
            0 => try writer.writeAll("NUL is not allowed anywhere in DOT input, not even inside quotes; remove it"),
            '>' => try writer.writeAll("'>' is only valid as the second character of '->'; write '->' for a directed edge or '--' for an undirected one"),
            '+' => try writer.writeAll("'+' only joins two double-quoted identifiers, and numerals take no leading '+'"),
            '|', '&', '!', '?', '@', '$', '%', '^', '*', '(', ')', '~', '`', '\'' => try writer.print(
                "'{c}' cannot appear outside a quoted identifier; put the text in double quotes, or remove the character",
                .{byte},
            ),
            else => try writer.writeAll(info.hint),
        },
        .invalid_operator => |operator| switch (operator.shape) {
            .long => try writer.print("write '{s}'; an edge operator is exactly two characters", .{if (operator.found == '>') "->" else "--"}),
            .spaced => try writer.print("write '{s}' as two adjacent characters; no whitespace is allowed inside an edge operator", .{if (operator.found == '>') "->" else "--"}),
            .lone => if (operator.found == null) {
                try writer.writeAll("the input ends after '-'; complete the operator as '--' or '->'");
            } else {
                try writer.writeAll("a single '-' is not an operator; write '--' for an undirected edge or '->' for a directed edge");
            },
        },
        .incomplete_numeral => |found| {
            if (found == null) {
                try writer.writeAll("the input ends after the dot; write a digit after it (for example '.5'), or quote the text to use it as a name");
            } else {
                try writer.writeAll(info.hint);
            }
        },
        .ambiguous_numeral => |byte| {
            if (byte == '.') {
                try writer.writeAll("a DOT numeral has at most one dot, so Graphviz reads this as two numerals; quote the text to keep it whole");
            } else {
                try writer.writeAll("Graphviz reads this as a numeral followed by a separate identifier; quote the text to keep one name, or add whitespace to make the split explicit");
            }
        },
        .reserved_keyword => |reserved| {
            const word = reserved.keyword.lexeme();
            switch (reserved.context) {
                .attribute_list => try writer.print(
                    "'{s}' starts an attribute statement, which needs a '[...]' list ('{s} [shape=box]'); to use it as a name instead, write \"{s}\" in double quotes",
                    .{ word, word, word },
                ),
                else => try writer.print(
                    "'{s}' is a reserved keyword and cannot be a name; write \"{s}\" in double quotes to use it as an identifier",
                    .{ word, word },
                ),
            }
        },
        .unexpected => |unexpected| try writeUnexpectedHint(d, unexpected, info, writer),
        else => try writer.writeAll(info.hint),
    }
}

/// The grammar rule the input broke, chosen from the parse context and the
/// token found. An expected-token set says what would have been legal; this
/// says why the user's text was not.
fn writeUnexpectedHint(
    d: Diagnostic,
    unexpected: diagnostic.Unexpected,
    info: diagnostic.Code.Info,
    writer: anytype,
) !void {
    const found = unexpected.found;
    const expected = unexpected.expected;
    const at_end = found == .end_of_input;
    switch (unexpected.context) {
        .document_header => {
            if (expected.contains(.digraph_keyword)) {
                // Before the kind keyword: nothing, 'strict', or a typo.
                if (at_end) {
                    try writer.writeAll("the input holds no graph; a DOT file starts with 'graph' or 'digraph', optionally preceded by 'strict'");
                } else if (found == .subgraph_keyword) {
                    try writer.writeAll("a subgraph cannot be the root of a document; start the file with 'graph' or 'digraph' (subgraphs go inside the body)");
                } else if (found == .identifier) {
                    if (d.fix) |fix| {
                        if (fix.edit == .replace) {
                            try writer.print("did you mean '{s}'? a DOT file starts with 'graph' or 'digraph'", .{fix.edit.replace.text()});
                            return;
                        }
                    }
                    try writer.writeAll("a DOT file starts with 'graph' or 'digraph' (optionally preceded by 'strict'), not with a name");
                } else {
                    try writer.writeAll("a DOT file starts with 'graph' or 'digraph', optionally preceded by 'strict'");
                }
            } else if (found == .strict_keyword) {
                try writer.writeAll("'strict' comes before the kind keyword: write 'strict graph' or 'strict digraph'");
            } else if (expected.contains(.identifier)) {
                // After the kind keyword: an optional name, then '{'.
                if (at_end) {
                    try writer.writeAll("the graph body is missing; add '{ ... }' after the header");
                } else {
                    try writer.writeAll("the header is '<kind> [name] {'; give the graph a name or open its body with '{'");
                }
            } else if (found == .identifier) {
                try writer.writeAll("the graph body must open with '{' after the name; a graph has at most one name");
            } else if (at_end) {
                try writer.writeAll("the graph body is missing; add '{ ... }' after the name");
            } else {
                try writer.writeAll("the graph body must open with '{' directly after the name");
            }
        },
        .subgraph_header => {
            if (found == .identifier) {
                try writer.writeAll("the subgraph body must open with '{' after the name; a subgraph has at most one name");
            } else if (at_end) {
                try writer.writeAll("the subgraph body is missing; add '{ ... }' after the header");
            } else {
                try writer.writeAll("a subgraph is written 'subgraph [name] { ... }'");
            }
        },
        .document_body => switch (found) {
            .semicolon => try writer.writeAll("a ';' may only end a statement; remove the stray ';'"),
            .left_bracket => try writer.writeAll("an attribute list must follow a node, an edge, or the 'graph'/'node'/'edge' keyword; nothing here owns this one"),
            .right_bracket => try writer.writeAll("there is no open attribute list for this ']'"),
            .equals => try writer.writeAll("an assignment is 'name = value'; the name before '=' is missing"),
            .undirected_operator, .directed_operator => try writer.writeAll("an edge needs a left endpoint before the operator: a node name, a subgraph, or '{ ... }'"),
            .colon => try writer.writeAll("a port suffix must follow a node name"),
            .comma => try writer.writeAll("',' only separates attributes inside '[...]'; statements are separated by ';' or a newline"),
            .end_of_input => try writeUnclosedScopeHint(unexpected, writer),
            else => try writer.writeAll(info.hint),
        },
        .subgraph_suffix => switch (found) {
            .colon => try writer.writeAll("a port suffix attaches to a node name only, never to a subgraph"),
            .left_bracket => try writer.writeAll("a standalone subgraph takes no attribute list; put attributes inside its braces, or on the edge statement that uses it"),
            else => try writer.writeAll(info.hint),
        },
        .statement => switch (found) {
            .comma => try writer.writeAll("',' does not separate statements; use ';' or a newline"),
            .colon => try writer.writeAll("a node reference has at most two port components: 'name:port' or 'name:port:compass'"),
            .equals => try writer.writeAll("an assignment key cannot carry a port suffix; write 'name = value'"),
            .right_bracket => try writer.writeAll("there is no open attribute list for this ']'"),
            .end_of_input => try writeUnclosedScopeHint(unexpected, writer),
            else => try writer.writeAll("after a node name, write ';', an edge operator, an attribute list '[...]', or the next statement"),
        },
        .statement_terminator => switch (found) {
            .undirected_operator, .directed_operator => try writer.writeAll("an attribute list ends the statement; write the whole chain first, then its attributes: 'a -> b -> c [x=1]'"),
            .colon => try writer.writeAll("a port suffix attaches directly to a node name, with at most two components ('name:port:compass')"),
            .comma => try writer.writeAll("',' does not separate statements; use ';' or a newline"),
            .equals => try writer.writeAll("an edge statement cannot be assigned to; give it attributes in '[...]' instead"),
            .right_bracket => try writer.writeAll("there is no open attribute list for this ']'"),
            .end_of_input => try writeUnclosedScopeHint(unexpected, writer),
            else => try writer.writeAll("after an edge, write ';', another operator to extend the chain, an attribute list '[...]', or the next statement"),
        },
        .edge_endpoint => switch (found) {
            .undirected_operator, .directed_operator => try writer.writeAll("two edge operators in a row; remove one"),
            .left_bracket => try writer.writeAll("attributes come after the last endpoint: 'a -> b [x=1]', not 'a -> [x=1]'"),
            .end_of_input => try writer.writeAll("the input ends after an edge operator; add the right endpoint (a node name, a subgraph, or '{ ... }')"),
            else => try writer.writeAll("an edge operator must be followed by an endpoint: a node name, a subgraph, or '{ ... }'"),
        },
        .port_component => switch (found) {
            .colon => try writer.writeAll("'::' has no port name; write 'name:port' or 'name:port:compass'"),
            .end_of_input => try writer.writeAll("the input ends after ':'; add the port name or compass point"),
            else => try writer.writeAll("':' must be followed by a port name or a compass point (n, ne, e, se, s, sw, w, nw, c, _)"),
        },
        .document_epilogue => switch (found) {
            .graph_keyword, .digraph_keyword, .strict_keyword => try writer.writeAll("this parser reads exactly one graph per parse; split the input and parse the second graph separately"),
            .right_brace => try writer.writeAll("this '}' has no matching '{'; the document was already closed"),
            else => try writer.writeAll("nothing may follow the closing '}' of the graph except whitespace and comments"),
        },
        .attribute_list => switch (found) {
            .equals => try writer.writeAll("an attribute is 'key=value'; the key before this '=' is missing"),
            .end_of_input => try writer.writeAll("the attribute list is not closed; add ']'"),
            else => if (outsideList(found))
                try writer.writeAll("the attribute list is not closed; add ']' before this token")
            else
                try writer.writeAll("inside '[...]', write 'key=value' pairs separated by ',' or ';', then close the list with ']'"),
        },
        .attribute_key => switch (found) {
            .comma, .semicolon => try writer.writeAll("attributes are separated by a single ',' or ';'; remove the extra separator"),
            .equals => try writer.writeAll("an attribute is 'key=value'; the key before this '=' is missing"),
            .identifier => try writer.writeAll("an attribute is 'key=value'; the '=' between the key and the value is missing"),
            .right_bracket => try writer.writeAll("an attribute is 'key=value'; the '=' and the value are missing after the key"),
            .end_of_input => try writer.writeAll("the attribute list is not closed; add ']'"),
            else => if (outsideList(found))
                try writer.writeAll("the attribute list is not closed; add ']' before this token")
            else
                try writer.writeAll("inside '[...]', write 'key=value' pairs separated by ',' or ';', then close the list with ']'"),
        },
        .attribute_value => switch (found) {
            .right_bracket, .comma, .semicolon, .end_of_input => try writer.writeAll("an attribute is 'key=value'; the value after '=' is missing"),
            else => if (outsideList(found))
                try writer.writeAll("the attribute list is not closed, and the value after '=' is missing; add the value and ']'")
            else
                try writer.writeAll("the value after '=' must be an identifier: bare, numeral, or double-quoted"),
        },
        .assignment_value => switch (found) {
            .semicolon, .right_brace, .end_of_input => try writer.writeAll("an assignment is 'name = value'; the value after '=' is missing"),
            else => try writer.writeAll("the value after '=' must be an identifier: bare, numeral, or double-quoted"),
        },
    }
}

/// True for a token that can never appear inside an attribute list: when
/// one shows up there, the list was left open.
fn outsideList(found: diagnostic.SyntaxItem) bool {
    return switch (found) {
        .identifier, .comma, .semicolon, .equals, .right_bracket, .end_of_input => false,
        else => true,
    };
}

/// End of input inside a scope: name the fix, and point at the suspect
/// brace when the indentation heuristic found one.
fn writeUnclosedScopeHint(unexpected: diagnostic.Unexpected, writer: anytype) !void {
    try writer.writeAll("the input ends inside this scope; add the missing '}'");
    if (unexpected.suspect) |suspect| {
        try writer.print("; the '}}' at {d}:{d} is indented like an outer scope, so the missing brace probably belongs above it", .{
            suspect.span.start.line, suspect.span.start.byte_column,
        });
    }
}

// ---------------------------------------------------------------------------
// Source excerpts
// ---------------------------------------------------------------------------

/// Maximum source bytes per excerpt; escaped bytes can expand to four display
/// cells. Longer lines are windowed with clip markers, so even a multi-megabyte
/// source line has bounded output. Tabs retain their existing presentation.
const max_view = 60;

/// Returns the source to excerpt from, or null when the box must fall back
/// to compact lines: no source given, or a span that does not fit it (a
/// mismatched source must degrade, never crash the renderer).
fn excerptSource(d: Diagnostic, options: RenderOptions) ?[]const u8 {
    const source = options.source orelse return null;
    if (!spanFits(d.span, source)) return null;
    for (secondaryAnnotations(d.details).slice()) |annotation| {
        if (!spanFits(annotation.span, source)) return null;
    }
    return source;
}

fn spanFits(span: location.Span, source: []const u8) bool {
    return span.start.byte_offset <= source.len and
        span.byte_len <= source.len - span.start.byte_offset;
}

const Annotation = struct {
    span: location.Span,
    primary: bool,
    /// The typed relation for a secondary annotation; null for the primary.
    role: ?diagnostic.Related.Role = null,
};

/// At most two secondary locations per payload today (the related opener
/// and the suspect brace); the excerpt renderer sorts them with the primary.
const max_secondary = 2;
const SecondaryList = struct {
    items: [max_secondary]Annotation = undefined,
    len: usize = 0,

    fn add(self: *SecondaryList, annotation: Annotation) void {
        self.items[self.len] = annotation;
        self.len += 1;
    }
    fn slice(self: *const SecondaryList) []const Annotation {
        return self.items[0..self.len];
    }
};

/// The secondary annotated locations the payload carries.
fn secondaryAnnotations(details: Details) SecondaryList {
    var list: SecondaryList = .{};
    switch (details) {
        .operator_mismatch => |mismatch| list.add(.{ .span = mismatch.declaration, .primary = false, .role = .declared_here }),
        .unexpected => |unexpected| {
            if (unexpected.related) |related| list.add(.{ .span = related.span, .primary = false, .role = related.role });
            if (unexpected.suspect) |suspect| list.add(.{ .span = suspect.span, .primary = false, .role = suspect.role });
        },
        else => {},
    }
    return list;
}

const View = struct {
    line_start: usize,
    start: usize,
    end: usize,
    clipped_left: bool,
    clipped_right: bool,
};

/// Write the annotated excerpt windows: each annotated line once, one
/// underline row per annotation, a gap marker between non-adjacent lines.
fn writeExcerpt(
    d: Diagnostic,
    source: []const u8,
    g: Glyphs,
    pal: Palette,
    writer: anytype,
) !void {
    var annotations: [max_secondary + 1]Annotation = undefined;
    var count: usize = 0;
    for (secondaryAnnotations(d.details).slice()) |annotation| {
        annotations[count] = annotation;
        count += 1;
    }
    annotations[count] = .{ .span = d.span, .primary = true };
    count += 1;
    // Source order, so the excerpt reads top to bottom.
    std.mem.sort(Annotation, annotations[0..count], {}, struct {
        fn lessThan(_: void, a: Annotation, b: Annotation) bool {
            return a.span.start.byte_offset < b.span.start.byte_offset;
        }
    }.lessThan);

    var gutter_width: usize = 0;
    for (annotations[0..count]) |annotation| {
        gutter_width = @max(gutter_width, digits(annotation.span.start.line));
    }

    var previous_line: usize = 0;
    var index: usize = 0;
    while (index < count) {
        const line = annotations[index].span.start.line;
        var group_end = index + 1;
        while (group_end < count and annotations[group_end].span.start.line == line) group_end += 1;

        if (previous_line != 0 and line > previous_line + 1) {
            try writeRail(g, pal, writer);
            try writer.print("{s}\n", .{g.gap});
        }
        const view = viewFor(source, annotations[index].span.start.byte_offset);
        try writeRail(g, pal, writer);
        try writeUnsigned(writer, line, gutter_width);
        try writer.print(" {s} ", .{g.gutter});
        if (view.clipped_left) try writer.writeAll(g.clip);
        for (source[view.start..view.end]) |byte| {
            if (byte == '\t' or std.ascii.isPrint(byte)) {
                try writer.writeAll(&.{byte});
            } else {
                try writer.print("\\x{X:0>2}", .{byte});
            }
        }
        if (view.clipped_right) try writer.writeAll(g.clip);
        try writer.writeAll("\n");
        previous_line = line;

        // One annotation, or spans that would draw on top of each other:
        // one underline row each. Otherwise a single mark row with the
        // labels hanging below it.
        const group = annotations[index..group_end];
        var placed: [max_secondary + 1]Placed = undefined;
        for (group, 0..) |annotation, i| placed[i] = place(annotation, view);
        if (group.len == 1 or overlapping(placed[0..group.len])) {
            for (group) |annotation| try writeUnderline(d, annotation, view, source, gutter_width, g, pal, writer);
        } else {
            try writeHangingLabels(d, placed[0..group.len], view, source, gutter_width, g, pal, writer);
        }
        index = group_end;
    }
}

/// One annotation's drawn extent within the view, in byte offsets.
const Placed = struct {
    annotation: Annotation,
    /// First byte under the marks, clamped into the view.
    start: usize,
    /// One past the last byte under the marks. Equal to `start` for a mark
    /// that stands for a position rather than bytes (a zero-width span such
    /// as end of input, or a span clipped out of the window).
    end: usize,
    /// The byte whose cell carries the T junction and the connector below.
    connector: usize,

    fn positional(self: Placed) bool {
        return self.end == self.start;
    }
};

fn place(annotation: Annotation, view: View) Placed {
    const offset: usize = annotation.span.start.byte_offset;
    const start = @min(offset, view.end);
    const len = if (offset < view.end) @min(annotation.span.byte_len, view.end - offset) else 0;
    if (len == 0) return .{ .annotation = annotation, .start = start, .end = start, .connector = start };
    // The middle cell, so the connector reads as belonging to the whole
    // span; a one-byte span puts it under that byte.
    return .{ .annotation = annotation, .start = start, .end = start + len, .connector = start + (len - 1) / 2 };
}

/// True when two marks would share a cell (sorted by start).
fn overlapping(placed: []const Placed) bool {
    for (placed[1..], 0..) |p, i| {
        const previous = placed[i];
        const previous_end = if (previous.positional()) previous.start + 1 else previous.end;
        if (p.start < previous_end) return true;
    }
    return false;
}

/// Display cells one source byte occupies in an excerpt: tabs are mirrored
/// as tabs, printable bytes are one cell, everything else is a 4-cell escape.
fn cellsOf(byte: u8) usize {
    return if (byte == '\t' or std.ascii.isPrint(byte)) 1 else 4;
}

/// Blank cells mirroring `bytes`, so marks below the excerpt line up.
fn writeMirror(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte| {
        try writer.writeAll(if (byte == '\t') "\t" else if (std.ascii.isPrint(byte)) " " else "    ");
    }
}

fn writeUnderlinePrefix(view: View, gutter_width: usize, g: Glyphs, pal: Palette, writer: anytype) !void {
    try writeRail(g, pal, writer);
    try writeRepeat(writer, " ", gutter_width);
    try writer.print(" {s} ", .{g.gutter});
    if (view.clipped_left) try writeRepeat(writer, " ", g.clip_width);
}

fn annotationStyle(annotation: Annotation, pal: Palette) []const u8 {
    return if (annotation.primary) pal.frame else pal.secondary;
}

/// Whether the annotation has label text at all (a primary span without
/// details is the one that does not).
fn hasLabel(d: Diagnostic, annotation: Annotation) bool {
    return !annotation.primary or d.details != .none;
}

fn writeLabel(d: Diagnostic, annotation: Annotation, writer: anytype) !void {
    if (annotation.primary) {
        try writePrimaryLabel(d.details, writer);
    } else {
        try writeSecondaryLabel(d.details, annotation.role.?, writer);
    }
}

/// The marks under one placed span: carets for the primary, dashes for a
/// secondary, with the T junction in the connector cell when the label
/// hangs below instead of sitting inline.
fn writeMarks(writer: anytype, source: []const u8, p: Placed, hanging: bool, g: Glyphs) !void {
    const mark = if (p.annotation.primary) "^" else g.secondary_underline;
    if (p.positional()) {
        try writer.writeAll(if (hanging) g.tee else mark);
        return;
    }
    var offset = p.start;
    while (offset < p.end) : (offset += 1) {
        const cells = cellsOf(source[offset]);
        if (hanging and offset == p.connector) {
            try writer.writeAll(g.tee);
            try writeRepeat(writer, mark, cells - 1);
        } else {
            try writeRepeat(writer, mark, cells);
        }
    }
}

/// Several non-overlapping annotations on one line: a single row of marks
/// with the rightmost label inline, then one row per remaining annotation,
/// right to left, each hanging its label from a connector. Rows for spans
/// further left come lower, so every connector runs through blank cells
/// and never through a label.
fn writeHangingLabels(
    d: Diagnostic,
    placed: []const Placed,
    view: View,
    source: []const u8,
    gutter_width: usize,
    g: Glyphs,
    pal: Palette,
    writer: anytype,
) !void {
    const last = placed.len - 1;

    // Mark row.
    try writeUnderlinePrefix(view, gutter_width, g, pal, writer);
    var cursor = view.start;
    for (placed, 0..) |p, i| {
        try writeMirror(writer, source[cursor..p.start]);
        try writer.writeAll(annotationStyle(p.annotation, pal));
        try writeMarks(writer, source, p, i != last, g);
        try writer.writeAll(pal.reset);
        cursor = p.end;
    }
    const inline_annotation = placed[last].annotation;
    if (hasLabel(d, inline_annotation)) {
        try writer.print(" {s}", .{annotationStyle(inline_annotation, pal)});
        try writeLabel(d, inline_annotation, writer);
        try writer.writeAll(pal.reset);
    }
    try writer.writeAll("\n");

    // Hanging rows, rightmost first.
    var k = last;
    while (k > 0) {
        k -= 1;
        try writeUnderlinePrefix(view, gutter_width, g, pal, writer);
        cursor = view.start;
        for (placed[0..k]) |q| {
            try writeMirror(writer, source[cursor..q.connector]);
            try writer.print("{s}{s}{s}", .{ annotationStyle(q.annotation, pal), g.vertical, pal.reset });
            if (q.positional()) {
                cursor = q.connector;
            } else {
                // The connector sits in the first cell of its byte.
                try writeRepeat(writer, " ", cellsOf(source[q.connector]) - 1);
                cursor = q.connector + 1;
            }
        }
        const p = placed[k];
        try writeMirror(writer, source[cursor..p.connector]);
        try writer.print("{s}{s}{s}", .{ annotationStyle(p.annotation, pal), g.corner, g.hang });
        if (hasLabel(d, p.annotation)) {
            try writer.writeAll(" ");
            try writeLabel(d, p.annotation, writer);
        }
        try writer.print("{s}\n", .{pal.reset});
    }
}

/// The visible window of the line containing `offset`: the whole line when
/// it fits, else a `max_view`-byte window that keeps the span in sight.
///
/// Line boundaries must agree with `location.Tracker`: LF, CRLF, and
/// standalone CR each terminate one physical line — otherwise a diagnostic's
/// line number and the excerpted content would contradict each other.
fn viewFor(source: []const u8, offset: usize) View {
    var line_start = offset;
    while (line_start > 0 and !lineBoundaryBefore(source, line_start)) line_start -= 1;
    var line_end = offset;
    while (line_end < source.len and
        source[line_end] != '\n' and source[line_end] != '\r') line_end += 1;

    var start = line_start;
    var end = line_end;
    if (line_end - line_start > max_view) {
        const column = offset - line_start;
        if (column > max_view - 20) {
            start = offset - (max_view / 2);
        }
        end = @min(line_end, start + max_view);
    }
    return .{
        .line_start = line_start,
        .start = start,
        .end = end,
        .clipped_left = start > line_start,
        .clipped_right = end < line_end,
    };
}

/// True when the byte before `i` ends a line: LF always; CR only when it is
/// standalone (the CR of a CRLF pair belongs to the LF's terminator).
fn lineBoundaryBefore(source: []const u8, i: usize) bool {
    const previous = source[i - 1];
    if (previous == '\n') return true;
    if (previous == '\r') return i >= source.len or source[i] != '\n';
    return false;
}

/// One annotation on its own row: marks, then the label inline.
fn writeUnderline(
    d: Diagnostic,
    annotation: Annotation,
    view: View,
    source: []const u8,
    gutter_width: usize,
    g: Glyphs,
    pal: Palette,
    writer: anytype,
) !void {
    try writeUnderlinePrefix(view, gutter_width, g, pal, writer);
    // Mirror tabs and account for the four cells of each escaped byte.
    // Excerpts intentionally use byte escapes rather than Unicode display-
    // width interpretation; canonical locations remain original byte columns.
    const p = place(annotation, view);
    try writeMirror(writer, source[view.start..p.start]);
    try writer.writeAll(annotationStyle(annotation, pal));
    try writeMarks(writer, source, p, false, g);
    if (hasLabel(d, annotation)) {
        try writer.writeAll(" ");
        try writeLabel(d, annotation, writer);
    }
    try writer.print("{s}\n", .{pal.reset});
}

/// The role-named label under the primary span. The offending text sits
/// directly above the carets, so labels never repeat what was found.
fn writePrimaryLabel(details: Details, writer: anytype) !void {
    switch (details) {
        .none => unreachable,
        .unterminated => |construct| try writer.print("{s} opened here, never closed", .{unterminatedName(construct)}),
        .expected_quote => |found| try writeExpectedQuote(found, writer),
        .invalid_byte => |byte| {
            if (byte == 0) {
                try writer.writeAll("NUL bytes are not allowed in DOT input");
            } else if (std.ascii.isPrint(byte)) {
                try writer.print("byte 0x{X:0>2} ('{c}') cannot start a DOT token", .{ byte, byte });
            } else {
                try writer.print("byte 0x{X:0>2} cannot start a DOT token", .{byte});
            }
        },
        .invalid_operator => |operator| switch (operator.shape) {
            .spaced => try writer.writeAll("no whitespace inside an edge operator"),
            .long, .lone => if (operator.found == null) {
                try writer.writeAll("expected '--' or '->', found end of input");
            } else {
                try writer.writeAll("expected '--' or '->'");
            },
        },
        .incomplete_numeral => |found| {
            if (found) |byte| {
                if (std.ascii.isPrint(byte)) {
                    try writer.print("expected a digit, found '{c}'", .{byte});
                } else {
                    try writer.print("expected a digit, found byte 0x{X:0>2}", .{byte});
                }
            } else {
                try writer.writeAll("expected a digit, found end of input");
            }
        },
        .ambiguous_numeral => |byte| {
            if (std.ascii.isPrint(byte)) {
                try writer.print("the numeral ends here; '{c}' begins a second token", .{byte});
            } else {
                try writer.writeAll("the numeral ends here; a second token follows");
            }
        },
        .reserved_keyword => |reserved| switch (reserved.context) {
            .attribute_list => try writer.writeAll("expected '[' after this keyword"),
            else => try writer.print("'{s}' is a reserved keyword", .{reserved.keyword.lexeme()}),
        },
        .unexpected => |unexpected| {
            try writer.writeAll("expected ");
            try writeExpectedSet(unexpected.expected, writer);
        },
        .operator_mismatch => |mismatch| {
            try writer.print("expected {s}, found {s}", .{
                operatorName(mismatch.expected), operatorName(mismatch.found),
            });
        },
        .unsupported_feature => {
            try writer.writeAll("the parse stopped at this deferred construct");
        },
        .capacity => |capacity| {
            try writer.print("{s} limit of {d} reached here", .{
                capacity.resource.name(), capacity.limit,
            });
        },
    }
}

/// The role-named label under a secondary span.
fn writeSecondaryLabel(details: Details, role: diagnostic.Related.Role, writer: anytype) !void {
    switch (details) {
        .operator_mismatch => |mismatch| switch (mismatch.expected) {
            .undirected => try writer.writeAll(
                "the document is undirected because of this keyword",
            ),
            .directed => try writer.writeAll(
                "the document is directed because of this keyword",
            ),
        },
        .unexpected => switch (role) {
            .opened_here => try writer.writeAll("opened here, never closed"),
            .suffix_started_here => try writer.writeAll("port suffix component started here"),
            .declared_here => try writer.writeAll("declared here"),
            .misindented_close => try writer.writeAll("this '}' is indented like an outer scope; is a '}' missing above it?"),
        },
        else => unreachable,
    }
}

fn digits(value: usize) usize {
    var remaining = value;
    var count: usize = 1;
    while (remaining >= 10) : (remaining /= 10) count += 1;
    return count;
}

fn writeUnsigned(writer: anytype, value: usize, width: usize) !void {
    try writeRepeat(writer, " ", width -| digits(value));
    try writer.print("{d}", .{value});
}

// ---------------------------------------------------------------------------
// Payload wording (shared by the compact renderer and the fallback path)
// ---------------------------------------------------------------------------

/// The detail content for each typed payload. Wording lives here, in the
/// renderer, never in the diagnostic data.
fn writeDetailValue(details: Details, writer: anytype) !void {
    switch (details) {
        .none => unreachable,
        .unterminated => |construct| try writer.print("unterminated {s}", .{unterminatedName(construct)}),
        .expected_quote => |found| try writeExpectedQuote(found, writer),
        .invalid_byte => |byte| {
            if (std.ascii.isPrint(byte)) {
                try writer.print("offending byte 0x{X:0>2} ('{c}')", .{ byte, byte });
            } else {
                try writer.print("offending byte 0x{X:0>2}", .{byte});
            }
        },
        .invalid_operator => |operator| {
            try writer.writeAll(switch (operator.shape) {
                .lone => "expected '--' or '->', found ",
                .long => "one character too many; the operator ended at ",
                .spaced => "whitespace inside the operator; it ended at ",
            });
            try writeByteOrEnd(operator.found, writer);
        },
        .incomplete_numeral => |found| {
            try writer.writeAll("expected a digit, found ");
            try writeByteOrEnd(found, writer);
        },
        .ambiguous_numeral => |byte| {
            try writer.writeAll("the numeral runs into ");
            try writeByteOrEnd(byte, writer);
        },
        .reserved_keyword => |reserved| {
            try writer.print("keyword '{s}' while parsing {s}", .{ reserved.keyword.lexeme(), contextName(reserved.context) });
        },
        .unexpected => |unexpected| {
            try writer.print("while parsing {s}: expected ", .{
                contextName(unexpected.context),
            });
            try writeExpectedSet(unexpected.expected, writer);
            try writer.print(", found {s}", .{itemName(unexpected.found)});
        },
        .operator_mismatch => |mismatch| {
            try writer.print("expected {s}, found {s}", .{
                operatorName(mismatch.expected), operatorName(mismatch.found),
            });
        },
        .unsupported_feature => |feature| {
            try writer.print("unsupported feature '{s}'", .{feature.name()});
        },
        .capacity => |capacity| {
            try writer.print("{s} limit of {d} reached", .{
                capacity.resource.name(), capacity.limit,
            });
        },
    }
}

fn unterminatedName(construct: diagnostic.UnterminatedConstruct) []const u8 {
    return switch (construct) {
        .block_comment => "block comment",
        .quoted_identifier => "quoted identifier",
    };
}

fn writeExpectedQuote(found: ?u8, writer: anytype) !void {
    if (found) |byte| {
        if (std.ascii.isPrint(byte)) {
            try writer.print("expected a double quote, found byte 0x{X:0>2} ('{c}')", .{ byte, byte });
        } else {
            try writer.print("expected a double quote, found byte 0x{X:0>2}", .{byte});
        }
    } else {
        try writer.writeAll("expected a double quote, found end of input");
    }
}

fn writeByteOrEnd(byte: ?u8, writer: anytype) !void {
    if (byte) |b| {
        if (std.ascii.isPrint(b)) {
            try writer.print("byte 0x{X:0>2} ('{c}')", .{ b, b });
        } else {
            try writer.print("byte 0x{X:0>2}", .{b});
        }
    } else {
        try writer.writeAll("end of input");
    }
}

fn hasNote(details: Details) bool {
    return switch (details) {
        .unexpected => |unexpected| unexpected.related != null or unexpected.suspect != null,
        .operator_mismatch => true,
        else => false,
    };
}

/// The note content: secondary locations related to the failure.
fn writeNoteValue(details: Details, writer: anytype) !void {
    switch (details) {
        .unexpected => |unexpected| {
            var first = true;
            for ([_]?diagnostic.Related{ unexpected.related, unexpected.suspect }) |maybe| {
                const related = maybe orelse continue;
                if (!first) try writer.writeAll("; ");
                first = false;
                try writer.print("{s} at {d}:{d}", .{
                    roleName(related.role),
                    related.span.start.line,
                    related.span.start.byte_column,
                });
            }
        },
        .operator_mismatch => |mismatch| {
            try writer.print("graph kind declared at {d}:{d}", .{
                mismatch.declaration.start.line,
                mismatch.declaration.start.byte_column,
            });
        },
        else => unreachable,
    }
}

/// The items that start a statement. When every one is expected, the set
/// reads "a statement" instead of six alternatives.
const statement_starters = diagnostic.ExpectedSet.init(.{
    .graph_keyword = true,
    .subgraph_keyword = true,
    .node_keyword = true,
    .edge_keyword = true,
    .identifier = true,
    .left_brace = true,
});
const edge_operators = diagnostic.ExpectedSet.init(.{
    .undirected_operator = true,
    .directed_operator = true,
});

/// The expected set as prose, with the two natural groups collapsed so a
/// thirteen-item set (`a, b;`) reads as a handful of choices.
fn writeExpectedSet(set: diagnostic.ExpectedSet, writer: anytype) !void {
    const group_statement = set.supersetOf(statement_starters);
    const group_operator = set.supersetOf(edge_operators);
    var names: [@typeInfo(diagnostic.SyntaxItem).@"enum".fields.len]?[]const u8 = undefined;
    var total: usize = 0;
    var statement_named = false;
    var operator_named = false;
    var iterator = set.iterator();
    while (iterator.next()) |item| {
        if (group_statement and statement_starters.contains(item)) {
            if (statement_named) continue;
            statement_named = true;
            names[total] = "a statement";
        } else if (group_operator and edge_operators.contains(item)) {
            if (operator_named) continue;
            operator_named = true;
            names[total] = "an edge operator";
        } else {
            names[total] = itemName(item);
        }
        total += 1;
    }
    for (names[0..total], 0..) |name, index| {
        if (index > 0) {
            try writer.writeAll(if (index + 1 == total) " or " else ", ");
        }
        try writer.writeAll(name.?);
    }
}

fn itemName(item: diagnostic.SyntaxItem) []const u8 {
    return switch (item) {
        .graph_keyword => "'graph'",
        .digraph_keyword => "'digraph'",
        .strict_keyword => "'strict'",
        .subgraph_keyword => "'subgraph'",
        .node_keyword => "'node'",
        .edge_keyword => "'edge'",
        .identifier => "an identifier",
        .left_brace => "'{'",
        .right_brace => "'}'",
        .semicolon => "';'",
        .colon => "':'",
        .undirected_operator => "'--'",
        .directed_operator => "'->'",
        .end_of_input => "end of input",
        .left_bracket => "'['",
        .right_bracket => "']'",
        .equals => "'='",
        .comma => "','",
    };
}

fn contextName(context: diagnostic.ParseContext) []const u8 {
    return switch (context) {
        .document_header => "the document header",
        .subgraph_header => "a subgraph header",
        .document_body => "the document body",
        .statement => "a statement",
        .edge_endpoint => "an edge endpoint",
        .port_component => "a port suffix component",
        .statement_terminator => "a statement terminator",
        .document_epilogue => "the end of the document",
        .attribute_list => "an attribute list",
        .attribute_key => "an attribute key",
        .attribute_value => "an attribute value",
        .assignment_value => "an assignment value",
        .subgraph_suffix => "the end of a standalone subgraph",
    };
}

fn roleName(role: diagnostic.Related.Role) []const u8 {
    return switch (role) {
        .opened_here => "unclosed delimiter opened",
        .suffix_started_here => "port suffix component started",
        .declared_here => "declared",
        .misindented_close => "misindented closing brace",
    };
}

fn operatorName(operator: diagnostic.OperatorMismatch.Operator) []const u8 {
    return switch (operator) {
        .undirected => "'--'",
        .directed => "'->'",
    };
}

/// Lowercase English severity word ("error: …"). Presentation-only; the
/// protocol identity is `Severity.letter()`.
fn severityWord(severity: Severity) []const u8 {
    return switch (severity) {
        .trace => "trace",
        .info => "info",
        .completed => "completed",
        .success => "success",
        .help => "help",
        .warning => "warning",
        .critical => "critical",
        .blocked => "blocked",
        .err => "error",
    };
}

/// Title-case English severity word for headers.
fn severityTitle(severity: Severity) []const u8 {
    return switch (severity) {
        .trace => "Trace",
        .info => "Info",
        .completed => "Completed",
        .success => "Success",
        .help => "Help",
        .warning => "Warning",
        .critical => "Critical",
        .blocked => "Blocked",
        .err => "Error",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Code = diagnostic.Code;

fn spanAt(offset: u32, line: u32, column: u32, len: u32) location.Span {
    return .{
        .start = .{ .byte_offset = offset, .line = line, .byte_column = column },
        .byte_len = len,
    };
}

test "unterminated constructs render typed wording and safe fallbacks" {
    const source = "graph { /* unfinished";
    var d: Diagnostic = .{
        .code = .syntax_unterminated_construct,
        .span = spanAt(8, 1, 9, 2),
        .details = .{ .unterminated = .block_comment },
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try render(d, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "input ended inside a block comment") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "close the block comment opened here with '*/'") != null);

    writer = std.Io.Writer.fixed(&buffer);
    try renderBoxed(d, 1, .{ .source = source, .style = .ascii }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "^^ block comment opened here, never closed") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "E.Syntax.Token.032") != null);

    // Publicly constructed diagnostics can omit details. The registry's
    // generic summary/hint still render without taking an unreachable arm.
    d.details = .none;
    writer = std.Io.Writer.fixed(&buffer);
    try render(d, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), d.code.info().summary) != null);
    writer = std.Io.Writer.fixed(&buffer);
    try renderBoxed(d, 1, .{ .source = source }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), d.code.info().summary) != null);
}

test "identifier diagnostics render typed quote and concatenation context" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var d: Diagnostic = .{
        .code = .syntax_unterminated_construct,
        .span = spanAt(0, 1, 1, 1),
        .details = .{ .unterminated = .quoted_identifier },
    };
    try renderBoxed(d, 1, .{ .source = "\"unfinished", .style = .ascii }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "quoted identifier opened here, never closed") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "close the quoted identifier") != null);
    d.code = .syntax_invalid_concatenation;
    inline for (.{ @as(?u8, 'b'), @as(?u8, 0x1b), @as(?u8, null) }) |found| {
        d.details = .{ .expected_quote = found };
        writer = std.Io.Writer.fixed(&buffer);
        try render(d, &writer);
        try expect(std.mem.indexOf(u8, writer.buffered(), "E.Syntax.Concatenation.003") != null);
        try expect(std.mem.indexOf(u8, writer.buffered(), if (found == null) "found end of input" else "found byte 0x") != null);
        try expect(std.mem.indexOfScalar(u8, writer.buffered(), 0x1b) == null);
    }
}

test "render produces informative text" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try render(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2, 7, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = .{ .start = .start, .byte_len = 5 },
        } },
    }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "error[dot_parser:E.Validation.Operator.002]") != null);
    try expect(std.mem.indexOf(u8, text, "line 2, byte column 7") != null);
    try expect(std.mem.indexOf(u8, text, "detail: expected '--', found '->'") != null);
    try expect(std.mem.indexOf(u8, text, "note: graph kind declared at 1:1") != null);
    try expect(std.mem.indexOf(u8, text, "help:") != null);
}

test "unexpected details render the expected set, context, and relation" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try render(.{
        .code = .syntax_unexpected_end,
        .span = spanAt(9, 1, 10, 0),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{
                .semicolon = true,
                .undirected_operator = true,
                .directed_operator = true,
            }),
            .found = .end_of_input,
            .context = .statement,
            .related = .{ .span = spanAt(6, 1, 7, 1), .role = .opened_here },
        } },
    }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "detail: while parsing a statement: expected ';' or an edge operator, found end of input") != null);
    try expect(std.mem.indexOf(u8, text, "note: unclosed delimiter opened at 1:7") != null);
}

test "boxed excerpt annotates both spans with role labels" {
    const source = "graph {\n    a -> b;\n}";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(14, 2, 7, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source_name = "example.dot", .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "┌─ Error 1: edge operator does not match the graph kind\n"));
    try expect(std.mem.indexOf(u8, text, "│ example.dot:2:7\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ 1 │ graph {\n") != null);
    try expect(std.mem.indexOf(u8, text, "│   │ ───── the document is undirected because of this keyword\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ 2 │     a -> b;\n") != null);
    try expect(std.mem.indexOf(u8, text, "│   │       ^^ expected '--', found '->'\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ Hint: change '->' to '--', or declare the document with 'digraph'\n") != null);
    try expect(std.mem.indexOf(u8, text, "└─ E1 ─ [dot_parser:E.Validation.Operator.002]\n") != null);

    // Default view carries no alias and no compact ID.
    const qualified_id = Code.validation_operator_mismatch.qualifiedCompactId();
    try expect(std.mem.indexOf(u8, text, "(MISMATCH)") == null);
    try expect(std.mem.indexOf(u8, text, &qualified_id) == null);
}

test "non-adjacent excerpt lines are separated by a gap marker" {
    const source = "graph {\n    a;\n    a -- b";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .syntax_unexpected_end,
        .span = spanAt(source.len, 3, 11, 0),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{
                .semicolon = true,
                .identifier = true,
                .right_brace = true,
            }),
            .found = .end_of_input,
            .context = .statement_terminator,
            .related = .{ .span = spanAt(6, 1, 7, 1), .role = .opened_here },
        } },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "│ 1 │ graph {\n") != null);
    try expect(std.mem.indexOf(u8, text, "│   │       ─ opened here, never closed\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ ⋯\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ 3 │     a -- b\n") != null);
    // Zero-width span: a single caret one column past the last byte.
    try expect(std.mem.indexOf(u8, text, "│   │           ^ expected an identifier, '}' or ';'\n") != null);
}

test "same-line annotations share one mark row and hang their labels" {
    const source = "graph { a -> b; }";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(10, 1, 11, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expectEqual(@as(usize, 1), std.mem.count(u8, text, "graph { a -> b; }"));
    // The rightmost label stays inline; the keyword's T junction sits in
    // the middle cell of its span and its label hangs from a connector.
    try expect(std.mem.indexOf(u8, text, "│   │ ──┬──     ^^ expected '--', found '->'\n" ++
        "│   │   └──── the document is undirected because of this keyword\n") != null);

    // ASCII has its own junction glyphs and stays 7-bit clean.
    var ascii_buffer: [2048]u8 = undefined;
    var ascii_writer = std.Io.Writer.fixed(&ascii_buffer);
    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(10, 1, 11, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source = source, .style = .ascii }, &ascii_writer);
    const ascii = ascii_writer.buffered();
    try expect(std.mem.indexOf(u8, ascii, "     | --+--     ^^ expected '--', found '->'\n" ++
        "     |   `---- the document is undirected because of this keyword\n") != null);
    for (ascii) |byte| try expect(byte < 0x80);
}

test "three same-line annotations hang leftmost lowest with continuations" {
    const source = "graph { a [x }";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try renderBoxed(.{
        .code = .syntax_unexpected_token,
        .span = spanAt(13, 1, 14, 1),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .identifier = true, .right_bracket = true }),
            .found = .right_brace,
            .context = .attribute_key,
            .related = .{ .span = spanAt(10, 1, 11, 1), .role = .opened_here },
            .suspect = .{ .span = spanAt(6, 1, 7, 1), .role = .misindented_close },
        } },
    }, 1, .{ .source = source }, &writer);
    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "│   │       ┬   ┬  ^ expected an identifier or ']'\n" ++
        "│   │       │   └──── opened here, never closed\n" ++
        "│   │       └──── this '}' is indented like an outer scope; is a '}' missing above it?\n") != null);

    // Overlapping spans fall back to one row each rather than drawing
    // marks on top of one another.
    var overlap_buffer: [2048]u8 = undefined;
    var overlap_writer = std.Io.Writer.fixed(&overlap_buffer);
    try renderBoxed(.{
        .code = .syntax_unexpected_token,
        .span = spanAt(8, 1, 9, 3),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .identifier = true }),
            .found = .identifier,
            .context = .statement,
            .related = .{ .span = spanAt(6, 1, 7, 4), .role = .opened_here },
        } },
    }, 1, .{ .source = source }, &overlap_writer);
    const overlap = overlap_writer.buffered();
    try expect(std.mem.indexOf(u8, overlap, "│   │       ──── opened here, never closed\n") != null);
    try expect(std.mem.indexOf(u8, overlap, "│   │         ^^^ expected an identifier\n") != null);
}

test "underline padding mirrors tabs so carets stay aligned" {
    const source = "graph {\n\ta -> b;\n}";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(11, 2, 4, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source = source }, &writer);

    try expect(std.mem.indexOf(u8, writer.buffered(), "│ \t  ^^ ") != null);
}

test "long lines are clamped to a window around the span" {
    const source = "graph { " ++ ("x" ** 80) ++ " -- b; }";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .syntax_unexpected_token,
        .span = spanAt(8 + 80 + 1, 1, 8 + 80 + 2, 2),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .semicolon = true }),
            .found = .undirected_operator,
            .context = .statement,
        } },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "…") != null);
    try expect(std.mem.indexOf(u8, text, "^^ expected ';'") != null);
    // The 80-byte identifier must not be shown whole.
    try expect(std.mem.indexOf(u8, text, "x" ** 61) == null);
}

test "CR-only line endings excerpt the same line the tracker counted" {
    // location.Tracker treats standalone CR as a line terminator (its
    // documented policy); the excerpt scanner must agree, or a diagnostic's
    // line number and its excerpted content would contradict each other.
    const source = "graph {\r    a -> b;\r}";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(14, 2, 7, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "│ 1 │ graph {\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ 2 │     a -> b;\n") != null);
    try expect(std.mem.indexOf(u8, text, "\r") == null);
}

test "carriage returns never leak into excerpts" {
    const source = "graph {\r\n    a -> b;\r\n}";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(15, 2, 7, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "│ 2 │     a -> b;\n") != null);
    try expect(std.mem.indexOf(u8, text, "\r") == null);
}

test "without source bytes the box degrades to compact lines" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2, 7, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = .{ .start = .start, .byte_len = 5 },
        } },
    }, 1, .{ .source_name = "example.dot" }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "┌─ Error 1: edge operator does not match the graph kind\n"));
    try expect(std.mem.indexOf(u8, text, "│ example.dot:2:7\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ expected '--', found '->'\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ graph kind declared at 1:1\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ Hint: ") != null);
    try expect(std.mem.indexOf(u8, text, "└─ E1 ─ [dot_parser:E.Validation.Operator.002]\n") != null);
}

test "a mismatched source degrades instead of crashing the renderer" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .syntax_unexpected_token,
        .span = spanAt(100, 9, 9, 2),
    }, 1, .{ .source = "short" }, &writer);

    try expect(std.mem.indexOf(u8, writer.buffered(), "┌─ Error 1: unexpected token") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "│ 9 │") == null);
}

test "unsupported constructs put the feature name in the headline" {
    const source = "graph { <table/> }";
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .profile_unsupported_feature,
        .span = spanAt(8, 1, 9, 8),
        .details = .{ .unsupported_feature = .html_identifier },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "┌─ Error 1: unsupported DOT construct: HTML-like identifier\n"));
    try expect(std.mem.indexOf(u8, text, "^^^^^^^^ the parse stopped at this deferred construct\n") != null);
}

test "verbose adds the alias and qualified compact ID to the closing line" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2, 7, 2),
    }, 2, .{ .verbose = true }, &writer);

    const qualified_id = Code.validation_operator_mismatch.qualifiedCompactId();
    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "└─ E2 ─ [dot_parser:E.Validation.Operator.002 (MISMATCH)] -> ") != null);
    try expect(std.mem.indexOf(u8, text, &qualified_id) != null);
}

test "ascii style is 7-bit clean with the same structure" {
    const source = "graph {\n    a -> b;\n}";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(14, 2, 7, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 1, 1, 5),
        } },
    }, 1, .{ .source_name = "example.dot", .source = source, .style = .ascii }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "-- Error 1: edge operator does not match the graph kind\n"));
    try expect(std.mem.indexOf(u8, text, "   1 | graph {\n") != null);
    try expect(std.mem.indexOf(u8, text, "   2 |     a -> b;\n") != null);
    try expect(std.mem.indexOf(u8, text, "^^ expected '--', found '->'\n") != null);
    try expect(std.mem.indexOf(u8, text, "-- E1 - [dot_parser:E.Validation.Operator.002]\n") != null);
    for (text) |byte| try expect(byte < 0x80);
}

test "ansi colors follow the WDP palette and reset cleanly" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2, 7, 2),
    }, 1, .{ .color = .ansi }, &writer);

    const text = writer.buffered();
    // Error severity is bold red (part 10 §3.1); the hint label is the
    // Help green; every escape is closed by a reset.
    try expect(std.mem.indexOf(u8, text, "\x1b[1;31m") != null);
    try expect(std.mem.indexOf(u8, text, "\x1b[32mHint:\x1b[0m") != null);
    try expect(std.mem.count(u8, text, "\x1b[0m") >= std.mem.count(u8, text, "\x1b[1;31m"));

    var plain_buffer: [2048]u8 = undefined;
    var plain_writer = std.Io.Writer.fixed(&plain_buffer);
    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2, 7, 2),
    }, 1, .{}, &plain_writer);
    try expect(std.mem.indexOf(u8, plain_writer.buffered(), "\x1b") == null);
}

test "a list of two or more diagnostics closes with a summary block" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const diagnostics = [_]Diagnostic{
        .{ .code = .validation_operator_mismatch, .span = spanAt(10, 2, 7, 2) },
        .{ .code = .validation_operator_mismatch, .span = spanAt(21, 3, 7, 2) },
    };
    try renderBoxedList(&diagnostics, 3, .{}, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "┌─ Error 1:") != null);
    try expect(std.mem.indexOf(u8, text, "┌─ Error 2:") != null);
    try expect(std.mem.indexOf(u8, text, "└─ E1 ─ [") != null);
    try expect(std.mem.indexOf(u8, text, "└─ E2 ─ [") != null);
    try expect(std.mem.indexOf(u8, text, "╔═ Summary\n║ 2 errors (3 more omitted: diagnostic bag is full)\n╚═") != null);
}

test "a single complete diagnostic renders no summary block" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const diagnostics = [_]Diagnostic{
        .{ .code = .validation_operator_mismatch, .span = spanAt(10, 2, 7, 2) },
    };
    try renderBoxedList(&diagnostics, 0, .{}, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "Summary") == null);

    // But a single diagnostic with omissions is an incomplete story: the
    // summary block carries the omission count.
    var omitted_writer = std.Io.Writer.fixed(&buffer);
    try renderBoxedList(&diagnostics, 2, .{}, &omitted_writer);
    try expect(std.mem.indexOf(u8, omitted_writer.buffered(), "║ 1 error (2 more omitted: diagnostic bag is full)") != null);
}

test "an empty list renders nothing" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try renderBoxedList(&.{}, 0, .{}, &writer);
    try expectEqualStrings("", writer.buffered());
}

test "render shows non-printable bytes as hex only" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try render(.{
        .code = .syntax_invalid_byte,
        .span = .{ .start = .start, .byte_len = 1 },
        .details = .{ .invalid_byte = 0x01 },
    }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "0x01") != null);
    try expect(std.mem.indexOf(u8, text, "('") == null);
}
