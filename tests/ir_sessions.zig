const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;

fn compareResults(comptime attributes: bool, expected: anytype, actual: anytype) !void {
    try std.testing.expectEqualSlices(dot.ir.Edge, expected.edges, actual.edges);
    if (attributes) {
        var left = expected.edgeIterator();
        var right = actual.edgeIterator();
        while (left.next()) |edge| {
            const other = right.next().?;
            var x = edge.attributes();
            var y = other.attributes();
            while (x.next()) |attribute| try equal(attribute, y.next().?);
            try expect(y.next() == null);
            try equal(edge.tailPort(), other.tailPort());
            try equal(edge.headPort(), other.headPort());
        }
        try expect(right.next() == null);
    }
}

// Hold allocation behavior fixed when comparing credit totals. A backing
// allocator may otherwise accept resize in one run and move in the next.
const NoResize = struct {
    backing: std.mem.Allocator,
    fn allocator(self: *NoResize) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(n, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ra);
    }
};

fn check(comptime attributes: bool, original: anytype) !void {
    var copy = original.*;
    var memory: NoResize = .{ .backing = if (@hasField(@TypeOf(copy), "allocator")) copy.allocator else copy._data.allocator };
    if (@hasField(@TypeOf(copy), "allocator")) copy.allocator = memory.allocator() else copy._data.allocator = memory.allocator();
    const ir = &copy; // Borrow all input buffers; do not deinit the copied owner.
    var expected = try ir.materialize(.{ .attributes = attributes });
    defer expected.deinit();
    var total: ?u64 = null;
    var peak: ?usize = null;
    for ([_]u32{ 0, 1, 2, 7, 64, 4096, std.math.maxInt(u32) }) |budget| {
        var session = try ir.materializationSession(.{ .attributes = attributes });
        defer session.deinit();
        try std.testing.expectError(error.NotReady, session.takeResult());
        var steps: u64 = 0;
        var turns: usize = 0;
        while (true) {
            const before = session.advance(0);
            try equal(@as(u32, 0), before.work_used);
            try equal(steps, before.total_work);
            const grant = if (budget != 0) budget else ([_]u32{ 1, 7, 64, 2, 4096 })[turns % 5];
            turns += 1;
            const p = session.advance(grant);
            try expect(p.work_used <= grant);
            steps += p.work_used;
            try equal(steps, p.total_work);
            if (p.outcome) |outcome| {
                try equal(dot.ir.MaterializationOutcome.success, outcome);
                break;
            }
            try expect(p.work_used != 0);
        }
        if (total) |n| try equal(n, steps) else total = steps;
        if (peak) |n| try equal(n, session.peakBytes()) else peak = session.peakBytes();
        var actual = try session.takeResult();
        defer actual.deinit();
        try expect(@TypeOf(actual) == @TypeOf(expected));
        try compareResults(attributes, &expected, &actual);
        if (@hasDecl(@TypeOf(actual), "state")) try equal(ir.state(), actual.state());
        try std.testing.expectError(error.AlreadyTaken, session.takeResult());
        const p = session.advance(budget);
        try equal(@as(u32, 0), p.work_used);
        try equal(steps, p.total_work);
        try equal(@as(u32, @intCast(actual.edges.len)), p.edges_created);
        session.cancel(); // A terminal success cannot turn into cancellation.
        try equal(dot.ir.MaterializationOutcome.success, session.run().outcome.?);
    }
}

