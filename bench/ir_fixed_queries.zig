//! Explicit fixed scratch versus growable queries. Lowering and caller buffer
//! allocation are untimed; constructor checks and lazy initialization are timed.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const Route = enum { growable, fixed_used, fixed_bounds, session_4096, session_1 };
const Case = enum { singletons, sets, strict_overlap, reopened, product_prefix, attributes };
const Counts = struct {
    checksum: u64 = 0,
    entries: u32 = 0,
    work: u64 = 0,
    bytes: usize = 0,
    edge_peak: dot.ir.EdgeScratchCapacities = .{},
    attribute_peak: dot.ir.AttributeScratchCapacities = .{},
};
fn fixture(out: *std.Io.Writer, case: Case) !void {
    try out.writeAll(if (case == .strict_overlap or case == .attributes) "strict digraph {" else "digraph {");
    switch (case) {
        .singletons => for (0..2000) |i| {
            try out.print("n{d}->n{d};", .{ i, i + 1 });
        },
        .sets => for (0..1000) |i| {
            try out.print("n{d}->{{a b c}};", .{i});
        },
        .strict_overlap => for (0..400) |_| {
            try out.writeAll("{a b c d}->{a b c d};");
        },
        .reopened => for (0..200) |i| {
            try out.print("subgraph s{{n{d}}}->x;", .{i});
        },
        .product_prefix => {
            try out.writeAll("{");
            for (0..5000) |i| try out.print("n{d};", .{i});
            try out.writeAll("}->{");
            for (5000..10000) |i| try out.print("n{d};", .{i});
            try out.writeAll("};");
        },
        .attributes => for (0..2000) |i| {
            try out.print("a->b[k{d}=v{d}];", .{ i % 16, i });
        },
    }
    try out.writeAll("}");
}
fn run(comptime route: Route, graph: *const IR.Graph, memory: IR.EdgeScratch, am: IR.AttributeScratch, comptime attributes: bool, prefix: bool) !Counts {
    var result: Counts = .{};
    if (attributes) {
        const view = try graph.edgeView(.{ .from = @fromBackingInt(@intCast(0)), .to = @fromBackingInt(@intCast(1)), .first_connection = @fromBackingInt(@intCast(0)), .operator = .directed });
        for (0..32) |_| {
            if (route == .session_4096 or route == .session_1) {
                var s = try IR.attributesSessionIn(view, am, .{});
                defer s.deinit();
                while (true) {
                    const p = s.advance(if (route == .session_1) 1 else 4096);
                    if (p.attribute) |v| {
                        result.checksum +%= v.resolved.attribute orelse 1;
                        result.entries += 1;
                    }
                    if (p.outcome) |o| {
                        if (o == .failure) return o.failure;
                        result.work += p.total_work;
                        break;
                    }
                }
                result.bytes = s.peakBytes();
                result.attribute_peak = s.scratchPeak();
            } else {
                var iterator = if (route == .growable) try view.attributes(.{}) else try view.attributesIn(am, .{});
                defer iterator.deinit();
                while (try iterator.next()) |v| {
                    result.checksum +%= v.resolved.attribute orelse 1;
                    result.entries += 1;
                }
                result.bytes = iterator.peakBytes();
                if (route != .growable) result.attribute_peak = iterator.scratchPeak();
            }
        }
    } else if (route == .session_4096 or route == .session_1) {
        var s = try IR.edgeSessionIn(graph, memory, .{});
        defer s.deinit();
        while (true) {
            const p = s.advance(if (route == .session_1) 1 else 4096);
            result.work = p.total_work;
            if (p.edge) |v| {
                result.checksum +%= @as(u64, @backingInt(v.edge.from)) + @backingInt(v.edge.to) + @backingInt(v.edge.first_connection);
                result.entries += 1;
                if (prefix and result.entries == 1000) break;
            }
            if (p.outcome) |o| {
                if (o == .failure) return o.failure;
                break;
            }
        }
        result.bytes = s.peakBytes();
        result.edge_peak = s.scratchPeak();
    } else {
        var iterator = if (route == .growable) try graph.edgeIterator(.{}) else try graph.edgeIteratorIn(memory, .{});
        defer iterator.deinit();
        while (try iterator.next()) |v| {
            result.checksum +%= @as(u64, @backingInt(v.edge.from)) + @backingInt(v.edge.to) + @backingInt(v.edge.first_connection);
            result.entries += 1;
            if (prefix and result.entries == 1000) break;
        }
        result.bytes = iterator.peakBytes();
        if (route != .growable) result.edge_peak = iterator.scratchPeak();
    }
    return result;
}
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const out = &output.interface;
    try out.print("state,edge,fixed_edge,edge_session,fixed_edge_session,attributes,fixed_attributes,attributes_session,fixed_attributes_session\nbytes,{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
        @sizeOf(IR.Graph.EdgeIterator),      @sizeOf(IR.Graph.FixedEdgeIterator),      @sizeOf(IR.EdgeSession),       @sizeOf(IR.FixedEdgeSession),
        @sizeOf(IR.Graph.AttributeIterator), @sizeOf(IR.Graph.FixedAttributeIterator), @sizeOf(IR.AttributesSession), @sizeOf(IR.FixedAttributesSession),
    });
    try out.writeAll("case,route,ms,entries,credits,peak_bytes,members,pairs,winners\n");
    inline for (comptime std.meta.tags(Case)) |case| {
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixture(&source.writer, case);
        var result = try dot.ir.parse(init.gpa, source.written(), .{});
        defer result.deinit();
        const graph = result.ir() orelse return error.InvalidFixture;
        const layout = try IR.edgeScratchLayout(graph, try IR.edgeScratchBounds(graph, .{}));
        const bytes = try init.gpa.alignedAlloc(u8, .@"16", layout.byte_size);
        defer init.gpa.free(bytes);
        const broad = try layout.bind(bytes);
        const al = try IR.attributeScratchLayout(IR.attributeScratchBounds(graph));
        const ab = try init.gpa.alignedAlloc(u8, .@"16", al.byte_size);
        defer init.gpa.free(ab);
        const broad_attributes = try al.bind(ab);
        const observed = try run(.fixed_bounds, graph, broad, broad_attributes, case == .attributes, case == .product_prefix);
        // Rebind the same bytes after the operation ends; no simultaneous borrow.
        const used = try (try IR.edgeScratchLayout(graph, observed.edge_peak)).bind(bytes);
        const used_attributes = try (try IR.attributeScratchLayout(observed.attribute_peak)).bind(ab);
        var samples: [5][11]u64 = undefined;
        var counts: [5]Counts = undefined;
        const warm = std.Io.Clock.Timestamp.now(init.io, .awake);
        var round: usize = 0;
        var sample: usize = 0;
        while (sample < 11) : (round += 1) {
            const timed = round >= 4 and warm.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds >= 50_000_000;
            for (0..5) |offset| {
                const index = (round + offset) % 5;
                const memory = if (index == @backingInt(Route.fixed_bounds)) broad else used;
                const attrs_memory = if (index == @backingInt(Route.fixed_bounds)) broad_attributes else used_attributes;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                const c = switch (@as(Route, @fromBackingInt(@intCast(index)))) {
                    inline else => |route| try run(route, graph, memory, attrs_memory, case == .attributes, case == .product_prefix),
                };
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (c.checksum != observed.checksum or c.entries != observed.entries) return error.ResultMismatch;
                counts[index] = c;
                if (timed) samples[index][sample] = @intCast(start.durationTo(end).raw.nanoseconds);
            }
            if (timed) sample += 1;
        }
        for (std.meta.tags(Route), 0..) |route, i| {
            std.mem.sort(u64, &samples[i], {}, std.sort.asc(u64));
            const c = counts[i];
            try out.print("{t},{t},{d:.5},{d},{d},{d},{d},{d},{d}\n", .{ case, route, @as(f64, @floatFromInt(samples[i][5])) / 1e6, c.entries, c.work, c.bytes, c.edge_peak.members, c.edge_peak.strict_pairs, c.attribute_peak.winners });
        }
    }
    try out.flush();
}
