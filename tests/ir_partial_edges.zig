const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;
const IR = dot.ir.Lowering(.{});

fn formatted(expected: []const u8, value: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{value});
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "partial edges reuse complete expansion and folded attributes on complete input" {
    for ([_][]const u8{
        "digraph {}",
        "digraph { a->b; a->b; {}->c }",
        "strict digraph { edge[color=red]; {a b}->{x y}[label=old]; edge[color=blue]; a->x[label=new] }",
        "strict graph {a:p--b:q[color=red]; b:r--a:s[label=new];a--a}",
        "digraph {a:p->{}; a->b[label=\"a\"+<<b>bee</b>>]; edge[color=red]; c->d}",
        "strict digraph {subgraph s {a}->x; subgraph s {b}->x[color=blue]}",
    }) |source| {
        var full = try dot.ir.parse(a, source, .{});
        defer full.deinit();
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        const ir = partial.ir().?;
        var expected = try full.ir().?.materialize(.{});
        defer expected.deinit();
        var actual = try ir.materialize(.{});
        defer actual.deinit();
        var topology = try ir.materialize(.{ .attributes = false });
        defer topology.deinit();
        try equal(.complete, actual.state());
        try equal(full.ir().?.kind, actual.kind().known);
        try equal(expected.retainedBytes(), actual.retainedBytes());
        try equal(expected.peak_bytes, actual.peak_bytes);
        try std.testing.expectEqualSlices(dot.ir.Edge, expected.edges, actual.edges);
        try std.testing.expectEqualSlices(dot.ir.Edge, expected.edges, topology.edges);
        var stream = try ir.edgeIterator(.{});
        defer stream.deinit();
        var edges = actual.edgeIterator();
        var plain_edges = topology.edgeIterator();
        var expected_edges = expected.edgeIterator();
        while (expected_edges.next()) |full_edge| {
            const edge = edges.next().?;
            const streamed = (try stream.next()).?;
            const plain = plain_edges.next().?;
            try equal(full_edge.edge, edge.edge);
            try equal(edge.edge, streamed.edge);
            try equal(edge.edge, plain.edge);
            try equal(edge.edge.first_connection, edge.firstConnection().known);
            try equal(edge.edge.from, edge.orientation().known.from);
            try equal(edge.edge.to, edge.to().id);
            var attrs = edge.attributes();
            var bounded = try edge.attributesWith(.{});
            var compact = try streamed.attributes(.{});
            defer compact.deinit();
            var expected_attrs = full_edge.attributes();
            while (expected_attrs.next()) |attribute| {
                try equal(attribute.resolved, attrs.next().?.known.resolved);
                try equal(attribute.resolved, (try bounded.next()).?.known.resolved);
                try equal(attribute.resolved, (try compact.next()).?.known.resolved);
                var buf: [64]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                try w.print("{f}", .{attribute.key()});
                try equal(attribute.resolved, edge.attribute(w.buffered()).known.?.resolved);
                try equal(attribute.resolved, (try streamed.attribute(w.buffered())).known.?.resolved);
                try equal(attribute.resolved, (try plain.attribute(w.buffered())).known.?.resolved);
            }
            try expect(attrs.next() == null);
            try expect(try bounded.next() == null);
            try expect(try compact.next() == null);
            try expect(edge.attribute("missing").known == null);
            inline for (.{ "tailPort", "headPort" }) |method| {
                const port = @field(@TypeOf(edge), method)(edge).known;
                const other = @field(@TypeOf(full_edge), method)(full_edge);
                try equal(if (other) |p| p.resolved else null, if (port) |p| p.resolved else null);
                const streamed_port = (try @field(@TypeOf(streamed), method)(streamed)).known;
                try equal(if (port) |p| p.resolved else null, if (streamed_port) |p| p.resolved else null);
            }
        }
        try expect(edges.next() == null);
        try expect(try stream.next() == null);
        try expect(try stream.next() == null);
        try expect(plain_edges.next() == null);
    }
}

