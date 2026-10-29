//! Cancellation polling tradeoffs. Source, pools and session initialization are
//! outside timing. Credits and callback counts are reported, not elapsed-time
//! guarantees. No callbacks request cancellation during these throughput runs.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const count = 30_000;
const Request = struct {
    polls: usize = 0,
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return false;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &output_buffer);
    const writer = &output.interface;
    try writer.writeAll("parser,fixture,scanner,policy,metered,interval,bytes,ns,MB/s,polls,credits,session_bytes\n");
    inline for (.{ false, true }) |is_markup| {
        const api = if (is_markup) markup else dot;
        const Storage = if (is_markup) markup.FixedDocumentStorage(.{ .nodes = count + 1, .attributes = count }) else dot.FixedDocumentStorage(.{ .statements = count, .nodes = count, .attributes = count });
        const storage = try allocator.create(Storage);
        storage.* = .{};
        var scratch: (if (is_markup) markup.FixedParseScratch(1) else dot.FixedParseScratch(.{ .nesting = 1 })) = .{};
        const memory: api.ParseMemory = .{ .document = storage.storage(), .scratch = scratch.storage() };
        inline for (.{ false, true }) |long| {
            var source: std.ArrayList(u8) = .empty;
            const start = if (is_markup) (if (long) "<a>" else "<root>") else (if (long) "graph{a[x=\"" else "graph{");
            const item = if (long) "The quick brown fox jumps over the lazy dog. " else if (is_markup) "<a x='1'/>" else "a[x=1];";
            const end = if (is_markup) (if (long) "</a>" else "</root>") else (if (long) "\"]}" else "}");
            try source.appendSlice(allocator, start);
            for (0..count) |_| try source.appendSlice(allocator, item);
            try source.appendSlice(allocator, end);
            inline for (.{ false, true }) |block| inline for (.{ false, true }) |metered| {
                // Disabled controls expose overhead even without a live hook.
                try run(init.io, writer, api, memory, source.items, long, block, metered, false, false, 1);
                inline for (.{ false, true }) |runtime| inline for (.{ 1, 4, 16, 64, 256 }) |interval| {
                    try run(init.io, writer, api, memory, source.items, long, block, metered, true, runtime, interval);
                };
            };
        }
    }
    try writer.flush();
}

fn run(io: std.Io, writer: *std.Io.Writer, comptime api: type, memory: api.ParseMemory, source: []const u8, long: bool, comptime block: bool, comptime metered: bool, comptime cancellable: bool, comptime runtime: bool, comptime interval: u32) !void {
    const P = api.Profile(.{ .runtime_policy = runtime, .policy = blk: {
        var p: api.Policy = .{ .scanner = if (block) .block else .scalar, .execution = .{ .metering = metered, .cancellation = cancellable, .cancellation_interval = if (runtime) 1 else interval } };
        if (api == markup) p.mode = .structural;
        break :blk p;
    } });
    var samples: [9]u64 = undefined;
    var polls: usize = 0;
    var credits: usize = 0;
    const warm_start = std.Io.Clock.Timestamp.now(io, .awake);
    var warmed = false;
    var sample: usize = 0;
    while (sample < samples.len) {
        var request: Request = .{};
        const hook: api.Cancellation = .{ .context = &request, .is_requested = Request.poll };
        const started = P.Session.init(source, memory, api.diagnostic.discard, if (runtime)
            .{ .policy = .{ .execution = .{ .cancellation_interval = interval } }, .cancellation = hook }
        else
            .{ .cancellation = if (cancellable) hook else {} });
        var session = if (runtime) try started else started;
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var work: usize = 0;
        const result = if (metered) done: {
            while (true) {
                const advancing = session.advance(4096);
                const progress = if (runtime) try advancing else advancing;
                work += progress.work_used;
                if (progress.outcome != null) break;
            }
            break :done session.result().?;
        } else session.run();
        const end = std.Io.Clock.Timestamp.now(io, .awake);
        if (result.outcome != .success) return error.ParseFailed;
        if (warmed) {
            samples[sample] = @intCast(start.durationTo(end).raw.nanoseconds);
            sample += 1;
        } else if (warm_start.durationTo(end).raw.nanoseconds >= 150_000_000) {
            warmed = true;
        }
        polls = request.polls;
        credits = work;
        session.deinit();
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    try writer.print("{s},{s},{s},{s},{any},{d},{d},{d},{d:.3},{d},{d},{d}\n", .{
        if (api == markup) "markup" else "dot", if (long) "long" else "dense", if (block) "block" else "scalar",
        if (runtime) "runtime" else "fixed",    metered,                       if (cancellable) interval else 0,
        source.len,                             samples[4],                    @as(f64, @floatFromInt(source.len)) * 1000 / @as(f64, @floatFromInt(samples[4])),
        polls,                                  credits,                       @sizeOf(P.Session),
    });
}
