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

fn formatted(expected: []const u8, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{value});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "IR attribute format delegates to values and distinguishes absent from empty optionals" {
    var ir = try lower(
        "digraph {label=root; node[color=red];" ++
            "a[text=\"a\"+\"bee\" html=<<B>x&amp;y</B>> empty=\"\"];" ++
            "b[only_b=x]; a:p:n->b[label=\"edge\"]}",
    );
    defer ir.deinit();
    const node = try ir.nodeView((try ir.findNode("a")).?);
    try formatted("red", node.attribute("color").?);
    try formatted("abee", node.attribute("text").?);
    try formatted("<B>x&amp;y</B>", node.attribute("html").?);
    try formatted("", node.attribute("empty").?);
    try formatted("", node.attribute("only_b").?);
    try equal(.explicit, node.attribute("empty").?.resolved.kind);
    try equal(.empty, node.attribute("only_b").?.resolved.kind);

    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writer.print("text={?f}; written=[{?f}]; implicit=[{?f}]; absent={?f}", .{
        node.attribute("text"), node.attribute("empty"), node.attribute("only_b"), node.attribute("missing"),
    });
    try std.testing.expectEqualStrings("text=abee; written=[]; implicit=[]; absent=null", writer.buffered());
    const root = try ir.scopeView(.root);
    try formatted("root", root.attribute("label").?);

    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    try formatted("p:n", (try edge.attribute("tailport")).?);
    var materialized = try ir.materialize(.{});
    defer materialized.deinit();
    var folded_edges = materialized.edgeIterator();
    const folded = folded_edges.next().?;
    try formatted("edge", folded.attribute("label").?);
    try formatted("p:n", folded.attribute("tailport").?);

    var small: [1]u8 = undefined;
    var short_writer = std.Io.Writer.fixed(&small);
    try std.testing.expectError(error.WriteFailed, short_writer.print("{?f}", .{node.attribute("text")}));
}

/// Compare iteration with independent direct lookups, including every origin.
fn checkAll(view: anytype, expected: []const []const u8) !void {
    var iterator = try view.attributes(.{});
    defer iterator.deinit();
    for (expected) |key| {
        const entry = (try iterator.next()) orelse return error.MissingAttribute;
        try formatted(key, entry.key());
        const direct = (try view.attributeWith(key, .{})) orelse return error.MissingAttribute;
        try std.testing.expectEqualDeep(direct.resolved, entry.resolved);
    }
    try expect(try iterator.next() == null);
    try expect(try iterator.next() == null);
}

test "IR node views provide names single attributes and unique effective attribute iteration" {
    var ir = try lower("graph {node[\"co\"+\"lor\"=red]; a; node[color=blue]; b; a[color=green color=yellow shape=box]; c[shape=\"\"]; }");
    defer ir.deinit();
    const before = ir.retainedBytes();
    const node = try ir.nodeView((try ir.findNode("a")).?);
    try formatted("a", node.name());
    const color = (node.attribute("color")).?;
    try formatted("color", color.key());
    try formatted("yellow", color.value());
    try equal(.explicit, color.resolved.kind);
    try expect(node.attribute("unknown") == null);
    var nodes = ir.nodeIterator();
    while (nodes.next()) |node_view| try checkAll(node_view, &.{ "color", "shape" });
    const b = try ir.nodeView((try ir.findNode("b")).?);
    try equal(.inherited, (b.attribute("color")).?.resolved.kind);
    try equal(.empty, (b.attribute("shape")).?.resolved.kind);
    const c = try ir.nodeView((try ir.findNode("c")).?);
    try equal(.explicit, (c.attribute("shape")).?.resolved.kind);
    try equal(before, ir.retainedBytes());
    // Views/entries borrow the IR, not the iterator that produced them.
    var attributes = try node.attributes(.{});
    const entry = (try attributes.next()).?;
    attributes.deinit();
    try formatted("yellow", entry.value());
}

test "IR graph and subgraph views iterate captured and explicit values separately from node and edge keys" {
    var ir = try lower("digraph {label=old; node[color=red]; edge[weight=1]; subgraph s{a}; label=new; subgraph s{bgcolor=blue}; }");
    defer ir.deinit();
    const root = try ir.scopeView(.root);
    try checkAll(root, &.{ "label", "bgcolor" });
    try equal(.empty, (root.attribute("bgcolor")).?.resolved.kind);
    const subgraph = try ir.scopeView(@fromBackingInt(1));
    try checkAll(subgraph, &.{ "label", "bgcolor" });
    const label = (subgraph.attribute("label")).?;
    try formatted("old", label.value());
    try equal(.inherited, label.resolved.kind);
    try expect(subgraph.attribute("color") == null);
}

