const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const Topology = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false } });
const Full = dot.ir.Lowering(.{});
const source = "digraph {node[color=red];a->subgraph s {b;c};subgraph s{d};a[label=\"logical value\"];a:p->b:q}";

test "IR capabilities retain topology and written provenance without attribute pools" {
    var full = try Full.parse(a, source, .{});
    defer full.deinit();
    var lean = try Topology.parse(a, source, .{});
    defer lean.deinit();
    const left = full.ir().?;
    const right = lean.ir().?;
    try std.testing.expect(!Topology.capabilities.attributes);
    try std.testing.expect(!Topology.Graph.capabilities.attributes);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Topology.Connection));
    try std.testing.expectEqual(void, @FieldType(Topology.Graph, "attribute_data"));
    try std.testing.expectEqual(void, @FieldType(Topology.Graph, "attributes"));
    try std.testing.expectEqual(void, @FieldType(Topology.Graph, "declarations"));
    try std.testing.expect(right.retainedBytes() < left.retainedBytes());
    try std.testing.expectEqual(@as(u32, 0), right.capacities().attribute_states);
    try std.testing.expectEqual(left.nodes.len, right.nodes.len);
    for (left.nodes, right.nodes) |l, r| {
        try std.testing.expectEqualDeep(l.name, r.name);
        try std.testing.expectEqual(l.hash, r.hash);
        try std.testing.expectEqual(l.first_mention, r.first_mention);
    }
    inline for (.{ "scopes", "occurrences", "mentions", "endpoint_ports", "bodies", "posting_offsets", "posting_positions" }) |field|
        try std.testing.expectEqualDeep(@field(left, field), @field(right, field));
    for (left.connections, right.connections) |l, r| {
        inline for (.{ "left", "right", "written_operator", "effective_operator", "operator_source", "occurrence" }) |field|
            try std.testing.expectEqualDeep(@field(l, field), @field(r, field));
    }
    const node = (try right.findNode("a")).?;
    const target = (try right.findNode("b")).?;
    try std.testing.expect(try right.hasEdge(node, target));
    var nodes = right.nodeIterator();
    var text: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    try writer.print("{f}", .{nodes.next().?.name()});
    try std.testing.expectEqualStrings("a", writer.buffered());
}

test "IR capabilities share graph identity across execution policies" {
    const Metered = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .policy = .{ .execution = .{ .metering = true } } });
    try std.testing.expectEqual(Topology.Graph, Metered.Graph);
    var result = try Metered.parse(a, source, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.ir().?.nodes.len);
}

test "IR capabilities preserve partial-source uncertainty" {
    const input = "digraph {a->b; c [x=]; d->e";
    var result = try Topology.parsePartial(a, input, .{});
    defer result.deinit();
    var full = try Full.parsePartial(a, input, .{});
    defer full.deinit();
    const graph = result.ir().?;
    try std.testing.expectEqual(.partial, graph.state());
    try std.testing.expect(try graph.findNode("a") == .known);
    const original = full.ir().?._coverage.entries.items;
    try std.testing.expectEqual(original.len, graph._coverage.entries.items.len);
    for (original, graph._coverage.entries.items) |left, right| {
        try std.testing.expectEqualDeep(left.gap, right.gap);
        try std.testing.expectEqual(left.connection_boundary, right.connection_boundary);
    }
}

fn compareCore(left: anytype, right: anytype) !void {
    inline for (.{ "source_info", "kind", "strict", "nodes", "scopes", "occurrences", "mentions", "connections", "endpoint_ports", "bodies", "posting_offsets", "posting_positions", "node_slots" }) |field|
        try std.testing.expectEqualDeep(@field(left, field), @field(right, field));
}

