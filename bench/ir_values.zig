//! Value access costs, separate from lowering. A benchmark-only one-byte kind
//! cache measures the tradeoff; production retains no kind/operand array.
const std = @import("std");
const dot = @import("dot_parser");
const Graph = dot.ir.Lowering(.{}).Graph;
const Operation = enum { kind, cache_build, cached_kind, parts, format, bounded_write, to_string };
const long: [4096]u8 = @splat('x');

pub fn main(init: std.process.Init) !void {
    var out_buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    const out = &output.interface;
    try out.writeAll("value_case,values,value_bytes,operation,ns_per_value,extra_kind_bytes,retained_bytes\n");
    inline for (.{
        .{ "bare", "red", 10_000 },
        .{ "quoted", "\"café_😀\"", 10_000 },
        .{ "concatenation", "\"a\" /*glue*/ + \"\" + <<b>A&amp;B</b>>", 10_000 },
        .{ "markup", "<<b><c>bee</c></b>>", 10_000 },
        .{ "empty", "\"\"", 10_000 },
        .{ "long_quoted", "\"" ++ long ++ "\"", 512 },
        .{ "long_markup", "<<b>" ++ long ++ "</b>>", 512 },
    }) |case| {
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try source.writer.writeAll("digraph {");
        for (0..case[2]) |i| try source.writer.print("n{d}[label={s}];", .{ i, case[1] });
        try source.writer.writeAll("}");
        var result = try dot.ir.parse(init.gpa, source.written(), .{});
        defer result.deinit();
        const ir = result.ir() orelse return error.BadFixture;
        const cache = try init.gpa.alloc(dot.ir.ValueKind, ir.attributes.len);
        defer init.gpa.free(cache);
        // One byte per written attribute, the optimistic no-padding layout.
        // Timing excludes allocation; cache_build includes the required scan.
        try run(.cache_build, init.gpa, ir, cache);
        inline for (comptime std.meta.tags(Operation)) |op| {
            var samples: [9]u64 = undefined;
            for (0..12) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                try run(op, init.gpa, ir, cache);
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (round >= 3) samples[round - 3] = @intCast(start.durationTo(end).raw.nanoseconds);
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            try out.print("{s},{d},{d},{s},{d:.2},{d},{d}\n", .{
                case[0],                                       case[2],                                                                                                case[1].len,        @tagName(op),
                @as(f64, @floatFromInt(samples[4])) / case[2], if (op == .cached_kind or op == .cache_build) cache.len * @sizeOf(dot.ir.ValueKind) else @as(usize, 0), ir.retainedBytes(),
            });
            try out.flush();
        }
    }
}

noinline fn run(comptime op: Operation, allocator: std.mem.Allocator, ir: *const Graph, cache: []dot.ir.ValueKind) !void {
    var buffer: [4096]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&buffer);
    for (ir.attributes, 0..) |attribute, index| {
        // Certified written attributes; avoids timing attribute-key lookup.
        const v = ir.attributeValue(.{ .value = .{ .written = attribute.value }, .kind = .explicit, .attribute = @intCast(index), .origin = .{ .declaration = 0 }, .scope = .root });
        switch (op) {
            .kind => std.mem.doNotOptimizeAway(v.kind()),
            .cache_build => cache[index] = v.kind(),
            .cached_kind => std.mem.doNotOptimizeAway(cache[index]),
            .parts => {
                var parts = v.parts();
                while (parts.next()) |part| std.mem.doNotOptimizeAway(part);
            },
            .format => try v.format(&discard.writer),
            .bounded_write => try v.writeLogicalWith(&discard.writer, .{}),
            .to_string => {
                const copy = try v.toString(allocator);
                defer allocator.free(copy);
                std.mem.doNotOptimizeAway(copy);
            },
        }
    }
    std.mem.doNotOptimizeAway(discard.fullCount());
    std.mem.doNotOptimizeAway(cache);
}
