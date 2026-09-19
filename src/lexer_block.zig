//! The block scanner: classifies the source 64 bytes at a time into bit
//! masks (one `u64` per byte class), then extracts tokens from the masks
//! with count-trailing-zeros instead of examining bytes one at a time.
//!
//! Same tokens, spans, diagnostics, fixes and warnings as the scalar
//! scanner — the differential tests in `lexer.zig` hold the two to
//! equality on every fixture, random input and truncation — but line
//! tracking is a popcount per block and the per-byte state dispatch is gone.
//! DOT's own rules (keywords, numerals, operators, `+` concatenation, the
//! comment forms, escapes) are decided over the short runs the masks
//! delimit, which is where a byte-oriented grammar belongs.
//!
//! Work credits (execution contract): one credit classifies one block, one
//! credit advances the token machine within the classified block. Both are
//! bounded by the block size, so a budget of one always makes progress and
//! cancellation latency is at most one block. The block's masks are part
//! of the saved state, so a yield never re-classifies; only a few
//! two-or-three-byte lookaheads (`-->`, `-.5`) may straddle a boundary and
//! read a byte of the next block directly.
//!
//! No allocation, no OS, instance-owned state (R-MEM-001, R-ROB-003). The
//! vector operations lower to scalar code on targets without SIMD; `lexer.zig`
//! chooses the scalar scanner there by default.

const std = @import("std");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const types = @import("lexer_types.zig");

pub const Token = types.Token;
pub const Result = types.Result;
const Advance = types.Advance;
const Terminal = types.Terminal;
const isIdentifierByte = types.isIdentifierByte;

pub const block_len = 64;

/// Classification compares the block in chunks of the target's natural u8
/// lane count, so each compare-to-mask step is one native movemask where
/// the target has one and plain scalar code where it does not. (A single
/// 64-lane bool vector bitcast miscompiles on wasm32 simd128 with Zig
/// 0.16; chunks of the native width do not.)
const chunk_len = @min(std.simd.suggestVectorLength(u8) orelse 16, block_len);
const Chunk = @Vector(chunk_len, u8);
const ChunkMask = std.meta.Int(.unsigned, chunk_len);
const Block = [block_len]u8;

pub const Lexer = Scanner(false, false);

/// Byte-class bit masks of one block: bit i describes byte `block_start + i`.
const Masks = struct {
    /// Space, tab, CR, LF.
    ws: u64,
    /// Space and tab only.
    blank: u64,
    /// LF or CR bytes.
    newline_byte: u64,
    /// Line-terminator events, one per physical line end: an LF, or a CR
    /// not followed by LF (CRLF is one event, carried by its LF).
    newline: u64,
    /// [A-Za-z0-9_] and bytes >= 0x80.
    ident: u64,
    digit: u64,
    /// Bytes >= 0x80.
    high: u64,
    quote: u64,
    /// Quotes escaped by an odd run of backslashes.
    escaped: u64,
    star: u64,
    slash: u64,
    nul: u64,
};

inline fn compare(bytes: *const Block, comptime op: std.math.CompareOperator, c: u8) u64 {
    var mask: u64 = 0;
    inline for (0..block_len / chunk_len) |i| {
        const chunk: Chunk = bytes[i * chunk_len ..][0..chunk_len].*;
        const hits: @Vector(chunk_len, bool) = switch (op) {
            .eq => chunk == @as(Chunk, @splat(c)),
            .gte => chunk >= @as(Chunk, @splat(c)),
            .lte => chunk <= @as(Chunk, @splat(c)),
            else => comptime unreachable,
        };
        mask |= @as(u64, @as(ChunkMask, @bitCast(hits))) << @as(u6, @intCast(i * chunk_len));
    }
    return mask;
}
inline fn eq(bytes: *const Block, c: u8) u64 {
    return compare(bytes, .eq, c);
}
inline fn ge(bytes: *const Block, c: u8) u64 {
    return compare(bytes, .gte, c);
}
inline fn le(bytes: *const Block, c: u8) u64 {
    return compare(bytes, .lte, c);
}

