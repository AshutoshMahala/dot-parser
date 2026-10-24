const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const IR = dot.ir.Lowering(.{});
const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });

fn formatted(expected: []const u8, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.print("{f}", .{value});
    try std.testing.expectEqualStrings(expected, out.buffered());
}
fn node(graph: *const IR.PartialGraph, name: []const u8) !IR.PartialGraph.NodeView {
    return graph.nodeView((try graph.findNode(name)).known.?);
}

test "partial IR complete inputs agree with complete IR and preserve known absence" {
    inline for (.{ "digraph {}", "digraph { a -> {b c}; \"a\" [label=\"a\" + \"b\"]; subgraph s { color=red; d } }", "strict graph { a:p--b:q [color=red]; b:r--a:s }" }) |source| {
        var complete = try dot.ir.parse(a, source, .{});
        defer complete.deinit();
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        const graph = result.ir().?;
        const full = complete.ir().?;
        try equal(.complete, graph.state());
        try equal(full.kind, graph.kind().known);
        try equal(full.nodes.len, graph.nodeCount());
        try equal(full.scopes.len, graph.scopeCount());
        try equal(full.connections.len, graph.connectionCount());
        try expect((try graph.findNode("missing")).known == null);
        try expect(graph.gaps().entries.len == 0);
        var nodes = graph.nodeIterator();
        while (nodes.next()) |n| {
            const other = try full.nodeView(n.id);
            try expect(n.attribute("missing").known == null);
            if (other.attribute("label")) |attr| try equal(attr.resolved.kind, n.attribute("label").known.?.resolved.kind);
            var mentions = n.mentions();
            var count: usize = 0;
            while (mentions.next()) |mention| {
                try equal(n.id, mention.node);
                count += 1;
            }
            try expect(count != 0);
            var destinations = graph.nodeIterator();
            while (destinations.next()) |to| try equal(try full.hasEdge(n.id, to.id), (try graph.hasEdge(n.id, to.id)).known);
        }
        var scopes = graph.scopeIterator();
        while (scopes.next()) |s| {
            const members = try s.membership();
            var ns = graph.nodeIterator();
            while (ns.next()) |n| try equal(try full.contains(try full.scopeMembership(s.id), n.id), (try graph.contains(members, n.id)).known);
        }
    }
}

test "partial IR candidates and explicit post-gap values remain distinct" {
    const source = "digraph { node [shape=box]; a [color=red]; broken -> ; b [color=blue]; a -> b; }";
    var result = try dot.ir.parsePartial(a, source, .{});
    defer result.deinit();
    try expect(result.checking.outcome == .invalid_syntax);
    const graph = result.ir().?;
    try equal(.partial, graph.state());
    const na = try node(graph, "a");
    const nb = try node(graph, "b");
    try formatted("red", na.attribute("color").unknown.retained.?);
    try formatted("blue", nb.attribute("color").known.?);
    try formatted("box", nb.attribute("shape").unknown.retained.?);
    try expect(nb.attribute("missing").unknown.retained == null);
    try expect((try graph.findNode("broken")) == .unknown);
    try expect((try graph.hasEdge(na.id, nb.id)).known);
    try expect((try graph.hasEdge(nb.id, na.id)) == .unknown);
    var gaps = graph.gaps();
    const gap = gaps.next().?;
    try equal(.skipped_input, gap.reason);
    try equal(dot.ir.OccurrenceId.root, gap.occurrence.?);
    try expect(gaps.next() == null);
}