test "partial edge winners use connection order and retain uncertainty after gaps" {
    const source = "strict digraph {edge[color=red];a->b[label=old];bad -> ;a->b[label=new];b->c[color=blue];}";
    var result = try dot.ir.parsePartial(a, source, .{});
    defer result.deinit();
    const ir = result.ir().?;
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    try equal(.partial, graph.state());
    var edges = graph.edgeIterator();
    const first = edges.next().?;
    try formatted("new", first.attribute("label").known.?);
    try formatted("red", first.attribute("color").unknown.retained.?);
    try expect(first.attribute("missing").unknown.retained == null);
    try expect(first.firstConnection() == .unknown);
    try expect(first.orientation() == .known);
    try formatted("blue", edges.next().?.attribute("color").known.?);
    try expect(edges.next() == null);
    var stream = try ir.edgeIterator(.{});
    defer stream.deinit();
    try formatted("new", (try (try stream.next()).?.attribute("label")).known.?);

    var tail = try dot.ir.parsePartial(a, "strict digraph {a->b[label=old];bad -> ;}", .{});
    defer tail.deinit();
    var tail_edges = try tail.ir().?.edgeIterator(.{});
    defer tail_edges.deinit();
    try formatted("old", (try (try tail_edges.next()).?.attribute("label")).unknown.retained.?);
}

test "partial non-strict parallel edges keep their own explicit values despite later gaps" {
    var result = try dot.ir.parsePartial(a, "digraph { a:p->b:q[color=red];bad -> ;a:r->b:s[color=blue];bad -> ;}", .{});
    defer result.deinit();
    var graph = try result.ir().?.materialize(.{});
    defer graph.deinit();
    try equal(@as(usize, 2), graph.edges.len);
    var edges = graph.edgeIterator();
    for ([_][]const u8{ "red", "blue" }) |color| {
        const edge = edges.next().?;
        try formatted(color, edge.attribute("color").known.?);
        try expect(edge.firstConnection() == .known);
        try expect(edge.tailPort() == .known);
        try expect(edge.headPort() == .known);
    }
}

test "partial strict undirected ports and orientation remain qualified" {
    var result = try dot.ir.parsePartial(a, "strict graph { bad -> ; a:p--b:q; b:r--a:s[color=blue headport=override]; }", .{});
    defer result.deinit();
    const ir = result.ir().?;
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    var edges = graph.edgeIterator();
    const edge = edges.next().?;
    try expect(edge.orientation() == .unknown);
    try equal(edge.edge.from, edge.orientation().unknown.retained.?.from);
    try equal(edge.edge.first_connection, edge.firstConnection().unknown.retained.?);
    try formatted("a", edge.from().name());
    try formatted("b", edge.to().name());
    try formatted("s", edge.attribute("tailport").unknown.retained.?);
    try formatted("override", edge.attribute("headport").unknown.retained.?);
    try formatted("blue", edge.attribute("color").known.?);
    try expect(edge.tailPort().unknown.retained.?.syntax() != null);
    try expect(edge.headPort().unknown.retained.?.syntax() == null);
    var stream = try ir.edgeIterator(.{});
    defer stream.deinit();
    const streamed = (try stream.next()).?;
    try equal(edge.tailPort().unknown.retained.?.resolved, (try streamed.tailPort()).unknown.retained.?.resolved);
}