const Scheduled = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
const PartialDot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
const Stop = struct {
    polls: usize = 0,
    limit: usize = std.math.maxInt(usize),
    fn requested(raw: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(raw.?));
        self.polls += 1;
        return self.polls >= self.limit;
    }
    fn hook(self: *Stop) dot.ir.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "IR capabilities preserve metering partitions cancellation and partial coverage" {
    const fixtures = [_][]const u8{
        source,
        "digraph {}",
        "strict graph {a:p--b:q; b:r--a:s [tailport=t]};",
        "digraph { subgraph s{a;subgraph n{b}};x->subgraph s{c}; subgraph s{d};x->subgraph s{} }",
        "digraph {a; c [x=]; d; x->subgraph s{b};",
    };
    for (fixtures) |input| {
        var parsed = PartialDot.parseAndValidate(a, input, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        const options = .{ .interpretation = PartialDot.interpretation(doc, .{}) };
        var direct = try Topology.lowerPartial(a, doc, options);
        defer direct.deinit();
        for ([_]u32{ 1, 7, 64, 4096 }) |budget| {
            var stop: Stop = .{};
            var session = try Scheduled.partialLoweringSession(a, doc, .{ .interpretation = options.interpretation, .cancellation = stop.hook() });
            defer session.deinit();
            try std.testing.expectEqual(@as(usize, 0), session.peakBytes());
            var total: u64 = 0;
            while (true) {
                const zero = session.advance(0);
                try std.testing.expectEqual(@as(u32, 0), zero.work_used);
                try std.testing.expectEqual(total, zero.total_work);
                const progress = session.advance(budget);
                try std.testing.expect(progress.work_used <= budget);
                total += progress.work_used;
                try std.testing.expectEqual(total, progress.total_work);
                if (progress.outcome) |outcome| {
                    try std.testing.expectEqual(dot.ir.LoweringOutcome.success, outcome);
                    break;
                }
                try std.testing.expect(progress.work_used != 0);
            }
            var result = try session.takeResult();
            defer result.deinit();
            try compareCore(direct._data, result._data);
            try std.testing.expectEqualDeep(direct._coverage.entries.items, result._coverage.entries.items);
            try std.testing.expectEqual(@as(u32, 0), session.advance(1).work_used);
        }
        var stop: Stop = .{ .limit = 5 };
        var session = try Scheduled.partialLoweringSession(a, doc, .{ .interpretation = options.interpretation, .cancellation = stop.hook() });
        defer session.deinit();
        try std.testing.expectEqual(dot.ir.LoweringOutcome{ .failure = error.Cancelled }, session.run().outcome.?);
        try std.testing.expectError(error.Cancelled, session.takeResult());
        try std.testing.expectEqual(@as(u32, 0), session.advance(64).work_used);
    }
}

test "IR capabilities convenience honors limits runtime overrides and stop delivery" {
    const Runtime = dot.ir.Lowering(.{ .capabilities = .{ .attributes = false }, .runtime_policy = true });
    const limits: dot.ir.Limits = .{ .max_attributes = 0, .max_attribute_states = 0 };
    var stop: Stop = .{ .limit = 1 };
    var result = try Runtime.parse(a, source, .{ .lowering = .{ .limits = limits, .cancellation = stop.hook(), .policy = .{ .execution = .{ .metering = true, .cancellation = false } } } });
    defer result.deinit();
    try std.testing.expect(result.ir() != null);
    try std.testing.expectEqual(@as(usize, 0), stop.polls);
    try std.testing.expectError(error.Cancelled, Runtime.parse(a, source, .{ .lowering = .{ .cancellation = stop.hook(), .policy = .{ .execution = .{ .cancellation = true } } } }));
    try std.testing.expectError(error.InvalidCancellationInterval, Runtime.parse(a, source, .{ .lowering = .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } } }));
    try std.testing.expectError(error.NodeLimit, Topology.parse(a, source, .{ .lowering = .{ .limits = .{ .max_nodes = 1 } } }));
    try std.testing.expectError(error.AttributeLimit, Full.parse(a, source, .{ .lowering = .{ .limits = limits } }));
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var invalid = try Topology.parse(a, "digraph {a -- b}", .{ .diagnostics = bag.sink() });
    defer invalid.deinit();
    try std.testing.expect(invalid.ir() == null);
    try std.testing.expect(bag.items().len != 0);
    var stopped = try Topology.parsePartial(a, "digraph {a[x=];b[y=];c[z=]}", .{ .diagnostics = bag.sink() });
    defer stopped.deinit();
    try std.testing.expect(stopped.ir() == null);
    try std.testing.expect(stopped.checking.diagnostic_stop != null);
}

