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
///   --> line 2, column 7 (byte 13, len 2)
///   detail: expected '--', found '->'
///   note: graph kind declared at 1:1
///   help: an undirected document ('graph') connects nodes with '--'; ...
/// ```
///
/// `writer` is anything with `print`, e.g. a `*std.Io.Writer`.
pub fn render(d: Diagnostic, writer: anytype) !void {
    const info = d.code.info();
    const loc = d.span.start;
    try writer.print("{s}[{s}:{s}]: ", .{
        severityWord(info.severity), diagnostic.namespace, d.code.structured(),
    });
    if (d.details == .unterminated) {
        try writeHeadline(d, info, writer);
    } else {
        try writer.writeAll(info.summary);
    }
    try writer.writeAll("\n");
    try writer.print("  --> line {d}, column {d} (byte {d}, len {d})\n", .{
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
    if (d.details == .unterminated) {
        try writeHint(d.details, info, writer);
    } else {
        try writer.writeAll(info.hint);
    }
    try writer.writeAll("\n");
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
    try writeHint(d.details, info, writer);
    try writer.writeAll("\n");

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
        else => try writer.writeAll(info.summary),
    }
}

/// The hint line: synthesized from the typed payload when it is derivable,
/// otherwise the registry's static hint. Extend one payload at a time as
/// contextual wording is developed; the fallback keeps every code covered.
fn writeHint(details: Details, info: diagnostic.Code.Info, writer: anytype) !void {
    switch (details) {
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
        else => try writer.writeAll(info.hint),
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
    if (secondarySpan(d.details)) |span| {
        if (!spanFits(span, source)) return null;
    }
    return source;
}

fn spanFits(span: location.Span, source: []const u8) bool {
    return span.start.byte_offset <= source.len and
        span.byte_len <= source.len - span.start.byte_offset;
}

/// The secondary annotated location, if the payload carries one.
fn secondarySpan(details: Details) ?location.Span {
    return switch (details) {
        .operator_mismatch => |mismatch| mismatch.declaration,
        .unexpected => |unexpected| if (unexpected.related) |related| related.span else null,
        else => null,
    };
}

const Annotation = struct {
    span: location.Span,
    primary: bool,
};

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
    // Every current payload carries at most one secondary span; grow this
    // (and the sort below) when a payload gains more related locations.
    var annotations: [2]Annotation = undefined;
    var count: usize = 0;
    if (secondarySpan(d.details)) |span| {
        annotations[count] = .{ .span = span, .primary = false };
        count += 1;
    }
    annotations[count] = .{ .span = d.span, .primary = true };
    count += 1;
    if (count == 2 and
        annotations[0].span.start.byte_offset > annotations[1].span.start.byte_offset)
    {
        std.mem.swap(Annotation, &annotations[0], &annotations[1]);
    }

    var gutter_width: usize = 0;
    for (annotations[0..count]) |annotation| {
        gutter_width = @max(gutter_width, digits(annotation.span.start.line));
    }

    var previous_line: usize = 0;
    var view: View = undefined;
    for (annotations[0..count]) |annotation| {
        const line = annotation.span.start.line;
        if (line != previous_line) {
            if (previous_line != 0 and line > previous_line + 1) {
                try writeRail(g, pal, writer);
                try writer.print("{s}\n", .{g.gap});
            }
            view = viewFor(source, annotation.span.start.byte_offset);
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
        }
        try writeUnderline(d, annotation, view, source, gutter_width, g, pal, writer);
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
    try writeRail(g, pal, writer);
    try writeRepeat(writer, " ", gutter_width);
    try writer.print(" {s} ", .{g.gutter});
    if (view.clipped_left) try writeRepeat(writer, " ", g.clip_width);

    // Mirror tabs and account for the four cells of each escaped byte.
    // Excerpts intentionally use byte escapes rather than Unicode display-
    // width interpretation; canonical locations remain original byte columns.
    const offset = annotation.span.start.byte_offset;
    for (source[view.start..@min(offset, view.end)]) |byte| {
        try writer.writeAll(if (byte == '\t') "\t" else if (std.ascii.isPrint(byte)) " " else "    ");
    }

    // At least one mark (zero-width spans point at a position, e.g. end of
    // input), at most the visible remainder of the window.
    const visible = if (offset < view.end) view.end - offset else 0;
    var marks: usize = 0;
    for (source[offset..][0..@min(annotation.span.byte_len, visible)]) |byte| {
        marks += if (byte == '\t' or std.ascii.isPrint(byte)) @as(usize, 1) else 4;
    }
    marks = @max(1, marks);
    const style = if (annotation.primary) pal.frame else pal.secondary;
    try writer.writeAll(style);
    if (annotation.primary) {
        try writeRepeat(writer, "^", marks);
        if (d.details != .none) {
            try writer.writeAll(" ");
            try writePrimaryLabel(d.details, writer);
        }
    } else {
        try writeRepeat(writer, g.secondary_underline, marks);
        try writer.writeAll(" ");
        try writeSecondaryLabel(d.details, writer);
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
            if (std.ascii.isPrint(byte)) {
                try writer.print("byte 0x{X:0>2} ('{c}') is not valid in DOT", .{ byte, byte });
            } else {
                try writer.print("byte 0x{X:0>2} is not valid in DOT", .{byte});
            }
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
fn writeSecondaryLabel(details: Details, writer: anytype) !void {
    switch (details) {
        .operator_mismatch => |mismatch| switch (mismatch.expected) {
            .undirected => try writer.writeAll(
                "the document is undirected because of this keyword",
            ),
            .directed => try writer.writeAll(
                "the document is directed because of this keyword",
            ),
        },
        .unexpected => |unexpected| switch (unexpected.related.?.role) {
            .opened_here => try writer.writeAll("opened here, never closed"),
            .suffix_started_here => try writer.writeAll("port suffix component started here"),
            .declared_here => try writer.writeAll("declared here"),
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

fn hasNote(details: Details) bool {
    return switch (details) {
        .unexpected => |unexpected| unexpected.related != null,
        .operator_mismatch => true,
        else => false,
    };
}

/// The note content: secondary locations related to the failure.
fn writeNoteValue(details: Details, writer: anytype) !void {
    switch (details) {
        .unexpected => |unexpected| {
            const related = unexpected.related.?;
            try writer.print("{s} at {d}:{d}", .{
                roleName(related.role),
                related.span.start.line,
                related.span.start.byte_column,
            });
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

fn writeExpectedSet(set: diagnostic.ExpectedSet, writer: anytype) !void {
    const total = set.count();
    var iterator = set.iterator();
    var index: usize = 0;
    while (iterator.next()) |item| : (index += 1) {
        if (index > 0) {
            try writer.writeAll(if (index + 1 == total) " or " else ", ");
        }
        try writer.writeAll(itemName(item));
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
    };
}

fn roleName(role: diagnostic.Related.Role) []const u8 {
    return switch (role) {
        .opened_here => "unclosed delimiter opened",
        .suffix_started_here => "port suffix component started",
        .declared_here => "declared",
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

fn spanAt(offset: usize, line: usize, column: usize, len: usize) location.Span {
    return .{
        .start = .{ .byte_offset = offset, .line = line, .byte_column = column },
        .byte_len = len,
    };
}

test "unterminated constructs render typed wording and safe fallbacks" {
    const source = "graph { /* unfinished";
    var d: Diagnostic = .{
        .code = .lexer_unterminated_construct,
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
    try expect(std.mem.indexOf(u8, writer.buffered(), "E.Lexer.Syntax.031") != null);

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
        .code = .lexer_unterminated_construct,
        .span = spanAt(0, 1, 1, 1),
        .details = .{ .unterminated = .quoted_identifier },
    };
    try renderBoxed(d, 1, .{ .source = "\"unfinished", .style = .ascii }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "quoted identifier opened here, never closed") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "close the quoted identifier") != null);
    d.code = .lexer_invalid_concatenation;
    inline for (.{ @as(?u8, 'b'), @as(?u8, 0x1b), @as(?u8, null) }) |found| {
        d.details = .{ .expected_quote = found };
        writer = std.Io.Writer.fixed(&buffer);
        try render(d, &writer);
        try expect(std.mem.indexOf(u8, writer.buffered(), "E.Lexer.Syntax.003") != null);
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
    try expect(std.mem.indexOf(u8, text, "line 2, column 7") != null);
    try expect(std.mem.indexOf(u8, text, "detail: expected '--', found '->'") != null);
    try expect(std.mem.indexOf(u8, text, "note: graph kind declared at 1:1") != null);
    try expect(std.mem.indexOf(u8, text, "help:") != null);
}

test "unexpected details render the expected set, context, and relation" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try render(.{
        .code = .parser_unexpected_end,
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
    try expect(std.mem.indexOf(u8, text, "detail: while parsing a statement: expected ';', '--' or '->', found end of input") != null);
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
        .code = .parser_unexpected_end,
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

test "same-line annotations render the line once with stacked underlines" {
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
    try expect(std.mem.indexOf(u8, text, "│   │ ───── the document is undirected") != null);
    try expect(std.mem.indexOf(u8, text, "│   │           ^^ expected '--', found '->'") != null);
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
        .code = .parser_unexpected_token,
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
        .code = .parser_unexpected_token,
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
        .code = .lexer_invalid_byte,
        .span = .{ .start = .start, .byte_len = 1 },
        .details = .{ .invalid_byte = 0x01 },
    }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "0x01") != null);
    try expect(std.mem.indexOf(u8, text, "('") == null);
}