test "IR edge views fold strict overlaps once and keep non-strict chain and parallel provenance" {
    inline for (.{ true, false }) |strict| {
        var ir = try lower((if (strict) "strict " else "") ++
            "digraph { edge[color=red weight=1]; {a b}->{x y}[penwidth=2]; edge[color=green weight=9]; a->x[color=blue]; a->x->y[label=last]; x->y[color=black]; }");
        defer ir.deinit();
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        while (try edges.next()) |view| {
            const edge = view.edge;
            try equal(edge.from, view.from().id);
            try equal(edge.to, view.to().id);
            try checkAll(view, &.{ "color", "weight", "penwidth", "label" });
        }
    }
    var ir = try lower("strict graph {edge[color=red]; b--a[weight=1]; edge[color=green]; a--b[label=later]; b--a[weight=2]}");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    try checkAll((try edges.next()).?, &.{ "color", "weight", "label" });
}

test "IR attribute iteration is empty without keys and includes derived endpoint ports" {
    inline for (.{ "digraph {a->b}", "strict digraph {a->b}" }) |source| {
        var ir = try lower(source);
        defer ir.deinit();
        try checkAll(try ir.nodeView((try ir.findNode("a")).?), &.{});
        try checkAll(try ir.scopeView(.root), &.{});
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        try checkAll((try edges.next()).?, &.{});
    }
    inline for (.{ "digraph {a:p->b}", "strict digraph {a->b[color=red]; a:p->b; c->d[label=ok]}" }) |source| {
        var ir = try lower(source);
        defer ir.deinit();
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        const view = (try edges.next()).?;
        var attributes = try view.attributes(.{});
        defer attributes.deinit();
        var found_port = false;
        while (try attributes.next()) |attribute| if (attribute.resolved.port_key == .tailport) {
            found_port = true;
        };
        try std.testing.expect(found_port);
        if (try edges.next()) |unrelated| try checkAll(unrelated, &.{ "color", "label", "tailport" });
    }
}

test "IR views reject invalid handles and attribute iterators preserve cumulative and terminal stops" {
    var ir = try lower("strict digraph {a[x=1 y=2 z=3]; a->b[color=red]; a->b[color=blue]; c}");
    defer ir.deinit();
    try std.testing.expectError(error.InvalidHandle, ir.nodeView(@fromBackingInt(99)));
    try std.testing.expectError(error.InvalidHandle, ir.scopeView(@fromBackingInt(99)));
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    var edge = (try edges.next()).?.edge;
    edge.first_connection = @fromBackingInt(99);
    try std.testing.expectError(error.InvalidHandle, ir.edgeView(edge));
    edge.first_connection = @fromBackingInt(1); // A later strict duplicate isn't the first contributor.
    var bad = try (try ir.edgeView(edge)).attributes(.{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidHandle, bad.next());
    edge.first_connection = @fromBackingInt(0);
    edge.to = (try ir.findNode("c")).?;
    var absent = try (try ir.edgeView(edge)).attributes(.{});
    defer absent.deinit();
    try std.testing.expectError(error.InvalidHandle, absent.next());

    const node = try ir.nodeView((try ir.findNode("a")).?);
    var limited = try node.attributes(.{ .limits = .{ .max_work = 4, .max_bytes = 0 } });
    defer limited.deinit();
    try expect(try limited.next() != null);
    try std.testing.expectError(error.WorkLimit, limited.next());
    try std.testing.expectError(error.WorkLimit, limited.next());
    const Stop = struct {
        fn poll(ctx: ?*anyopaque) bool {
            const stop: *bool = @ptrCast(@alignCast(ctx.?));
            return stop.*;
        }
    };
    var stop = false;
    const options: dot.ir.Options = .{ .cancellation = .{ .context = &stop, .is_requested = Stop.poll } };
    var cancellable = try node.attributes(options);
    defer cancellable.deinit();
    try expect(try cancellable.next() != null);
    stop = true;
    try std.testing.expectError(error.Cancelled, cancellable.next());
    try std.testing.expectError(error.Cancelled, node.attributeWith("x", options));
    try std.testing.expectError(error.Cancelled, node.attributes(options));
    stop = false;
    try std.testing.expectError(error.Cancelled, cancellable.next());
}

fn allocationProbe(allocator: std.mem.Allocator, original: *const IR.Graph, edge: dot.ir.Edge) !void {
    // A borrowed test copy routes only iterator scratch through the failing allocator.
    var ir = original.*;
    ir.allocator = allocator;
    var attributes = try (try ir.edgeView(edge)).attributes(.{});
    defer attributes.deinit();
    while (try attributes.next()) |_| {}
}

test "IR attribute iteration scratch is bounded by edge keys not updates and cleaned up on failures" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("strict digraph {a[");
    for (0..100) |i| try source.writer.print("n{d}=v ", .{i});
    try source.writer.writeAll("]; edge[color=red];");
    for (0..100) |i| try source.writer.print("a->b[weight={d} label=l];", .{i});
    try source.writer.writeAll("}");
    var ir = try lower(source.written());
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    const view = (try edges.next()).?;
    const edge = view.edge;
    var attributes = try view.attributes(.{});
    defer attributes.deinit();
    while (try attributes.next()) |_| {}
    try equal(@as(usize, 3 * 12), attributes.peakBytes());
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{ &ir, edge });
    var limited = try view.attributes(.{ .limits = .{ .max_bytes = 35 } });
    defer limited.deinit();
    try std.testing.expectError(error.MemoryLimit, limited.next());
    try std.testing.expectError(error.MemoryLimit, limited.next());
    // Exhaust work while initializing/merging scratch, not just at entry.
    for ([_]u64{ 5, 110, 220, 300 }) |budget| {
        var stopped = try view.attributes(.{ .limits = .{ .max_work = budget } });
        defer stopped.deinit();
        try std.testing.expectError(error.WorkLimit, stopped.next());
        try std.testing.expectError(error.WorkLimit, stopped.next());
    }
    const Stop = struct {
        remaining: u32,
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
    };
    for ([_]u32{ 5, 110, 220, 300 }) |polls| {
        var stop: Stop = .{ .remaining = polls };
        var stopped = try view.attributes(.{ .cancellation = .{ .context = &stop, .is_requested = Stop.poll } });
        defer stopped.deinit();
        try std.testing.expectError(error.Cancelled, stopped.next());
        stop.remaining = 10_000;
        try std.testing.expectError(error.Cancelled, stopped.next());
    }
}

