//! WDP diagnostic primitives (milestone 1, step 2).
//!
//! ## Specification pin (R-DIAG-006)
//!
//! Diagnostic identities follow the Waddling Diagnostic Protocol (WDP)
//! **version 0.1.0-draft** at **conformance Level 2 (Namespaced)**:
//! structured codes (parts 1–4), compact IDs (part 5), and namespaces
//! (part 7), plus the informative part 6 sequence conventions and part 10
//! presentation palette. Codes read
//! `namespace:Severity.Component.Primary.Sequence`, where the namespace is
//! this library (`dot_parser`), the component is the logical domain of the
//! problem (`Syntax`, `Validation`, `Resource`, `Profile` — never the source
//! module that noticed it), the primary is the failure domain within it,
//! and sequences follow part 6 (001 MISSING, 002 MISMATCH, 003 INVALID,
//! 009 UNSUPPORTED, 026 EXHAUSTED; 031+ project-specific). The hashing algorithms are verified against the
//! spec's test vectors below; upgrading the WDP baseline requires
//! re-verifying those vectors and reviewing the current registry.
//!
//! Design constraints from the requirements:
//! - Diagnostics are structured data; the library never prints, formats, or
//!   terminates (R-FUNC-005). Presentation is entirely the consumer's job —
//!   implement `Sink` to route diagnostics into any logger or reporter.
//!   `console.zig` ships one out-of-the-box renderer; the core never calls it.
//! - No allocation anywhere in this module (R-MEM-001). Summaries and hints
//!   are static strings; `Details` carries only primitives and static names.
//! - No mutable module state (R-ROB-003). Diagnostics flow through
//!   caller-owned sinks and bags.
//! - Compact IDs are precomputed at compile time (R-DIAG-001/R-DIAG-004);
//!   there is no runtime hashing, catalog, or message template machinery.

const std = @import("std");
const location = @import("location.zig");

/// WDP part 7 namespace (error boundary) for every diagnostic this library
/// emits. Codes are unique within this boundary.
pub const namespace = "dot_parser";

/// Precomputed WDP part 7 namespace hash for `namespace` ("wdpns-v1" seed).
pub const namespace_hash: [5]u8 = computeNamespaceHash(namespace);

/// WDP severity alphabet (WDP part 1). The enum value is the WDP priority.
pub const Severity = enum(u4) {
    trace = 0,
    info = 1,
    completed = 2,
    success = 3,
    help = 4,
    warning = 5,
    critical = 6,
    blocked = 7,
    err = 8,

    /// The single-character WDP severity code.
    pub fn letter(self: Severity) u8 {
        return switch (self) {
            .trace => 'T',
            .info => 'I',
            .completed => 'K',
            .success => 'S',
            .help => 'H',
            .warning => 'W',
            .critical => 'C',
            .blocked => 'B',
            .err => 'E',
        };
    }

    /// WDP priority, 0 (trace) through 8 (error).
    pub fn priority(self: Severity) u4 {
        return @intFromEnum(self);
    }

    /// Only E and B block the operation that reported them (WDP part 1 §5).
    pub fn isBlocking(self: Severity) bool {
        return self == .err or self == .blocked;
    }

    pub const Tone = enum { negative, positive, neutral };

    pub fn tone(self: Severity) Tone {
        return switch (self) {
            .err, .blocked, .critical, .warning => .negative,
            .success, .completed => .positive,
            .help, .info, .trace => .neutral,
        };
    }
};

/// WDP component: the domain of responsibility a diagnostic belongs to
/// (WDP part 2 allows logical components; these are not source modules).
/// A consumer filtering on `E.Syntax.*` receives every malformed-input
/// problem, whether the scanner or the grammar noticed it. The library
/// itself is identified by `namespace`, not by the component.
pub const Component = enum {
    /// The input is not well-formed DOT: lexical and grammatical problems.
    syntax,
    /// The document parsed but violates a rule (kind/operator agreement).
    validation,
    /// A caller-configured capacity or the allocator was exhausted.
    resource,
    /// Recognized DOT that this build profile does not process.
    profile,

    /// PascalCase display form used inside structured codes.
    pub fn name(self: Component) []const u8 {
        return switch (self) {
            .syntax => "Syntax",
            .validation => "Validation",
            .resource => "Resource",
            .profile => "Profile",
        };
    }
};

