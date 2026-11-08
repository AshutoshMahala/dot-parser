//! Whole-route fixed Document -> IR versus fixed event construction.
//! Explicit exact/bounded/roomy reservations; optional counting is timed alone.
//! Parser and lowering scratch share bytes on the Document route because their
//! lifetimes do not overlap. No edge expansion. Allocation is outside timing.
const std = @import("std");
const dot = @import("dot_parser");
const cases = @import("ir_pipeline.zig");
const D = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});
const E = IR.FromEvents(D);
const A = std.heap.smp_allocator;
const Route = enum { document, events };
const Sizing = enum { exact, bounds, roomy };
const samples = 9;
const Frame = std.meta.Elem(@FieldType(dot.ParseScratch, "frames"));
const Buffers = struct {
    graph: []align(16) u8,
    scratch: []align(16) u8,
    fn init(graph_bytes: usize, scratch_bytes: usize) !Buffers {
        const graph = try A.alignedAlloc(u8, .@"16", graph_bytes);
        errdefer A.free(graph);
        const scratch = try A.alignedAlloc(u8, .@"16", scratch_bytes);
        return .{ .graph = graph, .scratch = scratch };
    }
    fn deinit(self: Buffers) void {
        A.free(self.graph);
        A.free(self.scratch);
    }
    fn frames(self: Buffers, n: usize) []Frame {
        if (n == 0) return &.{};
        const ptr: [*]Frame = @ptrCast(self.scratch.ptr);
        return ptr[0..n];
    }
};
const DocumentMemory = struct {
    storage: dot.DocumentStorage = .{},
    bytes: usize = 0,
    fn init(counts: dot.DocumentCapacities) !DocumentMemory {
        var value: DocumentMemory = .{};
        errdefer value.deinit();
        inline for (comptime std.meta.fieldNames(dot.DocumentStorage)) |field| {
            const T = std.meta.Elem(@FieldType(dot.DocumentStorage, field));
            const n = @field(counts, if (std.mem.eql(u8, field, "statement_ids")) "statements" else field);
            @field(value.storage, field) = try A.alloc(T, n);
            value.bytes += n * @sizeOf(T);
        }
        return value;
    }
    fn deinit(self: DocumentMemory) void {
        inline for (comptime std.meta.fieldNames(dot.DocumentStorage)) |field| A.free(@field(self.storage, field));
    }
};
fn doubled(value: anytype) @TypeOf(value) {
    var result = value;
    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |field| if (@FieldType(@TypeOf(value), field) != bool) {
        @field(result, field) *= 2;
    };
    return result;
}
fn now(io: std.Io) std.Io.Clock.Timestamp {
    return .now(io, .awake);
}
fn elapsed(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) u64 {
    return @intCast(start.durationTo(end).raw.nanoseconds);
}
const Timed = struct { parse: u64 = 0, validation: u64 = 0, lower: u64 = 0, total: u64 };
noinline fn fixedDocument(io: std.Io, source: []const u8, document: dot.DocumentStorage, parser_frames: []Frame, memory: IR.LoweringMemory) !Timed {
    const start = now(io);
    const parsed = D.parseBorrowedIn(source, .{ .document = document, .scratch = .{ .frames = parser_frames } }, dot.diagnostic.discard, .{});
    const p = now(io);
    const doc = &(parsed.document orelse return error.InvalidFixture);
    const checked = D.validate(doc, dot.diagnostic.discard, .{});
    const v = now(io);
    if (!checked.documentValid()) return error.InvalidFixture;
    const lowered = IR.lowerCompleteIn(doc, memory, .{ .interpretation = D.interpretation(doc, .{}) });
    const end = now(io);
    if (lowered.outcome == .failure) return lowered.outcome.failure;
    std.mem.doNotOptimizeAway(lowered.graph.?.nodes);
    return .{ .parse = elapsed(start, p), .validation = elapsed(p, v), .lower = elapsed(v, end), .total = elapsed(start, end) };
}
noinline fn fixedEvents(io: std.Io, source: []const u8, memory: E.ParseMemory) !Timed {
    const start = now(io);
    const result = E.parseIn(source, memory, .{});
    const end = now(io);
    if (result.outcome == .failure) return result.outcome.failure;
    if (result.graph == null) return error.InvalidFixture;
    std.mem.doNotOptimizeAway(result.graph.?.nodes);
    return .{ .total = elapsed(start, end) };
}
fn report(init: std.process.Init, w: *std.Io.Writer, name: []const u8, source: []const u8) !void {
    var previous = D.parseAndValidate(A, source, dot.diagnostic.discard, .{});
    defer previous.deinit(A);
    if (!previous.documentValid()) return error.InvalidFixture;
    const doc = &previous.document.?;
    const counts = doc.capacities();
    const event_bounds = try E.parseBounds(counts, .{});
    const lower_bounds = try IR.loweringBounds(counts, .{});
    var grown = try E.parse(A, source, .{});
    defer grown.deinit();
    const used = grown.ir().?.capacities();
    const probe_layout = try E.parseLayout(used, event_bounds.scratch);
    const probe_buffers = try Buffers.init(probe_layout.graph_bytes, probe_layout.scratch_bytes);
    defer probe_buffers.deinit();
    const probe = E.parseIn(source, try probe_layout.bind(probe_buffers.graph, probe_buffers.scratch), .{});
    if (probe.outcome == .failure) return probe.outcome.failure;
    const event_peak = probe.scratch_peak;
    const lower_probe_layout = try IR.loweringLayout(used, lower_bounds.scratch);
    const lower_probe = try Buffers.init(lower_probe_layout.graph_bytes, lower_probe_layout.scratch_bytes);
    defer lower_probe.deinit();
    const lowered = IR.lowerCompleteIn(doc, try lower_probe_layout.bind(lower_probe.graph, lower_probe.scratch), .{ .interpretation = D.interpretation(doc, .{}) });
    if (lowered.outcome == .failure) return lowered.outcome.failure;
    const lower_peak = lowered.scratch_peak;
    var document = try DocumentMemory.init(counts);
    defer document.deinit();
    inline for (comptime std.meta.tags(Sizing)) |sizing| {
        const g = switch (sizing) {
            .exact => used,
            .bounds => event_bounds.graph,
            .roomy => doubled(used),
        };
        const s = switch (sizing) {
            .exact => event_peak,
            .bounds => event_bounds.scratch,
            .roomy => doubled(event_peak),
        };
        const ls = switch (sizing) {
            .exact => lower_peak,
            .bounds => lower_bounds.scratch,
            .roomy => doubled(lower_peak),
        };
        const el = try E.parseLayout(g, s);
        const ll = try IR.loweringLayout(g, ls);
        const events = try Buffers.init(el.graph_bytes, el.scratch_bytes);
        defer events.deinit();
        const frames = if (sizing == .bounds) counts.subgraphs else event_peak.nesting * @as(usize, if (sizing == .roomy) 2 else 1);
        const document_buffers = try Buffers.init(ll.graph_bytes, @max(ll.scratch_bytes, frames * @sizeOf(Frame)));
        defer document_buffers.deinit();
        const em = try el.bind(events.graph, events.scratch);
        const lm = try ll.bind(document_buffers.graph, document_buffers.scratch);
        var times: [2][4][samples]u64 = undefined;
        var measure_times: [samples]u64 = undefined;
        for (0..3 + samples) |round| {
            inline for (0..2) |turn| {
                const route: Route = if ((round + turn) % 2 == 0) .document else .events;
                const timing = if (route == .document) try fixedDocument(init.io, source, document.storage, document_buffers.frames(frames), lm) else try fixedEvents(init.io, source, em);
                if (round >= 3) {
                    const index: usize = if (route == .document) 0 else 1;
                    times[index][0][round - 3] = timing.total;
                    times[index][1][round - 3] = timing.parse;
                    times[index][2][round - 3] = timing.validation;
                    times[index][3][round - 3] = timing.lower;
                }
            }
            const start = now(init.io);
            const measured = D.measureIn(source, .{ .frames = document_buffers.frames(frames) }, dot.diagnostic.discard, .{});
            const end = now(init.io);
            if (measured.outcome != .success) return error.CountFailed;
            if (round >= 3) measure_times[round - 3] = elapsed(start, end);
        }
        const counting_ms = @as(f64, @floatFromInt(cases.median(&measure_times))) / 1e6;
        inline for (comptime std.meta.tags(Route), 0..) |route, ri| {
            const scratch_bytes = if (route == .document) document_buffers.scratch.len else events.scratch.len;
            const document_bytes = if (route == .document) document.bytes else 0;
            const retained = if (route == .document) document_buffers.graph.len else events.graph.len;
            const peak = document_bytes + retained + scratch_bytes;
            try w.print("{t},{s},{t},{t},{d},{x},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d},{d},{d},{d},{d},{d}\n", .{
                @import("builtin").mode,                                    name,                                                       sizing,                                                     route,                                                      source.len,                    std.hash.Wyhash.hash(0, source),
                @as(f64, @floatFromInt(cases.median(&times[ri][0]))) / 1e6, @as(f64, @floatFromInt(cases.median(&times[ri][1]))) / 1e6, @as(f64, @floatFromInt(cases.median(&times[ri][2]))) / 1e6, @as(f64, @floatFromInt(cases.median(&times[ri][3]))) / 1e6, counting_ms,                   retained,
                scratch_bytes,                                              document_bytes,                                             peak,                                                       probe.graph.?.nodes.len,                                    probe.graph.?.connections.len,
            });
            try w.flush();
        }
    }
}
pub fn main(init: std.process.Init) !void {
    const options = try cases.Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.Writer.initStreaming(.stdout(), init.io, &buffer);
    const w = &output.interface;
    try w.writeAll("build,case,sizing,route,source_bytes,source_hash,total_ms,parse_ms,validate_ms,lower_ms,count_ms,retained_bytes,scratch_bytes,document_bytes,reserved_peak_bytes,nodes,connections\n");
    var count: usize = 0;
    if (options.corpus) |directory| for (cases.corpus_cases) |case| {
        if (!options.selected(case)) continue;
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}_M.dot", .{ directory, case });
        defer init.gpa.free(path);
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(128 * 1024 * 1024));
        defer init.gpa.free(source);
        try report(init, w, case, source);
        count += 1;
    };
    for (std.meta.tags(cases.Shape)) |shape| {
        if (!options.selected(@tagName(shape))) continue;
        var source: std.Io.Writer.Allocating = .init(init.gpa);
        defer source.deinit();
        try cases.fixture(&source.writer, shape);
        try report(init, w, @tagName(shape), source.written());
        count += 1;
    }
    if (count == 0) return error.NoMatchingCases;
    try w.flush();
}
