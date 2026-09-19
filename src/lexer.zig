//! The lexer as the rest of the library sees it: one scanner interface, two
//! implementations. `lexer_block.zig` classifies 64-byte blocks into bit
//! masks with vector compares and extracts tokens from the masks, and is
//! the default where the target has 128-bit or wider vectors;
//! `lexer_scalar.zig` examines one byte per credit and is the default
//! elsewhere. Both produce identical tokens, spans, diagnostics, fixes and
//! warnings — the tests below hold them to it on fixtures, random inputs,
//! every truncation, every block shift and every work-budget partition.
//!
//! Selection is compile-time. A root source file overrides the default with
//!
//! ```zig
//! pub const dot_parser_options = .{ .lexer_backend = .block };
//! ```
//!
//! which is how the benches compare the two and how a consumer pins one.
//! Measured on Apple silicon (128-bit vectors) at the parse level: running
//! to completion, the block scanner is 18–21% faster on comment-heavy and
//! 14–18% on deeply nested sources, equal on the 200k-statement bench, and
//! 4–8% slower on sources made of short bare and quoted tokens; under work
//! budgets it needs 2–6x fewer credits and resumes far more cheaply, so
//! bounded sessions run 7–55% faster at 256 credits per call and 2–4x
//! faster at one. Its state is 208 B against 104 B and its code 6–9 KB
//! larger per build. Without a vector unit its compares lower to byte
//! loops: 1.9x slower than the scalar scanner on wasm32 and 27–52 KB
//! larger there and on riscv32, which is why those targets default to
//! scalar; see `docs/internal/OpenQuestions.md` (Q38).

const std = @import("std");
const root = @import("root");
const location = @import("location.zig");
const diagnostic = @import("diagnostic.zig");
const types = @import("lexer_types.zig");

pub const scalar = @import("lexer_scalar.zig");
pub const block = @import("lexer_block.zig");

pub const Token = types.Token;
pub const Result = types.Result;
pub const Advance = types.Advance;

pub const Backend = enum { scalar, block };

/// Block scanning where the target has 128-bit or wider vectors, so each
/// compare-to-mask step is native; the scalar scanner where the vector code
/// would lower to byte loops (measured 1.9x slower and 30–70% larger on
/// wasm32 and riscv32 without vector units). `backend` is the override.
pub const default_backend: Backend = if (std.simd.suggestVectorLength(u8)) |lanes|
    (if (lanes >= 16) .block else .scalar)
else
    .scalar;

/// The selected backend: the root file's `dot_parser_options.lexer_backend`
/// when it declares one, else `default_backend`.
pub const backend: Backend = blk: {
    if (@hasDecl(root, "dot_parser_options")) {
        const options = root.dot_parser_options;
        if (@hasField(@TypeOf(options), "lexer_backend")) break :blk options.lexer_backend;
    }
    break :blk default_backend;
};

pub fn Scanner(comptime metered: bool, comptime audited: bool) type {
    return switch (backend) {
        .scalar => scalar.Scanner(metered, audited),
        .block => block.Scanner(metered, audited),
    };
}

/// Ordinary lexing with the selected backend.
pub const Lexer = Scanner(false, false);

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
                .non_ascii, .html, .oversize, .none, .eof => return,
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
        .{ "\"", '\n', "\"" },   .{ "\xff", 'a', ";" },
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
    var bounded = block.Scanner(true, true).init(source);
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

test "the selected backend follows the target unless the root overrides it" {
    // The test root declares no `dot_parser_options`.
    try expectEqual(default_backend, backend);
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        try expectEqual(if (lanes >= 16) Backend.block else Backend.scalar, default_backend);
    } else {
        try expectEqual(Backend.scalar, default_backend);
    }
}
