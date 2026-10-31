const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const IR = dot.ir.Lowering(.{});

fn lower(source: []const u8) !IR.Graph {
    var parsed = dot.parseAndValidate(a, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    if (!parsed.documentValid()) return error.BadFixture;
    return IR.lowerComplete(a, &parsed.document.?, .{ .interpretation = dot.Profile(.{}).interpretation(&parsed.document.?, .{}) });
}

test "sparse endpoint ports retain written occurrences and share chain middles" {
    var plain = try lower("digraph {a:p;b; a->b; b->c}");
    defer plain.deinit();
    // Node-statement suffixes do not contribute edge ports. Their syntax is
    // still in the caller's Document, not in the effective graph's port pool.
    try std.testing.expectEqual(@as(usize, 0), plain.endpoint_ports.len);
    try std.testing.expect(!plain.has_ports);
    try std.testing.expectEqual(@as(u32, 0), plain.capacities().endpoint_ports);
    for (plain.connections) |connection| {
        try std.testing.expectEqual(dot.ir.PortId.none, connection.left.port);
        try std.testing.expect(connection.right.portSyntax(&plain) == null);
    }

    var graph = try lower("digraph {a:p->b:\"q:r\":n->c:<>;a:p->c;{x->y:s}->z:t}");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 6), graph.endpoint_ports.len);
    try std.testing.expectEqual(@as(u32, 6), graph.capacities().endpoint_ports);
    try std.testing.expect(graph.has_ports);
    const first = graph.connections[0];
    const second = graph.connections[1];
    try std.testing.expectEqual(first.right.port, second.left.port);
    const middle = first.right.portSyntax(&graph).?;
    try std.testing.expectEqualStrings("\"q:r\"", graph.text(middle.first));
    try std.testing.expectEqualStrings("n", graph.text(middle.second.?));
    try std.testing.expectEqualStrings("<>", graph.text(second.right.portSyntax(&graph).?.first));
    // Same text at another source location must retain its own provenance.
    try std.testing.expect(first.left.port != graph.connections[2].left.port);
    try std.testing.expect(first.left.portSyntax(&graph).?.first.start != graph.connections[2].left.portSyntax(&graph).?.first.start);
}

fn check(graph: anytype, record: dot.ir.Edge, folded: anytype, key: []const u8, expected: ?[]const u8) !void {
    const compact = try graph.edgeAttribute(record, key);
    const materialized = folded.attribute(key);
    const view = try graph.edgeView(record);
    const port = if (std.mem.eql(u8, key, "tailport")) try view.tailPort() else try view.headPort();
    const folded_port = if (std.mem.eql(u8, key, "tailport")) folded.tailPort() else folded.headPort();
    try std.testing.expectEqualDeep(port, folded_port);
    try std.testing.expectEqual(compact, if (port) |found| found.resolved else null);
    try std.testing.expectEqual(compact, if (materialized) |value| value.resolved else null);
    if (expected) |text| {
        const value = graph.attributeValue(compact orelse return error.MissingPort);
        const joined = try value.toString(a);
        defer a.free(joined);
        try std.testing.expectEqualStrings(text, joined);
        var output: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try writer.print("{f}", .{value});
        try std.testing.expectEqualStrings(text, writer.buffered());
    } else try std.testing.expect(compact == null);
}