/// Bytes escaped by an odd-length run of backslashes, with the run parity
/// carried across blocks (the simdjson formulation).
fn findEscaped(backslash_in: u64, prev_escaped: *bool) u64 {
    const prev: u64 = @intFromBool(prev_escaped.*);
    if (backslash_in == 0) {
        prev_escaped.* = false;
        return prev;
    }
    const backslash = backslash_in & ~prev;
    const follows_escape = (backslash << 1) | prev;
    const even_bits: u64 = 0x5555555555555555;
    const odd_sequence_starts = backslash & ~even_bits & ~follows_escape;
    const sum = @addWithOverflow(odd_sequence_starts, backslash);
    prev_escaped.* = sum[1] == 1;
    const invert_mask = sum[0] << 1;
    return (even_bits ^ invert_mask) & follows_escape;
}

pub fn Scanner(comptime metered: bool, comptime audited: bool) type {
    return struct {
        const Self = @This();
        const Mode = enum { trivia, line_comment, block_comment, quoted, ident, numeral, dash_gap };
        const TriviaMode = enum { ordinary, after_quote, after_plus };
        const NumeralPart = enum { integral, fraction };

        source: []const u8,
        /// Next byte to consider.
        cursor: u32 = 0,
        line: u32 = 1,
        /// Offset of the first byte of the current line (after its terminator).
        line_start: u32 = 0,
        /// The classified block, when `classified`; always 64-aligned.
        block_start: u32 = 0,
        masks: Masks = undefined,
        classified: bool = false,
        /// Backslash-run parity carried into the next block.
        prev_escaped: bool = false,
        mode: Mode = .trivia,
        trivia: TriviaMode = .ordinary,
        part: NumeralPart = .integral,
        saw_high: bool = false,
        /// Start of the token being built (or the failing token).
        anchor: location.Location = .start,
        /// Failure span start: a quote or comment opener, or the bad byte.
        opener: location.Location = .start,
        /// One past the last closing quote of the current quoted token.
        quote_end: location.Location = .start,
        /// First byte of a block comment's body (after `/*`).
        body_start: u32 = 0,
        /// The most recently completed token.
        ready: Token = undefined,
        terminal: Terminal = .none,
        terminal_len: u32 = 0,
        found: ?u8 = null,
        /// See `takeWarning`.
        ambiguous_numeral: ?u8 = null,
        source_frontier: if (metered) usize else void = if (metered) 0 else {},
        examinations: if (audited) usize else void = if (audited) 0 else {},

        pub fn init(source: []const u8) Self {
            var self: Self = .{ .source = source };
            // Positions are 32-bit: refuse a longer source before reading it.
            if (source.len > location.max_source_len) {
                self.terminal = .oversize;
                return self;
            }
            // A leading UTF-8 byte order mark is not content (Graphviz skips
            // it too); the bytes still occupy columns 1–3 of line 1.
            if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) self.cursor = 3;
            return self;
        }

        /// `next`, `drive` and `microstep` are forced inline: the parser's
        /// ordinary driver calls `next` once per token, and in the one
        /// instantiation where LLVM declined to inline the chain (fixed
        /// builder, unmetered) that path ran 20% slower than the same
        /// scanner behind the allocating builder.
        pub inline fn next(self: *Self) Result {
            return self.drive(false, 0).result.?;
        }

        // null means yield, never EOF. EOF remains an ordinary terminal token.
        pub fn nextBounded(self: *Self, budget: usize) Advance {
            return self.drive(true, budget);
        }

        /// One credit per microstep: a block classification or one bounded
        /// advance of the token machine inside the classified block.
        pub inline fn drive(self: *Self, comptime bounded: bool, budget: usize) Advance {
            if (self.terminal != .none) return .{ .result = self.terminalResult(), .work_used = 0 };
            var used: usize = 0;
            while (true) {
                if (bounded and used == budget) return .{ .result = null, .work_used = used };
                used += 1;
                if (audited) self.examinations += 1;
                if (self.microstep()) |result| return .{ .result = result, .work_used = used };
            }
        }

        pub fn here(self: *const Self) location.Location {
            return .{ .byte_offset = self.cursor, .line = self.line, .byte_column = self.cursor - self.line_start + 1 };
        }

        /// The diagnostic for the latched failure; see the scalar scanner.
        pub fn failureDiagnostic(self: *const Self) diagnostic.Diagnostic {
            std.debug.assert(self.terminal != .none and self.terminal != .eof);
            if (self.terminal == .oversize) return .{
                .code = .resource_capacity_exhausted,
                .span = .{ .start = .start, .byte_len = 0 },
                .details = .{ .capacity = .{ .resource = .source_range, .limit = location.max_source_len } },
            };
            const span: location.Span = .{ .start = self.opener, .byte_len = self.terminal_len };
            return .{
                .code = switch (self.terminal) {
                    .invalid => .syntax_invalid_byte,
                    .operator, .operator_long, .operator_spaced => .syntax_invalid_operator,
                    .numeral => .syntax_incomplete_numeral,
                    .block, .quote => .syntax_unterminated_construct,
                    .concat => .syntax_invalid_concatenation,
                    .non_ascii, .html => .profile_unsupported_feature,
                    .none, .eof, .oversize => unreachable,
                },
                .span = span,
                .details = switch (self.terminal) {
                    .invalid => .{ .invalid_byte = self.found.? },
                    .operator => .{ .invalid_operator = .{ .found = self.found, .shape = .lone } },
                    .operator_long => .{ .invalid_operator = .{ .found = self.found, .shape = .long } },
                    .operator_spaced => .{ .invalid_operator = .{ .found = self.found, .shape = .spaced } },
                    .numeral => .{ .incomplete_numeral = self.found },
                    .block => .{ .unterminated = .block_comment },
                    .quote => .{ .unterminated = .quoted_identifier },
                    .concat => .{ .expected_quote = self.found },
                    .non_ascii => .{ .unsupported_feature = .non_ascii_identifier },
                    .html => .{ .unsupported_feature = .html_identifier },
                    .none, .eof, .oversize => unreachable,
                },
                .fix = switch (self.terminal) {
                    .operator_long, .operator_spaced => .{
                        .span = span,
                        .edit = .{ .replace = if (self.found == '>') .directed_operator else .undirected_operator },
                        .applicability = .machine_applicable,
                    },
                    else => null,
                },
            };
        }

        /// The warning attached to the most recently produced token, if any,
        /// clearing it (a numeral running into a letter or dot).
        pub fn takeWarning(self: *Self) ?diagnostic.Diagnostic {
            const byte = self.ambiguous_numeral orelse return null;
            self.ambiguous_numeral = null;
            return .{
                .code = .syntax_ambiguous_numeral,
                .span = self.ready.span,
                .details = .{ .ambiguous_numeral = byte },
            };
        }

        /// Error-recovery support; same policy as the scalar scanner.
        pub fn resumeAfterFailure(self: *Self) void {
            const anchor = self.anchor.byte_offset;
            const start = self.opener.byte_offset;
            const target: u32 = switch (self.terminal) {
                .block, .quote => @intCast(self.source.len),
                .concat => start,
                .invalid, .operator, .operator_long, .operator_spaced, .numeral => if (start == anchor) start + self.terminal_len else @intCast(self.source.len),
                .none, .eof, .non_ascii, .html, .oversize => unreachable,
            };
            std.debug.assert(self.cursor == anchor and target >= anchor);
            self.skipTo(target);
            self.terminal = .none;
            self.terminal_len = 0;
            self.found = null;
            self.mode = .trivia;
            self.trivia = .ordinary;
        }

        // --- block classification ---------------------------------------

        fn classify(self: *Self, block_start: u32) void {
            const start: usize = block_start;
            const n: usize = @min(self.source.len - start, block_len);
            var bytes: Block = @splat(0);
            @memcpy(bytes[0..n], self.source[start..][0..n]);
            const v = &bytes;
            const valid: u64 = if (n == block_len) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;

            const lf = eq(v, '\n') & valid;
            const cr = eq(v, '\r') & valid;
            const blank = (eq(v, ' ') | eq(v, '\t')) & valid;
            // A CR directly followed by LF hands its event to the LF; a CR in
            // the last cell looks at the next source byte (examined, so it
            // counts toward the frontier).
            var cr_before_lf = (lf >> 1) & cr;
            const last_cell: u64 = @as(u64, 1) << 63;
            if (cr & last_cell != 0 and n == block_len and start + block_len < self.source.len) {
                if (metered) self.source_frontier = @max(self.source_frontier, start + block_len + 1);
                if (self.source[start + block_len] == '\n') cr_before_lf |= last_cell;
            }
            const digit = ge(v, '0') & le(v, '9') & valid;
            const high = ge(v, 0x80) & valid;
            const alpha = (ge(v, 'a') & le(v, 'z')) | (ge(v, 'A') & le(v, 'Z'));
            const backslash = eq(v, '\\') & valid;

            self.masks = .{
                .ws = blank | lf | cr,
                .blank = blank,
                .newline_byte = lf | cr,
                .newline = lf | (cr & ~cr_before_lf),
                .ident = (alpha | digit | eq(v, '_') | high) & valid,
                .digit = digit,
                .high = high,
                .quote = eq(v, '"') & valid,
                .escaped = findEscaped(backslash, &self.prev_escaped),
                .star = eq(v, '*') & valid,
                .slash = eq(v, '/') & valid,
                .nul = eq(v, 0) & valid,
            };
            self.block_start = block_start;
            self.classified = true;
            if (metered) self.source_frontier = @max(self.source_frontier, start + n);
        }

        fn blockEnd(self: *const Self) u32 {
            return @intCast(@min(@as(usize, self.block_start) + block_len, self.source.len));
        }

        /// The block's mask with bit 0 at the cursor.
        inline fn rest(self: *const Self, mask: u64) u64 {
            return mask >> @intCast(self.cursor - self.block_start);
        }

        /// How many consecutive bytes from the cursor are in `mask`
        /// (stops at the block end, since padding bits are never set).
        inline fn runLen(self: *const Self, mask: u64) u32 {
            return @ctz(~self.rest(mask));
        }

        /// The first byte at or after the cursor in `mask`, in this block.
        inline fn findFirst(self: *const Self, mask: u64) ?u32 {
            const r = self.rest(mask);
            if (r == 0) return null;
            return self.cursor + @ctz(r);
        }

        /// Move forward within the block, counting the line events passed.
        fn advanceTo(self: *Self, target: u32) void {
            std.debug.assert(target >= self.cursor and target <= self.blockEnd());
            const width: u6 = @intCast(@min(target - self.cursor, 63));
            if (target == self.cursor) return;
            const low: u6 = @intCast(self.cursor - self.block_start);
            // Bits [low, low + width'), where width' is the true width (≤ 64).
            const true_width = target - self.cursor;
            const range: u64 = if (true_width == 64) std.math.maxInt(u64) else ((@as(u64, 1) << width) - 1) << low;
            const events = self.masks.newline & range;
            if (events != 0) {
                self.line += @popCount(events);
                self.line_start = self.block_start + (63 - @clz(events)) + 1;
            }
            self.cursor = target;
        }

        /// Skip forward across blocks (recovery), keeping line tracking exact.
        fn skipTo(self: *Self, target: u32) void {
            while (self.cursor < target) {
                if (!self.classified or self.cursor >= self.block_start + block_len) {
                    self.classify(self.cursor - self.cursor % block_len);
                }
                self.advanceTo(@min(target, self.blockEnd()));
            }
        }

        /// Move to a saved location (backwards or forwards within the source
        /// already seen). The saved location follows a closing quote or is a
        /// token start, so no escape or comment state crosses it. Within the
        /// classified block nothing else changes: the backslash parity the
        /// block left behind still describes its last byte and must reach
        /// the next block's classification. Outside it the classification is
        /// dropped and re-derived; the parity restarts at zero, which is
        /// exact for every byte the scanner can still visit (a byte at a
        /// token start or after a closing quote is never escaped).
        fn restore(self: *Self, loc: location.Location) void {
            self.cursor = loc.byte_offset;
            self.line = loc.line;
            self.line_start = loc.byte_offset - (loc.byte_column - 1);
            if (!self.classified or self.cursor < self.block_start or self.cursor >= self.block_start + block_len) {
                self.classified = false;
                self.prev_escaped = false;
            }
        }

        /// A byte `k` past the cursor, read directly: the token machine's
        /// bounded lookahead of at most two bytes for operator and numeral
        /// shapes, which may reach past the block and counts as examined.
        inline fn peek(self: *Self, k: u32) ?u8 {
            const at = @as(usize, self.cursor) + k;
            if (at >= self.source.len) return null;
            if (metered) self.source_frontier = @max(self.source_frontier, at + 1);
            return self.source[at];
        }

        /// Consume `k` bytes that contain no newline; may leave the block.
        fn jump(self: *Self, k: u32) void {
            self.cursor += k;
            if (self.cursor >= self.block_start + block_len) self.classified = false;
        }

        // --- the token machine ------------------------------------------

        inline fn microstep(self: *Self) ?Result {
            if (self.cursor == self.source.len) return self.atEnd();
            if (!self.classified or self.cursor >= self.block_start + block_len) {
                self.classify(self.cursor - self.cursor % block_len);
                return null;
            }
            return switch (self.mode) {
                .trivia => self.stepTrivia(),
                .line_comment => self.stepLineComment(),
                .block_comment => self.stepBlockComment(),
                .quoted => self.stepQuoted(),
                .ident => self.stepIdent(),
                .numeral => self.stepNumeral(),
                .dash_gap => self.stepDashGap(),
            };
        }

        fn atEnd(self: *Self) ?Result {
            switch (self.mode) {
                .trivia, .line_comment => switch (self.trivia) {
                    .after_quote => return self.finishQuoted(),
                    .after_plus => return self.fail(.concat, self.here(), 0, null),
                    .ordinary => {
                        self.terminal = .eof;
                        return self.terminalResult();
                    },
                },
                .block_comment => {
                    // Malformed trailing trivia belongs to the next token
                    // unless '+' has committed us to another quoted part.
                    if (self.trivia == .after_quote) return self.finishQuoted();
                    return self.fail(.block, self.opener, 2, null);
                },
                .quoted => return self.fail(.quote, self.opener, 1, null),
                .ident => return self.finishIdent(),
                .numeral => return self.emit(.identifier),
                .dash_gap => return self.fail(.operator, self.anchor, 1, self.found),
            }
        }

        fn stepTrivia(self: *Self) ?Result {
            self.advanceTo(self.cursor + self.runLen(self.masks.ws));
            if (self.cursor == self.blockEnd()) return null;
            const b = self.source[self.cursor];
            // Comments are trivia in every mode, including between the parts
            // of a quoted concatenation. In ordinary mode the comment opener
            // is also the anchor, so an unterminated comment rests there.
            if (b == '#') {
                if (self.trivia == .ordinary) self.anchor = self.here();
                self.advanceTo(self.cursor + 1);
                self.mode = .line_comment;
                return null;
            }
            if (b == '/') {
                const n1 = self.peek(1);
                if (n1 == '/' or n1 == '*') {
                    self.opener = self.here();
                    if (self.trivia == .ordinary) self.anchor = self.here();
                    if (n1 == '*') {
                        self.body_start = self.cursor + 2;
                        self.mode = .block_comment;
                    } else {
                        self.mode = .line_comment;
                    }
                    self.advanceTo(self.cursor + 1);
                    return null;
                }
            }
            switch (self.trivia) {
                .after_quote => {
                    if (b != '+') return self.finishQuoted();
                    self.advanceTo(self.cursor + 1);
                    self.trivia = .after_plus;
                    return null;
                },
                .after_plus => {
                    if (b != '"') return self.fail(.concat, self.here(), 1, b);
                    self.opener = self.here();
                    self.advanceTo(self.cursor + 1);
                    self.mode = .quoted;
                    return null;
                },
                .ordinary => {},
            }
            self.anchor = self.here();
            switch (b) {
                '{', '}', ';', ':', '[', ']', '=', ',' => {
                    self.advanceTo(self.cursor + 1);
                    return self.emit(switch (b) {
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
                '/' => return self.fail(.invalid, self.anchor, 1, '/'),
                '"' => {
                    self.opener = self.anchor;
                    self.advanceTo(self.cursor + 1);
                    self.mode = .quoted;
                    return null;
                },
                'A'...'Z', 'a'...'z', '_', 0x80...0xff => {
                    self.mode = .ident;
                    self.saw_high = false;
                    return self.stepIdent();
                },
                '0'...'9' => {
                    self.mode = .numeral;
                    self.part = .integral;
                    return self.stepNumeral();
                },
                '-' => return self.dash(),
                '.' => {
                    const n1 = self.peek(1);
                    if (n1 != null and std.ascii.isDigit(n1.?)) {
                        self.mode = .numeral;
                        self.part = .fraction;
                        self.jump(1);
                        return null;
                    }
                    return self.fail(.numeral, self.anchor, 1, n1);
                },
                '<' => return self.fail(.html, self.anchor, 1, null),
                else => return self.fail(.invalid, self.anchor, 1, b),
            }
        }

        fn dash(self: *Self) ?Result {
            const n1 = self.peek(1) orelse return self.fail(.operator, self.anchor, 1, null);
            switch (n1) {
                '-' => {
                    const n2 = self.peek(2);
                    if (n2 == '>' or n2 == '-') return self.fail(.operator_long, self.anchor, 3, n2);
                    self.jump(2);
                    return self.emit(.edge_undirected);
                },
                '>' => {
                    self.jump(2);
                    return self.emit(.edge_directed);
                },
                '0'...'9' => {
                    self.mode = .numeral;
                    self.part = .integral;
                    self.jump(1);
                    return null;
                },
                '.' => {
                    const n2 = self.peek(2);
                    if (n2 != null and std.ascii.isDigit(n2.?)) {
                        self.mode = .numeral;
                        self.part = .fraction;
                        self.jump(2);
                        return null;
                    }
                    return self.fail(.numeral, self.anchor, 2, n2);
                },
                ' ', '\t' => {
                    // Look past the gap: `- >` is a spaced operator.
                    self.found = n1;
                    self.advanceTo(self.cursor + 1);
                    self.mode = .dash_gap;
                    return null;
                },
                else => return self.fail(.operator, self.anchor, 1, n1),
            }
        }

        fn stepDashGap(self: *Self) ?Result {
            self.advanceTo(self.cursor + self.runLen(self.masks.blank));
            if (self.cursor == self.blockEnd()) return null;
            const b = self.source[self.cursor];
            if (b == '>' or b == '-') {
                const len = self.cursor + 1 - self.anchor.byte_offset;
                return self.fail(.operator_spaced, self.anchor, len, b);
            }
            return self.fail(.operator, self.anchor, 1, self.found);
        }

        fn stepIdent(self: *Self) ?Result {
            const run = self.runLen(self.masks.ident);
            if (run != 0) {
                const low: u6 = @intCast(self.cursor - self.block_start);
                const bits: u64 = if (run == 64) std.math.maxInt(u64) else ((@as(u64, 1) << @intCast(run)) - 1) << low;
                if (self.masks.high & bits != 0) self.saw_high = true;
                self.advanceTo(self.cursor + run);
            }
            if (self.cursor == self.blockEnd()) return null;
            return self.finishIdent();
        }

        fn finishIdent(self: *Self) ?Result {
            const len = self.cursor - self.anchor.byte_offset;
            if (self.saw_high) return self.fail(.non_ascii, self.anchor, len, null);
            var tag: Token.Tag = .identifier;
            if (len <= 8) {
                var word: u64 = 0;
                for (self.source[self.anchor.byte_offset..self.cursor]) |byte| word = types.foldKeywordByte(word, byte);
                tag = types.keywordTag(word, len);
            }
            return self.emit(tag);
        }

        fn stepNumeral(self: *Self) ?Result {
            while (true) {
                self.advanceTo(self.cursor + self.runLen(self.masks.digit));
                if (self.cursor == self.blockEnd()) return null;
                const b = self.source[self.cursor];
                if (self.part == .integral and b == '.') {
                    self.advanceTo(self.cursor + 1);
                    self.part = .fraction;
                    if (self.cursor == self.blockEnd()) return null;
                    continue;
                }
                // Maximal munch ends the numeral here, exactly as Graphviz
                // does — and Graphviz warns when the next byte could have
                // been meant as part of it.
                if (isIdentifierByte(b) or b == '.') self.ambiguous_numeral = b;
                return self.emit(.identifier);
            }
        }

        fn stepLineComment(self: *Self) ?Result {
            if (self.findFirst(self.masks.newline_byte)) |p| {
                // The terminator byte belongs to the comment; a CRLF's LF is
                // then plain whitespace, exactly as the scalar scanner has it.
                self.advanceTo(p + 1);
                self.mode = .trivia;
                return null;
            }
            self.advanceTo(self.blockEnd());
            return null;
        }

        fn stepBlockComment(self: *Self) ?Result {
            // A '*' in the previous block's last cell closes with a '/' in
            // this block's first cell, unless that '*' is the opener's own.
            if (self.cursor == self.block_start and self.block_start > 0 and (self.masks.slash & 1) != 0 and
                self.source[self.block_start - 1] == '*' and self.block_start - 1 >= self.body_start)
            {
                self.advanceTo(self.cursor + 1);
                self.mode = .trivia;
                return null;
            }
            var close = self.masks.star & (self.masks.slash >> 1);
            // The opener's '*' can never close the comment (`/*/`); when the
            // body starts at or past this block's end (the `*` sits in the
            // last cell) nothing in this block can close it.
            if (self.body_start > self.block_start) {
                const below = self.body_start - self.block_start;
                close = if (below >= block_len) 0 else close & ~((@as(u64, 1) << @intCast(below)) - 1);
            }
            if (self.findFirst(close)) |p| {
                self.advanceTo(p + 2);
                self.mode = .trivia;
                return null;
            }
            self.advanceTo(self.blockEnd());
            return null;
        }

        fn stepQuoted(self: *Self) ?Result {
            const candidates = (self.masks.quote & ~self.masks.escaped) | self.masks.nul;
            if (self.findFirst(candidates)) |p| {
                self.advanceTo(p);
                if (self.source[p] == 0) return self.fail(.invalid, self.here(), 1, 0);
                self.advanceTo(p + 1);
                self.quote_end = self.here();
                self.trivia = .after_quote;
                self.mode = .trivia;
                return null;
            }
            self.advanceTo(self.blockEnd());
            return null;
        }

        /// The quoted token, including every `+`-joined part; trailing trivia
        /// is examined speculatively but excluded, and revisited once by the
        /// next call.
        fn finishQuoted(self: *Self) ?Result {
            const end = self.quote_end;
            self.restore(end);
            self.trivia = .ordinary;
            self.mode = .trivia;
            self.ready = .{ .tag = .identifier, .span = .{ .start = self.anchor, .byte_len = end.byte_offset - self.anchor.byte_offset } };
            return .{ .token = self.ready };
        }

        fn emit(self: *Self, tag: Token.Tag) ?Result {
            self.ready = .{ .tag = tag, .span = .{ .start = self.anchor, .byte_len = self.cursor - self.anchor.byte_offset } };
            self.mode = .trivia;
            self.trivia = .ordinary;
            return .{ .token = self.ready };
        }

        fn fail(self: *Self, kind: Terminal, start: location.Location, len: u32, found: ?u8) ?Result {
            self.terminal = kind;
            self.opener = start;
            self.terminal_len = len;
            self.found = found;
            // Like the scalar scanner, rest at the token anchor: recovery
            // measures its skip from there.
            self.restore(self.anchor);
            return .failure;
        }

        fn terminalResult(self: *const Self) Result {
            if (self.terminal == .eof) return .{ .token = .{
                .tag = .eof,
                .span = .{ .start = self.here(), .byte_len = 0 },
            } };
            return .failure;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: the block scanner on its own. Equivalence with the scalar scanner is
// tested in lexer.zig, which imports both.
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectToken(lexer: *Lexer, tag: Token.Tag, text: []const u8) !void {
    const result = lexer.next();
    try expect(result == .token);
    try expectEqual(tag, result.token.tag);
    try expectEqualStrings(text, result.token.span.slice(lexer.source));
}

test "bit order: element zero is bit zero" {
    var bytes: Block = @splat('x');
    bytes[0] = 'a';
    bytes[17] = 'c';
    bytes[40] = 'd';
    bytes[63] = 'b';
    try expectEqual(@as(u64, 1), eq(&bytes, 'a'));
    try expectEqual(@as(u64, 1) << 17, eq(&bytes, 'c'));
    try expectEqual(@as(u64, 1) << 40, eq(&bytes, 'd'));
    try expectEqual(@as(u64, 1) << 63, eq(&bytes, 'b'));
    try expectEqual(~((@as(u64, 1) << 17) | (@as(u64, 1) << 40)), ge(&bytes, 'x') | eq(&bytes, 'a') | eq(&bytes, 'b'));
    try expectEqual(@as(u64, 0), ge(&bytes, 'y'));
}

test "escaped quotes follow backslash parity across blocks" {
    var prev = false;
    // \" at bits 0-1: the quote at bit 1 is escaped.
    try expectEqual(@as(u64, 0b10), findEscaped(0b01, &prev));
    try expect(!prev);
    // \\" at bits 0-2: an even run, so the quote at bit 2 is not escaped
    // (the second backslash is).
    try expectEqual(@as(u64, 0b010), findEscaped(0b011, &prev));
    try expect(!prev);
    // A run ending on the last bit carries into the next block.
    _ = findEscaped(@as(u64, 1) << 63, &prev);
    try expect(prev);
    try expectEqual(@as(u64, 1), findEscaped(0, &prev));
    try expect(!prev);
}

test "tokens across a block boundary keep their spans and positions" {
    var buffer: [200]u8 = undefined;
    @memset(&buffer, 'a');
    // An identifier straddling the first boundary, a newline, then more.
    buffer[70] = ' ';
    buffer[71] = '\n';
    buffer[72] = '-';
    buffer[73] = '>';
    buffer[74] = ' ';
    buffer[75] = '"';
    @memset(buffer[76..130], 'q');
    buffer[130] = '"';
    buffer[131] = ';';
    const source = buffer[0..132];
    var lexer = Lexer.init(source);
    var result = lexer.next();
    try expect(result == .token);
    try expectEqual(@as(u32, 70), result.token.span.byte_len);
    try expectToken(&lexer, .edge_directed, "->");
    // The quoted identifier crosses the second boundary, on line 2.
    result = lexer.next();
    try expect(result == .token);
    try expectEqual(@as(u32, 2), result.token.span.start.line);
    try expectEqual(@as(u32, 56), result.token.span.byte_len);
    try expectEqual(@as(u32, 75), result.token.span.start.byte_offset);
    try expectEqual(@as(u32, 4), result.token.span.start.byte_column);
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .eof, "");
}

test "block scanner state is a small constant" {
    try expect(@sizeOf(Lexer) <= 256);
    try expectEqual(void, @FieldType(Lexer, "source_frontier"));
    try expectEqual(usize, @FieldType(Scanner(true, false), "source_frontier"));
}
