const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});
const EventIR = IR.FromEvents(dot.Profile(.{}));
test {
    _ = @import("ir_event_observer.zig");
}

test "event IR lowers without Document storage" {
    const source = "digraph G { a -> { b c }; \"a\" -> d; subgraph s { x } }";
    var result = try EventIR.parse(std.testing.allocator, source, .{});
    defer result.deinit();
    const graph = result.ir().?;
    try std.testing.expectEqual(@as(usize, 5), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), graph.connections.len);
    try std.testing.expect(result.checking.validation.?.documentValid());
}

test "event IR observing preserves full and topology graph semantics" {
    const Observer = struct {
        pub const observations = dot.events.Observations.all;
        pub const statement_extents = true;
        pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    const source = "strict graph {node[color=red];edge[weight=2];a:p--subgraph s{b;c};subgraph s{d};b:q--a:r[label=x];a[label=\"x\"+\"y\"]}";
    inline for (.{ true, false }) |attributes| {
        const L = dot.ir.Lowering(.{ .capabilities = .{ .attributes = attributes }, .indexes = .{ .connections = true, .scope_memberships = true } });
        const E = L.FromEvents(dot.Profile(.{}));
        var base = try E.parse(a, source, .{});
        defer base.deinit();
        var observer: Observer = .{};
        var observed = try E.Observe(Observer).parse(a, source, .{ .observer = &observer });
        defer observed.deinit();
        try sameGraphs(base.ir().?, observed.ir().?);
        try std.testing.expectEqualDeep(base.checking, observed.checking);
    }
}

test "event IR page boundaries preserve ports, attributes and reopened memberships" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph { node[color=red]; edge[weight=2]; ");
    for (0..16 * 1024 + 7) |i| try source.writer.print("n{d}:p -> n{d} [label=x];", .{ i, i + 1 });
    try source.writer.writeAll("subgraph s{x}; a -> subgraph s{b} -> subgraph s{c}; }");
    try pair(.{}, dot.Profile(.{}), source.written());
    try pair(.{ .capabilities = .{ .attributes = false }, .indexes = .{ .connections = true, .scope_memberships = true } }, dot.Profile(.{}), source.written());
}

test "event IR cancellation during publication of construction pages frees every pool" {
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph {");
    for (0..16 * 1024 + 7) |i| try source.writer.print("n{d}->n{d};", .{ i, i + 1 });
    try source.writer.writeAll("}");
    const E = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .cancellation = true } } }).FromEvents(dot.Profile(.{}));
    const Counter = struct {
        calls: usize = 0,
        stop: usize = std.math.maxInt(usize),
        fn check(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls == self.stop;
        }
    };
    var counter: Counter = .{};
    const hook: dot.Cancellation = .{ .context = &counter, .is_requested = Counter.check };
    var result = try E.parse(a, source.written(), .{ .lowering = .{ .cancellation = hook } });
    result.deinit();
    const total = counter.calls;
    for ([_]usize{ total / 2, total - 30_000, total - 1, total }) |stop| {
        counter = .{ .stop = stop };
        try std.testing.expectError(error.Cancelled, E.parse(a, source.written(), .{ .lowering = .{ .cancellation = hook } }));
        try std.testing.expectEqual(stop, counter.calls);
    }
}

