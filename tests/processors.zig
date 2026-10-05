const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

// Consumer-owned schema deliberately has different public/effective layouts.
const Schema = struct {
    pub const Policy = struct { target: ?u8 = null, report: ?bool = null };
    pub const Effective = struct { scan: struct { target: u8, report: bool } };
    pub const defaults: Effective = .{ .scan = .{ .target = '!', .report = true } };
    pub const Error = error{TargetWithoutReporting};
    pub const Issue = enum {
        target_without_reporting,
        pub fn asError(_: @This()) Error {
            return error.TargetWithoutReporting;
        }
    };
    pub const Check = union(enum) { valid, invalid: Issue };
    pub fn resolve(baseline: Effective, patch: Policy) Effective {
        return .{ .scan = .{ .target = patch.target orelse baseline.scan.target, .report = patch.report orelse baseline.scan.report } };
    }
    pub fn check(effective: Effective, patch: Policy) Check {
        return if (!effective.scan.report and patch.target != null) .{ .invalid = .target_without_reporting } else .valid;
    }
};

const Finding = struct {
    code: enum { marker } = .marker,
    span: dot.Span,
    related: dot.Span,
    fix: struct { span: dot.Span },
};

fn Consumer(comptime runtime: bool) type {
    return struct {
        pub const Policies = dot.processor.PolicyBinding(Schema, .{ .runtime_policy = runtime });
        // A test-only consumer processor: no DOT syntax/document dependency.
        pub fn run(fragment: dot.processor.Fragment, state: Policies.State, sink: dot.reporting.Sink(Finding)) !struct {
            findings: u64,
            stop: ?dot.reporting.StopReason = null,
            delivery: dot.reporting.Delivery = .complete,
        } {
            const effective = if (runtime) state else Policies.baseline;
            var count: u64 = 0;
            if (effective.scan.report) for (fragment.bytes, 0..) |byte, i| {
                if (byte != effective.scan.target) continue;
                const local: dot.Span = .{ .start = @intCast(i), .len = 1 };
                count += 1;
                const action = sink.emit(.{
                    .span = try fragment.rebase(local),
                    .related = try fragment.rebase(.{ .start = 0, .len = 0 }),
                    .fix = .{ .span = try fragment.rebase(local) },
                }) catch |err| return .{ .findings = count, .stop = dot.reporting.StopReason.fromError(err), .delivery = .failed };
                if (action == .stop) return .{ .findings = count, .stop = .requested };
            };
            return .{ .findings = count };
        }
    };
}

test "named configured profiles preflight independent schemas with zero fixed state" {
    const Fixed = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}), .content = Consumer(false) });
    try equal(@as(usize, 0), @sizeOf(Fixed.State));
    try equal(@as(usize, 0), @sizeOf(Fixed.Options));
    _ = try Fixed.prepare(.{});
    const Mixed = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}), .content = Consumer(true) });
    const prepared = try Mixed.prepare(.{ .content = .{ .policy = .{ .target = '?' } } });
    try equal(@as(u8, '?'), prepared.content.scan.target);
    try expect(prepared.content.scan.report);
    try equal(@sizeOf(Schema.Effective), @sizeOf(Mixed.State));
    try std.testing.expectError(error.TargetWithoutReporting, Mixed.prepare(.{ .content = .{ .policy = .{ .target = '?', .report = false } } }));
    const disabled = try Mixed.prepare(.{ .content = .{ .policy = .{ .report = false } } });
    try expect(!disabled.content.scan.report); // inherited target is allowed
    const AllRuntime = dot.processor.PolicySet(.{ .dot = dot.Profile(.{ .runtime_policy = true }), .content = Consumer(true) });
    try std.testing.expectError(error.GraphOperatorMismatchNotApplicable, AllRuntime.prepare(.{ .dot = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic, .operator_mismatch = .err } } } } }));
}

test "typed consumer diagnostics, independent operations and all original-source spans" {
    const Profiles = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}), .content = Consumer(true) });
    const settings = try Profiles.prepare(.{});
    var outer = dot.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer outer.deinit();
    var parsed = dot.parseAndValidate(std.testing.allocator, "graph { a -> b; c -> d }", outer.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.document != null and !parsed.documentValid());
    var inner = dot.reporting.GrowableBag(Finding).init(std.testing.allocator, .{});
    defer inner.deinit();
    const source = "prefix !! and !";
    const first = try Consumer(true).run(try dot.processor.Fragment.init(source[7..9], 7), settings.content, inner.sink());
    const second = try Consumer(true).run(try dot.processor.Fragment.init(source[14..], 14), settings.content, inner.sink());
    try equal(@as(u64, 2), first.findings);
    try equal(@as(u64, 1), second.findings);
    try equal(@as(usize, 2), outer.items().len);
    try equal(@as(usize, 3), inner.items().len);
    for (inner.items(), [_]u32{ 7, 8, 14 }) |finding, offset| {
        try equal(offset, finding.span.start);
        try equal(offset, finding.fix.span.start);
        try equal(if (offset == 14) @as(u32, 14) else 7, finding.related.start);
    }
    try expect(@sizeOf(Finding) < @sizeOf(dot.Diagnostic));
    var fixed: dot.reporting.FixedBag(Finding, 1, .stop) = .{};
    const stopped = try Consumer(false).run(try dot.processor.Fragment.init("!!", 0), {}, fixed.sink());
    try equal(@as(u64, 1), stopped.findings);
    try equal(dot.reporting.StopReason.requested, stopped.stop.?);
    try equal(dot.reporting.Delivery.complete, stopped.delivery);
    // Explicitly invoking another operation remains legal after that stop.
    const later = try Consumer(false).run(try dot.processor.Fragment.init("!", 0), {}, dot.reporting.Sink(Finding).discard);
    try expect(later.stop == null);
}