/// WDP primary: the failure domain within a component (WDP part 3).
pub const Primary = enum {
    byte,
    token,
    operator,
    numeral,
    concatenation,
    grammar,
    keyword,
    capacity,
    memory,
    feature,

    /// PascalCase display form used inside structured codes.
    pub fn name(self: Primary) []const u8 {
        return switch (self) {
            .byte => "Byte",
            .token => "Token",
            .operator => "Operator",
            .numeral => "Numeral",
            .concatenation => "Concatenation",
            .grammar => "Grammar",
            .keyword => "Keyword",
            .capacity => "Capacity",
            .memory => "Memory",
            .feature => "Feature",
        };
    }
};

/// A sequence number and its canonical alias, defined together so registry
/// entries cannot accidentally pair a number with another condition's alias.
pub const SequenceDefinition = struct {
    number: u16,
    alias: []const u8,
};

/// Named sequence assignments used by this diagnostic registry. Sequences
/// identify a condition within a component/primary domain, not a complete
/// diagnostic identity. Conventional numbers follow the pinned WDP baseline.
pub const Sequence = struct {
    // WDP part 6 conventional assignments.
    pub const missing: SequenceDefinition = .{ .number = 1, .alias = "MISSING" };
    pub const mismatch: SequenceDefinition = .{ .number = 2, .alias = "MISMATCH" };
    pub const invalid: SequenceDefinition = .{ .number = 3, .alias = "INVALID" };
    pub const unsupported: SequenceDefinition = .{ .number = 9, .alias = "UNSUPPORTED" };
    pub const exhausted: SequenceDefinition = .{ .number = 26, .alias = "EXHAUSTED" };

    // Project-specific assignments (031–897). 031 and 032 follow the parser
    // example in WDP part 6 §9.5.
    pub const unexpected_end: SequenceDefinition = .{ .number = 31, .alias = "UNEXPECTED_END" };
    pub const unterminated: SequenceDefinition = .{ .number = 32, .alias = "UNTERMINATED" };
    pub const ambiguous: SequenceDefinition = .{ .number = 33, .alias = "AMBIGUOUS" };
};