test "partial IR unclosed root has EOF coverage even with all bytes retained" {
    var exact = P.parseAndValidate(a, "digraph { color=red", dot.diagnostic.discard, .{});
    defer exact.deinit(a);
    try expect(exact.document.?.unrepresented() == null);
    try expect(!exact.document.?.root_closed);
    var exact_graph = try IR.lowerPartial(a, &exact.document.?, .{ .interpretation = P.interpretation(&exact.document.?, .{}) });
    defer exact_graph.deinit();
    var exact_gaps = exact_graph.gaps();
    try equal(@as(u32, 0), exact_gaps.next().?.range.len);
    try formatted("red", (try exact_graph.scopeView(.root)).attribute("color").unknown.retained.?);
    inline for (.{ "digraph { a [color=red];", "digraph { subgraph s { a [color=red]; }", "digraph { a; bad -> ;" }) |source| {
        var parsed = P.parseAndValidate(a, source, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        try expect(!parsed.document.?.root_closed);
        var graph = try IR.lowerPartial(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer graph.deinit();
        try equal(.partial, graph.state());
        const n = try node(&graph, "a");
        try expect(n.attribute("color") == .unknown);
        var gaps = graph.gaps();
        var eof = false;
        while (gaps.next()) |gap| {
            if (gap.reason == .unfinished_input) eof = true;
        }
        try expect(eof);
    }
}

test "partial IR retains child scopes of abandoned edges exactly once" {
    inline for (.{
        "digraph { a -> { b; subgraph s { c [color=red] } } -> ; d [color=blue] }",
        "digraph { a -> { b; subgraph s { c [color=red] } } ->",
        "digraph { subgraph s { a [color=red]; subgraph t { b;",
        "digraph { a -> {} -> ; b; }",
    }) |source| {
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        const graph = result.ir().?;
        try equal(.partial, graph.state());
        try equal(@as(u32, 0), graph.connectionCount());
        var nodes = graph.nodeIterator();
        while (nodes.next()) |n| {
            var mentions = n.mentions();
            try expect(mentions.next() != null);
            try expect(mentions.next() == null);
        }
        _ = try node(graph, "b");
    }
}

test "partial IR mentions preserve quoted identity and semantic order" {
    const source = "digraph { a; subgraph s { \"a\"; bad -> ; } \"a\" + \"\" -> a; }";
    var result = try dot.ir.parsePartial(a, source, .{});
    defer result.deinit();
    const graph = result.ir().?;
    const n = try node(graph, "a");
    var mentions = n.mentions();
    for ([_][]const u8{ "a", "\"a\"", "\"a\" + \"\"", "a" }, 0..) |spelling, i| {
        const mention = mentions.next().?;
        try std.testing.expectEqualStrings(spelling, source[mention.source.start..][0..mention.source.len]);
        try equal(@as(u32, if (i == 1) 1 else 0), @backingInt(mention.occurrence));
    }
    try expect(mentions.next() == null);
}

test "partial IR capped omission permits lowering while requested stops do not" {
    const source = "digraph { a; bad -> ; b; bad -> ; c; bad -> ; d; }";
    var omit: dot.reporting.FixedBag(dot.Diagnostic, 1, .omit) = .{};
    var result = try dot.ir.parsePartial(a, source, .{ .diagnostics = omit.sink() });
    defer result.deinit();
    try expect(omit.omitted != 0);
    _ = try node(result.ir().?, "d");
    var stop: dot.FixedDiagnosticBag(1) = .{};
    var stopped = try dot.ir.parsePartial(a, source, .{ .diagnostics = stop.sink() });
    defer stopped.deinit();
    try expect(stopped.ir() == null);
    try expect(stopped.checking.diagnostic_stop != null);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const source = "digraph { node [color=red]; a -> { b; c; } -> ; subgraph s { b [color=blue] } a -> b; d; }";
    // Preparse outside the tested allocator: lowering failures must be errors,
    // not valid partial coverage. The convenience parser reports its own stops.
    var parsed = P.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    var graph = try IR.lowerPartial(allocator, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
    defer graph.deinit();
    _ = try node(&graph, "b");
}
test "partial IR lowering is allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{});
}

test "partial IR unresolved auto is not a guessed undigraph and strict ambiguity is rejected" {
    const Auto = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .validation = .{ .graph = .{ .treated_as = .auto } } } });
    inline for (.{ "graph { a -- b; bad -> ; c; }", "graph { a -> b; bad -> ; c; }", "strict graph { a -- b; bad -> ; c; }" }) |source| {
        var parsed = Auto.parseAndValidate(a, source, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        const options = .{ .interpretation = Auto.interpretation(doc, .{}) };
        if (doc.strict) {
            try std.testing.expectError(error.UnsupportedSemantics, IR.lowerPartial(a, doc, options));
        } else {
            var graph = try IR.lowerPartial(a, doc, options);
            defer graph.deinit();
            if (std.mem.indexOf(u8, source, "a ->") != null) try equal(.generic, graph.kind().known) else try expect(graph.kind() == .unknown);
            const na = try node(&graph, "a");
            const nb = try node(&graph, "b");
            try expect((try graph.hasEdge(na.id, nb.id)).known);
        }
    }
}

