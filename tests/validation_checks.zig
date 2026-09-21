//! Consumer-facing validation policies, storage and stage boundaries.
const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const Runtime = dot.Profile(.{ .runtime_policy = true });
const Storage = dot.FixedDocumentStorage(.{ .statements = 32, .nodes = 32, .edges = 16, .attributes = 64, .subgraphs = 16, .scoped_edges = 16, .scoped_edge_links = 16, .edge_chains = 16, .edge_links = 32, .ported_references = 32, .assignments = 16, .attribute_statements = 16 });

fn checks(severity: dot.RuleSeverity) dot.Policy {
    return .{ .validation = .{
        .invalid_utf8 = severity,
        .repeated_attribute = severity,
        .graph = .{ .operator_mismatch = severity },
        .digraph = .{ .operator_mismatch = severity },
        .restrictions = .{ .graph_kinds = .{ .undigraph = severity, .digraph = severity, .generic = severity }, .ports = severity, .subgraphs = severity },
    } };
}

const mixed = "graph { a:p [x=1][\"x\"=2]; { b -> c } // \xff\n }";

test "all validation checks have fixed/runtime severity parity and source ordering" {
    inline for (.{ .err, .warning, .off }) |severity| {
        const input = comptime checks(severity);
        const Fixed = dot.Profile(.{ .policy = input });
        var a_keys: [2]dot.AttributeKeyScratch = undefined;
        var b_keys: [2]dot.AttributeKeyScratch = undefined;
        const a_scratch: dot.ValidationScratch = .{ .attribute_keys = if (severity == .off) &.{} else &a_keys };
        const b_scratch: dot.ValidationScratch = .{ .attribute_keys = if (severity == .off) &.{} else &b_keys };
        var a_bag: dot.FixedDiagnosticBag(16) = .{};
        var b_bag: dot.FixedDiagnosticBag(16) = .{};
        var a = Fixed.parseAndValidate(std.testing.allocator, mixed, a_bag.sink(), .{ .validation = a_scratch });
        defer a.deinit(std.testing.allocator);
        var b = try Runtime.parseAndValidate(std.testing.allocator, mixed, b_bag.sink(), .{ .policy = input, .validation = b_scratch });
        defer b.deinit(std.testing.allocator);
        try deep(a, b);
        try deep(a_bag.items(), b_bag.items());
        try expect(a.outcome == .success);
        try equal(severity != .err, a.documentValid());
        try equal(@as(u64, if (severity == .warning) 6 else 0), a.warnings);
        try equal(@as(u64, if (severity == .err) 6 else 0), a.validation.?.outcome.completed.violations);
        try equal(@as(usize, if (severity == .off) 0 else 6), a_bag.items().len);
        if (severity != .off) {
            try equal(.restriction, std.meta.activeTag(a_bag.items()[0].details));
            try equal(.port, a_bag.items()[1].details.restriction);
            try equal(.repeated_attribute, std.meta.activeTag(a_bag.items()[2].details));
            try equal(.subgraph, a_bag.items()[3].details.restriction);
            try equal(.operator_mismatch, std.meta.activeTag(a_bag.items()[4].details));
            try equal(.invalid_utf8, std.meta.activeTag(a_bag.items()[5].details));
            for (a_bag.items()[1..], a_bag.items()[0 .. a_bag.items().len - 1]) |next, previous| try expect(previous.span.start <= next.span.start);
        }
        // Repeated validation is deterministic and never mutates retained data.
        const doc = &a.document.?;
        const before = doc.attributes[0..2].*;
        var staged_bag: dot.FixedDiagnosticBag(16) = .{};
        const staged = Fixed.validate(doc, staged_bag.sink(), .{ .scratch = a_scratch });
        try deep(a.validation.?, staged);
        try deep(a_bag.items(), staged_bag.items());
        try deep(before, doc.attributes[0..2].*);
        try std.testing.expectEqualStrings(mixed, doc.source);
        try equal(@as(usize, 2), doc.attributes.len);
    }
}