/// The diagnostic registry.
///
/// Each current code is unique, documented here, and covered by registry
/// tests (R-DIAG-005). A code names one *condition*; where in the grammar
/// it occurred travels in the typed payload (`ParseContext`), never in the
/// identity. During experimental 0.x development, codes and payload enums
/// may change; obsolete entries are removed, not retained for replay.
pub const Code = enum {
    /// E.Syntax.Byte.003 (INVALID) — a byte that cannot start or continue
    /// any DOT token here, including NUL inside a quoted identifier.
    syntax_invalid_byte,
    /// E.Syntax.Operator.003 (INVALID) — a '-' that does not complete an
    /// edge operator (`a - b`, `a - > b`), or an over-long one (`-->`, `---`).
    /// Emitted with `Details.invalid_operator`.
    syntax_invalid_operator,
    /// E.Syntax.Numeral.001 (MISSING) — '.' or '-.' without the digit a DOT
    /// numeral requires. Emitted with `Details.incomplete_numeral`.
    syntax_incomplete_numeral,
    /// E.Syntax.Token.032 (UNTERMINATED) — a quoted identifier or block
    /// comment is never closed. Always emitted with `Details.unterminated`
    /// naming the construct; the span marks its opener.
    syntax_unterminated_construct,
    /// E.Syntax.Concatenation.003 (INVALID) — '+' must join two quoted
    /// identifiers. Emitted with `Details.expected_quote`.
    syntax_invalid_concatenation,
    /// E.Syntax.Grammar.003 (INVALID) — the token found violates the grammar.
    syntax_unexpected_token,
    /// E.Syntax.Grammar.031 (UNEXPECTED_END) — input ended mid-document.
    syntax_unexpected_end,
    /// E.Syntax.Keyword.003 (INVALID) — a reserved keyword where a name was
    /// needed, or an attribute keyword (`node`, `edge`, `graph`) not followed
    /// by its '[' list. Emitted with `Details.reserved_keyword`.
    syntax_reserved_keyword,
    /// W.Syntax.Numeral.033 (AMBIGUOUS) — a numeral runs directly into a
    /// letter or a second dot (`1e3`, `1.2.3`); it tokenizes as two tokens,
    /// exactly as Graphviz does, and Graphviz warns the same way. The parse
    /// continues. Emitted with `Details.ambiguous_numeral`.
    syntax_ambiguous_numeral,
    /// E.Validation.Operator.002 (MISMATCH) — edge operator does not match
    /// the document's graph kind.
    validation_operator_mismatch,
    /// E.Profile.Feature.009 (UNSUPPORTED) — valid DOT was recognized but is
    /// not supported by this milestone/build profile (R-MOD-006).
    profile_unsupported_feature,
    /// E.Resource.Capacity.026 (EXHAUSTED) — a caller-configured capacity was
    /// reached; distinct from invalid syntax (R-ROB-002).
    resource_capacity_exhausted,
    /// E.Resource.Memory.026 (EXHAUSTED) — the allocator could not provide
    /// memory for the retained document.
    resource_memory_exhausted,

    /// Comptime metadata for one diagnostic code. All strings are static.
    pub const Info = struct {
        severity: Severity,
        component: Component,
        primary: Primary,
        /// WDP sequence, 1–999.
        sequence: u16,
        /// Conventional or project-specific sequence name (WDP part 6).
        alias: []const u8,
        /// What went wrong.
        summary: []const u8,
        /// What the user can do about it. The registry text is the
        /// fallback; renderers derive a more specific hint from the typed
        /// payload whenever they can.
        hint: []const u8,
    };

    /// Internal entries select the sequence/alias pair once; Info exposes
    /// the derived number and alias for rendering and inspection.
    const Definition = struct {
        severity: Severity,
        component: Component,
        primary: Primary,
        sequence: SequenceDefinition,
        summary: []const u8,
        hint: []const u8,
    };

    pub fn info(self: Code) Info {
        const definition: Definition = switch (self) {
            .syntax_invalid_byte => .{
                .severity = .err,
                .component = .syntax,
                .primary = .byte,
                .sequence = Sequence.invalid,
                .summary = "input byte cannot start a DOT token",
                .hint = "remove the byte, or put the text inside a double-quoted identifier",
            },
            .syntax_invalid_operator => .{
                .severity = .err,
                .component = .syntax,
                .primary = .operator,
                .sequence = Sequence.invalid,
                .summary = "malformed edge operator",
                .hint = "an edge operator is '--' (undirected) or '->' (directed), written with no space inside",
            },
            .syntax_incomplete_numeral => .{
                .severity = .err,
                .component = .syntax,
                .primary = .numeral,
                .sequence = Sequence.missing,
                .summary = "a numeral needs a digit after '.'",
                .hint = "write a digit after the dot (for example '.5'), or quote the text to use it as a name",
            },
            .syntax_unterminated_construct => .{
                .severity = .err,
                .component = .syntax,
                .primary = .token,
                .sequence = Sequence.unterminated,
                .summary = "input ended inside an unterminated construct",
                .hint = "close the construct opened at the highlighted location",
            },
            .syntax_invalid_concatenation => .{
                .severity = .err,
                .component = .syntax,
                .primary = .concatenation,
                .sequence = Sequence.invalid,
                .summary = "expected a quoted identifier after '+'",
                .hint = "'+' joins quoted identifiers only; put the next identifier in double quotes",
            },
            .syntax_unexpected_token => .{
                .severity = .err,
                .component = .syntax,
                .primary = .grammar,
                .sequence = Sequence.invalid,
                .summary = "unexpected token",
                .hint = "check this statement against the DOT grammar: a body holds node, edge, attribute, assignment and subgraph statements",
            },
            .syntax_unexpected_end => .{
                .severity = .err,
                .component = .syntax,
                .primary = .grammar,
                .sequence = Sequence.unexpected_end,
                .summary = "input ended before the document was complete",
                .hint = "the input stops early; check for an unclosed delimiter or a truncated final statement",
            },
            .syntax_reserved_keyword => .{
                .severity = .err,
                .component = .syntax,
                .primary = .keyword,
                .sequence = Sequence.invalid,
                .summary = "reserved keyword used as a name",
                .hint = "DOT keywords are reserved in every position; write the name in double quotes to use it as an identifier",
            },
            .syntax_ambiguous_numeral => .{
                .severity = .warning,
                .component = .syntax,
                .primary = .numeral,
                .sequence = Sequence.ambiguous,
                .summary = "numeral runs directly into the next token",
                .hint = "Graphviz reads this as two tokens; quote the text, or separate the tokens with whitespace",
            },
            .validation_operator_mismatch => .{
                .severity = .err,
                .component = .validation,
                .primary = .operator,
                .sequence = Sequence.mismatch,
                .summary = "edge operator does not match the graph kind",
                .hint = "an undirected document ('graph') connects nodes with '--'; '->' is only valid in a 'digraph'",
            },
            .profile_unsupported_feature => .{
                .severity = .err,
                .component = .profile,
                .primary = .feature,
                .sequence = Sequence.unsupported,
                .summary = "recognized DOT construct is not supported by this profile",
                .hint = "this construct is recognized DOT syntax that this milestone or build does not process; parsing stopped at this boundary, so the rest of the input has not been checked",
            },
            .resource_capacity_exhausted => .{
                .severity = .err,
                .component = .resource,
                .primary = .capacity,
                .sequence = Sequence.exhausted,
                .summary = "a configured capacity was exhausted before the document finished",
                .hint = "raise the corresponding limit or provide larger caller-owned storage; the input itself may still be valid",
            },
            .resource_memory_exhausted => .{
                .severity = .err,
                .component = .resource,
                .primary = .memory,
                .sequence = Sequence.exhausted,
                .summary = "memory for the retained document was exhausted",
                .hint = "provide a larger allocator or arena, or parse into fixed pools sized for the document; the input itself may still be valid",
            },
        };
        return .{
            .severity = definition.severity,
            .component = definition.component,
            .primary = definition.primary,
            .sequence = definition.sequence.number,
            .alias = definition.sequence.alias,
            .summary = definition.summary,
            .hint = definition.hint,
        };
    }

    pub fn severity(self: Code) Severity {
        return self.info().severity;
    }

    /// The WDP structured code in display form, e.g. "E.Syntax.Grammar.003".
    pub fn structured(self: Code) []const u8 {
        return switch (self) {
            inline else => |code| comptime structuredText(code),
        };
    }

    /// The WDP compact ID (part 5): xxHash3 of the uppercased structured
    /// code, low 40 bits, Base62. Precomputed at compile time.
    pub fn compactId(self: Code) [5]u8 {
        return switch (self) {
            inline else => |code| comptime computeCompactId(structuredText(code)),
        };
    }

    /// The fully qualified compact ID (WDP part 7 §5.2):
    /// `namespace_hash-code_hash`, e.g. "4aF9x-V6a0B". Precomputed.
    pub fn qualifiedCompactId(self: Code) [11]u8 {
        return switch (self) {
            inline else => |code| comptime namespace_hash ++
                [1]u8{'-'} ++ computeCompactId(structuredText(code)),
        };
    }

    fn structuredText(comptime code: Code) []const u8 {
        const i = code.info();
        return std.fmt.comptimePrint("{c}.{s}.{s}.{d:0>3}", .{
            i.severity.letter(), i.component.name(), i.primary.name(), i.sequence,
        });
    }
};