test "partial IR native encodings preserve ranges candidates and root closure" {
    const NativeDot = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .retention = .{ .partial = true } } });
    const NativeIR = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width: usize = comptime dot.encoding.unitBytes(actual);
        const big = actual == .utf16be or actual == .utf32be;
        const text = "digraph { a[color=red]; bad -> ; \"a\"+\"\"[color=blue]; }";
        var bytes: [text.len * width]u8 = @splat(0);
        for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        var parsed = try NativeDot.parseAndValidate(a, &bytes, dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        const doc = &parsed.document.?;
        try expect(doc.root_closed);
        var graph = try NativeIR.lowerPartial(a, doc, .{ .interpretation = NativeDot.interpretation(doc, .{}) });
        defer graph.deinit();
        const n = try graph.nodeView((try graph.findNode("a")).known.?);
        try formatted("blue", n.attribute("color").known.?);
        try formatted("a", n.name());
        var mentions = n.mentions();
        try equal(@as(u32, @intCast(width)), mentions.next().?.source.len);
        try equal(@as(u32, @intCast(6 * width)), mentions.next().?.source.len);
        try expect(mentions.next() == null);
        var gaps = graph.gaps();
        const gap = gaps.next().?;
        try equal(@as(u32, 0), gap.range.start % width);
        try equal(@as(u32, 0), gap.range.len % width);
        try expect(gaps.next() == null);
        try std.testing.expectError(error.UnsupportedEncoding, IR.lowerPartial(a, doc, .{ .interpretation = NativeDot.interpretation(doc, .{}) }));
    }
}

test "partial IR early termination never starts automatic lowering" {
    const Stop = struct {
        fn check(_: ?*anyopaque) bool {
            return true;
        }
    };
    var context: u8 = 0;
    const cancellation: dot.ir.Cancellation = .{ .context = &context, .is_requested = Stop.check };
    try std.testing.expectError(error.Cancelled, dot.ir.parsePartial(a, "digraph { a }", .{ .lowering = .{ .cancellation = cancellation } }));
    const Failing = struct {
        fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.diagnostic.SinkError!dot.diagnostic.Action {
            return error.DiagnosticSinkFailure;
        }
    };
    var failed = try dot.ir.parsePartial(a, "digraph { bad -> ; a }", .{ .diagnostics = .{ .context = &context, .emit_fn = Failing.emit } });
    defer failed.deinit();
    try expect(failed.ir() == null);
    try equal(.failed, failed.checking.diagnostic_delivery);
    var empty = try dot.ir.parsePartial(a, "not_a_graph", .{});
    defer empty.deinit();
    try expect(empty.ir() == null);
}

