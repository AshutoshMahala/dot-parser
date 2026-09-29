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
const location = @import("parser_support").location;

const Diagnostic = diagnostic.Diagnostic;
const Details = diagnostic.Details;
const Severity = diagnostic.Severity;

const common = @import("parser_support").console;
const Positions = common.Positions;
pub const RenderOptions = common.RenderOptions;
const Bound = common.Renderer(Adapter);
pub const render = Bound.render;
pub const renderBoxed = Bound.renderBoxed;
pub const renderBoxedList = Bound.renderBoxedList;

/// DOT's presentation vocabulary; layout and terminal style belong to common.
pub const Adapter = struct {
    pub const Item = diagnostic.Diagnostic;
    pub const registry = diagnostic;
    pub const Annotations = common.Annotations(diagnostic.Related.Role, 2);
    pub fn headline(d: Diagnostic, writer: anytype) !void {
        try writeHeadline(d, d.code.info(), writer);
    }
    pub fn hasDetails(d: Diagnostic) bool {
        return d.details != .none;
    }
    pub fn detail(d: Diagnostic, writer: anytype) !void {
        try writeDetailValue(d.details, writer);
    }
    pub fn hasNote(d: Diagnostic) bool {
        return hasRelatedNote(d.details);
    }
    pub fn note(d: Diagnostic, positions: *Positions, writer: anytype) !void {
        try writeNoteValue(d.details, positions, writer);
    }
    pub fn hint(d: Diagnostic, positions: *Positions, writer: anytype) !void {
        try writeHint(d, d.code.info(), positions, writer);
    }
    pub fn fix(d: Diagnostic) ?diagnostic.Fix {
        return d.suggestedFix();
    }
    pub fn annotations(d: Diagnostic) Annotations {
        return secondaryAnnotations(d.details);
    }
    pub fn primaryLabel(d: Diagnostic, writer: anytype) !void {
        try writePrimaryLabel(d.details, writer);
    }
    pub fn secondaryLabel(d: Diagnostic, role: diagnostic.Related.Role, writer: anytype) !void {
        try writeSecondaryLabel(d.details, role, writer);
    }
};

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
            try writer.print("'{s}' must be followed by a digit", .{if (d.span.len == 2) "-." else "."});
        },
        .reserved_keyword => |reserved| switch (reserved.context) {
            .attribute_list => try writer.print("keyword '{s}' is not followed by its attribute list", .{reserved.keyword.lexeme()}),
            else => try writer.print("reserved keyword '{s}' used as a name", .{reserved.keyword.lexeme()}),
        },
        else => try writer.writeAll(info.summary),
    }
}

