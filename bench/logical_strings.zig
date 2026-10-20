//! Explicit logical binding, not automatic host dispatch. Fixed session storage
//! and no processing allocations; source duplication is outside timed regions.
const std = @import("std");
const s = @import("string_processor");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const report = @import("report.zig");
const Mode = enum { run, budget1, budget64 };
const Host = enum { plain, dot, markup };

fn reader(comptime host: Host, bytes: []const u8) Reader(host) {
    const input: s.Fragment = .{ .bytes = bytes, .origin = 31 };
    return if (host == .markup) Reader(host).init(input, .{}) catch unreachable else Reader(host).init(input) catch unreachable;
}
fn Reader(comptime host: Host) type {
    return switch (host) {
        .plain => s.LogicalReader(.utf8),
        .dot => dot.identifier.LogicalReader(.utf8),
        .markup => markup.LogicalReader(.utf8),
    };
}
const Observation = struct { valid: bool, credits: u64 };
noinline fn run(comptime P: type, comptime host: Host, comptime mode: Mode, bytes: []const u8) Observation {
    const B = P.WithReader(Reader(host));
    var session = B.Session.init(reader(host, bytes), P.Sink.discard, .{}) catch unreachable;
    if (mode == .run) return .{ .valid = session.run().valid(), .credits = 0 };
    var credits: u64 = 0;
    while (true) {
        const budget: u32 = if (mode == .budget1) 1 else 64;
        const progress = session.advance(budget);
        if (progress.work_used > budget) unreachable;
        credits += progress.work_used;
        if (progress.outcome != null) break;
    }
    return .{ .valid = session.result().?.valid(), .credits = credits };
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    const csv = try report.csvMode(init);
    if (csv) try writer.writeAll(report.header) else try writer.writeAll("Logical UTF-8 equality; processing heap=0; throughput counts source bytes, not decoded bytes\n");
    inline for (comptime .{
        .{ "short", "A&B", "\"A\" + \"&B\"", "A&amp;B" },
        .{ "long", std.mem.asBytes(&@as([512]["A&B ".len]u8, @splat("A&B ".*))), "\"" ++ std.mem.asBytes(&@as([512]["A&B ".len]u8, @splat("A&B ".*))) ++ "\"", std.mem.asBytes(&@as([512]["A&amp;B ".len]u8, @splat("A&amp;B ".*))) },
        .{ "unicode", "Straße 中文 😀", "\"Straße \" + \"中文 😀\"", "Stra&#223;e 中文 &#x1f600;" },
        .{ "glue", "AB", "\"A\" /*" ++ std.mem.asBytes(&@as([512]["comment ".len]u8, @splat("comment ".*))) ++ "*/ + \"B\"", "A&#" ++ &@as([4096]u8, @splat('0')) ++ "66;" },
    }) |fixture| {
        const P = s.Profile(.{ .policy = .{ .execution = .{ .metering = true }, .validation = .{
            .equals = .{ .expected = fixture[1], .severity = .err },
        } } });
        inline for (std.enums.values(Host)) |host| {
            const source = try init.gpa.dupe(u8, fixture[1 + @backingInt(host)]);
            defer init.gpa.free(source);
            inline for (std.enums.values(Mode)) |mode| {
                const observation = run(P, host, mode, source);
                if (!observation.valid) return error.InvalidResult;
                const iterations = @max(100, 500_000 / source.len);
                var times: [5]u64 = undefined;
                for (0..7) |sample| {
                    var accepted: usize = 0;
                    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
                    for (0..iterations) |_| {
                        std.mem.doNotOptimizeAway(source.ptr);
                        accepted += @intFromBool(run(P, host, mode, source).valid);
                    }
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (accepted != iterations) return error.InvalidResult;
                    if (sample >= 2) times[sample - 2] = @intCast(begin.durationTo(end).raw.nanoseconds);
                }
                std.mem.sort(u64, &times, {}, std.sort.asc(u64));
                const ns = @as(f64, @floatFromInt(times[2])) / @as(f64, @floatFromInt(iterations));
                const id = fixture[0] ++ "/" ++ @tagName(host) ++ "/" ++ @tagName(mode);
                const size = @sizeOf(P.WithReader(Reader(host)).Session);
                if (csv) try report.row(writer, id, source.len, ns, size, observation.credits, 0) else try writer.print("{s} bytes={d} ns/value={d:.1} MB/s={d:.1} session={d} credits={d}\n", .{ id, source.len, ns, @as(f64, @floatFromInt(source.len)) * 1000 / ns, size, observation.credits });
            }
        }
    }
    try writer.flush();
}
