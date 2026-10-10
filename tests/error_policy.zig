//! Public error handling, unsupported reporting, and parent/child boundaries.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
// These fixtures exercise vocabulary-independent structural behavior.
const Structural = markup.Profile(.{ .policy = .{ .mode = .structural } });
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const allocator = std.testing.allocator;

test "error handling and unsupported types are shared without legacy aliases" {
    try expect(dot.OnError == markup.OnError and dot.Unsupported == markup.Unsupported);
    try expect(!@hasDecl(dot, "Recovery") and !@hasDecl(markup, "Recovery"));
    try expect(!@hasField(dot.Policy, "recovery") and !@hasField(markup.Policy, "recovery"));
    try equal(dot.OnError.collect, dot.presets.standard.on_error.?);
    try equal(markup.Unsupported.err, markup.presets.untrusted.diagnostics.unsupported.?);
}

test "validation obeys on_error independently of warning reporting and sink retention" {
    const text = "<x a='1' a='2' a='3'/><y b='1' b='2'/>";
    var parsed = Structural.parseBorrowed(allocator, text, markup.diagnostic.discard, .{});
    defer parsed.deinit();
    var attributes: [3]markup.ScopeAttribute = undefined;
    for (&attributes, parsed.document.?.attributes[0..3]) |*target, a| target.* = .{ .name = a.name, .value = a.value };
    const header: markup.ValidationScope = .{ .opening_header = .{
        .span = .{ .start = 0, .len = @intCast(std.mem.indexOfScalar(u8, text, '>').? + 1) },
        .name = .{ .start = 1, .len = 1 },
        .attributes = &attributes,
    } };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| inline for (.{ .fail_fast, .collect }) |mode| inline for (.{ .err, .warning }) |severity| {
        const patch: markup.Policy = .{ .mode = .structural, .scanner = scanner, .on_error = mode, .validation = .{ .duplicate_attribute = severity } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{ .mode = .structural, .on_error = if (mode == .collect) .fail_fast else .collect } else patch });
        const options: P.Options = if (runtime) .{ .policy = patch } else .{};
        var scratch: markup.FixedSourceValidationScratch(3) = .{};
        const doc = P.validateIn(&parsed.document.?, .{ .attribute_keys = &scratch.keys }, markup.diagnostic.discard, options);
        const source = P.validateSourceIn(text, scratch.storage(), markup.diagnostic.discard, options);
        const scope = P.validateScopeIn(text, header, .{ .attribute_keys = &scratch.keys }, markup.diagnostic.discard, options);
        const fast = mode == .fail_fast and severity == .err;
        for ([_]markup.ValidationResult{ doc, source, scope }, 0..) |r, index| {
            try equal(if (fast) .error_stopped else .complete, std.meta.activeTag(r.completion));
            try equal(@as(u64, if (severity == .warning) 0 else if (fast) 1 else if (index == 2) 2 else 3), r.errors);
            try equal(@as(u64, if (severity == .err) 0 else if (index == 2) 2 else 3), r.warnings);
            try equal(markup.reporting.Delivery.complete, r.diagnostic_delivery);
        }
        const dpatch: dot.Policy = .{ .scanner = scanner, .on_error = mode, .validation = .{ .graph = .{ .operator_mismatch = severity } } };
        const D = dot.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{ .on_error = if (mode == .collect) .fail_fast else .collect } else dpatch });
        var d = if (runtime) try D.parseAndValidate(allocator, "graph { a -> b; c -> d; }", dot.diagnostic.discard, .{ .policy = dpatch }) else D.parseAndValidate(allocator, "graph { a -> b; c -> d; }", dot.diagnostic.discard, .{});
        defer d.deinit(allocator);
        try equal(dot.ParseOutcome.success, d.outcome);
        try equal(if (fast) .error_stopped else .completed, std.meta.activeTag(d.validation.?.outcome));
        try equal(@as(u64, if (severity == .warning) 2 else 0), d.warnings);
        try expect(d.diagnostic_stop == null);
    };
}