fn textEquals(expected: []const u8, text: anytype) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{text});
    try std.testing.expectEqualStrings(expected, writer.buffered());
    writer.end = 0;
    try text.writeLogical(&writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
    writer.end = 0;
    try text.writeLogicalWith(&writer, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "port syntax preserves components independently of Graphviz first-colon interpretation" {
    var ir = try lower("digraph {a:\"x:y\":n->b:<p>[headport=\"x\"+\":y:n\"]}");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    const tail = (try edge.tailPort()).?;
    const syntax = tail.syntax().?;
    try std.testing.expectEqualStrings("\"x:y\":n", syntax.raw());
    try textEquals("x:y", syntax.first());
    try textEquals("n", syntax.second().?);
    try std.testing.expectEqual(.n, syntax.compass().recognized);
    try std.testing.expectEqual(.n, (try syntax.compassWith(.{})).recognized);
    const head = (try edge.headPort()).?;
    try std.testing.expect(head.syntax() == null);
    for ([_]IR.Graph.PortView{ tail, head }) |port| {
        const split = port.graphvizParts();
        try std.testing.expectEqualDeep(split, try port.graphvizPartsWith(.{}));
        try textEquals("x", split.name());
        try textEquals("y:n", split.compassText().?);
        try textEquals("y:n", split.compass().unrecognized);
        try textEquals("y:n", (try split.compassWith(.{})).unrecognized);
        try std.testing.expect(split.asCompass() == null);
        try std.testing.expect(try split.asCompassWith(.{}) == null);
    }
    // An override does not destroy the original source endpoint.
    try std.testing.expectEqualStrings("<p>", ir.text(ir.connections[0].right.portSyntax(&ir).?.first));
}

test "port compass recognition preserves ambiguity absence and unsupported suffixes" {
    const Case = struct { value: []const u8, name: []const u8, suffix: ?[]const u8, candidate: ?dot.ir.Compass = null, compass: ?dot.ir.Compass = null };
    const cases = [_]Case{
        .{ .value = "n", .name = "n", .suffix = null, .candidate = .n },
        .{ .value = "_", .name = "_", .suffix = null, .candidate = .automatic },
        .{ .value = "N", .name = "N", .suffix = null },
        .{ .value = "", .name = "", .suffix = null },
        .{ .value = ":n", .name = "", .suffix = "n", .compass = .n },
        .{ .value = "p:", .name = "p", .suffix = "" },
        .{ .value = "p:N", .name = "p", .suffix = "N" },
        .{ .value = "p:middle", .name = "p", .suffix = "middle" },
        .{ .value = "p:n:e", .name = "p", .suffix = "n:e" },
        .{ .value = "p:_", .name = "p", .suffix = "_", .compass = .automatic },
        .{ .value = "p:ne", .name = "p", .suffix = "ne", .compass = .ne },
        .{ .value = "p:e", .name = "p", .suffix = "e", .compass = .e },
        .{ .value = "p:se", .name = "p", .suffix = "se", .compass = .se },
        .{ .value = "p:s", .name = "p", .suffix = "s", .compass = .s },
        .{ .value = "p:sw", .name = "p", .suffix = "sw", .compass = .sw },
        .{ .value = "p:w", .name = "p", .suffix = "w", .compass = .w },
        .{ .value = "p:nw", .name = "p", .suffix = "nw", .compass = .nw },
        .{ .value = "p:c", .name = "p", .suffix = "c", .compass = .c },
        .{ .value = "😀:東", .name = "😀", .suffix = "東" },
        .{ .value = "\xff:n", .name = "\xff", .suffix = "n", .compass = .n },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "digraph {{a->b[tailport=\"{s}\"]}}", .{case.value});
        defer a.free(source);
        var ir = try lower(source);
        defer ir.deinit();
        var edges = try ir.edgeIterator(.{});
        defer edges.deinit();
        const port = (try (try edges.next()).?.tailPort()).?;
        const split = port.graphvizParts();
        try textEquals(case.name, split.name());
        try std.testing.expectEqual(case.candidate, split.asCompass());
        try std.testing.expectEqual(case.candidate, try split.asCompassWith(.{}));
        if (case.suffix) |suffix| {
            try textEquals(suffix, split.compassText().?);
            if (case.compass) |compass| {
                try std.testing.expectEqual(compass, split.compass().recognized);
            } else try textEquals(suffix, split.compass().unrecognized);
        } else {
            try std.testing.expect(split.compassText() == null);
            try std.testing.expectEqual(.absent, split.compass());
            try std.testing.expectEqual(.absent, try split.compassWith(.{}));
        }
    }
}

test "port views retain stored orientation introduction empties and IR-only lifetimes" {
    var ir = try lower("strict graph {edge[headport=base];a:p--b:q;b:r--a:s;c--d;e--f[tailport=\"\"]}");
    defer ir.deinit();
    const retained = ir.retainedBytes();
    var saved: [3]IR.Graph.PortView = undefined;
    {
        var folded = try ir.materialize(.{});
        defer folded.deinit();
        var edges = folded.edgeIterator();
        const first = edges.next().?;
        saved[0] = first.tailPort().?;
        try std.testing.expectEqual(dot.ir.AttributeOrigin{ .written_right_port = @fromBackingInt(1) }, saved[0].resolved.origin);
        try textEquals("s", saved[0].syntax().?.first());
        try std.testing.expectEqual(.absent, saved[0].syntax().?.compass());
        try std.testing.expect(saved[0].syntax().?.second() == null);
        try std.testing.expectEqual(.s, saved[0].syntax().?.first().asCompass());
        try std.testing.expectEqual(dot.ir.AttributeOrigin{ .written_left_port = @fromBackingInt(1) }, first.headPort().?.resolved.origin);
        try std.testing.expectEqual((try ir.findNode("a")).?, first.from().id);
        try std.testing.expectEqual((try ir.findNode("b")).?, first.to().id);
        const second = edges.next().?;
        saved[1] = second.tailPort().?;
        try std.testing.expectEqual(.empty, saved[1].resolved.kind);
        try std.testing.expect(saved[1].syntax() == null);
        try std.testing.expect(saved[1].value().raw() == null);
        try std.testing.expectEqual(.inherited, second.headPort().?.resolved.kind);
        try std.testing.expect(second.headPort().?.syntax() == null);
        saved[2] = edges.next().?.tailPort().?;
        try std.testing.expectEqual(.explicit, saved[2].resolved.kind);
        try std.testing.expectEqualStrings("\"\"", saved[2].value().raw().?);
        try std.testing.expect(saved[2].syntax() == null);
    }
    try textEquals("s", saved[0].syntax().?.first());
    for (saved[1..]) |port| try textEquals("", port.graphvizParts().name());
    try std.testing.expectEqual(retained, ir.retainedBytes());

    var only_suffix = try lower("digraph {a:<p>->b;c->d}");
    defer only_suffix.deinit();
    var edges = try only_suffix.edgeIterator(.{});
    defer edges.deinit();
    const first = (try edges.next()).?;
    try textEquals("p", (try first.tailPort()).?.syntax().?.first());
    try std.testing.expect(try first.headPort() == null);
    const empty = (try (try edges.next()).?.tailPort()).?;
    try std.testing.expectEqual(.written_left_port, std.meta.activeTag(empty.resolved.origin));
    try std.testing.expect(empty.syntax() == null); // Introduction provenance is not this edge's value.
}

test "endpoint precedence and orientation match pinned Graphviz 16 cgraph probes" {
    const Case = struct { source: []const u8, tail: ?[]const u8, head: ?[]const u8 };
    const cases = [_]Case{
        .{ .source = "digraph {edge[tailport=default headport=default];a:p:n->b:q:s}", .tail = "p:n", .head = "q:s" },
        .{ .source = "digraph {a:p->b:q[tailport=x headport=y]}", .tail = "x", .head = "y" },
        .{ .source = "strict digraph {a:p->b:q;a->b:r;a->b[color=blue]}", .tail = "p", .head = "r" },
        .{ .source = "strict graph {a:p--b:q;b:r--a:s}", .tail = "s", .head = "r" },
        .{ .source = "strict graph {a:p--b:q;b:r--a:s[tailport=x]}", .tail = "x", .head = "r" },
        .{ .source = "strict graph {a:p--a:q;a:r--a:s}", .tail = "r", .head = "s" },
        .{ .source = "digraph {a:\"p\"+\"ort\":n->b:<q>}", .tail = "port:n", .head = "q" },
        .{ .source = "digraph {a:p->{};c->d}", .tail = null, .head = null },
        .{ .source = "digraph {a->b;c:p->d}", .tail = "", .head = null },
        .{ .source = "strict graph {a--b;b:p--a}", .tail = null, .head = "p" },
        .{ .source = "strict graph {b--a;a:p--b}", .tail = null, .head = "p" },
        .{ .source = "strict graph {a--b;a:p--b}", .tail = "p", .head = null },
        .{ .source = "digraph {edge[tailport=n];a:\"\"->b[headport=\"\"]}", .tail = "", .head = "" },
        .{ .source = "strict digraph {a:p->b;edge[tailport=new];a->b}", .tail = "p", .head = null },
        .{ .source = "strict digraph {a->b[tailport=old];a:p->b}", .tail = "p", .head = null },
        .{ .source = "digraph {a:p->b[\"tail\"+\"port\"=x tailport=y]}", .tail = "y", .head = null },
    };
    for (cases) |case| {
        var ir = try lower(case.source);
        defer ir.deinit();
        var materialized = try ir.materialize(.{});
        defer materialized.deinit();
        var iterator = materialized.edgeIterator();
        const first = iterator.next().?;
        try check(&ir, first.edge, first, "tailport", case.tail);
        try check(&ir, first.edge, first, "headport", case.head);
        try @import("ir_materialized_attributes.zig").compare(&ir);
    }
}

test "derived ports retain raw components and provide one logical string operand" {
    var ir = try lower("digraph { a:\"p\" + \"ort\" /* gap */ : n -> b:<p> }");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()).?;
    const attribute = (try edge.attribute("tailport")).?;
    try std.testing.expectEqual(.derived, attribute.resolved.kind);
    try std.testing.expect(attribute.resolved.attribute == null);
    try std.testing.expectEqual(dot.ir.AttributeOrigin{ .written_left_port = @fromBackingInt(0) }, attribute.resolved.origin);
    const value = attribute.value();
    try std.testing.expectEqual(.string, value.kind());
    try std.testing.expectEqualStrings("\"p\" + \"ort\" /* gap */ : n", value.raw().?);
    const port = (try edge.tailPort()).?;
    try std.testing.expectEqual(attribute.resolved, port.resolved);
    try std.testing.expectEqual(ir.connections[0].left.portSyntax(&ir).?, port.syntax().?.spans);
    try std.testing.expect(!@hasDecl(IR.Graph.ValueView, "endpointPort"));
    try std.testing.expect(!@hasDecl(IR.Graph.OperandView, "endpointPort"));
    var parts = value.parts();
    const part = parts.next().?;
    try std.testing.expectEqual(.string, part.kind());
    try std.testing.expect(part.form() == null and part.fragment() == null and parts.next() == null);
    try std.testing.expectEqual(value.span(), part.span());
    var out: [100]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try writer.print("{f}", .{part});
    try std.testing.expectEqualStrings("port:n", writer.buffered());
    const head = (try edge.attribute("headport")).?.value();
    try std.testing.expectEqual(.string, head.kind());
    var head_parts = head.parts();
    try std.testing.expect(head_parts.next().?.fragment() == null); // <p> is a port identifier, not a label.
    try std.testing.expectEqualStrings("<p>", head.raw().?);
    try std.testing.expectError(error.WorkLimit, value.toStringWith(a, .{ .limits = .{ .max_work = 0 } }));
    try std.testing.expectError(error.MemoryLimit, value.toStringWith(a, .{ .limits = .{ .max_bytes = 0 } }));
}

