//! Shared raw-byte scanner and metering tests.
//! root.zig exposes Token, Result and Lexer; scanner drivers stay package-internal.
//!
//! Recognizes the current subset: every DOT keyword (`graph` maps to the
//! `undigraph` kind at reading time, `digraph`, `strict`, `node`, `edge`, and the deferred
//! `subgraph`); bare ASCII, numeral, and quoted identifiers;
//! `{`, `}`, `;`, `:`, `[`, `]`, `=`, `,`; the
//! edge operators `--` and `->`; whitespace (space, tab, LF, CRLF, CR);
//! and comments (`//`, `/* ... */`, and `#` through the physical line end).
//! Comments are skipped without retention. See docs/SUPPORTED_SYNTAX.md for
//! the comment and physical-location compatibility policy.
//!
//! Guarantees:
//! - Spans borrow from the caller's source; no allocation ever (R-MEM-001).
//! - State is instance-owned (R-ROB-003); no OS or filesystem access.
//! - Every `next` call either consumes input or returns a terminal result
//!   (`eof` or a failure); the lexer cannot loop forever.
//! - Every keyword tokenizes, including keywords of deferred constructs:
//!   whether `subgraph` legally introduces a subgraph or sits in an illegal
//!   grammar position is the parser's decision, which the lexer cannot
//!   make. Only *lexical* deferred constructs — HTML/non-ASCII identifiers — are
//!   reported here as structured `profile_unsupported_feature` failures,
//!   distinct from invalid syntax (R-MOD-006).
//!   Detection stops at the introducer: neither the construct's body nor
//!   the remaining input is checked, so an unsupported result makes no
//!   whole-input validity claim.

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");

pub const Token = struct {
    tag: Tag,
    span: location.Span,

    pub const Tag = enum {
        keyword_graph,
        keyword_digraph,
        keyword_strict,
        keyword_subgraph,
        keyword_node,
        keyword_edge,
        identifier,
        edge_undirected,
        edge_directed,
        left_brace,
        right_brace,
        semicolon,
        colon,
        eof,
        left_bracket,
        right_bracket,
        equals,
        comma,
    };
};

/// The outcome of one `Lexer.next` call. Failures and EOF are latched:
/// repeated calls return the same terminal result without rescanning input.
pub const Result = union(enum) {
    token: Token,
    failure: diagnostic.Diagnostic,
};

/// Ordinary lexing and the internal metered fixture share one scanner.
/// Metering and audit counters are compile-time choices, not per-byte flags.
pub const Lexer = Scanner(false, false);

const Advance = struct {
    result: ?Result,
    work_used: usize,
};

/// Package-internal entry to the metered scanner; not re-exported by lexer.zig.
pub fn advanceBounded(comptime audited: bool, scanner: *Scanner(true, audited), budget: usize) Advance {
    return scanner.nextBounded(budget);
}

/// One resumable scan examination for the cancellable parser's safe points.
/// This may suspend an unmetered scanner; its ordinary next() remains immediate.
pub fn advanceOne(comptime metered: bool, comptime audited: bool, scanner: *Scanner(metered, audited)) Advance {
    return scanner.drive(true, 1);
}

