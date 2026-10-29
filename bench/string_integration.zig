//! Same harness works before routing exists: those builds emit default rows
//! only. Parse/validate/free are timed; source creation and accounting are not.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const strings = @import("string_processor");
const report = @import("report.zig");
const integrated = !@import("integration_options").default_only and @typeInfo(@TypeOf(dot.Profile)).@"fn".param_types[0] == null;
const Mode = enum { default, passthrough, process };
const n = 2000;

fn Parser(comptime api: type, comptime mode: Mode, comptime expected: []const u8) type {
    const Text = strings.Profile(.{});
    if (api == dot) return switch (mode) {
        .default => dot.Profile(.{}),
        .passthrough => dot.Profile(.{ .processors = .{ .string = Text } }),
        .process => dot.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .attributes = .{
            .label = .{ .string = .{ .process = .{ .validation = .{ .equals = .{ .expected = expected, .severity = .err } } } } },
        } } }),
    };
    return switch (mode) {
        .default => markup.Profile(.{ .policy = .{ .mode = .structural } }),
        .passthrough => markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural } }),
        .process => markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .attributes = .{
            .label = .{ .string = .{ .process = .{ .validation = .{ .equals = .{ .expected = expected, .severity = .err } } } } },
        } } }),
    };
}

noinline fn run(comptime api: type, comptime mode: Mode, comptime expected: []const u8, allocator: std.mem.Allocator, source: []const u8) !void {
    const P = Parser(api, mode, expected);
    const Sink = if (mode == .process) P.DiagnosticSink else api.DiagnosticSink;
    const call = P.parseAndValidate(allocator, if (api == dot) source else .{ .bytes = source, .origin = 0 }, Sink.discard, .{});
    var result = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
    defer if (api == dot) result.deinit(allocator) else result.deinit();
    if (!result.documentValid()) return error.InvalidResult;
    if (mode == .process and result.string.processed != n) return error.MissingValues;
    std.mem.doNotOptimizeAway(&result);
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    const csv = try report.csvMode(init);
    if (csv) try w.writeAll(report.header);
    inline for (comptime .{ dot, markup }) |api| {
        inline for (comptime .{
            .{ "short", "Seattle", "\"Seattle\"", "'Seattle'" },
            .{ "decoded", "A&B", "\"A\"/*join*/+\"&B\"", "'A&amp;B'" },
            .{ "unicode", "Straße 中文 😀", "\"Straße 中文 😀\"", "'Straße 中文 &#x1f600;'" },
            .{ "long", std.mem.asBytes(&@as([256]["abcdefgh ".len]u8, @splat("abcdefgh ".*))), "\"" ++ std.mem.asBytes(&@as([256]["abcdefgh ".len]u8, @splat("abcdefgh ".*))) ++ "\"", "'" ++ std.mem.asBytes(&@as([256]["abcdefgh ".len]u8, @splat("abcdefgh ".*))) ++ "'" },
        }) |fixture| {
            var source: std.ArrayList(u8) = .empty;
            defer source.deinit(init.gpa);
            try source.appendSlice(init.gpa, if (api == dot) "graph{" else "<root>");
            for (0..n) |_| {
                try source.appendSlice(init.gpa, if (api == dot) "a[label=" else "<a label=");
                try source.appendSlice(init.gpa, if (api == dot) fixture[2] else fixture[3]);
                try source.appendSlice(init.gpa, if (api == dot) " other=kept];" else " other='kept'/>");
            }
            try source.appendSlice(init.gpa, if (api == dot) "}" else "</root>");
            var times: [3][9]u64 = undefined;
            for (0..12) |round| {
                inline for (0..3) |slot| {
                    const index = if (round % 2 == 0) slot else 2 - slot;
                    switch (@as(Mode, @fromBackingInt(@intCast(index)))) {
                        inline else => |mode| if (comptime integrated or mode == .default) {
                            const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
                            for (0..3) |_| try run(api, mode, fixture[1], init.gpa, source.items);
                            const duration = begin.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
                            if (round >= 3) times[@backingInt(mode)][round - 3] = @intCast(@divTrunc(duration, 3));
                        },
                    }
                }
            }
            inline for (comptime std.meta.tags(Mode)) |mode| if (comptime integrated or mode == .default) {
                const samples = &times[@backingInt(mode)];
                std.mem.sort(u64, samples, {}, std.sort.asc(u64));
                const ns: f64 = @floatFromInt(samples[4]);
                const id = comptime (if (api == dot) "dot/" else "markup/") ++ fixture[0] ++ "/" ++ @tagName(mode);
                var tracked = std.testing.FailingAllocator.init(init.gpa, .{});
                try run(api, mode, fixture[1], tracked.allocator(), source.items);
                if (tracked.allocated_bytes != tracked.freed_bytes) return error.Leak;
                if (comptime integrated and mode != .default) {
                    var baseline = std.testing.FailingAllocator.init(init.gpa, .{});
                    try run(api, .default, fixture[1], baseline.allocator(), source.items);
                    if (baseline.allocations != tracked.allocations or baseline.allocated_bytes != tracked.allocated_bytes)
                        return error.AdditionalAllocation;
                }
                if (csv) try report.row(w, id, source.items.len, ns, 0, 0, 0) else try w.print("{s}: {d:.3} ms, {d:.2} MB/s, allocations={d}, cumulative requested bytes={d}\n", .{ id, ns / 1e6, @as(f64, @floatFromInt(source.items.len)) * 1000 / ns, tracked.allocations, tracked.allocated_bytes });
            };
        }
    }
    try w.flush();
}
