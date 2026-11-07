//! Event one-shot versus composed sessions. No expansion; identical inputs.
const std = @import("std");
const dot = @import("dot_parser");
const fixtures = @import("ir_lowering_sessions.zig");
const memory = @import("phase_memory.zig");
const IR = dot.ir.Lowering(.{});
const Plain = IR.FromEvents(dot.Profile(.{}));
const Scheduled = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } }).FromEvents(dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }));
const Route = enum { direct, session_run, session_4096, session_1 };
fn Result(comptime route: Route) type {
    return if (route == .direct) Plain.Result else Scheduled.Result;
}
fn run(comptime route: Route, a: std.mem.Allocator, source: []const u8, credits: *u64) !Result(route) {
    if (route == .direct) return Plain.parse(a, source, .{});
    var session = try Scheduled.Session.init(a, source, .{});
    defer session.deinit();
    if (route == .session_run) {
        _ = session.run();
    } else while (session.advance(if (route == .session_1) 1 else 4096).outcome == null) {}
    credits.* = session.total_work;
    return session.takeResult();
}
pub fn main(init: std.process.Init) !void {
    var out_buffer: [8192]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &out_buffer);
    const w = &output.interface;
    try w.print("# Inline session state: {d} bytes; heap figures exclude borrowed source\n", .{@sizeOf(Scheduled.Session)});
    try w.writeAll("build,case,route,source_bytes,ms,peak_bytes,retained_bytes,allocations,credits\n");
    for (std.meta.tags(fixtures.Case)) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try fixtures.fixture(&source.writer, case);
        var times: [4][9]u64 = undefined;
        for (0..11) |round| inline for (0..4) |turn| {
            const routes = std.meta.tags(Route);
            switch (routes[(round + turn) % 4]) {
                inline else => |route| {
                    var credits: u64 = 0;
                    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                    var result = try run(route, init.gpa, source.written(), &credits);
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (result.ir() == null) return error.Rejected;
                    std.mem.doNotOptimizeAway(result.ir().?.nodes.len);
                    result.deinit();
                    if (round >= 2) times[@backingInt(route)][round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
                },
            }
        };
        inline for (comptime std.meta.tags(Route)) |route| {
            var tracker: memory.Tracker = .{ .backing = init.gpa };
            var credits: u64 = 0;
            var result = try run(route, tracker.allocator(), source.written(), &credits);
            const retained = result.ir().?.retainedBytes();
            if (tracker.live != retained) return error.RetainedAccounting;
            result.deinit();
            if (tracker.live != 0) return error.LeakedMemory;
            const ns = @import("ir_pipeline.zig").median(&times[@backingInt(route)]);
            try w.print("{t},{t},{t},{d},{d:.6},{d},{d},{d},{d}\n", .{ @import("builtin").mode, case, route, source.written().len, @as(f64, @floatFromInt(ns)) / 1e6, tracker.peak, retained, tracker.stats[0].allocations, credits });
        }
        try w.flush();
    }
}