pub fn Scanner(comptime metered: bool, comptime audited: bool) type {
    return struct {
        const Self = @This();
        const State = enum {
            trivia,
            slash,
            line_comment,
            block_comment,
            block_star,
            bare,
            non_ascii,
            dash,
            /// After `--`: one byte of lookahead so `-->` / `---` are one
            /// malformed-operator diagnostic instead of a stray byte.
            double_dash,
            leading_dot,
            integral,
            fraction,
            quoted,
            escape,
            // Transient microstep result, never persisted in self.state.
            ready,
        };
        const Trivia = enum { ordinary, after_quote, after_plus };
        const Terminal = enum { none, eof, invalid, operator, numeral, block, quote, concat, non_ascii, html };

        source: []const u8,
        tracker: location.Tracker = .{},
        anchor: location.Tracker = .{},
        opener: location.Tracker = .{},
        quote_end: location.Tracker = .{},
        keyword: u64 = 0,
        terminal_len: usize = 0,
        state: State = .trivia,
        trivia: Trivia = .ordinary,
        terminal: Terminal = .none,
        found: ?u8 = null,
        initial: u8 = 0,
        ready_tag: Token.Tag = .eof,
        /// Set when the token just produced is a numeral that runs directly
        /// into a letter or dot (`1e3`, `1.2.3`): the byte it runs into.
        /// The token stream is unchanged (Graphviz splits identically);
        /// `takeWarning` turns it into a `syntax_ambiguous_numeral`.
        ambiguous_numeral: ?u8 = null,
        source_frontier: if (metered) usize else void = if (metered) 0 else {},
        examinations: if (audited) usize else void = if (audited) 0 else {},

        pub fn init(source: []const u8) Self {
            var self: Self = .{ .source = source };
            // A leading UTF-8 byte order mark is not content; Graphviz's
            // scanner ignores it and so does this one. Advancing the
            // tracker keeps every later byte column honest (the BOM
            // occupies columns 1–3 of line 1).
            if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) self.tracker.advanceSlice(source[0..3]);
            return self;
        }

        /// Error-recovery support: clear a latched failure and continue
        /// scanning past it, so the parser can resynchronize at the next
        /// statement boundary. The parser owns the policy; this only makes
        /// resumption sound:
        /// - a malformed operator, numeral, or stray byte is skipped whole;
        /// - a bad `+` concatenation resumes at the byte that followed it,
        ///   which starts a valid token;
        /// - an unterminated quote or comment, or a failure inside a quoted
        ///   identifier, jumps to end of input — the rest of the source is
        ///   the construct's body, and re-scanning it would only cascade.
        /// Never valid for deferred-feature boundaries, which are not errors.
        pub fn resumeAfterFailure(self: *Self) void {
            const anchor = self.anchor.location.byte_offset;
            const start = self.opener.location.byte_offset;
            const target: usize = switch (self.terminal) {
                .block, .quote => self.source.len,
                .concat => start,
                .invalid, .operator, .numeral => if (start == anchor) start + self.terminal_len else self.source.len,
                .none, .eof, .non_ascii, .html => unreachable,
            };
            // `fail` left the tracker at the token anchor; walk forward so
            // line and column stay exact through whatever was skipped.
            std.debug.assert(self.tracker.location.byte_offset == anchor and target >= anchor);
            self.tracker.advanceSlice(self.source[anchor..target]);
            self.terminal = .none;
            self.terminal_len = 0;
            self.found = null;
            self.state = .trivia;
            self.trivia = .ordinary;
        }

        /// The warning attached to the most recently produced token, if any,
        /// clearing it. Warnings never change the token stream or the
        /// outcome; the parser forwards them to the diagnostic sink.
        pub fn takeWarning(self: *Self) ?diagnostic.Diagnostic {
            const byte = self.ambiguous_numeral orelse return null;
            self.ambiguous_numeral = null;
            return .{
                .code = .syntax_ambiguous_numeral,
                .span = .{ .start = self.anchor.location, .byte_len = self.here().byte_offset - self.anchor.location.byte_offset },
                .details = .{ .ambiguous_numeral = byte },
            };
        }

        pub fn next(self: *Self) Result {
            return self.drive(false, 0).result.?;
        }

        // Internal until the fixed-storage session is published.
        // null means yield, never EOF. EOF remains an ordinary terminal token.
        fn nextBounded(self: *Self, budget: usize) Advance {
            if (!metered) @compileError("bounded calls require the metered scanner");
            return self.drive(true, budget);
        }

        fn drive(self: *Self, comptime bounded: bool, budget: usize) Advance {
            if (self.terminal != .none) return .{ .result = self.terminalResult(), .work_used = 0 };
            var remaining = if (bounded) budget else {};
            scan_done: {
                // Ordinary next() never suspends: every nonterminal result
                // resets to trivia. Keep its hot entry statically known;
                // bounded scan calls (including cancellation safe points)
                // must resume the saved lexical state.
                scan: switch (if (bounded or metered) self.state else State.trivia) {
                    inline else => |state| {
                        while (true) {
                            if (bounded) {
                                if (remaining == 0) {
                                    self.state = state;
                                    return .{ .result = null, .work_used = budget };
                                }
                                remaining -= 1;
                            }
                            // Charge before examining one byte or EOF. Keep
                            // repeated states in their specialized inner loop.
                            const next_state = self.microstep(state);
                            if (next_state == .ready) break :scan_done;
                            if (next_state == state) continue;
                            continue :scan next_state;
                        }
                    },
                }
            }
            // Materialize once, outside the comptime-expanded state branches.
            // Per-branch Result temporaries inflated the generated stack frame.
            return .{ .result = self.readyResult(), .work_used = if (bounded) budget - remaining else 0 };
        }

        fn here(self: *const Self) location.Location {
            return self.tracker.location;
        }

        // Sole source-byte fetch site. Keyword classification uses cached bytes;
        // location tracking consumes this same value, never rescans a range.
        fn examine(self: *Self) ?u8 {
            if (audited) self.examinations += 1;
            const offset = self.here().byte_offset;
            if (offset == self.source.len) return null;
            if (metered) self.source_frontier = @max(self.source_frontier, offset + 1);
            return self.source[offset];
        }

        fn consume(self: *Self, byte: u8) void {
            self.tracker.advance(byte);
        }

        inline fn microstep(self: *Self, comptime state: State) State {
            var continuation = state;
            const byte = self.examine();
            switch (state) {
                .ready => unreachable,
                .trivia => {
                    if (byte) |b| switch (b) {
                        ' ', '\t', '\r', '\n' => self.consume(b),
                        '#' => {
                            self.consume(b);
                            continuation = .line_comment;
                        },
                        '/' => {
                            self.opener = self.tracker;
                            if (self.trivia == .ordinary) self.anchor = self.tracker;
                            self.consume(b);
                            continuation = .slash;
                        },
                        else => return self.afterTrivia(byte),
                    } else return self.afterTrivia(null);
                },
                .slash => {
                    if (byte == '/' or byte == '*') {
                        self.consume(byte.?);
                        continuation = if (byte == '/') .line_comment else .block_comment;
                    } else {
                        // The slash was lookahead, not trivia. Restore its
                        // position and classify the cached introducer.
                        self.tracker = self.opener;
                        return self.afterTrivia('/');
                    }
                },
                .line_comment => {
                    if (byte) |b| {
                        self.consume(b);
                        if (b == '\r' or b == '\n') continuation = .trivia;
                    } else return self.afterTrivia(null);
                },
                .block_comment, .block_star => {
                    const b = byte orelse {
                        // Malformed trailing trivia belongs to the next token
                        // unless '+' has committed us to another quoted part.
                        if (self.trivia == .after_quote) return self.finishQuoted();
                        return self.fail(.block, self.opener.location, 2, null);
                    };
                    const closed = state == .block_star and b == '/';
                    self.consume(b);
                    continuation = if (closed) .trivia else if (b == '*') .block_star else .block_comment;
                },
                .bare, .non_ascii => {
                    if (byte) |b| {
                        if (isIdentifierByte(b)) {
                            if (b >= 0x80) continuation = .non_ascii;
                            self.cacheKeyword(b);
                            self.consume(b);
                            return continuation;
                        }
                    }
                    if (state == .non_ascii)
                        return self.fail(.non_ascii, self.anchor.location, self.here().byte_offset - self.anchor.location.byte_offset, null);
                    return self.finish(keywordTag(self.keyword, self.here().byte_offset - self.anchor.location.byte_offset));
                },
                .dash => {
                    if (byte) |b| switch (b) {
                        '>' => {
                            self.consume(b);
                            return self.finish(.edge_directed);
                        },
                        '-' => {
                            self.consume(b);
                            continuation = .double_dash;
                            return continuation;
                        },
                        '0'...'9' => {
                            self.consume(b);
                            continuation = .integral;
                            return continuation;
                        },
                        '.' => {
                            self.consume(b);
                            continuation = .leading_dot;
                            return continuation;
                        },
                        else => {},
                    };
                    // `a - b`, `a - > b`, `-` at EOF: the operator is
                    // incomplete. Legal DOT bytes, wrong shape.
                    return self.fail(.operator, self.anchor.location, 1, byte);
                },
                .double_dash => {
                    if (byte == '>' or byte == '-') {
                        // `-->` / `---`: one over-long operator, reported
                        // whole so the fix ("write '->'") is obvious.
                        self.consume(byte.?);
                        return self.fail(.operator, self.anchor.location, 3, byte);
                    }
                    return self.finish(.edge_undirected);
                },
                .leading_dot => {
                    if (byte) |b| {
                        if (std.ascii.isDigit(b)) {
                            self.consume(b);
                            continuation = .fraction;
                            return continuation;
                        }
                    }
                    // `.` or `-.` without a digit: the numeral is incomplete.
                    const len = self.here().byte_offset - self.anchor.location.byte_offset;
                    return self.fail(.numeral, self.anchor.location, len, byte);
                },
                .integral, .fraction => {
                    if (byte) |b| {
                        if (std.ascii.isDigit(b)) {
                            self.consume(b);
                            return continuation;
                        }
                        if (state == .integral and b == '.') {
                            self.consume(b);
                            continuation = .fraction;
                            return continuation;
                        }
                        // Maximal munch ends the numeral here, exactly as
                        // Graphviz does — and Graphviz warns when the next
                        // byte could have been meant as part of it.
                        if (isIdentifierByte(b) or b == '.') self.ambiguous_numeral = b;
                    }
                    return self.finish(.identifier);
                },
                .quoted, .escape => {
                    const b = byte orelse return self.fail(.quote, self.opener.location, 1, null);
                    if (b == 0) return self.fail(.invalid, self.here(), 1, b);
                    self.consume(b);
                    if (state == .escape) {
                        // CR/LF tracking is incremental; an escaped CR followed
                        // by LF has the same raw span as consuming the pair.
                        continuation = .quoted;
                    } else switch (b) {
                        '\\' => continuation = .escape,
                        '"' => {
                            self.quote_end = self.tracker;
                            self.trivia = .after_quote;
                            continuation = .trivia;
                        },
                        else => {},
                    }
                },
            }
            return continuation;
        }

        inline fn afterTrivia(self: *Self, byte: ?u8) State {
            var continuation: State = .trivia;
            switch (self.trivia) {
                .after_quote => {
                    if (byte != '+') return self.finishQuoted();
                    self.consume('+');
                    self.trivia = .after_plus;
                    continuation = .trivia;
                    return continuation;
                },
                .after_plus => {
                    if (byte != '"') return self.fail(.concat, self.here(), if (byte == null) 0 else 1, byte);
                    self.opener = self.tracker;
                    self.consume('"');
                    continuation = .quoted;
                    return continuation;
                },
                .ordinary => {},
            }
            self.anchor = self.tracker;
            const b = byte orelse {
                self.terminal = .eof;
                return .ready;
            };
            self.initial = b;
            switch (b) {
                '{', '}', ';', ':', '[', ']', '=', ',' => {
                    self.consume(b);
                    return self.finish(switch (b) {
                        '{' => .left_brace,
                        '}' => .right_brace,
                        ';' => .semicolon,
                        ':' => .colon,
                        '[' => .left_bracket,
                        ']' => .right_bracket,
                        '=' => .equals,
                        ',' => .comma,
                        else => unreachable,
                    });
                },
                'A'...'Z', 'a'...'z', '_', 0x80...0xff => {
                    self.keyword = 0;
                    self.cacheKeyword(b);
                    continuation = if (b >= 0x80) .non_ascii else .bare;
                },
                '-' => continuation = .dash,
                '.' => continuation = .leading_dot,
                '0'...'9' => continuation = .integral,
                '"' => {
                    self.opener = self.tracker;
                    continuation = .quoted;
                },
                '<' => return self.fail(.html, self.here(), 1, null),
                else => return self.fail(.invalid, self.here(), 1, b),
            }
            self.consume(b);
            return continuation;
        }

        fn cacheKeyword(self: *Self, byte: u8) void {
            // Keywords contain only ASCII letters. Folding bit 5 also changes
            // '_', but it cannot turn a non-letter into a keyword letter.
            // Keep the last eight bytes; length independently rejects long IDs.
            self.keyword = (self.keyword << 8) | (byte | 0x20);
        }

        fn finishQuoted(self: *Self) State {
            // Trivia is examined speculatively but excluded from the raw span.
            // Revisit it once on the next token, never once per resumed call.
            self.tracker = self.quote_end;
            return self.finish(.identifier);
        }

        fn finish(self: *Self, tag: Token.Tag) State {
            self.state = .trivia;
            self.trivia = .ordinary;
            self.ready_tag = tag;
            return .ready;
        }

        fn readyResult(self: *const Self) Result {
            if (self.terminal != .none) return self.terminalResult();
            return .{ .token = .{
                .tag = self.ready_tag,
                .span = .{ .start = self.anchor.location, .byte_len = self.here().byte_offset - self.anchor.location.byte_offset },
            } };
        }

        fn fail(self: *Self, kind: Terminal, start: location.Location, len: usize, found: ?u8) State {
            self.terminal = kind;
            self.opener.location = start;
            self.terminal_len = len;
            self.found = found;
            self.tracker = self.anchor;
            return .ready;
        }

        fn terminalResult(self: *const Self) Result {
            if (self.terminal == .eof) return .{ .token = .{
                .tag = .eof,
                .span = .{ .start = self.here(), .byte_len = 0 },
            } };
            return .{ .failure = .{
                .code = switch (self.terminal) {
                    .invalid => .syntax_invalid_byte,
                    .operator => .syntax_invalid_operator,
                    .numeral => .syntax_incomplete_numeral,
                    .block, .quote => .syntax_unterminated_construct,
                    .concat => .syntax_invalid_concatenation,
                    .non_ascii, .html => .profile_unsupported_feature,
                    .none, .eof => unreachable,
                },
                .span = .{ .start = self.opener.location, .byte_len = self.terminal_len },
                .details = switch (self.terminal) {
                    .invalid => .{ .invalid_byte = self.found.? },
                    .operator => .{ .invalid_operator = self.found },
                    .numeral => .{ .incomplete_numeral = self.found },
                    .block => .{ .unterminated = .block_comment },
                    .quote => .{ .unterminated = .quoted_identifier },
                    .concat => .{ .expected_quote = self.found },
                    .non_ascii => .{ .unsupported_feature = .non_ascii_identifier },
                    .html => .{ .unsupported_feature = .html_identifier },
                    .none, .eof => unreachable,
                },
            } };
        }
    };
}

