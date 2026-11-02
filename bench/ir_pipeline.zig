//! Phase-aware Document -> IR baseline. No event lowering or edge expansion.
//! zig build bench-ir-pipeline -Doptimize=fast -- --corpus /path/to/generated
//! Without --corpus, runs the built-in adversarial shapes only.
//! Timing uses unwrapped allocators; memory uses separate untimed probes.
const std = @import("std");
const dot = @import("dot_parser");
const memory = @import("phase_memory.zig");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});
const Phase = memory.Phase;
const Route = enum { gpa, arena };
const corpus_cases = [_][]const u8{ "nodes", "edges", "edge_chains", "node_attrs", "edge_attrs", "attr_stmts", "subgraphs_flat", "subgraphs_nested", "subgraph_endpoints", "identifiers", "comments", "ports", "minified", "mixed" };
const Shape = enum { deep_nesting, reopened, strict_reopened, giant_chain, giant_attributes, symbolic_product };
const sample_count = 9;
const warmup_count = 3;

const Options = struct {
    corpus: ?[]const u8 = null,
    case: ?[]const u8 = null,
    fn parse(args: []const []const u8) !@This() {
        var options: @This() = .{};
        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            if (i + 1 == args.len) return error.MissingArgument;
            if (std.mem.eql(u8, args[i], "--corpus")) {
                options.corpus = args[i + 1];
            } else if (std.mem.eql(u8, args[i], "--case")) {
                options.case = args[i + 1];
            } else return error.InvalidArgument;
        }
        return options;
    }
    fn selected(self: @This(), name: []const u8) bool {
        return if (self.case) |value| std.mem.eql(u8, value, name) else true;
    }
};

fn fixture(w: *std.Io.Writer, shape: Shape) !void {
    try w.writeAll(if (shape == .strict_reopened) "strict digraph {" else "digraph {");
    switch (shape) {
        .deep_nesting => {
            for (0..50_000) |_| try w.writeAll("{");
            try w.writeAll("a;");
            for (0..50_000) |_| try w.writeAll("}");
        },
        .reopened, .strict_reopened => for (0..1000) |i| {
            try w.print("subgraph s{{n{d}}}->x;", .{i});
        },
        .giant_chain => {
            try w.writeAll("n0");
            for (1..100_000) |i| try w.print("->n{d}", .{i});
            try w.writeAll(";");
        },
        .giant_attributes => {
            try w.writeAll("a[");
            for (0..100_000) |i| try w.print("k{d}=v{d} ", .{ i, i });
            try w.writeAll("];");
        },
        .symbolic_product => {
            try w.writeAll("{");
            for (0..50_000) |i| try w.print("a{d};", .{i});
            try w.writeAll("}->{");
            for (0..50_000) |i| try w.print("b{d};", .{i});
            try w.writeAll("};");
        },
    }
    try w.writeAll("}");
}

fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}
fn elapsed(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    return @intCast(start.durationTo(end).raw.nanoseconds);
}
const Timing = struct { phases: [4]u64, total: u64 };

// These are the same phases as IR.parse: parse/check, lower, release Document.
// Splitting the public calls exposes validation time without library changes.
noinline fn timed(allocator: std.mem.Allocator, source: []const u8, io: std.Io) !Timing {
    const t0 = now(io);
    var parsed = Dot.parseBorrowed(allocator, source, dot.diagnostic.discard, .{});
    const t1 = now(io);
    errdefer parsed.deinit(allocator);
    if (parsed.outcome != .success or parsed.document == null) return error.InvalidFixture;
    const checked = Dot.validate(&parsed.document.?, dot.diagnostic.discard, .{});
    const t2 = now(io);
    if (!checked.documentValid()) return error.InvalidFixture;
    var graph = try IR.lowerComplete(allocator, &parsed.document.?, .{ .interpretation = Dot.interpretation(&parsed.document.?, .{}) });
    const t3 = now(io);
    defer graph.deinit();
    parsed.deinit(allocator);
    const t4 = now(io);
    std.mem.doNotOptimizeAway(graph.nodes);
    return .{ .phases = .{ elapsed(t0, t1), elapsed(t1, t2), elapsed(t2, t3), elapsed(t3, t4) }, .total = elapsed(t0, t4) };
}

fn runTimed(comptime route: Route, backing: std.mem.Allocator, source: []const u8, io: std.Io) !Timing {
    if (route == .gpa) return timed(backing, source, io);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    return timed(arena.allocator(), source, io);
}

noinline fn convenience(allocator: std.mem.Allocator, source: []const u8, io: std.Io) !u64 {
    const start = now(io);
    var result = try IR.parse(allocator, source, .{});
    const end = now(io);
    defer result.deinit();
    if (result.ir() == null) return error.InvalidFixture;
    std.mem.doNotOptimizeAway(result.ir());
    return elapsed(start, end);
}
fn runConvenience(comptime route: Route, backing: std.mem.Allocator, source: []const u8, io: std.Io) !u64 {
    if (route == .gpa) return convenience(backing, source, io);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    return convenience(arena.allocator(), source, io);
}

