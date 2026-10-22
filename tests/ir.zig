const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const IR = dot.ir.Lowering(.{});
test {
    _ = @import("ir_attributes.zig");
    _ = @import("ir_views.zig");
}

fn lower(allocator: std.mem.Allocator, source: []const u8) !IR.Graph {
    var parsed = dot.parseAndValidate(allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(allocator);
    if (!parsed.documentValid()) return error.BadFixture;
    const doc = &parsed.document.?;
    return IR.lowerComplete(allocator, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) });
}
fn node(ir: *const IR.Graph, name: []const u8) !dot.ir.NodeId {
    return (try ir.findNode(name)) orelse error.MissingNode;
}
fn edge(ir: *const IR.Graph, from: []const u8, to: []const u8) !bool {
    return ir.hasEdge(try node(ir, from), try node(ir, to));
}

test "IR convenience parse matches explicit lowering with no extra allocation or retained syntax" {
    const source = "digraph { a -> { b c }; \"a\" -> d; subgraph s { x } }";
    var manual_memory: std.testing.FailingAllocator = .init(a, .{});
    var manual = try lower(manual_memory.allocator(), source);
    defer manual.deinit();
    var memory: std.testing.FailingAllocator = .init(a, .{});
    {
        var result = try dot.ir.parse(memory.allocator(), source, .{});
        defer result.deinit();
        const ir = result.ir().?;
        try expect(ir.source.ptr == source.ptr);
        try equal(ir.retainedBytes(), memory.allocated_bytes - memory.freed_bytes);
        try equal(manual_memory.allocated_bytes, memory.allocated_bytes);
        try equal(manual_memory.allocations, memory.allocations);
        try std.testing.expectEqualSlices(dot.ir.Node, manual.nodes, ir.nodes);
        try equal(@as(usize, 2), ir.connections.len); // No set expansion yet.
        var nodes = ir.nodeIterator();
        for ([_][]const u8{ "a", "b", "c", "d", "x" }) |expected| {
            var buffer: [16]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try writer.print("{f}", .{try ir.nodeName(nodes.next().?)});
            try std.testing.expectEqualStrings(expected, writer.buffered());
        }
        try expect(nodes.next() == null);
        try expect(nodes.next() == null);
        var graph = try ir.materialize(.{});
        defer graph.deinit();
        try equal(@as(usize, 3), graph.edges.len);
    }
    try equal(memory.allocated_bytes, memory.freed_bytes);
}