test "materialization sessions agree with direct output at every budget including one" {
    for ([_][]const u8{
        "digraph {}",
        "digraph { a->b; a->b; a->c }",
        // Reuse both endpoint buffers across singleton, deduplicated set and
        // empty products; a cached cardinality must never survive the reset.
        "digraph { a->{b c b}; {}->a; a->b; {a b}->{}; {a b a}->{c d c}; d->a }",
        "strict graph { edge[color=red]; {a b}--{a b}[label=first]; b--a[label=last]; edge[color=blue]; a--c }",
        "strict digraph {edge[weight=1];subgraph s{a}->x[color=red];edge[weight=2];subgraph s{b}->x[label=new];subgraph s{a}->x[color=blue]}",
        "digraph {edge[color=red]; a->{edge[color=blue];b->c[label=inside]}->d[label=outside]; x:p->{}; {}->y:q}",
        "strict graph {edge[tailport=default];a:p--b:q; b:r--a:s[headport=override]; a:t--a:u; a--c}",
        "strict graph {edge[\"tail\"+<>+\"port\"=default <headport>=other];a:p--b:q; b:r--a:s[\"he\"/*gap*/+\"adport\"=override]; a--c}",
        "digraph {a:p->b:q[\"tail\"+\"port\"=\"\" headport=<> label=\"a\"+<<b>bee</b>>]; c->d}",
    }) |source| {
        var complete = try dot.ir.parse(a, source, .{});
        defer complete.deinit();
        try expect(complete.ir() != null);
        inline for (.{ false, true }) |attributes| try check(attributes, complete.ir().?);
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        inline for (.{ false, true }) |attributes| try check(attributes, partial.ir().?);
    }
}

test "session options keep compile-time attributes and runtime execution configuration" {
    var result = try dot.ir.parse(a, "digraph {a->b[x=1]}", .{});
    defer result.deinit();
    const ir = result.ir().?;
    var stop: Stop = .{};
    var options: dot.ir.Options = .{ .limits = .{ .max_pairs = 1 }, .cancellation = stop.token() };
    _ = &options;
    var session = try ir.materializationSession(options);
    defer session.deinit();
    try expect(@TypeOf(session) == dot.ir.Lowering(.{}).Graph.MaterializationSession(true));
    _ = session.run();
    var graph = try session.takeResult();
    defer graph.deinit();
    var topology = try ir.materializationSession(.{ .attributes = false, .limits = options.limits, .cancellation = options.cancellation });
    defer topology.deinit();
    try expect(@TypeOf(topology.maps) == void);
    try expect(@TypeOf(topology.set_path) == void);
    try expect(@TypeOf(topology.port_match) == void);
    try equal(dot.ir.MaterializationOutcome.success, topology.run().outcome.?);
    var explicit_null = try ir.materializationSession(.{ .limits = null, .cancellation = null });
    defer explicit_null.deinit();
    try equal(dot.ir.MaterializationOutcome.success, explicit_null.run().outcome.?);
}

test "sessions preserve qualified partial answers not operational partial output" {
    for ([_][]const u8{
        "strict graph {edge[color=red];a:p--b:q; broken -> ; b:r--a:s[label=updated];c--d}",
        "digraph {edge[color=red]; a->b; subgraph s{c->d; e->",
    }) |source| {
        var parsed = try dot.ir.parsePartial(a, source, .{});
        defer parsed.deinit();
        try equal(.partial, parsed.ir().?.state());
        inline for (.{ false, true }) |attributes| try check(attributes, parsed.ir().?);
    }
}

const Stop = struct {
    polls: usize = 0,
    at: usize = std.math.maxInt(usize),
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(ctx.?));
        self.polls += 1;
        return self.polls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "session cancellation latches at every poll including zero and across growth" {
    var parsed = try dot.ir.parse(a, "strict graph {{a b c d}--{a b c d}[x=1 y=2];a:p--b:q[z=3]}", .{});
    defer parsed.deinit();
    var snapshot = parsed.ir().?.*;
    var memory: NoResize = .{ .backing = a };
    snapshot.allocator = memory.allocator();
    const ir = &snapshot;
    inline for (.{ false, true }) |attributes| {
        var counter: Stop = .{};
        {
            var session = try ir.materializationSession(.{ .attributes = attributes, .cancellation = counter.token() });
            defer session.deinit();
            const progress = session.run();
            try equal(dot.ir.MaterializationOutcome.success, progress.outcome.?);
            // One initialization poll and exactly one poll before every credit.
            try equal(progress.total_work + 1, @as(u64, counter.polls));
        }
        for ([_]u32{ 1, 7, std.math.maxInt(u32) }) |budget| for (1..counter.polls + 1) |at| {
            var stop: Stop = .{ .at = at };
            var session = ir.materializationSession(.{ .attributes = attributes, .cancellation = stop.token() }) catch |err| {
                try equal(error.Cancelled, err);
                try equal(@as(usize, 1), at);
                continue;
            };
            defer session.deinit();
            var p = session.advance(budget);
            while (p.outcome == null) p = session.advance(budget);
            try equal(error.Cancelled, p.outcome.?.failure);
            try equal(@as(u64, at - 2), p.total_work);
            try equal(at, stop.polls);
            try std.testing.expectError(error.Cancelled, session.takeResult());
            try equal(@as(u32, 0), session.advance(100).work_used);
            try equal(at, stop.polls); // A latched stop never polls again.
        };
        var stop: Stop = .{};
        var session = try ir.materializationSession(.{ .attributes = attributes, .cancellation = stop.token() });
        defer session.deinit();
        stop.at = stop.polls + 1;
        try equal(error.Cancelled, session.advance(0).outcome.?.failure);
        try equal(@as(u64, 0), session.advance(1).total_work);
    }
}