fn isIdentifierByte(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', 0x80...0xff => true,
        else => false,
    };
}

// No uncharged source access: retain up to eight folded bytes during
// scanning, then compare cached fixed-size values. Long words cannot be keywords.
fn keywordTag(word: u64, len: usize) Token.Tag {
    if (len > 8) return .identifier;
    const keywords = .{
        .{ "graph", Token.Tag.keyword_graph },   .{ "digraph", Token.Tag.keyword_digraph },
        .{ "strict", Token.Tag.keyword_strict }, .{ "subgraph", Token.Tag.keyword_subgraph },
        .{ "node", Token.Tag.keyword_node },     .{ "edge", Token.Tag.keyword_edge },
    };
    inline for (keywords) |entry| {
        const encoded = comptime blk: {
            var value: u64 = 0;
            for (entry[0]) |byte| value = (value << 8) | byte;
            break :blk value;
        };
        if (len == entry[0].len and word == encoded) return entry[1];
    }
    return .identifier;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "ordinary token completion restores the known entry state" {
    var scanner = Lexer.init("graph {a[x=1] b--c; \"q\" + \"r\" /*tail*/}");
    while (true) {
        const result = scanner.next();
        try expect(result == .token);
        if (result.token.tag == .eof) break;
        try expectEqual(Lexer.State.trivia, scanner.state);
        try expectEqual(Lexer.Trivia.ordinary, scanner.trivia);
    }
}

test "unbounded next on a metered scanner resumes saved continuation" {
    const sources = [_][]const u8{
        "/*pre*/ graph {a--b[x=-.5]}",
        "\"a\" /*join*/ + \"b\" tail",
        "\"a\\\"b\" //tail\r\n z",
        "/*unterminated",
        "\"a\" + x",
        "a\xff",
    };
    for (sources) |source| for (0..source.len + 3) |budget| {
        var reference = Lexer.init(source);
        var scanner = AuditedLexer.init(source);
        const first = scanner.nextBounded(budget);
        var result = first.result orelse scanner.next();
        while (true) {
            try std.testing.expectEqualDeep(reference.next(), result);
            if (result == .failure or result.token.tag == .eof) break;
            result = scanner.next();
        }
        try std.testing.expectEqualDeep(result, scanner.next());
    };
}

test "one-credit calls expose every lexical continuation and trivia mode" {
    var states = std.EnumSet(AuditedLexer.State).initEmpty();
    var trivia_modes = std.EnumSet(AuditedLexer.Trivia).initEmpty();
    for ([_][]const u8{
        " \r\n#x\r//y\n/*z**/a;",        "a\xff;", "-1.2 -.5 .1 1->2 3--4 5-->6",
        "\"a\\\"b\" /*glue*/ + \"c\" x",
    }) |source| {
        var lexer = AuditedLexer.init(source);
        while (true) {
            states.insert(lexer.state);
            trivia_modes.insert(lexer.trivia);
            const report = lexer.nextBounded(1);
            if (report.result) |result| {
                if (result == .failure or result.token.tag == .eof) break;
            }
        }
    }
    var persistent_states = std.EnumSet(AuditedLexer.State).initFull();
    persistent_states.remove(.ready);
    try expectEqual(persistent_states, states);
    try expectEqual(std.EnumSet(AuditedLexer.Trivia).initFull(), trivia_modes);
}

test "random byte streams preserve bounded partition equivalence" {
    const alphabet = "agN1.-/>\"*+#\\\r\n\t\x00\xff";
    var data: [96]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x626f756e646564);
    for (0..2000) |_| {
        const len = random.random().uintLessThan(usize, data.len + 1);
        for (data[0..len]) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        const whole = try checkPartition(data[0..len], &.{std.math.maxInt(usize)});
        try expectEqual(whole, try checkPartition(data[0..len], &.{ 0, 1, 2, 0, 11 }));
    }
}