/// The hint line: what to do about it, derived from the typed payload
/// (the grammar context, the token found, the related opener, the byte,
/// the attached fix). The registry's static hint is the fallback that
/// keeps every code covered.
fn writeHint(d: Diagnostic, info: diagnostic.Code.Info, positions: *Positions, writer: anytype) !void {
    switch (d.details) {
        .unterminated => |construct| switch (construct) {
            .block_comment => try writer.writeAll("close the block comment opened here with '*/'; block comments do not nest"),
            .quoted_identifier => try writer.writeAll("close the quoted identifier opened here with a double quote"),
            .html_identifier => try writer.writeAll("balance the angle brackets of the HTML-like identifier opened here"),
        },
        .operator_mismatch => |mismatch| if (d.code == .validation_operator_tolerated) {
            switch (mismatch.reading) {
                .as_written => try writer.writeAll("policy preserves the written operator; the graph declaration is unchanged"),
                .conform_to_kind => try writer.print("policy interprets this edge as {s}; the stored operator and source are unchanged", .{operatorName(mismatch.expected)}),
            }
        } else if (mismatch.reading == .conform_to_kind) {
            try writer.print("policy interprets this edge as {s}, but the written mismatch still fails validation", .{operatorName(mismatch.expected)});
        } else if (mismatch.kind_overridden) {
            try writer.writeAll("policy treats 'graph' as a digraph; change '--' to '->', or select a different graph policy");
        } else if (!mismatch.suggest_header_change) {
            try writer.print("change {s} to {s} to match the effective graph kind", .{ operatorName(mismatch.found), operatorName(mismatch.expected) });
        } else switch (mismatch.expected) {
            .directed => try writer.writeAll(
                "change '--' to '->', or declare the document with 'graph'",
            ),
            .undirected => try writer.writeAll(
                "change '->' to '--', or declare the document with 'digraph'",
            ),
        },
        .invalid_byte => |byte| switch (byte) {
            0 => try writer.writeAll("NUL is not allowed here; only comments and passthrough HTML-like identifiers retain it"),
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
        .unexpected => |unexpected| try writeUnexpectedHint(d, unexpected, info, positions, writer),
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
    positions: *Positions,
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
            .end_of_input => try writeUnclosedScopeHint(unexpected, positions, writer),
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
            .end_of_input => try writeUnclosedScopeHint(unexpected, positions, writer),
            else => try writer.writeAll("after a node name, write ';', an edge operator, an attribute list '[...]', or the next statement"),
        },
        .statement_terminator => switch (found) {
            .undirected_operator, .directed_operator => try writer.writeAll("an attribute list ends the statement; write the whole chain first, then its attributes: 'a -> b -> c [x=1]'"),
            .colon => try writer.writeAll("a port suffix attaches directly to a node name, with at most two components ('name:port:compass')"),
            .comma => try writer.writeAll("',' does not separate statements; use ';' or a newline"),
            .equals => try writer.writeAll("an edge statement cannot be assigned to; give it attributes in '[...]' instead"),
            .right_bracket => try writer.writeAll("there is no open attribute list for this ']'"),
            .end_of_input => try writeUnclosedScopeHint(unexpected, positions, writer),
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
fn writeUnclosedScopeHint(unexpected: diagnostic.Unexpected, positions: *Positions, writer: anytype) !void {
    try writer.writeAll("the input ends inside this scope; add the missing '}'");
    if (unexpected.suspect) |suspect| {
        try writer.writeAll("; the '}' at ");
        try positions.writeColonForm(suspect.span.start, writer);
        try writer.writeAll(" is indented like an outer scope, so the missing brace probably belongs above it");
    }
}

/// The secondary annotated locations the payload carries.
fn secondaryAnnotations(details: Details) Adapter.Annotations {
    var list: Adapter.Annotations = .{};
    switch (details) {
        .repeated_attribute => |first| list.add(.{ .span = first, .primary = false, .role = .declared_here }),
        .operator_mismatch => |mismatch| list.add(.{ .span = mismatch.declaration, .primary = false, .role = .declared_here }),
        .unexpected => |unexpected| {
            if (unexpected.related) |related| list.add(.{ .span = related.span, .primary = false, .role = related.role });
            if (unexpected.suspect) |suspect| list.add(.{ .span = suspect.span, .primary = false, .role = suspect.role });
        },
        else => {},
    }
    return list;
}

/// The role-named label under the primary span. The offending text sits
/// directly above the carets, so labels never repeat what was found.
fn writePrimaryLabel(details: Details, writer: anytype) !void {
    switch (details) {
        .invalid_utf8 => |byte| try writer.print("byte 0x{X:0>2} cannot begin a valid UTF-8 sequence here", .{byte}),
        .repeated_attribute => try writer.writeAll("same logical key as the earlier attribute"),
        .restriction => |kind| try writer.print("'{s}' is restricted by the consumer policy", .{@tagName(kind)}),
        .none => unreachable,
        .accepted_operator => |accepted| try writer.print("read as '{s}' by {s}", .{
            if (accepted.operator == .directed) "->" else "--",
            if (accepted.reason == .from_keyword) "the written header (from_keyword)" else "the long operator's shape",
        }),
        .unterminated => |construct| try writer.print("{s} opened here, never closed", .{unterminatedName(construct)}),
        .expected_string_part => |found| try writeExpectedStringPart(found, writer),
        .invalid_byte => |byte| {
            if (byte == 0) {
                try writer.writeAll("NUL bytes are not allowed at this position in DOT input");
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
            try writer.writeAll("this construct is disabled by the selected policy");
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
        .repeated_attribute => try writer.writeAll("first equal key in this statement"),
        .operator_mismatch => |mismatch| if (mismatch.kind_overridden)
            try writer.writeAll("written as 'graph'; policy treats it as a digraph")
        else switch (mismatch.expected) {
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

// ---------------------------------------------------------------------------
// Payload wording (shared by the compact renderer and the fallback path)
// ---------------------------------------------------------------------------

/// The detail content for each typed payload. Wording lives here, in the
/// renderer, never in the diagnostic data.
fn writeDetailValue(details: Details, writer: anytype) !void {
    switch (details) {
        .invalid_utf8 => |byte| try writer.print("invalid UTF-8 at byte 0x{X:0>2}", .{byte}),
        .repeated_attribute => |first| try writer.print("first equal key at byte offset {d}", .{first.start}),
        .restriction => |kind| try writer.print("restricted construct: {s}", .{@tagName(kind)}),
        .none => unreachable,
        .accepted_operator => |accepted| try writer.print("read as '{s}' by {s}", .{
            if (accepted.operator == .directed) "->" else "--",
            if (accepted.reason == .from_keyword) "the written header (from_keyword)" else "the long operator's shape",
        }),
        .unterminated => |construct| try writer.print("unterminated {s}", .{unterminatedName(construct)}),
        .expected_string_part => |found| try writeExpectedStringPart(found, writer),
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
        .html_identifier => "HTML-like identifier",
    };
}

fn writeExpectedStringPart(found: ?u8, writer: anytype) !void {
    if (found) |byte| {
        if (std.ascii.isPrint(byte)) {
            try writer.print("expected a double quote or '<', found byte 0x{X:0>2} ('{c}')", .{ byte, byte });
        } else {
            try writer.print("expected a double quote or '<', found byte 0x{X:0>2}", .{byte});
        }
    } else {
        try writer.writeAll("expected a double quote or '<', found end of input");
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

fn hasRelatedNote(details: Details) bool {
    return switch (details) {
        .unexpected => |unexpected| unexpected.related != null or unexpected.suspect != null,
        .operator_mismatch => true,
        else => false,
    };
}

/// The note content: secondary locations related to the failure.
fn writeNoteValue(details: Details, positions: *Positions, writer: anytype) !void {
    switch (details) {
        .unexpected => |unexpected| {
            var first = true;
            for ([_]?diagnostic.Related{ unexpected.related, unexpected.suspect }) |maybe| {
                const related = maybe orelse continue;
                if (!first) try writer.writeAll("; ");
                first = false;
                try writer.print("{s} at ", .{roleName(related.role)});
                try positions.writeColonForm(related.span.start, writer);
            }
        },
        .operator_mismatch => |mismatch| {
            try writer.writeAll(if (mismatch.kind_overridden) "written 'graph' treated as digraph by policy; header at " else "graph kind declared at ");
            try positions.writeColonForm(mismatch.declaration.start, writer);
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
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Code = diagnostic.Code;

fn spanAt(offset: u32, len: u32) location.Span {
    return .{ .start = offset, .len = len };
}

test "unterminated constructs render typed wording and safe fallbacks" {
    const source = "graph { /* unfinished";
    var d: Diagnostic = .{
        .code = .syntax_unterminated_construct,
        .span = spanAt(8, 2),
        .details = .{ .unterminated = .block_comment },
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try render(d, .{}, &writer);
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
    try render(d, .{}, &writer);
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
        .span = spanAt(0, 1),
        .details = .{ .unterminated = .quoted_identifier },
    };
    try renderBoxed(d, 1, .{ .source = "\"unfinished", .style = .ascii }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "quoted identifier opened here, never closed") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "close the quoted identifier") != null);
    d.code = .syntax_invalid_concatenation;
    inline for (.{ @as(?u8, 'b'), @as(?u8, 0x1b), @as(?u8, null) }) |found| {
        d.details = .{ .expected_string_part = found };
        writer = std.Io.Writer.fixed(&buffer);
        try render(d, .{}, &writer);
        try expect(std.mem.indexOf(u8, writer.buffered(), "E.Syntax.Concatenation.003") != null);
        try expect(std.mem.indexOf(u8, writer.buffered(), if (found == null) "found end of input" else "found byte 0x") != null);
        try expect(std.mem.indexOfScalar(u8, writer.buffered(), 0x1b) == null);
    }
}

test "render produces informative text" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Positions are derived from the source the caller passes.
    try render(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = .{ .start = 0, .len = 5 },
        } },
    }, .{ .source = "graph{\n  a   -> b" }, &writer);

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
        .span = spanAt(9, 0),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{
                .semicolon = true,
                .undirected_operator = true,
                .directed_operator = true,
            }),
            .found = .end_of_input,
            .context = .statement,
            .related = .{ .span = spanAt(6, 1), .role = .opened_here },
        } },
    }, .{ .source = "graph { a" }, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "detail: while parsing a statement: expected ';' or an edge operator, found end of input") != null);
    try expect(std.mem.indexOf(u8, text, "note: unclosed delimiter opened at 1:7") != null);
}

test "without a source the compact form shows byte offsets" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try render(.{
        .code = .syntax_unexpected_end,
        .span = spanAt(9, 0),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .semicolon = true }),
            .found = .end_of_input,
            .context = .statement,
            .related = .{ .span = spanAt(6, 1), .role = .opened_here },
        } },
    }, .{}, &writer);
    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "  --> offset 9, len 0\n") != null);
    try expect(std.mem.indexOf(u8, text, "note: unclosed delimiter opened at offset 6") != null);
}

