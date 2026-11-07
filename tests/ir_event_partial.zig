const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqualDeep;

fn attribute(left: anytype, right: @TypeOf(left)) !void {
    try equal(std.meta.activeTag(left), std.meta.activeTag(right));
    const l = if (left == .known) left.known else left.unknown.retained;
    const rr = if (right == .known) right.known else right.unknown.retained;
    if (left == .unknown) try equal(left.unknown.uncertainty, right.unknown.uncertainty);
    try equal(l == null, rr == null);
    if (l) |lv| {
        try equal(lv.resolved, rr.?.resolved);
        var lb: [256]u8 = undefined;
        var rb: [256]u8 = undefined;
        var lw = std.Io.Writer.fixed(&lb);
        var rw = std.Io.Writer.fixed(&rb);
        try lw.print("{f}", .{lv});
        try rw.print("{f}", .{rr.?});
        try std.testing.expectEqualStrings(lw.buffered(), rw.buffered());
    }
}
pub fn graphs(left: anytype, right: @TypeOf(left)) !void {
    try equal(left.state(), right.state());
    try equal(left.kind(), right.kind());
    inline for (.{ "declared_kind", "strict", "name", "source_info", "occurrences", "scopes", "bodies", "mentions", "endpoint_ports" }) |field|
        try equal(@field(left._data, field), @field(right._data, field));
    try equal(left._data.connections.len, right._data.connections.len);
    for (left._data.connections, right._data.connections) |l, r| {
        inline for (.{ "left", "right", "written_operator", "effective_operator", "operator_source", "occurrence" }) |field| try equal(@field(l, field), @field(r, field));
        if (@TypeOf(l.attributes) != void) try equal(left._data.attributes[l.attributes.start..][0..l.attributes.len], right._data.attributes[r.attributes.start..][0..r.attributes.len]);
    }
    try equal(left._coverage.entries.items, right._coverage.entries.items);
    try equal(left.nodeCount(), right.nodeCount());
    try equal(try left.findNode("missing"), try right.findNode("missing"));
    var nodes = left.nodeIterator();
    while (nodes.next()) |node| {
        const other = try right.nodeView(node.id);
        try equal(node.name().raw, other.name().raw);
        if (@TypeOf(left._data.attribute_data) != void) inline for (.{ "color", "shape", "label", "x", "missing" }) |key|
            try attribute(node.attribute(key), other.attribute(key));
        var destinations = left.nodeIterator();
        while (destinations.next()) |to| try equal(try left.hasEdge(node.id, to.id), try right.hasEdge(node.id, to.id));
        var scopes = left.scopeIterator();
        while (scopes.next()) |scope| try equal(try left.contains(try scope.membership(), node.id), try right.contains(try (try right.scopeView(scope.id)).membership(), node.id));
    }
    var scopes = left.scopeIterator();
    while (scopes.next()) |scope| {
        const other = try right.scopeView(scope.id);
        if (@TypeOf(left._data.attribute_data) != void) inline for (.{ "color", "label", "x", "missing" }) |key|
            try attribute(scope.attribute(key), other.attribute(key));
    }
    var le = try left.edgeIterator(.{});
    defer le.deinit();
    var re = try right.edgeIterator(.{});
    defer re.deinit();
    while (try le.next()) |edge| {
        const other = (try re.next()).?;
        try equal(edge.edge, other.edge);
        try equal(edge.firstConnection(), other.firstConnection());
        try equal(edge.orientation(), other.orientation());
        if (@TypeOf(left._data.attribute_data) != void) inline for (.{ "color", "shape", "label", "x", "tailport", "headport", "missing" }) |key|
            try attribute(try edge.attribute(key), try other.attribute(key));
    }
    try expect(try re.next() == null);
    var lm = try left.materialize(.{});
    defer lm.deinit();
    var rm = try right.materialize(.{});
    defer rm.deinit();
    try equal(lm.edges, rm.edges);
    try equal(lm.state(), rm.state());
}
fn optionsFor(comptime T: type, value: anytype) T {
    var result: T = .{};
    inline for (comptime std.meta.fieldNames(@TypeOf(value))) |field| if (@hasField(T, field)) {
        @field(result, field) = @field(value, field);
    };
    return result;
}
fn parity(comptime config: dot.ir.Config, comptime dot_config: dot.PolicyConfig, source: []const u8, options: anytype) !void {
    errdefer std.debug.print("partial parity input: {s}\n", .{source});
    const IR = dot.ir.Lowering(config);
    const EventDot = dot.Profile(dot_config);
    const PartialDot = comptime blk: {
        var cfg = dot_config;
        cfg.policy.retention.partial = true;
        break :blk dot.Profile(cfg);
    };
    var expected_bag = dot.FixedDiagnosticBag(256){};
    var keys: [256]dot.AttributeKeyScratch = undefined;
    var check_options = optionsFor(PartialDot.CheckOptions, options);
    check_options.validation.attribute_keys = &keys;
    const call = PartialDot.parseAndValidate(a, source, expected_bag.sink(), check_options);
    var checked = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
    defer checked.deinit(a);
    var bag = dot.FixedDiagnosticBag(256){};
    var result = try IR.FromEvents(EventDot).parsePartial(a, source, .{ .diagnostics = bag.sink(), .dot = optionsFor(@FieldType(IR.FromEvents(EventDot).Options, "dot"), options) });
    defer result.deinit();
    try equal(checked.outcome, result.checking.outcome);
    try equal(checked.completion, result.checking.completion);
    try equal(checked.syntax_errors, result.checking.syntax_errors);
    if (checked.document) |*document| {
        // A fail-fast Document convenience stops before its separate validation
        // pass. Validate the retained Document explicitly for the parity oracle;
        // event validation has already seen each committed contribution.
        if (checked.validation == null) {
            var validate_options = optionsFor(PartialDot.ValidationOptions, options);
            validate_options.scratch.attribute_keys = &keys;
            const validation_call = PartialDot.validate(document, expected_bag.sink(), validate_options);
            checked.validation = if (@typeInfo(@TypeOf(validation_call)) == .error_union) try validation_call else validation_call;
            checked.warnings += checked.validation.?.warningCount();
        }
        if (checked.warnings != result.checking.warnings) {
            for (expected_bag.items()) |d| std.debug.print("expected {t} {d}:{d}\n", .{ d.code, d.span.start, d.span.len });
            for (bag.items()) |d| std.debug.print("actual {t} {d}:{d}\n", .{ d.code, d.span.start, d.span.len });
        }
        try equal(checked.warnings, result.checking.warnings);
        try equal(if (document.scopeComplete()) @as(u32, @intCast(source.len)) else document.retained_end, result.checking.coverage.retained_end);
        try equal(document.root_closed, result.checking.coverage.root_closed);
        try equal(checked.validation, result.checking.validation);
        try equal(expected_bag.items().len, bag.items().len);
        for (expected_bag.items()) |d| {
            var count: usize = 0;
            var expected_count: usize = 0;
            for (expected_bag.items()) |v| if (std.meta.eql(v, d)) {
                expected_count += 1;
            };
            for (bag.items()) |v| if (std.meta.eql(v, d)) {
                count += 1;
            };
            try equal(expected_count, count);
        }
        if (checked.validation) |v| if (v.outcome != .completed or (document.strict and v.outcome.completed.violations != 0)) {
            try expect(result.ir() == null);
            return;
        };
        const interpretation_call = PartialDot.interpretation(document, optionsFor(PartialDot.Options, options));
        const interpretation = if (@typeInfo(@TypeOf(interpretation_call)) == .error_union) try interpretation_call else interpretation_call;
        var expected = IR.lowerPartial(a, document, .{ .interpretation = interpretation }) catch |err| {
            if (err == error.UnsupportedSemantics) {
                try expect(result.ir() == null);
                return;
            }
            return err;
        };
        defer expected.deinit();
        try expect(result.ir() != null);
        try graphs(@as(*const IR.PartialGraph, &expected), result.ir().?);
    } else try expect(result.ir() == null);
}
const inputs = [_][]const u8{
    "",                                                                                                "digraph",                                                           "digraph {}",                                  "digraph {;a;}",                                  "digraph { a; b[label=\"unfinished", "digraph {a; /*unfinished",                     "digraph {color=red",
    "digraph {node[shape=box];a[color=red];broken->;b[color=blue];a->b;}",                             "digraph {a->{b; subgraph s{c[color=red]}}->;d[color=blue]}",        "digraph {a->{b; subgraph s{c[color=red]}}->", "digraph {subgraph s{a[color=red];subgraph t{b;", "digraph {a->{}->;b;}",              "digraph {a->subgraph s{b;bad[x=];c}->{d};e;}", "digraph {subgraph s{a;bad->;} subgraph s{b}->x; a->x[color=blue]}",
    "strict digraph {edge[color=red];a:p->b:q[label=old];bad->;a:r->b:s[label=new];b->c[color=blue]}", "strict graph {a:p--b:q[color=red];bad->;b:r--a:s[label=new];a--a}",
};
test "partial event IR matches Document facts, gaps, attributes, queries and materialization" {
    for (inputs) |source| try parity(.{}, .{}, source, .{});
}
test "partial event IR prefixes preserve nested committed children and terminal coverage" {
    const source = "digraph G {node[color=red];a:p->{b;subgraph s{x};bad[x=];c}->subgraph s{d}[label=x];subgraph s{e};a->b}";
    for (0..source.len + 1) |end| try parity(.{}, .{}, source[0..end], .{});
}

