//! The lexer as the rest of the library sees it: one scanner interface, two
//! implementations. `scalar.zig` examines one byte per credit and is the
//! default; `block.zig` classifies 64-byte blocks into bit masks with
//! vector compares and extracts tokens from the masks. Both produce
//! identical tokens, spans, diagnostics, fixes and warnings — the tests
//! below hold them to it on fixtures, random inputs, every truncation,
//! every block shift and every work-budget partition.
//!
//! Parsing selects through `Policy.scanner`: a fixed profile specializes one
//! backend, while a runtime-enabled profile selects a specialized engine once
//! per operation or session init/reset. Direct lexical callers use `For`.
//! The historical measurements below predate the unified-policy migration;
//! its standard-machine performance comparison is still pending.
//! Measured on Apple silicon at the parse level, with positions derived on
//! demand rather than tracked per byte: running to completion the scalar
//! scanner is 3–15% faster on every corpus file and on the 200k-statement
//! bench, and faster at 256 credits per call; the block scanner wins only
//! at very small budgets (2–4x at one credit per call, since one credit
//! classifies 64 bytes) and on long runs of one byte class (2x on the
//! long-identifier fixture). Block state is 160 B against 56 B and its
//! code 6–9 KB larger per build; without a vector unit its compares lower
//! to byte loops, 1.9x slower on wasm32. Hence scalar everywhere, block
//! opt-in; see `docs/internal/OpenQuestions.md` (Q38).

const std = @import("std");
const policy = @import("../policy.zig");
const location = @import("../location.zig");
const diagnostic = @import("../diagnostic.zig");
const types = @import("token.zig");

pub const scalar = @import("scalar.zig");
pub const block = @import("block.zig");

pub const Token = types.Token;
pub const Result = types.Result;
pub const Advance = types.Advance;

pub fn scannerFor(comptime selected: policy.ScannerBackend) fn (comptime bool, comptime bool, comptime ?bool) type {
    return switch (selected) {
        .scalar => scalar.Scanner,
        .block => block.Scanner,
    };
}

/// Low-level fixed-backend scanner; retained parsing selects through Policy.
pub fn For(comptime selected: policy.ScannerBackend) type {
    return scannerFor(selected)(false, false, true);
}

/// Ordinary lexing with the library-default backend.
pub const Lexer = For(policy.defaults.scanner);

// ---------------------------------------------------------------------------
// Tests: the two backends are indistinguishable from outside.
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

test {
    _ = types;
    _ = scalar;
    _ = block;
}

/// Run both scanners over `source` to completion — through every recovery
/// resumption too — comparing each token, warning, and failure diagnostic.
fn expectEquivalent(source: []const u8) !void {
    var a = scalar.Lexer.init(source);
    var b = block.Lexer.init(source);
    while (true) {
        const ra = a.next();
        const rb = b.next();
        try expectEqualDeep(ra, rb);
        try expectEqualDeep(a.takeWarning(), b.takeWarning());
        if (ra == .failure) {
            try expectEqualDeep(a.failureDiagnostic(), b.failureDiagnostic());
            try expectEqual(a.terminal, b.terminal);
            switch (a.terminal) {
                .html, .oversize, .none, .eof => return,
                else => {
                    a.resumeAfterFailure();
                    b.resumeAfterFailure();
                    try expectEqual(a.here(), b.here());
                },
            }
            continue;
        }
        if (ra.token.tag == .eof) return;
    }
}