test "chains set endpoints strict reversals and implicit port empties agree across paths" {
    const cases = [_][]const u8{
        "digraph {a:p->b:q:n->c:r}",
        "digraph {a:p->{b c}->d:q}",
        "strict graph {a:p--{b c};b:q--a:r;c:s--a}",
        "strict graph {{b a}--{b a};a:p--b}",
        "strict graph {{a b}--{a b};b:p--a}",
        "strict graph {x--y;{b a}--{b a};a:p--b}",
        "strict graph {x--y;{a b}--{a b};b:p--a}",
        "digraph {a:p->{};{}->b:q; c->d}",
        "digraph {a:p; b:q; a->b}",
        "digraph {subgraph s{a};x:p->subgraph s{};subgraph s{b};subgraph s{}->y:q}",
        "strict graph {a--b[headport=x];b:p--a[tailport=\"\"]}",
    };
    for (cases) |source| {
        var ir = try lower(source);
        defer ir.deinit();
        try @import("ir_materialized_attributes.zig").compare(&ir);
    }
}

test "port cells respect limits and no port products are expanded during lowering" {
    var ir = try lower("strict graph {a:p--b:q;b:r--a:s}");
    defer ir.deinit();
    var materialized = try ir.materialize(.{ .limits = .{ .max_attribute_states = 2 } });
    defer materialized.deinit();
    try std.testing.expectError(error.AttributeStateLimit, ir.materialize(.{ .limits = .{ .max_attribute_states = 1 } }));
    try std.testing.expectError(error.MemoryLimit, ir.materialize(.{ .limits = .{ .max_bytes = 0 } }));
    try std.testing.expectError(error.WorkLimit, ir.materialize(.{ .limits = .{ .max_work = 0 } }));
    var topology = try ir.materialize(.{ .attributes = false, .limits = .{ .max_attribute_states = 0 } });
    defer topology.deinit();
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    const token: dot.ir.Cancellation = .{ .context = null, .is_requested = Stop.poll };
    try std.testing.expectError(error.Cancelled, ir.materialize(.{ .cancellation = token }));
    try std.testing.expectError(error.Cancelled, ir.edgeAttributeWith(topology.edges[0], "headport", .{ .cancellation = token }));
}

