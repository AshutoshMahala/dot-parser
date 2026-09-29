//! Optional, processor-independent console presentation. No parser imports or
//! runtime registration. Renderer(Adapter) binds wording and payloads at comptime.
//! The adapter supplies Item, registry, Annotations, headline/hint/detail,
//! hasDetails/hasNote/note, fix, annotations and primary/secondaryLabel methods.
//! Rendering writes only to the caller's writer and never allocates or probes IO.
const std = @import("std");
const location = @import("location.zig");
const Severity = @import("reporting.zig").Severity;

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

/// Where positions are shown from. Diagnostics carry byte offsets only;
/// with `options.source` a line and byte column are derived through one
/// cursor shared by everything a render call prints. Ascending queries reuse
/// that traversal; earlier related spans can require rescanning. Without source
/// bytes the offset itself is shown.
pub const Positions = struct {
    source: ?[]const u8,
    cursor: location.PositionCursor = .{},

    pub fn locate(self: *Positions, offset: u32) ?location.Location {
        const source = self.source orelse return null;
        if (offset > source.len) return null;
        return self.cursor.locate(source, offset);
    }

    /// `line:column`, or `offset N` without a source.
    pub fn writeColonForm(self: *Positions, offset: u32, writer: anytype) !void {
        if (self.locate(offset)) |at| {
            try writer.print("{d}:{d}", .{ at.line, at.byte_column });
        } else {
            try writer.print("offset {d}", .{offset});
        }
    }

    /// `line L, byte column C`, or `offset N` without a source.
    pub fn writeWordForm(self: *Positions, offset: u32, writer: anytype) !void {
        if (self.locate(offset)) |at| {
            try writer.print("line {d}, byte column {d}", .{ at.line, at.byte_column });
        } else {
            try writer.print("offset {d}", .{offset});
        }
    }
};