test "boxed excerpt annotates both spans with role labels" {
    const source = "graph {\n    a -> b;\n}";
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(14, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(source.len, 0),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{
                .semicolon = true,
                .identifier = true,
                .right_brace = true,
            }),
            .found = .end_of_input,
            .context = .statement_terminator,
            .related = .{ .span = spanAt(6, 1), .role = .opened_here },
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
        .span = spanAt(10, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(10, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(13, 1),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .identifier = true, .right_bracket = true }),
            .found = .right_brace,
            .context = .attribute_key,
            .related = .{ .span = spanAt(10, 1), .role = .opened_here },
            .suspect = .{ .span = spanAt(6, 1), .role = .misindented_close },
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
        .span = spanAt(8, 3),
        .details = .{ .unexpected = .{
            .expected = diagnostic.ExpectedSet.init(.{ .identifier = true }),
            .found = .identifier,
            .context = .statement,
            .related = .{ .span = spanAt(6, 4), .role = .opened_here },
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
        .span = spanAt(11, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(8 + 80 + 1, 2),
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
        .span = spanAt(14, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(15, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(13, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = .{ .start = 0, .len = 5 },
        } },
    }, 1, .{ .source_name = "example.dot" }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "┌─ Error 1: edge operator does not match the graph kind\n"));
    try expect(std.mem.indexOf(u8, text, "│ example.dot:offset 13\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ expected '--', found '->'\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ graph kind declared at offset 0\n") != null);
    try expect(std.mem.indexOf(u8, text, "│ Hint: ") != null);
    try expect(std.mem.indexOf(u8, text, "└─ E1 ─ [dot_parser:E.Validation.Operator.002]\n") != null);
}

test "a mismatched source degrades instead of crashing the renderer" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .syntax_unexpected_token,
        .span = spanAt(100, 2),
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
        .span = spanAt(8, 8),
        .details = .{ .unsupported_feature = .html_identifier },
    }, 1, .{ .source = source }, &writer);

    const text = writer.buffered();
    try expect(std.mem.startsWith(u8, text, "┌─ Error 1: unsupported DOT construct: HTML-like identifier\n"));
    try expect(std.mem.indexOf(u8, text, "^^^^^^^^ this construct is disabled by the selected policy\n") != null);
}