const AuditedLexer = Scanner(true, true);

fn checkPartition(source: []const u8, budgets: []const usize) !usize {
    var reference = Lexer.init(source);
    var bounded = AuditedLexer.init(source);
    var calls: usize = 0;
    var total: usize = 0;
    var frontier: usize = 0;
    while (true) {
        const budget = budgets[calls % budgets.len];
        calls += 1;
        const before = bounded.examinations;
        const report = bounded.nextBounded(budget);
        try expect(bounded.state != .ready);
        try expect(report.work_used <= budget);
        try expectEqual(report.work_used, bounded.examinations - before);
        try expect(bounded.source_frontier >= frontier);
        try expect(bounded.source_frontier <= source.len);
        frontier = bounded.source_frontier;
        total += report.work_used;
        // A conservative linear bound catches token-prefix restarts on yield.
        try expect(total <= 4 * source.len + 16);
        if (report.result) |result| {
            try expectEqual(reference.next(), result);
            try expectEqual(reference.tracker, bounded.tracker);
            if (result == .failure or result.token.tag == .eof) {
                const terminal_reads = bounded.examinations;
                inline for (.{ 0, 1, std.math.maxInt(usize) }) |after| {
                    const again = bounded.nextBounded(after);
                    try expectEqual(result, again.result.?);
                    try expectEqual(@as(usize, 0), again.work_used);
                    try expectEqual(terminal_reads, bounded.examinations);
                }
                return total;
            }
        } else {
            try expectEqual(budget, report.work_used);
        }
    }
}

test "metered scanner partitions preserve tokens diagnostics positions and total work" {
    const cases = [_][]const u8{
        "",                                            " \t\r\n\r\n",                                                  "graph { a -- b; x [label=\"hi\"]; }",
        "DiGraph STRICT SubGraph Node EDGE Graphical", "0 -0 123 -12 .5 -.5 12. -12.30 000.00 1->-2 3--4 1e3 1.2.3",   "-",
        "-->",                                         "---",                                                          "\xEF\xBB\xBFgraph {",
        "-.",                                          "-.x",                                                          ".",
        ".x",                                          "+1",                                                           "/x",
        "/",                                           "// comment\r\n# inline\ra /* ** / * */ -- b",                  "/* unterminated **",
        "a\xff_more",                                  "\xff\x80tail",                                                 "<",
        ":",                                           "\"a\\\"b\\\\c\\\r\nz\" /*glue*/ + // line\r\n\"d\" /*end*/ x", "\"a\"\"b\"",
        "\"a\"+}",                                     "\"a\"+",                                                       "\"a\"+/*",
        "\"a\" /*",                                    "\"a\"+ /",                                                     "\"a\" /x",
        "\"a\"+\"b\\",                                 "\"a\x00b\"",                                                   "\"a\\\x00b\"",
    };
    for (cases) |source| {
        // Truncate at every byte, including delimiters and CR/LF pairs.
        for (0..source.len + 1) |end| {
            const input = source[0..end];
            const all = try checkPartition(input, &.{std.math.maxInt(usize)});
            try expectEqual(all, try checkPartition(input, &.{1}));
            try expectEqual(all, try checkPartition(input, &.{2}));
            try expectEqual(all, try checkPartition(input, &.{ 0, 1, 0, 7, 2, 0, 3 }));
        }
    }
}