test "numeral severity applies to every parse path without reinterpreting tokens" {
    inline for (.{ .scalar, .block }) |scanner| {
        inline for (.{ false, true }) |metering| {
            inline for (.{ .err, .warning, .off }) |severity| {
                const input: dot.Policy = .{ .scanner = scanner, .execution = .{ .metering = metering, .cancellation = true }, .validation = .{ .ambiguous_numeral = severity } };
                const Fixed = dot.Profile(.{ .policy = input });
                const source = "graph { 1e3; 1.2.3; }";
                var a_bag: dot.FixedDiagnosticBag(8) = .{};
                var b_bag: dot.FixedDiagnosticBag(8) = .{};
                var a = Fixed.parseBorrowed(std.testing.allocator, source, a_bag.sink(), .{});
                defer a.deinit(std.testing.allocator);
                var b = try Runtime.parseBorrowed(std.testing.allocator, source, b_bag.sink(), .{ .policy = input });
                defer b.deinit(std.testing.allocator);
                try deep(a, b);
                try deep(a_bag.items(), b_bag.items());
                try equal(severity != .err, a.outcome == .success);
                try equal(@as(u32, if (severity == .warning) 2 else 0), a.warnings);
                try equal(@as(u32, 0), a.accepted_deviations);
                if (severity == .err) try equal(dot.Code.syntax_ambiguous_numeral_rejected, a_bag.items()[0].code);
                if (a.document) |doc| try equal(@as(usize, 4), doc.nodes.len);
                const measured = Fixed.measure(std.testing.allocator, source, dot.diagnostic.discard, .{});
                try deep(a.outcome, measured.outcome);
                try equal(a.warnings, measured.warnings);
                var storage: Storage = .{};
                const memory: dot.ParseMemory = .{ .document = storage.storage() };
                var session = try Runtime.Session.init(source, memory, dot.diagnostic.discard, .{ .policy = input });
                defer session.deinit();
                if (metering) while ((try session.advance(1)).outcome == null) {};
                const result = session.run();
                try deep(a.document, result.document);
                try deep(a.outcome, result.outcome);
                try equal(a.warnings, result.warnings);
                if (severity != .err) try equal(@as(u64, 0), session.validate(dot.diagnostic.discard, .{}).?.warningCount());
                const FixedDriver = @FieldType(@FieldType(Fixed.Session, "driver"), "machine");
                const Scanner = @FieldType(FixedDriver, "tokens");
                try expect(@FieldType(Scanner, "check_numerals") == void);
                if (severity == .off) try expect(@FieldType(Scanner, "ambiguous_numeral") == void);
            }
        }
    }
}

test "new leaves inherit independently and complete presets reset them" {
    const Custom = dot.Profile(.{ .runtime_policy = true, .policy = checks(.err) });
    var keys: [2]dot.AttributeKeyScratch = undefined;
    var checked = try Custom.parseAndValidate(std.testing.allocator, mixed, dot.diagnostic.discard, .{
        .policy = .{ .validation = .{ .invalid_utf8 = .warning, .restrictions = .{ .ports = .off } } },
        .validation = .{ .attribute_keys = &keys },
    });
    defer checked.deinit(std.testing.allocator);
    try equal(@as(u64, 4), checked.validation.?.outcome.completed.violations);
    try equal(@as(u64, 1), checked.warnings);
    var reset = try Custom.parseAndValidate(std.testing.allocator, mixed, dot.diagnostic.discard, .{ .policy = dot.presets.standard });
    defer reset.deinit(std.testing.allocator);
    try equal(@as(u64, 1), reset.validation.?.outcome.completed.violations); // only operator mismatch
    try equal(@as(u64, 0), reset.warnings);
    try expect(Custom.validatePolicy(checks(.warning)) == .valid);
}