const a = std.testing.allocator;
fn sameAttribute(left: anytype, right: @TypeOf(left)) !void {
    try std.testing.expectEqual(left == null, right == null);
    if (left) |l| {
        const rr = right.?;
        const x = try std.fmt.allocPrint(a, "{f}", .{l.value()});
        defer a.free(x);
        const y = try std.fmt.allocPrint(a, "{f}", .{rr.value()});
        defer a.free(y);
        try std.testing.expectEqualStrings(x, y);
        try std.testing.expectEqual(l.value().kind(), rr.value().kind());
    }
}
pub fn sameGraphs(left: anytype, right: @TypeOf(left)) !void {
    try std.testing.expectEqual(left.kind, right.kind);
    try std.testing.expectEqual(left.strict, right.strict);
    try std.testing.expectEqual(left.nodes.len, right.nodes.len);
    try std.testing.expectEqualDeep(left.mentions, right.mentions);
    try std.testing.expectEqualDeep(left.occurrences, right.occurrences);
    try std.testing.expectEqualDeep(left.bodies, right.bodies);
    try std.testing.expectEqualDeep(left.scopes, right.scopes);
    try std.testing.expectEqualDeep(left.endpoint_ports, right.endpoint_ports);
    try std.testing.expectEqual(left.connections.len, right.connections.len);
    for (left.connections, right.connections) |l, rr| {
        try std.testing.expectEqualDeep(l.left, rr.left);
        try std.testing.expectEqualDeep(l.right, rr.right);
        try std.testing.expectEqualDeep(l.operator_source, rr.operator_source);
        try std.testing.expectEqual(l.written_operator, rr.written_operator);
        try std.testing.expectEqual(l.effective_operator, rr.effective_operator);
    }
    var lnodes = left.nodeIterator();
    var rnodes = right.nodeIterator();
    while (lnodes.next()) |node| {
        const other = rnodes.next().?;
        try std.testing.expectEqualDeep(left.nodes[@backingInt(node.id)].name, right.nodes[@backingInt(other.id)].name);
        if (@TypeOf(left.attribute_data) != void) inline for (.{ "color", "shape", "label", "weight", "x", "tailport", "headport" }) |key| try sameAttribute(node.attribute(key), other.attribute(key));
    }
    if (@TypeOf(left.attribute_data) != void) for (0..left.scopes.len) |i| {
        const id: dot.ir.ScopeId = @fromBackingInt(@as(u32, @intCast(i)));
        const scope = try left.scopeView(id);
        const other = try right.scopeView(id);
        inline for (.{ "color", "label", "x" }) |key| try sameAttribute(scope.attribute(key), other.attribute(key));
    };
    var le = try left.edgeIterator(.{});
    defer le.deinit();
    var re = try right.edgeIterator(.{});
    defer re.deinit();
    while (try le.next()) |edge| {
        const other = (try re.next()).?;
        try std.testing.expectEqual(edge.from().id, other.from().id);
        try std.testing.expectEqual(edge.to().id, other.to().id);
        if (@TypeOf(left.attribute_data) != void) inline for (.{ "color", "shape", "label", "weight", "x", "tailport", "headport" }) |key| try sameAttribute(try edge.attribute(key), try other.attribute(key));
    }
    try std.testing.expect((try re.next()) == null);
}
fn pair(comptime Config: dot.ir.Config, comptime Dot: type, source: []const u8) !void {
    const Lower = dot.ir.Lowering(Config);
    var doc_bag = dot.FixedDiagnosticBag(128){};
    var keys: [256]dot.AttributeKeyScratch = undefined;
    var parsed = Dot.parseAndValidate(a, source, doc_bag.sink(), .{ .validation = .{ .attribute_keys = &keys } });
    defer parsed.deinit(a);
    var event_bag = dot.FixedDiagnosticBag(128){};
    var event = try Lower.FromEvents(Dot).parse(a, source, .{ .diagnostics = event_bag.sink() });
    defer event.deinit();
    try std.testing.expectEqual(parsed.documentValid(), event.ir() != null);
    try std.testing.expectEqual(doc_bag.items().len, event_bag.items().len);
    for (doc_bag.items()) |d| {
        var found = false;
        for (event_bag.items()) |other| if (d.code == other.code and d.span.start == other.span.start and d.span.len == other.span.len) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }
    if (!parsed.documentValid()) return;
    var graph = try Lower.lowerComplete(a, &parsed.document.?, .{ .interpretation = Dot.interpretation(&parsed.document.?, .{}) });
    defer graph.deinit();
    try sameGraphs(@as(*const Lower.Graph, &graph), event.ir().?);
}