const fixtures = [_][]const u8{
    "",
    " \t\r\n\r\n",
    "graph { a -- b; x [label=\"hi\"]; }",
    "DiGraph STRICT SubGraph Node EDGE Graphical",
    "0 -0 123 -12 .5 -.5 12. -12.30 000.00 1->-2 3--4 1e3 1.2.3",
    "-",
    "-.",
    "-.x",
    ".",
    ".x",
    "+1",
    "/x",
    "/",
    "// comment\r\n# inline\ra /* ** / * */ -- b",
    "/* unterminated **",
    "a\xff_more",
    "\xff\x80tail",
    "<",
    ":",
    "\"a\\\"b\\\\c\\\r\nz\" /*glue*/ + // line\r\n\"d\" /*end*/ x",
    "\"a\"\"b\"",
    "\"a\"+}",
    "\"a\"+",
    "\"a\"+/*",
    "\"a\" /*",
    "\"a\"+ /",
    "\"a\" /x",
    "\"a\"+\"b\\",
    "\"a\x00b\"",
    "\"a\\\x00b\"",
    "-->",
    "---",
    "\xEF\xBB\xBFgraph {",
    "\xEF\xBB\xBF",
    "- >",
    "-  -",
    "- x",
    "-\t",
    "a - b; c - > d",
    "a -\t\t- b",
    "a --> b; c => d; e -> f",
    "a -b",
    "-/**/-",
    "gr/**/aph",
    "1e3 1.2.3 12.x 7 8_ .5e 9 ",
    "caf\xC3\xA9 x",
    "\xC3\xA9tat;",
    "digraph 名 { café:出口:北 -> 東京 [色=青]; }",
    "graphé node\xff \x80edge strict名 graph node edge strict",
    "é e\xcc\x81 \xc0\xaf \x80\xff caf\xe9",
    "a \xEF\xBB\xBFb \xEF\xBB\xBF \xEF\xBB\xBFgraph",
    "\xEF\xBB\xBF\xEF\xBB\xBFgraph",
    "café\x00 x",
    "1é 2\xff .3名",
    "\x7f",
    "a\tb\rc\nd\r\ne",
    "graph { @ }",
    "digraph { a -> ; b -> ; c [x=1 =]; e -- }",
    "digraph { a - b; c => d; subgraph s { e -> ; f } g -> ; h [k=v]; i -> { j -> ; k } }",
    "digraph {\n  subgraph s {\n    a -> b;\n  b -> c;\n}\n",
    "\"unterminated\n\nmore\n",
    "/* multi\nline\r\ncomment */ x",
    "\"a\" + \r\n \"bc",
    "\"a\" //c\n+ \"b\" ; \"c\" #x\r\n + \"d\" /*x*/ + \"e\"",
    "a;b;c;d;e;f;g;h;i;j;k;l;m;n;o;p;q;r;s;t;u;v;w;x;y;z;aa;bb;cc;dd;ee;ff;gg;hh;ii;jj;kk;ll;mm",
};

test "every high byte can start and continue a bare identifier in both scanners" {
    inline for (.{ scalar.Lexer, block.Lexer }) |ScannerType| {
        for (0x80..0x100) |value| {
            const byte: u8 = @intCast(value);
            const source = [_]u8{ byte, '_', '0', ' ', 'a', byte, ';' };
            var scanner = ScannerType.init(&source);
            for ([_]location.Span{ .{ .start = 0, .len = 3 }, .{ .start = 4, .len = 2 } }) |span| {
                const result = scanner.next();
                try expect(result == .token);
                try expectEqual(Token.Tag.identifier, result.token.tag);
                try expectEqual(span, result.token.span);
            }
            try expectEqual(Token.Tag.semicolon, scanner.next().token.tag);
            try expectEqual(Token.Tag.eof, scanner.next().token.tag);
        }
    }
}

test "high bytes keep keyword lookalikes as identifiers" {
    inline for (.{ scalar.Lexer, block.Lexer }) |ScannerType| {
        inline for (.{ "graph", "DiGraph", "node", "edge", "strict", "subgraph" }) |keyword| {
            inline for (.{ keyword ++ "é", "\xff" ++ keyword }) |source| {
                var scanner = ScannerType.init(source);
                try expectEqual(Token.Tag.identifier, scanner.next().token.tag);
                try expectEqual(Token.Tag.eof, scanner.next().token.tag);
            }
        }
    }
}

test "raw token scanning preserves BOM bytes at the start of an identifier" {
    inline for (.{ scalar.Lexer, block.Lexer }) |ScannerType| {
        inline for (.{ "\xEF\xBB\xBF", "\xEF\xBB\xBFgraph" }) |source| {
            var scanner = ScannerType.initRaw(source);
            const token = scanner.next().token;
            try expectEqual(Token.Tag.identifier, token.tag);
            try expectEqual(@as(u32, 0), token.span.start);
            try std.testing.expectEqualStrings(source, token.span.slice(source));
            try expectEqual(Token.Tag.eof, scanner.next().token.tag);
        }
    }
}

test "both scanners agree on every fixture and on every truncation of it" {
    for (fixtures) |source| {
        for (0..source.len + 1) |end| {
            errdefer std.debug.print("fixture: {s}\n truncated at {d}\n", .{ source, end });
            try expectEquivalent(source[0..end]);
        }
    }
}