test "zero credits leave every nonterminal continuation unchanged" {
    var lexer = AuditedLexer.init("\"a\\\r\nb\" /*glue*/ + \"c\"; /*tail*/");
    while (true) {
        const before = lexer;
        const zero = lexer.nextBounded(0);
        try expectEqual(@as(?Result, null), zero.result);
        try expectEqual(@as(usize, 0), zero.work_used);
        try expectEqual(before, lexer);
        const one = lexer.nextBounded(1);
        try expectEqual(@as(usize, 1), one.work_used);
        if (one.result) |result| {
            if (result == .failure or result.token.tag == .eof) break;
        }
    }
}

test "frontier includes speculative trivia without claiming it in the token" {
    var lexer = AuditedLexer.init("\"a\" /* trailing */ x");
    var result: ?Result = null;
    while (result == null) result = lexer.nextBounded(1).result;
    try expectEqualStrings("\"a\"", result.?.token.span.slice(lexer.source));
    try expectEqual(@as(usize, 3), lexer.here().byte_offset);
    try expectEqual(lexer.source.len, lexer.source_frontier);
    const frontier = lexer.source_frontier;
    while (true) {
        const next = lexer.nextBounded(1);
        try expectEqual(frontier, lexer.source_frontier);
        if (next.result) |ready| {
            if (ready.token.tag == .eof) break;
        }
    }
}

test "megabyte lexical runs resume in linear work with constant state" {
    const size = 1024 * 1024;
    const buffer = try std.testing.allocator.alloc(u8, size + 32);
    defer std.testing.allocator.free(buffer);
    const cases = .{
        .{ "", ' ', "x" },
        .{ "", 'a', ";" },
        .{ "", '9', ";" },
        .{ "\xff", 'a', ";" },
        .{ "//", 'x', "\r\nx" },
        .{ "#", 'x', "\rx" },
        .{ "/*", '*', "/x" },
        .{ "/*", 'x', "" },
        .{ "\"", 'x', "\";" },
        .{ "\"", '\\', "\";" },
        .{ "\"", 'x', "" },
        .{ "\"a\" /*", 'x', "*/ + \"b\";" },
        .{ "\"a\" /*", 'x', "*/ x" },
        .{ "\"a\" /*", 'x', "" },
    };
    inline for (cases) |case| {
        @memcpy(buffer[0..case[0].len], case[0]);
        @memset(buffer[case[0].len..][0..size], case[1]);
        @memcpy(buffer[case[0].len + size ..][0..case[2].len], case[2]);
        const source = buffer[0 .. case[0].len + size + case[2].len];
        const one = try checkPartition(source, &.{1});
        try expectEqual(one, try checkPartition(source, &.{ 0, 17, 4096, 1 }));
    }
}

test "metering storage and source-examination instrumentation compile out" {
    try expectEqual(void, @FieldType(Lexer, "source_frontier"));
    try expectEqual(void, @FieldType(Lexer, "examinations"));
    try expectEqual(void, @FieldType(Scanner(true, false), "examinations"));
    try expectEqual(usize, @FieldType(Scanner(true, false), "source_frontier"));
    try expectEqual(@sizeOf(Lexer) + @sizeOf(usize), @sizeOf(Scanner(true, false)));
    // Fixed native-state guard, independent of source size; no allocation in
    // either scanner. Test buffers above are caller-owned fixture storage.
    try expect(@sizeOf(Lexer) <= 176);
}

fn expectToken(lexer: *Lexer, tag: Token.Tag, text: []const u8) !void {
    const result = lexer.next();
    try expect(result == .token);
    try expectEqual(tag, result.token.tag);
    try expectEqualStrings(text, result.token.span.slice(lexer.source));
}

fn expectUnsupported(lexer: *Lexer, feature: diagnostic.Feature) !void {
    const result = lexer.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Code.profile_unsupported_feature, result.failure.code);
    try expectEqual(feature, result.failure.details.unsupported_feature);
}

fn expectInvalidByte(lexer: *Lexer, byte: u8) !void {
    const result = lexer.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Code.syntax_invalid_byte, result.failure.code);
    try expectEqual(byte, result.failure.details.invalid_byte);
}

fn expectInvalidOperator(lexer: *Lexer, text: []const u8, found: ?u8) !void {
    const result = lexer.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Code.syntax_invalid_operator, result.failure.code);
    try expectEqual(found, result.failure.details.invalid_operator);
    try expectEqualStrings(text, result.failure.span.slice(lexer.source));
}

fn expectIncompleteNumeral(lexer: *Lexer, text: []const u8, found: ?u8) !void {
    const result = lexer.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Code.syntax_incomplete_numeral, result.failure.code);
    try expectEqual(found, result.failure.details.incomplete_numeral);
    try expectEqualStrings(text, result.failure.span.slice(lexer.source));
}

test "empty input yields eof forever" {
    var lexer = Lexer.init("");
    try expectToken(&lexer, .eof, "");
    try expectToken(&lexer, .eof, "");
    try expectEqual(location.Location.start, lexer.here());
}

test "comments separate tokens without joining identifiers or operators" {
    var lexer = Lexer.init("/* header */graph// line\n{a/**/b/* /* not nested */--c;}// eof");
    try expectToken(&lexer, .keyword_graph, "graph");
    try expectToken(&lexer, .left_brace, "{");
    try expectToken(&lexer, .identifier, "a");
    try expectToken(&lexer, .identifier, "b");
    try expectToken(&lexer, .edge_undirected, "--");
    try expectToken(&lexer, .identifier, "c");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .right_brace, "}");
    try expectToken(&lexer, .eof, "");
    try expectToken(&lexer, .eof, "");

    var split_operator = Lexer.init("-/**/-");
    try expectInvalidOperator(&split_operator, "-", '/');
    var split_keyword = Lexer.init("gr/**/aph");
    try expectToken(&split_keyword, .identifier, "gr");
    try expectToken(&split_keyword, .identifier, "aph");
}

test "line comments accept EOF and all physical line endings" {
    inline for (.{ "//", "#" }) |prefix| {
        var eof = Lexer.init(prefix ++ " opaque /* \" @ \x00\xff");
        try expectToken(&eof, .eof, "");
        inline for (.{ "\n", "\r\n", "\r" }) |newline| {
            const source = prefix ++ " ignored" ++ newline ++ "x";
            var lexer = Lexer.init(source);
            const token = lexer.next().token;
            try expectEqual(Token.Tag.identifier, token.tag);
            try expectEqual(location.Location{
                .byte_offset = source.len - 1,
                .line = 2,
                .byte_column = 1,
            }, token.span.start);
        }
    }
}