test "UTF-8 checks all source bytes and recovers one invalid byte at a time" {
    const Utf8 = dot.Profile(.{ .policy = .{ .validation = .{ .invalid_utf8 = .err } } });
    const source = "// \xc0\xaf \xed\xa0\x80 \xf4\x90\x80\x80 \xe2(\xa1 \x00\n";
    // Keep the BOM document-leading, and put malformed bytes in all payload forms.
    const input = "\xef\xbb\xbfgraph { caf\xe9 [label=\"\xff\"] } " ++ source ++ "// \xe2\x82";
    var bag: dot.FixedDiagnosticBag(32) = .{};
    var checked = Utf8.parseAndValidate(std.testing.allocator, input, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try expect(checked.outcome == .success);
    try equal(@as(u64, 15), checked.validation.?.outcome.completed.violations);
    for (bag.items()) |d| {
        try equal(dot.Code.validation_invalid_utf8, d.code);
        try equal(@as(u32, 1), d.span.len);
        try equal(input[d.span.start], d.details.invalid_utf8);
        try expect(d.fix == null);
    }
    var valid = Utf8.parseAndValidate(std.testing.allocator, "\xef\xbb\xbfgraph { café [label=\"東京 😀 \xF4\x8F\xBF\xBF\"] } // \x00", dot.diagnostic.discard, .{});
    defer valid.deinit(std.testing.allocator);
    try expect(valid.documentValid());
}

test "duplicate keys use logical byte equality and are local to attribute owners" {
    const Lint = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning } } });
    const source = "digraph { a[x=1][\"x\"=2 x=3]; b[x=0]; node[x=0][x=1]; a->b->c[\"a\"+\"b\"=1 ab=2]; { c[foo=1 foo=2] } -> d[q=1 q=2]; e[\xff=1 \"\xff\"=2]; z[1=a \"1\"=b 1.0=c \"a\\\nb\"=d ab=e]; x=1; x=2; }";
    var keys: [32]dot.AttributeKeyScratch = undefined;
    var bag: dot.FixedDiagnosticBag(16) = .{};
    var result = Lint.parseAndValidate(std.testing.allocator, source, bag.sink(), .{ .validation = .{ .attribute_keys = &keys } });
    defer result.deinit(std.testing.allocator);
    try expect(result.documentValid());
    try equal(@as(u64, 9), result.warnings);
    for (bag.items()) |d| {
        try equal(dot.Code.validation_repeated_attribute_tolerated, d.code);
        try expect(d.details.repeated_attribute.start < d.span.start);
        try expect(d.fix == null); // removing or merging values could change meaning
    }
    try equal(bag.items()[0].details.repeated_attribute, bag.items()[1].details.repeated_attribute);
    // Case and numeral spellings are not normalized; separate statements do not merge.
    var distinct = Lint.parseAndValidate(std.testing.allocator, "graph { a[X=1 x=2 1=a 1.0=b]; a[x=3]; node[x=4]; node[x=5] }", dot.diagnostic.discard, .{ .validation = .{ .attribute_keys = &keys } });
    defer distinct.deinit(std.testing.allocator);
    try expect(distinct.documentValid());
    try equal(@as(u64, 0), distinct.warnings);
}

test "scratch preflight is explicit, failure atomic and skipped for off" {
    const Lint = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning } } });
    var parsed = dot.parseBorrowed(std.testing.allocator, "graph { a[x=1 x=2] }", dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    var keys = [_]dot.AttributeKeyScratch{.{ .hash = 7, .index = 8, .first = 9 }};
    var bag: dot.FixedDiagnosticBag(4) = .{};
    const result = Lint.validate(&parsed.document.?, bag.sink(), .{ .scratch = .{ .attribute_keys = &keys } });
    try expect(result.outcome == .insufficient_scratch and !result.documentValid());
    try equal(@as(u32, 2), result.outcome.insufficient_scratch.required_attribute_keys);
    try equal(@as(usize, 1), result.outcome.insufficient_scratch.provided_attribute_keys);
    try equal(@as(u32, 8), keys[0].index);
    try equal(dot.diagnostic.Capacity.Resource.validation_attribute_keys, bag.items()[0].details.capacity.resource);
    try expect(dot.validate(&parsed.document.?, dot.diagnostic.discard, .{}).documentValid());
    var composed = Lint.parseAndValidate(std.testing.allocator, "graph { 1e3 [x=1 x=2] }", dot.diagnostic.discard, .{});
    defer composed.deinit(std.testing.allocator);
    try expect(composed.outcome == .success and composed.document != null and !composed.documentValid());
    try expect(composed.validation.?.outcome == .insufficient_scratch);
    try equal(@as(u64, 1), composed.warnings); // parse facts survive validation exhaustion
}

