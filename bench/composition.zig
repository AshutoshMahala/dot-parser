//! One-shot composition: time includes parse/validate/free, but excludes source
//! construction and instrumentation. A separate allocator probe counts calls and
//! requested live/peak bytes (not RSS or allocator-internal remap overhead).
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const count = 1000;
const batch = 10;

const Tracking = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *@This(), old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.allocs += 1;
        const ptr = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.grow(0, len);
        return ptr;
    }
    fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.resizes += 1;
        if (!self.backing.rawResize(bytes, alignment, len, ra)) return false;
        self.grow(bytes.len, len);
        return true;
    }
    fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.remaps += 1;
        const ptr = self.backing.rawRemap(bytes, alignment, len, ra) orelse return null;
        self.grow(bytes.len, len);
        return ptr;
    }
    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.backing.rawFree(bytes, alignment, ra);
        self.live -= bytes.len;
    }
};

noinline fn run(comptime P: type, allocator: std.mem.Allocator, source: []const u8, valid: bool, visited: u32) !void {
    var result = try P.parseAndValidate(allocator, source, P.DiagnosticSink.discard, .{});
    defer result.deinit(allocator);
    if (result.dot.outcome != .success or result.documentValid() != valid or result.markup.visited != visited) return error.UnexpectedResult;
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    inline for (.{ "plain", "labels", "invalid", "large_first" }) |fixture| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(init.gpa);
        try source.appendSlice(init.gpa, "digraph {");
        if (comptime std.mem.eql(u8, fixture, "large_first")) {
            try source.appendSlice(init.gpa, "n[label=<<a>");
            for (0..10_000) |_| try source.appendSlice(init.gpa, "<b/>");
            try source.appendSlice(init.gpa, "</a>>];");
        }
        const statement = comptime if (std.mem.eql(u8, fixture, "labels"))
            "n[label=<<b x='1' y='2'>t</b>>];"
        else if (std.mem.eql(u8, fixture, "invalid"))
            "n[label=<<b x='1' x='2'></wrong>>];"
        else
            "n;";
        // Let outer storage overtake the first child's tree to expose the cost
        // of retaining that child's high-water capacity through the operation.
        for (0..if (comptime std.mem.eql(u8, fixture, "large_first")) 50_000 else count) |_| try source.appendSlice(init.gpa, statement);
        try source.appendSlice(init.gpa, "}");
        const valid = comptime !std.mem.eql(u8, fixture, "invalid");
        const visited: u32 = comptime if (std.mem.eql(u8, fixture, "plain")) 0 else if (std.mem.eql(u8, fixture, "large_first")) 1 else count;
        inline for (.{ false, true }) |runtime| inline for (.{ .scalar, .block }) |scanner| {
            const P = dot.Profile(.{ .runtime_policy = runtime, .policy = .{ .scanner = scanner }, .processors = .{ .markup = markup.Profile(.{ .runtime_policy = runtime, .policy = .{ .mode = .structural, .scanner = scanner } }) } });
            var tracking: Tracking = .{ .backing = init.gpa };
            try run(P, tracking.allocator(), source.items, valid, visited);
            if (tracking.live != 0) return error.Leak;
            var times: [9]u64 = undefined;
            for (0..times.len + 3) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                for (0..batch) |_| try run(P, init.gpa, source.items, valid, visited);
                const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
                if (round >= 3) times[round - 3] = @intCast(@divTrunc(elapsed, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[times.len / 2]);
            try writer.print("{s}/{s}/{s}: bytes={d} alloc={d} resize={d} remap={d} peak={d} median={d:.3}ms {d:.1}MB/s\n", .{
                fixture, if (runtime) "runtime" else "fixed", @tagName(scanner), source.items.len, tracking.allocs, tracking.resizes, tracking.remaps, tracking.peak, ns / 1e6, @as(f64, @floatFromInt(source.items.len)) * 1000 / ns,
            });
        };
    }
    try writer.flush();
}
