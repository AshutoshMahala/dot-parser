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
//! The numbered renderers use uniform labeled sections, one per line, all at
//! the same level:
//!
//! ```text
//! Error:      <summary>
//! Where:      <source>:<line>:<column>
//! Detail:     <typed payload, worded here>
//! Note:       <related location, worded here>
//! Suggestion: <registry hint>
//! ```
//!
//! Sections without content are omitted; no section is more special than
//! another.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");

const Diagnostic = diagnostic.Diagnostic;
const Details = diagnostic.Details;
const Severity = diagnostic.Severity;

/// Column where labeled-section content starts: derived from the widest
/// label (plus colon and one space) so adding a longer label can never
/// silently misalign the sections.
const label_column = blk: {
    var widest: usize = 0;
    for ([_][]const u8{
        "Where",    "Detail",    "Note",    "Suggestion", "Trace",
        "Info",     "Completed", "Success", "Help",       "Warning",
        "Critical", "Blocked",   "Error",
    }) |label| {
        widest = @max(widest, label.len);
    }
    break :blk widest + 2;
};

/// Options for the numbered renderers.
pub const RenderOptions = struct {
    /// Name shown in the Where section ("name:line:column"). The core never
    /// learns file names (R-MOD-003), so the presenter supplies one.
    source_name: []const u8 = "<input>",
    /// Visual style. `.unicode` draws a box; `.ascii` is plain 7-bit output
    /// for terminals and logs that cannot render box-drawing characters.
    style: Style = .unicode,
    /// Number of '─' characters in the unicode closing rule.
    rule_width: usize = 54,

    pub const Style = enum { unicode, ascii };
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
    try writer.print("{s}[{s}:{s}]: {s}\n", .{
        severityWord(info.severity), diagnostic.namespace, d.code.structured(), info.summary,
    });
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
    try writer.print("  help: {s}\n", .{info.hint});
}

/// Render one diagnostic as a numbered block of labeled sections.
///
/// `.unicode` style:
///
/// ```text
/// ┌─ Error 1 ─── [dot_parser:E.Validation.Operator.002 (MISMATCH)] -> xnOyw-In71I
/// │
/// │ Error:      edge operator does not match the graph kind
/// │ Where:      example.dot:2:7
/// │ Detail:     expected '--', found '->'
/// │ Note:       graph kind declared at 1:1
/// │ Suggestion: an undirected document ('graph') connects nodes with '--'; ...
/// │
/// └────────────────────────────────────────────────────── E1
/// ```
///
/// `.ascii` style carries the same sections without the box frame.
///
/// The header shows the WDP structured code with its sequence alias and the
/// fully qualified compact ID (`namespace_hash-code_hash`, WDP part 7 §5.2).
pub fn renderBoxed(
    d: Diagnostic,
    number: usize,
    options: RenderOptions,
    writer: anytype,
) !void {
    const info = d.code.info();
    const qualified_id = d.code.qualifiedCompactId();

    switch (options.style) {
        .unicode => {
            try writer.print("┌─ {s} {d} ─── [{s}:{s} ({s})] -> {s}\n", .{
                severityTitle(info.severity), number,     diagnostic.namespace,
                d.code.structured(),          info.alias, &qualified_id,
            });
            try writer.writeAll("│\n");
            try writeSections("│ ", d, info, options, writer);
            try writer.writeAll("│\n");
            try writer.writeAll("└");
            for (0..options.rule_width) |_| try writer.writeAll("─");
            try writer.print(" {c}{d}\n", .{ info.severity.letter(), number });
        },
        .ascii => {
            try writer.print("-- {s} {d} - [{s}:{s} ({s})] -> {s}\n", .{
                severityTitle(info.severity), number,     diagnostic.namespace,
                d.code.structured(),          info.alias, &qualified_id,
            });
            try writeSections("   ", d, info, options, writer);
        },
    }
}