test "fail-fast syntax ends the combined child but explicit local validation is independent" {
    const P = markup.Profile(.{ .policy = .{ .mode = .structural, .on_error = .fail_fast } });
    const text = "<p q=1/><x a='1' a='2'/>";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    var child = try P.parseAndValidate(allocator, try markup.Fragment.init(text, 50), bag.sink(), .{});
    defer child.deinit();
    try expect(child.parse.outcome == .invalid_syntax and child.validation == null);
    try expect(child.has_errors and !child.stopped());
    try equal(@as(usize, 1), bag.items().len);
    const explicit = P.validateSource(allocator, text, bag.sink(), .{});
    try equal(.error_stopped, explicit.completion);
    try equal(@as(u64, 1), explicit.errors);
    try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[1].code);
    try equal(markup.reporting.Delivery.complete, explicit.diagnostic_delivery);
}

test "each parent child on_error combination respects its own operation boundary" {
    inline for (.{ .fail_fast, .collect }) |outer| inline for (.{ .fail_fast, .collect }) |inner| {
        const P = markup.Profile(.{ .policy = .{ .mode = .structural, .on_error = inner } });
        const ready = P.prepare(.{});
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var visited: u32 = 0;
        for ([_][]const u8{ "<a x='1' x='2' x='3'/>", "<b y='1' y='2'/>" }) |text| {
            var child = try ready.parseAndValidate(allocator, try markup.Fragment.init(text, 0), bag.sink(), .{});
            defer child.deinit();
            visited += 1;
            try expect(child.has_errors and !child.stopped());
            try expect(child.parse.document != null);
            if (child.shouldStop(outer)) break;
        }
        try equal(@as(u32, if (outer == .fail_fast) 1 else 2), visited);
        try equal(@as(usize, if (inner == .fail_fast) visited else if (outer == .fail_fast) 2 else 3), bag.items().len);
    };
}

test "unsupported markup is never silently accepted or automatically a batch stop" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| inline for (.{ .fail_fast, .collect }) |mode| inline for (.{ .err, .warning, .silent }) |unsupported| {
        const patch: markup.Policy = .{ .mode = .structural, .scanner = scanner, .on_error = mode, .diagnostics = .{ .unsupported = unsupported } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{ .mode = .structural, .diagnostics = .{ .unsupported = .silent } } else patch });
        const options: P.Options = if (runtime) .{ .policy = patch } else .{};
        for ([_][]const u8{ "<?pi?>", "<!DOCTYPE x>", "\xff\xfe<a/>" }) |text| {
            var bag: markup.FixedDiagnosticBag(8) = .{};
            var storage: markup.FixedDocumentStorage(.{ .nodes = 8, .attributes = 2 }) = .{};
            var child = try P.parseAndValidate(allocator, try markup.Fragment.init(text, 7), bag.sink(), if (runtime) .{ .policy = patch } else .{});
            defer child.deinit();
            const fixed = try P.parseAndValidateIn(try markup.Fragment.init(text, 7), .{ .document = storage.storage() }, .{}, markup.diagnostic.discard, options);
            const measured = P.measureIn(text, .{}, markup.diagnostic.discard, options);
            try std.testing.expectEqualDeep(child.parse.outcome, measured.outcome);
            try equal(child.parse.warnings, measured.warnings);
            try expect(child.parse.outcome == .unsupported_feature and child.validation == null and child.parse.document == null);
            try expect(!child.documentValid() and !child.stopped() and !fixed.stopped());
            try equal(unsupported == .err, child.has_errors);
            try equal(unsupported == .err, child.shouldStop(.fail_fast));
            try expect(!child.shouldStop(.collect));
            try equal(@as(usize, if (unsupported == .silent) 0 else 1), bag.items().len);
            try equal(@as(u32, if (unsupported == .warning) 1 else 0), child.parse.warnings);
            if (unsupported != .silent) {
                try equal(@as(u32, 7), bag.items()[0].span.start);
                try equal(if (unsupported == .err) markup.diagnostic.Severity.err else .warning, bag.items()[0].code.severity());
            }
        }
    };
}

