const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const IR = dot.ir.Lowering(.{});
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn lower(source: []const u8) !IR.Graph {
    var parsed = dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    if (!parsed.documentValid()) return error.BadFixture;
    return IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}) });
}
fn node(ir: *const IR.Graph, name: []const u8) !dot.ir.NodeId {
    return (try ir.findNode(name)) orelse error.MissingNode;
}
fn value(ir: anytype, result: ?dot.ir.ResolvedAttribute, expected: []const u8) !dot.ir.ResolvedAttribute {
    const resolved = result orelse return error.MissingAttribute;
    var out: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try writer.print("{f}", .{ir.attributeValue(resolved)});
    try std.testing.expectEqualStrings(expected, writer.buffered());
    return resolved;
}
fn scope(ir: *const IR.Graph, name: []const u8) !dot.ir.ScopeId {
    for (ir.scopes, 0..) |s, i| if (s.name) |raw| {
        if (std.mem.eql(u8, ir.text(raw), name)) return @fromBackingInt(@as(u32, @intCast(i)));
    };
    return error.MissingScope;
}

test "IR defaults apply at object creation while explicit updates preserve other keys" {
    var ir = try lower("digraph { node[color=red]; a; node[color=blue]; b; a[shape=box]; \"a\"[shape=ellipse shape=diamond]; }");
    defer ir.deinit();
    const na = try node(&ir, "a");
    const color = try value(&ir, try ir.nodeAttribute(na, "color"), "red");
    try equal(.inherited, color.kind);
    try equal(.root, color.scope);
    try expect(color.origin == .declaration);
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "b"), "color"), "blue");
    const shape = try value(&ir, try ir.nodeAttribute(na, "shape"), "diamond");
    try equal(.explicit, shape.kind);
    try std.testing.expectEqualStrings("diamond", ir.text(ir.attributes[shape.attribute].value));
    const empty = try value(&ir, try ir.nodeAttribute(try node(&ir, "b"), "shape"), "");
    try equal(.empty, empty.kind);
    try expect(empty.value == .empty);
    try expect(try ir.nodeAttribute(na, "unknown") == null);
    try expect(try ir.nodeAttribute(na, "Color") == null);
}

test "IR late keys and explicit empty values are different from absence" {
    var ir = try lower("digraph { a; b[color=red]; c[color=\"\"]; node[color=blue]; d; graph[color=green]; a->b[color=purple]; }");
    defer ir.deinit();
    const empty = try value(&ir, try ir.nodeAttribute(try node(&ir, "a"), "color"), "");
    try equal(.empty, empty.kind);
    const written = try value(&ir, try ir.nodeAttribute(try node(&ir, "c"), "color"), "");
    try equal(.explicit, written.kind);
    try expect(written.value == .written);
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "d"), "color"), "blue");
    _ = try value(&ir, try ir.scopeAttribute(.root, "color"), "green");
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    _ = try value(&ir, try ir.edgeAttribute((try edges.next()).?.edge, "color"), "purple");
}

test "IR subgraph graph attributes freeze while parent node defaults remain inheritable" {
    // Graphviz 16.0.0: graph values freeze, but a reopened subgraph sees new
    // parent node/edge defaults for keys that have no local override.
    var ir = try lower("digraph { label=old; node[color=red]; edge[weight=1]; subgraph s{ a; node[shape=box] }; label=new; node[color=blue]; edge[weight=2]; subgraph s{ b; a->b }; subgraph t{ c }; subgraph s{ node[color=green]; d }; node[color=yellow]; subgraph s{e}; f; }");
    defer ir.deinit();
    const s = try scope(&ir, "s");
    const label = try value(&ir, try ir.scopeAttribute(s, "label"), "old");
    try equal(.inherited, label.kind);
    _ = try value(&ir, try ir.scopeAttribute(try scope(&ir, "t"), "label"), "new");
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "a", "red", "" },      .{ "b", "blue", "box" },  .{ "c", "blue", "" },
        .{ "d", "green", "box" }, .{ "e", "green", "box" }, .{ "f", "yellow", "" },
    };
    for (cases) |item| {
        _ = try value(&ir, try ir.nodeAttribute(try node(&ir, item[0]), "color"), item[1]);
        _ = try value(&ir, try ir.nodeAttribute(try node(&ir, item[0]), "shape"), item[2]);
    }
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    _ = try value(&ir, try ir.edgeAttribute((try edges.next()).?.edge, "weight"), "2");
    var late = try lower("digraph { subgraph s{a}; label=late; node[color=red]; subgraph s{b} }");
    defer late.deinit();
    try equal(.empty, (try value(&late, try late.scopeAttribute(try scope(&late, "s"), "label"), "")).kind);
    _ = try value(&late, try late.nodeAttribute(try node(&late, "a"), "color"), "");
    _ = try value(&late, try late.nodeAttribute(try node(&late, "b"), "color"), "red");
}