const Rejecting = struct {
    fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
        return error.DiagnosticSinkFailure;
    }
    const sink: dot.DiagnosticSink = .{ .context = null, .emit_fn = emit };
};

test "suppression retention and delivery do not change validation counts or validity" {
    const Errors = dot.Profile(.{ .policy = checks(.err) });
    var parsed = dot.parseBorrowed(std.testing.allocator, mixed, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    var keys: [2]dot.AttributeKeyScratch = undefined;
    const options: Errors.ValidationOptions = .{ .scratch = .{ .attribute_keys = &keys } };
    const discarded = Errors.validate(&parsed.document.?, dot.diagnostic.discard, options);
    var small: dot.FixedDiagnosticBag(1) = .{};
    try deep(discarded, Errors.validate(&parsed.document.?, small.sink(), options));
    try equal(@as(usize, 5), small.omitted);
    const rejected = Errors.validate(&parsed.document.?, Rejecting.sink, options);
    try deep(discarded.outcome, rejected.outcome);
    try equal(.failed, rejected.diagnostic_delivery);
    const exhausted = Errors.validate(&parsed.document.?, Rejecting.sink, .{});
    try expect(exhausted.outcome == .insufficient_scratch and exhausted.diagnostic_delivery == .failed);
    const Numerals = dot.Profile(.{ .policy = .{ .validation = .{ .ambiguous_numeral = .err } } });
    var numeral = Numerals.parseBorrowed(std.testing.allocator, "graph { 1e3 }", Rejecting.sink, .{});
    defer numeral.deinit(std.testing.allocator);
    try expect(numeral.outcome == .invalid_syntax and numeral.diagnostic_delivery == .failed);
}

test "graph restrictions use effective kind and never conform or rewrite syntax" {
    const DirectedOnly = dot.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{
        .restrictions = .{ .graph_kinds = .{ .undigraph = .err, .generic = .warning } },
    } } });
    for ([_][]const u8{ "graph {}", "graph {a--b}", "graph {a->b}", "digraph {a->b}" }) |source| {
        inline for (.{ .undigraph, .digraph, .generic, .auto }) |treatment| {
            const patch: dot.Policy = .{ .validation = .{ .graph = .{ .treated_as = treatment } } };
            var result = try DirectedOnly.parseAndValidate(std.testing.allocator, source, dot.diagnostic.discard, .{ .policy = patch });
            defer result.deinit(std.testing.allocator);
            const doc = &result.document.?;
            const kind = doc.effectiveKind(try DirectedOnly.interpretation(doc, .{ .policy = patch }));
            if (kind == .undigraph) try expect(!result.documentValid());
            try equal(@as(u64, if (kind == .generic) 1 else 0), result.warnings);
        }
    }
}