test "event IR agrees on endpoint execution, creation defaults, ports and reopened versions" {
    const Dot = dot.Profile(.{});
    const cases = [_][]const u8{
        "digraph {}",
        "digraph { a -> { node[color=red]; a; } }",
        "digraph { node[color=red]; a; node[color=blue]; b; a[shape=box]; a->b[weight=2]; }",
        "digraph { a:p:n -> b:q -> c:r; a [label=\"x\"+\"y\"]; b[label=<<b>x</b>>] }",
        "strict graph { edge[color=red]; a:p--b:q; edge[color=blue]; b:r--a:s[label=updated]; a--c[color=green] }",
        "digraph { subgraph s { a } -> subgraph s {b}; x->subgraph s{}; subgraph s{c}->x }",
        "digraph { node[color=red]; subgraph s{ a; node[shape=box]; { b } } node[color=blue]; subgraph s{ c } }",
        "digraph { a -> {b c} -> {d e} -> f; {g}->h->{i}->j }",
        "digraph { x=one; subgraph s{x=two; a} x=three; subgraph s{b} graph[label=last] }",
        "digraph {a;{b;{c;{d}}} a->a; \"a\"->a}",
    };
    inline for (.{ true, false }) |attributes| for (cases) |source| try pair(.{ .capabilities = .{ .attributes = attributes }, .indexes = .{ .connections = true, .scope_memberships = true } }, Dot, source);
}

test "event IR validates active rules even without retained attributes" {
    const Dot = dot.Profile(.{ .policy = .{ .validation = .{
        .repeated_attribute = .warning,
        .invalid_encoding = .warning,
        .graphviz = .{ .unknown_attribute = .warning },
        .restrictions = .{ .ports = .warning, .subgraphs = .warning, .graph_kinds = .{ .digraph = .warning } },
    } } });
    inline for (.{ true, false }) |attributes| try pair(.{ .capabilities = .{ .attributes = attributes } }, Dot, "digraph { a:p [label=x label=y x=z]; subgraph s{ b } a->b:q[bad=v] }");
    try pair(.{}, dot.Profile(.{}), "graph {a->b;c->d}");
    try pair(.{}, dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } } }), "graph {a--b;c->d}");
    try pair(.{}, dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .digraph, .operator_mismatch = .warning, .operator_reading = .conform_to_kind } } } }), "graph {a--b;c->d}");
}

test "event IR agrees for both scanners, metering and accepted deviations" {
    inline for (.{ dot.ScannerBackend.scalar, dot.ScannerBackend.block }) |scanner| inline for (.{ false, true }) |metered| {
        const settings = comptime blk: {
            var settings = dot.presets.lenient;
            settings.scanner = scanner;
            settings.execution.metering = metered;
            break :blk settings;
        };
        try pair(.{}, dot.Profile(.{ .policy = settings }), "graph { ; a - b; a --- c; { d;; } -- e; }");
    };
}

test "event IR rejects syntax without publishing staged nodes" {
    for ([_][]const u8{ "digraph {a-> {node[color=red];a;} -> ;}", "digraph {a[x=;b;}", "digraph {a; \"unfinished", "not a graph" }) |source| {
        var result = try EventIR.parse(a, source, .{});
        defer result.deinit();
        try std.testing.expect(result.ir() == null);
    }
}

test "event IR runtime policies resolve independently, including one-shot metering" {
    const Dot = dot.Profile(.{ .runtime_policy = true });
    const Lower = dot.ir.Lowering(.{ .runtime_policy = true });
    const E = Lower.FromEvents(Dot);
    try std.testing.expect(@hasDecl(E, "Session"));
    var result = try E.parse(a, "graph{a->b}", .{
        .dot = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } }, .execution = .{ .metering = true } } },
        .lowering = .{ .policy = .{ .execution = .{ .metering = true } } },
    });
    defer result.deinit();
    try std.testing.expectEqual(.generic, result.ir().?.kind);
    try std.testing.expectError(error.InvalidCancellationInterval, E.parse(a, "digraph{}", .{ .lowering = .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } } }));
}