/// Render a list of diagnostics as numbered blocks followed by a one-line
/// summary. `omitted` is the overflow count from a `FixedBag` (0 if none).
pub fn renderBoxedList(
    diagnostics: []const Diagnostic,
    omitted: usize,
    options: RenderOptions,
    writer: anytype,
) !void {
    var errors: usize = 0;
    var warnings: usize = 0;
    for (diagnostics, 0..) |d, index| {
        if (index != 0) try writer.writeAll("\n");
        try renderBoxed(d, index + 1, options, writer);
        switch (d.code.severity()) {
            .err, .blocked, .critical => errors += 1,
            .warning => warnings += 1,
            else => {},
        }
    }
    if (diagnostics.len != 0) try writer.writeAll("\n");
    try writer.print("Summary: {d} error(s), {d} warning(s), {d} total", .{
        errors, warnings, diagnostics.len,
    });
    if (omitted > 0) {
        try writer.print(" (+{d} omitted, capacity reached)", .{omitted});
    }
    try writer.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Labeled sections
// ---------------------------------------------------------------------------

fn writeSections(
    comptime prefix: []const u8,
    d: Diagnostic,
    info: diagnostic.Code.Info,
    options: RenderOptions,
    writer: anytype,
) !void {
    try writeLabel(prefix, severityTitle(info.severity), writer);
    try writer.print("{s}\n", .{info.summary});

    try writeLabel(prefix, "Where", writer);
    try writer.print("{s}:{d}:{d}\n", .{
        options.source_name, d.span.start.line, d.span.start.byte_column,
    });

    if (d.details != .none) {
        try writeLabel(prefix, "Detail", writer);
        try writeDetailValue(d.details, writer);
        try writer.writeAll("\n");
    }

    if (hasNote(d.details)) {
        try writeLabel(prefix, "Note", writer);
        try writeNoteValue(d.details, writer);
        try writer.writeAll("\n");
    }

    try writeLabel(prefix, "Suggestion", writer);
    try writer.print("{s}\n", .{info.hint});
}

fn writeLabel(comptime prefix: []const u8, label: []const u8, writer: anytype) !void {
    try writer.print(prefix ++ "{s}:", .{label});
    var column = label.len + 1;
    while (column < label_column) : (column += 1) try writer.writeAll(" ");
}

/// The Detail section content for each typed payload. Wording lives here,
/// in the renderer, never in the diagnostic data.
fn writeDetailValue(details: Details, writer: anytype) !void {
    switch (details) {
        .none => unreachable,
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

fn hasNote(details: Details) bool {
    return switch (details) {
        .unexpected => |unexpected| unexpected.related != null,
        .operator_mismatch => true,
        else => false,
    };
}

/// The Note section content: secondary locations related to the failure.
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
        .undirected_operator => "'--'",
        .directed_operator => "'->'",
        .end_of_input => "end of input",
    };
}

fn contextName(context: diagnostic.ParseContext) []const u8 {
    return switch (context) {
        .document_header => "the document header",
        .document_body => "the document body",
        .statement => "a statement",
        .edge_endpoint => "an edge endpoint",
        .statement_terminator => "a statement terminator",
        .document_epilogue => "the end of the document",
    };
}

fn roleName(role: diagnostic.Related.Role) []const u8 {
    return switch (role) {
        .opened_here => "unclosed delimiter opened",
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

/// Title-case English severity word for headers and section labels.
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
const expectEqualStrings = std.testing.expectEqualStrings;
const Code = diagnostic.Code;

test "render produces informative text" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try render(.{
        .code = .validation_operator_mismatch,
        .span = .{ .start = .{ .byte_offset = 13, .line = 2, .byte_column = 7 }, .byte_len = 2 },
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
        .span = .{ .start = .{ .byte_offset = 9, .line = 1, .byte_column = 10 }, .byte_len = 0 },
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{
                .semicolon = true,
                .undirected_operator = true,
                .directed_operator = true,
            }),
            .found = .end_of_input,
            .context = .statement,
            .related = .{
                .span = .{ .start = .{ .byte_offset = 6, .line = 1, .byte_column = 7 }, .byte_len = 1 },
                .role = .opened_here,
            },
        } },
    }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "detail: while parsing a statement: expected ';', '--' or '->', found end of input") != null);
    try expect(std.mem.indexOf(u8, text, "note: unclosed delimiter opened at 1:7") != null);
}

