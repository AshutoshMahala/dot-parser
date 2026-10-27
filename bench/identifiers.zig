//! End-to-end event-only parsing plus a logical-name reference index.
//! Compare checked helpers with parser-certified names. Source construction and
//! table reservation are outside timing; both paths use the same storage.
const std = @import("std");
const dot = @import("dot_parser");
const count = 10_000;
const unique = 1_000;

fn Consumer(comptime trusted: bool) type {
    const Context = struct {
        pub fn hash(_: @This(), key: dot.identifier.Parsed) u64 {
            return (if (trusted) key.hash() else dot.identifier.hash(key.raw)) catch unreachable;
        }
        pub fn eql(_: @This(), a: dot.identifier.Parsed, b: dot.identifier.Parsed) bool {
            return (if (trusted) a.eql(b) else dot.identifier.eql(a.raw, b.raw)) catch unreachable;
        }
    };
    return struct {
        source: []const u8,
        table: std.HashMapUnmanaged(dot.identifier.Parsed, u32, Context, std.hash_map.default_max_load_percentage) = .empty,
        count: usize = 0,
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            switch (event) {
                .commit_node => |node| {
                    const name = dot.identifier.fromName(self.source, node.value.identifier);
                    const entry = self.table.getOrPutAssumeCapacity(name);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += 1;
                    self.count += 1;
                },
                else => {},
            }
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
}

noinline fn run(comptime trusted: bool, consumer: *Consumer(trusted)) !void {
    consumer.table.clearRetainingCapacity();
    consumer.count = 0;
    const P = dot.Events(Consumer(trusted));
    var scratch: P.FixedParseScratch(.{ .nesting = 1 }) = .{};
    const result = P.parseIn(consumer.source, scratch.storage(), consumer, dot.diagnostic.discard, .{});
    if (result.outcome != .success or consumer.count != count or consumer.table.count() != unique)
        return error.InvalidIndex;
    var values = consumer.table.valueIterator();
    while (values.next()) |value| if (value.* != count / unique) return error.InvalidReferenceCount;
    std.mem.doNotOptimizeAway(consumer);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.print("{d} statements, {d} unique names; event-only parse + reference index.\nNine alternating samples, four parses/sample; no timed allocation.\n", .{ count, unique });
    inline for (.{
        .{ "bare", "node_", "", "" },
        .{ "quoted", "\"node_", "", "\"" },
        .{ "concatenated", "\"node_\"/**/+\"", "", "\"" },
        .{ "escaped", "\"node_\\\"_", "", "\"" },
        .{ "unicode", "\"café_東京_😀_", "", "\"" },
        .{ "long-quoted", "\"node_", "_" ++ std.mem.asBytes(&@as([128]["abcdefgh".len]u8, @splat("abcdefgh".*))), "\"" },
    }) |fixture| {
        var source: std.Io.Writer.Allocating = .init(allocator);
        defer source.deinit();
        try source.writer.writeAll("graph {");
        for (0..count) |i| try source.writer.print("{s}{d}{s}{s};", .{ fixture[1], i % unique, fixture[2], fixture[3] });
        try source.writer.writeAll("}");
        var checked: Consumer(false) = .{ .source = source.written() };
        var trusted: Consumer(true) = .{ .source = source.written() };
        defer checked.table.deinit(allocator);
        defer trusted.table.deinit(allocator);
        var tracked = std.testing.FailingAllocator.init(allocator, .{});
        try checked.table.ensureTotalCapacity(tracked.allocator(), unique);
        try trusted.table.ensureTotalCapacity(tracked.allocator(), unique);
        if (checked.table.capacity() != trusted.table.capacity()) return error.DifferentStorage;
        var times: [2][9]u64 = undefined;
        for (0..12) |round| {
            for (0..2) |slot| {
                const index = if (round % 2 == 0) slot else 1 - slot;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                for (0..4) |_| {
                    if (index == 0) try run(false, &checked) else try run(true, &trusted);
                }
                const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
                if (round >= 3) times[index][round - 3] = @intCast(@divTrunc(elapsed, 4));
            }
        }
        for (&times) |*samples| std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        const before: f64 = @floatFromInt(times[0][4]);
        const after: f64 = @floatFromInt(times[1][4]);
        try w.print("{s}: {d} bytes, checked {d:.3} ms ({d:.1} MB/s), trusted {d:.3} ms ({d:.1} MB/s), time {d:.1}%, index storage {d} bytes/path, allocations {d}/path\n", .{
            fixture[0],                 source.written().len,
            before / 1e6,               @as(f64, @floatFromInt(source.written().len)) * 1000 / before,
            after / 1e6,                @as(f64, @floatFromInt(source.written().len)) * 1000 / after,
            (after / before - 1) * 100, tracked.allocated_bytes / 2,
            tracked.allocations / 2,
        });
        try w.flush();
    }
}
