const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const strings = @import("string_processor");
const a = std.testing.allocator;
const Text = strings.Profile(.{});
const city = .{ .validation = .{ .one_of = .{ .values = &.{ "SF", "Seattle" }, .severity = .err } } };

test "passthrough binding is exactly the original profile for both hosts" {
    try std.testing.expect(dot.Profile(.{}) == dot.Profile(.{ .processors = .{ .string = Text } }));
    try std.testing.expect(markup.Profile(.{}) == markup.Profile(.{ .processors = .{ .string = Text } }));
    try std.testing.expect(dot.Profile(.{}) == dot.Profile(.{
        .processors = .{ .string = Text },
        .policy = .{ .attributes = .{ .label = .{ .string = .passthrough } } },
    }));
}

test "DOT per-attribute precedence logical keys concatenation and delayed checks" {
    const P = dot.Profile(.{
        .processors = .{ .string = Text },
        .policy = .{ .attributes = .{
            .label = .{ .string = .{ .process = city } },
            .restricted = .{ .string = .none },
            .description = .{ .string = .passthrough },
        } },
    });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var result = try P.parseAndValidate(a, "graph { a [\"la\"+\"bel\"=\"Sea\"+\"ttle\" description=\"anything\" restricted=x other=y]; label=SF; b[label=Paris] }", bag.sink(), .{});
    defer result.deinit(a);
    try std.testing.expect(result.scopeComplete());
    try std.testing.expect(!result.documentValid());
    try std.testing.expectEqual(3, result.string.processed);
    try std.testing.expectEqual(2, result.string.passed);
    try std.testing.expectEqual(1, result.string.unsupported);
    try std.testing.expectEqual(2, result.string.passthrough);
    try std.testing.expectEqual(2, result.string.errors);
    const again = try P.processStrings(&result.host.document.?, P.DiagnosticSink.discard, .{});
    try std.testing.expectEqualDeep(result.string, again);
}

test "markup default processing, explicit bypass, omitted branch inherits" {
    const P = markup.Profile(.{
        .processors = .{ .string = Text },
        .policy = .{
            .mode = .structural,
            .string = .{ .process = .{ .validation = .{ .equals = .{ .expected = "A&B", .severity = .err } } } },
            .attributes = .{ .skip = .{ .string = .passthrough }, .inherit = .{} },
        },
    });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var result = try P.parseAndValidate(a, .{ .bytes = "<x value='A&amp;B' skip='anything' inherit='A&#38;B'/>", .origin = 70 }, bag.sink(), .{});
    defer result.deinit();
    try std.testing.expect(result.documentValid());
    try std.testing.expectEqual(2, result.string.passed);
    try std.testing.expectEqual(1, result.string.passthrough);
}

test "nested DOT markup string uses a shared bag and original offsets" {
    const Labels = markup.Profile(.{
        .processors = .{ .string = Text },
        .policy = .{ .mode = .structural, .attributes = .{ .title = .{ .string = .{ .process = city } } } },
    });
    const P = dot.Profile(.{ .processors = .{ .markup = Labels, .string = Text }, .policy = .{ .attributes = .{ .label = .{ .string = .{ .process = city } } } } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    const source = "graph { a[label=<<x title='Paris'/>>]; b[label=\"Paris\"] }";
    var result = try P.parseAndValidate(a, source, bag.sink(), .{});
    defer result.deinit(a);
    try std.testing.expect(!result.documentValid());
    try std.testing.expectEqual(1, result.string.processed);
    try std.testing.expectEqual(2, bag.items().len);
    try std.testing.expectEqualStrings("Paris", bag.items()[0].span().slice(source));
    try std.testing.expectEqualStrings("\"Paris\"", bag.items()[1].span().slice(source));
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    var positions: [32]dot.Location = undefined;
    try P.console.renderBoxedList(bag.items(), 0, .{ .source = source }, &positions, &out.writer);
    try std.testing.expect(out.written().len > 0);
}

test "delegation overrides child baseline and runtime overrides delegation" {
    const Child = strings.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{ .equals = .{ .expected = "base", .severity = .warning } } } });
    const P = dot.Profile(.{ .processors = .{ .string = Child }, .policy = .{
        .string = .process,
        .attributes = .{ .label = .{ .string = .{ .process = .{ .validation = .{ .equals = .{ .expected = "delegated", .severity = .err } } } } } },
    } });
    var result = try P.parseAndValidate(a, "graph{ a[label=delegated other=base] }", P.DiagnosticSink.discard, .{});
    defer result.deinit(a);
    try std.testing.expect(result.documentValid());
    var overridden = try P.parseAndValidate(a, "graph{a[label=runtime other=runtime]}", P.DiagnosticSink.discard, .{
        .string = .{ .policy = .{ .validation = .{ .equals = .{ .expected = "runtime", .severity = .err } } } },
    });
    defer overridden.deinit(a);
    try std.testing.expect(overridden.documentValid());
}