test "IR capabilities convenience binds native source encodings and keeps their ranges" {
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .capabilities = .{ .attributes = false } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width = comptime dot.encoding.unitBytes(actual);
        const big = actual == .utf16be or actual == .utf32be;
        const text = "digraph {a:p->\"a\":q [label=<<B>x</B>>]}";
        var bytes: [text.len * width]u8 = @splat(0);
        for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        var result = try Native.parse(a, &bytes, .{ .dot = .{ .encoding = actual } });
        defer result.deinit();
        const graph = result.ir().?;
        try std.testing.expectEqual(actual, graph.source_info.encoding);
        try std.testing.expectEqual(@as(usize, 1), graph.nodes.len);
        try std.testing.expectEqual(@as(u32, width), graph.nodes[0].name.len);
        try std.testing.expectEqual(@as(usize, 2), graph.endpoint_ports.len);
        try std.testing.expect(graph.source.ptr == &bytes);
    }
    const Ascii = dot.ir.Lowering(.{ .source_encodings = &.{}, .capabilities = .{ .attributes = false } });
    var ascii = try Ascii.parse(a, "graph{a--b}", .{});
    defer ascii.deinit();
    try std.testing.expectEqual(.ascii, ascii.ir().?.source_info.encoding);
}

fn AllocationCheck(comptime partial: bool, comptime scheduled: bool) type {
    const Profile = if (scheduled) Scheduled else Topology;
    return struct {
        fn run(allocator: std.mem.Allocator) !void {
            // Parse failures are carried in checking; lowering failures are error unions.
            var result = if (partial) try Profile.parsePartial(allocator, source[0 .. source.len - 1], .{}) else try Profile.parse(allocator, source, .{});
            defer result.deinit();
            if (result.ir() == null and result.checking.outcome == .storage_failure and result.checking.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
        }
    };
}

test "IR capabilities free every failed allocation in complete and partial convenience paths" {
    inline for (.{ false, true }) |partial| inline for (.{ false, true }) |scheduled| {
        try std.testing.checkAllAllocationFailures(a, AllocationCheck(partial, scheduled).run, .{});
    };
}

test "IR capabilities streaming stays symbolic until explicit expansion" {
    const input = "strict digraph {a->{b c};a->b;x:p:n->y:q [tailport=ignored]}";
    var result = try Topology.parse(a, input, .{});
    defer result.deinit();
    const graph = result.ir().?;
    try std.testing.expectEqual(@as(usize, 3), graph.connections.len);
    var iterator = try graph.edgeIterator(.{});
    defer iterator.deinit();
    var count: usize = 0;
    while (try iterator.next()) |edge| {
        _ = edge.from().name();
        _ = edge.to().name();
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    var materialized = try graph.materialize(.{});
    defer materialized.deinit();
    try std.testing.expectEqual(count, materialized.edges.len);
    const last = graph.connections[2];
    try std.testing.expectEqualStrings("p", graph.text(last.left.portSyntax(graph).?.first));
    try std.testing.expectEqualStrings("n", graph.text(last.left.portSyntax(graph).?.second.?));
    try std.testing.expectEqualStrings("q", graph.text(last.right.portSyntax(graph).?.first));
}

test "IR capabilities compact sessions and large symbolic sets keep representation costs explicit" {
    const FullScheduled = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    try std.testing.expect(@sizeOf(Scheduled.LoweringSession) < @sizeOf(FullScheduled.LoweringSession));
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.writeAll("digraph { {");
    for (0..1000) |i| try text.writer.print("a{d};", .{i});
    try text.writer.writeAll("} -> {");
    for (0..1000) |i| try text.writer.print("b{d};", .{i});
    try text.writer.writeAll("} }");
    var result = try Topology.parse(a, text.written(), .{ .lowering = .{ .limits = .{ .max_edges = 1, .max_pairs = 1 } } });
    defer result.deinit();
    const graph = result.ir().?;
    try std.testing.expectEqual(@as(usize, 1), graph.connections.len);
    try std.testing.expectEqual(@as(usize, 2000), graph.nodes.len);
    try std.testing.expect(graph.retainedBytes() < 1024 * 1024);
    try std.testing.expectError(error.PairLimit, graph.materialize(.{}));
}
