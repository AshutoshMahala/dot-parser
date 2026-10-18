//! Diagnostics-only recovery: traversal continues, retained output never does.
const std = @import("std");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const discard = markup.diagnostic.discard;

test "collect is the markup recovery default and presets expose the same two choices" {
    try equal(@as(usize, 2), std.meta.fields(markup.OnError).len);
    try equal(markup.OnError.collect, markup.Profile(.{}).baseline.on_error);
    try equal(markup.OnError.collect, markup.presets.standard.on_error.?);
    try equal(markup.OnError.collect, markup.presets.untrusted.on_error.?);
    try equal(markup.OnError.fail_fast, markup.Profile(.{ .policy = .{ .on_error = .fail_fast } }).baseline.on_error);
}

test "closing typo recovery is configurable without accepting or repairing syntax" {
    const Case = struct { source: []const u8, exact: u32, one: u32, two: u32 };
    for ([_]Case{
        .{ .source = "<config><server></servr></config>", .exact = 2, .one = 1, .two = 1 },
        .{ .source = "<config><sever></server></config>", .exact = 2, .one = 1, .two = 1 },
        .{ .source = "<config><server></serverr></config>", .exact = 2, .one = 1, .two = 1 },
        .{ .source = "<config><server></srever></config>", .exact = 2, .one = 1, .two = 1 },
        .{ .source = "<config><server></serxer></config>", .exact = 2, .one = 1, .two = 1 },
        .{ .source = "<config><server></serveq></config>", .exact = 2, .one = 1, .two = 1 },
        .{ .source = "<config><configuration></confguratin></config>", .exact = 2, .one = 2, .two = 1 },
        .{ .source = "<config><configuration></ocnfiguratiom></config>", .exact = 2, .one = 2, .two = 1 },
        // Exact ancestors always win, even if the top is within one edit.
        .{ .source = "<servers><server></servers>", .exact = 1, .one = 1, .two = 1 },
        // Small names never guess; a short two-edit collision remains ignored.
        .{ .source = "<config><a></b></config>", .exact = 2, .one = 2, .two = 2 },
        .{ .source = "<config><server></sender></server></config>", .exact = 1, .one = 1, .two = 1 },
        // Intent is unknown. These document genuine false-positive tradeoffs:
        // a guessed top closure makes the later exact closer unexpected.
        .{ .source = "<config><items></item></items></config>", .exact = 1, .one = 2, .two = 2 },
        .{ .source = "<config><server_name></sender_name></server_name></config>", .exact = 1, .one = 1, .two = 2 },
        // Never fuzzy-search ancestors. Only unrelated is eligible here.
        .{ .source = "<config><server><unrelated></servr></server></config>", .exact = 2, .one = 2, .two = 2 },
    }) |case| inline for (.{ .exact, .one_edit, .two_edits }, .{ case.exact, case.one, case.two }) |strategy, errors| {
        const P = markup.Profile(.{ .policy = .{ .mode = .structural, .closing_tag_recovery = strategy } });
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var parsed = P.parseBorrowed(std.testing.allocator, case.source, bag.sink(), .{});
        defer parsed.deinit();
        errdefer std.debug.print("recovery case '{s}', strategy={s}\n", .{ case.source, @tagName(strategy) });
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try equal(markup.Completion.complete, parsed.completion);
        try equal(errors, parsed.syntax_errors);
        try equal(@as(usize, errors), bag.items().len);
        try equal(@as(u32, 0), parsed.accepted_deviations);
        try expect(parsed.document == null);
        try equal(markup.diagnostic.Code.mismatched_tag, bag.items()[0].code);
        for (bag.items()) |finding| try expect(finding.suggestedFix() == null);
    };
}