test "IR convenience preserves DOT diagnostics and facts on success, rejection and destination stops" {
    for ([_][]const u8{ "graph {}", "graph { 1e3 }", "digraph { a -- b }", "digraph { a -> }" }) |source| {
        var direct_bag: dot.FixedDiagnosticBag(8) = .{};
        var direct = dot.parseAndValidate(a, source, direct_bag.sink(), .{});
        defer direct.deinit(a);
        var bag: dot.FixedDiagnosticBag(8) = .{};
        var result = try dot.ir.parse(a, source, .{ .diagnostics = bag.sink() });
        defer result.deinit();
        try equal(direct.documentValid(), result.ir() != null);
        try std.testing.expectEqualDeep(direct_bag.items(), bag.items());
        try std.testing.expectEqualDeep(direct.outcome, result.checking.outcome);
        try std.testing.expectEqualDeep(direct.validation, result.checking.validation);
        try equal(direct.completion, result.checking.completion);
        try equal(direct.syntax_errors, result.checking.syntax_errors);
        try equal(direct.warnings, result.checking.warnings);
        if (std.mem.indexOf(u8, source, "1e3") != null) {
            try expect(result.ir() != null and result.checking.warnings != 0);
        }
    }
    const Stop = struct {
        fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!dot.DiagnosticAction {
            return .stop;
        }
        fn reject(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!dot.DiagnosticAction {
            return error.DiagnosticSinkFailure;
        }
    };
    inline for (.{ Stop.emit, Stop.reject }) |callback| {
        var result = try dot.ir.parse(a, "graph { 1e3 }", .{ .diagnostics = .{ .context = null, .emit_fn = callback } });
        defer result.deinit();
        try expect(result.ir() == null);
        try expect(result.checking.diagnostic_stop != null);
        if (callback == Stop.reject) try equal(dot.diagnostic.Delivery.failed, result.checking.diagnostic_delivery);
    }
}

test "IR convenience renders useful diagnostics without retaining a Document" {
    for ([_][]const u8{ "digraph { a -- b }", "digraph { a -> }", "graph { 1e3 }" }) |source| {
        var bag: dot.FixedDiagnosticBag(8) = .{};
        var result = try dot.ir.parse(a, source, .{ .diagnostics = bag.sink() });
        defer result.deinit();
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        for (bag.items(), 1..) |problem, number|
            try dot.console.renderBoxed(problem, number, .{ .source = source, .source_name = "graph.dot" }, &writer);
        try expect(std.mem.indexOf(u8, writer.buffered(), "graph.dot") != null);
        try expect(std.mem.indexOf(u8, writer.buffered(), source) != null);
    }
}

fn parseAllocationProbe(allocator: std.mem.Allocator) !void {
    var result = try dot.ir.parse(allocator, "digraph { a -> { b c }; \"a\" -> d }", .{});
    defer result.deinit();
    if (result.ir() == null) {
        if (result.checking.outcome == .storage_failure and result.checking.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
        return error.BadFixture;
    }
}

test "IR convenience releases temporary and output storage on allocation or lowering failure" {
    try std.testing.checkAllAllocationFailures(a, parseAllocationProbe, .{});
    var memory: std.testing.FailingAllocator = .init(a, .{});
    const source = "digraph { a -> b }";
    try std.testing.expectError(error.NodeLimit, dot.ir.parse(memory.allocator(), source, .{ .lowering = .{ .limits = .{ .max_nodes = 0 } } }));
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    try std.testing.expectError(error.Cancelled, dot.ir.parse(memory.allocator(), source, .{ .lowering = .{ .cancellation = .{ .context = null, .is_requested = Stop.poll } } }));
    try equal(memory.allocated_bytes, memory.freed_bytes);
    var empty = try dot.ir.parse(a, "graph {}", .{});
    defer empty.deinit();
    var nodes = empty.ir().?.nodeIterator();
    try expect(nodes.next() == null);
}

test "IR lowers complete topology without expanding endpoint products" {
    var parsed = dot.parseAndValidate(a, "digraph { a -> { b c } -> d; a -> b }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    const doc = &parsed.document.?;
    var ir = try IR.lowerComplete(a, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) });
    defer ir.deinit();
    try equal(@as(usize, 4), ir.nodes.len);
    try equal(@as(usize, 3), ir.connections.len);
    const from = (try ir.findNode("a")).?;
    const to = (try ir.findNode("b")).?;
    try expect(try ir.hasEdge(from, to));
    try expect(!try ir.hasEdge(to, from));
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    try equal(@as(usize, 5), graph.edges.len);
}

test "IR interns logical identities and keeps source order ports and raw attributes" {
    var ir = try lower(a, "digraph { a:p -> { b [x=1] c -> d } -> e:q:n [x=2 x=3]; \"a\" + \"\"; <a>; graph [rankdir=LR]; rank=same }");
    defer ir.deinit();
    try equal(@as(usize, 5), ir.nodes.len);
    for ([_][]const u8{ "a", "b", "c", "d", "e" }, 0..) |name, i| try equal(@as(u32, @intCast(i)), @backingInt(try node(&ir, name)));
    try expect(try ir.findNode("\"a\"") == null);
    try expect(try ir.findNode("missing") == null);
    try equal(@as(usize, 3), ir.connections.len);
    // Inner edge commits first; outer left's node is still introduced first.
    try expect(try edge(&ir, "c", "d"));
    try std.testing.expectEqualStrings("p", ir.text(ir.connections[1].left.port.?.first));
    try std.testing.expectEqualStrings("n", ir.text(ir.connections[2].right.port.?.second.?));
    const attrs = ir.attributeSlice(ir.connections[1].attributes).?;
    try equal(@as(usize, 2), attrs.len);
    try std.testing.expectEqualStrings("2", ir.text(attrs[0].value));
    try std.testing.expectEqualStrings("3", ir.text(attrs[1].value));
    try equal(@as(usize, 5), ir.declarations.len);
    try equal(@as(usize, 5), ir.attributes.len);
}

test "IR name helpers distinguish borrowed spelling from streamed logical bytes" {
    const spelling = "\"ca\" /* glue */ + \"fé\\\"\" + \"\\\n中文\"";
    var ir = try lower(a, "digraph { " ++ spelling ++ "; <A&amp;B>; \"\"; \"raw\xff\" }");
    defer ir.deinit();
    const id = try node(&ir, "café\"中文");
    const raw = try ir.nodeSpelling(id);
    try std.testing.expectEqualStrings(spelling, raw);
    try expect(raw.ptr == ir.text(ir.nodes[@backingInt(id)].name).ptr);
    for ([_][]const u8{ "café\"中文", "A&amp;B", "", "raw\xff" }) |name| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try ir.writeNodeName(try node(&ir, name), &writer);
        try std.testing.expectEqualStrings(name, writer.buffered());
        writer.end = 0;
        try writer.print("{f}", .{try ir.nodeName(try node(&ir, name))});
        try std.testing.expectEqualStrings(name, writer.buffered());
    }
}