const base62_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn base62Encode(hash: u64) [5]u8 {
    var value: u64 = hash & 0xFF_FFFF_FFFF; // low 40 bits (bytes 0-4)
    var out: [5]u8 = undefined;
    var i: usize = 5;
    while (i > 0) {
        i -= 1;
        out[i] = base62_alphabet[@intCast(value % 62)];
        value /= 62;
    }
    return out;
}

/// Compute a WDP part 5 compact ID from a structured code (parts 1–4).
///
/// Input is normalized to uppercase; caller passes the display form. Usable
/// at compile time and runtime; the registry only uses it at compile time.
pub fn computeCompactId(code_text: []const u8) [5]u8 {
    // "wdp-v1" zero-padded to 8 bytes, little-endian (WDP part 5 §4.5).
    const wdp_seed: u64 = 0x000031762D706477;

    var upper_buf: [64]u8 = undefined;
    std.debug.assert(code_text.len <= upper_buf.len);
    for (code_text, 0..) |byte, i| upper_buf[i] = std.ascii.toUpper(byte);

    return base62Encode(std.hash.XxHash3.hash(wdp_seed, upper_buf[0..code_text.len]));
}

/// Compute a WDP part 7 namespace hash. Unlike code hashes, namespaces are
/// hashed as-is (no uppercase normalization) with the "wdpns-v1" seed.
pub fn computeNamespaceHash(namespace_text: []const u8) [5]u8 {
    const wdpns_seed: u64 = 0x31762D736E706477;
    return base62Encode(std.hash.XxHash3.hash(wdpns_seed, namespace_text));
}

/// Typed, allocation-free context accompanying a diagnostic
/// (R-FUNC-005: structured data, no preformatted messages).
///
/// Every payload is a plain value type — enums, bytes, spans — safe to copy
/// and retain in a `FixedBag`. No variant stores a pointer or slice, so a
/// retained diagnostic has no lifetime of its own; the only indirection is
/// `location.Span`, which indexes the single source buffer the operation ran
/// over (multi-source diagnostics would need a source-identity field; out of
/// scope for now). Wording lives in renderers/catalogs, never here —
/// localization, consistent phrasing, and telemetry all want typed values.
pub const Details = union(enum) {
    none,
    /// For `syntax_invalid_byte`: the offending byte.
    invalid_byte: u8,
    /// For `syntax_invalid_operator`: the byte that broke the operator (the
    /// byte after '-' or '--'), or null when the input ended there.
    invalid_operator: ?u8,
    /// For `syntax_incomplete_numeral`: the byte found where a digit was
    /// required, or null when the input ended there.
    incomplete_numeral: ?u8,
    /// For `syntax_ambiguous_numeral`: the byte the numeral runs into.
    ambiguous_numeral: u8,
    /// For `syntax_unexpected_token` and `syntax_unexpected_end`.
    unexpected: Unexpected,
    /// For `syntax_reserved_keyword`.
    reserved_keyword: ReservedKeyword,
    /// For `validation_operator_mismatch`.
    operator_mismatch: OperatorMismatch,
    /// For `profile_unsupported_feature`.
    unsupported_feature: Feature,
    /// For `resource_capacity_exhausted`.
    capacity: Capacity,
    /// For `syntax_unterminated_construct`; the primary span is the opener.
    unterminated: UnterminatedConstruct,
    /// For `syntax_invalid_concatenation`: next raw byte, or null at EOF.
    expected_quote: ?u8,
};

