//! Fixed-storage parse execution: dense syntax and long ASCII/UTF-8 runs.
//! Sources and storage are prepared before timing. Decimal MB/s; credits retain
//! each scanner's existing meaning. Includes default, one-credit, batched,
//! cancellation and runtime-policy paths. No validation or allocation is timed.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const count = 10_000;
const Mode = enum { plain, budget1, budget64, budget4096, cancel1, cancel64, runtime1, runtime64 };
const Probe = struct {
    calls: u64 = 0,
    fn poll(raw: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        std.mem.doNotOptimizeAway(self.calls);
        return false;
    }
};
const Observation = struct { credits: u64 = 0, polls: u64 = 0 };
fn Parser(comptime api: type, comptime block: bool, comptime mode: Mode) type {
    var p: api.Policy = .{ .scanner = if (block) .block else .scalar, .execution = .{
        .metering = mode != .plain,
        .cancellation = mode == .cancel1 or mode == .cancel64,
        .cancellation_interval = if (mode == .cancel64) 64 else 1,
    } };
    if (api == markup) p.mode = .structural;
    return api.Profile(.{ .policy = p, .runtime_policy = mode == .runtime1 or mode == .runtime64 });
}
noinline fn run(comptime api: type, comptime block: bool, comptime mode: Mode, source: []const u8, memory: api.ParseMemory) !Observation {
    const P = Parser(api, block, mode);
    var probe: Probe = .{};
    const runtime = mode == .runtime1 or mode == .runtime64;
    const started = P.Session.init(source, memory, api.diagnostic.discard, if (mode == .cancel1 or mode == .cancel64)
        .{ .cancellation = .{ .context = &probe, .is_requested = Probe.poll } }
    else
        .{});
    var session = if (runtime) try started else started;
    defer session.deinit();
    var credits: u64 = 0;
    const parsed = if (mode == .plain) session.run() else done: {
        const budget = if (mode == .budget1 or mode == .runtime1) 1 else if (mode == .budget64 or mode == .runtime64) 64 else 4096;
        while (true) {
            const advancing = session.advance(budget);
            const p = if (runtime) try advancing else advancing;
            if (p.work_used > budget) return error.OverBudget;
            credits += p.work_used;
            if (p.outcome != null) break;
        }
        break :done session.result().?;
    };
    if (parsed.outcome != .success or parsed.document == null) return error.ParseFailed;
    std.mem.doNotOptimizeAway(parsed.document.?);
    return .{ .credits = credits, .polls = probe.calls };
}
pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    const allocator = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("parser,fixture,scanner,mode,bytes,ns,MB/s,credits,polls,session_bytes\n");
    inline for (.{ dot, markup }) |api| {
        const is_markup = api == markup;
        const Storage = if (is_markup) markup.FixedDocumentStorage(.{ .nodes = count + 1, .attributes = count }) else dot.FixedDocumentStorage(.{ .statements = count, .nodes = count, .attributes = count });
        const storage = try allocator.create(Storage);
        storage.* = .{};
        var scratch: (if (is_markup) markup.FixedParseScratch(1) else dot.FixedParseScratch(.{ .nesting = 1 })) = .{};
        const memory: api.ParseMemory = .{ .document = storage.storage(), .scratch = scratch.storage() };
        inline for (.{ "dense", "long_ascii", "long_unicode" }) |fixture| {
            const dense = comptime std.mem.eql(u8, fixture, "dense");
            var source: std.ArrayList(u8) = .empty;
            const begin = if (is_markup) (if (dense) "<root>" else "<a>") else (if (dense) "graph{" else "graph{a[x=\"");
            const item = if (dense) (if (is_markup) "<a x='1'/>" else "a[x=1];") else if (comptime std.mem.eql(u8, fixture, "long_ascii")) "The quick brown fox jumps over the lazy dog. " else "Straße 中文 😀";
            const end = if (is_markup) (if (dense) "</root>" else "</a>") else (if (dense) "}" else "\"]}");
            try source.appendSlice(allocator, begin);
            for (0..count) |_| try source.appendSlice(allocator, item);
            try source.appendSlice(allocator, end);
            inline for (.{ false, true }) |block| {
                var samples: [8][7]u64 = undefined;
                var observations: [8]Observation = undefined;
                for (0..9) |round| {
                    inline for (comptime std.meta.tags(Mode)) |slot| {
                        // Reverse order between rounds; no parallel timing.
                        const i = if (round % 2 == 0) @backingInt(slot) else 7 - @backingInt(slot);
                        switch (@as(Mode, @fromBackingInt(@intCast(i)))) {
                            inline else => |mode| {
                                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                                var observation: Observation = undefined;
                                for (0..4) |_| observation = try run(api, block, mode, source.items, memory);
                                const stop = std.Io.Clock.Timestamp.now(init.io, .awake);
                                observations[@backingInt(mode)] = observation;
                                if (round >= 2) samples[@backingInt(mode)][round - 2] = @intCast(@divTrunc(start.durationTo(stop).raw.nanoseconds, 4));
                            },
                        }
                    }
                }
                inline for (comptime std.meta.tags(Mode)) |mode| {
                    const index = @backingInt(mode);
                    std.mem.sort(u64, &samples[index], {}, std.sort.asc(u64));
                    const ns = samples[index][3];
                    const observation = observations[index];
                    if (mode != .plain and observation.credits != observations[@backingInt(Mode.budget1)].credits) return error.ChangedCredits;
                    try w.print("{s},{s},{s},{s},{d},{d},{d:.2},{d},{d},{d}\n", .{
                        if (is_markup) "markup" else "dot",                                             fixture,             if (block) "block" else "scalar", @tagName(mode),                            source.items.len, ns,
                        @as(f64, @floatFromInt(source.items.len)) * 1000 / @as(f64, @floatFromInt(ns)), observation.credits, observation.polls,                @sizeOf(Parser(api, block, mode).Session),
                    });
                }
                try w.flush();
            }
        }
    }
}
