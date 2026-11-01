//! Deterministic adversarial differential fuzzing through public APIs only.
//! Run `zig build fuzz-ir -Doptimize=safe -- --cases 10000 --seed 1`.
//! Replay a case with the same seed and `--start N --cases 1`.
const std = @import("std");
const dot = @import("dot_parser");
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
var active_seed: u64 = 0;
var active_case: u64 = 0;
var active_source: []const u8 = "";
pub const panic = std.debug.FullPanic(reportPanic);
fn reportPanic(message: []const u8, address: ?usize) noreturn {
    std.debug.print("PANIC seed={d} case={d} source_hex={x}\n", .{ active_seed, active_case, active_source });
    std.debug.defaultPanic(message, address);
}
const limits: dot.ir.Limits = .{
    .max_nodes = 4096,
    .max_scopes = 1024,
    .max_mentions = 16384,
    .max_connections = 8192,
    .max_attributes = 8192,
    .max_attribute_states = 131072,
    .max_edges = 16384,
    .max_pairs = 65536,
    .max_work = 2_000_000,
    .max_bytes = 16 * 1024 * 1024,
};
const P = dot.Profile(.{ .policy = .{
    .retention = .{ .partial = true },
    .limits = .{ .max_nesting = 256, .max_statements = 16384, .max_attributes = 8192 },
    .validation = .{ .graph = .{ .treated_as = .auto } },
} });
const IR = dot.ir.Lowering(.{ .limits = limits, .policy = .{ .execution = .{ .metering = true } } });
const Indexed = dot.ir.Lowering(.{ .limits = limits, .indexes = .{ .connections = true, .scope_memberships = true } });
const Topology = dot.ir.Lowering(.{ .limits = limits, .capabilities = .{ .attributes = false } });
const Selection = struct { attributes: bool = true, adjacency: dot.ir.Adjacency = .all };
const Random = struct {
    state: u64,
    fn next(self: *Random) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
    fn pick(self: *Random, n: usize) usize {
        return @intCast(self.next() % n);
    }
};
const Counts = struct { inputs: u64 = 0, complete: u64 = 0, partial: u64 = 0, no_document: u64 = 0, rejected: u64 = 0, operations: u64 = 0 };

fn allowed(err: anyerror) bool {
    return switch (err) {
        error.WorkLimit, error.MemoryLimit, error.NodeLimit, error.ScopeLimit, error.MentionLimit, error.ConnectionLimit, error.AttributeLimit, error.AttributeStateLimit, error.EdgeLimit, error.PairLimit, error.IndexLimit, error.UnsupportedSemantics, error.InvalidIdentifier, error.IncompleteDocument, error.InvalidDocument, error.UnsupportedEncoding => true,
        else => false,
    };
}

