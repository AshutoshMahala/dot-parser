const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const eq = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

fn lookup(comptime Profile: type, view: anytype, key: []const u8) !void {
    const expected = try view.attributeWith(key, .{});
    var total: ?u64 = null;
    for ([_]u32{ 1, 2, 7, 64, 4096 }) |grant| {
        var s = try Profile.attributeSession(view, key, .{});
        defer s.deinit();
        try eq(@as(u64, 0), s.total_work);
        while (true) {
            const zero = s.advance(0);
            try eq(@as(u32, 0), zero.work_used);
            try expect(zero.outcome == null);
            const result = s.advance(grant);
            try expect(result.work_used <= grant);
            if (result.outcome) |o| {
                try eq(expected, o.success);
                if (total) |n| try eq(n, result.total_work) else total = result.total_work;
                break;
            }
        }
        try eq(@as(usize, 0), s.peakBytes());
        s.cancel();
        try eq(expected, s.run().outcome.?.success);
        try eq(@as(u32, 0), s.advance(9).work_used);
    }
}
fn enumeration(comptime Profile: type, view: anytype, comptime folded: bool) !void {
    var total: ?u64 = null;
    for ([_]u32{ 1, 3, 64, 4096 }) |grant| {
        var expected = if (folded) try view.attributesWith(.{}) else try view.attributes(.{});
        defer if (!folded) expected.deinit();
        var s = try Profile.attributesSession(view, .{});
        defer s.deinit();
        var count: u32 = 0;
        while (true) {
            const zero = s.advance(0);
            try expect(zero.attribute == null);
            try eq(@as(u32, 0), zero.work_used);
            const result = s.advance(grant);
            try expect(result.work_used <= grant);
            if (result.attribute) |v| {
                try eq((try expected.next()).?, v);
                count += 1;
            }
            try eq(count, result.attributes_emitted);
            if (result.outcome) |o| {
                try expect(o == .success);
                try expect(try expected.next() == null);
                if (total) |n| try eq(n, result.total_work) else total = result.total_work;
                break;
            }
        }
        const terminal = s.run();
        try expect(terminal.attribute == null);
        try eq(@as(u32, 0), terminal.work_used);
    }
}
fn checkGraph(comptime Profile: type, graph: anytype) !void {
    var nodes = graph.nodeIterator();
    while (nodes.next()) |node| {
        for ([_][]const u8{ "color", "label", "empty", "missing", "tailport", "headport" }) |key| try lookup(Profile, node, key);
        try enumeration(Profile, node, false);
    }
    const data = if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph;
    for (0..data.scopes.len) |i| {
        const scope = try graph.scopeView(@fromBackingInt(@as(u32, @intCast(i))));
        try lookup(Profile, scope, "color");
        try lookup(Profile, scope, "missing");
        try enumeration(Profile, scope, false);
    }
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |edge| {
        for ([_][]const u8{ "color", "label", "empty", "missing", "tailport", "headport" }) |key| try lookup(Profile, edge, key);
        try enumeration(Profile, edge, false);
    }
    var folded = try graph.materialize(.{});
    defer folded.deinit();
    var folded_edges = folded.edgeIterator();
    while (folded_edges.next()) |edge| {
        for ([_][]const u8{ "color", "label", "empty", "missing", "tailport", "headport" }) |key| try lookup(Profile, edge, key);
        try enumeration(Profile, edge, true);
    }
}

test "attribute sessions match direct views across all targets and budget partitions" {
    for ([_][]const u8{
        "digraph { a -> b; }",
        "digraph { graph[color=gold]; node[color=red]; edge[color=blue]; a[empty=\"\"]; a:p->b:q[label=x]; a:r->b:s[label=y]; subgraph s{c[color=green]} subgraph s{d} -> a; }",
        "strict digraph { node[color=red]; edge[color=blue]; a:p->{b c}; edge[color=green]; a:q->b[label=updated color=yellow]; a->c; b->c; }",
        "strict graph { a:p--b:q; b:r--a:s[label=x]; {a b}--{b a}[color=red]; c--d; }",
        "strict graph { {a b}--{b a}; b:p--a:q; x--y; z:ignored; }",
    }) |source| {
        var complete = try dot.ir.parse(a, source, .{});
        defer complete.deinit();
        try checkGraph(IR, complete.ir().?);
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        try checkGraph(IR, partial.ir().?);
    }
}

