const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
const Dot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });

// Credit totals include actual copies. Force moving growth for deterministic
// partition and allocation-failure comparisons (the backing allocator may
// otherwise resize in place depending on its current page layout).
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

fn compare(expected: anytype, actual: anytype) !void {
    inline for (.{ "source_info", "declared_kind", "kind", "strict", "name", "has_ports", "nodes", "scopes", "declarations", "occurrences", "bodies", "mentions", "connections", "attributes", "posting_offsets", "posting_positions", "node_slots" }) |field|
        try equal(@field(expected, field), @field(actual, field));
    inline for (.{ "meta", "scopes", "connection_defaults" }) |field|
        try equal(@field(expected.attribute_data, field), @field(actual.attribute_data, field));
    inline for (.{ "keys", "cells" }) |field|
        try equal(@field(expected.attribute_data, field).items, @field(actual.attribute_data, field).items);
}

fn check(comptime partial: bool, source: []const u8) !void {
    var parsed = Dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const options = .{ .interpretation = Dot.interpretation(doc, .{}) };
    var direct = if (partial) try IR.lowerPartial(a, doc, options) else try IR.lowerComplete(a, doc, options);
    defer direct.deinit();
    var work: ?u64 = null;
    var memory: NoResize = .{ .backing = a };
    for ([_]u32{ 1, 2, 7, 64, 4096, std.math.maxInt(u32) }) |budget| {
        var session = if (partial) try IR.partialLoweringSession(memory.allocator(), doc, options) else try IR.loweringSession(memory.allocator(), doc, options);
        defer session.deinit();
        try equal(@as(usize, 0), session.peakBytes());
        try std.testing.expectError(error.NotReady, session.takeResult());
        var total: u64 = 0;
        while (true) {
            const zero = session.advance(0);
            try equal(@as(u32, 0), zero.work_used);
            try equal(total, zero.total_work);
            const progress = session.advance(budget);
            try expect(progress.work_used <= budget);
            total += progress.work_used;
            try equal(total, progress.total_work);
            if (progress.outcome) |outcome| {
                try equal(dot.ir.LoweringOutcome.success, outcome);
                break;
            }
            try expect(progress.work_used != 0);
        }
        if (work) |previous| try equal(previous, total) else work = total;
        var actual = try session.takeResult();
        defer actual.deinit();
        if (partial) {
            try compare(direct._data, actual._data);
            try equal(direct._coverage.entries.items, actual._coverage.entries.items);
        } else try compare(direct, actual);
        try std.testing.expectError(error.AlreadyTaken, session.takeResult());
        session.cancel();
        try equal(dot.ir.LoweringOutcome.success, session.run().outcome.?);
        try equal(@as(u32, 0), session.advance(1).work_used);
    }
}

test "lowering sessions match direct complete and partial lowering at budget one and larger grants" {
    for ([_][]const u8{
        "digraph {}",
        "digraph { a->b->c; a->b; z }",
        "digraph { a; \"a\"; \"a\"+<>+\"\"; <a>; \"x\\N\"; \"x\\\"y\"; \"a\"/*glue*/+\"b\"; <<b>x</b>> }",
        "digraph { \"a\\\nb\"; \"a\\\r\nb\"; \"a\"//glue\n+\"b\"; \"a\"#glue\n+\"b\"; \"a\\\\b\"; ab; \xff; \"\xff\" }",
        "strict graph {node[color=red];edge[weight=1];a:p--b:q; b:r--a:s[label=last]; edge[weight=2]; a--c}",
        "digraph { graph[label=root]; node[color=red]; subgraph s {a;node[color=local]} node[color=blue shape=box];subgraph s{b}; c }",
        "digraph {subgraph s{a}->x;subgraph s{b}->subgraph s{c};{x->{y z}}->q[label=outside];x->{};{}->z}",
        "digraph {a[a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8 i=9];a[d=last];subgraph s{node[x=1 y=2]; b};node[z=3];subgraph s{c}}",
    }) |source| {
        try check(false, source);
        try check(true, source);
    }
    for ([_][]const u8{
        "digraph { a[color=red]; broken -> ; b[color=blue]; }",
        "digraph {a; subgraph s {b; c->;d}",
        "digraph { {a}-> {b; subgraph s{c}} -> ; d->e;",
        "digraph { a; x[label=\"unfinished",
    }) |source| try check(true, source);
}

