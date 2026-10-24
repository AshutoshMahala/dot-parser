const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const IR = dot.ir.Lowering(.{});
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn lower(allocator: std.mem.Allocator, source: []const u8) !IR.Graph {
    var parsed = dot.parseAndValidate(allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(allocator);
    if (parsed.outcome == .storage_failure and parsed.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    if (!parsed.documentValid()) return error.BadFixture;
    return IR.lowerComplete(allocator, &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}) });
}

pub fn compare(ir: anytype) !void {
    const before = ir.retainedBytes();
    var topology = try ir.materialize(.{ .attributes = false });
    defer topology.deinit();
    var folded = try ir.materialize(.{});
    defer folded.deinit();
    try equal(topology.edges.len, folded.edges.len);
    try expect(folded.peak_bytes >= folded.retainedBytes());
    var edges = folded.edgeIterator();
    var index: usize = 0;
    while (edges.next()) |edge| : (index += 1) {
        try equal(topology.edges[index], edge.edge);
        try equal(edge.edge.from, edge.from().id);
        try equal(edge.edge.to, edge.to().id);
        const compact = try ir.edgeView(edge.edge);
        var expected = try compact.attributes(.{});
        defer expected.deinit();
        var actual = edge.attributes();
        var bounded = try edge.attributesWith(.{});
        while (try expected.next()) |attribute| {
            const got = actual.next().?;
            try equal(attribute.resolved, got.resolved);
            try equal(attribute.resolved, (try bounded.next()).?.resolved);
            var buffer: [256]u8 = undefined;
            var key = std.Io.Writer.fixed(&buffer);
            try key.print("{f}", .{attribute.key()});
            try equal(attribute.resolved, edge.attribute(key.buffered()).?.resolved);
            try equal(attribute.resolved, (try compact.attribute(key.buffered())).?.resolved);
            try equal(attribute.resolved, (try edge.attributeWith(key.buffered(), .{})).?.resolved);
            // A winner's original value view (including mixed operands) is reused.
            try equal(attribute.value().span(), got.value().span());
            try equal(attribute.value().kind(), got.value().kind());
        }
        try expect(actual.next() == null);
        try expect(try bounded.next() == null);
        try expect(edge.attribute("never_introduced") == null);
    }
    try equal(topology.edges.len, index);
    try equal(before, ir.retainedBytes());
}

test "materialize includes attributes by default and accepts runtime execution options" {
    var ir = try lower(a, "strict digraph {edge[color=red];a->b[label=old];a->b[label=new]}");
    defer ir.deinit();
    var cancel: Cancellation = .{};
    var options: dot.ir.Options = .{ .limits = .{ .max_pairs = 2 }, .cancellation = cancel.token() };
    // Taking the address prevents these limits from being compile-time values.
    _ = &options;
    var default = try ir.materialize(options);
    defer default.deinit();
    try expect(@TypeOf(default) == IR.Graph.Materialized);
    var edges = default.edgeIterator();
    const first = edges.next().?;
    try equal(.inherited, first.attribute("color").?.resolved.kind);
    try equal(@as(u32, 1), @backingInt(first.attribute("label").?.resolved.origin.connection));
    try expect(!@hasDecl(IR.Graph, "materializeWithAttributes"));

    inline for (.{ false, true }) |include_attributes| {
        var graph = try ir.materialize(.{ .attributes = include_attributes, .limits = options.limits, .cancellation = options.cancellation });
        defer graph.deinit();
        try expect(@TypeOf(graph) == if (include_attributes) IR.Graph.Materialized else dot.ir.MaterializedTopology);
        try std.testing.expectEqualSlices(dot.ir.Edge, default.edges, graph.edges);
        var denied = options.limits.?;
        denied.max_pairs = 0;
        try std.testing.expectError(error.PairLimit, ir.materialize(.{ .attributes = include_attributes, .limits = denied }));
        cancel.stop = cancel.polls + 1;
        try std.testing.expectError(error.Cancelled, ir.materialize(.{ .attributes = include_attributes, .cancellation = options.cancellation }));
        cancel.stop = std.math.maxInt(usize);
    }
    var explicit_null = try ir.materialize(.{ .limits = null, .cancellation = null });
    defer explicit_null.deinit();
    try std.testing.expectEqualSlices(dot.ir.Edge, default.edges, explicit_null.edges);
    // Excluding attributes neither builds winner cells nor discards the IR's data.
    var topology = try ir.materialize(.{ .attributes = false, .limits = .{ .max_attribute_states = 0 } });
    defer topology.deinit();
    try expect((try ir.edgeAttribute(topology.edges[0], "label")) != null);
}