test "IR name writing checks handles, accounts work and propagates writer failure" {
    var ir = try lower(a, "graph { \"ab\" + \"cd\" }");
    defer ir.deinit();
    const id = try node(&ir, "abcd");
    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidHandle, ir.nodeSpelling(@fromBackingInt(500)));
    try std.testing.expectError(error.InvalidHandle, ir.nodeName(@fromBackingInt(500)));
    try std.testing.expectError(error.InvalidHandle, ir.writeNodeName(@fromBackingInt(500), &writer));
    try std.testing.expectError(error.WorkLimit, ir.writeNodeNameWith(id, &writer, .{ .limits = .{ .max_work = 1 } }));
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    try std.testing.expectError(error.Cancelled, ir.writeNodeNameWith(id, &writer, .{ .cancellation = .{ .context = null, .is_requested = Stop.poll } }));
    try equal(@as(usize, 0), writer.buffered().len);
    var tiny: [1]u8 = undefined;
    var short = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, ir.writeNodeName(id, &short));
    short.end = 0;
    try std.testing.expectError(error.WriteFailed, short.print("{f}", .{try ir.nodeName(id)}));
    // A failed write does not change the IR or the name's identity.
    try ir.writeNodeName(id, &writer);
    try std.testing.expectEqualStrings("abcd", writer.buffered());
}

test "IR reopened scopes freeze statement-end snapshots without retroactive changes" {
    var ir = try lower(a, "digraph { x -> subgraph s { a }; subgraph s { b } -> subgraph s { c }; y -> subgraph s {} }");
    defer ir.deinit();
    try equal(@as(usize, 2), ir.scopes.len);
    try equal(@as(usize, 5), ir.occurrences.len);
    try expect(try edge(&ir, "x", "a"));
    try expect(!try edge(&ir, "x", "b"));
    try expect(!try edge(&ir, "x", "c"));
    for ([_][]const u8{ "a", "b", "c" }) |from| {
        for ([_][]const u8{ "a", "b", "c" }) |to| try expect(try edge(&ir, from, to));
        try expect(try edge(&ir, "y", from));
    }
    var materialized = try ir.materialize(.{});
    defer materialized.deinit();
    try equal(@as(usize, 13), materialized.edges.len);
    try expect(!try ir.contains(ir.occurrences[1].membership, try node(&ir, "b")));
    try expect(try ir.contains(try ir.scopeMembership(@fromBackingInt(1)), try node(&ir, "c")));
}

test "IR anonymous scopes stay distinct and nested members include descendant nodes" {
    var ir = try lower(a, "digraph { {a {b b}} -> {c}; {} -> {}; subgraph p { subgraph s {d} } subgraph q { subgraph s {e} } }");
    defer ir.deinit();
    try equal(ir.occurrences.len, ir.scopes.len);
    try expect(try edge(&ir, "a", "c"));
    try expect(try edge(&ir, "b", "c"));
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    try equal(@as(usize, 2), graph.edges.len);
    try expect(!try edge(&ir, "d", "e"));
    for (ir.nodes, 0..) |_, i| try expect(try ir.contains(ir.occurrences[0].membership, @fromBackingInt(@as(u32, @intCast(i)))));
}

test "IR strict pairs coalesce in forward contribution order while non-strict keeps parallels" {
    inline for (.{ "strict graph { a--b; b--a; {a b}--{a b}; a--a }", "graph { a--b; b--a; {a b}--{a b}; a--a }" }, .{ @as(usize, 3), @as(usize, 7) }) |source, expected| {
        var ir = try lower(a, source);
        defer ir.deinit();
        var graph = try ir.materialize(.{});
        defer graph.deinit();
        try equal(expected, graph.edges.len);
        try expect(try edge(&ir, "b", "a"));
        try equal(@as(u32, 0), @backingInt(graph.edges[0].first_connection));
        try equal(@as(usize, 4), ir.connections.len);
    }
    var directed = try lower(a, "strict digraph { a->b; b->a; a->b }");
    defer directed.deinit();
    var graph = try directed.materialize(.{});
    defer graph.deinit();
    try equal(@as(usize, 2), graph.edges.len);
}