test "event IR total limits and allocation failures never publish or leak" {
    const source = "digraph{node[color=red]; a:p->subgraph s{b;x=one}->{c;d};a->b[label=x]}";
    try std.testing.expectError(error.WorkLimit, EventIR.parse(a, source, .{ .lowering = .{ .limits = .{ .max_work = 1 } } }));
    try std.testing.expectError(error.MemoryLimit, EventIR.parse(a, source, .{ .lowering = .{ .limits = .{ .max_bytes = 0 } } }));
    try std.testing.expectError(error.NodeLimit, EventIR.parse(a, source, .{ .lowering = .{ .limits = .{ .max_nodes = 1 } } }));
    try std.testing.expectError(error.ConnectionLimit, EventIR.parse(a, source, .{ .lowering = .{ .limits = .{ .max_connections = 0 } } }));
    const Run = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var result = try EventIR.parse(allocator, source, .{});
            defer result.deinit();
            if (result.checking.outcome == .storage_failure) return error.OutOfMemory;
            try std.testing.expect(result.ir() != null);
        }
    };
    try std.testing.checkAllAllocationFailures(a, Run.run, .{});
}

test "event IR preserves sink failure and stops at validation fail-fast" {
    const Dot = dot.Profile(.{ .policy = .{ .on_error = .fail_fast } });
    var bag = dot.FixedDiagnosticBag(8){};
    var result = try IR.FromEvents(Dot).parse(a, "graph{a->b;c->d}", .{ .diagnostics = bag.sink() });
    defer result.deinit();
    try std.testing.expect(result.ir() == null);
    try std.testing.expectEqual(@as(usize, 1), bag.items().len);
    try std.testing.expectEqual(.error_stopped, std.meta.activeTag(result.checking.validation.?.outcome));
    const Sink = struct {
        fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.diagnostic.SinkError!dot.diagnostic.Action {
            return error.DiagnosticSinkFailure;
        }
    };
    var stopped = try EventIR.parse(a, "graph{a->b;c->d}", .{ .diagnostics = .{ .context = null, .emit_fn = Sink.emit } });
    defer stopped.deinit();
    try std.testing.expect(stopped.ir() == null);
    try std.testing.expectEqual(.failed, stopped.checking.diagnostic_delivery);
    try std.testing.expect(stopped.checking.diagnostic_stop != null);
}

test "event IR cancellation covers construction and the final validation pass" {
    const Dot = dot.Profile(.{ .policy = .{ .execution = .{ .cancellation = true }, .validation = .{ .invalid_encoding = .err } } });
    const Lower = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .cancellation = true } } });
    const E = Lower.FromEvents(Dot);
    const Cancel = struct {
        calls: u32 = 0,
        limit: u32,
        fn check(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls >= self.limit;
        }
    };
    for ([_]u32{ 1, 8, 64, 256 }) |limit| {
        var c: Cancel = .{ .limit = limit };
        const hook: dot.Cancellation = .{ .context = &c, .is_requested = Cancel.check };
        const source = "digraph { a -> b [label=\"a long quoted value with unicode café\"]; c->d; e->f; g->h; i->j; k->l }";
        try std.testing.expectError(error.Cancelled, E.parse(a, source, .{ .lowering = .{ .cancellation = hook } }));
        try std.testing.expectEqual(limit, c.calls);
        c.calls = 0;
        try std.testing.expectError(error.Cancelled, E.parse(a, source, .{ .dot = .{ .cancellation = hook } }));
    }
}