test "hash comments match Graphviz token-boundary behavior without remapping lines" {
    var lexer = Lexer.init("  # 42 \"elsewhere.dot\"\na# inline\nb");
    const a = lexer.next().token;
    try expectEqualStrings("a", a.span.slice(lexer.source));
    try expectEqual(@as(usize, 2), a.span.start.line);
    const b = lexer.next().token;
    try expectEqualStrings("b", b.span.slice(lexer.source));
    try expectEqual(@as(usize, 3), b.span.start.line);
}

test "block comments preserve mixed physical positions and opaque contents" {
    const source = "/*\r\n\r\n\n# // \" \x00\xff*/x";
    var lexer = Lexer.init(source);
    const token = lexer.next().token;
    try expectEqualStrings("x", token.span.slice(source));
    try expectEqual(location.locate(source, source.len - 1), token.span.start);
    try expectEqual(@as(usize, 4), token.span.start.line);
}

test "block comment truncation reports the opener on repeated calls" {
    const body = "/* body **/";
    for (2..body.len) |end| {
        var lexer = Lexer.init(body[0..end]);
        const first = lexer.next();
        try expect(first == .failure);
        try expectEqual(diagnostic.Code.syntax_unterminated_construct, first.failure.code);
        try expectEqual(location.Location.start, first.failure.span.start);
        try expectEqual(@as(usize, 2), first.failure.span.byte_len);
        try expectEqual(diagnostic.UnterminatedConstruct.block_comment, first.failure.details.unterminated);
        try expectEqual(first, lexer.next());
        try expectEqual(first, lexer.next());
    }
    var complete = Lexer.init(body);
    try expectToken(&complete, .eof, "");
    var slash = Lexer.init("/");
    try expectInvalidByte(&slash, '/');
    var ordinary_slash = Lexer.init("/x");
    try expectInvalidByte(&ordinary_slash, '/');
}

test "unterminated comments preserve nonzero physical locations on repeated calls" {
    inline for (.{ "\n", "\r\n", "\r" }) |newline| {
        const source = "// ignored" ++ newline ++ "  /* x";
        var lexer = Lexer.init(source);
        const expected = location.locate(source, source.len - 4);
        const first = lexer.next();
        try expect(first == .failure);
        try expectEqual(expected, first.failure.span.start);
        try expectEqual(@as(usize, 2), first.failure.span.start.line);
        try expectEqual(@as(usize, 3), first.failure.span.start.byte_column);
        try expectEqual(first, lexer.next());
        try expectEqual(expected, lexer.here());
    }
}

test "each milestone token lexes on its own" {
    inline for (.{
        .{ "graph", Token.Tag.keyword_graph },
        .{ "digraph", Token.Tag.keyword_digraph },
        .{ "strict", Token.Tag.keyword_strict },
        .{ "abc", Token.Tag.identifier },
        .{ "--", Token.Tag.edge_undirected },
        .{ "->", Token.Tag.edge_directed },
        .{ "{", Token.Tag.left_brace },
        .{ "}", Token.Tag.right_brace },
        .{ ";", Token.Tag.semicolon },
    }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectToken(&lexer, case[1], case[0]);
        try expectToken(&lexer, .eof, "");
    }
}

test "keyword boundary: graphical is one identifier, not graph + ical" {
    var lexer = Lexer.init("graphical");
    try expectToken(&lexer, .identifier, "graphical");
    try expectToken(&lexer, .eof, "");

    var digraphs = Lexer.init("digraphs stricter");
    try expectToken(&digraphs, .identifier, "digraphs");
    try expectToken(&digraphs, .identifier, "stricter");
}

test "DOT keywords are case-independent" {
    var upper = Lexer.init("GRAPH");
    try expectToken(&upper, .keyword_graph, "GRAPH");

    var mixed = Lexer.init("Graph");
    try expectToken(&mixed, .keyword_graph, "Graph");

    var directed = Lexer.init("DiGraph STRICT");
    try expectToken(&directed, .keyword_digraph, "DiGraph");
    try expectToken(&directed, .keyword_strict, "STRICT");

    var deferred = Lexer.init("SubGraph Node EDGE");
    try expectToken(&deferred, .keyword_subgraph, "SubGraph");
    try expectToken(&deferred, .keyword_node, "Node");
    try expectToken(&deferred, .keyword_edge, "EDGE");
}

test "identifiers may contain underscores and digits after the first byte" {
    var lexer = Lexer.init("_a1B x9_");
    try expectToken(&lexer, .identifier, "_a1B");
    try expectToken(&lexer, .identifier, "x9_");
    try expectToken(&lexer, .eof, "");
}

test "every whitespace and newline combination separates tokens" {
    var lexer = Lexer.init("graph\t{\r\na ;\rb\n}  ");
    try expectToken(&lexer, .keyword_graph, "graph");
    try expectToken(&lexer, .left_brace, "{");

    const a = lexer.next();
    try expectEqual(Token.Tag.identifier, a.token.tag);
    try expectEqual(@as(usize, 2), a.token.span.start.line);
    try expectEqual(@as(usize, 1), a.token.span.start.byte_column);

    try expectToken(&lexer, .semicolon, ";");

    const b = lexer.next();
    try expectEqual(Token.Tag.identifier, b.token.tag);
    try expectEqual(@as(usize, 3), b.token.span.start.line);
    try expectEqual(@as(usize, 1), b.token.span.start.byte_column);

    const brace = lexer.next();
    try expectEqual(Token.Tag.right_brace, brace.token.tag);
    try expectEqual(@as(usize, 4), brace.token.span.start.line);

    try expectToken(&lexer, .eof, "");
}

