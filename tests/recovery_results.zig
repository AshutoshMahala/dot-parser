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