test "batched session progress matches single credits with and without cancellation" {
    var parsed = try dot.ir.parse(a, "strict graph {{a b c d}--{a b c d}[x=1 y=2];a:p--b:q[z=3];subgraph s{a b}--x}", .{});
    defer parsed.deinit();
    var snapshot = parsed.ir().?.*;
    var memory: NoResize = .{ .backing = a };
    snapshot.allocator = memory.allocator();
    inline for (.{ false, true }) |attributes| for ([_]bool{ false, true }) |cancellable| {
        var stop: Stop = .{};
        var reference = try snapshot.materializationSession(.{ .attributes = attributes });
        defer reference.deinit();
        var session = try snapshot.materializationSession(.{ .attributes = attributes, .cancellation = if (cancellable) stop.token() else null });
        defer session.deinit();
        var turn: usize = 0;
        var zero_polls: u64 = 0;
        while (true) : (turn += 1) {
            const grant = ([_]u32{ 0, 1, 7, 64, 2, 4096 })[turn % 6];
            var expected = reference.advance(0);
            var consumed: u32 = 0;
            while (consumed < grant and expected.outcome == null) : (consumed += 1) expected = reference.advance(1);
            expected.work_used = consumed;
            const actual = session.advance(grant);
            try equal(expected, actual);
            try equal(reference.peakBytes(), session.peakBytes());
            if (grant == 0) zero_polls += 1;
            if (cancellable) try equal(actual.total_work + zero_polls + 1, @as(u64, stop.polls));
            if (actual.outcome != null) break;
        }
        var left = try reference.takeResult();
        defer left.deinit();
        var right = try session.takeResult();
        defer right.deinit();
        try compareResults(attributes, &left, &right);
    };
}

test "session cancellation wins at the exact lifetime work boundary" {
    var parsed = try dot.ir.parse(a, "digraph {a->b}", .{});
    defer parsed.deinit();
    for ([_]u32{ 0, 1, 7 }) |limit| {
        var stop: Stop = .{ .at = @as(usize, limit) + 2 };
        var session = try parsed.ir().?.materializationSession(.{ .limits = .{ .max_work = limit }, .cancellation = stop.token() });
        defer session.deinit();
        const p = session.advance(limit + 1);
        try equal(@as(u64, limit), p.total_work);
        try equal(error.Cancelled, p.outcome.?.failure);
        try equal(stop.at, stop.polls);
    }
}

test "work limits and ownership transfer are exact and terminal" {
    var parsed = try dot.ir.parse(a, "digraph {a:p->b:q[x=1]}", .{});
    defer parsed.deinit();
    const ir = parsed.ir().?;
    var probe = try ir.materializationSession(.{});
    const total = probe.run().total_work;
    probe.deinit(); // An untaken successful output is still owned by the session.
    for ([_]u64{ 0, 1, total - 1, total }) |limit| {
        var session = try ir.materializationSession(.{ .limits = .{ .max_work = limit } });
        defer session.deinit();
        const p = session.run();
        try equal(limit, p.total_work);
        if (limit == total) {
            var output = try session.takeResult();
            defer output.deinit();
            try equal(@as(usize, 1), output.edges.len);
        } else {
            try equal(error.WorkLimit, p.outcome.?.failure);
            try std.testing.expectError(error.WorkLimit, session.takeResult());
        }
    }
    var session = try ir.materializationSession(.{});
    _ = session.run();
    var output = try session.takeResult();
    session.deinit();
    defer output.deinit();
    try expect(output.edgeIterator().owner.edges.len == 1);
    var cancelled = try ir.materializationSession(.{});
    defer cancelled.deinit();
    _ = cancelled.advance(7);
    cancelled.cancel();
    try std.testing.expectError(error.Cancelled, cancelled.takeResult());
}

