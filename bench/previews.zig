//! Opt-in token observations: allocation-free event sessions, alternating
//! measurements, callback/work totals and retained state size in one report.
const std = @import("std");
const dot = @import("dot_parser");
const Mode = enum { plain, budget1, budget64, budget4096 };
const Observation = struct { credits: usize = 0, callbacks: usize = 0, previews: usize = 0, ends: usize = 0 };
fn Consumer(comptime enabled: bool) type {
    return struct {
        pub const observations: dot.events.Observations = .{ .token_preview = enabled };
        observation: Observation = .{},
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            self.observation.callbacks += 1;
            switch (event) {
                .token_preview => |p| {
                    self.observation.previews += 1;
                    std.mem.doNotOptimizeAway(p.span);
                },
                .token_preview_end => self.observation.ends += 1,
                else => {},
            }
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
}
fn Parser(comptime enabled: bool, comptime scanner: dot.ScannerBackend, comptime mode: Mode) type {
    return dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = mode != .plain } } }).Events(Consumer(enabled));
}
noinline fn run(comptime enabled: bool, comptime scanner: dot.ScannerBackend, comptime mode: Mode, source: []const u8, valid: bool) !Observation {
    const P = Parser(enabled, scanner, mode);
    var sink: Consumer(enabled) = .{};
    var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
    var session = P.Session.init(source, frames.storage(), &sink, dot.diagnostic.discard, .{});
    defer session.deinit();
    if (mode == .plain) {
        _ = session.run();
    } else {
        const budget = switch (mode) {
            .budget1 => 1,
            .budget64 => 64,
            .budget4096 => 4096,
            .plain => unreachable,
        };
        while (session.result() == null) {
            const progress = session.advance(budget);
            if (progress.work_used > budget) return error.OverBudget;
            sink.observation.credits += progress.work_used;
        }
    }
    if (session.result().?.outcome != (if (valid) dot.events.Outcome.success else .invalid_syntax)) return error.WrongOutcome;
    std.mem.doNotOptimizeAway(sink.observation);
    return sink.observation;
}
pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("fixture,scanner,mode,enabled,bytes,ns,MB/s,credits,callbacks,previews,ends,session_bytes\n");
    inline for (.{ "dense", "long_unicode", "unfinished" }) |fixture| {
        const dense = comptime std.mem.eql(u8, fixture, "dense");
        const valid = comptime !std.mem.eql(u8, fixture, "unfinished");
        var source: std.ArrayList(u8) = .empty;
        const allocator = init.arena.allocator();
        try source.appendSlice(allocator, if (dense) "graph{" else "graph{a[label=\"");
        for (0..5000) |_| try source.appendSlice(allocator, if (dense) "a[x=1];" else "Straße 中文 😀");
        if (valid) try source.appendSlice(allocator, if (dense) "}" else "\"]}");
        inline for (.{ .scalar, .block }) |scanner| inline for (comptime std.meta.tags(Mode)) |mode| {
            var samples: [2][7]u64 = undefined;
            var observations: [2]Observation = undefined;
            for (0..9) |round| inline for (0..2) |slot| {
                const which = if (round % 2 == 0) slot else 1 - slot;
                switch (which) {
                    inline 0, 1 => |index| {
                        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                        for (0..8) |_| observations[index] = try run(index == 1, scanner, mode, source.items, valid);
                        const stop = std.Io.Clock.Timestamp.now(init.io, .awake);
                        if (round >= 2) samples[index][round - 2] = @intCast(@divTrunc(start.durationTo(stop).raw.nanoseconds, 8));
                    },
                    else => unreachable,
                }
            };
            if (mode != .plain and observations[1].credits != observations[0].credits + observations[1].previews + observations[1].ends) return error.ChangedCoreWork;
            inline for (0..2) |index| {
                std.mem.sort(u64, &samples[index], {}, std.sort.asc(u64));
                const ns = samples[index][3];
                const o = observations[index];
                try w.print("{s},{s},{s},{},{d},{d},{d:.2},{d},{d},{d},{d},{d}\n", .{ fixture, @tagName(scanner), @tagName(mode), index == 1, source.items.len, ns, @as(f64, @floatFromInt(source.items.len)) * 1000 / @as(f64, @floatFromInt(ns)), o.credits, o.callbacks, o.previews, o.ends, @sizeOf(Parser(index == 1, scanner, mode).Session) });
            }
            try w.flush();
        };
    }
}