test "attribute sessions preserve partial candidates and port orientation uncertainty" {
    for ([_][]const u8{
        "digraph { node[color=red]; a[color=blue]; bad->; b[label=ok]; a->b; }",
        "strict graph { a:p--b:q; bad-- ; b:r--a:s[color=green]; c--d; }",
        "strict digraph { a->b[color=red]; bad->; a->b[label=ok]; c->d;",
        "strict digraph { subgraph s { @@ }; a->b[color=red]; subgraph s {} -> b[color=blue] }",
        "strict graph { @@; a:p--b:q; subgraph s {}--b:r }",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        try checkGraph(IR, result.ir().?);
    }
}

fn advance(session: anytype, grant: u32) !@TypeOf(session.*).Progress {
    return switch (@typeInfo(@TypeOf(session.advance(grant)))) {
        .error_union => try session.advance(grant),
        else => session.advance(grant),
    };
}
fn drain(session: anytype, grant: u32) !@TypeOf(session.*).Progress {
    while (true) {
        const result = if (grant == 0) session.run() else try advance(session, grant);
        if (result.outcome != null) return result;
    }
}

test "lifetime work limits include preparation and never replenish on resume" {
    var result = try dot.ir.parse(a, "strict digraph {edge[color=red];a->b[label=x];a->b[color=green];}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    inline for (.{ false, true }) |all| {
        var reference = if (all) try IR.attributesSession(edge, .{}) else try IR.attributeSession(edge, "color", .{});
        defer reference.deinit();
        const total = (try drain(&reference, 0)).total_work;
        for (0..@intCast(total + 1)) |limit| {
            for ([_]u32{ 1, 7, 4096 }) |budget| {
                const options = .{ .limits = .{ .max_work = limit } };
                var s = if (all) try IR.attributesSession(edge, options) else try IR.attributeSession(edge, "color", options);
                defer s.deinit();
                const p = try drain(&s, budget);
                try eq(@as(u64, limit), p.total_work);
                if (limit < total) try eq(error.WorkLimit, p.outcome.?.failure) else try expect(p.outcome.? == .success);
                const stopped = s.run();
                try eq(@as(u32, 0), stopped.work_used);
                try eq(p.outcome, stopped.outcome);
                if (all) try expect(stopped.attribute == null);
            }
        }
    }
    var borrowed = graph.*;
    borrowed.limits.max_work = 0;
    var s = try IR.attributeSession(try borrowed.nodeView(edge.edge.from), "color", .{});
    defer s.deinit();
    try eq(error.WorkLimit, s.run().outcome.?.failure);
}

const Stop = struct {
    calls: u64 = 0,
    stop_at: u64 = std.math.maxInt(u64),
    work: ?*const u64 = null,
    last: u64 = 0,
    max_gap: u64 = 0,
    fn requested(ctx: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.work) |n| {
            self.max_gap = @max(self.max_gap, n.* - self.last);
            self.last = n.*;
        }
        return self.calls >= self.stop_at;
    }
    fn hook(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "cancellation polls entry zero grants and every selected interval including scratch work" {
    var result = try dot.ir.parsePartial(a, "strict graph {a:p--b:q[color=red];bad--;b:r--a:s[label=x];}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    inline for (.{ false, true }) |runtime| inline for (.{ 1, 4, 64 }) |interval| {
        const P = dot.ir.Lowering(.{ .runtime_policy = runtime, .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } });
        inline for (.{ false, true }) |all| {
            for ([_]u32{ 1, 7, 4096 }) |budget| {
                var count: Stop = .{};
                var full = if (all) try P.attributesSession(edge, .{ .cancellation = count.hook() }) else try P.attributeSession(edge, "tailport", .{ .cancellation = count.hook() });
                defer full.deinit();
                count.work = &full.total_work;
                _ = try drain(&full, budget);
                try expect(count.max_gap <= interval);
                for (1..@intCast(count.calls + 1)) |stop_at| {
                    var stop: Stop = .{ .stop_at = stop_at };
                    const options = .{ .cancellation = stop.hook() };
                    const initial = if (all) P.attributesSession(edge, options) else P.attributeSession(edge, "tailport", options);
                    if (stop_at == 1) {
                        try std.testing.expectError(error.Cancelled, initial);
                        continue;
                    }
                    var s = try initial;
                    defer s.deinit();
                    stop.work = &s.total_work;
                    const p = try drain(&s, budget);
                    try eq(error.Cancelled, p.outcome.?.failure);
                    try expect(stop.max_gap <= interval);
                    try eq(@as(u64, stop_at), stop.calls);
                    _ = try advance(&s, 0);
                    _ = s.run();
                    try eq(@as(u64, stop_at), stop.calls);
                }
            }
            var stop: Stop = .{ .stop_at = 2 };
            var zero = if (all) try P.attributesSession(edge, .{ .cancellation = stop.hook() }) else try P.attributeSession(edge, "color", .{ .cancellation = stop.hook() });
            defer zero.deinit();
            try eq(error.Cancelled, (try advance(&zero, 0)).outcome.?.failure);
            try eq(@as(u64, 0), zero.total_work);
            // Cancellation wins at a zero lifetime allowance when entry to
            // the advance is the next cancellation checkpoint.
            stop = .{ .stop_at = 2 };
            var limited = if (all) try P.attributesSession(edge, .{ .cancellation = stop.hook(), .limits = .{ .max_work = 0 } }) else try P.attributeSession(edge, "color", .{ .cancellation = stop.hook(), .limits = .{ .max_work = 0 } });
            defer limited.deinit();
            try eq(error.Cancelled, limited.run().outcome.?.failure);
        }
    };
}

test "runtime policy shared options and disabled metering retain existing session conventions" {
    var result = try dot.ir.parse(a, "digraph {a[color=red];a->b;}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var node_it = graph.nodeIterator();
    const node = node_it.next().?;
    const Runtime = dot.ir.Lowering(.{ .runtime_policy = true });
    var s = try Runtime.attributeSession(node, "color", .{});
    defer s.deinit();
    try std.testing.expectError(error.MeteringDisabled, s.advance(7));
    try eq(@as(u64, 0), s.total_work);
    try eq(try node.attributeWith("color", .{}), s.run().outcome.?.success);
    const options: Runtime.AttributesSession.Options = .{ .policy = .{ .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = 4 } } };
    try expect(Runtime.AttributeSession.Options == Runtime.PartialAttributesSession.Options);
    try expect(Runtime.AttributeSession.Options == Runtime.ContainsSession.Options);
    try expect(Runtime.AttributeSession.Options == Runtime.EdgeSession.Options);
    var stream = try Runtime.attributesSession(node, options);
    defer stream.deinit();
    try expect((try drain(&stream, 1)).outcome.? == .success);
    var edge_stream = try IR.edgeSession(graph, @as(IR.AttributeSession.Options, .{}));
    defer edge_stream.deinit();
    _ = edge_stream.run();
    try std.testing.expectError(error.InvalidCancellationInterval, Runtime.attributeSession(node, "color", .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    var manual = try IR.attributesSession(node, .{});
    defer manual.deinit();
    manual.cancel();
    try eq(error.Cancelled, manual.advance(0).outcome.?.failure);
    var plain = try dot.ir.Lowering(.{}).attributesSession(node, .{});
    defer plain.deinit();
    while (true) {
        if (plain.run().outcome) |outcome| {
            try expect(outcome == .success);
            break;
        }
    }
}

test "only strict compact enumeration allocates winner scratch and failures clean up" {
    var result = try dot.ir.parse(a, "strict digraph {a[n=1];a:p->b:q[color=red label=x];a->b[color=green];}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var memory = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var borrowed = graph.*;
    borrowed.allocator = memory.allocator();
    const edge = try borrowed.edgeView(.{ .from = (try graph.findNode("a")).?, .to = (try graph.findNode("b")).?, .first_connection = @fromBackingInt(0), .operator = .directed });
    const node = edge.from();
    var one = try IR.attributeSession(edge, "color", .{ .limits = .{ .max_bytes = 0, .max_pairs = 0 } });
    defer one.deinit();
    try eq(try edge.attribute("color"), one.run().outcome.?.success);
    var nodes = try IR.attributesSession(node, .{ .limits = .{ .max_bytes = 0 } });
    defer nodes.deinit();
    try expect((try drain(&nodes, 1)).outcome.? == .success);
    var failed = try IR.attributesSession(edge, .{});
    defer failed.deinit();
    try eq(@as(usize, 0), memory.allocations);
    try eq(@as(usize, 0), failed.peakBytes());
    try eq(error.OutOfMemory, (try drain(&failed, 1)).outcome.?.failure);
    var limited = try IR.attributesSession(edge, .{ .limits = .{ .max_bytes = 0 } });
    defer limited.deinit();
    try eq(error.MemoryLimit, (try drain(&limited, 1)).outcome.?.failure);
    // A successful stream retains exactly 12 bytes per written edge key, not
    // per update or per node key. Derived ports need only inline winner slots.
    const good_edge = try graph.edgeView(edge.edge);
    var success = try IR.attributesSession(good_edge, .{});
    defer success.deinit();
    try expect((try drain(&success, 1)).outcome.? == .success);
    try eq(@as(usize, 24), success.peakBytes());
    var folded = try graph.materialize(.{});
    defer folded.deinit();
    var folded_it = folded.edgeIterator();
    var folded_stream = try IR.attributesSession(folded_it.next().?, .{ .limits = .{ .max_bytes = 0, .max_pairs = 0 } });
    defer folded_stream.deinit();
    try expect((try drain(&folded_stream, 1)).outcome.? == .success);
    try eq(@as(usize, 0), folded_stream.peakBytes());
}

test "long borrowed keys and source glue are metered without a decoded allocation" {
    const key: [1024]u8 = @splat('k');
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.print("digraph {{a[\"{s}\"/*", .{key[0..512]});
    try source.writer.splatBytesAll("x", 4096);
    try source.writer.print("*/+\"{s}\"=ok];}}", .{key[512..]});
    var result = try dot.ir.parse(a, source.written(), .{});
    defer result.deinit();
    const graph = result.ir().?;
    var nodes = graph.nodeIterator();
    const node = nodes.next().?;
    try lookup(IR, node, &key);
    var s = try IR.attributeSession(node, &key, .{});
    defer s.deinit();
    try eq(@as(u64, 0), s.total_work);
    try expect(s.advance(64).outcome == null);
    try eq(@as(u64, 64), s.total_work);
    try eq(try node.attributeWith(&key, .{}), s.run().outcome.?.success);
    try expect(s.total_work > 4096);
    try eq(@as(usize, 0), s.peakBytes());
}

test "port introductions never invent keys for empty products and preserve first undirected orientation" {
    for ([_][]const u8{
        "graph {a:p--{}; x--y;}",
        "strict graph {{a b}--{b a}; b:p--a:q; x--y;}",
        "strict graph {{b a}--{a b}; b:p--a:q; x--y;}",
        "strict graph {a--b; b:p--{a}; x--y;}",
        "strict graph {a:p--a:q; a:r--a:s; x--y;}",
        "strict graph {a:ignored; subgraph s{a b}--x; subgraph s{c}; x:p--subgraph s{}; y--z;}",
        "digraph {a:unused; x->y[\"tail\"+\"port\"=\"\"]; z->w;}",
    }) |source| {
        var result = try dot.ir.parse(a, source, .{});
        defer result.deinit();
        try checkGraph(IR, result.ir().?);
    }
}

test "native encoded keys use the same logical UTF8 lookup and partial qualifications" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .retention = .{ .partial = true } } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .execution = .{ .metering = true } } });
    inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        for ([_]bool{ false, true }) |broken| {
            var source = std.Io.Writer.Allocating.init(a);
            defer source.deinit();
            const text = "strict graph {graph[color=gold];node[color=red];a[\"café😀\"=yes \"co\"/*gap*/+\"lor\"=green];a:p--b:q; b:r--a:s[\"head\"+\"port\"=\"m:n\"];";
            const fragments = [_][]const u8{ text, if (broken) "bad-- ;" else "", "x--y;}" };
            for (fragments) |fragment| {
                var it = (try std.unicode.Utf8View.init(fragment)).iterator();
                while (it.nextCodepoint()) |scalar| {
                    switch (actual) {
                        .utf8 => {
                            var bytes: [4]u8 = undefined;
                            const n = try std.unicode.utf8Encode(scalar, &bytes);
                            try source.writer.writeAll(bytes[0..n]);
                        },
                        .utf16le, .utf16be => {
                            const order = if (actual == .utf16be) .big else .little;
                            if (scalar < 0x10000) try source.writer.writeInt(u16, @intCast(scalar), order) else {
                                try source.writer.writeInt(u16, @intCast(0xd800 + ((scalar - 0x10000) >> 10)), order);
                                try source.writer.writeInt(u16, @intCast(0xdc00 + ((scalar - 0x10000) & 0x3ff)), order);
                            }
                        },
                        .utf32le, .utf32be => try source.writer.writeInt(u32, scalar, if (actual == .utf32be) .big else .little),
                        else => unreachable,
                    }
                }
            }
            var parsed = try P.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{ .encoding = actual });
            defer parsed.deinit(a);
            const doc = &parsed.document.?;
            var graph = try Native.lowerPartial(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
            defer graph.deinit();
            try checkGraph(Native, &graph);
            var nodes = graph.nodeIterator();
            const node = nodes.next().?;
            try lookup(Native, node, "café😀");
            try lookup(Native, node, "café😁");
            if (!broken) {
                var complete = try Native.lowerComplete(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
                defer complete.deinit();
                try checkGraph(Native, &complete);
            }
        }
    }
}