test "typo recovery keeps later independent errors and the original frozen prefix" {
    const source = "<config><server></servr><later x=0/><name>fish & chips</name></config>";
    const P = markup.Profile(.{ .policy = .{ .mode = .structural, .retention = .{ .partial = true } } });
    var bag: markup.FixedDiagnosticBag(16) = .{};
    var parsed = P.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit();
    try equal(markup.Outcome.invalid_syntax, parsed.outcome);
    try equal(markup.Completion.complete, parsed.completion);
    try equal(@as(u32, 3), parsed.syntax_errors);
    try equal(markup.diagnostic.Code.mismatched_tag, bag.items()[0].code);
    try equal(markup.diagnostic.Code.unexpected_byte, bag.items()[1].code);
    try equal(markup.diagnostic.Code.malformed_reference, bag.items()[2].code);
    const doc = parsed.document.?;
    try equal(@as(u32, 2), doc.nodeCount());
    try expect(!doc.scopeComplete());
    var roots = doc.roots();
    const root = roots.next().?;
    var children = root.children();
    const child = children.next().?;
    try std.testing.expectEqualStrings("server", child.name().?);
    try expect(!child.scopeComplete());
    try expect(children.next() == null);
}

test "typo policies inherit and latch across fixed runtime scanner and execution paths" {
    try equal(markup.ClosingTagRecovery.one_edit, markup.Profile(.{}).baseline.closing_tag_recovery);
    try equal(markup.ClosingTagRecovery.one_edit, markup.presets.standard.closing_tag_recovery.?);
    try equal(markup.ClosingTagRecovery.one_edit, markup.presets.untrusted.closing_tag_recovery.?);
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .structural, .closing_tag_recovery = .exact } });
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .exact, .one_edit, .two_edits }) |strategy| inline for (.{ .collect, .fail_fast }) |on_error| {
        const source = if (strategy == .two_edits) "<config><configuration></ocnfiguratiom></config>" else "<config><server></servr></config>";
        const p: markup.Policy = .{ .mode = .structural, .scanner = scanner, .closing_tag_recovery = strategy, .on_error = on_error, .execution = .{ .metering = true, .cancellation = true } };
        const P = markup.Profile(.{ .policy = p });
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 4 }) = .{};
        var frames: markup.FixedParseScratch(4) = .{};
        const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
        var first: markup.FixedDiagnosticBag(8) = .{};
        const expected = P.parseBorrowedIn(source, memory, first.sink(), .{});
        var reference_work: ?u64 = null;
        for ([_]u32{ 1, 7, 256 }) |budget| {
            var second: markup.FixedDiagnosticBag(8) = .{};
            var session = (try Dynamic.Session.init(source, memory, second.sink(), .{ .policy = p }));
            defer session.deinit();
            var work: u64 = 0;
            while (true) {
                try equal(@as(u32, 0), (try session.advance(0)).work_used);
                const progress = try session.advance(budget);
                try expect(progress.work_used <= budget);
                work += progress.work_used;
                try expect(work < source.len * 16);
                if (progress.outcome != null) break;
            }
            if (reference_work) |prior| try equal(prior, work) else reference_work = work;
            try deep(expected, session.result().?);
            try std.testing.expectEqualSlices(markup.Diagnostic, first.items(), second.items());
            try equal(markup.Outcome.invalid_syntax, expected.outcome);
            try equal(if (on_error == .fail_fast) markup.Completion.incomplete else .complete, expected.completion);
            try equal(@as(u32, if (on_error == .collect and strategy == .exact) 2 else 1), expected.syntax_errors);
            try session.reset(source, discard, .{});
            try equal(@as(u32, 2), session.run().syntax_errors); // exact-only baseline restored
        }
    };
}

test "Graphviz typo recovery folds ASCII while structural names stay byte exact" {
    const source = "<table></TaBl>";
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .structural, .graphviz }) |mode| {
        const P = markup.Profile(.{ .policy = .{ .mode = mode, .scanner = scanner } });
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = P.measure(std.testing.allocator, source, bag.sink(), .{});
        try equal(markup.Outcome.invalid_syntax, r.outcome);
        try equal(@as(u32, if (mode == .graphviz) 1 else 2), r.syntax_errors);
        try equal(markup.diagnostic.Code.mismatched_tag, bag.items()[0].code);
        const Fast = markup.Profile(.{ .policy = .{ .mode = mode, .scanner = scanner, .on_error = .fail_fast } });
        const fast = Fast.measure(std.testing.allocator, source, discard, .{});
        try equal(markup.Completion.incomplete, fast.completion);
        try equal(@as(u32, 1), fast.syntax_errors);
    };
}