test "partial IR lower/query limits cancellation and handle errors are not uncertainty" {
    var parsed = P.parseAndValidate(a, "digraph { a[color=red]; bad -> ; b; a -> b }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    inline for (.{
        .{ dot.ir.Limits{ .max_work = 0 }, error.WorkLimit },
        .{ dot.ir.Limits{ .max_nodes = 0 }, error.NodeLimit },
        .{ dot.ir.Limits{ .max_mentions = 0 }, error.MentionLimit },
        .{ dot.ir.Limits{ .max_scopes = 0 }, error.ScopeLimit },
        .{ dot.ir.Limits{ .max_connections = 0 }, error.ConnectionLimit },
        .{ dot.ir.Limits{ .max_attributes = 0 }, error.AttributeLimit },
        .{ dot.ir.Limits{ .max_bytes = 0 }, error.MemoryLimit },
    }) |case| try std.testing.expectError(case[1], IR.lowerPartial(a, doc, .{ .interpretation = P.interpretation(doc, .{}), .limits = case[0] }));
    var graph = try IR.lowerPartial(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
    defer graph.deinit();
    const n = try node(&graph, "a");
    try std.testing.expectError(error.WorkLimit, n.attributeWith("color", .{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.WorkLimit, graph.findNodeWith("missing", .{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.WorkLimit, graph.hasEdgeWith(n.id, n.id, .{ .limits = .{ .max_work = 0 } }));
    const bad: dot.ir.NodeId = @fromBackingInt(std.math.maxInt(u32));
    try std.testing.expectError(error.InvalidHandle, graph.nodeView(bad));
    try std.testing.expectError(error.InvalidHandle, graph.hasEdge(n.id, bad));
    try std.testing.expectError(error.InvalidHandle, graph.contains(@fromBackingInt(0), bad));
}

test "partial IR lexical tails never manufacture nodes or values" {
    inline for (.{ "digraph { a; \"fake -> b", "digraph { a; /* fake -> b", "digraph { a; <fake b", "digraph { a; b[x=\"unterminated" }) |source| {
        errdefer std.debug.print("lexical fixture: {s}\n", .{source});
        var result = try dot.ir.parsePartial(a, source, .{});
        defer result.deinit();
        const graph = result.ir().?;
        try equal(@as(u32, 1), graph.nodeCount());
        try equal(@as(u32, 0), graph.connectionCount());
        try expect((try graph.findNode("b")) == .unknown);
        try expect((try node(graph, "a")).attribute("x").unknown.retained == null);
    }
}

test "partial IR implicit empty is a candidate not absence" {
    var result = try dot.ir.parsePartial(a, "digraph { a [color=red]; b; bad -> ; }", .{});
    defer result.deinit();
    const n = try node(result.ir().?, "b");
    const color = n.attribute("color").unknown.retained.?;
    try equal(.empty, color.resolved.kind);
    try formatted("", color);
    try expect(n.attribute("absent").unknown.retained == null);
}

test "partial IR retained memory includes coverage storage but no query allocations" {
    var memory = std.testing.FailingAllocator.init(a, .{});
    var result = try dot.ir.parsePartial(memory.allocator(), "digraph { a[color=red]; bad -> ; b[color=blue] }", .{});
    defer result.deinit();
    const graph = result.ir().?;
    try equal(graph.retainedBytes(), memory.allocated_bytes - memory.freed_bytes);
    const allocations = memory.allocations;
    for (0..100) |_| {
        const n = try node(graph, "a");
        _ = n.attribute("color").unknown.retained.?;
        _ = try n.attributeWith("color", .{});
        var mentions = n.mentions();
        while (mentions.next()) |_| {}
        _ = try graph.hasEdge(n.id, n.id);
    }
    try equal(allocations, memory.allocations);
}

test "partial IR known answers survive compatible fillings and candidates match independent replay" {
    // Tiny independent interpreter for one node/key: first creation captures
    // the current default; only explicit updates subsequently replace it.
    const Replay = struct {
        current_default: ?[]const u8 = null,
        created: bool = false,
        value: ?[]const u8 = null,
        fn apply(self: *@This(), operation: u8) void {
            switch (operation) {
                0 => self.current_default = "red",
                1 => {
                    if (!self.created) self.value = self.current_default;
                    self.created = true;
                },
                2 => {
                    self.value = "blue";
                    self.created = true;
                },
                3 => self.current_default = "green",
                else => unreachable,
            }
        }
    };
    const commands = [_][]const u8{ "node[color=red];", "a;", "a[color=blue];", "node[color=green];" };
    const fillings = [_][]const u8{ "", "a[color=orange]; a->z;", "node[color=purple]; z->a;", "subgraph s { a[color=yellow]; }" };
    for (0..4) |x| for (0..4) |y| for (0..4) |z| {
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        try source.writer.print("digraph {{ {s} {s} bad -> ; {s} a; b; a->b }}", .{ commands[x], commands[y], commands[z] });
        var result = try dot.ir.parsePartial(a, source.written(), .{});
        defer result.deinit();
        const graph = result.ir().?;
        const n = try node(graph, "a");
        const answer = n.attribute("color");
        const candidate = switch (answer) {
            .known => |v| v,
            .unknown => |u| u.retained,
        };
        var replay: Replay = .{};
        replay.apply(@intCast(x));
        replay.apply(@intCast(y));
        replay.apply(@intCast(z));
        replay.apply(1);
        // A default introduces the key even if this node predates the default.
        const catalog_has_color = x != 1 or y != 1 or z != 1;
        if (replay.value) |value| try formatted(value, candidate.?) else if (catalog_has_color) {
            try equal(.empty, candidate.?.resolved.kind);
            try formatted("", candidate.?);
        } else try expect(candidate == null);

        for (fillings) |filling| {
            var full_source: std.Io.Writer.Allocating = .init(a);
            defer full_source.deinit();
            try full_source.writer.print("digraph {{ {s} {s} {s} {s} a; b; a->b }}", .{ commands[x], commands[y], filling, commands[z] });
            var full = try dot.ir.parse(a, full_source.written(), .{});
            defer full.deinit();
            const complete = full.ir().?;
            const other = try complete.nodeView((try complete.findNode("a")).?);
            if (answer == .known) {
                var buf: [64]u8 = undefined;
                var out = std.Io.Writer.fixed(&buf);
                try out.print("{?f}", .{other.attribute("color")});
                try formatted(out.buffered(), answer.known.?);
            }
            // Positive topology and identity witnesses cannot disappear.
            try expect((try graph.hasEdge(n.id, (try graph.findNode("b")).known.?)).known);
            try expect(try complete.hasEdge(other.id, (try complete.findNode("b")).?));
            try expect((try graph.findNode("z")) == .unknown);
        }
    };
}

test "partial IR deep and reopened scopes remain iterative and symbolic" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    for (0..2000) |_| try source.writer.writeByte('{');
    try source.writer.writeAll("a[color=red]; bad -> ;");
    for (0..2000) |_| try source.writer.writeByte('}');
    try source.writer.writeAll("subgraph s{ b } subgraph s{ c } -> a; a[color=blue] }");
    var result = try dot.ir.parsePartial(a, source.written(), .{});
    defer result.deinit();
    const graph = result.ir().?;
    try equal(@as(u32, 2002), graph.scopeCount());
    try equal(@as(u32, 1), graph.connectionCount());
    const na = try node(graph, "a");
    try formatted("blue", na.attribute("color").known.?);
    try expect((try graph.hasEdge((try node(graph, "b")).id, na.id)).known);
    try expect((try graph.hasEdge((try node(graph, "c")).id, na.id)).known);
}

test "partial IR stopped Document can be lowered only by an explicit new operation" {
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var parsed = P.parseAndValidate(a, "digraph { a; bad -> ; b }", bag.sink(), .{});
    defer parsed.deinit(a);
    try expect(parsed.diagnostic_stop != null);
    const doc = &parsed.document.?;
    var graph = try IR.lowerPartial(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
    defer graph.deinit();
    _ = try node(&graph, "a");
    try expect((try graph.findNode("b")) == .unknown);
}

test "partial IR coverage does not turn validation rejection into acceptance" {
    var result = try dot.ir.parsePartial(a, "digraph { a -- b }", .{});
    defer result.deinit();
    try expect(!result.checking.validation.?.documentValid());
    const graph = result.ir().?;
    try equal(.complete, graph.state());
    try expect((try graph.hasEdge((try node(graph, "a")).id, (try node(graph, "b")).id)).known);
    try expect((try graph.hasEdge((try node(graph, "b")).id, (try node(graph, "a")).id)).known);
}

test "partial IR complete DOT topology is independent of rejected inner markup" {
    const markup = @import("markup_parser");
    const Composed = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    var checked = try Composed.parseAndValidate(a, "digraph { a[label=<<unknown/>>]; a -> b }", .discard, .{});
    defer checked.deinit(a);
    try expect(!checked.documentValid());
    // Use the outer report/Document explicitly: inner rejection is not missing
    // DOT syntax or a reason to invent a gap in DOT semantic coverage.
    const doc = &checked.dot.document.?;
    var graph = try IR.lowerPartial(a, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) });
    defer graph.deinit();
    try equal(.complete, graph.state());
    try expect((try graph.hasEdge((try node(&graph, "a")).id, (try node(&graph, "b")).id)).known);
}

test "partial IR lowers every retained truncation with both scanners" {
    const source = "digraph G { a[color=red]; a -> subgraph s { b; c->d } -> {e}; node[shape=box]; subgraph s{x}; bad->; y; }";
    inline for (.{ .scalar, .block }) |scanner| {
        const Dot = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true } } });
        for (0..source.len + 1) |end| {
            errdefer std.debug.print("retained truncation: {s}\n", .{source[0..end]});
            var parsed = Dot.parseBorrowed(a, source[0..end], dot.diagnostic.discard, .{});
            defer parsed.deinit(a);
            const doc = if (parsed.document) |*document| document else continue;
            var graph = try IR.lowerPartial(a, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
            defer graph.deinit();
            try equal(doc.subgraph_records.len + 1, graph._data.occurrences.len);
            var nodes = graph.nodeIterator();
            while (nodes.next()) |n| {
                var mentions = n.mentions();
                while (mentions.next()) |mention| {
                    try expect(mention.source.endOffset() <= end);
                    try expect(@backingInt(mention.occurrence) < graph._data.occurrences.len);
                }
            }
        }
    }
}