test "IR limits and cancellation fail explicitly without pretending absence" {
    const source = "digraph { a -> { b c } }";
    var parsed = dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    const interpretation = dot.Profile(.{}).interpretation(doc, .{});
    inline for (.{ .{ .max_nodes = 1 }, .{ .max_scopes = 1 }, .{ .max_mentions = 1 }, .{ .max_connections = 0 }, .{ .max_work = 0 }, .{ .max_bytes = 1 } }, .{ error.NodeLimit, error.ScopeLimit, error.MentionLimit, error.ConnectionLimit, error.WorkLimit, error.MemoryLimit }) |limits, err| {
        var settings: dot.ir.Limits = .{};
        inline for (comptime std.meta.fieldNames(@TypeOf(limits))) |field| @field(settings, field) = @field(limits, field);
        try std.testing.expectError(err, IR.lowerComplete(a, doc, .{ .interpretation = interpretation, .limits = settings }));
    }
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    const cancel: dot.ir.Cancellation = .{ .context = null, .is_requested = Stop.poll };
    try std.testing.expectError(error.Cancelled, IR.lowerComplete(a, doc, .{ .interpretation = interpretation, .cancellation = cancel }));
    var ir = try IR.lowerComplete(a, doc, .{ .interpretation = interpretation });
    defer ir.deinit();
    try std.testing.expectError(error.PairLimit, ir.materialize(.{ .limits = .{ .max_pairs = 1 } }));
    try std.testing.expectError(error.EdgeLimit, ir.materialize(.{ .limits = .{ .max_edges = 1 } }));
    try std.testing.expectError(error.MemoryLimit, ir.materialize(.{ .limits = .{ .max_bytes = 1 } }));
    try std.testing.expectError(error.WorkLimit, ir.hasEdgeWith(try node(&ir, "a"), try node(&ir, "b"), .{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.Cancelled, ir.materialize(.{ .cancellation = cancel }));
    try std.testing.expectError(error.InvalidHandle, ir.hasEdge(@fromBackingInt(500), try node(&ir, "a")));
    try std.testing.expectError(error.InvalidHandle, ir.contains(@fromBackingInt(1000), try node(&ir, "a")));
}

test "IR rejects partial Documents instead of publishing a complete graph" {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
    var parsed = P.parseBorrowed(a, "digraph { a; b ->", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.document != null);
    const doc = &parsed.document.?;
    try std.testing.expectError(error.IncompleteDocument, IR.lowerComplete(a, doc, .{ .interpretation = P.interpretation(doc, .{}) }));
}

fn allocationProbe(allocator: std.mem.Allocator, doc: *const dot.Document) !void {
    var ir = try IR.lowerComplete(allocator, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) });
    defer ir.deinit();
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    var index: usize = 0;
    while (try edges.next()) |actual| {
        try equal(graph.edges[index], actual);
        index += 1;
    }
    try equal(graph.edges.len, index);
    try expect(try edge(&ir, "a", "b"));
}
test "IR, materialization and streaming release every allocation on failure" {
    var parsed = dot.parseAndValidate(a, "strict digraph { a -> subgraph s { a b }; subgraph s { c } -> subgraph s {}; node [x=1] a[x=2]; x=y }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{&parsed.document.?});
}

test "IR nesting is iterative and Cartesian products stay symbolic" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    for (0..2000) |_| try source.writer.writeAll("{");
    try source.writer.writeAll("a");
    for (0..2000) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("-> b }");
    var deep = try lower(a, source.written());
    defer deep.deinit();
    try expect(try edge(&deep, "a", "b"));
    var deep_edges = try deep.edgeIterator(.{});
    defer deep_edges.deinit();
    try equal(try node(&deep, "a"), (try deep_edges.next()).?.from);
    try expect(try deep_edges.next() == null);
    source.clearRetainingCapacity();
    try source.writer.writeAll("digraph {{");
    for (0..2000) |i| try source.writer.print("n{d};", .{i});
    try source.writer.writeAll("}->{");
    for (2000..4000) |i| try source.writer.print("n{d};", .{i});
    try source.writer.writeAll("}}");
    var product = try lower(a, source.written());
    defer product.deinit();
    try equal(@as(usize, 1), product.connections.len);
    try equal(@as(usize, 4000), product.nodes.len);
    try expect(try edge(&product, "n0", "n3999"));
    try expect(product.peak_bytes < 4 * 1024 * 1024);
    try std.testing.expectError(error.PairLimit, product.materialize(.{ .limits = .{ .max_pairs = 1_000_000 } }));
}

test "IR interpretation preserves written operators and explicit profile meanings" {
    const Conform = dot.Profile(.{ .policy = .{ .validation = .{ .digraph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind } } } });
    var parsed = Conform.parseAndValidate(a, "digraph { a -- b }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    var ir = try IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = Conform.interpretation(&parsed.document.?, .{}) });
    defer ir.deinit();
    try equal(dot.EdgeOperator.undirected, ir.connections[0].written_operator);
    try equal(dot.EdgeOperator.directed, ir.connections[0].effective_operator);
    try expect(!try edge(&ir, "b", "a"));

    const Generic = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } } });
    inline for (.{ "graph { a -- b; b -> c }", "strict graph { a -- b; b -> c }" }) |source| {
        var mixed = Generic.parseAndValidate(a, source, dot.diagnostic.discard, .{});
        defer mixed.deinit(a);
        try expect(mixed.documentValid());
        const doc = &mixed.document.?;
        const options = .{ .interpretation = Generic.interpretation(doc, .{}) };
        if (doc.strict) {
            try std.testing.expectError(error.UnsupportedSemantics, IR.lowerComplete(a, doc, options));
        } else {
            var generic = try IR.lowerComplete(a, doc, options);
            defer generic.deinit();
            try equal(dot.GraphKind.generic, generic.kind);
            try expect(try edge(&generic, "b", "a"));
            try expect(!try edge(&generic, "c", "b"));
            var stream = try generic.edgeIterator(.{});
            defer stream.deinit();
            try equal(dot.EdgeOperator.undirected, (try stream.next()).?.operator);
            try equal(dot.EdgeOperator.directed, (try stream.next()).?.operator);
            try expect(try stream.next() == null);
        }
    }
}