test "boxed render shows every section as a uniform labeled line" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = .{ .start = .{ .byte_offset = 13, .line = 2, .byte_column = 7 }, .byte_len = 2 },
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = .{ .start = .start, .byte_len = 5 },
        } },
    }, 1, .{ .source_name = "example.dot" }, &writer);

    const text = writer.buffered();
    const qualified_id = Code.validation_operator_mismatch.qualifiedCompactId();

    try expect(std.mem.startsWith(u8, text, "┌─ Error 1 ─── [dot_parser:E.Validation.Operator.002 (MISMATCH)] -> "));
    try expect(std.mem.indexOf(u8, text, &qualified_id) != null);
    try expect(std.mem.indexOf(u8, text, "│ Error:      edge operator does not match the graph kind") != null);
    try expect(std.mem.indexOf(u8, text, "│ Where:      example.dot:2:7") != null);
    try expect(std.mem.indexOf(u8, text, "│ Detail:     expected '--', found '->'") != null);
    try expect(std.mem.indexOf(u8, text, "│ Note:       graph kind declared at 1:1") != null);
    try expect(std.mem.indexOf(u8, text, "│ Suggestion: an undirected document") != null);
    try expect(std.mem.indexOf(u8, text, "─ E1\n") != null);
}

test "ascii render style is 7-bit clean with the same sections" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .parser_unexpected_token,
        .span = .{ .start = .{ .byte_offset = 4, .line = 1, .byte_column = 5 }, .byte_len = 1 },
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .semicolon = true }),
            .found = .right_brace,
            .context = .statement_terminator,
        } },
    }, 1, .{ .source_name = "example.dot", .style = .ascii }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "-- Error 1 - [dot_parser:E.Parser.Syntax.003 (INVALID)] -> "));
    try expect(std.mem.indexOf(u8, text, "   Error:      unexpected token") != null);
    try expect(std.mem.indexOf(u8, text, "   Where:      example.dot:1:5") != null);
    try expect(std.mem.indexOf(u8, text, "   Detail:     while parsing a statement terminator: expected ';', found '}'") != null);
    try expect(std.mem.indexOf(u8, text, "   Suggestion: ") != null);
    for (text) |byte| try expect(byte < 0x80);
}

test "boxed list numbers diagnostics and summarizes" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const diagnostics = [_]Diagnostic{
        .{
            .code = .validation_operator_mismatch,
            .span = .{ .start = .{ .byte_offset = 10, .line = 2, .byte_column = 7 }, .byte_len = 2 },
        },
        .{
            .code = .validation_operator_mismatch,
            .span = .{ .start = .{ .byte_offset = 21, .line = 3, .byte_column = 7 }, .byte_len = 2 },
        },
    };
    try renderBoxedList(&diagnostics, 3, .{}, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "Error 1") != null);
    try expect(std.mem.indexOf(u8, text, "Error 2") != null);
    try expect(std.mem.indexOf(u8, text, "─ E1\n") != null);
    try expect(std.mem.indexOf(u8, text, "─ E2\n") != null);
    try expect(std.mem.indexOf(u8, text, "<input>:2:7") != null);
    try expect(std.mem.indexOf(u8, text, "Summary: 2 error(s), 0 warning(s), 2 total (+3 omitted, capacity reached)") != null);
}

test "boxed list with no diagnostics prints only the summary" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try renderBoxedList(&.{}, 0, .{}, &writer);
    try expectEqualStrings("Summary: 0 error(s), 0 warning(s), 0 total\n", writer.buffered());
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