test "DOT unsupported reporting is separate from passthrough and continuation" {
    const text = "graph { a [label=<b>]; c [label=<d>]; }";
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| inline for (.{ .fail_fast, .collect }) |mode| inline for (.{ .err, .warning, .silent }) |unsupported| {
        const patch: dot.Policy = .{ .scanner = scanner, .on_error = mode, .markup = .none, .diagnostics = .{ .unsupported = unsupported } };
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else patch });
        var bag: dot.FixedDiagnosticBag(8) = .{};
        const r = if (runtime) try P.measureIn(text, .{}, bag.sink(), .{ .policy = patch }) else P.measureIn(text, .{}, bag.sink(), .{});
        const count: usize = if (mode == .fail_fast and unsupported == .err) 1 else 2;
        try equal(dot.ParseOutcome.unsupported_feature, r.outcome);
        try equal(@as(u32, 0), r.syntax_errors);
        try equal(if (mode == .fail_fast and unsupported == .err) dot.Completion.incomplete else .complete, r.completion);
        try equal(if (unsupported == .silent) @as(usize, 0) else count, bag.items().len);
        try equal(@as(u32, @intCast(if (unsupported == .warning) count else 0)), r.warnings);
        for (bag.items()) |d| try equal(if (unsupported == .err) dot.Severity.err else .warning, d.code.severity());
        const Passthrough = dot.Profile(.{ .policy = .{ .scanner = scanner, .on_error = mode, .markup = .passthrough, .diagnostics = .{ .unsupported = unsupported } } });
        bag.reset();
        const accepted = Passthrough.measureIn(text, .{}, bag.sink(), .{});
        try equal(dot.ParseOutcome.success, accepted.outcome);
        try equal(@as(usize, 0), bag.items().len);
    };
}

test "actual destination stops still end both levels including terminal unsupported findings" {
    const M = markup.Profile(.{ .policy = .{ .mode = .structural, .diagnostics = .{ .unsupported = .warning } } });
    var bag: markup.FixedDiagnosticBag(1) = .{};
    var child = try M.parseAndValidate(allocator, try markup.Fragment.init("<?pi?>", 0), bag.sink(), .{});
    defer child.deinit();
    try expect(!child.has_errors and child.stopped() and child.shouldStop(.collect));
    try equal(markup.reporting.StopReason.requested, child.parse.diagnostic_stop.?);
    const D = dot.Profile(.{ .policy = .{ .markup = .none, .diagnostics = .{ .unsupported = .warning } } });
    var outer: dot.FixedDiagnosticBag(1) = .{};
    const d = D.measureIn("graph <id> {}", .{}, outer.sink(), .{});
    try equal(dot.ParseOutcome.unsupported_feature, d.outcome);
    try equal(dot.reporting.StopReason.requested, d.diagnostic_stop.?);
    try equal(dot.reporting.Delivery.complete, d.diagnostic_delivery);
}

test "unsupported warnings do not erase earlier syntax errors in a child" {
    inline for (.{ .warning, .silent }) |unsupported| {
        const P = markup.Profile(.{ .policy = .{ .mode = .structural, .diagnostics = .{ .unsupported = unsupported } } });
        var child = try P.parseAndValidate(allocator, try markup.Fragment.init("</extra><?pi?>", 0), markup.diagnostic.discard, .{});
        defer child.deinit();
        try equal(@as(u32, 1), child.parse.syntax_errors);
        try expect(child.has_errors and !child.stopped());
        try expect(child.shouldStop(.fail_fast) and !child.shouldStop(.collect));
    }
}