test "generated overlap, reopenings, map rotations and table rehashing agree" {
    for (0..8) |seed| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        const directed = seed % 2 == 0;
        try source.writer.print("{s}{s} {{ edge[base=initial];", .{ if (seed % 4 < 2) "strict " else "", if (directed) "digraph" else "graph" });
        var random: u32 = @intCast(seed + 1);
        for (0..40) |round| {
            random = random *% 1664525 +% 1013904223;
            const op: []const u8 = if (directed) "->" else "--";
            try source.writer.print("subgraph s{{n{d}}}{s}{{n{d} n{d}}}[", .{ random % 12, op, (random >> 4) % 12, (random >> 8) % 12 });
            for (0..16) |key| try source.writer.print(" k{d}=v{d}", .{ (key * 7 + round) % 16, round });
            try source.writer.print("]; n{d}:p{s}n{d}:q[headport=override];", .{ random % 12, op, (random >> 4) % 12 });
        }
        try source.writer.writeAll("}");
        var result = try dot.ir.parse(a, source.written(), .{});
        defer result.deinit();
        inline for (.{ false, true }) |attributes| try check(attributes, result.ir().?);
    }
}

fn allocationCase(allocator: std.mem.Allocator, original: *const dot.ir.Lowering(.{}).Graph) !void {
    // Snapshot borrows all original IR buffers; only output uses this allocator.
    var ir = original.*;
    // Failure-index replay requires a stable number of allocations; accepting
    // in-place resize depends on the testing allocator's current page layout.
    var memory: NoResize = .{ .backing = allocator };
    ir.allocator = memory.allocator();
    inline for (.{ false, true }) |attributes| {
        var session = try ir.materializationSession(.{ .attributes = attributes });
        defer session.deinit();
        while (session.advance(1).outcome == null) {}
        var result = try session.takeResult();
        defer result.deinit();
        try expect(result.edges.len != 0);
    }
}
test "every allocation failure frees pending growth buffers and partial fold state" {
    var parsed = try dot.ir.parse(a, "strict digraph {{a b c d e}->{v w x y z}[a=1 b=2 c=3 d=4];a:p->x:q[b=last];{a b c}->{x y z}[e=5]}", .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{parsed.ir().?});
}

test "resource stops never publish output and inherited defaults use no winner cells" {
    var parsed = try dot.ir.parse(a, "strict digraph {{a b c}->{x y z}[a=1 b=2 c=3];a:p->x:q[a=last]}", .{});
    defer parsed.deinit();
    var snapshot = parsed.ir().?.*;
    var memory: NoResize = .{ .backing = a };
    snapshot.allocator = memory.allocator();
    const ir = &snapshot;
    const cases = .{
        .{ dot.ir.Limits{ .max_bytes = 0 }, error.MemoryLimit },
        .{ dot.ir.Limits{ .max_pairs = 8 }, error.PairLimit },
        .{ dot.ir.Limits{ .max_edges = 8 }, error.EdgeLimit },
        .{ dot.ir.Limits{ .max_attribute_states = 26 }, error.AttributeStateLimit },
    };
    inline for (cases) |case| {
        var session = try ir.materializationSession(.{ .limits = case[0] });
        defer session.deinit();
        try equal(case[1], session.run().outcome.?.failure);
        try std.testing.expectError(case[1], session.takeResult());
        session.cancel();
        try equal(case[1], session.advance(0).outcome.?.failure);
    }
    var probe = try ir.materializationSession(.{});
    _ = probe.run();
    const peak = probe.peakBytes();
    probe.deinit();
    for ([_]usize{ peak - 1, peak }) |limit| {
        var session = try ir.materializationSession(.{ .limits = .{ .max_bytes = limit } });
        defer session.deinit();
        const p = session.run();
        try expect(session.peakBytes() <= limit);
        if (limit == peak) try equal(dot.ir.MaterializationOutcome.success, p.outcome.?) else try equal(error.MemoryLimit, p.outcome.?.failure);
    }
    var defaults = try dot.ir.parse(a, "digraph {edge[a=1 b=2];a->b; c->d}", .{});
    defer defaults.deinit();
    var session = try defaults.ir().?.materializationSession(.{ .limits = .{ .max_attribute_states = 0 } });
    defer session.deinit();
    try equal(dot.ir.MaterializationOutcome.success, session.run().outcome.?);
}

