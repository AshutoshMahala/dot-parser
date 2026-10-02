//! Stop reasons, completion and syntax facts are independent of diagnostic delivery.
const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const source = "graph { a -- ; b; }";
const Reject = struct {
    fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!dot.DiagnosticAction {
        return error.DiagnosticSinkFailure;
    }
};

test "all DOT result adapters retain syntax facts when a sink stops or rejects" {
    inline for (.{ .scalar, .block }) |scanner| {
        inline for (.{ false, true }) |runtime| {
            const P = dot.Profile(.{ .runtime_policy = runtime, .policy = .{ .scanner = scanner } });
            var bag: dot.FixedDiagnosticBag(1) = .{};
            inline for (.{ false, true }) |reject| {
                const sink: dot.DiagnosticSink = if (reject) .{ .context = null, .emit_fn = Reject.emit } else bag.sink();
                const reason: dot.diagnostic.StopReason = if (reject) .failure else .requested;
                var checked = if (runtime) try P.parseAndValidate(std.testing.allocator, source, sink, .{}) else P.parseAndValidate(std.testing.allocator, source, sink, .{});
                defer checked.deinit(std.testing.allocator);
                try equal(dot.ParseOutcome{ .diagnostic_stopped = reason }, checked.outcome);
                try equal(@as(u32, 1), checked.syntax_errors);
                try equal(dot.Completion.incomplete, checked.completion);
                try equal(if (reject) dot.reporting.Delivery.failed else .complete, checked.diagnostic_delivery);
                try expect(checked.document == null and checked.validation == null and !checked.documentValid());

                bag = .{};
                const fixed = if (runtime) try P.parseBorrowedIn(source, .{ .document = .{} }, sink, .{}) else P.parseBorrowedIn(source, .{ .document = .{} }, sink, .{});
                try equal(checked.outcome, fixed.outcome);
                try equal(checked.syntax_errors, fixed.syntax_errors);
                try equal(checked.completion, fixed.completion);
                try expect(fixed.document == null);

                bag = .{};
                const measured = if (runtime) try P.measureIn(source, .{}, sink, .{}) else P.measureIn(source, .{}, sink, .{});
                try equal(checked.outcome, measured.outcome);
                try equal(checked.syntax_errors, measured.syntax_errors);
                try equal(checked.completion, measured.completion);
                try expect(measured.capacities == null);
                bag = .{};
            }

            // The same stopping outcome after a warning does not imply invalidity.
            const warning = if (runtime) try P.measureIn("graph { 1e3; }", .{}, bag.sink(), .{}) else P.measureIn("graph { 1e3; }", .{}, bag.sink(), .{});
            try expect(warning.outcome == .diagnostic_stopped);
            try equal(@as(u32, 0), warning.syntax_errors);
            try equal(@as(u32, 1), warning.warnings);
            try equal(dot.Completion.incomplete, warning.completion);
        }
    }
}