test "IR nested endpoint bodies respect node creation and edge contribution timing" {
    var ir = try lower("strict digraph { node[color=red]; edge[weight=1]; a -> {node[color=blue]; edge[weight=2]; b->c; a[color=green]} -> d [label=outer]; }");
    defer ir.deinit();
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "a"), "color"), "green");
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "b"), "color"), "blue");
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "d"), "color"), "red");
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |view| {
        const edge = view.edge;
        const inner = @backingInt(edge.first_connection) == 0;
        _ = try value(&ir, try ir.edgeAttribute(edge, "weight"), if (inner) "2" else "1");
        _ = try value(&ir, try ir.edgeAttribute(edge, "label"), if (inner) "" else "outer");
    }
}

test "IR strict edge attributes use first defaults and ordered updates including set overlap" {
    var ir = try lower("strict digraph { edge[color=red weight=1]; {a b}->{x y}[penwidth=2]; edge[color=green weight=9]; a->x[color=blue]; {a}->{x}[label=last]; }");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |view| {
        const edge = view.edge;
        const changed = edge.from == try node(&ir, "a") and edge.to == try node(&ir, "x");
        const color = try value(&ir, try ir.edgeAttribute(edge, "color"), if (changed) "blue" else "red");
        try equal(@as(@TypeOf(color.kind), if (changed) .explicit else .inherited), color.kind);
        if (changed) try equal(@as(u32, 1), @backingInt(color.origin.connection));
        _ = try value(&ir, try ir.edgeAttribute(edge, "weight"), "1");
        _ = try value(&ir, try ir.edgeAttribute(edge, "penwidth"), "2");
        _ = try value(&ir, try ir.edgeAttribute(edge, "label"), if (changed) "last" else "");
        try expect(try ir.edgeAttribute(edge, "absent") == null);
    }
    var reverse = try lower("strict graph { edge[color=red]; b--a[weight=1]; edge[color=green]; a--b[label=later]; b--a[weight=2] }");
    defer reverse.deinit();
    var undirected = try reverse.edgeIterator(.{});
    defer undirected.deinit();
    const edge = (try undirected.next()).?.edge;
    _ = try value(&reverse, try reverse.edgeAttribute(edge, "color"), "red");
    _ = try value(&reverse, try reverse.edgeAttribute(edge, "weight"), "2");
    _ = try value(&reverse, try reverse.edgeAttribute(edge, "label"), "later");
}

test "IR non-strict parallel edges and chain provenance stay distinct" {
    var ir = try lower("digraph {edge[color=red]; a->b->c[label=one]; edge[color=blue]; a->b[label=two]; }");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    var index: u32 = 0;
    while (try edges.next()) |view| : (index += 1) {
        const edge = view.edge;
        _ = try value(&ir, try ir.edgeAttribute(edge, "color"), if (index < 2) "red" else "blue");
        const label = try value(&ir, try ir.edgeAttribute(edge, "label"), if (index < 2) "one" else "two");
        try equal(index, @backingInt(label.origin.connection));
    }
    try equal(@as(u32, 3), index);
}

