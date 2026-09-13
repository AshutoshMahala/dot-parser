//! Fixed-session overhead; allocation/source construction are outside timing.
const std = @import("std");
const dot = @import("dot_parser");
const count = 200_000;
const Polls = struct {
    count: usize = 0,
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.count += 1;
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const source = try allocator.alloc(u8, 8 + count * 2);
    @memcpy(source[0..7], "graph {");
    for (0..count) |i| @memcpy(source[7 + i * 2 ..][0..2], "a;");
    source[source.len - 1] = '}';
    const storage: dot.DocumentStorage = .{
        .statement_ids = try allocator.alloc(dot.StatementId, count),
        .nodes = try allocator.alloc(dot.NodeStatement, count),
        .edges = &.{},
    };
    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        const Session = dot.FixedSession(.{ .metering = metering, .cancellation = cancellation });
        var times: [9]u64 = undefined;
        var polls: usize = 0;
        for (0..11) |round| {
            var probe: Polls = .{};
            var session = Session.init(source, storage, dot.diagnostic.discard, .{
                .cancellation = if (cancellation) .{ .context = &probe, .is_requested = Polls.poll } else {},
            });
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            const result = if (metering) blk: {
                while (session.advance(256).outcome == null) {}
                break :blk session.result().?;
            } else session.run();
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            if (result.outcome != .success or result.document.?.statementCount() != count) return error.ParseFailed;
            if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
            polls = probe.count;
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        try file.interface.print("metering={any}, cancellation={any}: session {d} B, driver {d} B, median {d:.2} ms ({d:.2}–{d:.2}), polls {d}\n", .{
            metering,                                cancellation,                            @sizeOf(Session),                        @sizeOf(@FieldType(Session, "machine")),
            @as(f64, @floatFromInt(times[4])) / 1e6, @as(f64, @floatFromInt(times[0])) / 1e6, @as(f64, @floatFromInt(times[8])) / 1e6, polls,
        });
    };
    try file.interface.flush();
}