test "native encoding sessions match direct attributes and structured ports" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const source = "strict graph {edge[café=初 \"tail\"+<>+\"port\"=default];a:\"埠😀\":n--b:q[label=\"😀\"+<<b>中文&amp;</b>>]; b:<終>--a:p[<headport>=override]}";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var encoded = std.Io.Writer.Allocating.init(a);
        defer encoded.deinit();
        var chars = (try std.unicode.Utf8View.init(source)).iterator();
        while (chars.nextCodepoint()) |cp| {
            if (E.width == 2) {
                if (cp <= 0xffff) try encoded.writer.writeInt(u16, @intCast(cp), E.endian) else {
                    try encoded.writer.writeInt(u16, @intCast(0xd800 + ((cp - 0x10000) >> 10)), E.endian);
                    try encoded.writer.writeInt(u16, @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff)), E.endian);
                }
            } else try encoded.writer.writeInt(u32, cp, E.endian);
        }
        var parsed = try P.parseAndValidate(a, encoded.written(), dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        var ir = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer ir.deinit();
        inline for (.{ false, true }) |attributes| try check(attributes, &ir);
    }
}

test "long glue and large symbolic products remain bounded before any edge is published" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {a:p->b:q[\"tail\"/*");
    try source.writer.splatByteAll('x', 4096);
    try source.writer.writeAll("*/+\"port\"=override];}");
    var parsed = try dot.ir.parse(a, source.written(), .{});
    defer parsed.deinit();
    var session = try parsed.ir().?.materializationSession(.{});
    defer session.deinit();
    for (0..4096) |_| {
        const p = session.advance(1);
        try equal(@as(u32, 1), p.work_used);
        try expect(p.outcome == null);
        try equal(@as(u32, 0), p.edges_created);
    }
    try equal(dot.ir.MaterializationOutcome.success, session.run().outcome.?);
    try check(true, parsed.ir().?);
    var product = std.Io.Writer.Allocating.init(a);
    defer product.deinit();
    try product.writer.writeAll("digraph {{");
    for (0..200) |i| try product.writer.print("n{d};", .{i});
    try product.writer.writeAll("}->{");
    for (0..200) |i| try product.writer.print("m{d};", .{i});
    try product.writer.writeAll("}}");
    var large = try dot.ir.parse(a, product.written(), .{});
    defer large.deinit();
    var bounded = try large.ir().?.materializationSession(.{ .limits = .{ .max_pairs = 39_999 } });
    defer bounded.deinit();
    while (bounded.advance(1).outcome == null) {}
    try equal(error.PairLimit, bounded.advance(0).outcome.?.failure);
    try equal(@as(u64, 0), bounded.advance(0).pairs_visited);
    try std.testing.expectError(error.PairLimit, bounded.takeResult());
}

test "membership mark generation rollover clears in bounded chunks" {
    var parsed = try dot.ir.parse(a, "digraph {{a b}->{x y};{a b}->{x y}}", .{});
    defer parsed.deinit();
    var expected = try parsed.ir().?.materialize(.{ .attributes = false });
    defer expected.deinit();
    var session = try parsed.ir().?.materializationSession(.{ .attributes = false });
    defer session.deinit();
    while (session.phase != .product) _ = session.advance(1);
    // Exercise the otherwise billions-of-endpoints wraparound with real marks.
    session.generation = std.math.maxInt(u32);
    while (session.advance(1).outcome == null) {}
    var actual = try session.takeResult();
    defer actual.deinit();
    try compareResults(false, &expected, &actual);
}