test "IR attribute names and values reuse logical identity without renderer processing" {
    var ir = try lower("graph { node[\"co\"+\"lor\"=\"r\"+\"ed\" label=<A&amp;B>]; a[color=blue Color=green]; }");
    defer ir.deinit();
    const id = try node(&ir, "a");
    _ = try value(&ir, try ir.nodeAttribute(id, "color"), "blue");
    _ = try value(&ir, try ir.nodeAttribute(id, "Color"), "green");
    _ = try value(&ir, try ir.nodeAttribute(id, "label"), "A&amp;B");
    try expect(try ir.nodeAttribute(id, "\"color\"") == null);
}

test "IR attribute queries reject handles, preserve stops, and expose unsupported port synthesis" {
    var ir = try lower("strict digraph {node[color=red]; a:p->b[color=blue]; a->b[color=green]; c->d[tailport=e]}");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?.edge;
    try std.testing.expectError(error.InvalidHandle, ir.nodeAttribute(@fromBackingInt(100), "color"));
    try std.testing.expectError(error.InvalidHandle, ir.scopeAttribute(@fromBackingInt(100), "color"));
    var wrong = edge;
    wrong.first_connection = @fromBackingInt(1);
    try std.testing.expectError(error.InvalidHandle, ir.edgeAttribute(wrong, "color"));
    try std.testing.expectError(error.UnsupportedSemantics, ir.edgeAttribute(edge, "tailport"));
    _ = try value(&ir, try ir.edgeAttribute(edge, "color"), "green");
    _ = try value(&ir, try ir.edgeAttribute((try edges.next()).?.edge, "tailport"), "e");
    try std.testing.expectError(error.WorkLimit, ir.nodeAttributeWith(edge.from, "color", .{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.WorkLimit, ir.edgeAttributeWith(edge, "color", .{ .limits = .{ .max_work = 0 } }));
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    const options: dot.ir.Options = .{ .cancellation = .{ .context = null, .is_requested = Stop.poll } };
    try std.testing.expectError(error.Cancelled, ir.nodeAttributeWith(edge.from, "color", options));
    try std.testing.expectError(error.Cancelled, ir.scopeAttributeWith(.root, "color", options));
    try std.testing.expectError(error.Cancelled, ir.edgeAttributeWith(edge, "color", options));
}

test "IR persistent attribute maps stay balanced and preserve old versions under varied update order" {
    inline for (.{ false, true }) |reverse| {
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        try source.writer.writeAll("graph { node[");
        for (0..512) |i| try source.writer.print("k{d}=v{d};", .{ if (reverse) 511 - i else i, i });
        try source.writer.writeAll("]; a; node[");
        for (0..512) |i| try source.writer.print("k{d}=new{d};", .{ (i * 137) % 512, i });
        try source.writer.writeAll("]; b; }");
        var ir = try lower(source.written());
        defer ir.deinit();
        const na = try node(&ir, "a");
        const nb = try node(&ir, "b");
        var name: [32]u8 = undefined;
        var expected: [32]u8 = undefined;
        for (0..512) |i| {
            const key = try std.fmt.bufPrint(&name, "k{d}", .{if (reverse) 511 - i else i});
            _ = try value(&ir, try ir.nodeAttributeWith(na, key, .{ .limits = .{ .max_work = 100 } }), try std.fmt.bufPrint(&expected, "v{d}", .{i}));
        }
        for (0..512) |i| {
            const key = try std.fmt.bufPrint(&name, "k{d}", .{(i * 137) % 512});
            _ = try value(&ir, try ir.nodeAttributeWith(nb, key, .{ .limits = .{ .max_work = 100 } }), try std.fmt.bufPrint(&expected, "new{d}", .{i}));
        }
    }
}

fn allocationProbe(allocator: std.mem.Allocator, document: *const dot.Document) !void {
    var ir = try IR.lowerComplete(allocator, document, .{ .interpretation = dot.Profile(.{}).interpretation(document, .{}) });
    defer ir.deinit();
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "b"), "color"), "blue");
}
test "IR attribute storage cleans up every allocation failure and honors state limits" {
    const source = "graph { node[color=red shape=box]; subgraph s{a; node[shape=ellipse]}; node[color=blue]; subgraph s{b}; a[x=1 y=2 z=3] }";
    var parsed = dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{&parsed.document.?});
    try std.testing.expectError(error.AttributeStateLimit, IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}), .limits = dot.ir.Limits{ .max_attribute_states = 0 } }));
    // Stop at several points during interning/map construction, not just entry.
    const Stop = struct {
        remaining: usize,
        fn poll(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
    };
    for ([_]usize{ 10, 40, 100, 180 }) |after| {
        var stop: Stop = .{ .remaining = after };
        try std.testing.expectError(error.Cancelled, IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}), .cancellation = dot.ir.Cancellation{ .context = &stop, .is_requested = Stop.poll } }));
    }
}