test "IR native encoding names keep original source ranges" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width: usize = comptime dot.encoding.unitBytes(actual);
        const big = actual == .utf16be or actual == .utf32be;
        const text = "digraph { a -> \"a\"; \"A&B\" -> <A&amp;B> }";
        var bytes: [text.len * width]u8 = @splat(0);
        for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        var parsed = try P.parseAndValidate(a, &bytes, dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        const doc = &parsed.document.?;
        var ir = try Native.lowerComplete(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
        defer ir.deinit();
        try equal(@as(usize, 3), ir.nodes.len);
        for ([_][]const u8{ "a", "A&B", "A&amp;B" }) |name| {
            const id = (try ir.findNode(name)).?;
            var out: [32]u8 = undefined;
            var writer = std.Io.Writer.fixed(&out);
            try ir.writeNodeName(id, &writer);
            try std.testing.expectEqualStrings(name, writer.buffered());
            writer.end = 0;
            try writer.print("{f}", .{try ir.nodeName(id)});
            try std.testing.expectEqualStrings(name, writer.buffered());
            try expect((try ir.nodeSpelling(id)).len % width == 0);
        }
        try equal(actual, ir.source_info.encoding);
        try equal(@as(u32, @intCast(width)), ir.nodes[0].name.len);
        var stream = try ir.edgeIterator(.{});
        defer stream.deinit();
        const first = (try stream.next()).?;
        try equal(first.from, first.to); // a and "a" are one native node.
        const second = (try stream.next()).?;
        try expect(second.from != second.to); // No HTML entity expansion.
        try expect(try stream.next() == null);
        try std.testing.expectError(error.UnsupportedEncoding, IR.lowerComplete(a, doc, .{ .interpretation = P.interpretation(doc, .{}) }));
    }
}

test "IR name writing transcodes native non-ASCII and surrogate pairs without a copy" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    // Code points, including a supplementary-plane scalar, serialized into
    // each native encoding. The quoted concatenation must still be decoded.
    const scalars = [_]u21{ 'g', 'r', 'a', 'p', 'h', ' ', '{', '"', 'é', '"', '+', '"', '中', '😀', '"', '}' };
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var buffer: [scalars.len * 4]u8 = undefined;
        var at: usize = 0;
        for (scalars) |scalar| {
            if (E.width == 2) {
                if (scalar > 0xffff) {
                    const extra = scalar - 0x10000;
                    std.mem.writeInt(u16, buffer[at..][0..2], @intCast(0xd800 + (extra >> 10)), E.endian);
                    at += 2;
                    std.mem.writeInt(u16, buffer[at..][0..2], @intCast(0xdc00 + (extra & 1023)), E.endian);
                } else std.mem.writeInt(u16, buffer[at..][0..2], @intCast(scalar), E.endian);
            } else std.mem.writeInt(u32, buffer[at..][0..4], scalar, E.endian);
            at += E.width;
        }
        var parsed = try P.parseAndValidate(a, buffer[0..at], dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        try expect(parsed.documentValid());
        const doc = &parsed.document.?;
        var ir = try Native.lowerComplete(a, doc, .{ .interpretation = P.interpretation(doc, .{}) });
        defer ir.deinit();
        const id = (try ir.findNode("é中😀")).?;
        var out: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try ir.writeNodeName(id, &writer);
        try std.testing.expectEqualStrings("é中😀", writer.buffered());
        writer.end = 0;
        try writer.print("{f}", .{try ir.nodeName(id)});
        try std.testing.expectEqualStrings("é中😀", writer.buffered());
    }
}

test "IR empty and isolated-node graphs need no connections" {
    inline for (.{ "graph {}", "graph { a a \"\" }" }, .{ @as(usize, 0), @as(usize, 2) }) |source, count| {
        var ir = try lower(a, source);
        defer ir.deinit();
        try equal(count, ir.nodes.len);
        try equal(@as(usize, 0), ir.connections.len);
        var graph = try ir.materialize(.{});
        defer graph.deinit();
        try equal(@as(usize, 0), graph.edges.len);
    }
}