test "IR ordinary attribute iteration allocates nothing including inherited-only strict edges" {
    inline for (.{ "digraph {label=g; node[color=red]; a->b[weight=1]}", "strict digraph {label=g; node[color=red]; edge[weight=1]; a->b}" }) |source| {
        var ir = try lower(source);
        defer ir.deinit();
        const node = try ir.nodeView((try ir.findNode("a")).?);
        const root = try ir.scopeView(.root);
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        const edge = (try edges.next()).?;
        inline for (.{ node, root, edge }) |view| {
            var attributes = try view.attributes(.{ .limits = .{ .max_bytes = 0 } });
            defer attributes.deinit();
            try expect(try attributes.next() != null);
            try expect(try attributes.next() == null);
            try equal(@as(usize, 0), attributes.peakBytes());
        }
    }
}

test "IR attribute views preserve Unicode keys and native original spans" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const source = "strict graph { \"café\"=root; node[\"café\"=default]; a[\"café\"=\"😀\"]; a--b[\"café\"=link]; }";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var encoded: std.Io.Writer.Allocating = .init(a);
        defer encoded.deinit();
        var characters = (try std.unicode.Utf8View.init(source)).iterator();
        while (characters.nextCodepoint()) |cp| {
            if (E.width == 2) {
                if (cp <= 0xffff) {
                    try encoded.writer.writeInt(u16, @intCast(cp), E.endian);
                } else {
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
        const node = try ir.nodeView((try ir.findNode("a")).?);
        try checkAll(node, &.{"café"});
        try formatted("😀", (node.attribute("café")).?.value());
        try formatted("😀", node.attribute("café").?);
        const root = try ir.scopeView(.root);
        try checkAll(root, &.{"café"});
        try formatted("root", (root.attribute("café")).?.value());
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        const edge = (try edges.next()).?;
        try checkAll(edge, &.{"café"});
        const entry = (try edge.attribute("café")).?;
        try formatted("link", entry.value());
        try equal(@as(u32, 4 * E.width), entry.resolved.value.written.len);
    }
    var ir = try lower("graph {a[\"\xff\"=\"\xfe\"]}");
    defer ir.deinit();
    const node = try ir.nodeView((try ir.findNode("a")).?);
    try checkAll(node, &.{"\xff"});
    try formatted("\xfe", (node.attribute("\xff")).?.value());
}