test "IR native attributes keep source coordinates and return UTF-8 logical values" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        const source = "graph {node[color=red]; a[color=blue];}";
        var bytes: [source.len * E.width]u8 = undefined;
        for (source, 0..) |byte, i| {
            if (E.width == 2) std.mem.writeInt(u16, bytes[i * 2 ..][0..2], byte, E.endian) else std.mem.writeInt(u32, bytes[i * 4 ..][0..4], byte, E.endian);
        }
        var parsed = try P.parseAndValidate(a, &bytes, dot.diagnostic.discard, .{ .encoding = actual });
        defer parsed.deinit(a);
        var ir = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer ir.deinit();
        const color = try value(&ir, try ir.nodeAttribute((try ir.findNode("a")).?, "color"), "blue");
        try equal(@as(u32, 4 * E.width), color.value.written.len);
        const view = try ir.nodeView((try ir.findNode("a")).?);
        var attributes = try view.attributes(.{});
        defer attributes.deinit();
        const entry = (try attributes.next()).?;
        try std.testing.expectEqualDeep(color, entry.resolved);
        var output: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try writer.print("{f}={f}", .{ entry.key(), entry.value() });
        try std.testing.expectEqualStrings("color=blue", writer.buffered());
        try expect(try attributes.next() == null);
    }
}

test "IR attribute formatting preserves byte values and checks malformed native values before publication" {
    var bytes = try lower("graph {a[label=\"\xff\"]}");
    defer bytes.deinit();
    const label = try value(&bytes, try bytes.nodeAttribute(try node(&bytes, "a"), "label"), "\xff");
    var empty: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&empty);
    try std.testing.expectError(error.WriteFailed, writer.print("{f}", .{bytes.attributeValue(label)}));
    const P = dot.Profile(.{ .source_encodings = &.{.utf16} });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{.utf16} });
    const source = "graph {a[label=\"x\"]}";
    var encoded: [source.len * 2]u8 = undefined;
    for (source, 0..) |c, i| std.mem.writeInt(u16, encoded[i * 2 ..][0..2], if (c == 'x') 0xd800 else c, .little);
    var parsed = try P.parseAndValidate(a, &encoded, dot.diagnostic.discard, .{ .encoding = .utf16le });
    defer parsed.deinit(a);
    try expect(parsed.documentValid()); // Encoding checks are opt-in.
    try std.testing.expectError(error.InvalidIdentifier, Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) }));
}