test "truncated operators fail; keyword prefixes are identifiers" {
    // '-' alone, or followed by anything but '-', '>', digit, '.', is a
    // malformed operator: legal DOT bytes in the wrong shape, reported as
    // such (never as an invalid byte) with the byte that broke it.
    var lone = Lexer.init("-");
    try expectInvalidOperator(&lone, "-", null);

    var stray = Lexer.init("-x");
    try expectInvalidOperator(&stray, "-", 'x');

    var spaced = Lexer.init("a - > b");
    try expectToken(&spaced, .identifier, "a");
    try expectInvalidOperator(&spaced, "-", ' ');

    // Over-long operators are one diagnostic covering the whole run.
    var long = Lexer.init("a --> b");
    try expectToken(&long, .identifier, "a");
    try expectInvalidOperator(&long, "-->", '>');
    var triple = Lexer.init("---");
    try expectInvalidOperator(&triple, "---", '-');
    // `--` directly followed by an identifier stays a valid operator.
    var tight = Lexer.init("a--b");
    try expectToken(&tight, .identifier, "a");
    try expectToken(&tight, .edge_undirected, "--");
    try expectToken(&tight, .identifier, "b");

    // Every proper prefix of "graph" is just a shorter identifier.
    inline for (.{ "g", "gr", "gra", "grap" }) |prefix| {
        var lexer = Lexer.init(prefix);
        try expectToken(&lexer, .identifier, prefix);
        try expectToken(&lexer, .eof, "");
    }
}

test "invalid leading bytes are reported with the byte itself" {
    inline for (.{ "@", "\x01", "\\", ")", "/x", "/" }) |source| {
        var lexer = Lexer.init(source);
        try expectInvalidByte(&lexer, source[0]);
    }
}

test "a dot without a following digit is an incomplete numeral" {
    // DOT numerals require a digit after a leading '.'. The span covers the
    // numeral prefix and the payload names the byte found instead.
    inline for (.{ .{ ".", null }, .{ ".x", 'x' }, .{ ". ", ' ' } }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectIncompleteNumeral(&lexer, ".", case[1]);
    }
    // Same lookahead through a leading '-': `-.` needs a digit after '.'.
    inline for (.{ .{ "-.", null }, .{ "-.x", 'x' } }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectIncompleteNumeral(&lexer, "-.", case[1]);
    }
}

test "numerals running into letters or dots warn without changing tokens" {
    // Graphviz: "syntax ambiguity - badly delimited number ... splits into
    // two tokens". Same split here, same warning, parse continues.
    var lexer = Lexer.init("1e3 1.2.3 12.x 7 8_ .5e 9 ");
    try expectToken(&lexer, .identifier, "1");
    const first = lexer.takeWarning().?;
    try expectEqual(diagnostic.Code.syntax_ambiguous_numeral, first.code);
    try expectEqual(@as(u8, 'e'), first.details.ambiguous_numeral);
    try expectEqualStrings("1", first.span.slice(lexer.source));
    try expectEqual(@as(?diagnostic.Diagnostic, null), lexer.takeWarning());
    try expectToken(&lexer, .identifier, "e3");
    try expectEqual(@as(?diagnostic.Diagnostic, null), lexer.takeWarning());
    try expectToken(&lexer, .identifier, "1.2");
    try expectEqual(@as(u8, '.'), lexer.takeWarning().?.details.ambiguous_numeral);
    try expectToken(&lexer, .identifier, ".3");
    try expectEqual(@as(?diagnostic.Diagnostic, null), lexer.takeWarning());
    try expectToken(&lexer, .identifier, "12.");
    try expectEqual(@as(u8, 'x'), lexer.takeWarning().?.details.ambiguous_numeral);
    try expectToken(&lexer, .identifier, "x");
    try expectToken(&lexer, .identifier, "7");
    try expectEqual(@as(?diagnostic.Diagnostic, null), lexer.takeWarning());
    try expectToken(&lexer, .identifier, "8");
    try expectEqual(@as(u8, '_'), lexer.takeWarning().?.details.ambiguous_numeral);
    try expectToken(&lexer, .identifier, "_");
    try expectToken(&lexer, .identifier, ".5");
    try expectEqual(@as(u8, 'e'), lexer.takeWarning().?.details.ambiguous_numeral);
    try expectToken(&lexer, .identifier, "e");
    try expectToken(&lexer, .identifier, "9");
    try expectEqual(@as(?diagnostic.Diagnostic, null), lexer.takeWarning());
    try expectToken(&lexer, .eof, "");
}

test "a leading UTF-8 byte order mark is skipped, keeping byte columns honest" {
    var lexer = Lexer.init("\xEF\xBB\xBFgraph {");
    const result = lexer.next();
    try expect(result == .token);
    try expectEqual(Token.Tag.keyword_graph, result.token.tag);
    try expectEqual(@as(usize, 3), result.token.span.start.byte_offset);
    try expectEqual(@as(usize, 1), result.token.span.start.line);
    try expectEqual(@as(usize, 4), result.token.span.start.byte_column);
    try expectToken(&lexer, .left_brace, "{");
    // Only at the very start: elsewhere the bytes are a non-ASCII run.
    var inner = Lexer.init("a \xEF\xBB\xBFb");
    try expectToken(&inner, .identifier, "a");
    try expectUnsupported(&inner, .non_ascii_identifier);
    // A BOM alone is an empty document.
    var alone = Lexer.init("\xEF\xBB\xBF");
    try expectToken(&alone, .eof, "");
}

test "non-ASCII bytes are the deferred identifier range, not invalid input" {
    // DOT unquoted identifiers may use bytes \200-\377.
    var leading = Lexer.init("\xC3\xA9");
    try expectUnsupported(&leading, .non_ascii_identifier);

    // One identifier running into the non-ASCII range is reported whole,
    // not split into an ASCII identifier plus an error — and the span
    // covers the complete run, not just the first non-ASCII byte.
    var mixed = Lexer.init("caf\xC3\xA9 x");
    const result = mixed.next();
    try expect(result == .failure);
    try expectEqual(diagnostic.Feature.non_ascii_identifier, result.failure.details.unsupported_feature);
    try expectEqual(@as(usize, 0), result.failure.span.start.byte_offset);
    try expectEqual(@as(usize, 5), result.failure.span.byte_len);

    // A leading multi-byte identifier is spanned whole as well.
    var leading_run = Lexer.init("\xC3\xA9tat;");
    const leading_result = leading_run.next();
    try expect(leading_result == .failure);
    try expectEqual(@as(usize, 5), leading_result.failure.span.byte_len);

    // Control bytes below 0x80 remain invalid, as before.
    var control = Lexer.init("\x7f");
    try expectInvalidByte(&control, 0x7f);
}

test "recognized lexical deferred features are unsupported, not invalid" {
    // Keyword-introduced subgraphs are the parser's call; keywords tokenize.
    inline for (.{
        .{ "<html>", diagnostic.Feature.html_identifier },
    }) |case| {
        var lexer = Lexer.init(case[0]);
        try expectUnsupported(&lexer, case[1]);
    }
}

