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

test "structural recovery reports independent findings without publishing a tree" {
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
        var parsed = markup.parseBorrowed(std.testing.allocator, case.source, bag.sink(), .{});
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
        const fixed = markup.parseBorrowedIn(case.source, .{ .document = nodes.storage(), .scratch = frames.storage() }, fixed_bag.sink(), .{});
        try equal(parsed.outcome, fixed.outcome);
        try equal(parsed.completion, fixed.completion);
        try equal(parsed.syntax_errors, fixed.syntax_errors);
        try equal(parsed.counts, fixed.counts);
        try expect(fixed.document == null);
        try std.testing.expectEqualSlices(markup.Diagnostic, bag.items(), fixed_bag.items());
        const measured = markup.measureIn(case.source, frames.storage(), discard, .{});
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
        var session = Dynamic.Session.init(source, memory, b.sink(), .{ .policy = p });
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
        session.reset(source, discard, .{});
        try equal(@as(u32, 1), session.run().syntax_errors); // compiled baseline restored
        session.reset("<ok/>", discard, .{});
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