fn name(out: *std.Io.Writer, random: *Random) !void {
    const n = random.pick(16);
    switch (random.pick(6)) {
        0 => try out.print("\"n{d}\"", .{n}),
        1 => try out.print("\"n\" + \"{d}\"", .{n}),
        else => try out.print("n{d}", .{n}),
    }
    if (random.pick(5) == 0) try out.print(":\"p{d}\":{s}", .{ random.pick(3), ([_][]const u8{ "n", "s", "_", "c" })[random.pick(4)] });
}
fn endpoint(out: *std.Io.Writer, random: *Random) !void {
    switch (random.pick(6)) {
        0 => {
            try out.writeAll("{");
            for (0..random.pick(8)) |_| {
                try name(out, random);
                try out.writeAll(";");
            }
            try out.writeAll("}");
        },
        1 => try out.print("subgraph s{d} {{n{d};}}", .{ random.pick(4), random.pick(16) }),
        else => try name(out, random),
    }
}
fn generate(buffer: []u8, random: *Random, index: u64) ![]u8 {
    var out = std.Io.Writer.fixed(buffer);
    const strict = random.pick(2) == 0;
    const directed = random.pick(2) == 0;
    const op = if (directed) "->" else "--";
    try out.print("{s}{s}{{\n", .{ if (strict) "strict " else "", if (directed) "digraph " else "graph " });
    const depth = if (index % 31 == 0) 1 + random.pick(300) else random.pick(6);
    for (0..depth) |_| try out.writeAll("subgraph s0 {");
    for (0..1 + random.pick(48)) |_| {
        switch (random.pick(7)) {
            0 => try out.print("node[color=c{d} label=\"hello\" + \" world\"];", .{random.pick(4)}),
            1 => try out.print("edge[color=c{d} tailport=\"p:n\"];", .{random.pick(4)}),
            2 => try out.print("subgraph s{d}{{n{d};color=c{d};}}", .{ random.pick(4), random.pick(16), random.pick(4) }),
            else => {
                try endpoint(&out, random);
                for (0..random.pick(4)) |_| {
                    try out.writeAll(if (!strict and !directed and random.pick(3) == 0) "->" else op);
                    try endpoint(&out, random);
                }
                if (random.pick(2) == 0) try out.print("[color=c{d} label=\"v{d}\" headport=\"q:s\"]", .{ random.pick(4), random.pick(8) });
                try out.writeAll(";\n");
            },
        }
    }
    for (0..depth) |_| try out.writeAll("}");
    try out.writeAll("}\n");
    var len = out.buffered().len;
    // Preserve half the grammar-generated inputs; damage the other half.
    if (index % 2 != 0) {
        const tokens = [_][]const u8{ "\"", "/*", "->;", "\xff", "\x00", "}", "[", "=", "//", "<", "+", "\n#" };
        for (0..1 + random.pick(5)) |_| switch (random.pick(4)) {
            0 => len = random.pick(len + 1),
            1 => if (len > 0) {
                buffer[random.pick(len)] = @truncate(random.next());
            },
            2 => if (len > 0) {
                const at = random.pick(len);
                std.mem.copyForwards(u8, buffer[at .. len - 1], buffer[at + 1 .. len]);
                len -= 1;
            },
            else => {
                const at = random.pick(len + 1);
                const token = tokens[random.pick(tokens.len)];
                std.mem.copyBackwards(u8, buffer[at + token.len .. len + token.len], buffer[at..len]);
                @memcpy(buffer[at..][0..token.len], token);
                len += token.len;
            },
        };
    }
    return buffer[0..len];
}