test "event IR native sources and encoding scopes agree with Document checking" {
    const Dot = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .validation = .{ .invalid_encoding = .err } } });
    const Lower = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    const text = "digraph G {node[color=red]; a:p->subgraph s{b}; subgraph s{c}; a[label=<<b>x</b>>]}";
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const width = if (actual == .utf16le or actual == .utf16be) 2 else 4;
        const endian = if (actual == .utf16le or actual == .utf32le) std.builtin.Endian.little else .big;
        var source: [text.len * width]u8 = undefined;
        for (text, 0..) |ch, i| std.mem.writeInt(if (width == 2) u16 else u32, source[i * width ..][0..width], ch, endian);
        var doc = try Dot.parseAndValidate(a, &source, dot.diagnostic.discard, .{ .encoding = actual });
        defer doc.deinit(a);
        var graph = try Lower.lowerComplete(a, &doc.document.?, .{ .interpretation = Dot.interpretation(&doc.document.?, .{}) });
        defer graph.deinit();
        var result = try Lower.FromEvents(Dot).parse(a, &source, .{ .dot = .{ .encoding = actual } });
        defer result.deinit();
        try sameGraphs(@as(*const Lower.Graph, &graph), result.ir().?);
    }
    const Checked = dot.Profile(.{ .policy = .{ .validation = .{ .invalid_encoding = .err } } });
    try pair(.{}, Checked, "digraph {a[label=<\xff>]} // \xff");
    try pair(.{}, Checked, "digraph {a[label=<\xff>]}");
    const Ascii = dot.Profile(.{ .source_encodings = &.{}, .policy = .{ .validation = .{ .invalid_encoding = .err } } });
    var result = try IR.FromEvents(Ascii).parse(a, "digraph {café}", .{});
    defer result.deinit();
    try std.testing.expect(result.ir() == null);
}

test "event IR generated nesting, reopens, mixed chains and strict updates match" {
    var state: u64 = 0x3c578abb;
    for (0..180) |sample| {
        var source: std.Io.Writer.Allocating = .init(a);
        defer source.deinit();
        const w = &source.writer;
        try w.writeAll(if (sample % 2 == 0) "strict digraph{" else "digraph{");
        for (0..24) |_| {
            state = state *% 6364136223846793005 +% 1;
            const n = (state >> 32) % 9;
            const other = (state >> 40) % 9;
            switch (state % 7) {
                0 => try w.print("n{d}[color=c{d}];", .{ n, other }),
                1 => try w.print("node[color=c{d}];n{d};", .{ n, other }),
                2 => try w.print("n{d}:p:n -> n{d}:q[label=l{d}];", .{ n, other, n }),
                3 => try w.print("subgraph s{d}{{node[shape=box];n{d};{{n{d}}}}}", .{ n % 3, n, other }),
                4 => try w.print("subgraph s{d}{{n{d}}}->subgraph s{d}{{n{d}}};", .{ n % 3, n, n % 3, other }),
                5 => try w.print("n{d}->{{n{d};n{d};}}->n{d}[weight=2];", .{ n, other, n, other }),
                else => try w.print("x=v{d};edge[color=c{d}];", .{ n, other }),
            }
        }
        try w.writeAll("}");
        try pair(.{}, dot.Profile(.{}), source.written());
    }
}

test "event IR native invalid names retain encoding diagnostics before semantic failure" {
    const Dot = dot.Profile(.{ .source_encodings = &.{.utf16}, .policy = .{ .validation = .{ .invalid_encoding = .err } } });
    const Lower = dot.ir.Lowering(.{ .source_encodings = &.{.utf16} });
    for ([_][]const u8{ "digraph X{a}", "digraph{subgraph X{a}}", "digraph{X}", "digraph{a[X=v]}" }) |text| {
        const source = try a.alloc(u8, text.len * 2);
        defer a.free(source);
        for (text, 0..) |ch, i| std.mem.writeInt(u16, source[i * 2 ..][0..2], if (ch == 'X') 0xd800 else ch, .little);
        var bag = dot.FixedDiagnosticBag(8){};
        var result = try Lower.FromEvents(Dot).parse(a, source, .{ .dot = .{ .encoding = .utf16le }, .diagnostics = bag.sink() });
        defer result.deinit();
        try std.testing.expect(result.ir() == null);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        try std.testing.expectEqual(.validation_invalid_encoding, bag.items()[0].code);
    }
}