test "fragment mapping rejects invalid descriptors and spans including overflow" {
    const Fragment = dot.processor.Fragment;
    try std.testing.expectError(error.InvalidFragment, Fragment.init("xx", std.math.maxInt(u32)));
    const fragment = try Fragment.init("abc", 10);
    try std.testing.expectError(error.InvalidSpan, fragment.rebase(.{ .start = 3, .len = 1 }));
    try std.testing.expectError(error.InvalidSpan, fragment.rebase(.{ .start = std.math.maxInt(u32), .len = 2 }));
    try equal(dot.Span{ .start = 13, .len = 0 }, try fragment.rebase(.{ .start = 3, .len = 0 }));
}

test "DOT warning stops latch across fixed/runtime backends and budget partitions" {
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |metered| {
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = .{
            .scanner = backend,
            .syntax = dot.presets.lenient.syntax,
            .execution = .{ .metering = metered },
        } });
        for ([_][]const u8{ "graph { ; a; b; }", "graph { 1e3; a; b; }", "graph { a - b; c; }", "graph { a:p --- b; c; }", "graph { a -- b --> c; d; }" }) |source| {
            var storage: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8, .edge_chains = 8, .edge_links = 8, .ported_references = 8 }) = .{};
            var bag: dot.FixedDiagnosticBag(1) = .{};
            var session = if (runtime) try P.Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{}) else P.Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{});
            defer session.deinit();
            if (metered) {
                const zero = if (runtime) try session.advance(0) else session.advance(0);
                try equal(@as(usize, 0), zero.work_used);
                try equal(@as(usize, 0), bag.items().len);
                while (true) {
                    const progress = if (runtime) try session.advance(1) else session.advance(1);
                    if (progress.outcome != null) break;
                }
            }
            const result = session.run();
            try equal(dot.reporting.StopReason.requested, result.outcome.diagnostic_stopped);
            try equal(dot.reporting.Delivery.complete, result.diagnostic_delivery);
            try equal(@as(u32, 1), result.warnings);
            try expect(result.document == null);
            try std.testing.expectEqualDeep(result, session.run());
            try std.testing.expectEqualDeep(result, session.cancel());
            try equal(@as(usize, 1), bag.items().len);
        }
    };
}

test "DOT validation stops on capacity/OOM and preserves committed outer document" {
    const source = "graph { a -> b; c -> d }";
    var fixed: dot.FixedDiagnosticBag(1) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, fixed.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try expect(checked.outcome == .success and checked.document != null);
    try expect(!checked.documentValid());
    try equal(dot.reporting.StopReason.requested, checked.validation.?.outcome.diagnostic_stopped.reason);
    try equal(dot.reporting.Delivery.complete, checked.diagnostic_delivery);
    var zero: dot.FixedDiagnosticBag(0) = .{};
    const exhausted = dot.validate(&checked.document.?, zero.sink(), .{});
    try equal(dot.reporting.StopReason.capacity, exhausted.outcome.diagnostic_stopped.reason);
    try equal(@as(u64, 1), exhausted.outcome.diagnostic_stopped.violations);
    var failing = dot.GrowableDiagnosticBag.init(std.testing.failing_allocator, .{});
    defer failing.deinit();
    const failed = dot.validate(&checked.document.?, failing.sink(), .{});
    try equal(dot.reporting.StopReason.out_of_memory, failed.outcome.diagnostic_stopped.reason);
    try equal(dot.reporting.Delivery.failed, failed.diagnostic_delivery);
    try equal(@as(u64, 1), failed.outcome.diagnostic_stopped.violations);
    var growable = dot.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer growable.deinit();
    const completed = dot.validate(&checked.document.?, growable.sink(), .{});
    try equal(@as(u64, 2), completed.outcome.completed.violations);
    try equal(@as(usize, 2), growable.items().len);
}

test "default growable bag bounds DOT validation floods and explicit unlimited completes" {
    const source = "graph {" ++ "a -> b;" ** 2048 ++ "}";
    var bag = dot.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    var parsed = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success and parsed.document != null);
    try expect(!parsed.documentValid());
    const stopped = parsed.validation.?.outcome.diagnostic_stopped;
    try equal(dot.reporting.StopReason.requested, stopped.reason);
    try equal(@as(u64, 1024), stopped.violations);
    try equal(@as(usize, 1024), bag.items().len);
    try expect(bag.storage.capacity <= 1024);
    var unlimited = dot.GrowableDiagnosticBag.init(std.testing.allocator, .{ .max_entries = .unlimited });
    defer unlimited.deinit();
    const complete = dot.validate(&parsed.document.?, unlimited.sink(), .{});
    try equal(@as(u64, 2048), complete.outcome.completed.violations);
    try equal(@as(usize, 2048), unlimited.items().len);
}