test "synthetic-key discovery is cancellable at every boundary and iterator errors are terminal" {
    var ir = try lower("strict graph {x--y; a--{b c}; b:p--a; c:q--a}");
    defer ir.deinit();
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    const first = (try edges.next()).?;
    const Cancel = struct {
        polls: u32 = 0,
        stop: u32 = std.math.maxInt(u32),
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.polls += 1;
            return self.polls >= self.stop;
        }
        fn token(self: *@This()) dot.ir.Cancellation {
            return .{ .context = self, .is_requested = poll };
        }
    };
    var cancellation: Cancel = .{};
    const found = (try first.attributeWith("headport", .{ .cancellation = cancellation.token() })).?;
    try std.testing.expectEqual(.empty, found.resolved.kind);
    try std.testing.expect(found.resolved.attribute == null);
    const polls = cancellation.polls;
    for (1..polls + 1) |stop| {
        cancellation = .{ .stop = @intCast(stop) };
        try std.testing.expectError(error.Cancelled, first.attributeWith("headport", .{ .cancellation = cancellation.token() }));
    }
    var attributes = try first.attributes(.{ .limits = .{ .max_work = 1 } });
    defer attributes.deinit();
    try std.testing.expectError(error.WorkLimit, attributes.next());
    try std.testing.expectError(error.WorkLimit, attributes.next());
    try std.testing.expectEqual(@as(usize, 0), attributes.peakBytes());
}

