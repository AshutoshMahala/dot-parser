const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;
const IR = dot.ir.Lowering(.{});

fn formatted(expected: []const u8, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{value});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

// Compare enumeration to independent per-key lookup, including uncertainty and
// provenance. Complete replay also verifies catalog ordering and empties.
fn check(view: anytype, complete: anytype) !u32 {
    var values = try view.attributes(.{});
    defer values.deinit();
    var expected = if (@TypeOf(complete) != @TypeOf(null)) try complete.attributes(.{}) else {};
    defer if (@TypeOf(complete) != @TypeOf(null)) expected.deinit();
    var count: u32 = 0;
    while (try values.next()) |answer| {
        const value = switch (answer) {
            .known => |v| v,
            .unknown => |u| u.retained.?,
        };
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.print("{f}", .{value.key()});
        const lookup = view.attribute(writer.buffered());
        try equal(lookup == .known, answer == .known);
        switch (answer) {
            .known => |v| try equal(lookup.known.?.resolved, v.resolved),
            .unknown => |u| {
                try equal(lookup.unknown.uncertainty, u.uncertainty);
                try equal(lookup.unknown.retained.?.resolved, u.retained.?.resolved);
            },
        }
        if (@TypeOf(complete) != @TypeOf(null)) {
            const other = (try expected.next()).?;
            // Partial lowering copies attributes in semantic order; complete
            // lowering keeps pool order. Local pool IDs need not be equal.
            try equal(other.graph.attributes[other.resolved.attribute.?], value.graph.attributes[value.resolved.attribute.?]);
            var resolved = other.resolved;
            resolved.attribute = value.resolved.attribute;
            try equal(resolved, value.resolved);
            try formatted(writer.buffered(), other.key());
        }
        count += 1;
    }
    try expect(try values.next() == null);
    try std.testing.expectEqual(@as(usize, 0), values.peakBytes());
    if (@TypeOf(complete) != @TypeOf(null)) try expect(try expected.next() == null);
    return count;
}

fn checkAll(graph: anytype) !void {
    var nodes = graph.nodeIterator();
    while (nodes.next()) |node| _ = try check(node, null);
    var scopes = graph.scopeIterator();
    while (scopes.next()) |scope| _ = try check(scope, null);
}

test "partial node and scope attribute enumeration matches complete values order and origins" {
    for ([_][]const u8{
        "digraph {}",
        "digraph { a; subgraph s{b} }",
        "digraph { graph[g=one]; node[color=red]; a; subgraph s{rank=same;a[label=\"a\"+<<b>bee</b>>];b}; graph[g=two]; subgraph s{rank=min;c[label=\"\"]}; d[\"color\"+\"\"=blue]; a->b[edge_only=x] }",
        "digraph {graph[x=one y=two];subgraph s{};x=three;subgraph s{y=four};subgraph t{graph[z=\"\"];node[n=one];a};b}",
        "strict graph {a:p--b:q[tailport=z];node[x=1 x=2];a[x=3];graph[g=1 g=2];{g=3}}",
        "digraph { graph[état=\"prêt\"]; node[clé=\"café\"]; 中文; 中文[\"cl\"+\"é\"=\"thé\"]; subgraph s{état=\"終\"} }",
    }) |source| {
        var full = try dot.ir.parse(a, source, .{});
        defer full.deinit();
        var partial = try dot.ir.parsePartial(a, source, .{});
        defer partial.deinit();
        const graph = partial.ir().?;
        var nodes = graph.nodeIterator();
        while (nodes.next()) |node| _ = try check(node, try full.ir().?.nodeView(node.id));
        var scopes = graph.scopeIterator();
        while (scopes.next()) |scope| _ = try check(scope, try full.ir().?.scopeView(scope.id));
    }
}

