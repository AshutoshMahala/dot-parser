//! Opt-in DOT delimiter/metadata costs; all variants run in alternating order.
//! zig build bench-event-boundaries -Doptimize=fast
const std = @import("std");
const dot = @import("dot_parser");
const Selection = enum { none, metadata, all };
const Mode = enum { plain, budget1, budget4096 };
const Counts = struct { work: usize = 0, callbacks: usize = 0, delimiters: usize = 0, checksum: usize = 0 };
fn Consumer(comptime selection: Selection) type {
    return struct {
        pub const observations: dot.events.Observations = .{ .delimiter = selection == .all };
        pub const statement_extents = selection != .none;
        pub const coverage = selection != .none;
        counts: Counts = .{},
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            self.counts.callbacks += 1;
            switch (event) {
                .delimiter => |v| {
                    self.counts.delimiters += 1;
                    self.counts.checksum +%= v.span.start;
                },
                inline .commit_node, .commit_edge, .commit_edge_chain, .commit_subgraph, .commit_assignment, .commit_attribute_statement => |v| {
                    if (v.extent) |span| self.counts.checksum +%= span.len;
                },
                else => {},
            }
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
}
fn Parser(comptime selection: Selection, comptime scanner: dot.ScannerBackend, comptime mode: Mode) type {
    return dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = mode != .plain } } }).Events(Consumer(selection));
}
noinline fn run(comptime selection: Selection, comptime scanner: dot.ScannerBackend, comptime mode: Mode, source: []const u8) !Counts {
    const P = Parser(selection, scanner, mode);
    var sink: Consumer(selection) = .{};
    var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
    var session = P.Session.init(source, frames.storage(), &sink, dot.diagnostic.discard, .{});
    defer session.deinit();
    if (mode == .plain) {
        _ = session.run();
    } else {
        const budget = if (mode == .budget1) 1 else 4096;
        while (session.result() == null) {
            const progress = session.advance(budget);
            if (progress.work_used > budget) return error.OverBudget;
            sink.counts.work += progress.work_used;
        }
    }
    const result = session.result().?;
    if (result.outcome != .success) return error.WrongOutcome;
    if (selection != .none) {
        if (!result.coverage.root_closed or result.coverage.retained_end != source.len) return error.WrongCoverage;
        sink.counts.checksum +%= result.coverage.retained_end;
    }
    std.mem.doNotOptimizeAway(sink.counts);
    return sink.counts;
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("fixture,scanner,mode,selection,bytes,ns,MB/s,credits,callbacks,delimiters,session_bytes,checksum\n");
    inline for (.{ "nodes", "attributes_scopes" }, .{ "a;\n", "subgraph s { a:p [] [x=y]; b -> c [z=w]; }\n" }) |fixture, line| {
        var source: std.ArrayList(u8) = .empty;
        const allocator = init.arena.allocator();
        try source.appendSlice(allocator, "digraph{");
        for (0..5000) |_| try source.appendSlice(allocator, line);
        try source.appendSlice(allocator, "}");
        inline for (.{ .scalar, .block }) |scanner| inline for (comptime std.meta.tags(Mode)) |mode| {
            var samples: [3][7]u64 = undefined;
            var counts: [3]Counts = undefined;
            for (0..9) |round| inline for (0..3) |slot| {
                const which = (round + slot) % 3;
                switch (@as(Selection, @fromBackingInt(@intCast(which)))) {
                    inline else => |selection| {
                        const index = @backingInt(selection);
                        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                        for (0..4) |_| counts[index] = try run(selection, scanner, mode, source.items);
                        const stop = std.Io.Clock.Timestamp.now(init.io, .awake);
                        if (round >= 2) samples[index][round - 2] = @intCast(@divTrunc(start.durationTo(stop).raw.nanoseconds, 4));
                    },
                }
            };
            if (mode != .plain and (counts[1].work != counts[0].work or counts[2].work != counts[0].work + counts[2].delimiters)) return error.ChangedCoreWork;
            inline for (comptime std.meta.tags(Selection), 0..) |selection, index| {
                std.mem.sort(u64, &samples[index], {}, std.sort.asc(u64));
                const ns = samples[index][3];
                const c = counts[index];
                try w.print("{s},{t},{t},{t},{d},{d},{d:.2},{d},{d},{d},{d},{d}\n", .{
                    fixture, scanner, mode, selection, source.items.len, ns, @as(f64, @floatFromInt(source.items.len)) * 1000 / @as(f64, @floatFromInt(ns)), c.work, c.callbacks, c.delimiters, @sizeOf(Parser(selection, scanner, mode).Session), c.checksum,
                });
            }
            try w.flush();
        };
    }
}