test "both scanners agree on inputs that straddle block boundaries" {
    // Every fixture shifted to start at each offset of a block, so tokens,
    // comments, quotes and escapes cross the 64-byte edge at every position.
    var buffer: [512]u8 = undefined;
    for (fixtures) |source| {
        var shift: usize = 0;
        while (shift < 70) : (shift += 7) {
            @memset(buffer[0..shift], ' ');
            @memcpy(buffer[shift..][0..source.len], source);
            errdefer std.debug.print("fixture: {s}\n shifted by {d}\n", .{ source, shift });
            try expectEquivalent(buffer[0 .. shift + source.len]);
        }
    }
    // Long runs of each kind through many blocks.
    const runs = .{
        .{ "", 'a', ";" },       .{ "", ' ', "x" },                   .{ "", '9', ";" },
        .{ "//", 'x', "\r\nx" }, .{ "#", 'x', "\rx" },                .{ "/*", '*', "/x" },
        .{ "/*", 'x', "" },      .{ "\"", 'x', "\";" },               .{ "\"", '\\', "\";" },
        .{ "\"", 'x', "" },      .{ "\"a\" /*", 'x', "*/ + \"b\";" }, .{ "a -", ' ', "> b" },
        .{ "\"", '\n', "\"" },   .{ "\xff", 'a', ";" },               .{ "", 0x80, ";" },
    };
    inline for (runs) |run| {
        inline for (.{ 63, 64, 65, 127, 128, 200 }) |size| {
            @memcpy(buffer[0..run[0].len], run[0]);
            @memset(buffer[run[0].len..][0..size], run[1]);
            @memcpy(buffer[run[0].len + size ..][0..run[2].len], run[2]);
            const source = buffer[0 .. run[0].len + size + run[2].len];
            errdefer std.debug.print("run: {s}{c}x{d}{s}\n", .{ run[0], run[1], size, run[2] });
            try expectEquivalent(source);
        }
    }
}

test "both scanners agree on random byte streams" {
    const alphabet = "agN1.-/>\"*+#\\\r\n\t\x00\xff {};:=,[]<_9e";
    var data: [300]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x626c6f636b);
    for (0..3000) |_| {
        const len = random.random().uintLessThan(usize, data.len + 1);
        for (data[0..len]) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        errdefer std.debug.print("random input: {any}\n", .{data[0..len]});
        try expectEquivalent(data[0..len]);
    }
    // A second stream biased towards quoted tokens and escapes, with no byte
    // that ends scanning early, so strings and their backslash runs cross
    // the block edges in many combinations.
    const quoted_alphabet = "\"\"\"\\\\\\ab \n+;-";
    var quoted = std.Random.DefaultPrng.init(0x657363617065);
    for (0..3000) |_| {
        const len = quoted.random().uintLessThan(usize, data.len + 1);
        for (data[0..len]) |*byte| byte.* = quoted_alphabet[quoted.random().uintLessThan(usize, quoted_alphabet.len)];
        errdefer std.debug.print("random quoted input: {any}\n", .{data[0..len]});
        try expectEquivalent(data[0..len]);
    }
    // The first stream as a 32-bit target draws it (`usize` draws consume
    // the generator differently there); this found a comment opener ending
    // exactly at a block edge.
    var random32 = std.Random.DefaultPrng.init(0x626c6f636b);
    for (0..3000) |_| {
        const len = random32.random().uintLessThan(u32, data.len + 1);
        for (data[0..len]) |*byte| byte.* = alphabet[random32.random().uintLessThan(u32, alphabet.len)];
        errdefer std.debug.print("random input (32-bit draws): {any}\n", .{data[0..len]});
        try expectEquivalent(data[0..len]);
    }
}

test "comment openers at every position around a block edge" {
    // A `/*` whose `*` lands in a block's last cell, or whose `/` does, must
    // neither take that `*` as a closer nor overflow the body mask; `/*/`
    // and unterminated openers likewise.
    var buffer: [160]u8 = undefined;
    for ([_][]const u8{ "/*x*/ a", "/*/x*/ a", "/**/ a", "/*/ a", "/* a", "/*", "/*/", "/**", "/*x\n*/ a", "//x\n a" }) |body| {
        for ([_]usize{ 56, 118 }) |base| {
            for (0..15) |shift| {
                const lead = base + shift;
                @memset(buffer[0..lead], ' ');
                @memcpy(buffer[lead..][0..body.len], body);
                errdefer std.debug.print("lead {d}: {s}\n", .{ lead, body });
                try expectEquivalent(buffer[0 .. lead + body.len]);
            }
        }
    }
}