test "DOT facts survive limits scratch exhaustion unsupported boundaries cancellation and reset" {
    inline for (.{ .scalar, .block }) |scanner| {
        inline for (.{ false, true }) |runtime| {
            const P = dot.Profile(.{ .runtime_policy = runtime, .policy = .{ .scanner = scanner, .execution = .{ .metering = true }, .markup = .none } });
            const Limited = dot.Profile(.{ .runtime_policy = runtime, .policy = .{ .scanner = scanner, .limits = .{ .max_statements = 1 } } });
            const limited = if (runtime) try Limited.measureIn("graph { a -- ; b; c; d; }", .{}, dot.diagnostic.discard, .{}) else Limited.measureIn("graph { a -- ; b; c; d; }", .{}, dot.diagnostic.discard, .{});
            try equal(dot.ParseOutcome.resource_exhausted, limited.outcome);
            try equal(@as(u32, 1), limited.syntax_errors);
            try equal(dot.Completion.incomplete, limited.completion);

            const scratch = if (runtime) try P.measureIn("graph { a -- ; subgraph { b; } }", .{}, dot.diagnostic.discard, .{}) else P.measureIn("graph { a -- ; subgraph { b; } }", .{}, dot.diagnostic.discard, .{});
            try expect(scratch.outcome == .storage_failure);
            try equal(@as(u32, 1), scratch.syntax_errors);
            try equal(dot.Completion.incomplete, scratch.completion);

            const unsupported = if (runtime) try P.measureIn("graph { a -- ; } <x>", .{}, dot.diagnostic.discard, .{}) else P.measureIn("graph { a -- ; } <x>", .{}, dot.diagnostic.discard, .{});
            try equal(dot.ParseOutcome.unsupported_feature, unsupported.outcome);
            try equal(@as(u32, 1), unsupported.syntax_errors);
            try equal(dot.Completion.incomplete, unsupported.completion);

            var bag: dot.FixedDiagnosticBag(8) = .{};
            var session = if (runtime) try P.Session.init(source, .{ .document = .{} }, bag.sink(), .{}) else P.Session.init(source, .{ .document = .{} }, bag.sink(), .{});
            defer session.deinit();
            var steps: usize = 0;
            while (bag.items().len == 0) : (steps += 1) {
                try expect(steps < 1024);
                const progress = if (runtime) try session.advance(1) else session.advance(1);
                try equal(@as(u32, @intCast(bag.items().len)), progress.syntax_errors);
            }
            const stopped = session.cancel();
            try equal(dot.ParseOutcome.cancelled, stopped.outcome);
            try equal(@as(u32, 1), stopped.syntax_errors);
            try equal(dot.Completion.incomplete, stopped.completion);
            try std.testing.expectEqualDeep(stopped, session.run());

            if (runtime) try session.reset("graph {}", dot.diagnostic.discard, .{}) else session.reset("graph {}", dot.diagnostic.discard, .{});
            const complete = session.run();
            try equal(dot.ParseOutcome.success, complete.outcome);
            try equal(@as(u32, 0), complete.syntax_errors);
            try equal(dot.Completion.complete, complete.completion);
        }
    }
}

test "discard and omission do not erase DOT syntax rejection and EOF alone is not completion" {
    var bag: dot.reporting.FixedBag(dot.Diagnostic, 0, .omit) = .{};
    const measured = dot.measureIn("graph { a -- ; b -- ; }", .{}, bag.sink(), .{});
    try equal(dot.ParseOutcome.invalid_syntax, measured.outcome);
    try equal(@as(u32, 2), measured.syntax_errors);
    try equal(@as(u64, 2), bag.omitted);
    try equal(dot.Completion.complete, measured.completion);
    const unfinished = dot.measureIn("graph { a -- ", .{}, dot.diagnostic.discard, .{});
    try equal(dot.ParseOutcome.invalid_syntax, unfinished.outcome);
    try equal(@as(u32, 1), unfinished.syntax_errors);
    try equal(dot.Completion.incomplete, unfinished.completion);
}