test "generated compact and folded streams agree without expanding during lookup" {
    const ends = [_][]const u8{ "a", "b", "a:p", "b:q", "{a b}", "{b a}", "{}" };
    for (0..28) |seed| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        try source.writer.writeAll(if (seed % 2 == 0) "strict graph {" else "graph {");
        for (0..5) |i| {
            try source.writer.print("{s}--{s}", .{ ends[(seed + i * 3) % ends.len], ends[(seed * 3 + i * 5) % ends.len] });
            if (i % 2 == 0) try source.writer.print("[color=v{d} label=\"x\"+\"y\"]", .{i});
            if (i == 3) try source.writer.writeAll("[\"tail\"+\"port\"=\"p:n\"]");
            try source.writer.writeAll(";");
        }
        try source.writer.writeAll("x--y;}");
        var result = try dot.ir.parse(a, source.written(), .{});
        defer result.deinit();
        try checkGraph(IR, result.ir().?);
    }
}

test "delivered views survive scratch and materialized owner cleanup and borrowed keys stay stable" {
    var result = try dot.ir.parse(a, "strict digraph {a->b[color=red];a->b[color=green];}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    var folded = try graph.materialize(.{});
    var edges = folded.edgeIterator();
    const edge = edges.next().?;
    const key = try a.dupe(u8, "color");
    defer a.free(key);
    var query = try IR.attributeSession(edge, key, .{});
    const expected = edge.attribute("color").?;
    try expect(query.advance(1).outcome == null);
    const found = query.run().outcome.?.success.?;
    query.deinit();
    var stream = try IR.attributesSession(edge, .{});
    const entry = stream.run().attribute.?;
    stream.deinit();
    folded.deinit();
    try eq(expected, found);
    try eq(expected, entry);
    const text = try entry.value().toString(a);
    defer a.free(text);
    try std.testing.expectEqualStrings("green", text);
}

test "constructors reject bad handles without traversal and strict identity checks are metered" {
    var result = try dot.ir.parse(a, "strict digraph {a->b[color=red];a->b[color=green];c;}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const invalid: IR.Graph.NodeView = .{ .graph = graph, .id = @fromBackingInt(@as(u32, @intCast(graph.nodes.len))) };
    try std.testing.expectError(error.InvalidHandle, IR.attributeSession(invalid, "color", .{}));
    try std.testing.expectError(error.InvalidHandle, IR.attributesSession(invalid, .{}));
    const bad_scope: IR.Graph.ScopeView = .{ .graph = graph, .id = @fromBackingInt(999) };
    try std.testing.expectError(error.InvalidHandle, IR.attributesSession(bad_scope, .{}));
    const later = try graph.edgeView(.{ .from = (try graph.findNode("a")).?, .to = (try graph.findNode("b")).?, .first_connection = @fromBackingInt(1), .operator = .directed });
    inline for (.{ false, true }) |all| {
        var session = if (all) try IR.attributesSession(later, .{}) else try IR.attributeSession(later, "missing", .{});
        defer session.deinit();
        try eq(@as(u64, 0), session.total_work);
        try eq(error.InvalidHandle, (try drain(&session, 1)).outcome.?.failure);
    }
}

test "huge products deep nesting and reopened scopes stay symbolic during attribute work" {
    for ([_]enum { product, nested, reopened }{ .product, .nested, .reopened }) |case| {
        var source = std.Io.Writer.Allocating.init(a);
        defer source.deinit();
        try source.writer.writeAll("strict digraph {");
        switch (case) {
            .product => {
                try source.writer.writeAll("{");
                for (0..50_000) |i| try source.writer.print("n{d};", .{i});
                try source.writer.writeAll("a}->{");
                for (50_000..100_000) |i| try source.writer.print("n{d};", .{i});
                try source.writer.writeAll("b}[color=red];");
            },
            .nested => {
                for (0..3000) |_| try source.writer.writeAll("{");
                try source.writer.writeAll("a");
                for (0..3000) |_| try source.writer.writeAll("}");
                try source.writer.writeAll("->b[color=red];");
            },
            .reopened => for (0..2000) |i| {
                try source.writer.print("subgraph s{{a n{d}}}->b[color=red];", .{i});
            },
        }
        try source.writer.writeAll("}");
        var result = try dot.ir.parse(a, source.written(), .{});
        defer result.deinit();
        const graph = result.ir().?;
        const edge = try graph.edgeView(.{ .from = (try graph.findNode("a")).?, .to = (try graph.findNode("b")).?, .operator = .directed, .first_connection = @fromBackingInt(0) });
        const expected = try edge.attribute("color");
        var query = try IR.attributeSession(edge, "color", .{ .limits = .{ .max_bytes = 0, .max_pairs = 0 } });
        defer query.deinit();
        try eq(@as(u64, 0), query.total_work);
        try eq(expected, (try drain(&query, 1)).outcome.?.success);
        try eq(@as(usize, 0), query.peakBytes());
        var stream = try IR.attributesSession(edge, .{ .limits = .{ .max_bytes = 12, .max_pairs = 0 } });
        defer stream.deinit();
        var delivered: u32 = 0;
        while (true) {
            const progress = stream.advance(7);
            try expect(progress.work_used <= 7);
            if (progress.attribute) |value| {
                try eq(expected.?, value);
                delivered += 1;
            }
            if (progress.outcome) |outcome| {
                try expect(outcome == .success);
                break;
            }
        }
        try eq(@as(u32, 1), delivered);
        try eq(@as(usize, 12), stream.peakBytes());
        try expect(graph.connections.len == if (case == .reopened) @as(usize, 2000) else 1);
    }
}

test "a stream keeps delivered views but does not report exhaustion after a later stop" {
    var result = try dot.ir.parse(a, "strict digraph {a->b[color=red label=x];a->b[color=green];}", .{});
    defer result.deinit();
    var edges = try result.ir().?.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    var first = try IR.attributesSession(edge, .{});
    defer first.deinit();
    const delivered = first.run();
    try expect(delivered.attribute != null and delivered.outcome == null);
    var limited = try IR.attributesSession(edge, .{ .limits = .{ .max_work = delivered.total_work } });
    const value = limited.run().attribute.?;
    const stopped = limited.advance(1);
    try expect(stopped.attribute == null);
    try eq(@as(u32, 1), stopped.attributes_emitted);
    try eq(error.WorkLimit, stopped.outcome.?.failure);
    limited.deinit();
    const text = try value.value().toString(a);
    defer a.free(text);
    try std.testing.expectEqualStrings("green", text);
}

test "queued lookup owns a stable key independently of its movable job record" {
    const Job = struct {
        key: []u8,
        query: IR.AttributeSession,
        fn init(gpa: std.mem.Allocator, node: IR.Graph.NodeView, key: []const u8) !@This() {
            const owned = try gpa.dupe(u8, key);
            errdefer gpa.free(owned);
            return .{ .key = owned, .query = try IR.attributeSession(node, owned, .{}) };
        }
        fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            self.query.deinit();
            gpa.free(self.key);
            self.* = undefined;
        }
    };
    var result = try dot.ir.parse(a, "digraph {a[color=red];}", .{});
    defer result.deinit();
    var nodes = result.ir().?.nodeIterator();
    const node = nodes.next().?;
    var original = try Job.init(a, node, "color");
    try expect(original.query.advance(1).outcome == null);
    var moved = original;
    original = undefined; // Move ownership; never keep two live owners.
    defer moved.deinit(a);
    try eq(try node.attributeWith("color", .{}), moved.query.run().outcome.?.success);
}