/// The DOT keywords, for `ReservedKeyword`.
pub const Keyword = enum(u8) {
    graph,
    digraph,
    strict,
    subgraph,
    node,
    edge,

    /// The canonical lowercase spelling.
    pub fn lexeme(self: Keyword) []const u8 {
        return switch (self) {
            .graph => "graph",
            .digraph => "digraph",
            .strict => "strict",
            .subgraph => "subgraph",
            .node => "node",
            .edge => "edge",
        };
    }
};

/// A reserved keyword in a position that needed a name. With context
/// `.attribute_list` the keyword began an attribute statement (`node`,
/// `edge`, `graph`) and the required '[' did not follow — the two readings
/// (attribute statement or a name that needs quoting) are both possible,
/// and the span marks the keyword itself.
pub const ReservedKeyword = struct {
    keyword: Keyword,
    context: ParseContext,
};

/// Currently supported lexical constructs requiring a closing delimiter.
pub const UnterminatedConstruct = enum(u8) {
    block_comment,
    quoted_identifier,
};

/// Diagnostic-layer vocabulary for grammar-level constructs.
/// Deliberately NOT the lexer's token tags: diagnostics must not depend on
/// the lexer (dependency direction), and token tags are an implementation
/// detail that may diverge from user-facing grammar concepts.
pub const SyntaxItem = enum(u8) {
    graph_keyword,
    digraph_keyword,
    strict_keyword,
    subgraph_keyword,
    node_keyword,
    edge_keyword,
    identifier,
    left_brace,
    right_brace,
    semicolon,
    colon,
    undirected_operator,
    directed_operator,
    end_of_input,
    left_bracket,
    right_bracket,
    equals,
    comma,
};

/// An inline, allocation-free, deterministic set of expected constructs.
pub const ExpectedSet = std.EnumSet(SyntaxItem);

/// Grammar concepts identifying where a parser failure occurred, rather than
/// internal state-machine names.
pub const ParseContext = enum(u8) {
    document_header,
    subgraph_header,
    document_body,
    statement,
    edge_endpoint,
    port_component,
    statement_terminator,
    document_epilogue,
    attribute_list,
    attribute_key,
    attribute_value,
    assignment_value,
    /// Directly after a standalone subgraph: where ports and attribute
    /// lists are not allowed.
    subgraph_suffix,
};

/// A secondary source location related to a diagnostic. The role is typed;
/// renderers map it to (possibly localized) text.
pub const Related = struct {
    span: location.Span,
    role: Role,

    pub const Role = enum(u8) {
        /// A still-open delimiter this failure traces back to.
        opened_here,
        /// A colon whose required following component is missing.
        suffix_started_here,
        /// The declaration that established the violated expectation.
        declared_here,
        /// A closing '}' that sits at a smaller indentation than the line
        /// that opened the scope it closed — it probably belongs to an
        /// enclosing scope, and the real omission is above it.
        misindented_close,
    };
};

pub const Unexpected = struct {
    expected: ExpectedSet,
    found: SyntaxItem,
    context: ParseContext,
    /// The still-open delimiter (or pending port colon) this failure
    /// traces back to.
    related: ?Related = null,
    /// A location the parser suspects is the actual mistake, when a
    /// heuristic found one (`.misindented_close`).
    suspect: ?Related = null,
};

pub const OperatorMismatch = struct {
    /// The operator the document kind requires.
    expected: Operator,
    /// The operator actually written.
    found: Operator,
    /// Where the document declared its graph kind.
    declaration: location.Span,

    pub const Operator = enum(u8) { undirected, directed };
};

/// DOT features recognized but not implemented in the current parser.
/// Remove a variant when its feature ships. Consumers use these typed values
/// instead of parsing diagnostic text; this is not a cross-version wire enum.
pub const Feature = enum {
    html_identifier,
    non_ascii_identifier,

    /// Canonical English display name. Renderers may localize instead.
    pub fn name(self: Feature) []const u8 {
        return switch (self) {
            .html_identifier => "HTML-like identifier",
            .non_ascii_identifier => "non-ASCII identifier",
        };
    }
};