test "DOT recovery discards stale attribute openers but preserves scopes and later lists" {
    const Case = struct {
        input: []const u8,
        opener: enum { root, inner, bracket } = .root,
    };
    const cases = [_]Case{
        .{ .input = "digraph {\n  b [x=];\n" },
        .{ .input = "digraph { b[x=@];" },
        .{ .input = "digraph { subgraph { b[x=];", .opener = .inner },
        .{ .input = "digraph { subgraph { b[x=] }" },
        .{ .input = "digraph { b[x=]; c[y=1", .opener = .bracket },
        .{ .input = "digraph { b[x=]; c[y=1];" },
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |metered| {
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = .{
            .scanner = scanner,
            .execution = .{ .metering = metered },
            .recovery = if (runtime) .fail_fast else .collect,
        } });
        const options: P.FixedParseOptions = if (runtime) .{ .policy = .{ .recovery = .collect } } else .{};
        for (cases, 0..) |case, index| {
            var frames: dot.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var bag: dot.FixedDiagnosticBag(8) = .{};
            const measured = if (runtime) try P.measureIn(case.input, frames.storage(), bag.sink(), options) else P.measureIn(case.input, frames.storage(), bag.sink(), options);
            try equal(dot.ParseOutcome.invalid_syntax, measured.outcome);
            try equal(dot.Completion.incomplete, measured.completion);
            try equal(@as(u32, 2), measured.syntax_errors);
            try equal(@as(usize, 2), bag.items().len);
            const last = bag.items()[1];
            try equal(dot.diagnostic.Code.syntax_unexpected_end, last.code);
            const opener_at = switch (case.opener) {
                .root => std.mem.indexOfScalar(u8, case.input, '{').?,
                .inner => std.mem.lastIndexOfScalar(u8, case.input, '{').?,
                .bracket => std.mem.lastIndexOfScalar(u8, case.input, '[').?,
            };
            try equal(@as(u32, @intCast(opener_at)), last.details.unexpected.related.?.span.start);
            try equal(@as(u32, 1), last.details.unexpected.related.?.span.len);
            try equal(dot.diagnostic.Related.Role.opened_here, last.details.unexpected.related.?.role);
            try equal(if (case.opener == .bracket) dot.diagnostic.Replacement.right_bracket else .right_brace, last.fix.?.edit.insert_before);
            try equal(@as(u32, @intCast(case.input.len)), last.fix.?.span.start);
            try equal(@as(u32, 0), last.fix.?.span.len);

            var pools: dot.FixedDocumentStorage(.{ .statements = 4, .nodes = 4, .subgraphs = 2, .attributes = 4 }) = .{};
            var session_bag: dot.FixedDiagnosticBag(8) = .{};
            const memory: dot.ParseMemory = .{ .document = pools.storage(), .scratch = frames.storage() };
            var session = if (runtime) try P.Session.init(case.input, memory, session_bag.sink(), options) else P.Session.init(case.input, memory, session_bag.sink(), options);
            defer session.deinit();
            if (metered) {
                var steps: usize = 0;
                while (session.result() == null) : (steps += 1) {
                    try expect(steps < case.input.len * 32 + 100);
                    const progress = if (runtime) try session.advance(1) else session.advance(1);
                    try expect(progress.work_used <= 1);
                }
            } else _ = session.run();
            const result = session.result().?;
            try equal(measured.outcome, result.outcome);
            try equal(measured.completion, result.completion);
            try equal(measured.syntax_errors, result.syntax_errors);
            try expect(result.document == null);
            try std.testing.expectEqualSlices(dot.Diagnostic, bag.items(), session_bag.items());

            if (scanner == .scalar and !runtime and !metered and index == 0) {
                var bytes: [4096]u8 = undefined;
                var writer = std.Io.Writer.fixed(&bytes);
                try dot.console.render(last, .{ .source = case.input }, &writer);
                try expect(std.mem.indexOf(u8, writer.buffered(), "missing '}'") != null);
                try expect(std.mem.indexOf(u8, writer.buffered(), "insert '}'") != null);
                try expect(std.mem.indexOf(u8, writer.buffered(), "insert ']'") == null);
            }
        }
    };
}

test "DOT recovery keeps the original attribute diagnostic and terminal EOF context" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .fail_fast, .collect }) |recovery| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .recovery = recovery } });
        for ([_][]const u8{ "digraph { b[x=1 }", "digraph { b[x=1" }) |input| {
            var bag: dot.FixedDiagnosticBag(8) = .{};
            const result = P.measureIn(input, .{}, bag.sink(), .{});
            try equal(dot.ParseOutcome.invalid_syntax, result.outcome);
            try equal(@as(u32, 1), result.syntax_errors);
            try equal(@as(usize, 1), bag.items().len);
            const d = bag.items()[0];
            try equal(@as(u32, @intCast(std.mem.indexOfScalar(u8, input, '[').?)), d.details.unexpected.related.?.span.start);
            try equal(dot.diagnostic.Replacement.right_bracket, d.fix.?.edit.insert_before);
        }
    };
}