test "IR generated reopened nested scopes agree with an independent eager set oracle" {
    // The oracle copies tiny membership bitsets and explicitly expands pairs;
    // production lowering never uses this representation or expansion algorithm.
    for (0..25) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        try source.writer.writeAll("strict digraph {");
        var sets: [4]u16 = @splat(0);
        var expected: [48][48]bool = @splat(@splat(false));
        for (0..32) |step| {
            const parent = random.random().uintLessThan(u8, 4);
            const child = random.random().uintLessThan(u8, 3);
            const first = random.random().int(u4);
            const second = random.random().int(u4);
            const last = random.random().int(u4);
            try source.writer.print("subgraph p{d}{{subgraph c{d}{{n{d};n{d};}}}} -> subgraph p{d}{{n{d};}} -> q{d};", .{ parent, child, first, second, parent, last, step });
            sets[parent] |= (@as(u16, 1) << first) | (@as(u16, 1) << second) | (@as(u16, 1) << last);
            for (0..16) |from| if (sets[parent] & (@as(u16, 1) << @intCast(from)) != 0) {
                expected[from][16 + step] = true;
                for (0..16) |to| if (sets[parent] & (@as(u16, 1) << @intCast(to)) != 0) {
                    expected[from][to] = true;
                };
            };
        }
        try source.writer.writeAll("}");
        var ir = try lower(a, source.written());
        defer ir.deinit();
        var ids: [48]?dot.ir.NodeId = undefined;
        var spelling: [16]u8 = undefined;
        for (&ids, 0..) |*id, index| id.* = try ir.findNode(try std.fmt.bufPrint(&spelling, "{s}{d}", .{ if (index < 16) "n" else "q", if (index < 16) index else index - 16 }));
        var expected_edges: usize = 0;
        for (expected, 0..) |row, from| for (row, 0..) |present, to| {
            if (present) expected_edges += 1;
            const actual = if (ids[from] != null and ids[to] != null) try ir.hasEdge(ids[from].?, ids[to].?) else false;
            try equal(present, actual);
        };
        var graph = try ir.materialize(.{});
        defer graph.deinit();
        try equal(expected_edges, graph.edges.len);
        // Verify streamed pairs against the independent eager oracle as well
        // as the owning path. Shared traversal alone is not an oracle.
        var stream = try ir.edgeIterator(.{});
        defer stream.deinit();
        var seen: [48][48]bool = @splat(@splat(false));
        var count: usize = 0;
        while (try stream.next()) |actual| {
            var from: usize = 0;
            while (ids[from] != actual.from) : (from += 1) {}
            var to: usize = 0;
            while (ids[to] != actual.to) : (to += 1) {}
            try expect(expected[from][to] and !seen[from][to]);
            seen[from][to] = true;
            try equal(graph.edges[count], actual);
            count += 1;
        }
        try equal(expected_edges, count);
    }
}

test "IR mixed endpoint chains preserve every link and first introductions" {
    var ir = try lower(a, "digraph { a -> b -> {c -> d} -> e -> {f} -> g }");
    defer ir.deinit();
    try equal(@as(usize, 6), ir.connections.len);
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g" }, 0..) |name, i| try equal(@as(u32, @intCast(i)), @backingInt(try node(&ir, name)));
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    try equal(@as(usize, 8), graph.edges.len);
    try expect(try edge(&ir, "d", "e"));
    try expect(try edge(&ir, "f", "g"));
}

test "IR ASCII admission and runtime interpretation do not need a second parser" {
    const P = dot.Profile(.{ .source_encodings = &.{}, .runtime_policy = true });
    const options: P.Options = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } } };
    var parsed = try P.parseAndValidate(a, "graph { a -> b -- c }", dot.diagnostic.discard, .{ .policy = options.policy });
    defer parsed.deinit(a);
    try expect(parsed.documentValid());
    const doc = &parsed.document.?;
    var ir = try IR.lowerComplete(a, doc, .{ .interpretation = try P.interpretation(doc, options) });
    defer ir.deinit();
    try equal(dot.GraphKind.generic, ir.kind);
    try expect(try edge(&ir, "c", "b"));
    try expect(!try edge(&ir, "b", "a"));
    var buffer: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try ir.writeNodeName(try node(&ir, "a"), &writer);
    try std.testing.expectEqualStrings("a", writer.buffered());
    writer.end = 0;
    try writer.print("{f}", .{try ir.nodeName(try node(&ir, "a"))});
    try std.testing.expectEqualStrings("a", writer.buffered());
}

