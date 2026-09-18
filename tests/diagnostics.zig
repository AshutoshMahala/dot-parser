//! Diagnostics regression table: for each deliberately broken input, the
//! identity, the primary location, and the wording a user actually sees.
//! Inputs mirror the external probe corpus that motivated the wording.

const std = @import("std");
const dot = @import("dot_parser");

const Case = struct {
    source: []const u8,
    code: dot.Code,
    line: usize,
    column: usize,
    /// Expected length of the primary span, when it matters.
    len: ?usize = null,
    /// Substring of the rendered hint line.
    hint: ?[]const u8 = null,
    /// Substring of the rendered excerpt labels.
    label: ?[]const u8 = null,
    /// The parse succeeds (warnings or validation errors only).
    parses: bool = false,
};

const cases = [_]Case{
    // Attribute lists.
    .{ .source = "digraph { a [color=red,,shape=box]; }", .code = .syntax_unexpected_token, .line = 1, .column = 24, .hint = "single ',' or ';'" },
    .{ .source = "digraph { a [color=red", .code = .syntax_unexpected_end, .line = 1, .column = 23, .hint = "add ']'", .label = "opened here, never closed" },
    .{ .source = "digraph { a [color=red; }", .code = .syntax_unexpected_token, .line = 1, .column = 25, .hint = "add ']' before this token", .label = "opened here, never closed" },
    .{ .source = "digraph { a [color=red\n  b -> c;\n}", .code = .syntax_unexpected_token, .line = 2, .column = 5, .hint = "not closed" },
    .{ .source = "digraph { a [color red]; }", .code = .syntax_unexpected_token, .line = 1, .column = 20, .hint = "'=' between the key and the value" },
    .{ .source = "digraph { a [=red]; }", .code = .syntax_unexpected_token, .line = 1, .column = 14, .hint = "key before this '='" },
    .{ .source = "digraph { a [color=]; }", .code = .syntax_unexpected_token, .line = 1, .column = 20, .hint = "value after '=' is missing" },
    .{ .source = "digraph { { a } [x=1] }", .code = .syntax_unexpected_token, .line = 1, .column = 17, .hint = "standalone subgraph takes no attribute list" },
    .{ .source = "digraph { a -> b [x=1] -> c; }", .code = .syntax_unexpected_token, .line = 1, .column = 24, .hint = "attribute list ends the statement" },
    .{ .source = "digraph { a [x=1] -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 19, .hint = "attribute list ends the statement" },
    // Headers.
    .{ .source = "", .code = .syntax_unexpected_end, .line = 1, .column = 1, .hint = "holds no graph" },
    .{ .source = "// nothing here\n", .code = .syntax_unexpected_end, .line = 2, .column = 1, .hint = "holds no graph" },
    .{ .source = "G { a; }", .code = .syntax_unexpected_token, .line = 1, .column = 1, .hint = "not with a name" },
    .{ .source = "digrph { a; }", .code = .syntax_unexpected_token, .line = 1, .column = 1, .hint = "did you mean 'digraph'" },
    .{ .source = "Grpah { }", .code = .syntax_unexpected_token, .line = 1, .column = 1, .hint = "did you mean 'graph'" },
    .{ .source = "digraph G\n  a -> b;\n}\n", .code = .syntax_unexpected_token, .line = 2, .column = 3, .hint = "must open with '{'" },
    .{ .source = "digraph G H { }", .code = .syntax_unexpected_token, .line = 1, .column = 11, .hint = "at most one name" },
    .{ .source = "digraph strict { }", .code = .syntax_unexpected_token, .line = 1, .column = 9, .hint = "'strict' comes before" },
    .{ .source = "strict { }", .code = .syntax_unexpected_token, .line = 1, .column = 8, .hint = "starts with 'graph' or 'digraph'" },
    .{ .source = "subgraph { a }", .code = .syntax_unexpected_token, .line = 1, .column = 1, .hint = "cannot be the root" },
    .{ .source = "digraph { a; } }", .code = .syntax_unexpected_token, .line = 1, .column = 16, .hint = "no matching '{'" },
    .{ .source = "digraph { a; } b", .code = .syntax_unexpected_token, .line = 1, .column = 16, .hint = "nothing may follow" },
    .{ .source = "digraph { a } digraph { b }", .code = .syntax_unexpected_token, .line = 1, .column = 15, .hint = "exactly one graph" },
    .{ .source = "digraph {\n  a -> b;\n  b -> c;\n", .code = .syntax_unexpected_end, .line = 4, .column = 1, .hint = "add the missing '}'", .label = "opened here, never closed" },
    // Lexical.
    .{ .source = "digraph { \"a\" + b -> c; }", .code = .syntax_invalid_concatenation, .line = 1, .column = 17, .hint = "double quotes" },
    .{ .source = "digraph { a -> @b; }", .code = .syntax_invalid_byte, .line = 1, .column = 16, .hint = "'@' cannot appear outside", .label = "cannot start a DOT token" },
    .{ .source = "digraph { . -> b; }", .code = .syntax_incomplete_numeral, .line = 1, .column = 11, .len = 1, .label = "expected a digit, found ' '" },
    .{ .source = "digraph { -. -> b; }", .code = .syntax_incomplete_numeral, .line = 1, .column = 11, .len = 2 },
    .{ .source = "digraph { \"a\x00b\"; }", .code = .syntax_invalid_byte, .line = 1, .column = 13, .hint = "NUL", .label = "NUL bytes are not allowed" },
    .{ .source = "digraph {\n  a -> b; /* comment\n  b -> c;\n}\n", .code = .syntax_unterminated_construct, .line = 2, .column = 11, .hint = "'*/'" },
    .{ .source = "digraph {\n  a -> \"unterminated;\n  b -> c;\n}\n", .code = .syntax_unterminated_construct, .line = 2, .column = 8, .hint = "double quote" },
    .{ .source = "digraph { a [label=<b>]; }", .code = .profile_unsupported_feature, .line = 1, .column = 20 },
    // Operators and numerals as typed.
    .{ .source = "digraph { a - b; }", .code = .syntax_invalid_operator, .line = 1, .column = 13, .len = 1, .hint = "single '-' is not an operator" },
    .{ .source = "digraph { a - > b; }", .code = .syntax_invalid_operator, .line = 1, .column = 13, .len = 1, .hint = "no space between" },
    .{ .source = "digraph { a --> b; }", .code = .syntax_invalid_operator, .line = 1, .column = 13, .len = 3, .hint = "write '->'" },
    .{ .source = "digraph { a => b; }", .code = .syntax_invalid_byte, .line = 1, .column = 14, .hint = "second character of '->'" },
    .{ .source = "digraph { a -> -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 16, .hint = "two edge operators in a row" },
    .{ .source = "digraph { 1e3; }", .code = .syntax_ambiguous_numeral, .line = 1, .column = 11, .len = 1, .hint = "quote the text", .parses = true },
    .{ .source = "digraph { 1.2.3; }", .code = .syntax_ambiguous_numeral, .line = 1, .column = 11, .len = 3, .hint = "at most one dot", .parses = true },
    // Keywords.
    .{ .source = "digraph { node; }", .code = .syntax_reserved_keyword, .line = 1, .column = 11, .len = 4, .hint = "starts an attribute statement", .label = "expected '[' after this keyword" },
    .{ .source = "digraph { edge = red; }", .code = .syntax_reserved_keyword, .line = 1, .column = 11, .hint = "write \"edge\" in double quotes" },
    .{ .source = "digraph { a -> graph; }", .code = .syntax_reserved_keyword, .line = 1, .column = 16, .hint = "write \"graph\" in double quotes", .label = "'graph' is a reserved keyword" },
    .{ .source = "digraph { subgraph node { } }", .code = .syntax_reserved_keyword, .line = 1, .column = 20, .hint = "reserved keyword" },
    // Statements.
    .{ .source = "digraph { ; }", .code = .syntax_unexpected_token, .line = 1, .column = 11, .hint = "stray ';'" },
    .{ .source = "digraph { -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 11, .hint = "left endpoint" },
    .{ .source = "digraph { a -> ; }", .code = .syntax_unexpected_token, .line = 1, .column = 16, .hint = "followed by an endpoint" },
    .{ .source = "graph { a -> b; c -> ; }", .code = .syntax_unexpected_token, .line = 1, .column = 22 },
    .{ .source = "digraph { a, b; }", .code = .syntax_unexpected_token, .line = 1, .column = 12, .hint = "',' does not separate statements", .label = "expected a statement, '}', ';', ':', an edge operator, '[' or '='" },
    .{ .source = "digraph { = LR; }", .code = .syntax_unexpected_token, .line = 1, .column = 11, .hint = "name before '='" },
    .{ .source = "digraph { rankdir = ; }", .code = .syntax_unexpected_token, .line = 1, .column = 21, .hint = "value after '='" },
    // Ports.
    .{ .source = "digraph { a::n -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 13, .hint = "'::'" },
    .{ .source = "digraph { a:", .code = .syntax_unexpected_end, .line = 1, .column = 13, .label = "port suffix component started here" },
    .{ .source = "digraph { a: -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 14, .hint = "compass point" },
    .{ .source = "digraph { {a}:n -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 14, .hint = "never to a subgraph" },
    .{ .source = "digraph { a:n:e:w -> b; }", .code = .syntax_unexpected_token, .line = 1, .column = 16, .hint = "at most two port components" },
    // Subgraphs.
    .{ .source = "digraph { subgraph s t { } }", .code = .syntax_unexpected_token, .line = 1, .column = 22, .hint = "at most one name" },
    .{ .source = "digraph { subgraph s a; }", .code = .syntax_unexpected_token, .line = 1, .column = 22, .hint = "must open with '{'" },
    .{
        .source = "digraph {\n  subgraph s {\n    a -> b;\n  b -> c;\n}\n",
        .code = .syntax_unexpected_end,
        .line = 6,
        .column = 1,
        .hint = "the '}' at 5:1 is indented like an outer scope",
        .label = "is a '}' missing above it?",
    },
    // Validation is unchanged.
    .{ .source = "graph { a -- b; a -> b; }", .code = .validation_operator_mismatch, .line = 1, .column = 19, .hint = "change '->' to '--'", .parses = true },
};

test "every probe reports the expected identity, location, and wording" {
    for (cases) |case| {
        errdefer std.debug.print("probe source: {s}\n", .{case.source});
        var bag: dot.FixedDiagnosticBag(8) = .{};
        var checked = dot.parseAndValidate(std.testing.allocator, case.source, bag.sink(), .{});
        defer checked.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.parses, checked.outcome == .success);
        try std.testing.expect(bag.items().len >= 1);
        const d = bag.items()[0];
        try std.testing.expectEqual(case.code, d.code);
        try std.testing.expectEqual(case.line, d.span.start.line);
        try std.testing.expectEqual(case.column, d.span.start.byte_column);
        if (case.len) |len| try std.testing.expectEqual(len, d.span.byte_len);

        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try dot.console.renderBoxed(d, 1, .{ .source = case.source, .style = .ascii }, &writer);
        const text = writer.buffered();
        if (case.hint) |hint| {
            errdefer std.debug.print("rendered:\n{s}\n", .{text});
            try std.testing.expect(std.mem.indexOf(u8, text, hint) != null);
        }
        if (case.label) |label| {
            errdefer std.debug.print("rendered:\n{s}\n", .{text});
            try std.testing.expect(std.mem.indexOf(u8, text, label) != null);
        }
    }
}

test "a byte order mark is not a diagnostic" {
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, "\xEF\xBB\xBFdigraph { a -> b; }", bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try std.testing.expect(checked.documentValid());
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
    // The keyword's byte column accounts for the three BOM bytes.
    try std.testing.expectEqual(@as(u32, 3), checked.document.?.keyword.start);
}

test "the compact renderer says byte column and lists every note" {
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, "digraph {\n  subgraph s {\n    a -> b;\n  b -> c;\n}\n", bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dot.console.render(bag.items()[0], &writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "line 6, byte column 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "note: unclosed delimiter opened at 1:9; misindented closing brace at 5:1") != null);
}
