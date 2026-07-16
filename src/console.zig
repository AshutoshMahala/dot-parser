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

const std = @import("std");
const diagnostic = @import("diagnostic.zig");

const Diagnostic = diagnostic.Diagnostic;
const Details = diagnostic.Details;
const Severity = diagnostic.Severity;

/// Options for the numbered renderers.
pub const RenderOptions = struct {
    /// Name shown in the location line ("--> name:line:column"). The core
    /// never learns file names (R-MOD-003), so the presenter supplies one.
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
///   expected '--', found '->'
///   help: an undirected document ('graph') connects nodes with '--'; ...
/// ```
///
/// `writer` is anything with `print`, e.g. a `*std.Io.Writer`.
pub fn render(d: Diagnostic, writer: anytype) !void {
    const i = d.code.info();
    const loc = d.span.start;
    try writer.print("{s}[{s}:{s}]: {s}\n", .{
        severityWord(i.severity), diagnostic.namespace, d.code.structured(), i.summary,
    });
    try writer.print("  --> line {d}, column {d} (byte {d}, len {d})\n", .{
        loc.line, loc.byte_column, loc.byte_offset, d.span.byte_len,
    });
    try writeDetails(d.details, "  ", writer);
    try writer.print("  help: {s}\n", .{i.hint});
}

/// Render one diagnostic as a numbered block.
///
/// `.unicode` style:
///
/// ```text
/// ┌─ Error 1 ─── [dot_parser:E.Validation.Operator.002] -> 4aF9x-V6a0B
/// │
/// │ error: edge operator does not match the graph kind
/// │   --> example.dot:2:7
/// │   expected '--', found '->'
/// │
/// │   Suggestion: an undirected document ('graph') connects nodes with '--'; ...
/// └────────────────────────────────────────────────────── E1
/// ```
///
/// `.ascii` style:
///
/// ```text
/// -- Error 1 - [dot_parser:E.Validation.Operator.002] -> 4aF9x-V6a0B
///    error: edge operator does not match the graph kind
///    --> example.dot:2:7
///    expected '--', found '->'
///    Suggestion: an undirected document ('graph') connects nodes with '--'; ...
/// ```
///
/// The `-> …` reference is the fully qualified compact ID
/// (`namespace_hash-code_hash`, WDP part 7 §5.2).
pub fn renderBoxed(
    d: Diagnostic,
    number: usize,
    options: RenderOptions,
    writer: anytype,
) !void {
    const i = d.code.info();
    const loc = d.span.start;
    const qualified_id = d.code.qualifiedCompactId();

    switch (options.style) {
        .unicode => {
            try writer.print("┌─ {s} {d} ─── [{s}:{s}] -> {s}\n", .{
                severityTitle(i.severity), number,        diagnostic.namespace,
                d.code.structured(),       &qualified_id,
            });
            try writer.writeAll("│\n");
            try writer.print("│ {s}: {s}\n", .{ severityWord(i.severity), i.summary });
            try writer.print("│   --> {s}:{d}:{d}\n", .{
                options.source_name, loc.line, loc.byte_column,
            });
            try writeDetails(d.details, "│   ", writer);
            try writer.writeAll("│\n");
            try writer.print("│   Suggestion: {s}\n", .{i.hint});
            try writer.writeAll("└");
            for (0..options.rule_width) |_| try writer.writeAll("─");
            try writer.print(" {c}{d}\n", .{ i.severity.letter(), number });
        },
        .ascii => {
            try writer.print("-- {s} {d} - [{s}:{s}] -> {s}\n", .{
                severityTitle(i.severity), number,        diagnostic.namespace,
                d.code.structured(),       &qualified_id,
            });
            try writer.print("   {s}: {s}\n", .{ severityWord(i.severity), i.summary });
            try writer.print("   --> {s}:{d}:{d}\n", .{
                options.source_name, loc.line, loc.byte_column,
            });
            try writeDetails(d.details, "   ", writer);
            try writer.print("   Suggestion: {s}\n", .{i.hint});
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

fn writeDetails(details: Details, comptime prefix: []const u8, writer: anytype) !void {
    switch (details) {
        .none => {},
        .invalid_byte => |byte| {
            if (std.ascii.isPrint(byte)) {
                try writer.print(prefix ++ "offending byte: 0x{X:0>2} ('{c}')\n", .{ byte, byte });
            } else {
                try writer.print(prefix ++ "offending byte: 0x{X:0>2}\n", .{byte});
            }
        },
        .expected_found => |ef| {
            try writer.print(prefix ++ "expected {s}, found {s}\n", .{ ef.expected, ef.found });
        },
        .unsupported_feature => |feature| {
            try writer.print(prefix ++ "feature: {s}\n", .{feature});
        },
        .capacity => |cap| {
            try writer.print(prefix ++ "{s} limit of {d} reached\n", .{ cap.resource, cap.limit });
        },
    }
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

/// Title-case English severity word for headers ("Error 1").
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
        .details = .{ .expected_found = .{ .expected = "'--'", .found = "'->'" } },
    }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "error[dot_parser:E.Validation.Operator.002]") != null);
    try expect(std.mem.indexOf(u8, text, "line 2, column 7") != null);
    try expect(std.mem.indexOf(u8, text, "expected '--', found '->'") != null);
    try expect(std.mem.indexOf(u8, text, "help:") != null);
}

test "boxed render frames one numbered diagnostic" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = .{ .start = .{ .byte_offset = 13, .line = 2, .byte_column = 7 }, .byte_len = 2 },
        .details = .{ .expected_found = .{ .expected = "'--'", .found = "'->'" } },
    }, 1, .{ .source_name = "example.dot" }, &writer);

    const text = writer.buffered();
    const qualified_id = Code.validation_operator_mismatch.qualifiedCompactId();

    try expect(std.mem.startsWith(u8, text, "┌─ Error 1 ─── [dot_parser:E.Validation.Operator.002] -> "));
    try expect(std.mem.indexOf(u8, text, &qualified_id) != null);
    try expect(std.mem.indexOf(u8, text, "│ error: edge operator does not match the graph kind") != null);
    try expect(std.mem.indexOf(u8, text, "--> example.dot:2:7") != null);
    try expect(std.mem.indexOf(u8, text, "│   expected '--', found '->'") != null);
    try expect(std.mem.indexOf(u8, text, "│   Suggestion: ") != null);
    try expect(std.mem.indexOf(u8, text, "─ E1\n") != null);
}

test "ascii render style is 7-bit clean" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .parser_unexpected_token,
        .span = .{ .start = .{ .byte_offset = 4, .line = 1, .byte_column = 5 }, .byte_len = 1 },
        .details = .{ .expected_found = .{ .expected = "';'", .found = "'}'" } },
    }, 1, .{ .source_name = "example.dot", .style = .ascii }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "-- Error 1 - [dot_parser:E.Parser.Syntax.003] -> "));
    try expect(std.mem.indexOf(u8, text, "   error: unexpected token") != null);
    try expect(std.mem.indexOf(u8, text, "--> example.dot:1:5") != null);
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
    try expect(std.mem.indexOf(u8, text, "--> <input>:2:7") != null);
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