test "IR cancellation during lowering and expansion discards operation-owned storage" {
    const Counter = struct {
        left: usize,
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.left == 0) return true;
            self.left -= 1;
            return false;
        }
    };
    var parsed = dot.parseAndValidate(a, "digraph { a -> { b c d } a->b[x=1] }", dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    const doc = &parsed.document.?;
    for ([_]usize{ 1, 10, 40, 80 }) |allowance| {
        var counter: Counter = .{ .left = allowance };
        const cancel: dot.ir.Cancellation = .{ .context = &counter, .is_requested = Counter.poll };
        try std.testing.expectError(error.Cancelled, IR.lowerComplete(a, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}), .cancellation = cancel }));
    }
    var ir = try IR.lowerComplete(a, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) });
    defer ir.deinit();
    var counter: Counter = .{ .left = 8 };
    try std.testing.expectError(error.Cancelled, ir.materialize(.{ .cancellation = .{ .context = &counter, .is_requested = Counter.poll } }));
    // The existing IR is still queryable after a stopped expansion.
    try expect(try edge(&ir, "a", "d"));
}

test "IR streaming preserves nested contribution, endpoint and parallel occurrence order" {
    var ir = try lower(a, "digraph { a:p -> {b b; c -> d} -> e:q; a->b; {}->x }");
    defer ir.deinit();
    const Expected = struct { from: []const u8, to: []const u8, connection: u32 };
    const expected = [_]Expected{
        .{ .from = "c", .to = "d", .connection = 0 },
        .{ .from = "a", .to = "b", .connection = 1 },
        .{ .from = "a", .to = "c", .connection = 1 },
        .{ .from = "a", .to = "d", .connection = 1 },
        .{ .from = "b", .to = "e", .connection = 2 },
        .{ .from = "c", .to = "e", .connection = 2 },
        .{ .from = "d", .to = "e", .connection = 2 },
        .{ .from = "a", .to = "b", .connection = 3 },
    };
    var stream = try ir.edgeIterator(.{});
    defer stream.deinit();
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    for (expected, graph.edges) |wanted, materialized| {
        const actual = (try stream.next()).?;
        try equal(try node(&ir, wanted.from), actual.from);
        try equal(try node(&ir, wanted.to), actual.to);
        try equal(wanted.connection, @backingInt(actual.first_connection));
        try equal(dot.EdgeOperator.directed, actual.operator);
        try equal(materialized, actual);
    }
    try expect(try stream.next() == null);
    try expect(try stream.next() == null);
}

test "IR strict streaming coalesces reversed pairs and self loops without losing first provenance" {
    var ir = try lower(a, "strict graph { b:p -- a:q; a:r -- b:s; {a b}--{a b}; a--a }");
    defer ir.deinit();
    var stream = try ir.edgeIterator(.{ .limits = .{ .max_edges = 3, .max_pairs = 7 } });
    defer stream.deinit();
    const expected = [_]struct { []const u8, []const u8, u32 }{ .{ "b", "a", 0 }, .{ "a", "a", 2 }, .{ "b", "b", 2 } };
    for (expected) |wanted| {
        const actual = (try stream.next()).?;
        try equal(try node(&ir, wanted[0]), actual.from);
        try equal(try node(&ir, wanted[1]), actual.to);
        try equal(wanted[2], @backingInt(actual.first_connection));
        try equal(dot.EdgeOperator.undirected, actual.operator);
    }
    // Duplicates after the edge cap still count as work/pairs, not new edges.
    try expect(try stream.next() == null);
    try equal(@as(usize, 4), ir.connections.len);

    var directed = try lower(a, "strict digraph { a->b; b->a; a->b }");
    defer directed.deinit();
    var ds = try directed.edgeIterator(.{});
    defer ds.deinit();
    try equal(try node(&directed, "a"), (try ds.next()).?.from);
    try equal(try node(&directed, "b"), (try ds.next()).?.from);
    try expect(try ds.next() == null);
}

test "IR empty and non-strict singleton streams allocate nothing" {
    inline for (.{ "graph {}", "graph { a }", "graph { {}--{} }", "graph { a--b; b--a; a--a }" }, .{ 0, 0, 0, 3 }) |source, expected| {
        var ir = try lower(a, source);
        defer ir.deinit();
        var stream = try ir.edgeIterator(.{ .limits = .{ .max_bytes = 0 } });
        defer stream.deinit();
        var count: u32 = 0;
        while (try stream.next() != null) count += 1;
        try equal(@as(u32, expected), count);
        try equal(@as(usize, 0), stream.peakBytes());
    }
}