test "partial expansion retains children but never invents abandoned owners" {
    for ([_][]const u8{
        "digraph { a -> {b->c;} -> ; d->e; }",
        "digraph { a -> {b->c;} ->",
        "digraph { subgraph s {b->c; ",
        "digraph { b->c; unfinished [label=\"fake -> edge",
        "digraph { b->c; /* fake -> edge",
        "digraph { b->c; unfinished [label=<fake edge",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        var graph = try result.ir().?.materialize(.{});
        defer graph.deinit();
        var edges = graph.edgeIterator();
        const first = edges.next().?;
        try formatted("b", first.from().name());
        try formatted("c", first.to().name());
        if (std.mem.indexOf(u8, source, "d->e") != null) {
            const second = edges.next().?;
            try formatted("d", second.from().name());
            try formatted("e", second.to().name());
        }
        try expect(edges.next() == null);
        try equal(.partial, graph.state());
    }
}

test "partial edge qualification follows child execution order and shared chain origins" {
    var result = try dot.ir.parsePartial(a, "strict digraph { a->{b->c[color=old];bad -> ;}->d[color=blue]; a->b->c[label=new]; }", .{});
    defer result.deinit();
    const ir = result.ir().?;
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    var edges = graph.edgeIterator();
    while (edges.next()) |edge| {
        // b->c was executed before the gap; all outer colors follow it.
        if (edge.edge.from == (try ir.findNode("b")).known.? and edge.edge.to == (try ir.findNode("c")).known.?) {
            try formatted("old", edge.attribute("color").unknown.retained.?);
            try formatted("new", edge.attribute("label").known.?);
        } else {
            const color = edge.attribute("color");
            // The partial-only dependency summary is conservative: a later
            // set connection can consume membership introduced by a gap.
            try formatted("blue", if (color == .known) color.known.? else color.unknown.retained.?);
        }
    }
}

test "earlier gaps cannot certify a strict winner consumed by a later set endpoint" {
    for ([_][]const u8{
        "strict digraph { subgraph s { @@ }; a->b[color=red]; subgraph s {}->b[color=blue] }",
        "strict digraph { @@; a->b[color=red]; subgraph s {}->b[color=blue] }",
        "strict digraph { {@@}->{a->b[color=red]}[color=blue] }",
        "strict digraph { subgraph s {subgraph t {@@}}; a->b[color=red]; subgraph s {}->b[color=blue] }",
        "strict digraph { subgraph s {@@}->c; a->b[color=red]; subgraph s {}->b[color=blue] }",
        "strict digraph { subgraph s {@@}; a->b[color=red]; a->subgraph s {}[color=blue] }",
        "strict graph { subgraph s {@@}; a--b[color=red]; subgraph s {}--b[color=blue] }",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        const ir = result.ir().?;
        const from = (try ir.findNode("a")).known.?;
        const to = (try ir.findNode("b")).known.?;
        var folded = try ir.materialize(.{});
        defer folded.deinit();
        var stream = try ir.edgeIterator(.{});
        defer stream.deinit();
        var saw_pair = false;
        while (try stream.next()) |edge| {
            if (edge.edge.from != from or edge.edge.to != to) continue;
            saw_pair = true;
            const answer = try edge.attribute("color");
            try expect(answer == .unknown);
            try formatted("red", answer.unknown.retained.?);
            var entries = folded.edgeIterator();
            while (entries.next()) |entry| if (entry.edge.from == from and entry.edge.to == to) {
                try equal(answer, entry.attribute("color"));
            };
        }
        try expect(saw_pair);
    }
}

test "known partial strict edge answers survive compatible gap fillings" {
    const prefixes = [_][]const u8{ "", "edge[color=red];", "a:p--b:q[color=red];", "{a b}--{a b}[color=red];" };
    const suffixes = [_][]const u8{ "a--b;", "b:r--a:s[color=blue];", "a--b[color=blue]; b--a[label=done];" };
    const fillings = [_][]const u8{ "", "edge[color=green headport=x];", "b:t--a:u[color=green headport=override];", "z--y[newkey=v];a--b[label=hidden];" };
    for (prefixes) |prefix| for (suffixes) |suffix| {
        const broken = try std.fmt.allocPrint(a, "strict graph {{{s} bad -> ; {s}}}", .{ prefix, suffix });
        defer a.free(broken);
        var partial = try dot.ir.parsePartial(a, broken, .{});
        defer partial.deinit();
        var graph = try partial.ir().?.materialize(.{});
        defer graph.deinit();
        for (fillings) |filling| {
            const source = try std.fmt.allocPrint(a, "strict graph {{{s} {s} {s}}}", .{ prefix, filling, suffix });
            defer a.free(source);
            var full = try dot.ir.parse(a, source, .{});
            defer full.deinit();
            var complete = try full.ir().?.materialize(.{});
            defer complete.deinit();
            var edges = graph.edgeIterator();
            while (edges.next()) |edge| {
                var from_buf: [32]u8 = undefined;
                var from = std.Io.Writer.fixed(&from_buf);
                try from.print("{f}", .{edge.from().name()});
                var to_buf: [32]u8 = undefined;
                var to = std.Io.Writer.fixed(&to_buf);
                try to.print("{f}", .{edge.to().name()});
                const from_id = (try full.ir().?.findNode(from.buffered())).?;
                const to_id = (try full.ir().?.findNode(to.buffered())).?;
                var complete_edges = complete.edgeIterator();
                var found = false;
                while (complete_edges.next()) |other| {
                    if (!(other.edge.from == from_id and other.edge.to == to_id) and !(other.edge.from == to_id and other.edge.to == from_id)) continue;
                    found = true;
                    for ([_][]const u8{ "color", "label", "headport", "tailport", "newkey", "missing" }) |key| {
                        const answer = edge.attribute(key);
                        // With the gap removed, candidates must also match the
                        // independent complete-input replay of retained input.
                        if (answer == .known or filling.len == 0) {
                            const known = if (answer == .known) answer.known else answer.unknown.retained;
                            const expected = other.attribute(key);
                            try equal(expected == null, known == null);
                            if (known) |v| {
                                var buffer: [128]u8 = undefined;
                                var w = std.Io.Writer.fixed(&buffer);
                                try w.print("{f}", .{expected.?});
                                try formatted(w.buffered(), v);
                            }
                        }
                    }
                    break;
                }
                try expect(found);
            }
        }
    };
}

test "partial huge symbolic products permit streaming prefixes and reject bounded materialization" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph { bad -> ; {");
    for (0..2500) |i| try source.writer.print("a{d};", .{i});
    try source.writer.writeAll("}->{");
    for (0..2500) |i| try source.writer.print("b{d};", .{i});
    try source.writer.writeAll("} }");
    var result = try dot.ir.parsePartial(a, source.written(), .{});
    defer result.deinit();
    const ir = result.ir().?;
    try equal(@as(u32, 1), ir.connectionCount());
    var stream = try ir.edgeIterator(.{ .limits = .{ .max_pairs = 3 } });
    defer stream.deinit();
    for (0..3) |_| try expect(try stream.next() != null);
    try std.testing.expectError(error.PairLimit, stream.next());
    try std.testing.expectError(error.PairLimit, stream.next());
    inline for (.{ true, false }) |attributes| try std.testing.expectError(error.PairLimit, ir.materialize(.{ .attributes = attributes }));
    try equal(@as(u32, 1), ir.connectionCount());
}

test "partial edge native views borrow IR values after output deinit without query allocations" {
    var memory = std.testing.FailingAllocator.init(a, .{});
    var result = try dot.ir.parsePartial(memory.allocator(), "strict digraph { a->b[label=\"a\"+<<b>bee</b>>];bad -> ; }", .{});
    defer result.deinit();
    const retained = result.ir().?.retainedBytes();
    var saved: IR.PartialGraph.AttributeView = undefined;
    {
        var materialized = try result.ir().?.materialize(.{});
        defer materialized.deinit();
        try equal(retained + materialized.retainedBytes(), memory.allocated_bytes - memory.freed_bytes);
        const count = memory.allocations;
        var edges = materialized.edgeIterator();
        const edge = edges.next().?;
        saved = edge.attribute("label").unknown.retained.?;
        var attributes = edge.attributes();
        while (attributes.next()) |_| {}
        try equal(count, memory.allocations);
    }
    try equal(retained, memory.allocated_bytes - memory.freed_bytes);
    try formatted("a<b>bee</b>", saved);
}

test "partial deep reopened memberships remain immutable during expansion" {
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    for (0..2000) |_| try source.writer.writeByte('{');
    try source.writer.writeAll("subgraph s{a;bad -> ;b}->x;subgraph s{c}->x;");
    for (0..2000) |_| try source.writer.writeByte('}');
    try source.writer.writeByte('}');
    var result = try dot.ir.parsePartial(a, source.written(), .{});
    defer result.deinit();
    const ir = result.ir().?;
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    var edges = graph.edgeIterator();
    for ([_][]const u8{ "a", "b", "a", "b", "c" }) |from| {
        const edge = edges.next().?;
        try formatted(from, edge.from().name());
        try formatted("x", edge.to().name());
    }
    try expect(edges.next() == null);
    try equal(@as(u32, 2), ir.connectionCount());
}

test "partial materialization accepts runtime options and topology-only excludes folding" {
    var result = try dot.ir.parsePartial(a, "digraph {a->b[x=1];bad -> ;}", .{});
    defer result.deinit();
    const ir = result.ir().?;
    var options: dot.ir.Options = .{ .limits = .{ .max_edges = 1 } };
    _ = &options;
    var folded = try ir.materialize(options);
    defer folded.deinit();
    try expect(@TypeOf(folded) == IR.PartialGraph.Materialized);
    var topology = try ir.materialize(.{ .attributes = false, .limits = .{ .max_attribute_states = 0 }, .cancellation = null });
    defer topology.deinit();
    try expect(@TypeOf(topology) == IR.PartialGraph.MaterializedTopology);
    try std.testing.expectEqualSlices(dot.ir.Edge, folded.edges, topology.edges);
    try std.testing.expectError(error.AttributeStateLimit, ir.materialize(.{ .limits = .{ .max_attribute_states = 0 } }));
    var plain = topology.edgeIterator();
    try formatted("1", (try plain.next().?.attribute("x")).known.?);
    try std.testing.expectError(error.InvalidHandle, ir.edgeView(.{ .from = @fromBackingInt(999), .to = @fromBackingInt(0), .operator = .directed, .first_connection = @fromBackingInt(0) }));
}

test "partial native edge values and unresolved auto do not invent a concrete graph kind" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .retention = .{ .partial = true } } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const text = "strict digraph { a:p:n->b[color=red];bad -> ;a->b[color=blue]; }";
        const width = comptime dot.encoding.unitBytes(actual);
        const big = actual == .utf16be or actual == .utf32be;
        var bytes: [text.len * width]u8 = @splat(0);
        for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        var parsed = try P.parseAndValidate(a, &bytes, dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        var ir = try Native.lowerPartial(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer ir.deinit();
        var graph = try ir.materialize(.{});
        defer graph.deinit();
        var edges = graph.edgeIterator();
        const edge = edges.next().?;
        const attr = edge.attribute("color").known.?;
        try formatted("blue", attr);
        try equal(@as(u32, 0), attr.value().span().?.start % width);
        try expect(edge.tailPort() == .unknown);
        var stream = try ir.edgeIterator(.{});
        defer stream.deinit();
        try equal(attr.resolved, (try (try stream.next()).?.attribute("color")).known.?.resolved);
    }
    const Auto = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .validation = .{ .graph = .{ .treated_as = .auto } } } });
    var parsed = Auto.parseAndValidate(a, "graph { a--b; bad -> ; }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    var ir = try IR.lowerPartial(a, &parsed.document.?, .{ .interpretation = Auto.interpretation(&parsed.document.?, .{}) });
    defer ir.deinit();
    try expect(ir.kind() == .unknown);
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    try expect(graph.kind() == .unknown);
    try equal(@as(usize, 1), graph.edges.len);
    try equal(.undirected, graph.edges[0].operator);
}