test "partial attribute iteration preserves candidates post-gap facts and implicit empty values" {
    const source = "digraph {graph[color=red];node[shape=box];subgraph s{rank=same;a[color=red]};bad -> ;graph[label=\"\"];subgraph s{rank=min;b[color=blue label=\"a\"+<<b>bee</b>>]}}";
    var result = try dot.ir.parsePartial(a, source, .{});
    defer result.deinit();
    const graph = result.ir().?;
    try checkAll(graph);
    const na = try graph.nodeView((try graph.findNode("a")).known.?);
    const nb = try graph.nodeView((try graph.findNode("b")).known.?);
    try expect(na.attribute("color") == .unknown);
    try equal(.empty, na.attribute("label").unknown.retained.?.resolved.kind);
    try formatted("blue", nb.attribute("color").known.?);
    try expect(nb.attribute("shape") == .unknown);
    try formatted("a<b>bee</b>", nb.attribute("label").known.?);
    const root = try graph.scopeView(.root);
    try expect(root.attribute("color") == .unknown);
    try formatted("", root.attribute("label").known.?);
    var scopes = graph.scopeIterator();
    _ = scopes.next().?;
    try formatted("min", scopes.next().?.attribute("rank").known.?);
    // Empty retained catalogs are not proof of absence in missing source.
    var no_keys = try dot.ir.parsePartial(a, "digraph {a;bad -> ;}", .{});
    defer no_keys.deinit();
    try checkAll(no_keys.ir().?);
    const empty = try no_keys.ir().?.nodeView((try no_keys.ir().?.findNode("a")).known.?);
    try equal(@as(u32, 0), try check(empty, null));
    try expect(empty.attribute("unseen") == .unknown);
}