test "mutated long names have fuzzy recovery parity across scanners and pause boundaries" {
    const parts = [_][]const u8{ "<config>", "</config>", "<configuration>", "</ocnfiguratiom>", "</configuration>", "<server>", "</servr>", "</sender>", "<items>", "</item>", "<later x=0/>", "<x q='", "&bad ", "<!--ok-->" };
    var prng = std.Random.DefaultPrng.init(0x873baef);
    const random = prng.random();
    inline for (.{ .exact, .one_edit, .two_edits }) |strategy| {
        const P = markup.Profile(.{ .policy = .{ .mode = .structural, .closing_tag_recovery = strategy } });
        for (0..512) |_| {
            var buffer: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            for (0..16) |_| try writer.writeAll(parts[random.uintLessThan(usize, parts.len)]);
            const source = writer.buffered()[0..random.uintLessThan(usize, writer.end + 1)];
            var nodes: markup.FixedDocumentStorage(.{ .nodes = 64, .attributes = 64 }) = .{};
            var frames: markup.FixedParseScratch(32) = .{};
            const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
            var first: markup.FixedDiagnosticBag(64) = .{};
            const expected = P.parseBorrowedIn(source, memory, first.sink(), .{});
            inline for (.{ .scalar, .block }) |scanner| {
                const S = markup.Profile(.{ .policy = .{ .mode = .structural, .scanner = scanner, .closing_tag_recovery = strategy, .execution = .{ .metering = true } } });
                var second: markup.FixedDiagnosticBag(64) = .{};
                var session = S.Session.init(source, memory, second.sink(), .{});
                defer session.deinit();
                var work: u64 = 0;
                while (true) {
                    const progress = session.advance(1 + random.uintLessThan(u32, 8));
                    work += progress.work_used;
                    try expect(work <= source.len * 16 + 32);
                    if (progress.outcome != null) break;
                }
                try deep(expected, session.result().?);
                try std.testing.expectEqualSlices(markup.Diagnostic, first.items(), second.items());
            }
        }
    }
}

test "structural recovery reports independent findings without publishing a tree" {
    const Structural = markup.Profile(.{ .policy = .{ .mode = .structural } });
    const Case = struct { source: []const u8, errors: u32 };
    for ([_]Case{
        .{ .source = "<a><b></a><c/>", .errors = 1 },
        .{ .source = "<a></wrong><b/></a>", .errors = 1 },
        .{ .source = "<a><a><b></a></a>", .errors = 1 },
        .{ .source = "<aa><ab><ac></aa>", .errors = 1 },
        .{ .source = "<A><a><b></A>", .errors = 1 },
        .{ .source = "</x></y><ok/>", .errors = 2 },
        .{ .source = "<a><b>", .errors = 2 },
        .{ .source = "<a></b>", .errors = 2 },
        .{ .source = "&; <x a='&;'> &bad </x></extra>", .errors = 4 },
    }) |case| {
        var bag: markup.FixedDiagnosticBag(32) = .{};
        var parsed = Structural.parseBorrowed(std.testing.allocator, case.source, bag.sink(), .{});
        defer parsed.deinit();
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try equal(markup.Completion.complete, parsed.completion);
        try equal(case.errors, parsed.syntax_errors);
        try equal(@as(usize, case.errors), bag.items().len);
        try equal(@as(u32, 0), parsed.accepted_deviations);
        try expect(parsed.document == null);
        var frames: markup.FixedParseScratch(8) = .{};
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 8 }) = .{};
        var fixed_bag: markup.FixedDiagnosticBag(32) = .{};
        const fixed = Structural.parseBorrowedIn(case.source, .{ .document = nodes.storage(), .scratch = frames.storage() }, fixed_bag.sink(), .{});
        try equal(parsed.outcome, fixed.outcome);
        try equal(parsed.completion, fixed.completion);
        try equal(parsed.syntax_errors, fixed.syntax_errors);
        try equal(parsed.counts, fixed.counts);
        try expect(fixed.document == null);
        try std.testing.expectEqualSlices(markup.Diagnostic, bag.items(), fixed_bag.items());
        const measured = Structural.measureIn(case.source, frames.storage(), discard, .{});
        try equal(parsed.counts, measured.counts);
        try equal(parsed.syntax_errors, measured.syntax_errors);
        try equal(parsed.completion, measured.completion);
    }
}