test "DOT non-error unsupported input stays partition invariant with fail-fast" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| inline for (.{ .warning, .silent }) |unsupported| {
        const patch: dot.Policy = .{ .scanner = scanner, .on_error = .fail_fast, .markup = .none, .diagnostics = .{ .unsupported = unsupported }, .execution = .{ .metering = true } };
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else patch });
        const text = "graph { a [label=<b>]; c [label=<d>]; e[x=]; f[x=]; }";
        var one_bag: dot.FixedDiagnosticBag(8) = .{};
        var step_bag: dot.FixedDiagnosticBag(8) = .{};
        var one_pools: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .attributes = 8 }) = .{};
        var step_pools: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .attributes = 8 }) = .{};
        const options: P.FixedParseOptions = if (runtime) .{ .policy = patch } else .{};
        const one = if (runtime) try P.parseBorrowedIn(text, .{ .document = one_pools.storage() }, one_bag.sink(), options) else P.parseBorrowedIn(text, .{ .document = one_pools.storage() }, one_bag.sink(), options);
        var session = if (runtime) try P.Session.init(text, .{ .document = step_pools.storage() }, step_bag.sink(), options) else P.Session.init(text, .{ .document = step_pools.storage() }, step_bag.sink(), options);
        defer session.deinit();
        var steps: u32 = 0;
        while (session.result() == null) : (steps += 1) {
            try expect(steps < 2000);
            const progress = if (runtime) try session.advance(1) else session.advance(1);
            try expect(progress.work_used <= 1);
        }
        const result = session.result().?;
        try equal(dot.ParseOutcome.invalid_syntax, result.outcome);
        try equal(@as(u32, 1), result.syntax_errors);
        try std.testing.expectEqualDeep(one, result);
        try std.testing.expectEqualSlices(dot.Diagnostic, one_bag.items(), step_bag.items());
        _ = session.run();
        try std.testing.expectEqualSlices(dot.Diagnostic, one_bag.items(), step_bag.items());
    };
}

test "fail-fast applies to every markup validation finding and sink stop wins" {
    inline for ([_]@FieldType(markup.Policy, "validation"){ .{ .invalid_utf8 = .err, .duplicate_attribute = .off }, .{ .names = .{ .severity = .err }, .duplicate_attribute = .off }, .{ .references = .{ .severity = .err }, .duplicate_attribute = .off } }) |rules| {
        const P = markup.Profile(.{ .policy = .{ .mode = .structural, .on_error = .fail_fast, .validation = rules } });
        const text = "<a\xff/><a\xff/>&unknown;&absent;";
        var parsed = Structural.parseBorrowed(allocator, text, markup.diagnostic.discard, .{});
        defer parsed.deinit();
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const checked = P.validateIn(&parsed.document.?, .{}, bag.sink(), .{});
        try equal(.error_stopped, checked.completion);
        try equal(@as(u64, 1), checked.errors);
        try equal(@as(usize, 1), bag.items().len);
        var full: markup.FixedDiagnosticBag(1) = .{};
        const stop = P.validateIn(&parsed.document.?, .{}, full.sink(), .{});
        try equal(markup.reporting.StopReason.requested, stop.completion.diagnostic_stopped);
        try equal(@as(u64, 1), stop.errors);
        var empty: markup.FixedDiagnosticBag(0) = .{};
        const rejected = P.validateIn(&parsed.document.?, .{}, empty.sink(), .{});
        try equal(markup.reporting.StopReason.capacity, rejected.completion.diagnostic_stopped);
        try equal(markup.reporting.Delivery.failed, rejected.diagnostic_delivery);
    }
}

test "DOT terminal validation resource failures preserve sink acknowledgment" {
    const P = dot.Profile(.{ .policy = .{ .validation = .{ .repeated_attribute = .err } } });
    inline for (.{ 0, 1 }) |capacity| {
        var bag: dot.FixedDiagnosticBag(capacity) = .{};
        var result = P.parseAndValidate(allocator, "graph { a[x=1 x=2]; }", bag.sink(), .{});
        defer result.deinit(allocator);
        try expect(result.outcome == .success and result.document != null);
        try expect(result.validation.?.outcome == .insufficient_scratch);
        try equal(if (capacity == 0) dot.reporting.StopReason.capacity else .requested, result.diagnostic_stop.?);
        try equal(result.diagnostic_stop, result.validation.?.diagnostic_stop);
    }
}