test "IR attributes agree with an independent eager oracle across defaults scopes sets and duplicates" {
    const Oracle = struct {
        const Values = [3]?u32;
        const Edge = struct { from: usize, to: usize, values: Values };
        defaults: [3][2]Values = @splat(@splat(@splat(null))),
        nodes: [12]?Values = @splat(null),
        edges: std.ArrayList(Edge) = .empty,
        keys: [2][3]bool = @splat(@splat(false)),

        fn inherited(o: *@This(), s: usize, kind: usize) Values {
            var v = o.defaults[0][kind];
            if (s != 0) for (o.defaults[s][kind], 0..) |local, k| {
                if (local != null) v[k] = local;
            };
            return v;
        }
        fn mention(o: *@This(), s: usize, n: usize) void {
            if (o.nodes[n] == null) o.nodes[n] = o.inherited(s, 0);
        }
        fn connect(o: *@This(), strict: bool, directed: bool, s: usize, from: usize, to: usize, key: ?usize, v: u32) !void {
            o.mention(s, from);
            o.mention(s, to);
            if (strict) for (o.edges.items) |*e| {
                if ((e.from == from and e.to == to) or (!directed and e.from == to and e.to == from)) {
                    if (key) |k| e.values[k] = v;
                    return;
                }
            };
            var values = o.inherited(s, 1);
            if (key) |k| values[k] = v;
            try o.edges.append(a, .{ .from = from, .to = to, .values = values });
        }
        fn check(ir: *const IR.Graph, actual: ?dot.ir.ResolvedAttribute, present: bool, expected: ?u32) !void {
            if (!present) return expect(actual == null);
            var buffer: [32]u8 = undefined;
            _ = try value(ir, actual, if (expected) |v| try std.fmt.bufPrint(&buffer, "v{d}", .{v}) else "");
        }
    };
    var random_state: std.Random.DefaultPrng = .init(0x89c4_1e23);
    const random = random_state.random();
    for (0..48) |seed| {
        const strict = seed % 2 == 0;
        const directed = seed % 4 < 2;
        var oracle: Oracle = .{};
        defer oracle.edges.deinit(a);
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        const w = &source.writer;
        try w.print("{s}{s} {{", .{ if (strict) "strict " else "", if (directed) "digraph" else "graph" });
        for (0..120) |step| {
            const s = random.uintLessThan(usize, 3);
            const k = random.uintLessThan(usize, 3);
            const v: u32 = @intCast(step + 1);
            if (s != 0) try w.print("subgraph s{d}{{", .{s});
            switch (random.uintLessThan(u8, 5)) {
                0, 1 => |kind| {
                    try w.print("{s}[k{d}=v{d}];", .{ if (kind == 0) "node" else "edge", k, v });
                    oracle.defaults[s][kind][k] = v;
                    oracle.keys[kind][k] = true;
                },
                2 => {
                    const n = random.uintLessThan(usize, 12);
                    try w.print("n{d}[k{d}=v{d}];", .{ n, k, v });
                    oracle.mention(s, n);
                    oracle.nodes[n].?[k] = v;
                    oracle.keys[0][k] = true;
                },
                3, 4 => |operation| {
                    const left = random.uintLessThan(usize, 6);
                    const right = random.uintLessThan(usize, 6) + 6;
                    const from = [_]usize{ left, (left + 1) % 6 };
                    const to = [_]usize{ right, (right - 6 + 1) % 6 + 6 };
                    const swap = !directed and random.boolean();
                    try w.print("{{n{d};n{d}}}{s}{{n{d};n{d}}}", .{ if (swap) to[0] else from[0], if (swap) to[1] else from[1], if (directed) "->" else "--", if (swap) from[0] else to[0], if (swap) from[1] else to[1] });
                    const key: ?usize = if (operation == 3) k else null;
                    if (key) |key_id| {
                        try w.print("[k{d}=v{d}]", .{ key_id, v });
                        oracle.keys[1][key_id] = true;
                    }
                    try w.writeAll(";");
                    for (if (swap) to else from) |u| for (if (swap) from else to) |vtx|
                        try oracle.connect(strict, directed, s, u, vtx, key, v);
                },
                else => unreachable,
            }
            if (s != 0) try w.writeAll("}");
        }
        try w.writeAll("}");
        var ir = try lower(source.written());
        defer ir.deinit();
        var ids: [12]?dot.ir.NodeId = @splat(null);
        var buffer: [32]u8 = undefined;
        for (oracle.nodes, 0..) |expected, n| if (expected) |values| {
            ids[n] = try node(&ir, try std.fmt.bufPrint(&buffer, "n{d}", .{n}));
            for (values, 0..) |v, k| try Oracle.check(&ir, try ir.nodeAttribute(ids[n].?, try std.fmt.bufPrint(&buffer, "k{d}", .{k})), oracle.keys[0][k], v);
        };
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        for (oracle.edges.items) |expected| {
            const actual = (try edges.next()).?.edge;
            try equal(ids[expected.from].?, actual.from);
            try equal(ids[expected.to].?, actual.to);
            for (expected.values, 0..) |v, k| try Oracle.check(&ir, try ir.edgeAttribute(actual, try std.fmt.bufPrint(&buffer, "k{d}", .{k})), oracle.keys[1][k], v);
            var attributes = try (try ir.edgeView(actual)).attributes(.{});
            defer attributes.deinit();
            var seen: [3]bool = @splat(false);
            while (try attributes.next()) |entry| {
                var key_buffer: [16]u8 = undefined;
                var key = std.Io.Writer.fixed(&key_buffer);
                try key.print("{f}", .{entry.key()});
                const k = try std.fmt.parseInt(usize, key.buffered()[1..], 10);
                try expect(!seen[k]);
                seen[k] = true;
                try Oracle.check(&ir, entry.resolved, oracle.keys[1][k], expected.values[k]);
            }
            try equal(oracle.keys[1], seen);
        }
        try expect(try edges.next() == null);
    }
}