pub const Capacity = struct {
    resource: Resource,
    limit: usize,

    /// Which current caller-configured capacity was exhausted.
    pub const Resource = enum(u8) {
        statements,
        /// Caller-provided pools (`parseBorrowedIn`).
        statement_pool,
        node_pool,
        edge_pool,
        edge_chain_pool,
        edge_link_pool,
        edge_link_index,
        ported_reference_pool,
        subgraph_pool,
        scoped_edge_pool,
        scoped_edge_link_pool,
        nesting_frames,
        nesting_depth,
        ported_reference_index,
        /// The document's statement index width.
        statement_index,
        /// The 4 GiB retained source-range domain.
        source_range,
        attributes,
        attribute_pool,
        assignment_pool,
        attribute_statement_pool,
        attribute_index,

        pub fn name(self: Resource) []const u8 {
            return switch (self) {
                .statements => "statement",
                .statement_pool => "statement pool",
                .node_pool => "node pool",
                .edge_pool => "edge pool",
                .edge_chain_pool => "edge chain pool",
                .edge_link_pool => "edge link pool",
                .edge_link_index => "edge link index",
                .ported_reference_pool => "ported reference pool",
                .subgraph_pool => "subgraph pool",
                .scoped_edge_pool => "subgraph-edge owner pool",
                .scoped_edge_link_pool => "subgraph-edge link pool",
                .nesting_frames => "nesting frame storage",
                .nesting_depth => "nesting depth",
                .ported_reference_index => "ported reference index",
                .statement_index => "statement index",
                .source_range => "source range",
                .attributes => "attribute",
                .attribute_pool => "attribute pool",
                .assignment_pool => "assignment pool",
                .attribute_statement_pool => "attribute statement pool",
                .attribute_index => "attribute index",
            };
        }
    };
};

/// One reported problem: identity, where, and typed context.
pub const Diagnostic = struct {
    code: Code,
    span: location.Span,
    details: Details = .none,
};

pub const SinkError = error{DiagnosticSinkFailure};

/// Whether every diagnostic a pass emitted actually reached the caller's
/// sink. Reported by each phase separately from its outcome, so a failure
/// of the reporting infrastructure neither masks nor hides behind the
/// original result.
pub const Delivery = enum {
    complete,
    /// The sink rejected at least one diagnostic; that diagnostic is lost.
    failed,
};

/// A caller-owned destination for diagnostics (R-FUNC-008).
/// The pointed-to context must outlive every emit call.
pub const Sink = struct {
    context: ?*anyopaque,
    emit_fn: *const fn (context: ?*anyopaque, diagnostic: Diagnostic) SinkError!void,

    pub fn emit(self: Sink, diagnostic: Diagnostic) SinkError!void {
        return self.emit_fn(self.context, diagnostic);
    }
};

/// A sink that explicitly drops every diagnostic, for callers that
/// genuinely do not want them. Explicit disposal beats a hidden overload:
/// the choice is visible and greppable at the call site.
pub const discard: Sink = .{ .context = null, .emit_fn = discardEmit };

fn discardEmit(context: ?*anyopaque, d: Diagnostic) SinkError!void {
    _ = context;
    _ = d;
}