test "backslash parity survives a restore inside the block" {
    // Closing a quoted token restores the scanner to the byte after the
    // quote. When that byte is still in the classified block, the parity the
    // block computed for its last byte must survive, or a string whose odd
    // backslash run ends exactly at the block edge sees its escaped quote at
    // the start of the next block as a closing one. (Found by the comparison
    // corpus: `"node \"204\" name"` split at byte 4352.)
    var buffer: [256]u8 = undefined;
    for ([_]usize{ 63, 127 }) |edge| {
        for ([_]usize{ 1, 2, 3 }) |run| {
            for ([_]usize{ 1, 2, 9 }) |gap| {
                var close_at: usize = 1;
                while (close_at + gap + run + 2 <= edge) : (close_at += 1) {
                    @memset(&buffer, 'a');
                    buffer[0] = '"';
                    buffer[close_at] = '"';
                    @memset(buffer[close_at + 1 ..][0..gap], ' ');
                    buffer[close_at + 1 + gap] = '"';
                    @memset(buffer[edge + 1 - run ..][0..run], '\\');
                    buffer[edge + 1] = '"';
                    const tail = "c\" ; \"d\"";
                    @memcpy(buffer[edge + 2 ..][0..tail.len], tail);
                    const source = buffer[0 .. edge + 2 + tail.len];
                    errdefer std.debug.print("edge {d} run {d} gap {d} close_at {d}: {s}\n", .{ edge, run, gap, close_at, source });
                    try expectEquivalent(source);
                }
            }
        }
    }
}

/// Bounded block scanning yields the same stream as unbounded scanning for
/// any budget partition, and the same total work.
fn checkBlockPartition(source: []const u8, budgets: []const usize) !usize {
    var reference = block.Lexer.init(source);
    var bounded = block.Scanner(true, true, true).init(source);
    var calls: usize = 0;
    var total: usize = 0;
    var frontier: usize = 0;
    while (true) {
        const budget = budgets[calls % budgets.len];
        calls += 1;
        const before = bounded.examinations;
        const report = bounded.nextBounded(budget);
        try expect(report.work_used <= budget);
        try expectEqual(report.work_used, bounded.examinations - before);
        try expect(bounded.source_frontier >= frontier);
        try expect(bounded.source_frontier <= source.len);
        frontier = bounded.source_frontier;
        total += report.work_used;
        // Blocks plus tokens, never a rescan of a prefix.
        try expect(total <= 2 * (source.len / 64 + 1) + 4 * source.len + 16);
        if (report.result) |result| {
            try expectEqualDeep(reference.next(), result);
            try expectEqualDeep(reference.takeWarning(), bounded.takeWarning());
            if (result == .failure) try expectEqualDeep(reference.failureDiagnostic(), bounded.failureDiagnostic());
            if (result == .failure or result.token.tag == .eof) {
                inline for (.{ 0, 1, std.math.maxInt(usize) }) |after| {
                    const again = bounded.nextBounded(after);
                    try expectEqualDeep(result, again.result.?);
                    try expectEqual(@as(usize, 0), again.work_used);
                }
                return total;
            }
        } else {
            try expectEqual(budget, report.work_used);
        }
    }
}

test "block scanner budget partitions preserve tokens, diagnostics and total work" {
    for (fixtures) |source| {
        for (0..source.len + 1) |end| {
            const input = source[0..end];
            errdefer std.debug.print("fixture: {s}\n truncated at {d}\n", .{ source, end });
            const all = try checkBlockPartition(input, &.{std.math.maxInt(usize)});
            try expectEqual(all, try checkBlockPartition(input, &.{1}));
            try expectEqual(all, try checkBlockPartition(input, &.{ 0, 1, 0, 7, 2, 0, 3 }));
        }
    }
}

test "block scanner megabyte runs resume in linear work" {
    const size = 1024 * 1024;
    const buffer = try std.testing.allocator.alloc(u8, size + 32);
    defer std.testing.allocator.free(buffer);
    const cases = .{
        .{ "", 'a', ";" },                   .{ "", ' ', "x" },     .{ "//", 'x', "\r\nx" },
        .{ "/*", '*', "/x" },                .{ "\"", 'x', "\";" }, .{ "\"", '\\', "\";" },
        .{ "\"a\" /*", 'x', "*/ + \"b\";" },
    };
    inline for (cases) |case| {
        @memcpy(buffer[0..case[0].len], case[0]);
        @memset(buffer[case[0].len..][0..size], case[1]);
        @memcpy(buffer[case[0].len + size ..][0..case[2].len], case[2]);
        const source = buffer[0 .. case[0].len + size + case[2].len];
        const one = try checkBlockPartition(source, &.{1});
        try expectEqual(one, try checkBlockPartition(source, &.{ 0, 17, 4096, 1 }));
        try expectEquivalent(source);
    }
}

test "direct lexing defaults to scalar with an explicit fixed-backend factory" {
    try expect(For(.scalar) == Lexer);
    try expect(For(.block) == block.Lexer);
}