test "none needs no string implementation and respects host unsupported policy" {
    inline for (.{ dot.Unsupported.err, .warning, .silent }) |severity| {
        const P = dot.Profile(.{ .policy = .{ .string = .none, .diagnostics = .{ .unsupported = severity } } });
        var bag: P.FixedDiagnosticBag(8) = .{};
        var result = try P.parseAndValidate(a, "graph{a[x=y]}", bag.sink(), .{});
        defer result.deinit(a);
        try std.testing.expectEqual(severity != .err, result.documentValid());
        try std.testing.expectEqual(if (severity == .silent) @as(usize, 0) else 1, bag.items().len);
        const M = markup.Profile(.{ .policy = .{ .mode = .structural, .string = .none, .diagnostics = .{ .unsupported = severity } } });
        var other = try M.parseAndValidate(a, .{ .bytes = "<a x='y'/>", .origin = 0 }, M.DiagnosticSink.discard, .{});
        defer other.deinit();
        try std.testing.expectEqual(severity != .err, other.documentValid());
    }
}

test "inner fail-fast does not end collect batch; outer fail-fast does" {
    const Fast = strings.Profile(.{ .policy = .{ .on_error = .fail_fast } });
    inline for (.{ dot.OnError.collect, .fail_fast }) |outer| {
        const P = dot.Profile(.{ .processors = .{ .string = Fast }, .policy = .{
            .on_error = outer,
            .string = .{ .process = city },
        } });
        var bag: P.FixedDiagnosticBag(8) = .{};
        var result = try P.parseAndValidate(a, "graph{a[x=Paris y=London]}", bag.sink(), .{});
        defer result.deinit(a);
        try std.testing.expectEqual(if (outer == .collect) @as(u32, 2) else 1, result.string.processed);
        try std.testing.expectEqual(outer == .collect, result.string.complete);
    }
}

test "sink stop prevents sibling string work" {
    const P = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .string = .{ .process = city } } });
    var bag: P.FixedDiagnosticBag(1) = .{};
    var result = try P.parseAndValidate(a, .{ .bytes = "<a x='Paris' y='London'/>", .origin = 0 }, bag.sink(), .{});
    defer result.deinit();
    try std.testing.expectEqual(1, result.string.processed);
    try std.testing.expectEqual(.diagnostic_stop, result.string.stop.?);
    try std.testing.expect(result.stopped());
}

test "markup host failure stops dispatch but collect validation errors do not" {
    inline for (.{ markup.OnError.collect, .fail_fast }) |on_error| {
        const P = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .on_error = on_error, .string = .{ .process = city } } });
        var result = try P.parseAndValidate(a, .{ .bytes = "<a x='Paris' x='London'/>", .origin = 0 }, P.DiagnosticSink.discard, .{});
        defer result.deinit();
        try std.testing.expectEqual(if (on_error == .collect) @as(u32, 2) else 0, result.string.processed);
    }
}

test "unknown references remain unavailable even with host reference checks off" {
    const P = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .string = .{ .process = city } } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var result = try P.parseAndValidate(a, .{ .bytes = "<a x='&bogus;'/>", .origin = 90 }, bag.sink(), .{});
    defer result.deinit();
    try std.testing.expectEqual(0, bag.items().len);
    try std.testing.expectEqual(1, result.string.unavailable);
    try std.testing.expectEqual(96, result.string.first_unavailable.?.location.span.start);
    try std.testing.expect(!result.documentValid());
}

test "Graphviz attribute matching and reference catalog; structural names exact" {
    const P = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{
        .validation = .{ .references = .{ .catalog = .graphviz, .severity = .err } },
        .attributes = .{ .face = .{ .string = .{ .process = .{ .validation = .{ .equals = .{ .expected = "A\u{a0}B", .severity = .err } } } } } },
    } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var result = try P.parseAndValidate(a, .{ .bytes = "<FONT FACE='A&nbsp;B'>x</FONT>", .origin = 0 }, bag.sink(), .{});
    defer result.deinit();
    try std.testing.expect(result.documentValid());
    try std.testing.expectEqual(1, result.string.processed);
    const S = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .attributes = .{ .x = .{ .string = .{ .process = city } } } } });
    var exact = try S.parseAndValidate(a, .{ .bytes = "<a X='Paris'/>", .origin = 0 }, S.DiagnosticSink.discard, .{});
    defer exact.deinit();
    try std.testing.expect(exact.documentValid());
    try std.testing.expectEqual(0, exact.string.processed);
}