test "partial attribute enumeration retains unfinished child scopes without inspecting broken tokens" {
    for ([_][]const u8{
        "digraph {g=red;node[x=1];a;subgraph s{g=blue;b[y=2]",
        "digraph { a->{g=red;b[x=1];}->; c[y=2]; }",
        "digraph { a[x=1]; unfinished[label=\"fake=key",
        "digraph { g=red; a[x=1]; /* fake=key",
        "digraph { g=red; a[x=1]; unfinished[label=<fake=key",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        try checkAll(result.ir().?);
        try equal(.partial, result.ir().?.state());
    }
}

test "partial attribute iteration allocates nothing and views outlive iterator cleanup" {
    var memory = std.testing.FailingAllocator.init(a, .{});
    var result = try dot.ir.parsePartial(memory.allocator(), "digraph {g=1;node[x=1];a;bad -> ;subgraph s{g=2;a[y=2];b}}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const allocations = memory.allocations;
    const retained = graph.retainedBytes();
    memory.fail_index = allocations;
    var saved: IR.PartialGraph.AttributeView = undefined;
    inline for (.{ "nodeIterator", "scopeIterator" }) |method| {
        var components = @field(@TypeOf(graph.*), method)(graph);
        while (components.next()) |component| {
            var values = try component.attributes(.{ .limits = .{ .max_bytes = 0 } });
            defer values.deinit();
            while (try values.next()) |answer| saved = switch (answer) {
                .known => |v| v,
                .unknown => |u| u.retained.?,
            };
            try equal(@as(usize, 0), values.peakBytes());
        }
    }
    try equal(allocations, memory.allocations);
    try equal(retained, graph.retainedBytes());
    try equal(retained, memory.allocated_bytes - memory.freed_bytes);
    try expect(saved.value().raw().?.len != 0);
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
        return .{ .context = self, .is_requested = @This().check };
    }
};

test "partial node and scope iteration shares lifetime work and latches every cancellation" {
    var result = try dot.ir.parsePartial(a, "digraph {node[x=1 y=2];g=1;bad -> ;a[x=3 y=4];h=2}", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const node = try graph.nodeView((try graph.findNode("a")).known.?);
    const scope = try graph.scopeView(.root);
    inline for (.{ node, scope }) |view| {
        var minimum: u64 = 0;
        while (minimum < 100) : (minimum += 1) {
            var values = try view.attributes(.{ .limits = .{ .max_work = minimum } });
            defer values.deinit();
            var failed = false;
            while (true) {
                const value = values.next() catch |err| {
                    try equal(error.WorkLimit, err);
                    try std.testing.expectError(error.WorkLimit, values.next());
                    failed = true;
                    break;
                };
                if (value == null) break;
            }
            if (!failed) break;
        }
        try expect(minimum > 0 and minimum < 100);
        var cancel: Cancellation = .{};
        {
            var values = try view.attributes(.{ .cancellation = cancel.token() });
            defer values.deinit();
            while (try values.next()) |_| {}
        }
        const polls = cancel.polls;
        for (1..polls + 1) |stop| {
            cancel = .{ .stop = stop };
            if (view.attributes(.{ .cancellation = cancel.token() })) |started| {
                var values = started;
                defer values.deinit();
                while (true) {
                    const value = values.next() catch |err| {
                        try equal(error.Cancelled, err);
                        cancel.stop = std.math.maxInt(usize);
                        try std.testing.expectError(error.Cancelled, values.next());
                        break;
                    };
                    try expect(value != null);
                }
            } else |err| try equal(error.Cancelled, err);
        }
    }
    const bad_node: IR.PartialGraph.NodeView = .{ .graph = graph, .id = @fromBackingInt(999) };
    const bad_scope: IR.PartialGraph.ScopeView = .{ .graph = graph, .id = @fromBackingInt(999) };
    try std.testing.expectError(error.InvalidHandle, bad_node.attributes(.{}));
    try std.testing.expectError(error.InvalidHandle, bad_scope.attributes(.{}));
}

test "partial native attribute iteration preserves key value and provenance encoding" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .retention = .{ .partial = true } } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const text = "digraph {g=red;a[x=one];bad -> ;g=blue;subgraph s{a[x=\"t\"+\"wo\"];h=<>}}";
        const width = comptime dot.encoding.unitBytes(actual);
        const big = actual == .utf16be or actual == .utf32be;
        var bytes: [text.len * width]u8 = @splat(0);
        for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        var parsed = try P.parseAndValidate(a, &bytes, dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        var graph = try Native.lowerPartial(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer graph.deinit();
        try checkAll(&graph);
        var nodes = graph.nodeIterator();
        var values = try nodes.next().?.attributes(.{});
        defer values.deinit();
        const value = (try values.next()).?.known;
        try formatted("x", value.key());
        try formatted("two", value);
        try equal(@as(u32, 0), value.value().span().?.start % width);
    }
}

fn minimumWork(view: anytype) !u64 {
    next_budget: for (0..100) |budget| {
        var values = try view.attributes(.{ .limits = .{ .max_work = budget } });
        defer values.deinit();
        while (true) {
            const value = values.next() catch |err| {
                try equal(error.WorkLimit, err);
                continue :next_budget;
            };
            if (value == null) return budget;
        }
    }
    return error.NoSufficientBudget;
}

test "partial iterator qualification is charged to the same allowance as lookup" {
    var full = try dot.ir.parse(a, "digraph {a[x=1 y=2];g=1;h=2}", .{});
    defer full.deinit();
    var partial = try dot.ir.parsePartial(a, "digraph {bad -> ;a[x=1 y=2];g=1;h=2}", .{});
    defer partial.deinit();
    const id = (try full.ir().?.findNode("a")).?;
    const node = try partial.ir().?.nodeView((try partial.ir().?.findNode("a")).known.?);
    const scope = try partial.ir().?.scopeView(.root);
    // Two explicit winners, one gap-index probe each. No reset per entry.
    try equal(try minimumWork(try full.ir().?.nodeView(id)) + 2, try minimumWork(node));
    try equal(try minimumWork(try full.ir().?.scopeView(.root)) + 2, try minimumWork(scope));
}