test "EOF reports open elements innermost first without fabricated closing tags" {
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const source = "<outer><inner>";
    const r = markup.measure(std.testing.allocator, source, bag.sink(), .{});
    try equal(markup.Completion.complete, r.completion);
    try equal(@as(u32, 2), r.syntax_errors);
    try std.testing.expectEqualStrings("inner", bag.items()[0].related.?.slice(source));
    try std.testing.expectEqualStrings("outer", bag.items()[1].related.?.slice(source));
    for (bag.items()) |d| {
        try equal(markup.diagnostic.Code.unclosed_element, d.code);
        try equal(@as(u32, source.len), d.span.start);
        try expect(d.suggestedFix() == null);
    }
}

test "reference acceptance remains independent of recovery and preserves factual counters" {
    inline for (.{ .reject, .warn, .accept }) |acceptance| {
        const P = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = acceptance } } });
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = P.parseBorrowedIn("</bad>&; &;", .{}, bag.sink(), .{});
        try equal(markup.Outcome.invalid_syntax, r.outcome);
        try equal(markup.Completion.complete, r.completion);
        try equal(@as(u32, if (acceptance == .reject) 3 else 1), r.syntax_errors);
        try equal(@as(u32, if (acceptance == .reject) 0 else 2), r.accepted_deviations);
        try equal(@as(u32, if (acceptance == .warn) 2 else 0), r.warnings);
        try equal(@as(usize, if (acceptance == .accept) 1 else 3), bag.items().len);
        try expect(r.document == null);
    }
}

test "uncertain lexical boundaries stop recovery without cascading EOF findings" {
    for ([_][]const u8{ "<a x=0", "<a x='", "<!--", "<![CDATA[", "<1/>", "<a>\x00" }) |suffix| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "</bad><outer>{s}", .{suffix});
        defer std.testing.allocator.free(source);
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = markup.measure(std.testing.allocator, source, bag.sink(), .{});
        try equal(markup.Outcome.invalid_syntax, r.outcome);
        try equal(markup.Completion.incomplete, r.completion);
        try equal(@as(u32, 2), r.syntax_errors);
        try equal(@as(usize, 2), bag.items().len);
        try expect(bag.items()[1].code != .unclosed_element);
    }
    const unsupported = markup.measure(std.testing.allocator, "</bad><?pi?>", discard, .{});
    try expect(unsupported.outcome == .unsupported_feature);
    try equal(markup.Completion.incomplete, unsupported.completion);
    try equal(@as(u32, 1), unsupported.syntax_errors);
}

test "sink stop and failure terminate recovery immediately and preserve rejected count" {
    var last: markup.FixedDiagnosticBag(1) = .{};
    const stopped = markup.measureIn("</a></b>", .{}, last.sink(), .{});
    try equal(markup.Outcome{ .diagnostic_stopped = .requested }, stopped.outcome);
    try equal(markup.reporting.Delivery.complete, stopped.diagnostic_delivery);
    try equal(markup.Completion.incomplete, stopped.completion);
    try equal(@as(u32, 1), stopped.syntax_errors);
    const Reject = struct {
        calls: u32 = 0,
        fn emit(context: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return error.DiagnosticSinkFailure;
        }
    };
    var reject: Reject = .{};
    const failed = markup.measureIn("</a></b>", .{}, .{ .context = &reject, .emit_fn = Reject.emit }, .{});
    try expect(failed.outcome == .diagnostic_stopped);
    try equal(markup.reporting.Delivery.failed, failed.diagnostic_delivery);
    try equal(@as(u32, 1), failed.syntax_errors);
    try equal(@as(u32, 1), reject.calls);
    // An unterminated quote is already terminal: delivery failure cannot replace it.
    var empty: markup.FixedDiagnosticBag(0) = .{};
    const terminal = markup.measureIn("<a x='", .{}, empty.sink(), .{});
    try equal(markup.Outcome.invalid_syntax, terminal.outcome);
    try equal(markup.reporting.Delivery.failed, terminal.diagnostic_delivery);
    try equal(@as(u32, 1), terminal.syntax_errors);
    var omitted: markup.reporting.FixedBag(markup.Diagnostic, 0, .omit) = .{};
    const complete = markup.measureIn("</a></b>", .{}, omitted.sink(), .{});
    try equal(markup.Completion.complete, complete.completion);
    try equal(@as(u32, 2), complete.syntax_errors);
    try equal(@as(usize, 2), omitted.omitted);
}