test "sessions latch validation leaves and scratch stays a call resource" {
    const input: dot.Policy = .{ .execution = .{ .metering = true }, .validation = checks(.warning).validation };
    var storage: Storage = .{};
    var frames: dot.FixedParseScratch(.{ .nesting = 16 }) = .{};
    var session = try Runtime.Session.init(mixed, .{ .document = storage.storage(), .scratch = frames.storage() }, dot.diagnostic.discard, .{ .policy = input });
    defer session.deinit();
    try expect(session.validate(dot.diagnostic.discard, .{}) == null);
    while ((try session.advance(1)).outcome == null) {}
    try expect(session.validate(dot.diagnostic.discard, .{}).?.outcome == .insufficient_scratch);
    var keys: [2]dot.AttributeKeyScratch = undefined;
    const checked = session.validate(dot.diagnostic.discard, .{ .attribute_keys = &keys }).?;
    try expect(checked.documentValid());
    try equal(@as(u64, 6), checked.warningCount());
    try session.reset("graph {a[x=1 x=2]}", dot.diagnostic.discard, .{});
    try expect(session.run().outcome == .success);
    try equal(@as(u64, 0), session.validate(dot.diagnostic.discard, .{}).?.warningCount());
}

test "new diagnostics render in compact ASCII and Unicode forms" {
    const All = dot.Profile(.{ .policy = checks(.warning) });
    var keys: [2]dot.AttributeKeyScratch = undefined;
    var bag: dot.FixedDiagnosticBag(16) = .{};
    var result = All.parseAndValidate(std.testing.allocator, mixed, bag.sink(), .{ .validation = .{ .attribute_keys = &keys } });
    defer result.deinit(std.testing.allocator);
    for (bag.items()) |d| {
        var bytes: [8192]u8 = undefined;
        var compact = std.Io.Writer.fixed(&bytes);
        try dot.console.render(d, .{ .source = mixed }, &compact);
        inline for (.{ .ascii, .unicode }) |style| {
            var boxed = std.Io.Writer.fixed(&bytes);
            try dot.console.renderBoxed(d, 1, .{ .source = mixed, .style = style }, &boxed);
            try expect(boxed.buffered().len != 0);
        }
    }
}

test "large repeated attribute list uses bounded caller workspace" {
    var source_bytes: [16000]u8 = undefined;
    var source = std.Io.Writer.fixed(&source_bytes);
    try source.writeAll("graph { a[");
    for (0..1000) |i| try source.writeAll(if (i % 2 == 0) "key=1 " else "\"ke\"+\"y\"=2 ");
    try source.writeAll("] }");
    var keys: [1000]dot.AttributeKeyScratch = undefined;
    const Lint = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .err } } });
    var result = Lint.parseAndValidate(std.testing.allocator, source.buffered(), dot.diagnostic.discard, .{ .validation = .{ .attribute_keys = &keys } });
    defer result.deinit(std.testing.allocator);
    try expect(result.outcome == .success);
    try equal(@as(u64, 999), result.validation.?.outcome.completed.violations);
    try equal(@as(usize, 16), @sizeOf(dot.AttributeKeyScratch));
}

test "duplicate equality agrees with explicit decoding across spellings and chunk boundaries" {
    const Lint = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .warning } } });
    const spellings = [_][]const u8{
        "x",          "\"x\"",     "X",    "\"\"",     "\"\"+\"\"",  "\"a\"+\"b\"",          "ab", "1", "\"1\"", "1.0",
        "\"a\\\nb\"", "\"a\\nb\"", "\xff", "\"\xff\"", "\"a\\\"b\"", "\"a\"/*c*/+\"\\\"b\"",
    };
    var keys: [2]dot.AttributeKeyScratch = undefined;
    var pools: Storage = .{};
    for (spellings) |left| {
        for (spellings) |right| {
            var bytes: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try writer.print("graph {{ a[{s}=1 {s}=2] }}", .{ left, right });
            const parsed = Lint.parseBorrowedIn(writer.buffered(), .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
            try expect(parsed.outcome == .success);
            var left_value: [64]u8 = undefined;
            var right_value: [64]u8 = undefined;
            const same = std.mem.eql(u8, try dot.identifier.decodeInto(left, &left_value), try dot.identifier.decodeInto(right, &right_value));
            const checked = Lint.validate(&parsed.document.?, dot.diagnostic.discard, .{ .scratch = .{ .attribute_keys = &keys } });
            try equal(@as(u64, if (same) 1 else 0), checked.warningCount());
        }
    }
}