test "partial coverage never certifies a missing tail" {
    const P = dot.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .retention = .{ .partial = true }, .string = .{ .process = city } } });
    var result = try P.parseAndValidate(a, "graph{a[x=SF]; b[y=\"", P.DiagnosticSink.discard, .{});
    defer result.deinit(a);
    try std.testing.expectEqual(1, result.string.processed);
    try std.testing.expect(!result.string.complete);
    try std.testing.expect(!result.documentValid());
}

test "fixed markup pools and workspace reuse add no string allocations" {
    const P = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .string = .{ .process = city } } });
    var storage: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 1 }) = .{};
    var stack: markup.FixedParseScratch(1) = .{};
    const ready = try P.prepare(.{});
    const fixed = try ready.parseAndValidateIn(.{ .bytes = "<a x='Seattle'/>", .origin = 13 }, .{ .document = storage.storage(), .scratch = stack.storage() }, .{}, P.DiagnosticSink.discard);
    try std.testing.expect(fixed.documentValid());
    var workspace = ready.initWorkspace(a, .{});
    defer workspace.deinit();
    const first = try workspace.parseAndValidate(.{ .bytes = "<a x='Seattle'/>", .origin = 13 }, P.DiagnosticSink.discard);
    try std.testing.expect(first.documentValid());
    const bytes = workspace.reservedBytes();
    const second = try workspace.parseAndValidate(.{ .bytes = "<a x='SF'/>", .origin = 200 }, P.DiagnosticSink.discard);
    try std.testing.expect(second.documentValid());
    try std.testing.expectEqual(bytes, workspace.reservedBytes());
}

test "delegated cancellation stops during a string without changing parent parse" {
    const Probe = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    const P = dot.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .string = .{ .process = .{
        .execution = .{ .cancellation = true, .metering = true },
        .validation = .{ .one_of = .{ .values = &.{"SF"}, .severity = .err } },
    } } } });
    var result = try P.parseAndValidate(a, "graph{a[x=SF y=SF]}", P.DiagnosticSink.discard, .{ .string = .{ .cancellation = .{ .context = null, .is_requested = Probe.poll } } });
    defer result.deinit(a);
    try std.testing.expect(result.scopeComplete());
    try std.testing.expectEqual(.cancelled, result.string.stop.?);
    try std.testing.expectEqual(1, result.string.processed);
}

test "native source readers retain original diagnostics through nested composition" {
    const Labels = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .string = .{ .process = city } } });
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .processors = .{ .markup = Labels, .string = Text }, .policy = .{ .attributes = .{ .label = .{ .string = .{ .process = city } } } } });
    inline for (.{ dot.InputEncoding.utf16le, .utf16be, .utf32le, .utf32be }) |encoding| {
        const raw = "graph{a[label=<<x title='Paris'/>>];b[label=Paris]}";
        const width = if (encoding == .utf16le or encoding == .utf16be) 2 else 4;
        var buffer: [raw.len * width]u8 = @splat(0);
        for (raw, 0..) |byte, i| buffer[i * width + (if (encoding == .utf16be or encoding == .utf32be) width - 1 else 0)] = byte;
        var bag: P.FixedDiagnosticBag(8) = .{};
        var result = try P.parseAndValidate(a, &buffer, bag.sink(), .{ .dot = .{ .encoding = encoding } });
        defer result.deinit(a);
        try std.testing.expectEqual(2, bag.items().len);
        try std.testing.expectEqual(std.mem.indexOf(u8, raw, "Paris").? * width, bag.items()[0].span().start);
        try std.testing.expectEqual(5 * width, bag.items()[0].span().len);
    }
}

test "custom validator receives logical contents and reports reference spelling" {
    const NoAmp = struct {
        pub const Settings = void;
        pub const defaults: Settings = {};
        pub const uses_comparison = false;
        pub fn State(comptime Context: type) type {
            return struct { cursor: Context.Cursor = .{} };
        }
        pub fn step(state: anytype, value: anytype, _: Settings, context: anytype) strings.Step {
            return switch (context.readStep(&state.cursor, value)) {
                .pending => .pending,
                .stopped => .stopped,
                .end => .passed,
                .scalar => |item| if (item.codepoint == '&' and !context.report(.{ .at = item.location })) .stopped else .pending,
            };
        }
    };
    const P = markup.Profile(.{ .processors = .{ .string = strings.Profile(.{ .custom = NoAmp }) }, .policy = .{
        .mode = .structural,
        .string = .{ .process = .{ .validation = .{ .custom = .err } } },
    } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var result = try P.parseAndValidate(a, .{ .bytes = "<a x='A&amp;B'/>", .origin = 100 }, bag.sink(), .{});
    defer result.deinit();
    try std.testing.expectEqual(1, bag.items().len);
    try std.testing.expectEqual(107, bag.items()[0].span().start);
    try std.testing.expectEqual(5, bag.items()[0].span().len);
}

test "invalid runtime child policy fails before allocations or host findings" {
    const P = dot.Profile(.{ .processors = .{ .string = strings.Profile(.{ .runtime_policy = true }) }, .policy = .{ .string = .{ .process = city } } });
    var alloc = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var bag: P.FixedDiagnosticBag(8) = .{};
    try std.testing.expectError(error.InvalidCancellationInterval, P.parseAndValidate(alloc.allocator(), "broken", bag.sink(), .{ .string = .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } } }));
    try std.testing.expectEqual(0, alloc.allocations);
    try std.testing.expectEqual(0, bag.items().len);
}

