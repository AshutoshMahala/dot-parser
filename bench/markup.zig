//! Standalone baseline: sources/storage are constructed outside timed regions.
//! Decimal MB/s. Fixed-storage retained parsing and count-only execution are
//! measured separately; reserved bytes are not process RSS or allocator overhead.
const std = @import("std");
const markup = @import("markup_parser");
const Runtime = markup.Profile(.{ .runtime_policy = true });
const batch = 16;
const warmups = 5;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    try writer.print("Node={d} Attribute={d} KeyScratch={d} Frame={d} Diagnostic={d} fixed_session={d} bounded_session={d} runtime_session={d}\n", .{
        @sizeOf(markup.Node),                  @sizeOf(markup.Attribute),  @sizeOf(markup.AttributeKeyScratch),
        markup.FixedParseScratch(1).byte_size, @sizeOf(markup.Diagnostic), @sizeOf(markup.Profile(.{}).Session),
        @sizeOf(markup.BoundedSession),        @sizeOf(Runtime.Session),
    });
    inline for (.{ "flat", "mixed", "text", "deep", "attributes", "duplicates" }) |name| {
        var source: std.ArrayList(u8) = .empty;
        if (comptime std.mem.eql(u8, name, "deep")) {
            for (0..10_000) |_| try source.appendSlice(allocator, "<a>");
            for (0..10_000) |_| try source.appendSlice(allocator, "</a>");
        } else if (comptime std.mem.eql(u8, name, "text")) {
            try source.resize(allocator, 1_000_000);
            @memset(source.items, 'x');
        } else {
            const item = if (comptime std.mem.eql(u8, name, "flat")) "<a/>" else if (comptime std.mem.eql(u8, name, "attributes")) "<a x='1' y=\"2\" z='3'/>" else if (comptime std.mem.eql(u8, name, "duplicates")) "<a x='1' y=\"2\" x='3'/>" else "<a><b/>text</a>";
            for (0..50_000) |_| try source.appendSlice(allocator, item);
        }
        const measured = markup.measure(allocator, source.items, markup.diagnostic.discard, .{});
        if (measured.outcome != .success) return error.MeasureFailed;
        const memory: markup.ParseMemory = .{
            .document = .{ .nodes = try allocator.alloc(markup.Node, measured.counts.nodes), .attributes = try allocator.alloc(markup.Attribute, measured.counts.attributes) },
            .scratch = .{ .frames = try allocator.alloc(std.meta.Elem(@FieldType(markup.ParseScratch, "frames")), measured.counts.max_depth) },
        };
        try writer.print("{s}: source={d} nodes={d} attributes={d} retained={d} scratch_reserved={d}\n", .{
            name, source.items.len, measured.counts.nodes, measured.counts.attributes, memory.document.nodes.len * @sizeOf(markup.Node) + memory.document.attributes.len * @sizeOf(markup.Attribute), memory.scratch.frames.len * markup.FixedParseScratch(1).byte_size,
        });
        inline for (.{ "fixed", "runtime_baseline", "runtime_override", "count_only" }) |mode| {
            var times: [9]u64 = undefined;
            var patch: markup.Policy = if (comptime std.mem.eql(u8, mode, "runtime_override")) markup.presets.standard else .{};
            const opaque_patch: *volatile markup.Policy = &patch;
            for (0..warmups + times.len) |round| {
                const input = opaque_patch.*;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var node_sum: u64 = 0;
                for (0..batch) |_| {
                    const counts = if (comptime std.mem.eql(u8, mode, "count_only")) countOnly(source.items, memory.scratch) else if (comptime std.mem.eql(u8, mode, "fixed")) parseFixed(source.items, memory) else parseRuntime(source.items, memory, input);
                    node_sum += counts.nodes;
                }
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (node_sum != @as(u64, measured.counts.nodes) * batch) return error.ParseFailed;
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("  {s}: {d:.3} ms, {d:.1} MB/s\n", .{ mode, ns / 1e6, @as(f64, @floatFromInt(source.items.len)) * 1000 / ns });
        }
        if (comptime std.mem.eql(u8, name, "attributes") or std.mem.eql(u8, name, "duplicates")) {
            const parsed = markup.parseBorrowedIn(source.items, memory, markup.diagnostic.discard, .{});
            const document = parsed.document orelse return error.ParseFailed;
            const capacity = markup.requiredValidationScratch(&document);
            const scratch: markup.ValidationScratch = .{ .attribute_keys = try allocator.alloc(markup.AttributeKeyScratch, capacity) };
            var times: [9]u64 = undefined;
            for (0..warmups + times.len) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var errors: u64 = 0;
                for (0..batch) |_| errors += validateFixed(&document, scratch);
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (errors != (if (comptime std.mem.eql(u8, name, "duplicates")) @as(u64, 50_000 * batch) else 0)) return error.ValidationFailed;
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("  validation_only: {d:.3} ms, {d:.1} MB/s, scratch={d}\n", .{ ns / 1e6, @as(f64, @floatFromInt(source.items.len)) * 1000 / ns, capacity * @sizeOf(markup.AttributeKeyScratch) });
        }
    }
    try writer.flush();
}
noinline fn validateFixed(document: *const markup.Document, scratch: markup.ValidationScratch) u32 {
    const r = markup.validateIn(document, scratch, markup.diagnostic.discard, .{});
    return if (r.completion == .complete) r.errors else std.math.maxInt(u32);
}
noinline fn parseFixed(source: []const u8, memory: markup.ParseMemory) markup.Counts {
    const r = markup.parseBorrowedIn(source, memory, markup.diagnostic.discard, .{});
    return if (r.outcome == .success) r.counts else .{};
}
noinline fn countOnly(source: []const u8, frames: markup.ParseScratch) markup.Counts {
    const r = markup.measureIn(source, frames, markup.diagnostic.discard, .{});
    return if (r.outcome == .success) r.counts else .{};
}
noinline fn parseRuntime(source: []const u8, memory: markup.ParseMemory, patch: markup.Policy) markup.Counts {
    const r = Runtime.parseBorrowedIn(source, memory, markup.diagnostic.discard, .{ .policy = patch });
    return if (r.outcome == .success) r.counts else .{};
}