const Cancellation = struct {
    polls: usize = 0,
    stop: usize = std.math.maxInt(usize),
    fn check(ctx: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.polls += 1;
        return self.polls >= self.stop;
    }
    fn token(self: *@This()) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = check };
    }
};

test "partial expansion limits cancellation terminal errors and no half-built output" {
    var result = try dot.ir.parsePartial(a, "strict digraph {edge[base=1];{a b}->{x y}[color=red];bad -> ;a:p:n->x:q[color=blue];}", .{});
    defer result.deinit();
    const ir = result.ir().?;
    inline for (.{ true, false }) |folded| {
        try std.testing.expectError(error.PairLimit, ir.materialize(.{ .attributes = folded, .limits = .{ .max_pairs = 4 } }));
        try std.testing.expectError(error.EdgeLimit, ir.materialize(.{ .attributes = folded, .limits = .{ .max_edges = 3 } }));
        try std.testing.expectError(error.MemoryLimit, ir.materialize(.{ .attributes = folded, .limits = .{ .max_bytes = 0 } }));
        try std.testing.expectError(error.WorkLimit, ir.materialize(.{ .attributes = folded, .limits = .{ .max_work = 0 } }));
        var cancel: Cancellation = .{};
        var materialized = try ir.materialize(.{ .attributes = folded, .cancellation = cancel.token() });
        defer materialized.deinit();
        const polls = cancel.polls;
        for (1..polls + 1) |stop| {
            cancel = .{ .stop = stop };
            try std.testing.expectError(error.Cancelled, ir.materialize(.{ .attributes = folded, .cancellation = cancel.token() }));
        }
        var stream = try ir.edgeIterator(.{ .limits = .{ .max_edges = 1 } });
        defer stream.deinit();
        try expect(try stream.next() != null);
        try std.testing.expectError(error.EdgeLimit, stream.next());
        try std.testing.expectError(error.EdgeLimit, stream.next());
    }
    try std.testing.expectError(error.AttributeStateLimit, ir.materialize(.{ .limits = .{ .max_attribute_states = 0 } }));
    var cancel: Cancellation = .{};
    var stream = try ir.edgeIterator(.{ .cancellation = cancel.token() });
    defer stream.deinit();
    _ = try stream.next();
    cancel.stop = cancel.polls + 1;
    try std.testing.expectError(error.Cancelled, stream.next());
    try std.testing.expectError(error.Cancelled, stream.next());
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var parsed = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } }).parseBorrowed(allocator, "strict graph { edge[color=red]; {a b}--{c d};bad -> ;c:q--a:p[color=blue] }", dot.diagnostic.discard, .{});
    defer parsed.deinit(allocator);
    if (parsed.outcome == .storage_failure and parsed.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    const doc = &(parsed.document orelse return error.BadFixture);
    var ir = try IR.lowerPartial(allocator, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) });
    defer ir.deinit();
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    var topology = try ir.materialize(.{ .attributes = false });
    defer topology.deinit();
    var stream = try ir.edgeIterator(.{});
    defer stream.deinit();
    while (try stream.next()) |edge| {
        var attributes = try edge.attributes(.{});
        defer attributes.deinit();
        while (try attributes.next()) |_| {}
    }
}
test "partial expansion allocation failures clean scratch and output" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