test "DOT delayed markup also invokes its configured string processor" {
    const Labels = markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .string = .{ .process = city } } });
    const P = dot.Profile(.{ .processors = .{ .markup = Labels }, .policy = .{ .markup = .passthrough, .retention = .{ .markup = true } } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var result = try P.parseAndValidate(a, "graph{a[label=<<x title='Paris'/>>]}", bag.sink(), .{});
    defer result.deinit(a);
    const span = result.dot.document.?.attributes[0].value;
    try result.requestMarkup(a, span);
    try P.processPendingMarkup(a, &result, bag.sink(), .{});
    try std.testing.expectEqual(1, bag.items().len);
    try std.testing.expectEqual(1, result.markup.rejected);
    try std.testing.expectEqual(1, result.markupResults().?[0].result.string.processed);
}

test "standalone native markup and runtime host policies route the actual reader" {
    const P = markup.Profile(.{ .runtime_policy = true, .source_encodings = &.{.utf16}, .processors = .{ .string = Text }, .policy = .{
        .mode = .structural,
        .string = .{ .process = city },
    } });
    const raw = "<a x='SF'/>";
    var bytes: [raw.len * 2]u8 = @splat(0);
    for (raw, 0..) |byte, i| bytes[i * 2] = byte;
    var result = try P.parseAndValidate(a, .{ .bytes = &bytes, .origin = 4 }, P.DiagnosticSink.discard, .{ .markup = .{ .encoding = .utf16le, .policy = .{ .on_error = .fail_fast } } });
    defer result.deinit();
    try std.testing.expect(result.documentValid());
    try std.testing.expectEqual(1, result.string.passed);
}

test "processing does not add allocator requests to either host" {
    inline for (.{ dot, markup }) |api| {
        const P = if (api == dot) dot.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .string = .{ .process = city } } }) else markup.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .mode = .structural, .string = .{ .process = city } } });
        const Outer = if (api == dot) dot.Profile(.{}) else markup.Profile(.{ .policy = .{ .mode = .structural } });
        const input = if (api == dot) "graph{a[x=Seattle y=SF]}" else markup.Fragment{ .bytes = "<a x='Seattle' y='SF'/>", .origin = 0 };
        var before = std.testing.FailingAllocator.init(a, .{});
        var after = std.testing.FailingAllocator.init(a, .{});
        const call = Outer.parseAndValidate(before.allocator(), input, api.DiagnosticSink.discard, .{});
        var plain = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
        defer if (api == dot) plain.deinit(before.allocator()) else plain.deinit();
        var checked = try P.parseAndValidate(after.allocator(), input, P.DiagnosticSink.discard, .{});
        defer if (api == dot) checked.deinit(after.allocator()) else checked.deinit();
        try std.testing.expect(checked.documentValid());
        try std.testing.expectEqual(before.allocations, after.allocations);
        try std.testing.expectEqual(before.allocated_bytes, after.allocated_bytes);
    }
}

test "runtime child patch is verified and applied inside markup composition" {
    const Labels = markup.Profile(.{ .processors = .{ .string = strings.Profile(.{ .runtime_policy = true }) }, .policy = .{
        .mode = .structural,
        .string = .{ .process = city },
    } });
    const P = dot.Profile(.{ .processors = .{ .markup = Labels } });
    var result = try P.parseAndValidate(a, "graph{a[label=<<x title='Paris'/>>]}", P.DiagnosticSink.discard, .{
        .markup = .{ .string = .{ .policy = .{ .validation = .{ .one_of = .{ .values = &.{"Paris"}, .severity = .err } } } } },
    });
    defer result.deinit(a);
    try std.testing.expect(result.documentValid());
}

test "aggregation honors child validity and checks factual counter overflow" {
    const P = dot.Profile(.{ .processors = .{ .string = Text }, .policy = .{ .string = .process } });
    const R = @FieldType(P.CheckResult, "string");
    const ChildResult = Text.WithReader(dot.identifier.LogicalReader(.utf8)).Result;
    var report: R = .{};
    report.record(ChildResult{}, .collect); // complete tag alone is not validity
    report.complete = true;
    try std.testing.expect(!report.valid());
    report.errors = std.math.maxInt(u64);
    report.record(ChildResult{ .errors = 1 }, .collect);
    try std.testing.expectEqual(.invalid_validator, report.stop.?);
}