test "after rejection output pools stop growing but scratch and policy limits still apply" {
    var frames: markup.FixedParseScratch(4) = .{};
    const source = "</bad><a x='1'><b/><c>text</c></a>";
    const r = markup.parseBorrowedIn(source, .{ .scratch = frames.storage() }, discard, .{});
    try equal(markup.Outcome.invalid_syntax, r.outcome);
    try equal(markup.Completion.complete, r.completion);
    try equal(markup.Counts{ .nodes = 4, .elements = 3, .attributes = 1, .max_depth = 2 }, r.counts);
    try expect(r.document == null);
    const no_scratch = markup.parseBorrowedIn(source, .{}, discard, .{});
    try equal(markup.Outcome{ .storage_exhausted = .nesting_frames }, no_scratch.outcome);
    try equal(@as(u32, 1), no_scratch.syntax_errors);
    inline for (.{ .{ "max_nodes", "</bad><a/>" }, .{ "max_attributes", "</bad><a x='1'/>" }, .{ "max_nesting", "</bad><a/>" } }) |case| {
        const P = markup.Profile(.{ .policy = .{ .limits = value: {
            var v: @FieldType(markup.Policy, "limits") = .{};
            @field(v, case[0]) = 0;
            break :value v;
        } } });
        const limited = P.parseBorrowedIn(case[1], .{}, discard, .{});
        try expect(limited.outcome == .resource_limit);
        try equal(@as(u32, 1), limited.syntax_errors);
        try equal(markup.Completion.incomplete, limited.completion);
    }
}

test "recovery has compile-time runtime scanner and execution parity, including reset" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .on_error = .fail_fast } });
    const source = "<aa><bb><cc></aa></bad>&;";
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .fail_fast, .collect }) |recovery| inline for (.{ false, true }) |metered| inline for (.{ false, true }) |cancellable| {
        const p: markup.Policy = .{ .scanner = scanner, .on_error = recovery, .execution = .{ .metering = metered, .cancellation = cancellable } };
        const P = markup.Profile(.{ .policy = p });
        var frames: markup.FixedParseScratch(4) = .{};
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 8 }) = .{};
        const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
        var a: markup.FixedDiagnosticBag(16) = .{};
        var b: markup.FixedDiagnosticBag(16) = .{};
        const expected = P.parseBorrowedIn(source, memory, a.sink(), .{});
        var session = (try Dynamic.Session.init(source, memory, b.sink(), .{ .policy = p }));
        defer session.deinit();
        if (metered) {
            var work: u64 = 0;
            while (true) {
                const progress = try session.advance(1);
                work += progress.work_used;
                try expect(work < source.len * 10 + 100);
                if (progress.outcome != null) break;
            }
        } else _ = session.run();
        try deep(expected, session.result().?);
        try std.testing.expectEqualSlices(markup.Diagnostic, a.items(), b.items());
        try equal(@as(u32, if (recovery == .fail_fast) 1 else 3), expected.syntax_errors);
        try equal(if (recovery == .fail_fast) markup.Completion.incomplete else .complete, expected.completion);
        try session.reset(source, discard, .{});
        try equal(@as(u32, 1), session.run().syntax_errors); // compiled baseline restored
        try session.reset("<ok/>", discard, .{});
        try equal(markup.Completion.complete, session.run().completion);
    };
}

test "ancestor searches are collectively source-bounded and partition-independent" {
    const source = "<aa>" ** 128 ++ "</ab>" ** 128;
    var reference_work: ?u64 = null;
    inline for (.{ .scalar, .block }) |scanner| {
        const P = markup.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } });
        for ([_]u32{ 1, 7, 256 }) |budget| {
            var frames: markup.FixedParseScratch(128) = .{};
            var nodes: markup.FixedDocumentStorage(.{ .nodes = 128 }) = .{};
            var bag: markup.FixedDiagnosticBag(32) = .{};
            var session = P.Session.init(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, bag.sink(), .{});
            defer session.deinit();
            var work: u64 = 0;
            while (true) {
                try equal(@as(u32, 0), session.advance(0).work_used);
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                work += progress.work_used;
                try expect(work < source.len * 10);
                if (progress.outcome != null) break;
            }
            if (reference_work) |prior| try equal(prior, work) else reference_work = work;
            const r = session.result().?;
            try equal(markup.Outcome{ .resource_limit = .{ .resource = .recovery_work, .limit = source.len } }, r.outcome);
            try equal(markup.Completion.incomplete, r.completion);
            try expect(r.syntax_errors > 0 and r.syntax_errors < 128);
            try equal(@as(usize, r.syntax_errors) + 1, bag.items().len);
            try expect(r.document == null);
            try deep(r, session.cancel());
            try deep(r, session.run());
            try equal(@as(u32, 0), session.advance(1).work_used);
        }
    }
}