test "bounded port helpers share attribute limits and poll throughout logical rereads" {
    const padding: [1024]u8 = @splat('p');
    var ir = try lower("digraph {a:\"" ++ padding ++ "\":n->b:<q>}");
    defer ir.deinit();
    var materialized = try ir.materialize(.{});
    defer materialized.deinit();
    var edges = materialized.edgeIterator();
    const folded = edges.next().?;
    const compact = try ir.edgeView(folded.edge);
    try std.testing.expectEqualDeep(folded.tailPort(), try folded.tailPortWith(.{}));
    try std.testing.expectEqualDeep(folded.headPort(), try folded.headPortWith(.{}));
    try std.testing.expectEqualDeep(folded.tailPort(), try compact.tailPortWith(.{}));
    try std.testing.expectEqualDeep(folded.headPort(), try compact.headPortWith(.{}));
    const no_work: dot.ir.Options = .{ .limits = .{ .max_work = 0 } };
    try std.testing.expectError(error.WorkLimit, compact.tailPortWith(no_work));
    try std.testing.expectError(error.WorkLimit, compact.headPortWith(no_work));
    try std.testing.expectError(error.WorkLimit, folded.tailPortWith(no_work));
    try std.testing.expectError(error.WorkLimit, folded.headPortWith(no_work));
    const port = folded.tailPort().?;
    const syntax = port.syntax().?;
    const split = port.graphvizParts();
    try std.testing.expectError(error.WorkLimit, port.graphvizPartsWith(no_work));
    try std.testing.expectError(error.WorkLimit, syntax.compassWith(no_work));
    try std.testing.expectError(error.WorkLimit, split.compassWith(no_work));
    var output: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.testing.expectError(error.WorkLimit, split.name().writeLogicalWith(&writer, no_work));
    writer.end = 0;
    try split.name().writeLogicalWith(&writer, .{});
    try std.testing.expectEqualStrings(&padding, writer.buffered());
    try textEquals("n", split.compassText().?);
    var tiny = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, split.name().writeLogical(&tiny));
    try std.testing.expectError(error.WriteFailed, split.name().writeLogicalWith(&tiny, .{}));

    const Cancel = struct {
        polls: u32 = 0,
        stop: u32 = std.math.maxInt(u32),
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.polls += 1;
            return self.polls >= self.stop;
        }
        fn options(self: *@This()) dot.ir.Options {
            return .{ .cancellation = .{ .context = self, .is_requested = poll } };
        }
    };
    inline for (.{ "split", "text", "syntax_compass", "split_compass", "candidate" }) |operation| {
        var cancel: Cancel = .{};
        const Run = struct {
            fn run(p: IR.Graph.PortView, w: *std.Io.Writer, options: dot.ir.Options) !void {
                if (comptime std.mem.eql(u8, operation, "split")) {
                    _ = try p.graphvizPartsWith(options);
                } else if (comptime std.mem.eql(u8, operation, "text")) {
                    try p.graphvizParts().name().writeLogicalWith(w, options);
                } else if (comptime std.mem.eql(u8, operation, "syntax_compass")) {
                    _ = try p.syntax().?.compassWith(options);
                } else if (comptime std.mem.eql(u8, operation, "split_compass")) {
                    _ = try p.graphvizParts().compassWith(options);
                } else {
                    _ = try p.syntax().?.first().asCompassWith(options);
                }
            }
        };
        writer.end = 0;
        try Run.run(port, &writer, cancel.options());
        const polls = cancel.polls;
        try std.testing.expect(polls > 1);
        for (1..polls + 1) |stop| {
            cancel = .{ .stop = @intCast(stop) };
            writer.end = 0;
            try std.testing.expectError(error.Cancelled, Run.run(port, &writer, cancel.options()));
        }
    }
    var cancel: Cancel = .{ .stop = 1 };
    try std.testing.expectError(error.Cancelled, compact.tailPortWith(cancel.options()));
    try std.testing.expectError(error.Cancelled, compact.headPortWith(cancel.options()));
    try std.testing.expectError(error.Cancelled, folded.tailPortWith(cancel.options()));
    try std.testing.expectError(error.Cancelled, folded.headPortWith(cancel.options()));
    // Absent/candidate short paths still honor cancellation at entry.
    try std.testing.expectError(error.Cancelled, split.asCompassWith(cancel.options()));
    const head = folded.headPort().?;
    try std.testing.expectError(error.Cancelled, head.syntax().?.compassWith(cancel.options()));
    try std.testing.expectError(error.Cancelled, head.graphvizParts().compassWith(cancel.options()));
    try std.testing.expectError(error.Cancelled, head.graphvizParts().asCompassWith(cancel.options()));
}