fn documentBytes(doc: *const dot.Document) usize {
    var bytes: usize = 0;
    inline for (.{ "order", "nodes", "edges", "edge_chains", "edge_links", "scoped_edges", "scoped_edge_links", "ported_references", "subgraph_records", "attributes", "assignments", "attribute_statements" }) |field| {
        const items = @field(doc, field);
        bytes += items.len * @sizeOf(std.meta.Elem(@TypeOf(items)));
    }
    if (doc.comments) |items| bytes += items.len * @sizeOf(dot.Comment);
    return bytes;
}
const Observation = struct {
    stats: [memory.count]memory.Stats,
    arena_capacities: [memory.count]usize,
    arena_peaks: [memory.count]usize,
    peak: usize,
    peak_phase: Phase,
    peak_bound: usize,
    bound_phase: Phase,
    arena_peak: usize,
    arena_peak_phase: Phase,
    doc_used: usize,
    doc_live: usize,
    ir_retained: usize,
    lower_peak: usize,
    statements: usize,
    root_statements: usize,
    counts: dot.ir.GraphCapacities,
};
fn begin(phase: Phase, logical: *memory.Tracker, backing: *memory.Tracker) void {
    logical.begin(phase);
    backing.begin(phase);
}

fn probe(comptime route: Route, allocator: std.mem.Allocator, source: []const u8) !Observation {
    // Wrappers are stable on this stack until graph/Document deinit finishes.
    var backing: memory.Tracker = .{ .backing = allocator };
    var arena = std.heap.ArenaAllocator.init(backing.allocator());
    defer arena.deinit();
    var logical: memory.Tracker = .{ .backing = if (route == .arena) arena.allocator() else allocator };
    const a = logical.allocator();
    var capacities: [memory.count]usize = @splat(0);
    begin(.parse, &logical, &backing);
    var parsed = Dot.parseBorrowed(a, source, dot.diagnostic.discard, .{});
    var owns_document = true;
    defer if (owns_document) parsed.deinit(a);
    if (parsed.outcome != .success or parsed.document == null) return error.InvalidFixture;
    const doc = &parsed.document.?;
    const used = documentBytes(doc);
    const live = logical.live;
    const statements = doc.statementCount();
    const root_statements = doc.rootStatementCount();
    if (live < used) return error.DocumentAccounting;
    capacities[0] = arena.queryCapacity();

    begin(.validate, &logical, &backing);
    const checked = Dot.validate(doc, dot.diagnostic.discard, .{});
    if (!checked.documentValid()) return error.InvalidFixture;
    if (logical.live != live) return error.ValidationRetainedMemory;
    capacities[1] = arena.queryCapacity();

    begin(.lower, &logical, &backing);
    var graph = try IR.lowerComplete(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    var owns_graph = true;
    defer if (owns_graph) graph.deinit();
    const retained = graph.retainedBytes();
    const peak = graph.peak_bytes;
    const counts = graph.capacities();
    if (logical.live != live + retained) return error.IRRetainedAccounting;
    if (logical.stats[@backingInt(Phase.lower)].peak != live + peak) return error.IRPeakAccounting;
    capacities[2] = arena.queryCapacity();

    begin(.release_document, &logical, &backing);
    parsed.deinit(a);
    owns_document = false;
    if (logical.live != retained) return error.DocumentReleaseAccounting;
    capacities[3] = arena.queryCapacity();
    // IR borrows source, not Document pools. Queries must still be usable now.
    var nodes = graph.nodeIterator();
    if (nodes.next()) |node| std.mem.doNotOptimizeAway(node.name());

    begin(.release_ir, &logical, &backing);
    graph.deinit();
    owns_graph = false;
    if (logical.live != 0) return error.LeakedMemory;
    capacities[4] = arena.queryCapacity();
    var arena_peaks: [memory.count]usize = undefined;
    for (&arena_peaks, backing.stats) |*out, stats| out.* = stats.peak;
    return .{ .stats = logical.stats, .arena_capacities = capacities, .arena_peaks = arena_peaks, .peak = logical.peak, .peak_phase = logical.peak_phase, .peak_bound = logical.peakBound(), .bound_phase = logical.boundPhase(), .arena_peak = backing.peak, .arena_peak_phase = backing.peak_phase, .doc_used = used, .doc_live = live, .ir_retained = retained, .lower_peak = peak, .statements = statements, .root_statements = root_statements, .counts = counts };
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}
fn report(init: std.process.Init, w: *std.Io.Writer, name: []const u8, source: []const u8) !void {
    // Init.gpa can select SafeAllocator, libc or SmpAllocator by build mode.
    // Hold the backing allocator constant across build modes. Source loading
    // and reporting still use Init's allocator, outside all measurements.
    const backing = std.heap.smp_allocator;
    // Same accepted graph/counts through the unsplit convenience API.
    const expected = blk: {
        var reference = try IR.parse(backing, source, .{});
        defer reference.deinit();
        const graph = reference.ir() orelse return error.InvalidFixture;
        break :blk graph.capacities();
    };
    if (std.mem.eql(u8, name, "symbolic_product") and (expected.connections != 1 or expected.nodes != 100_000)) return error.ExpandedProduct;

    var samples: [2][6][sample_count]u64 = undefined;
    for (0..warmup_count + sample_count) |round| inline for (0..2) |offset| {
        const selected = (round + offset) % 2;
        switch (@as(Route, @fromBackingInt(@intCast(selected)))) {
            inline else => |route| {
                // Also time the unsplit public convenience, to expose any
                // difference from call separation/clock reads in phase timing.
                var timing: Timing = undefined;
                var direct: u64 = undefined;
                if (round % 2 == 0) {
                    timing = try runTimed(route, backing, source, init.io);
                    direct = try runConvenience(route, backing, source, init.io);
                } else {
                    direct = try runConvenience(route, backing, source, init.io);
                    timing = try runTimed(route, backing, source, init.io);
                }
                if (round >= warmup_count) {
                    for (timing.phases, 0..) |ns, p| samples[selected][p][round - warmup_count] = ns;
                    samples[selected][4][round - warmup_count] = timing.total;
                    samples[selected][5][round - warmup_count] = direct;
                }
            },
        }
    };
    inline for (comptime std.meta.tags(Route), 0..) |route, i| {
        var measured: ?Observation = null;
        var min_peak: usize = std.math.maxInt(usize);
        for (0..3) |_| {
            const observation = try probe(route, backing, source);
            if (!std.meta.eql(expected, observation.counts)) return error.RouteMismatch;
            min_peak = @min(min_peak, observation.peak);
            if (measured == null or observation.peak > measured.?.peak or
                (observation.peak == measured.?.peak and observation.peak_bound > measured.?.peak_bound)) measured = observation;
        }
        const m = measured.?;
        try w.print("{t},{t},{s},{d},{x},{d},{d},{d},{d}", .{ @import("builtin").mode, route, name, source.len, std.hash.Wyhash.hash(0, source), m.statements, m.root_statements, m.counts.nodes, m.counts.connections });
        for (&samples[i]) |*times| try w.print(",{d:.6}", .{@as(f64, @floatFromInt(median(times))) / 1e6});
        try w.print(",{d},{d},{d},{d},{t},{d},{t},{d},{d},{d},{t}", .{ m.doc_used, m.doc_live, min_peak, m.peak, m.peak_phase, m.peak_bound, m.bound_phase, m.ir_retained, m.lower_peak, m.arena_peak, m.arena_peak_phase });
        inline for (0..4) |p| {
            const s = m.stats[p];
            try w.print(",{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}", .{ s.start, s.end, s.peak, s.allocations, s.allocated_bytes, s.growth_moves, s.growth_old_bytes, s.largest_growth_pair, s.resize_ok, s.remap_ok, s.moving_remaps, m.arena_capacities[p], m.arena_peaks[p] });
        }
        try w.writeByte('\n');
        try w.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const options = try Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("build,allocator,case,source_bytes,source_hash,statements,root_statements,nodes,connections,parse_ms,validate_ms,lower_ms,release_document_ms,total_ms,convenience_ms,document_used_bytes,document_live_bytes,route_min_peak_bytes,route_peak_bytes,peak_phase,route_peak_bound_bytes,peak_bound_phase,ir_retained_bytes,lower_only_peak_bytes,arena_backing_peak_bytes,arena_peak_phase");
    inline for (.{ "parse", "validate", "lower", "release_document" }) |phase| inline for (.{ "start_live", "end_live", "peak_live", "allocations", "allocated_bytes", "growth_moves", "growth_old_bytes", "largest_growth_pair", "in_place_resizes", "remaps", "moving_remaps", "arena_capacity", "arena_backing_peak" }) |metric| try w.print(",{s}_{s}", .{ phase, metric });
    try w.writeByte('\n');
    var cases: usize = 0;
    if (options.corpus) |directory| for (corpus_cases) |case| {
        if (!options.selected(case)) continue;
        const filename = try std.fmt.allocPrint(init.gpa, "{s}_M.dot", .{case});
        defer init.gpa.free(filename);
        const path = try std.fs.path.join(init.gpa, &.{ directory, filename });
        defer init.gpa.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(128 * 1024 * 1024));
        defer init.gpa.free(source);
        try report(init, w, case, source);
        cases += 1;
    };
    for (std.meta.tags(Shape)) |shape| {
        if (!options.selected(@tagName(shape))) continue;
        var source = std.Io.Writer.Allocating.init(init.gpa);
        defer source.deinit();
        try fixture(&source.writer, shape);
        try report(init, w, @tagName(shape), source.written());
        cases += 1;
    }
    if (cases == 0) return error.NoMatchingCases;
    try w.flush();
}