test "numerals are maximal textual IDs and preserve adjacent operators" {
    inline for (.{ "0", "-0", "123", "-12", ".5", "-.5", "12.", "-12.30", "000.00" }) |raw| {
        var lexer = Lexer.init(raw);
        try expectToken(&lexer, .identifier, raw);
        try expectToken(&lexer, .eof, "");
    }
    var lexer = Lexer.init("1->-2 3--4 1e3 1.2.3");
    try expectToken(&lexer, .identifier, "1");
    try expectToken(&lexer, .edge_directed, "->");
    try expectToken(&lexer, .identifier, "-2");
    try expectToken(&lexer, .identifier, "3");
    try expectToken(&lexer, .edge_undirected, "--");
    try expectToken(&lexer, .identifier, "4");
    try expectToken(&lexer, .identifier, "1");
    try expectToken(&lexer, .identifier, "e3");
    try expectToken(&lexer, .identifier, "1.2");
    try expectToken(&lexer, .identifier, ".3");
    try expectToken(&lexer, .eof, "");
    var positive = Lexer.init("+1");
    try expectInvalidByte(&positive, '+');
}

test "quoted identifiers include concatenations but exclude trailing trivia" {
    const raw = "\"gr\" /* \" */ + // \"\r\n \"aph\"";
    var lexer = Lexer.init(raw ++ " /* trailing */ -> \"b\"");
    try expectToken(&lexer, .identifier, raw);
    try expectEqual(@as(usize, raw.len), lexer.here().byte_offset);
    try expectToken(&lexer, .edge_directed, "->");
    try expectToken(&lexer, .identifier, "\"b\"");
    try expectToken(&lexer, .eof, "");
    var adjacent = Lexer.init("\"a\"\"b\"");
    try expectToken(&adjacent, .identifier, "\"a\"");
    try expectToken(&adjacent, .identifier, "\"b\"");
}

test "quoted content preserves physical positions and accepts opaque non-NUL bytes" {
    inline for (.{ "\n", "\r\n", "\r" }) |newline| {
        const raw = "\"a\\" ++ newline ++ "b" ++ newline ++ "// /* # \x01\x7f\xff\"";
        var lexer = Lexer.init(raw ++ " x");
        try expectToken(&lexer, .identifier, raw);
        const next = lexer.next().token;
        try expectEqual(location.locate(lexer.source, raw.len + 1), next.span.start);
        try expectEqual(@as(usize, 3), next.span.start.line);
    }
    inline for (.{ "\"a\x00b\"", "\"a\\\x00b\"" }) |raw| {
        var lexer = Lexer.init(raw);
        const failure = lexer.next().failure;
        try expectEqual(diagnostic.Code.syntax_invalid_byte, failure.code);
        try expectEqual(@as(u8, 0), failure.details.invalid_byte);
        try expectEqualStrings("\x00", failure.span.slice(raw));
        try expectEqual(failure, lexer.next().failure);
    }
}

test "unterminated strings report their own opener including later concatenated parts" {
    const raw = "\"a\\\"b\\\\c\"";
    for (1..raw.len) |end| {
        var lexer = Lexer.init(raw[0..end]);
        const result = lexer.next();
        try expect(result == .failure);
        try expectEqual(diagnostic.UnterminatedConstruct.quoted_identifier, result.failure.details.unterminated);
        try expectEqual(@as(usize, 0), result.failure.span.start.byte_offset);
        try expectEqual(@as(usize, 1), result.failure.span.byte_len);
        try expectEqual(result, lexer.next());
    }
    var lexer = Lexer.init("\"a\" +\r\n \"bc");
    const first = lexer.next().failure;
    try expectEqual(@as(usize, 8), first.span.start.byte_offset);
    try expectEqual(@as(usize, 2), first.span.start.line);
    try expectEqual(@as(usize, 2), first.span.start.byte_column);
    try expectEqual(first, lexer.next().failure);
}

test "malformed concatenation distinguishes expected quote from unclosed comment" {
    inline for (.{ "\"a\"+", "\"a\"+b", "\"a\"+1", "\"a\"+}", "\"a\"++\"b\"", "\"a\"+<html>" }) |raw| {
        var lexer = Lexer.init(raw);
        const first = lexer.next().failure;
        try expectEqual(diagnostic.Code.syntax_invalid_concatenation, first.code);
        try expectEqual(@as(usize, 4), first.span.start.byte_offset);
        try expectEqual(if (raw.len == 4) @as(?u8, null) else raw[4], first.details.expected_quote);
        try expectEqual(first, lexer.next().failure);
    }
    var after_plus = Lexer.init("\"a\"+/*");
    const failure = after_plus.next().failure;
    try expectEqual(diagnostic.UnterminatedConstruct.block_comment, failure.details.unterminated);
    try expectEqual(@as(usize, 4), failure.span.start.byte_offset);
    var trailing = Lexer.init("\"a\" /*");
    try expectToken(&trailing, .identifier, "\"a\"");
    try expectEqual(diagnostic.UnterminatedConstruct.block_comment, trailing.next().failure.details.unterminated);
}

test "failures are terminal and idempotent" {
    var lexer = Lexer.init("graph @ x");
    try expectToken(&lexer, .keyword_graph, "graph");

    const first = lexer.next();
    const second = lexer.next();
    try expect(first == .failure);
    try expect(second == .failure);
    try expectEqual(first.failure.code, second.failure.code);
    try expectEqual(first.failure.span.start, second.failure.span.start);
    try expectEqual(
        first.failure.details.invalid_byte,
        second.failure.details.invalid_byte,
    );
}

test "full milestone document produces the expected token stream" {
    const source = "graph {\n    a;\n    b;\n    a -- b;\n}\n";
    var lexer = Lexer.init(source);

    try expectToken(&lexer, .keyword_graph, "graph");
    try expectToken(&lexer, .left_brace, "{");
    try expectToken(&lexer, .identifier, "a");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .identifier, "b");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .identifier, "a");

    const op = lexer.next();
    try expectEqual(Token.Tag.edge_undirected, op.token.tag);
    try expectEqual(@as(usize, 4), op.token.span.start.line);
    try expectEqual(@as(usize, 7), op.token.span.start.byte_column);

    try expectToken(&lexer, .identifier, "b");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .right_brace, "}");
    try expectToken(&lexer, .eof, "");
}

test "colon punctuation stays separate from quoted content and trivia" {
    var lexer = Lexer.init("\"a:b\" :/**/p:n");
    try expectToken(&lexer, .identifier, "\"a:b\"");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .identifier, "p");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .identifier, "n");
    try expectToken(&lexer, .eof, "");
}