test "lowering runtime execution policy resolves once and direct operations remain available" {
    const Runtime = dot.ir.Lowering(.{ .runtime_policy = true });
    var parsed = Dot.parseAndValidate(a, "digraph {a->b}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const interpretation = Dot.interpretation(doc, .{});
    var disabled = try Runtime.loweringSession(a, doc, .{ .interpretation = interpretation });
    defer disabled.deinit();
    try std.testing.expectError(error.MeteringDisabled, disabled.advance(1));
    try equal(@as(usize, 0), disabled.peakBytes());
    try equal(dot.ir.LoweringOutcome.success, disabled.run().outcome.?);
    var result = try disabled.takeResult();
    defer result.deinit();
    var enabled = try Runtime.loweringSession(a, doc, .{ .interpretation = interpretation, .policy = .{ .execution = .{ .metering = true } } });
    defer enabled.deinit();
    while ((try enabled.advance(1)).outcome == null) {}
    var other = try enabled.takeResult();
    defer other.deinit();
    try compare(result, other);
    try std.testing.expectError(error.InvalidCancellationInterval, Runtime.validatePolicy(.{ .execution = .{ .cancellation_interval = 0 } }));
    try std.testing.expectError(error.InvalidCancellationInterval, Runtime.loweringSession(a, doc, .{ .interpretation = interpretation, .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    var stop: Stop = .{ .at = 1 };
    // The hook is a resource, not an implicit policy override.
    var ignored = try Runtime.loweringSession(a, doc, .{ .interpretation = interpretation, .cancellation = .{ .context = &stop, .is_requested = Stop.requested } });
    defer ignored.deinit();
    try equal(dot.ir.LoweringOutcome.success, ignored.run().outcome.?);
    try equal(@as(u64, 0), stop.polls);
    try std.testing.expectError(error.Cancelled, Runtime.loweringSession(a, doc, .{ .interpretation = interpretation, .policy = .{ .execution = .{ .cancellation = true } }, .cancellation = stop.token() }));
    var plain = try IR.lowerComplete(a, doc, .{ .interpretation = interpretation });
    defer plain.deinit();
    try compare(plain, result);
}

test "lowering session admission preserves complete and partial boundaries" {
    var parsed = Dot.parseAndValidate(a, "digraph {a->b;", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    try std.testing.expectError(error.IncompleteDocument, IR.loweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) }));
    var partial = try IR.partialLoweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer partial.deinit();
    try equal(dot.ir.LoweringOutcome.success, partial.run().outcome.?);
    var result = try partial.takeResult();
    defer result.deinit();
    try equal(dot.Completeness.partial, result.state());
    const Auto = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .validation = .{ .graph = .{ .treated_as = .auto } } } });
    inline for (.{ "graph {a--b;bad->;c}", "graph {a->b;bad->;c}", "strict graph {a--b;bad->;c}" }) |source| {
        var input = Auto.parseAndValidate(a, source, dot.diagnostic.discard, .{});
        defer input.deinit(a);
        const view = &input.document.?;
        const options = .{ .interpretation = Auto.interpretation(view, .{}) };
        if (view.strict) {
            try std.testing.expectError(error.UnsupportedSemantics, IR.partialLoweringSession(a, view, options));
        } else {
            var expected = try IR.lowerPartial(a, view, options);
            defer expected.deinit();
            var operation = try IR.partialLoweringSession(a, view, options);
            defer operation.deinit();
            _ = operation.run();
            var actual = try operation.takeResult();
            defer actual.deinit();
            try compare(expected._data, actual._data);
            try equal(expected._coverage.entries.items, actual._coverage.entries.items);
        }
    }
    const Ascii = dot.Profile(.{ .source_encodings = &.{} });
    const AsciiIR = dot.ir.Lowering(.{ .source_encodings = &.{}, .policy = .{ .execution = .{ .metering = true } } });
    var ascii = try Ascii.parseAndValidate(a, "digraph{\"a\"+<b>->c}", dot.diagnostic.discard, .{});
    defer ascii.deinit(a);
    const options = .{ .interpretation = Ascii.interpretation(&ascii.document.?, .{}) };
    var expected = try AsciiIR.lowerComplete(a, &ascii.document.?, options);
    defer expected.deinit();
    var operation = try AsciiIR.loweringSession(a, &ascii.document.?, options);
    defer operation.deinit();
    while (operation.advance(1).outcome == null) {}
    var actual = try operation.takeResult();
    defer actual.deinit();
    try compare(expected, actual);
}