test "native port text windows preserve source spans and split logical UTF-8 across operands" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf16, .utf32 } });
    const source = "digraph {a:\"埠😀:x\":ne->b[headport=\"終😀\"+\":\"+\"sw\"]}";
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
        try std.testing.expect(parsed.documentValid());
        var ir = try Native.lowerComplete(a, &parsed.document.?, .{ .interpretation = P.interpretation(&parsed.document.?, .{}) });
        defer ir.deinit();
        var folded = try ir.materialize(.{});
        defer folded.deinit();
        var edges = folded.edgeIterator();
        const edge = edges.next().?;
        const compact = try ir.edgeView(edge.edge);
        const tail = edge.tailPort().?;
        try std.testing.expectEqualDeep(tail, (try compact.tailPort()).?);
        try std.testing.expectEqualDeep(edge.headPort(), try compact.headPort());
        const syntax = tail.syntax().?;
        try std.testing.expectEqualStrings(ir.text(syntax.span()), syntax.raw());
        try std.testing.expectEqual(@as(u32, 11 * E.width), syntax.spans.first.start);
        try textEquals("埠😀:x", syntax.first());
        try textEquals("ne", syntax.second().?);
        try std.testing.expectEqual(.ne, (try syntax.compassWith(.{})).recognized);
        const split = try tail.graphvizPartsWith(.{});
        try std.testing.expectEqualDeep(tail.graphvizParts(), split);
        try textEquals("埠😀", split.name());
        try textEquals("x:ne", split.compass().unrecognized);
        try textEquals("x:ne", (try split.compassWith(.{})).unrecognized);
        const head = edge.headPort().?;
        try std.testing.expect(head.syntax() == null);
        const head_parts = try head.graphvizPartsWith(.{});
        try textEquals("終😀", head_parts.name());
        try std.testing.expectEqual(.sw, (try head_parts.compassWith(.{})).recognized);
    }
}