test "partial event IR topology and selected indexes keep the same qualified answers" {
    for (inputs) |source| try parity(.{ .capabilities = .{ .attributes = false }, .indexes = .{ .connections = true, .scope_memberships = true } }, .{}, source, .{});
    for (inputs) |source| try parity(.{ .indexes = .{ .connections = true, .scope_memberships = true } }, .{}, source, .{});
}
test "partial event IR validates retained syntax and leaves missing coverage unchecked" {
    const cfg: dot.PolicyConfig = .{ .policy = .{ .validation = .{
        .repeated_attribute = .warning,
        .invalid_encoding = .warning,
        .graphviz = .{ .unknown_attribute = .warning },
        .restrictions = .{ .ports = .warning, .subgraphs = .warning, .graph_kinds = .{ .digraph = .warning } },
    } } };
    for ([_][]const u8{
        "digraph {a:p[x=x x=y];bad[z=q z=w q=];b:q[y=z];}",
        "digraph {a:p->{b:q[x=x x=y];subgraph s{z}}->;c:x[x=y]}",
        "digraph {a;bad[x=\"\xff",
        "digraph {a;bad[x=\xff]; b[label=<\xff>]} ",
        "graph {a--b;bad[x=];c->d}",
        "digraph {a--b;bad[x=];c->d}",
        "strict digraph {a--b;bad[x=];c->d}",
    }) |source| try parity(.{}, cfg, source, .{});
}
test "partial event IR auto kind and syntax policy match Document admission" {
    inline for (.{ .auto, .generic, .digraph }) |treatment| {
        for ([_][]const u8{ "graph {a--b;bad[x=];c->d}", "graph {a--b;bad[x=];c}", "strict graph {a--b;bad[x=];c}", "strict graph {a->b;bad[x=];c}", "graph {a->b->;c}" }) |source|
            try parity(.{}, .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = treatment } } } }, source, .{});
    }
    inline for (.{ .collect, .fail_fast }) |on_error| for (inputs) |source|
        try parity(.{}, .{ .policy = .{ .scanner = .scalar, .on_error = on_error, .execution = .{ .metering = true } } }, source, .{});
    for (inputs) |source| try parity(.{}, .{ .runtime_policy = true }, source, .{ .policy = dot.Policy{ .scanner = .scalar, .execution = .{ .metering = true } } });
}
test "partial event IR native spans and BOM coverage match the Document route" {
    const text = "digraph G {a:p->subgraph s{b;bad[x=];c};d[label=x]";
    const cfg: dot.PolicyConfig = .{ .source_encodings = &.{ .utf8, .utf16, .utf32 } };
    inline for (.{ dot.encoding.Actual.utf16le, .utf16be, .utf32le, .utf32be }) |encoding| {
        const width = if (encoding == .utf16le or encoding == .utf16be) 2 else 4;
        const big = encoding == .utf16be or encoding == .utf32be;
        var bytes: [(text.len + 1) * width]u8 = @splat(0);
        bytes[if (big) width - 2 else 1] = 0xfe;
        bytes[if (big) width - 1 else 0] = 0xff;
        for (text, 1..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
        for (1..text.len + 2) |end| try parity(.{ .source_encodings = cfg.source_encodings }, cfg, bytes[0 .. end * width], .{});
    }
}

test "partial event IR differential malformed mutations" {
    for ([_][]const u8{
        "digraph G{a:p->{b;q->r;bad[x=]}->subgraph s{c}[x=y];d}",
        "strict graph{a:p--b:q[color=red];b:r--a:s[label=x];}",
        "graph{node[x=y];subgraph s{a};x->subgraph s{b}->c}",
    }) |source| {
        var buffer: [256]u8 = undefined;
        for (0..source.len) |at| {
            @memcpy(buffer[0..at], source[0..at]);
            @memcpy(buffer[at..][0 .. source.len - at - 1], source[at + 1 ..]);
            try parity(.{}, .{}, buffer[0 .. source.len - 1], .{});
            for ("{}[];:=@\"<") |byte| {
                @memcpy(buffer[0..source.len], source);
                buffer[at] = byte;
                try parity(.{}, .{}, buffer[0..source.len], .{});
            }
        }
    }
}
fn allocationFailure(allocator: std.mem.Allocator, source: []const u8) !void {
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{}));
    var result = try E.parsePartial(allocator, source, .{});
    defer result.deinit();
    if (result.checking.outcome == .storage_failure) return error.OutOfMemory;
    try expect(result.ir() != null);
}
test "partial event IR allocation failures never leak staging or publish an incomplete operation" {
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{"digraph {node[color=red];a:p->{b;subgraph s{c}}->;subgraph s{d};d->e[label=x];tail->"});
}
test "partial event IR operational stops and diagnostic stops never publish" {
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{}));
    const source = "digraph {a;bad[x=];b}";
    try std.testing.expectError(error.MemoryLimit, E.parsePartial(a, source, .{ .lowering = .{ .limits = .{ .max_bytes = 0 } } }));
    try std.testing.expectError(error.NodeLimit, E.parsePartial(a, source, .{ .lowering = .{ .limits = .{ .max_nodes = 1 } } }));
    var completed = false;
    for (0..512) |budget| {
        var result = E.parsePartial(a, source, .{ .lowering = .{ .limits = .{ .max_work = budget } } }) catch |err| {
            try equal(error.WorkLimit, err);
            continue;
        };
        defer result.deinit();
        try expect(result.ir() != null);
        completed = true;
        break;
    }
    try expect(completed);
    const Sink = struct {
        fail: bool,
        fn emit(raw: ?*anyopaque, _: dot.Diagnostic) error{DiagnosticSinkFailure}!dot.diagnostic.Action {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail) return error.DiagnosticSinkFailure;
            return .stop;
        }
    };
    inline for (.{ false, true }) |fail| {
        var sink: Sink = .{ .fail = fail };
        var result = try E.parsePartial(a, source, .{ .diagnostics = .{ .context = &sink, .emit_fn = Sink.emit } });
        defer result.deinit();
        try expect(result.ir() == null);
        try expect(result.checking.diagnostic_stop != null);
    }
    const Limited = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 2 } } }));
    var limited = try Limited.parsePartial(a, source, .{});
    defer limited.deinit();
    try equal(dot.ParseOutcome.resource_exhausted, limited.checking.outcome);
    try expect(limited.ir() == null);
}
test "partial event IR cancellation stops at every accounted boundary" {
    const P = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } });
    const E = dot.ir.Lowering(.{ .runtime_policy = true }).FromEvents(P);
    const Counter = struct {
        calls: u32 = 0,
        stop: u32 = std.math.maxInt(u32),
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls == self.stop;
        }
    };
    const source = "digraph {a:p->{b;subgraph s{c}}->;subgraph s{d}->e} trailing";
    var counter: Counter = .{};
    const options = E.Options{ .lowering = .{
        .cancellation = .{ .context = &counter, .is_requested = Counter.requested },
        .policy = .{ .execution = .{ .cancellation = true, .metering = true } },
    } };
    var result = try E.parsePartial(a, source, options);
    result.deinit();
    const total = counter.calls;
    for (1..total + 1) |stop| {
        counter = .{ .stop = @intCast(stop) };
        try std.testing.expectError(error.Cancelled, E.parsePartial(a, source, options));
        try equal(@as(u32, @intCast(stop)), counter.calls);
    }
}
test "partial event IR large construction pages and deep abandoned scopes remain bounded" {
    const E = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{}));
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("digraph{");
    for (0..16 * 1024 + 7) |i| try source.writer.print("n{d}->n{d};", .{ i, i + 1 });
    try source.writer.writeAll("bad->;n0->{x;y};");
    var pages = try E.parsePartial(a, source.written(), .{});
    defer pages.deinit();
    try equal(@as(u32, 16 * 1024 + 8), pages.ir().?.connectionCount());
    try expect((try pages.ir().?.findNode("y")) == .known);
    source.clearRetainingCapacity();
    try source.writer.writeAll("digraph{a->");
    for (0..4096) |_| try source.writer.writeByte('{');
    try source.writer.writeAll("b;");
    var deep = try E.parsePartial(a, source.written(), .{});
    defer deep.deinit();
    try equal(@as(u32, 4097), deep.ir().?.scopeCount());
    try equal(@as(u32, 1), deep.ir().?.nodeCount());
    try equal(@as(u32, 0), deep.ir().?.connectionCount());
}

test "partial event IR abandoned scoped prefixes keep validation without promoting graph facts" {
    const cfg: dot.PolicyConfig = .{ .policy = .{ .validation = .{
        .digraph = .{ .operator_mismatch = .warning },
        .repeated_attribute = .warning,
        .restrictions = .{ .ports = .warning, .subgraphs = .warning },
    } } };
    for ([_][]const u8{
        "digraph{a:p--b:q->c:r->subgraph s{x:p}->d:q--e:r->;b}",
        "digraph{a:p->{}--b:q->c:r->{}->d:q->;z}",
        "digraph{{a:p}--b:q->c:r->{}--d:q->;z}",
        "digraph{a:p->subgraph s{b:p[x=y x=z];bad[x=];subgraph t{c:p}}->",
    }) |source| for (0..source.len + 1) |end| try parity(.{}, cfg, source[0..end], .{});
}