test "cancellation during recovery preserves known errors and does no further work" {
    const P = markup.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    const Request = struct {
        stop: bool = false,
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.stop;
        }
    };
    var request: Request = .{};
    var frames: markup.FixedParseScratch(4) = .{};
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 4 }) = .{};
    var session = P.Session.init("<aa><bb><cc></aa>", .{ .document = nodes.storage(), .scratch = frames.storage() }, discard, .{ .cancellation = .{ .context = &request, .is_requested = Request.poll } });
    defer session.deinit();
    while (session.advance(1).syntax_errors == 0) {}
    request.stop = true;
    const progress = session.advance(0);
    try equal(@as(u32, 0), progress.work_used);
    const r = session.result().?;
    try equal(markup.Outcome.cancelled, r.outcome);
    try equal(@as(u32, 1), r.syntax_errors);
    try equal(markup.Completion.incomplete, r.completion);
    try expect(r.document == null);
    try deep(r, session.run());
}

test "mutated fragments preserve recovery results across scanners and budget partitions" {
    const parts = [_][]const u8{ "<a>", "</a>", "<bb>", "</bb>", "</cc>", "<x/>", "&;", "&#0;", "x", "<!--ok-->", "<![CDATA[<x>]]>", "<x a='&;'/>", "<x a='", "\x00" };
    var prng = std.Random.DefaultPrng.init(0x5eeda11);
    const random = prng.random();
    for (0..256) |_| {
        var bytes: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        for (0..16) |_| try writer.writeAll(parts[random.uintLessThan(usize, parts.len)]);
        const source = writer.buffered()[0..random.uintLessThan(usize, writer.end + 1)];
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 128, .attributes = 64 }) = .{};
        var frames: markup.FixedParseScratch(64) = .{};
        const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
        var first_bag: markup.reporting.FixedBag(markup.Diagnostic, 128, .omit) = .{};
        const expected = markup.parseBorrowedIn(source, memory, first_bag.sink(), .{});
        inline for (.{ .scalar, .block }) |scanner| {
            const P = markup.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } });
            var bag: markup.reporting.FixedBag(markup.Diagnostic, 128, .omit) = .{};
            var session = P.Session.init(source, memory, bag.sink(), .{});
            defer session.deinit();
            var work: u64 = 0;
            while (true) {
                const p = session.advance(1 + random.uintLessThan(u32, 8));
                work += p.work_used;
                try expect(work < source.len * 16 + 100);
                if (p.outcome != null) break;
            }
            const got = session.result().?;
            try equal(expected.outcome, got.outcome);
            try equal(expected.completion, got.completion);
            try equal(expected.syntax_errors, got.syntax_errors);
            try equal(expected.counts, got.counts);
            try equal(expected.document == null, got.document == null);
            try std.testing.expectEqualSlices(markup.Diagnostic, first_bag.items(), bag.items());
            for (bag.items()) |finding| {
                try expect(finding.span.endOffset() <= source.len);
                if (finding.related) |related| try expect(related.endOffset() <= source.len);
            }
        }
    }
}

fn allocateRecovery(allocator: std.mem.Allocator) !void {
    const source = "</bad>" ++ "<a>" ** 64 ++ "</a>" ** 64;
    var r = markup.parseBorrowed(allocator, source, discard, .{});
    defer r.deinit();
    try equal(@as(u32, 1), r.syntax_errors);
    try expect(r.document == null);
    if (r.outcome == .out_of_memory) return error.OutOfMemory;
    try equal(markup.Outcome.invalid_syntax, r.outcome);
    try equal(markup.Completion.complete, r.completion);
}

test "scratch growth failures after output abort clean up and preserve rejection" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateRecovery, .{});
}