test "partial bounded queries and iterators charge qualification and latch failures" {
    var result = try dot.ir.parsePartial(a, "strict digraph { a->b[color=red];bad -> ;a->b[color=blue];bad -> ; }", .{});
    defer result.deinit();
    var graph = try result.ir().?.materialize(.{});
    defer graph.deinit();
    var edges = graph.edgeIterator();
    const edge = edges.next().?;
    var full = try dot.ir.parse(a, "strict digraph { a->b[color=red];a->b[color=blue]; }", .{});
    defer full.deinit();
    var folded_full = try full.ir().?.materialize(.{});
    defer folded_full.deinit();
    var full_edges = folded_full.edgeIterator();
    const full_edge = full_edges.next().?;
    var minimum: u64 = 0;
    while (minimum < 100) : (minimum += 1) {
        _ = full_edge.attributeWith("color", .{ .limits = .{ .max_work = minimum } }) catch continue;
        break;
    }
    try expect(minimum < 100);
    try std.testing.expectError(error.WorkLimit, edge.attributeWith("color", .{ .limits = .{ .max_work = minimum } }));
    try formatted("blue", (try edge.attributeWith("color", .{ .limits = .{ .max_work = minimum + 2 } })).unknown.retained.?);
    var attributes = try edge.attributesWith(.{ .limits = .{ .max_work = 1 } });
    try std.testing.expectError(error.WorkLimit, attributes.next());
    try std.testing.expectError(error.WorkLimit, attributes.next());
    var compact = try result.ir().?.edgeIterator(.{});
    defer compact.deinit();
    var compact_attributes = try (try compact.next()).?.attributes(.{ .limits = .{ .max_work = 1 } });
    defer compact_attributes.deinit();
    try std.testing.expectError(error.WorkLimit, compact_attributes.next());
    try std.testing.expectError(error.WorkLimit, compact_attributes.next());
}