test "verbose adds the alias and qualified compact ID to the closing line" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try renderBoxed(.{
        .code = .validation_operator_mismatch,
        .span = spanAt(13, 2),
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
        .span = spanAt(14, 2),
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = spanAt(0, 5),
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
        .span = spanAt(13, 2),
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
        .span = spanAt(13, 2),
    }, 1, .{}, &plain_writer);
    try expect(std.mem.indexOf(u8, plain_writer.buffered(), "\x1b") == null);
}

test "a list of two or more diagnostics closes with a summary block" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const diagnostics = [_]Diagnostic{
        .{ .code = .validation_operator_mismatch, .span = spanAt(10, 2) },
        .{ .code = .validation_operator_mismatch, .span = spanAt(21, 2) },
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
        .{ .code = .validation_operator_mismatch, .span = spanAt(10, 2) },
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
        .span = .{ .start = 0, .len = 1 },
        .details = .{ .invalid_byte = 0x01 },
    }, .{}, &writer);

    const text = writer.buffered();
    try expect(std.mem.indexOf(u8, text, "0x01") != null);
    try expect(std.mem.indexOf(u8, text, "('") == null);
}

test "NUL diagnostics describe the rejected position rather than all DOT bytes" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const finding: diagnostic.Diagnostic = .{
        .code = .syntax_invalid_byte,
        .span = .{ .start = 0, .len = 1 },
        .details = .{ .invalid_byte = 0 },
    };
    try render(finding, .{}, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "NUL is not allowed here") != null);
    writer = std.Io.Writer.fixed(&buffer);
    try renderBoxed(finding, 1, .{ .source = "\x00" }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "at this position") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "only comments and passthrough HTML-like identifiers retain it") != null);
}
