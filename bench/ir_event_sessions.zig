//! Event one-shot versus composed sessions. No expansion; identical inputs.
const std = @import("std");
const dot = @import("dot_parser");
const fixtures = @import("ir_lowering_sessions.zig");
const memory = @import("phase_memory.zig");
const IR = dot.ir.Lowering(.{});
const Plain = IR.FromEvents(dot.Profile(.{}));
const Scheduled = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } }).FromEvents(dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }));
const Route = enum { direct, session_run, session_4096, session_1, block_4096, cancel_every_1, cancel_every_64, runtime_every_1, runtime_every_64 };
const routes = std.meta.tags(Route);
const warmups = 6;
const samples = 9;
fn runtime(comptime route: Route) bool {
    return route == .runtime_every_1 or route == .runtime_every_64;
}
fn cancelled(comptime route: Route) bool {
    return runtime(route) or route == .cancel_every_1 or route == .cancel_every_64;
}
fn interval(comptime route: Route) u32 {
    return if (route == .cancel_every_64 or route == .runtime_every_64) 64 else 1;
}
fn API(comptime route: Route) type {
    if (route == .direct) return Plain;
    if (comptime runtime(route)) return dot.ir.Lowering(.{ .runtime_policy = true }).FromEvents(dot.Profile(.{ .runtime_policy = true }));
    const exec = .{ .metering = true, .cancellation = cancelled(route), .cancellation_interval = interval(route) };
    return dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = exec.metering, .cancellation = exec.cancellation, .cancellation_interval = exec.cancellation_interval } } }).FromEvents(dot.Profile(.{ .policy = .{ .scanner = if (route == .block_4096) .block else .scalar, .execution = .{ .metering = exec.metering, .cancellation = exec.cancellation, .cancellation_interval = exec.cancellation_interval } } }));
}
const Polls = struct {
    count: u64 = 0,
    fn requested(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.count += 1;
        return false;
    }
};
fn run(comptime route: Route, a: std.mem.Allocator, source: []const u8, credits: *u64, polls: *Polls) !API(route).Result {
    if (route == .direct) return Plain.parse(a, source, .{});
    const E = API(route);
    const hook: dot.Cancellation = .{ .context = polls, .is_requested = Polls.requested };
    const exec = .{ .metering = true, .cancellation = true, .cancellation_interval = interval(route) };
    const options: E.Options = if (comptime runtime(route)) .{
        .dot = .{ .policy = .{ .execution = .{ .metering = exec.metering, .cancellation = exec.cancellation, .cancellation_interval = exec.cancellation_interval } }, .cancellation = hook },
        .lowering = .{ .policy = .{ .execution = .{ .metering = exec.metering, .cancellation = exec.cancellation, .cancellation_interval = exec.cancellation_interval } }, .cancellation = hook },
    } else if (comptime cancelled(route)) .{ .dot = .{ .cancellation = hook }, .lowering = .{ .cancellation = hook } } else .{};
    var session = try E.Session.init(a, source, options);
    defer session.deinit();
    if (route == .session_run) {
        _ = session.run();
    } else while (true) {
        const progress = if (comptime runtime(route)) try session.advance(4096) else session.advance(if (route == .session_1) 1 else 4096);
        if (progress.outcome != null) break;
    }
    credits.* = session.total_work;
    return session.takeResult();
}
pub fn main(init: std.process.Init) !void {
    var out_buffer: [8192]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &out_buffer);
    const w = &output.interface;
    try w.print("# Inline session state: {d} bytes; heap figures exclude borrowed source\n", .{@sizeOf(Scheduled.Session)});
    try w.writeAll("build,case,route,source_bytes,ms,peak_bytes,retained_bytes,allocations,credits,cancel_polls\n");
    for (std.meta.tags(fixtures.Case)) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try fixtures.fixture(&source.writer, case);
        var times: [routes.len][samples]u64 = undefined;
        for (0..warmups + samples) |round| inline for (0..routes.len) |turn| {
            switch (routes[(round + turn) % routes.len]) {
                inline else => |route| {
                    var credits: u64 = 0;
                    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                    var polls: Polls = .{};
                    var result = try run(route, init.gpa, source.written(), &credits, &polls);
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (result.ir() == null) return error.Rejected;
                    std.mem.doNotOptimizeAway(result.ir().?.nodes.len);
                    result.deinit();
                    if (round >= warmups) times[@backingInt(route)][round - warmups] = @intCast(start.durationTo(end).raw.nanoseconds);
                },
            }
        };
        inline for (comptime std.meta.tags(Route)) |route| {
            var tracker: memory.Tracker = .{ .backing = init.gpa };
            var credits: u64 = 0;
            var polls: Polls = .{};
            var result = try run(route, tracker.allocator(), source.written(), &credits, &polls);
            const retained = result.ir().?.retainedBytes();
            if (tracker.live != retained) return error.RetainedAccounting;
            result.deinit();
            if (tracker.live != 0) return error.LeakedMemory;
            const ns = @import("ir_pipeline.zig").median(&times[@backingInt(route)]);
            try w.print("{t},{t},{t},{d},{d:.6},{d},{d},{d},{d},{d}\n", .{ @import("builtin").mode, case, route, source.written().len, @as(f64, @floatFromInt(ns)) / 1e6, tracker.peak, retained, tracker.stats[0].allocations, credits, polls.count });
        }
        try w.flush();
    }
}