test "partial IR safely lowers retained scope forests around mutated syntax" {
    const source = "digraph { a -> subgraph s { b[x=1]; c -> { d; e } } -> {f}; subgraph s {g}; h[y=2]; }";
    for (0..source.len) |at| for ("{}[];\"<>-") |replacement| {
        var bytes = source.*;
        bytes[at] = replacement;
        errdefer std.debug.print("mutated fixture: {s}\n", .{bytes});
        var parsed = P.parseBorrowed(a, &bytes, dot.diagnostic.discard, .{});
        defer parsed.deinit(a);
        const doc = if (parsed.document) |*document| document else continue;
        var graph = try IR.lowerPartial(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
        defer graph.deinit();
        var nodes = graph.nodeIterator();
        while (nodes.next()) |n| {
            var mentions = n.mentions();
            while (mentions.next()) |mention| try expect(mention.source.endOffset() <= bytes.len);
        }
    };
}

test "partial IR bounded attributes charge coverage search against the same work allowance" {
    var result = try dot.ir.parsePartial(a, "digraph { a[color=red]; bad -> ; a[color=blue]; bad -> ; }", .{});
    defer result.deinit();
    const graph = result.ir().?;
    const n = try node(graph, "a");
    var complete = try dot.ir.parse(a, "digraph { a[color=red]; a[color=blue]; }", .{});
    defer complete.deinit();
    const full = try complete.ir().?.nodeView((try complete.ir().?.findNode("a")).?);
    var minimum: u64 = 0;
    while (minimum < 100) : (minimum += 1) {
        _ = full.attributeWith("color", .{ .limits = .{ .max_work = minimum } }) catch |err| {
            try equal(error.WorkLimit, err);
            continue;
        };
        break;
    }
    try expect(minimum < 100);
    try std.testing.expectError(error.WorkLimit, n.attributeWith("color", .{ .limits = .{ .max_work = minimum } }));
    try formatted("blue", (try n.attributeWith("color", .{ .limits = .{ .max_work = minimum + 2 } })).unknown.retained.?);
}
