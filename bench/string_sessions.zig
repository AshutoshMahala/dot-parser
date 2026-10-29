//! Opt-in execution overhead, allocations and caller-owned session size.
const std = @import("std");
const s = @import("string_processor");
const report = @import("report.zig");

const Variant = enum { default, plain, runtime_plain, budget1, budget64, run, cancel1, cancel64, runtime1, runtime64, custom1, custom64, custom_step64, one_of64 };
const StepOnlyEquals = struct {
    pub const Settings = []const u8;
    pub const defaults: Settings = "";
    pub const uses_comparison = true;
    pub const State = s.validators.Equals.State;
    pub const step = s.validators.Equals.step;
};
fn isRuntime(comptime variant: Variant) bool {
    return variant == .runtime_plain or variant == .runtime1 or variant == .runtime64;
}
fn isPlain(comptime variant: Variant) bool {
    return variant == .default or variant == .plain or variant == .runtime_plain;
}
fn isCustom(comptime variant: Variant) bool {
    return variant == .custom1 or variant == .custom64 or variant == .custom_step64;
}
fn Checker(comptime variant: Variant, comptime text: []const u8) type {
    return s.Profile(.{
        .runtime_policy = isRuntime(variant),
        .custom = if (variant == .custom_step64) StepOnlyEquals else if (isCustom(variant)) s.validators.Equals else s.validators.None,
        .policy = .{
            .execution = .{
                .metering = !isPlain(variant),
                .cancellation = variant == .cancel1 or variant == .cancel64,
                .cancellation_interval = if (variant == .cancel64) 64 else 1,
            },
            .custom = if (isCustom(variant)) text else {},
            .validation = .{
                .equals = .{ .expected = text, .severity = if (variant == .default or isCustom(variant) or variant == .one_of64) .off else .err },
                .custom = if (isCustom(variant)) .err else .off,
                .one_of = .{ .values = &.{ "not this", text }, .severity = if (variant == .one_of64) .err else .off },
            },
        },
    });
}
const Hook = struct {
    calls: u64 = 0,
    fn poll(raw: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        std.mem.doNotOptimizeAway(self.calls);
        return false;
    }
};
const Observation = struct { valid: bool, credits: u64 = 0, polls: u64 = 0 };
noinline fn run(comptime P: type, comptime variant: Variant, bytes: []const u8) Observation {
    var hook: Hook = .{};
    var options: P.Options = .{};
    if (variant == .cancel1 or variant == .cancel64) options.cancellation = .{ .context = &hook, .is_requested = Hook.poll };
    if (comptime isPlain(variant)) return .{ .valid = (P.parseAndValidate(.{ .bytes = bytes, .origin = 0 }, P.Sink.discard, options) catch unreachable).valid() };
    var session = P.Session.init(.{ .bytes = bytes, .origin = 0 }, P.Sink.discard, options) catch unreachable;
    defer session.deinit();
    if (variant == .run) return .{ .valid = session.run().valid() };
    var credits: u64 = 0;
    while (true) {
        const budget: u32 = if (variant == .budget1 or variant == .runtime1 or variant == .custom1) 1 else 64;
        const progress = if (comptime isRuntime(variant)) session.advance(budget) catch unreachable else session.advance(budget);
        if (progress.work_used > budget) unreachable;
        credits += progress.work_used;
        if (progress.outcome != null) break;
    }
    return .{ .valid = session.result().?.valid(), .credits = credits, .polls = hook.calls };
}
pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(1_000_000);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &output_buffer);
    const writer = &output.interface;
    const csv = try report.csvMode(init);
    if (csv) try writer.writeAll(report.header) else try writer.writeAll("UTF-8 exact checks (default: encoding only); processor heap=0; fixed policies unless runtime*\n");
    const mixed = comptime std.mem.asBytes(&@as([10]["The quick brown fox. ".len]u8, @splat("The quick brown fox. ".*))) ++ "中文";
    inline for (comptime .{ "Seattle", std.mem.asBytes(&@as([200]["The quick brown fox. ".len]u8, @splat("The quick brown fox. ".*))), std.mem.asBytes(&@as([64]["Straße 中文 😀".len]u8, @splat("Straße 中文 😀".*))), std.mem.asBytes(&@as([64]["中文".len]u8, @splat("中文".*))), std.mem.asBytes(&@as([64]["😀".len]u8, @splat("😀".*))), std.mem.asBytes(&@as([8][mixed.len]u8, @splat(mixed.*))) }, .{ "short", "long_ascii", "unicode", "cjk", "emoji", "mixed" }) |text, fixture| {
        const bytes = try init.gpa.dupe(u8, text);
        defer init.gpa.free(bytes);
        inline for (comptime std.meta.tags(Variant)) |variant| {
            const P = Checker(variant, text);
            const iterations = @max(100, 1_000_000 / text.len);
            var times: [7]u64 = undefined;
            const observation = run(P, variant, bytes);
            if (!observation.valid) return error.InvalidResult;
            for (0..9) |sample| {
                var accepted: usize = 0;
                const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
                for (0..iterations) |_| {
                    std.mem.doNotOptimizeAway(bytes.ptr);
                    accepted += @intFromBool(run(P, variant, bytes).valid);
                }
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (accepted != iterations) return error.InvalidResult;
                if (sample >= 2) times[sample - 2] = @intCast(begin.durationTo(end).raw.nanoseconds);
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns = @as(f64, @floatFromInt(times[3])) / @as(f64, @floatFromInt(iterations));
            if (csv) try report.row(writer, fixture ++ "/" ++ @tagName(variant), bytes.len, ns, if (isPlain(variant)) 0 else @sizeOf(P.Session), observation.credits, observation.polls) else try writer.print("{s} bytes={d} ns/value={d:.1} MB/s={d:.1} state={d} credits={d} polls={d}\n", .{
                @tagName(variant),                                           bytes.len,           ns,                @as(f64, @floatFromInt(bytes.len)) * 1000 / ns,
                if (isPlain(variant)) @as(usize, 0) else @sizeOf(P.Session), observation.credits, observation.polls,
            });
        }
    }
    try writer.flush();
}