test "bulk attributes match compact queries and provenance across DOT semantics" {
    const fixtures = [_][]const u8{
        "digraph {}",
        "digraph {a->b}",
        "digraph {node[color=red];a->b}",
        "digraph {edge[color=red];a->b;edge[color=blue];a->b; a->b[label=\"\"]}",
        "strict digraph {edge[color=red weight=1];{a b}->{x y}[label=first];edge[color=green weight=9];a->x[color=blue];{a}->{x}[label=last]}",
        "strict graph {edge[weight=1];{a b}--{a b}[color=red];b--a[color=blue]; a--a[label=loop]}",
        "strict digraph {edge[weight=1]; a->b; edge[color=red]; c->d; a->b[label=\"a\"+<<b>bee</b>>]; a->c[label=<>]; d->a[label=\"\"]}",
        "strict digraph {edge[weight=1];subgraph s{a}->x[color=red];edge[weight=2];subgraph s{b}->x[label=new];edge[weight=3];subgraph s{a}->x[color=blue]}",
        "strict digraph {a->b->c[label=first];a->b->c[label=last]}",
        "strict digraph {edge[weight=1]; a->{edge[weight=2];b->c[color=blue]}->d[color=red]}",
        "strict graph {a--b[tailport=p headport=q];b--a[color=blue]}",
        "digraph {edge[\"co\"+\"lor\"=red];a->b[color=blue \"\"=v café=oui label=<>]; a->c[label=\"\"]}",
        "digraph {a:p->{}; {}->b:q}",
    };
    for (fixtures) |source| {
        var ir = try lower(a, source);
        defer ir.deinit();
        try compare(&ir);
    }
}

test "bulk attribute maps balance ordered and shuffled keys and overwrite in place" {
    for ([_]u32{ 1, 31, 127 }) |stride| {
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        try source.writer.writeAll("strict digraph {edge[weight=1];{a b}->{x y};");
        for (0..128) |i| try source.writer.print("{{a b}}->{{x y}}[k{d}=v{d}];", .{ (i * stride) % 128, i });
        for (0..128) |i| try source.writer.print("a->x[k{d}=last];", .{i});
        try source.writer.writeAll("}");
        var ir = try lower(a, source.written());
        defer ir.deinit();
        try compare(&ir);
        var folded = try ir.materialize(.{ .limits = .{ .max_attribute_states = 512 } });
        defer folded.deinit();
        try std.testing.expectError(error.AttributeStateLimit, ir.materialize(.{ .limits = .{ .max_attribute_states = 511 } }));
    }
}

test "bulk generated overlapping sets agree with compact queries" {
    for (0..64) |seed| {
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        const directed = seed % 2 == 0;
        try source.writer.print("{s}{s} {{edge[base=initial];", .{ if (seed % 4 < 2) "strict " else "", if (directed) "digraph" else "graph" });
        var state: u32 = @intCast(seed + 1);
        for (0..24) |step| {
            state = state *% 1664525 +% 1013904223;
            if (step % 5 == 0) try source.writer.print("edge[base=d{d}];", .{step});
            try source.writer.print("{{n{d} n{d}}}{s}{{n{d} n{d}}}[k{d}=v{d} k{d}=last];", .{
                state % 5,        (state >> 3) % 5,  if (directed) "->" else "--", (state >> 6) % 5,
                (state >> 9) % 5, (state >> 12) % 5, step,                         (state >> 15) % 5,
            });
        }
        try source.writer.writeAll("}");
        var ir = try lower(a, source.written());
        defer ir.deinit();
        try compare(&ir);
    }
}

