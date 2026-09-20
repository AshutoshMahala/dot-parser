//! Run on the standard benchmark machine; no allocation/source construction in
//! the timed region. Compare equivalent fixed and runtime policies separately.
const std = @import("std");
const dot = @import("dot_parser");
const Runtime = dot.Profile(.{ .runtime_policy = true });
const count = 50_000;
const rounds = 9;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const source = try allocator.alloc(u8, 8 + count * 2);
    @memcpy(source[0..7], "graph {");
    for (0..count) |i| @memcpy(source[7 + 2 * i ..][0..2], "a;");
    source[source.len - 1] = '}';
    const memory: dot.ParseMemory = .{ .document = .{
        .statement_ids = try allocator.alloc(dot.StatementId, count),
        .nodes = try allocator.alloc(dot.NodeStatement, count),
        .edges = &.{},
    } };
    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file.interface;
    try writer.print("Document={d}, Diagnostic={d}, fixed session={d}, runtime session={d}, runtime options={d}\n", .{
        @sizeOf(dot.Document), @sizeOf(dot.Diagnostic), @sizeOf(dot.Profile(.{}).Session), @sizeOf(Runtime.Session), @sizeOf(Runtime.FixedParseOptions),
    });
    inline for (.{ .scalar, .block }) |backend| {
        const baseline: dot.Policy = .{ .scanner = backend };
        const Fixed = dot.Profile(.{ .policy = baseline });
        const Configurable = dot.Profile(.{ .policy = baseline, .runtime_policy = true });
        inline for (.{ .fixed, .runtime_baseline, .runtime_override }) |mode| {
            var times: [rounds]u64 = undefined;
            var patch: dot.Policy = if (mode == .runtime_override) baseline else .{};
            const opaque_patch: *volatile dot.Policy = &patch;
            for (0..rounds + 2) |round| {
                // Keep the runtime path opaque to constant propagation; the
                // volatile read itself is outside the timed region.
                const input = opaque_patch.*;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                const parsed = if (mode == .fixed)
                    fixedParse(Fixed, source, memory)
                else
                    try runtimeParse(Configurable, source, memory, input);
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (parsed.outcome != .success or parsed.document.?.statementCount() != count) return error.ParseFailed;
                if (round >= 2) times[round - 2] = @intCast(start.durationTo(end).raw.nanoseconds);
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            try writer.print("{s} {s}: median {d:.3} ms ({d:.3}–{d:.3}), {d} statements\n", .{
                @tagName(backend),                                @tagName(mode),
                @as(f64, @floatFromInt(times[rounds / 2])) / 1e6, @as(f64, @floatFromInt(times[0])) / 1e6,
                @as(f64, @floatFromInt(times[rounds - 1])) / 1e6, count,
            });
        }
    }
    try writer.flush();
}

noinline fn fixedParse(comptime Parser: type, source: []const u8, memory: dot.ParseMemory) dot.FixedParseResult {
    return Parser.parseBorrowedIn(source, memory, dot.diagnostic.discard, .{});
}
noinline fn runtimeParse(comptime Parser: type, source: []const u8, memory: dot.ParseMemory, input: dot.Policy) dot.PolicyError!dot.FixedParseResult {
    return Parser.parseBorrowedIn(source, memory, dot.diagnostic.discard, .{ .policy = input });
}