test "IR attribute queries allocate nothing and products remain symbolic with shared defaults" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph { node[color=red]; edge[weight=2]; {");
    for (0..2000) |i| try source.writer.print("n{d};", .{i});
    try source.writer.writeAll("}->{");
    for (2000..4000) |i| try source.writer.print("n{d};", .{i});
    try source.writer.writeAll("}[label=group] }");
    var parsed = dot.parseAndValidate(a, source.written(), dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    var memory: std.testing.FailingAllocator = .init(a, .{});
    var ir = try IR.lowerComplete(memory.allocator(), &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}), .limits = dot.ir.Limits{ .max_bytes = 1024 * 1024, .max_attribute_states = 2 } });
    defer ir.deinit();
    try equal(@as(usize, 1), ir.connections.len);
    try equal(@as(usize, 2), ir.attribute_data.cells.items.len);
    try equal(ir.retainedBytes(), memory.allocated_bytes - memory.freed_bytes);
    const allocations = memory.allocations;
    const from = try node(&ir, "n0");
    _ = try value(&ir, try ir.nodeAttribute(from, "color"), "red");
    const edge: dot.ir.Edge = .{ .from = from, .to = try node(&ir, "n3999"), .operator = .directed, .first_connection = @fromBackingInt(0) };
    _ = try value(&ir, try ir.edgeAttribute(edge, "weight"), "2");
    _ = try value(&ir, try ir.edgeAttribute(edge, "label"), "group");
    try equal(allocations, memory.allocations);
}

test "IR deep default inheritance shares maps and attribute-free graphs allocate no attribute states" {
    var plain = try lower("digraph {a->b}");
    defer plain.deinit();
    try equal(@as(usize, 0), plain.attribute_data.retainedBytes());
    try equal(@as(usize, 24), @sizeOf(dot.ir.Node));
    try expect(try plain.nodeAttribute(try node(&plain, "a"), "color") == null);
    try expect(try plain.scopeAttribute(.root, "label") == null);
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("graph {label=parent; node[color=red];");
    for (0..10_000) |_| try source.writer.writeAll("{");
    try source.writer.writeAll("a");
    for (0..10_000) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("}");
    var ir = try lower(source.written());
    defer ir.deinit();
    try equal(@as(usize, 2), ir.attribute_data.cells.items.len);
    _ = try value(&ir, try ir.nodeAttribute(try node(&ir, "a"), "color"), "red");
    _ = try value(&ir, try ir.scopeAttribute(@fromBackingInt(10_000), "label"), "parent");
}