const Stop = struct {
    polls: u64 = 0,
    at: u64 = std.math.maxInt(u64),
    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.polls >= self.at;
    }
    fn token(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "lowering sessions poll every credit and cancellation wins over work exhaustion" {
    const C = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var parsed = Dot.parseAndValidate(a, "digraph { node[color=red]; subgraph s{a b};a:p->{b c}[x=1];node[y=2];subgraph s{d}}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const interpretation = Dot.interpretation(doc, .{});
    var probe = try C.loweringSession(a, doc, .{ .interpretation = interpretation });
    const total = probe.run().total_work;
    probe.deinit();
    // Every possible cancellation checkpoint, including table growth, native
    // helpers, map rotations, scope overlay, and finishing indexes.
    for (2..@as(usize, @intCast(total + 2))) |at| {
        var stop: Stop = .{ .at = at };
        var session = try C.loweringSession(a, doc, .{ .interpretation = interpretation, .cancellation = stop.token() });
        defer session.deinit();
        const progress = session.run();
        try equal(error.Cancelled, progress.outcome.?.failure);
        try equal(@as(u64, at - 2), progress.total_work);
        try std.testing.expectError(error.Cancelled, session.takeResult());
        _ = session.advance(0);
        try equal(@as(u64, at), stop.polls);
    }
    for ([_]u64{ 0, 1, 7, total - 1, total }) |limit| {
        var session = try C.loweringSession(a, doc, .{ .interpretation = interpretation, .limits = .{ .max_work = limit } });
        defer session.deinit();
        const progress = session.run();
        try equal(limit, progress.total_work);
        if (limit == total) try equal(dot.ir.LoweringOutcome.success, progress.outcome.?) else try equal(error.WorkLimit, progress.outcome.?.failure);
    }
    var stop: Stop = .{ .at = 9 };
    var session = try C.loweringSession(a, doc, .{ .interpretation = interpretation, .limits = .{ .max_work = 7 }, .cancellation = stop.token() });
    defer session.deinit();
    try equal(error.Cancelled, session.advance(8).outcome.?.failure);
}

test "lowering cancellation intervals and budget partitions do not change credits" {
    const C = dot.ir.Lowering(.{ .runtime_policy = true, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var parsed = Dot.parseAndValidate(a, "digraph {a->b[x=1];subgraph s{c d}->a}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    var total: ?u64 = null;
    for ([_]u32{ 1, 4, 64 }) |interval| {
        var stop: Stop = .{};
        var session = try C.loweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}), .policy = .{ .execution = .{ .cancellation_interval = interval } }, .cancellation = stop.token() });
        defer session.deinit();
        const progress = session.run();
        try equal(dot.ir.LoweringOutcome.success, progress.outcome.?);
        try equal(1 + (progress.total_work + interval - 1) / interval, stop.polls);
        if (total) |n| try equal(n, progress.total_work) else total = progress.total_work;
    }
    var one = try IR.loweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer one.deinit();
    var mixed = try IR.loweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer mixed.deinit();
    var turn: usize = 0;
    while (true) : (turn += 1) {
        const grant = ([_]u32{ 0, 1, 2, 7, 64 })[turn % 5];
        var expected = one.advance(0);
        var used: u32 = 0;
        while (used < grant and expected.outcome == null) : (used += 1) expected = one.advance(1);
        expected.work_used = used;
        const actual = mixed.advance(grant);
        try equal(expected, actual);
        if (actual.outcome != null) break;
    }
}

fn allocationCase(allocator: std.mem.Allocator, doc: *const dot.Document) !void {
    var memory: NoResize = .{ .backing = allocator };
    var session = try IR.partialLoweringSession(memory.allocator(), doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer session.deinit();
    _ = session.run();
    var result = try session.takeResult();
    defer result.deinit();
}

test "lowering generated reopenings rehashing nesting and rotations agree without expanding sets" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {node[base=initial];");
    for (0..40) |i| {
        try source.writer.print("subgraph s{d}{{node[local=v{d}];n{d}}}->subgraph s{d}{{n{d}}};node[parent=v{d}];subgraph s{d}{{n{d}}}; n{d}[", .{ i % 10, i, i, (i + 1) % 10, i + 1, i, i % 10, i + 100, i });
        for (0..20) |k| try source.writer.print("k{d}=v{d} ", .{ (k * 7 + i) % 20, i });
        try source.writer.writeAll("];");
    }
    for (0..256) |_| try source.writer.writeAll("{");
    try source.writer.writeAll("{x y z}->{p q r}");
    for (0..256) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("}");
    try check(false, source.written());
    try check(true, source.written());
}

test "long identifier glue is resumable and successful output outlives Document and session" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {\"a\"/*");
    try source.writer.splatByteAll('x', 8192);
    try source.writer.writeAll("*/+\"b\"; <ab>}");
    var parsed = Dot.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{});
    var session = try IR.loweringSession(a, &parsed.document.?, .{ .interpretation = Dot.interpretation(&parsed.document.?, .{}) });
    const prefix = session.advance(4096);
    try expect(prefix.outcome == null);
    try equal(@as(u32, 0), prefix.nodes_created);
    _ = session.run();
    var result = try session.takeResult();
    session.deinit();
    parsed.deinit(a);
    defer result.deinit();
    try equal(@as(usize, 1), result.nodes.len);
    try expect(try result.findNode("ab") != null);
}