fn supports(comptime storage: dot.ir.Adjacency, comptime direction: dot.ir.EdgeDirection) bool {
    return storage == .all or direction == .undirected or
        (storage == .forward and (direction == .outgoing or direction == .forward)) or
        (storage == .backward and (direction == .incoming or direction == .backward));
}
fn matches(edge: dot.ir.Edge, id: dot.ir.NodeId, direction: dot.ir.EdgeDirection) bool {
    const incident = edge.from == id or edge.to == id;
    return switch (direction) {
        .all => incident,
        .undirected => incident and edge.operator == .undirected,
        .outgoing => edge.from == id and edge.operator == .directed,
        .incoming => edge.to == id and edge.operator == .directed,
        .forward => if (edge.operator == .undirected) incident else edge.from == id,
        .backward => if (edge.operator == .undirected) incident else edge.to == id,
    };
}
fn rows(comptime selection: Selection, result: anytype) !void {
    var nodes = result.nodeIterator();
    while (nodes.next()) |node| inline for (comptime std.meta.tags(dot.ir.EdgeDirection)) |direction| if (comptime supports(selection.adjacency, direction)) {
        var entries = node.edges(.{ .direction = direction });
        var count: u32 = 0;
        for (result.edges, 0..) |edge, i| {
            if (!matches(edge, node.id, direction)) continue;
            const entry = entries.next() orelse return error.MissingAdjacency;
            try eq(@as(u32, @intCast(i)), entry.index);
            try eq(edge, entry.edge().edge);
            try eq(if (edge.from == node.id) edge.to else edge.from, entry.neighbor().id);
            const flags = entry.directions();
            try eq(edge.operator == .undirected, flags.undirected);
            try eq(edge.operator == .directed and edge.from == node.id, flags.outgoing);
            try eq(edge.operator == .directed and edge.to == node.id, flags.incoming);
            count += 1;
        }
        try expect(entries.next() == null);
        try expect(entries.next() == null);
        const actual = node.edgeCount(.{ .direction = direction });
        if (@TypeOf(actual) == u32) try eq(count, actual) else switch (actual) {
            .known => |n| try eq(count, n),
            .unknown => |u| try eq(count, u.retained.?),
        }
    };
}
fn compare(comptime attributes: bool, expected: anytype, actual: anytype) !void {
    try std.testing.expectEqualSlices(dot.ir.Edge, expected.edges, actual.edges);
    if (attributes) {
        var left = expected.edgeIterator();
        var right = actual.edgeIterator();
        while (left.next()) |edge| {
            const other = right.next() orelse return error.MissingEdge;
            var x = edge.attributes();
            var y = other.attributes();
            while (x.next()) |attribute| try eq(attribute, y.next().?);
            try expect(y.next() == null);
        }
        try expect(right.next() == null);
    }
}
fn finish(session: anytype, random: *Random) !u64 {
    var last: u64 = 0;
    var turns: u64 = 0;
    while (true) {
        const grant: u32 = @intCast(([_]usize{ 0, 1, 2, 7, 64, 4096 })[random.pick(6)]);
        const p = session.advance(grant);
        try expect(p.work_used <= grant);
        try eq(last + p.work_used, p.total_work);
        last = p.total_work;
        turns += 1;
        if (turns > limits.max_work * 3 + 100) return error.SessionDidNotFinish;
        if (p.outcome) |outcome| {
            try eq(@as(u32, 0), session.advance(1).work_used);
            try eq(outcome, session.advance(0).outcome.?);
            if (outcome == .failure) return outcome.failure;
            return last;
        }
    }
}
const Stop = struct {
    polls: u64 = 0,
    at: u64,
    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.polls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

fn exercise(comptime selection: Selection, a: std.mem.Allocator, graph: anytype, random: *Random, detailed: bool, counts: *Counts) !void {
    var plain = graph.materialize(.{ .attributes = selection.attributes }) catch |err| {
        if (!allowed(err)) return err;
        counts.rejected += 1;
        return;
    };
    defer plain.deinit();
    var direct = try graph.materialize(selection);
    defer direct.deinit();
    try compare(selection.attributes, &plain, &direct);
    try rows(selection, &direct);
    var session = try graph.materializationSession(selection);
    defer session.deinit();
    const work = try finish(&session, random);
    var resumed = try session.takeResult();
    defer resumed.deinit();
    try compare(selection.attributes, &direct, &resumed);
    try rows(selection, &resumed);
    counts.operations += 3;
    if (!detailed) return;
    var memory_limit = limits;
    memory_limit.max_bytes = random.pick(direct.peak_bytes + 1);
    if (graph.materialize(.{ .attributes = selection.attributes, .adjacency = selection.adjacency, .limits = memory_limit })) |value| {
        var bounded = value;
        defer bounded.deinit();
        try expect(bounded.peak_bytes <= memory_limit.max_bytes);
    } else |err| try eq(error.MemoryLimit, err);
    const sizing = try IR.scanMaterializationBounds(graph, selection);
    const layout = try IR.materializationLayout(graph, direct.capacities(), sizing.scratch, selection);
    const output = try a.alignedAlloc(u8, .@"16", layout.output_bytes + 16);
    defer a.free(output);
    const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
    defer a.free(scratch);
    @memset(output, 0xcd);
    @memset(scratch, 0xcd);
    const memory = try layout.bind(output, scratch);
    var fixed = graph.materializeIn(memory, .{});
    try eq(dot.ir.MaterializationOutcome.success, fixed.outcome);
    try compare(selection.attributes, &direct, &fixed.materialized.?);
    try rows(selection, &fixed.materialized.?);
    fixed.materialized.?.deinit();
    var fixed_session = try graph.materializationSessionIn(memory, .{});
    defer fixed_session.deinit();
    _ = try finish(&fixed_session, random);
    var fixed_result = try fixed_session.takeResult();
    defer fixed_result.deinit();
    try compare(selection.attributes, &direct, &fixed_result);
    try rows(selection, &fixed_result);
    for (output[layout.output_bytes..]) |byte| try eq(@as(u8, 0xcd), byte);
    for (scratch[layout.scratch_bytes..]) |byte| try eq(@as(u8, 0xcd), byte);
    counts.operations += 2;
    var stop: Stop = .{ .at = 1 + random.pick(@intCast(work + 1)) };
    var stopped = graph.materializationSession(.{ .attributes = selection.attributes, .adjacency = selection.adjacency, .cancellation = stop.token() }) catch |err| {
        try eq(error.Cancelled, err);
        try eq(@as(u64, 1), stop.at);
        return;
    };
    defer stopped.deinit();
    try std.testing.expectError(error.Cancelled, finish(&stopped, random));
    try eq(stop.at, stop.polls);
    try std.testing.expectError(error.Cancelled, stopped.takeResult());
    var limited = limits;
    limited.max_work = random.pick(@intCast(work));
    var bounded = try graph.materializationSession(.{ .attributes = selection.attributes, .adjacency = selection.adjacency, .limits = limited });
    defer bounded.deinit();
    try std.testing.expectError(error.WorkLimit, finish(&bounded, random));
    try eq(limited.max_work, bounded.advance(1).total_work);
    // Caller-owned output can be short in any of the selected storage pools.
    inline for (.{ "edges", "attribute_states", "attribute_keys", "adjacency_offsets", "adjacency_entries" }) |field| short: {
        var cap = direct.capacities();
        if (@field(cap, field) == 0) break :short;
        @field(cap, field) = @intCast(random.pick(@field(cap, field)));
        const short_layout = try IR.materializationLayout(graph, cap, sizing.scratch, selection);
        const short_memory = try short_layout.bind(output, scratch);
        const failed = graph.materializeIn(short_memory, .{});
        try eq(error.PoolExhausted, failed.outcome.failure);
        try expect(failed.materialized == null);
        try expect(failed.shortfall != null);
        var short_session = try graph.materializationSessionIn(short_memory, .{});
        defer short_session.deinit();
        try std.testing.expectError(error.PoolExhausted, finish(&short_session, random));
        try eq(failed.shortfall, short_session.shortfall());
    }
}

fn checkGraph(a: std.mem.Allocator, graph: anytype, random: *Random, detailed: bool, counts: *Counts) !void {
    switch (random.pick(3)) {
        0 => try exercise(.{ .adjacency = .all }, a, graph, random, detailed, counts),
        1 => try exercise(.{ .adjacency = .forward }, a, graph, random, detailed, counts),
        else => try exercise(.{ .attributes = false, .adjacency = .backward }, a, graph, random, detailed, counts),
    }
    if (detailed) try queries(graph, random, counts);
}
fn queries(graph: anytype, random: *Random, counts: *Counts) !void {
    var direct = try graph.edgeIterator(.{});
    defer direct.deinit();
    var stream = try IR.edgeSession(graph, .{});
    defer stream.deinit();
    var work: u64 = 0;
    var emitted: u32 = 0;
    while (true) {
        const grant: u32 = @intCast(([_]usize{ 0, 1, 7, 64, 4096 })[random.pick(5)]);
        const p = stream.advance(grant);
        try expect(p.work_used <= grant);
        work += p.work_used;
        try eq(work, p.total_work);
        try expect(work <= limits.max_work);
        if (p.edge) |edge| {
            const expected = (try direct.next()).?;
            try eq(expected.edge, edge.edge);
            if (emitted < 4) {
                try eq(try expected.tailPort(), try edge.tailPort());
                try eq(try expected.headPort(), try edge.headPort());
                const key = ([_][]const u8{ "color", "label", "missing", "tailport", "headport" })[random.pick(5)];
                var query = try IR.attributeSession(edge, key, .{});
                defer query.deinit();
                _ = try finish(&query, random);
                try eq(try edge.attributeWith(key, .{}), query.advance(0).outcome.?.success);
                var attributes = try edge.attributes(.{});
                defer attributes.deinit();
                var enumeration = try IR.attributesSession(edge, .{});
                defer enumeration.deinit();
                var attribute_work: u64 = 0;
                while (true) {
                    const budget: u32 = @intCast(1 + random.pick(64));
                    const step = enumeration.advance(budget);
                    try expect(step.work_used <= budget);
                    attribute_work += step.work_used;
                    try eq(attribute_work, step.total_work);
                    if (step.attribute) |entry| try eq((try attributes.next()).?, entry);
                    if (step.outcome) |outcome| {
                        if (outcome == .failure) return outcome.failure;
                        try expect(try attributes.next() == null);
                        break;
                    }
                }
                counts.operations += 2;
            }
            emitted += 1;
        }
        try eq(emitted, p.edges_emitted);
        if (p.outcome) |outcome| {
            if (outcome == .failure) return outcome.failure;
            try expect(try direct.next() == null);
            try eq(@as(u32, 0), stream.advance(1).work_used);
            break;
        }
    }
    var nodes = graph.nodeIterator();
    const first = nodes.next() orelse return;
    while (nodes.next()) |node| {
        var query = try IR.hasEdgeSession(graph, first.id, node.id, .{});
        defer query.deinit();
        _ = try finish(&query, random);
        try eq(try graph.hasEdge(first.id, node.id), query.advance(0).outcome.?.success);
        counts.operations += 1;
    }
    const data = if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph;
    for (0..data.scopes.len) |i| {
        const membership = try data.scopeMembership(@fromBackingInt(@as(u32, @intCast(i))));
        var query = try IR.containsSession(graph, membership, first.id, .{});
        defer query.deinit();
        _ = try finish(&query, random);
        try eq(try graph.contains(membership, first.id), query.advance(0).outcome.?.success);
        counts.operations += 1;
    }
}
fn one(a: std.mem.Allocator, source: []const u8, random: *Random, index: u64, counts: *Counts) !void {
    var parsed = P.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = if (parsed.document) |*d| d else {
        counts.no_document += 1;
        return;
    };
    const options = .{ .interpretation = P.interpretation(doc, .{}) };
    var partial = IR.lowerPartial(a, doc, options) catch |err| {
        if (!allowed(err)) return err;
        counts.rejected += 1;
        return;
    };
    defer partial.deinit();
    if (partial.state() == .partial) counts.partial += 1 else counts.complete += 1;
    try checkGraph(a, &partial, random, index % 8 == 0, counts);
    if (index % 16 == 0) try fixedLowering(true, a, doc, &partial, options, random, counts);
    if (!doc.scopeComplete()) return;
    var graph = try IR.lowerComplete(a, doc, options);
    defer graph.deinit();
    try checkGraph(a, &graph, random, index % 8 == 0, counts);
    if (index % 16 == 0) try fixedLowering(false, a, doc, &graph, options, random, counts);
    if (index % 4 == 0) {
        var lowering = try IR.loweringSession(a, doc, options);
        defer lowering.deinit();
        _ = try finish(&lowering, random);
        var resumed = try lowering.takeResult();
        defer resumed.deinit();
        var expected = try graph.materialize(.{ .attributes = false });
        defer expected.deinit();
        var actual = try resumed.materialize(.{ .attributes = false });
        defer actual.deinit();
        try compare(false, &expected, &actual);
        var indexed = try Indexed.lowerComplete(a, doc, options);
        defer indexed.deinit();
        var topology = try Topology.lowerComplete(a, doc, options);
        defer topology.deinit();
        var top = try topology.materialize(.{ .attributes = false, .adjacency = .all });
        defer top.deinit();
        try compare(false, &expected, &top);
        try rows(.{ .attributes = false }, &top);
        var nodes = graph.nodeIterator();
        while (nodes.next()) |node| {
            var other = graph.nodeIterator();
            while (other.next()) |to| {
                const found = try graph.hasEdge(node.id, to.id);
                try eq(found, try indexed.hasEdge(node.id, to.id));
                try eq(found, try topology.hasEdge(node.id, to.id));
            }
        }
        counts.operations += 5;
    }
}

fn fixedLowering(comptime partial: bool, a: std.mem.Allocator, doc: anytype, expected: anytype, options: anytype, random: *Random, counts: *Counts) !void {
    const bounds = if (partial) try IR.partialLoweringBounds(doc.capacities(), options) else try IR.loweringBounds(doc.capacities(), options);
    const layout = try IR.loweringLayout(expected.capacities(), bounds.scratch);
    const output = try a.alignedAlloc(u8, .@"16", layout.graph_bytes + 16);
    defer a.free(output);
    const scratch = try a.alignedAlloc(u8, .@"16", layout.scratch_bytes + 16);
    defer a.free(scratch);
    @memset(output, 0xcd);
    @memset(scratch, 0xcd);
    const memory = try layout.bind(output, scratch);
    var direct = if (partial) IR.lowerPartialIn(doc, memory, options) else IR.lowerCompleteIn(doc, memory, options);
    try eq(dot.ir.LoweringOutcome.success, direct.outcome);
    try compareGraph(expected, &direct.graph.?);
    direct.graph.?.deinit();
    var session = if (partial) try IR.partialLoweringSessionIn(doc, memory, options) else try IR.loweringSessionIn(doc, memory, options);
    defer session.deinit();
    _ = try finish(&session, random);
    var actual = try session.takeResult();
    defer actual.deinit();
    try compareGraph(expected, &actual);
    for (output[layout.graph_bytes..]) |byte| try eq(@as(u8, 0xcd), byte);
    for (scratch[layout.scratch_bytes..]) |byte| try eq(@as(u8, 0xcd), byte);
    counts.operations += 2;
}
fn compareGraph(expected: anytype, actual: anytype) !void {
    const partial = @hasField(@TypeOf(expected.*), "_data");
    const x = if (partial) &expected._data else expected;
    const y = if (partial) &actual._data else actual;
    inline for (.{ "source_info", "declared_kind", "kind", "strict", "name", "has_ports", "nodes", "scopes", "declarations", "occurrences", "bodies", "mentions", "connections", "endpoint_ports", "attributes", "posting_offsets", "posting_positions" }) |field| try eq(@field(x, field), @field(y, field));
    inline for (.{ "meta", "scopes", "connection_defaults" }) |field| try eq(@field(x.attribute_data, field), @field(y.attribute_data, field));
    inline for (.{ "keys", "cells" }) |field| try eq(@field(x.attribute_data, field).items, @field(y.attribute_data, field).items);
    if (partial) try eq(expected._coverage.entries.items, actual._coverage.entries.items);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var cases: u64 = 10000;
    var seed: u64 = 1;
    var start: u64 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("fuzz-ir [--cases N] [--seed N] [--start N]\nDeterministic grammar and byte mutation; replay with --start N --cases 1.\n", .{});
            return;
        }
        if (i + 1 == args.len) return error.MissingArgument;
        const n = try std.fmt.parseInt(u64, args[i + 1], 0);
        if (std.mem.eql(u8, args[i], "--cases")) cases = n else if (std.mem.eql(u8, args[i], "--seed")) seed = n else if (std.mem.eql(u8, args[i], "--start")) start = n else return error.UnknownArgument;
    }
    var allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 6 }) = .init;
    defer if (allocator.deinit() == .leak) @panic("fuzz runner leaked memory");
    const a = allocator.allocator();
    var counts: Counts = .{};
    const began = std.Io.Clock.Timestamp.now(init.io, .awake);
    active_seed = seed;
    for (0..cases) |offset| {
        const index = start + offset;
        active_case = index;
        var random: Random = .{ .state = seed +% (index *% 0x9e3779b97f4a7c15) };
        var buffer: [65536]u8 = undefined;
        const source = try generate(&buffer, &random, index);
        active_source = source;
        one(a, source, &random, index, &counts) catch |err| {
            std.debug.print("FAIL seed={d} case={d} error={t}\n{s}\nsource_hex={x}\n", .{ seed, index, err, source, source });
            return err;
        };
        counts.inputs += 1;
        if (offset % 1000 == 0) std.debug.print("seed={d} case={d} complete={d} partial={d} operations={d}\n", .{ seed, index, counts.complete, counts.partial, counts.operations });
    }
    active_source = "";
    const elapsed = began.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds;
    std.debug.print("PASS seed={d} start={d} inputs={d} complete={d} partial={d} no_document={d} bounded_rejections={d} operations={d} seconds={d:.3}\n", .{ seed, start, counts.inputs, counts.complete, counts.partial, counts.no_document, counts.rejected, counts.operations, @as(f64, @floatFromInt(elapsed)) / 1e9 });
}