test "IR streaming can consume a bounded prefix of a large symbolic product" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {{");
    for (0..1000) |i| try source.writer.print("n{d};", .{i});
    try source.writer.writeAll("}->{");
    for (1000..2000) |i| try source.writer.print("n{d};", .{i});
    try source.writer.writeAll("}}");
    var memory: std.testing.FailingAllocator = .init(a, .{});
    var ir = try lower(memory.allocator(), source.written());
    defer ir.deinit();
    const retained = memory.allocated_bytes - memory.freed_bytes;
    const options: dot.ir.Options = .{ .limits = .{ .max_pairs = 3, .max_edges = 3 } };
    {
        var stream = try ir.edgeIterator(options);
        defer stream.deinit();
        try equal(@as(usize, 0), stream.peakBytes()); // Lazy scratch.
        const first = (try stream.next()).?;
        try equal(try node(&ir, "n0"), first.from);
        try equal(try node(&ir, "n1000"), first.to);
        const peak = stream.peakBytes();
        for (1..3) |i| {
            const next = (try stream.next()).?;
            try equal(first.from, next.from);
            try equal(@backingInt(first.to) + @as(u32, @intCast(i)), @backingInt(next.to));
        }
        try equal(peak, stream.peakBytes()); // No per-output allocation.
        try expect(peak < 32 * 1024); // Not a million-edge output array.
        try std.testing.expectError(error.PairLimit, stream.next());
        try std.testing.expectError(error.PairLimit, stream.next());
    }
    try equal(retained, memory.allocated_bytes - memory.freed_bytes);
    {
        var stream = try ir.edgeIterator(.{});
        defer stream.deinit();
        _ = try stream.next(); // Deliberate early exit, no exhaustion required.
    }
    try equal(retained, memory.allocated_bytes - memory.freed_bytes);
    // Owning output cannot succeed with that cap: reject before expanding it.
    try std.testing.expectError(error.PairLimit, ir.materialize(options));
    try equal(retained, memory.allocated_bytes - memory.freed_bytes);
}

test "IR streaming limits are cumulative and failures are sticky rather than exhaustion" {
    var ir = try lower(a, "digraph { a->b; b->c }");
    defer ir.deinit();
    inline for (.{ .{ .max_pairs = 1 }, .{ .max_edges = 1 }, .{ .max_work = 3 } }, .{ error.PairLimit, error.EdgeLimit, error.WorkLimit }) |limit, err| {
        var settings: dot.ir.Limits = .{};
        inline for (comptime std.meta.fieldNames(@TypeOf(limit))) |field| @field(settings, field) = @field(limit, field);
        var stream = try ir.edgeIterator(.{ .limits = settings });
        defer stream.deinit();
        try expect(try stream.next() != null);
        try std.testing.expectError(err, stream.next());
        try std.testing.expectError(err, stream.next());
    }
    inline for (.{ "strict digraph { a->b }", "digraph { a->{b c} }" }) |source| {
        var bounded = try lower(a, source);
        defer bounded.deinit();
        var stream = try bounded.edgeIterator(.{ .limits = .{ .max_bytes = 1 } });
        defer stream.deinit();
        try std.testing.expectError(error.MemoryLimit, stream.next());
        try std.testing.expectError(error.MemoryLimit, stream.next());
    }
}

test "IR materialization has one combined scratch and output allocation limit" {
    var ir = try lower(a, "digraph { {a b}->{c d} }");
    defer ir.deinit();
    var stream = try ir.edgeIterator(.{});
    defer stream.deinit();
    while (try stream.next() != null) {}
    // Both paths need the same endpoint scratch. An output buffer in addition
    // must not fit by silently receiving its own independent max_bytes cap.
    try std.testing.expectError(error.MemoryLimit, ir.materialize(.{ .limits = .{ .max_bytes = stream.peakBytes() } }));
}

test "IR streaming cancellation is polled between calls and inside endpoint and strict walks" {
    const Counter = struct {
        remaining: u32,
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
    };
    var ir = try lower(a, "strict digraph { {a b c d e f}->{a b c d e f}; a->b; b->a }");
    defer ir.deinit();
    for (0..180) |allowed| {
        var counter: Counter = .{ .remaining = @intCast(allowed) };
        const options: dot.ir.Options = .{ .cancellation = .{ .context = &counter, .is_requested = Counter.poll } };
        if (allowed == 0) {
            try std.testing.expectError(error.Cancelled, ir.edgeIterator(options));
            continue;
        }
        var stream = try ir.edgeIterator(options);
        defer stream.deinit();
        while (true) {
            const actual = stream.next() catch |err| {
                try equal(error.Cancelled, err);
                counter.remaining = 1000;
                try std.testing.expectError(error.Cancelled, stream.next());
                break;
            };
            try expect(actual != null); // This fixture needs >180 polls.
        }
    }
    var simple = try lower(a, "digraph { a->b; b->c }");
    defer simple.deinit();
    var counter: Counter = .{ .remaining = 100 };
    var stream = try simple.edgeIterator(.{ .cancellation = .{ .context = &counter, .is_requested = Counter.poll } });
    defer stream.deinit();
    try expect(try stream.next() != null);
    counter.remaining = 0;
    try std.testing.expectError(error.Cancelled, stream.next());
}
