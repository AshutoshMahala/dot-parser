//! Run on the standard benchmark machine; no allocation/source construction in
//! the timed region. Compare equivalent fixed and runtime policies separately.
const std = @import("std");
const dot = @import("dot_parser");
const Runtime = dot.Profile(.{ .runtime_policy = true });
const count = 50_000;
const rounds = 9;
const parses_per_sample = 4;
const warmup_ns = 150 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file.interface;
    try writer.print("Document={d}, Diagnostic={d}, fixed session={d}, runtime session={d}, runtime options={d}\n", .{
        @sizeOf(dot.Document), @sizeOf(dot.Diagnostic), @sizeOf(dot.Profile(.{}).Session), @sizeOf(Runtime.Session), @sizeOf(Runtime.FixedParseOptions),
    });
    try writer.print("Per case: at least {d} ms warm-up, {d} samples of {d} parses; times are per-parse averages\n", .{
        warmup_ns / std.time.ns_per_ms, rounds, parses_per_sample,
    });
    inline for (.{ "nodes", "edges", "subgraph_endpoints" }) |fixture| {
        const line = comptime if (std.mem.eql(u8, fixture, "nodes")) "a;\n" else if (std.mem.eql(u8, fixture, "edges")) "a -> b;\n" else "{a;} -> {b;};\n";
        const source = try allocator.alloc(u8, 8 + count * line.len);
        @memcpy(source[0..7], "graph {");
        for (0..count) |i| @memcpy(source[7 + line.len * i ..][0..line.len], line);
        source[source.len - 1] = '}';
        const measured = dot.measure(allocator, source, dot.diagnostic.discard, .{});
        const capacities = measured.capacities orelse return error.MeasureFailed;
        var memory: dot.ParseMemory = .{ .document = .{ .statement_ids = &.{}, .nodes = &.{}, .edges = &.{} } };
        inline for (@typeInfo(dot.DocumentStorage).@"struct".field_names) |field| {
            const capacity = @field(capacities, if (std.mem.eql(u8, field, "statement_ids")) "statements" else field);
            @field(memory.document, field) = try allocator.alloc(std.meta.Child(@FieldType(dot.DocumentStorage, field)), capacity);
        }
        var scratch: dot.FixedParseScratch(.{ .nesting = 1 }) = .{};
        memory.scratch = scratch.storage();
        try writer.print("\n{s}: {d} bytes, {d} statements; parse-only fixed pools\n", .{ fixture, source.len, capacities.statements });
        try run(init.io, writer, source, memory, capacities.statements);
    }
    try writer.flush();
}

fn run(io: std.Io, writer: *std.Io.Writer, source: []const u8, memory: dot.ParseMemory, statements: usize) !void {
    inline for (.{ .scalar, .block }) |backend| {
        const baseline: dot.Policy = .{ .scanner = backend };
        const Fixed = dot.Profile(.{ .policy = baseline });
        const Configurable = dot.Profile(.{ .policy = baseline, .runtime_policy = true });
        inline for (.{ .fixed, .runtime_baseline, .runtime_override, .runtime_partial }) |mode| {
            var times: [rounds]u64 = undefined;
            var patch: dot.Policy = if (mode == .runtime_override) baseline else .{};
            if (mode == .runtime_partial) patch.retention.partial = true;
            const opaque_patch: *volatile dot.Policy = &patch;
            // Two short parses do not reliably settle first-row warm-up effects.
            // Warm every case by elapsed time and average several timed parses
            // per sample. Policy reads and result checks remain outside timing.
            const warming = std.Io.Clock.Timestamp.now(io, .awake);
            while (warming.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds < warmup_ns) {
                const input = opaque_patch.*;
                const parsed = if (mode == .fixed)
                    fixedParse(Fixed, source, memory)
                else
                    try runtimeParse(Configurable, source, memory, input);
                if (parsed.outcome != .success or parsed.document.?.statementCount() != statements) return error.ParseFailed;
            }
            for (&times) |*time| {
                var total: u64 = 0;
                for (0..parses_per_sample) |_| {
                    // Keep the runtime path opaque to constant propagation; the
                    // volatile read itself is outside the timed region.
                    const input = opaque_patch.*;
                    const start = std.Io.Clock.Timestamp.now(io, .awake);
                    const parsed = if (mode == .fixed)
                        fixedParse(Fixed, source, memory)
                    else
                        try runtimeParse(Configurable, source, memory, input);
                    const end = std.Io.Clock.Timestamp.now(io, .awake);
                    if (parsed.outcome != .success or parsed.document.?.statementCount() != statements) return error.ParseFailed;
                    total += @intCast(start.durationTo(end).raw.nanoseconds);
                }
                time.* = total / parses_per_sample;
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            try writer.print("{s} {s}: median {d:.3} ms ({d:.3}–{d:.3}), {d:.1} MB/s\n", .{
                @tagName(backend),                                @tagName(mode),
                @as(f64, @floatFromInt(times[rounds / 2])) / 1e6, @as(f64, @floatFromInt(times[0])) / 1e6,
                @as(f64, @floatFromInt(times[rounds - 1])) / 1e6, @as(f64, @floatFromInt(source.len)) * 1e3 / @as(f64, @floatFromInt(times[rounds / 2])),
            });
        }
    }
}

noinline fn fixedParse(comptime Parser: type, source: []const u8, memory: dot.ParseMemory) dot.FixedParseResult {
    return Parser.parseBorrowedIn(source, memory, dot.diagnostic.discard, .{});
}
noinline fn runtimeParse(comptime Parser: type, source: []const u8, memory: dot.ParseMemory, input: dot.Policy) dot.PolicyError!dot.FixedParseResult {
    return Parser.parseBorrowedIn(source, memory, dot.diagnostic.discard, .{ .policy = input });
}
