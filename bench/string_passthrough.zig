//! Simulated host handoff: the real DOT lexer scans one quoted identifier,
//! then optional standalone string processing checks its unchanged contents.
//! No escapes/concatenations, tree construction, source copies in timing or
//! production integration. Both scanner backends use the same input/checks.
const std = @import("std");
const dot = @import("dot_parser");
const strings = @import("string_processor");

const Mode = enum { passthrough, encoding, exact, metered64 };
const modes = std.meta.tags(Mode);
const rounds = 9;
const warmups = 2;

fn Checker(comptime text: []const u8, comptime mode: Mode) type {
    @setEvalBranchQuota(200_000);
    return strings.Profile(.{ .policy = .{
        .execution = .{ .metering = mode == .metered64 },
        .validation = .{ .equals = .{ .expected = text, .severity = if (mode == .exact or mode == .metered64) .err else .off } },
    } });
}

// Keep exactly the same host scanner call in all four timed variants.
noinline fn scan(comptime backend: dot.ScannerBackend, source: []const u8) !strings.Fragment {
    var lexer = dot.lexer.For(backend).init(source);
    const token = switch (lexer.next()) {
        .failure => return error.InvalidFixture,
        .token => |token| token,
    };
    if (token.tag != .identifier or token.span.start != 0 or token.span.len != source.len or
        token.flags.concatenated or token.flags.has_html or source.len < 2 or
        source[0] != '"' or source[source.len - 1] != '"') return error.InvalidFixture;
    switch (lexer.next()) {
        .failure => return error.InvalidFixture,
        .token => |end| if (end.tag != .eof) return error.InvalidFixture,
    }
    // These fixtures have no escape sequences, so raw and logical contents agree.
    return .{ .bytes = source[1 .. source.len - 1], .origin = 1 };
}

noinline fn run(comptime backend: dot.ScannerBackend, comptime mode: Mode, comptime P: type, source: []const u8) !u64 {
    const fragment = try scan(backend, source);
    switch (mode) {
        .passthrough => {},
        .encoding, .exact => {
            if (!(try P.parseAndValidate(fragment, P.Sink.discard, .{})).valid()) return error.RejectedFixture;
        },
        .metered64 => {
            var session = try P.Session.init(fragment, P.Sink.discard, .{});
            defer session.deinit();
            while (true) {
                const progress = session.advance(64);
                if (progress.work_used > 64) return error.BudgetExceeded;
                if (progress.outcome != null) break;
            }
            if (!session.result().?.valid()) return error.RejectedFixture;
        },
    }
    return fragment.bytes.len;
}

fn measure(comptime backend: dot.ScannerBackend, comptime mode: Mode, comptime text: []const u8, source: []const u8, iterations: usize, io: std.Io) !u64 {
    @setEvalBranchQuota(200_000);
    const P = Checker(text, mode);
    var checksum: u64 = 0;
    const begin = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(source.ptr);
        checksum +%= try run(backend, mode, P, source);
    }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    if (checksum != text.len * iterations) return error.UnstableChecksum;
    return @intCast(begin.durationTo(end).raw.nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(1_000_000);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const writer = &output.interface;
    try writer.writeAll("DOT quote scan + optional string checks; UTF-8; discard sink; processor heap=0\nMB/s uses content bytes (excludes two quotes); no host tree or unescaping\n");
    inline for (.{ dot.ScannerBackend.scalar, .block }) |backend| {
        // Exercise the distinction: quote passthrough accepts this non-NUL byte,
        // whereas the standalone processor must report malformed UTF-8.
        const malformed = try scan(backend, "\"\xff\"");
        if ((try strings.parseAndValidate(malformed, strings.Sink.discard, .{})).valid()) return error.MissedEncodingError;
        inline for (.{
            .{ "short-ascii", "Seattle" },
            .{ "short-unicode", "Straße 中文 😀" },
            .{ "long-ascii", "The quick brown fox. " ** 200 },
            .{ "long-unicode", "Straße 中文 😀" ** 64 },
        }) |fixture| {
            const text = fixture[1];
            const source = try init.gpa.dupe(u8, "\"" ++ text ++ "\"");
            defer init.gpa.free(source);
            const iterations = @max(128, 2_000_000 / text.len);
            var times: [modes.len][rounds]u64 = undefined;
            // Alternate the order within each round; no builds during timing.
            for (0..warmups + rounds) |round| {
                for (0..modes.len) |slot| {
                    const index = if (round % 2 == 0) slot else modes.len - 1 - slot;
                    const elapsed = switch (modes[index]) {
                        inline else => |mode| try measure(backend, mode, text, source, iterations, init.io),
                    };
                    if (round >= warmups) times[index][round - warmups] = elapsed;
                }
            }
            for (&times) |*samples| std.mem.sort(u64, samples, {}, std.sort.asc(u64));
            const baseline = @as(f64, @floatFromInt(times[0][rounds / 2]));
            for (modes, 0..) |mode, index| {
                const elapsed = @as(f64, @floatFromInt(times[index][rounds / 2]));
                const ns = elapsed / @as(f64, @floatFromInt(iterations));
                try writer.print("{s} {s} {s} bytes={d} ns/value={d:.2} MB/s={d:.1} ratio={d:.3}\n", .{
                    @tagName(backend),                             fixture[0],         @tagName(mode), text.len, ns,
                    @as(f64, @floatFromInt(text.len)) * 1000 / ns, elapsed / baseline,
                });
            }
            try writer.flush();
        }
    }
}