test "lowering frees every interrupted allocation including pending growth and map snapshots" {
    var parsed = Dot.parseAndValidate(a, "digraph {node[x=1 y=2]; subgraph s{a b c}; node[z=3]; subgraph s{d};a->{e f g}[k=1 l=2 m=3];bad->;h}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{&parsed.document.?});
}

test "lowering resource stops never publish output" {
    var parsed = Dot.parseAndValidate(a, "digraph {subgraph s{a b};a->c[x=1 y=2];}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const cases = .{
        .{ dot.ir.Limits{ .max_bytes = 0 }, error.MemoryLimit },
        .{ dot.ir.Limits{ .max_mentions = 0 }, error.MentionLimit },
        .{ dot.ir.Limits{ .max_connections = 0 }, error.ConnectionLimit },
        .{ dot.ir.Limits{ .max_attributes = 0 }, error.AttributeLimit },
        .{ dot.ir.Limits{ .max_scopes = 1 }, error.ScopeLimit },
        .{ dot.ir.Limits{ .max_nodes = 1 }, error.NodeLimit },
    };
    inline for (cases) |case| {
        var session = try IR.loweringSession(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}), .limits = case[0] });
        defer session.deinit();
        try equal(case[1], session.run().outcome.?.failure);
        try std.testing.expectError(case[1], session.takeResult());
        session.cancel();
        try equal(case[1], session.advance(1).outcome.?.failure);
    }
    var node = Dot.parseAndValidate(a, "digraph {a[x=1]}", dot.diagnostic.discard, .{});
    defer node.deinit(a);
    var limited = try IR.loweringSession(a, &node.document.?, .{ .interpretation = Dot.interpretation(&node.document.?, .{}), .limits = .{ .max_attribute_states = 0 } });
    defer limited.deinit();
    try equal(error.AttributeStateLimit, limited.run().outcome.?.failure);
}

test "native lowering names ports and concatenations match direct logical identity" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .execution = .{ .metering = true } } });
    const source = "digraph {subgraph 名{\"初\"+\"😀\"};\"初😀\":\"埠😀\":n->x[café=\"a\"+<<b>中文&amp;</b>>]; \"尾\\😀\";subgraph 名{z}}";
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
        const doc = &parsed.document.?;
        var direct = try Native.lowerComplete(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
        defer direct.deinit();
        var session = try Native.loweringSession(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
        defer session.deinit();
        while (session.advance(1).outcome == null) {}
        var result = try session.takeResult();
        defer result.deinit();
        try compare(direct, result);
    }
}