/// A fixed-capacity diagnostic bag with bounded-overflow policy: the first
/// `capacity` diagnostics are retained and later ones are counted in
/// `omitted` (R-FUNC-008). Never allocates; never fails.
pub fn FixedBag(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        entries: [capacity]Diagnostic = undefined,
        len: usize = 0,
        /// How many diagnostics arrived after the bag was full.
        omitted: usize = 0,

        pub fn push(self: *Self, diagnostic: Diagnostic) void {
            if (self.len < capacity) {
                self.entries[self.len] = diagnostic;
                self.len += 1;
            } else {
                self.omitted += 1;
            }
        }

        /// The retained diagnostics, in emission order.
        pub fn items(self: *const Self) []const Diagnostic {
            return self.entries[0..self.len];
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.omitted = 0;
        }

        pub fn sink(self: *Self) Sink {
            return .{ .context = self, .emit_fn = emitOpaque };
        }

        fn emitOpaque(context: ?*anyopaque, diagnostic: Diagnostic) SinkError!void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.push(diagnostic);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "severity alphabet matches WDP part 1" {
    try expectEqual(@as(u8, 'E'), Severity.err.letter());
    try expectEqual(@as(u8, 'B'), Severity.blocked.letter());
    try expectEqual(@as(u8, 'C'), Severity.critical.letter());
    try expectEqual(@as(u8, 'W'), Severity.warning.letter());
    try expectEqual(@as(u8, 'H'), Severity.help.letter());
    try expectEqual(@as(u8, 'S'), Severity.success.letter());
    try expectEqual(@as(u8, 'K'), Severity.completed.letter());
    try expectEqual(@as(u8, 'I'), Severity.info.letter());
    try expectEqual(@as(u8, 'T'), Severity.trace.letter());

    // Priority ordering: T(0) < I < K < S < H < W < C < B < E(8).
    try expectEqual(@as(u4, 8), Severity.err.priority());
    try expectEqual(@as(u4, 0), Severity.trace.priority());
    try expect(Severity.warning.priority() < Severity.critical.priority());

    // Blocking and tone.
    try expect(Severity.err.isBlocking());
    try expect(Severity.blocked.isBlocking());
    try expect(!Severity.critical.isBlocking());
    try expectEqual(Severity.Tone.negative, Severity.warning.tone());
    try expectEqual(Severity.Tone.positive, Severity.completed.tone());
    try expectEqual(Severity.Tone.neutral, Severity.help.tone());
}

test "structured codes follow the documented registry" {
    try expectEqualStrings("E.Syntax.Byte.003", Code.syntax_invalid_byte.structured());
    try expectEqualStrings("E.Syntax.Operator.003", Code.syntax_invalid_operator.structured());
    try expectEqualStrings("E.Syntax.Numeral.001", Code.syntax_incomplete_numeral.structured());
    try expectEqualStrings("E.Syntax.Token.032", Code.syntax_unterminated_construct.structured());
    try expectEqualStrings("E.Syntax.Concatenation.003", Code.syntax_invalid_concatenation.structured());
    try expectEqualStrings("E.Syntax.Grammar.003", Code.syntax_unexpected_token.structured());
    try expectEqualStrings("E.Syntax.Grammar.031", Code.syntax_unexpected_end.structured());
    try expectEqualStrings("E.Syntax.Keyword.003", Code.syntax_reserved_keyword.structured());
    try expectEqualStrings("W.Syntax.Numeral.033", Code.syntax_ambiguous_numeral.structured());
    try expectEqualStrings("E.Validation.Operator.002", Code.validation_operator_mismatch.structured());
    try expectEqualStrings("E.Profile.Feature.009", Code.profile_unsupported_feature.structured());
    try expectEqualStrings("E.Resource.Capacity.026", Code.resource_capacity_exhausted.structured());
    try expectEqualStrings("E.Resource.Memory.026", Code.resource_memory_exhausted.structured());
}

test "registry is coherent: unique identities, valid fields (R-DIAG-005)" {
    const codes = std.enums.values(Code);
    // Components are logical domains (WDP part 2), never source modules.
    for (std.enums.values(Component)) |component| {
        try expect(!std.mem.eql(u8, component.name(), "Lexer"));
        try expect(!std.mem.eql(u8, component.name(), "Parser"));
    }
    for (codes, 0..) |a, i| {
        const ia = a.info();
        // A primary never repeats its component (WDP part 3 naming rule).
        try expect(!std.mem.eql(u8, ia.component.name(), ia.primary.name()));

        // Sequence range: 001–999; 000 is reserved by WDP part 4.
        try expect(ia.sequence >= 1 and ia.sequence <= 999);

        // Component and primary must satisfy ^[A-Z][a-zA-Z0-9]{0,15}$.
        try expectValidWdpName(ia.component.name());
        try expectValidWdpName(ia.primary.name());

        // Summaries and hints are the user-facing payload; never empty.
        try expect(ia.summary.len > 0);
        try expect(ia.hint.len > 0);

        // Alias is SCREAMING_SNAKE_CASE starting with a letter.
        try expect(ia.alias.len > 0);
        try expect(std.ascii.isUpper(ia.alias[0]));
        for (ia.alias) |byte| {
            try expect(std.ascii.isUpper(byte) or std.ascii.isDigit(byte) or byte == '_');
        }

        // No two codes may share an identity or a compact ID.
        for (codes[i + 1 ..]) |b| {
            const ib = b.info();
            const same_identity = ia.severity == ib.severity and
                ia.component == ib.component and
                ia.primary == ib.primary and ia.sequence == ib.sequence;
            try expect(!same_identity);
            try expect(!std.mem.eql(u8, &a.compactId(), &b.compactId()));
        }
    }
}

test "namespace follows WDP part 7 conventions" {
    // Lowercase snake_case, starting with a letter, 1-16 chars.
    try expect(namespace.len >= 1 and namespace.len <= 16);
    try expect(std.ascii.isLower(namespace[0]));
    for (namespace) |byte| {
        try expect(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_');
    }
}

fn expectValidWdpName(name: []const u8) !void {
    try expect(name.len >= 1 and name.len <= 16);
    try expect(std.ascii.isUpper(name[0]));
    for (name) |byte| try expect(std.ascii.isAlphanumeric(byte));
}

test "compact IDs match the official WDP test vectors" {
    // wdp-specs/test-vectors/data/compact-ids.json
    try expectEqualStrings("V6a0B", &computeCompactId("E.AUTH.TOKEN.001"));
    try expectEqualStrings("KF52S", &computeCompactId("W.DATABASE.CONNECTION.027"));
    try expectEqualStrings("l3i4I", &computeCompactId("E.A.B.001"));
    try expectEqualStrings("fnOQk", &computeCompactId("T.PROFILER.TIMER.999"));
    try expectEqualStrings("Unzd9", &computeCompactId("I.HTTP2SERVER.REQUEST.001"));
    // Case-insensitive: display form hashes identically to canonical form.
    try expectEqualStrings("V6a0B", &computeCompactId("E.Auth.Token.001"));
}

test "namespace hashes match the official WDP test vectors" {
    // wdp-specs/test-vectors/data/namespaces.json
    try expectEqualStrings("05o5h", &computeNamespaceHash("auth_lib"));
    try expectEqualStrings("oFN7q", &computeNamespaceHash("user_service"));
    try expectEqualStrings("XPb13", &computeNamespaceHash("my_app"));
    try expectEqualStrings("ECjXV", &computeNamespaceHash("a"));
}

test "qualified compact ID is namespace_hash-code_hash (part 7 §5.2)" {
    const qualified = Code.syntax_unexpected_token.qualifiedCompactId();
    try expectEqual(@as(usize, 11), qualified.len);
    try expectEqualStrings(&namespace_hash, qualified[0..5]);
    try expectEqual(@as(u8, '-'), qualified[5]);
    const code_id = Code.syntax_unexpected_token.compactId();
    try expectEqualStrings(&code_id, qualified[6..11]);
}

test "fixed bag retains the first diagnostics and counts the rest" {
    var bag: FixedBag(2) = .{};
    const sink = bag.sink();

    const diagnostic: Diagnostic = .{
        .code = .syntax_unexpected_token,
        .span = .{ .start = .{ .byte_offset = 4, .line = 1, .byte_column = 5 }, .byte_len = 2 },
    };
    try sink.emit(diagnostic);
    try sink.emit(diagnostic);
    try sink.emit(diagnostic);

    try expectEqual(@as(usize, 2), bag.items().len);
    try expectEqual(@as(usize, 1), bag.omitted);
    try expectEqual(Code.syntax_unexpected_token, bag.items()[0].code);

    bag.reset();
    try expectEqual(@as(usize, 0), bag.items().len);
    try expectEqual(@as(usize, 0), bag.omitted);
}

test "zero-capacity bag only counts" {
    var bag: FixedBag(0) = .{};
    bag.push(.{ .code = .syntax_unexpected_end, .span = .{ .start = .start, .byte_len = 0 } });
    try expectEqual(@as(usize, 0), bag.items().len);
    try expectEqual(@as(usize, 1), bag.omitted);
}

test "direct sink receives diagnostics without retention" {
    const Counter = struct {
        count: usize = 0,
        fn emit(context: ?*anyopaque, diagnostic: Diagnostic) SinkError!void {
            _ = diagnostic;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    const sink: Sink = .{ .context = &counter, .emit_fn = Counter.emit };
    try sink.emit(.{ .code = .syntax_invalid_byte, .span = .{ .start = .start, .byte_len = 1 } });
    try sink.emit(.{ .code = .syntax_invalid_byte, .span = .{ .start = .start, .byte_len = 1 } });
    try expectEqual(@as(usize, 2), counter.count);
}

test "the discard sink accepts and drops everything" {
    try discard.emit(.{
        .code = .syntax_unexpected_end,
        .span = .{ .start = .start, .byte_len = 0 },
    });
}

test "failing sink propagates its error" {
    const Rejecting = struct {
        fn emit(context: ?*anyopaque, diagnostic: Diagnostic) SinkError!void {
            _ = context;
            _ = diagnostic;
            return error.DiagnosticSinkFailure;
        }
    };
    const sink: Sink = .{ .context = null, .emit_fn = Rejecting.emit };
    const result = sink.emit(.{ .code = .syntax_unexpected_end, .span = .{ .start = .start, .byte_len = 0 } });
    try std.testing.expectError(error.DiagnosticSinkFailure, result);
}