/// Bounded scratch for presentation only; roles stay processor-owned.
pub fn Annotations(comptime Role: type, comptime capacity: u8) type {
    return struct {
        pub const max_count = capacity;
        pub const Annotation = struct {
            span: location.Span,
            primary: bool,
            role: ?Role = null,
            line: u32 = 0,
        };
        items: [capacity]Annotation = undefined,
        len: u8 = 0,
        pub fn add(self: *@This(), annotation: Annotation) void {
            std.debug.assert(self.len < capacity);
            self.items[self.len] = annotation;
            self.len += 1;
        }
        pub fn slice(self: *const @This()) []const Annotation {
            return self.items[0..self.len];
        }
    };
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

/// The repair, as an instruction. With the source, the marked text is
/// quoted (when short and printable) so the line reads on its own.
pub fn writeFix(fix: anytype, positions: *Positions, writer: anytype) !void {
    const source = positions.source;
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
        .insert_before => |replacement| if (fix.span.len == 0) {
            // A position rather than text: usually end of input.
            if (source != null and fix.span.start == source.?.len) {
                try writer.print("insert '{s}' at end of input", .{replacement.text()});
            } else {
                try writer.print("insert '{s}' at ", .{replacement.text()});
                try positions.writeWordForm(fix.span.start, writer);
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
    if (span.len == 0 or span.len > 24 or !spanFits(span, bytes)) return null;
    const text = span.slice(bytes);
    for (text) |byte| {
        if (!std.ascii.isPrint(byte)) return null;
    }
    return text;
}

fn spanFits(span: location.Span, source: []const u8) bool {
    return span.start <= source.len and span.len <= source.len - span.start;
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

/// All payload-specific calls are statically bound to Adapter. Annotation
/// capacity is a processor-specific compile-time bound, not a heap allocation.
pub fn Renderer(comptime Adapter: type) type {
    return struct {
        const Diagnostic = Adapter.Item;
        const diagnostic = Adapter.registry;
        const Annotation = Adapter.Annotations.Annotation;
        const max_secondary: usize = Adapter.Annotations.max_count;
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
        pub fn render(d: Diagnostic, options: RenderOptions, writer: anytype) !void {
            const info = d.code.info();
            var positions: Positions = .{ .source = options.source };
            try writer.print("{s}[{s}:{s}]: ", .{
                severityWord(info.severity), diagnostic.namespace, d.code.structured(),
            });
            try Adapter.headline(d, writer);
            try writer.writeAll("\n");
            if (positions.locate(d.span.start)) |at| {
                try writer.print("  --> line {d}, byte column {d} (offset {d}, len {d})\n", .{
                    at.line, at.byte_column, at.byte_offset, d.span.len,
                });
            } else {
                try writer.print("  --> offset {d}, len {d}\n", .{ d.span.start, d.span.len });
            }
            if (Adapter.hasDetails(d)) {
                try writer.writeAll("  detail: ");
                try Adapter.detail(d, writer);
                try writer.writeAll("\n");
            }
            if (Adapter.hasNote(d)) {
                try writer.writeAll("  note: ");
                try Adapter.note(d, &positions, writer);
                try writer.writeAll("\n");
            }
            try writer.writeAll("  help: ");
            try Adapter.hint(d, &positions, writer);
            try writer.writeAll("\n");
            if (Adapter.fix(d)) |fix| {
                try writer.writeAll("  fix: ");
                try writeFix(fix, &positions, writer);
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
            var positions: Positions = .{ .source = options.source };
            try renderBoxedWith(d, number, options, &positions, writer);
        }

        fn renderBoxedWith(
            d: Diagnostic,
            number: usize,
            options: RenderOptions,
            positions: *Positions,
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
            try Adapter.headline(d, writer);
            try writer.writeAll("\n");

            try writeRail(g, pal, writer);
            try writer.print("{s}:", .{options.source_name});
            try positions.writeColonForm(d.span.start, writer);
            try writer.writeAll("\n");

            if (excerptSource(d, options)) |source| {
                try writeBlankRail(g, pal, writer);
                try writeExcerpt(d, source, positions, g, pal, writer);
                try writeBlankRail(g, pal, writer);
            } else {
                // Compact fallback: the typed payload and the related location as
                // unlabeled lines — the header already says what kind of line each
                // one is.
                if (Adapter.hasDetails(d)) {
                    try writeRail(g, pal, writer);
                    try Adapter.detail(d, writer);
                    try writer.writeAll("\n");
                }
                if (Adapter.hasNote(d)) {
                    try writeRail(g, pal, writer);
                    try Adapter.note(d, positions, writer);
                    try writer.writeAll("\n");
                }
            }

            try writeRail(g, pal, writer);
            try writer.print("{s}Hint:{s} ", .{ pal.hint, pal.reset });
            try Adapter.hint(d, positions, writer);
            try writer.writeAll("\n");
            if (Adapter.fix(d)) |fix| {
                try writeRail(g, pal, writer);
                try writer.print("{s}Fix:{s} ", .{ pal.hint, pal.reset });
                try writeFix(fix, positions, writer);
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
            omitted: u64,
            options: RenderOptions,
            writer: anytype,
        ) !void {
            var errors: usize = 0;
            var warnings: usize = 0;
            var worst: Severity = .trace;
            var positions: Positions = .{ .source = options.source };
            for (diagnostics, 0..) |d, index| {
                if (index != 0) try writer.writeAll("\n");
                try renderBoxedWith(d, index + 1, options, &positions, writer);
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
            for (Adapter.annotations(d).slice()) |annotation| {
                if (!spanFits(annotation.span, source)) return null;
            }
            return source;
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
            positions: *Positions,
            g: Glyphs,
            pal: Palette,
            writer: anytype,
        ) !void {
            var annotations: [max_secondary + 1]Annotation = undefined;
            var count: usize = 0;
            for (Adapter.annotations(d).slice()) |annotation| {
                annotations[count] = annotation;
                count += 1;
            }
            annotations[count] = .{ .span = d.span, .primary = true };
            count += 1;
            // Source order, so the excerpt reads top to bottom.
            std.mem.sort(Annotation, annotations[0..count], {}, struct {
                fn lessThan(_: void, a: Annotation, b: Annotation) bool {
                    return a.span.start < b.span.start;
                }
            }.lessThan);

            var gutter_width: usize = 0;
            for (annotations[0..count]) |*annotation| {
                annotation.line = positions.cursor.locate(source, annotation.span.start).line;
                gutter_width = @max(gutter_width, digits(annotation.line));
            }

            var previous_line: usize = 0;
            var index: usize = 0;
            while (index < count) {
                const line = annotations[index].line;
                var group_end = index + 1;
                while (group_end < count and annotations[group_end].line == line) group_end += 1;

                if (previous_line != 0 and line > previous_line + 1) {
                    try writeRail(g, pal, writer);
                    try writer.print("{s}\n", .{g.gap});
                }
                const view = viewFor(source, annotations[index].span.start);
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
            const offset: usize = annotation.span.start;
            const start = @min(offset, view.end);
            const len = if (offset < view.end) @min(annotation.span.len, view.end - offset) else 0;
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
            return !annotation.primary or Adapter.hasDetails(d);
        }

        fn writeLabel(d: Diagnostic, annotation: Annotation, writer: anytype) !void {
            if (annotation.primary) {
                try Adapter.primaryLabel(d, writer);
            } else {
                try Adapter.secondaryLabel(d, annotation.role.?, writer);
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
    };
}