test "bulk generic graphs preserve distinct directed and undirected occurrences" {
    const P = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
    var parsed = P.parseAndValidate(a, "graph {edge[color=red];a->b[color=blue];a--b; b->a[label=reverse]}", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    var ir = try IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
    defer ir.deinit();
    try compare(&ir);
}

test "bulk limits cover state updates pair visits output and growth without changing the IR" {
    var ir = try lower(a, "strict digraph {a->b[x=1];a->b[x=2];a->b[x=3]}");
    defer ir.deinit();
    // Three contributions, one edge, one winning explicit key.
    var folded = try ir.materialize(.{ .limits = .{ .max_attribute_states = 1, .max_edges = 1, .max_pairs = 3 } });
    defer folded.deinit();
    var edges = folded.edgeIterator();
    const edge = edges.next().?;
    try equal(@as(u32, 2), @backingInt(edge.attribute("x").?.resolved.origin.connection));
    try std.testing.expectError(error.PairLimit, ir.materialize(.{ .limits = .{ .max_pairs = 2 } }));
    try std.testing.expectError(error.EdgeLimit, ir.materialize(.{ .limits = .{ .max_edges = 0 } }));
    try std.testing.expectError(error.AttributeStateLimit, ir.materialize(.{ .limits = .{ .max_attribute_states = 0 } }));
    try std.testing.expectError(error.WorkLimit, ir.materialize(.{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.MemoryLimit, ir.materialize(.{ .limits = .{ .max_bytes = 0 } }));
    try std.testing.expectError(error.MemoryLimit, ir.materialize(.{ .limits = .{ .max_bytes = folded.peak_bytes - 1 } }));
    try std.testing.expectError(error.WorkLimit, edge.attributeWith("x", .{ .limits = .{ .max_work = 0 } }));
    try expect(edge.attribute("x") != null);
    var attributes = try edge.attributesWith(.{ .limits = .{ .max_work = 1 } });
    try std.testing.expectError(error.WorkLimit, attributes.next());
    try std.testing.expectError(error.WorkLimit, attributes.next());
    try compare(&ir);

    var empty = try lower(a, "digraph {edge[x=1]}");
    defer empty.deinit();
    var no_edges = try empty.materialize(.{ .limits = .{ .max_bytes = 0 } });
    defer no_edges.deinit();
    try equal(@as(usize, 0), no_edges.retainedBytes());

    var defaults = try lower(a, "digraph {edge[color=red];a->b;a->c}");
    defer defaults.deinit();
    var shared = try defaults.materialize(.{ .limits = .{ .max_attribute_states = 0 } });
    defer shared.deinit();
    var default_edges = shared.edgeIterator();
    try equal(.inherited, default_edges.next().?.attribute("color").?.resolved.kind);
}

test "bulk endpoints with ports agree with compact queries including a later strict update" {
    for ([_][]const u8{
        "digraph {a:p->b}",
        "strict graph {a--b[color=red];b:q--a}",
        "digraph {a->b; c->d:p[headport=override]}",
    }) |source| {
        var ir = try lower(a, source);
        defer ir.deinit();
        try compare(&ir);
        var topology = try ir.materialize(.{ .attributes = false });
        defer topology.deinit();
        try expect(topology.edges.len != 0);
    }
}

const Cancellation = struct {
    polls: usize = 0,
    stop: usize = std.math.maxInt(usize),
    fn requested(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.polls >= self.stop;
    }
    fn token(self: *@This()) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "bulk cancellation at each work boundary cleans all output and leaves IR reusable" {
    var ir = try lower(a, "strict digraph {edge[base=1];{a b}->{x y}[p=1 q=2 r=3];a:port:n->x:other[p=2];{a b}->{x y}[z=4]}");
    defer ir.deinit();
    var cancel: Cancellation = .{};
    var result = try ir.materialize(.{ .cancellation = cancel.token() });
    defer result.deinit();
    const polls = cancel.polls;
    for (1..polls + 1) |stop| {
        cancel = .{ .stop = stop };
        try std.testing.expectError(error.Cancelled, ir.materialize(.{ .cancellation = cancel.token() }));
    }
    try compare(&ir);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var ir = try lower(allocator, "strict digraph {edge[base=1];{a b}->{x y}[p=1 q=2 r=3];a:port:n->x:other[p=2 z=4]}");
    defer ir.deinit();
    var folded = try ir.materialize(.{});
    defer folded.deinit();
    try expect(folded.edges.len == 4);
}
test "bulk materialization releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

test "bulk returned attribute views borrow only the IR" {
    var ir = try lower(a, "strict digraph {edge[color=red];a->b[label=\"a\"+<<b>bee</b>>];a->b[color=blue]}");
    defer ir.deinit();
    const label = blk: {
        var folded = try ir.materialize(.{});
        defer folded.deinit();
        var edges = folded.edgeIterator();
        break :blk edges.next().?.attribute("label").?;
    };
    try equal(.concatenation, label.value().kind());
    const joined = try label.value().toString(a);
    defer a.free(joined);
    try std.testing.expectEqualStrings("a<b>bee</b>", joined);
}

test "bulk native values retain source encoding and original provenance" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const source = "strict digraph {edge[café=初];a:\"埠😀\":n->b[label=\"a😀\"+<<b>中文&amp;</b>>];a->b:<終>[café=次 \"😀\"=oui]}";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var encoded: std.Io.Writer.Allocating = .init(a);
        defer encoded.deinit();
        var characters = (try std.unicode.Utf8View.init(source)).iterator();
        while (characters.nextCodepoint()) |cp| {
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
        try compare(&ir);
    }
}
