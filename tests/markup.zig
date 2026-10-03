//! Standalone consumer tests: deliberately no DOT import or build dependency.
const std = @import("std");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const discard = markup.diagnostic.discard;

test {
    _ = @import("markup_content.zig");
    _ = @import("markup_scanners.zig");
    _ = @import("markup_validation.zig");
    _ = @import("markup_budgets.zig");
    _ = @import("markup_rules.zig");
    _ = @import("markup_diagnostics.zig");
    _ = @import("markup_recovery.zig");
    _ = @import("markup_header_recovery.zig");
}

test "standalone public lexer yields borrowed tokens and latches EOF/errors" {
    const source = "text<a>body<b/></a>";
    var lexer = markup.lexer.Lexer.init(source);
    inline for (.{ .text, .open, .text, .empty, .close, .eof }) |kind| {
        const item = lexer.next();
        try expect(item == .token);
        try equal(kind, item.token.kind);
        try expect(item.token.span.endOffset() <= source.len);
    }
    try expect(lexer.next().token.kind == .eof);
    var invalid = markup.lexer.Lexer.init("<1>");
    const first = invalid.next();
    try expect(first == .problem);
    try std.testing.expectEqualDeep(first, invalid.next());
}

test "truncated tag endings and declaration prefixes have precise stable diagnostics" {
    for ([_][]const u8{ "<a/", "<a/x" }) |source| {
        var lexer = markup.lexer.Lexer.init(source);
        const first = lexer.next();
        try expect(first == .problem);
        try equal(markup.Outcome.invalid_syntax, first.problem.outcome);
        try equal(markup.diagnostic.Expected.closing_angle, first.problem.diagnostic.details.expected);
        try equal(if (source.len == 3) markup.diagnostic.Code.unexpected_end else .unexpected_byte, first.problem.diagnostic.code);
        try equal(@as(u32, 3), first.problem.diagnostic.span.start);
        try equal(@as(u32, if (source.len == 3) 0 else 1), first.problem.diagnostic.span.len);
        try std.testing.expectEqualDeep(first, lexer.next());
        try comparePartition(source);
    }
    for ([_]struct { source: []const u8, feature: markup.diagnostic.Feature }{
        .{ .source = "<!x", .feature = .declarations },
    }) |case| {
        var lexer = markup.lexer.Lexer.init(case.source);
        const first = lexer.next();
        try equal(markup.Outcome{ .unsupported_feature = case.feature }, first.problem.outcome);
        try equal(markup.diagnostic.Code.unsupported_feature, first.problem.diagnostic.code);
        try equal(case.feature, first.problem.diagnostic.details.feature);
        try equal(markup.location.Span{ .start = 0, .len = 1 }, first.problem.diagnostic.span);
        try std.testing.expectEqualDeep(first, lexer.next());
        try comparePartition(case.source);
    }
}

test "oversized descriptors are rejected before any byte access and remain latched" {
    if (@sizeOf(usize) <= 4) return error.SkipZigTest;
    // Deliberately unreadable descriptor: length preflight must never dereference
    // it. This avoids allocating more than 4 GiB just to test the domain guard.
    const length: usize = @as(u64, std.math.maxInt(u32)) + 1;
    const source = @as([*]const u8, @ptrFromInt(1))[0..length];
    var lexer = markup.lexer.Lexer.init(source);
    const first = lexer.next();
    const expected: markup.Outcome = .{ .resource_limit = .{ .resource = .source_bytes, .limit = std.math.maxInt(u32) } };
    try equal(expected, first.problem.outcome);
    try equal(markup.location.Span{ .start = 0, .len = 0 }, first.problem.diagnostic.span);
    try std.testing.expectEqualDeep(first, lexer.next());
    var session = markup.BoundedSession.init(source, .{}, discard, .{});
    try equal(@as(u32, 0), session.advance(0).work_used);
    const stopped = session.advance(1);
    try equal(expected, stopped.outcome.?);
    try equal(@as(u32, 0), stopped.source_frontier);
    try equal(@as(u32, 0), session.advance(1).work_used);
    try equal(expected, markup.measureIn(source, .{}, discard, .{}).outcome);
}

test "source-shaped forest, borrowed text, arbitrary names and child traversal" {
    const source = "before<widget> hi <b/> after </widget><x></x>tail";
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    var parsed = markup.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit();
    try expect(parsed.outcome == .success);
    try equal(@as(usize, 0), bag.items().len);
    try equal(markup.Counts{ .nodes = 7, .elements = 3, .max_depth = 2 }, parsed.counts);
    const doc = parsed.document.?;
    try expect(doc.source.ptr == source.ptr);
    try equal(@as(u32, 7), doc.nodeCount());
    try expect(doc.node(@enumFromInt(100)) == null);
    var roots = doc.roots();
    try strings("before", roots.next().?.raw());
    const widget = roots.next().?;
    try strings("widget", widget.name().?);
    try strings("<widget> hi <b/> after </widget>", widget.raw());
    var children = widget.children();
    const text = children.next().?;
    try expect(text.name() == null);
    try strings(" hi ", text.raw());
    const b = children.next().?;
    try strings("b", b.name().?);
    var empty = b.children();
    try expect(empty.next() == null);
    try strings(" after ", children.next().?.raw());
    try expect(children.next() == null);
    try strings("<x></x>", roots.next().?.raw());
    try strings("tail", roots.next().?.raw());
    try expect(roots.next() == null);
    try equal(@as(usize, 20), @sizeOf(markup.Node));
}

test "empty/text fragments, raw high bytes, exact case, names and encoding signatures" {
    const valid = [_][]const u8{
        "",                      "hello\r\n\t > text", "<a/><b/>",      "<a />",   "<a\r\n></a\t>",
        "<_:name-1.2/>",
        "<東京>é</東京>",
        "<\xff>\xc0\xaf</\xff>", "\xef\xbb\xbf<a/>",   "x\xef\xbb\xbf", "<B></B>",
    };
    for (valid) |source| {
        var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        try expect(parsed.outcome == .success);
    }
    const invalid = [_][]const u8{
        "<B></b>", "<a><b></a>", "<a>",  "</a>",        "<a></b>", "<a></aa>",
        "<",       "</",         "<1/>", "< a/>",       "<a/ >",   "<a//>",
        "<a =x>",  "</a x>",     "\x00", "<a>\x01</a>", "<a\x00>", "<a></ a>",
    };
    for (invalid) |source| {
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var parsed = markup.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
        defer parsed.deinit();
        try expect(parsed.outcome == .invalid_syntax);
        try expect(parsed.document == null);
        try expect(bag.items().len >= 1);
        try expect(bag.items()[0].span.endOffset() <= source.len);
    }
    for ([_][]const u8{ "\xff\xfe<\x00", "\xfe\xff\x00<", "\x00\x00\xfe\xff", "\xff\xfe\x00\x00" }) |source| {
        var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome{ .unsupported_feature = .encoding }, parsed.outcome);
    }
}

test "later slices are recognized as unsupported, not silently accepted" {
    const cases = [_]struct { source: []const u8, feature: markup.diagnostic.Feature }{
        .{ .source = "<!DOCTYPE a>", .feature = .declarations },
        .{ .source = "<?xml version='1.0'?>", .feature = .processing_instructions },
    };
    for (cases) |case| {
        var parsed = markup.parseBorrowed(std.testing.allocator, case.source, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome{ .unsupported_feature = case.feature }, parsed.outcome);
        try expect(parsed.document == null);
    }
}

test "fixed storage and count-only processing share allocator results and source offsets" {
    const source = "<a>x<b/>y<c>z</c></a><d/>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 8 }) = .{};
    var frames: markup.FixedParseScratch(2) = .{};
    const fixed = markup.parseBorrowedIn(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, discard, .{});
    try equal(markup.Outcome.success, fixed.outcome);
    try equal(parsed.counts, fixed.counts);
    try std.testing.expectEqualDeep(parsed.document.?.records, fixed.document.?.records);
    const measured = markup.measureIn(source, frames.storage(), discard, .{});
    try equal(parsed.counts, measured.counts);
    const owned_measure = markup.measure(std.testing.allocator, source, discard, .{});
    try equal(measured, owned_measure);
    try equal(@as(usize, 24), @TypeOf(frames).byte_size);
    // A self-closing element counts toward depth, but needs no persistent frame.
    const leaf = markup.measureIn("<a/>", .{}, discard, .{});
    try equal(markup.Counts{ .nodes = 1, .elements = 1, .max_depth = 1 }, leaf.counts);
    try equal(markup.Outcome.success, leaf.outcome);
}

test "policy limits and storage exhaustion are separate and never publish a partial tree" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 2 }) = .{};
    var frames: markup.FixedParseScratch(1) = .{};
    const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
    try equal(markup.Outcome{ .storage_exhausted = .node_pool }, markup.parseBorrowedIn("<a/><b/><c/>", memory, discard, .{}).outcome);
    try equal(markup.Outcome{ .storage_exhausted = .nesting_frames }, markup.parseBorrowedIn("<a><b></b></a>", memory, discard, .{}).outcome);
    inline for (.{ "max_source_bytes", "max_nesting", "max_nodes" }) |name| {
        var patch: markup.Policy = .{};
        @field(patch.limits, name) = 0;
        const r = Dynamic.parseBorrowedIn("<a/>", memory, discard, .{ .policy = patch });
        try expect(r.outcome == .resource_limit);
        try expect(r.document == null);
    }
    const Fixed = markup.Profile(.{ .policy = .{ .limits = .{ .max_nesting = 1, .max_nodes = 2 } } });
    const limited = Fixed.parseBorrowedIn("<a><b/></a>", memory, discard, .{});
    try equal(markup.Outcome{ .resource_limit = .{ .resource = .nesting_depth, .limit = 1 } }, limited.outcome);
    try equal(markup.Outcome.success, markup.parseBorrowedIn("<a/>", memory, discard, .{}).outcome);
    try equal(markup.Outcome.success, Dynamic.parseBorrowedIn("", .{}, discard, .{ .policy = .{ .limits = .{ .max_nodes = 0, .max_nesting = 0, .max_source_bytes = 0 } } }).outcome);
}

test "all budget partitions preserve records, diagnostics, counts, work and terminal state" {
    for ([_][]const u8{ "<long-name><b/>hello</long-name>", "<a>\r\nx</a>tail", "<a><b></a>", "<a x='1'>", "<a", "", "\xef\xbb\xbf<a/>" }) |source| {
        var reference = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer reference.deinit();
        var total: ?u64 = null;
        for ([_]u32{ 1, 2, 7, 128 }) |budget| {
            var nodes: markup.FixedDocumentStorage(.{ .nodes = 12, .attributes = 12 }) = .{};
            var frames: markup.FixedParseScratch(4) = .{};
            var bag: markup.FixedDiagnosticBag(16) = .{};
            var session = markup.BoundedSession.init(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, bag.sink(), .{});
            defer session.deinit();
            try expect(session.result() == null);
            const zero = session.advance(0);
            try equal(@as(u32, 0), zero.work_used);
            try equal(@as(u32, 0), zero.source_frontier);
            var sum: u64 = 0;
            var frontier: u32 = 0;
            while (true) {
                const p = session.advance(budget);
                try expect(p.work_used <= budget);
                try expect(p.source_frontier >= frontier and p.source_frontier <= source.len);
                frontier = p.source_frontier;
                sum += p.work_used;
                if (p.outcome != null) break;
                try expect(p.work_used > 0);
                try expect(sum < 1000);
            }
            if (total) |t| try equal(t, sum) else total = sum;
            const got = session.result().?;
            try equal(reference.outcome, got.outcome);
            try equal(reference.counts, got.counts);
            try equal(reference.completion, got.completion);
            try equal(reference.syntax_errors, got.syntax_errors);
            if (reference.document) |doc| {
                try std.testing.expectEqualDeep(doc.records, got.document.?.records);
                try std.testing.expectEqualDeep(doc.attributes, got.document.?.attributes);
            }
            try equal(@as(u32, 0), session.advance(1).work_used);
            try equal(got.outcome, session.cancel().outcome);
            try equal(got.outcome, session.run().outcome);
        }
    }
}

test "fixed/runtime settings agree, patches inherit, resets use the compiled baseline" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .limits = .{ .max_nodes = 2 } } });
    const Fixed = markup.Profile(.{ .policy = .{ .limits = .{ .max_nodes = 2 } } });
    try equal(markup.PolicyValidation.valid, Fixed.validatePolicy(.{}));
    try equal(markup.PolicyValidation.valid, Dynamic.validatePolicy(.{ .limits = .{ .max_nodes = 0 } }));
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 4 }) = .{};
    var frames: markup.FixedParseScratch(4) = .{};
    const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
    inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        const P = markup.Profile(.{ .policy = .{ .limits = .{ .max_nodes = 2 }, .execution = .{ .metering = metering, .cancellation = cancellation } } });
        var dynamic = Dynamic.Session.init("<a/><b/><c/>", memory, discard, .{ .policy = .{ .execution = .{ .metering = metering, .cancellation = cancellation } } });
        if (metering) {
            while ((try dynamic.advance(1)).outcome == null) {}
        } else {
            try std.testing.expectError(error.MeteringDisabled, dynamic.advance(1));
            _ = dynamic.run();
        }
        const expected = P.parseBorrowedIn("<a/><b/><c/>", memory, discard, .{});
        try equal(expected.outcome, dynamic.result().?.outcome);
        dynamic.reset("<a/><b/><c/>", discard, .{ .policy = .{ .limits = .{ .max_nodes = 3 } } });
        try equal(markup.Outcome.success, dynamic.run().outcome);
        dynamic.reset("<a/><b/><c/>", discard, .{});
        try expect(dynamic.run().outcome == .resource_limit);
        dynamic.deinit();
    };
}

const Stop = struct {
    polls: u32 = 0,
    after: u32,
    fn requested(context: ?*anyopaque) bool {
        const self: *Stop = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.polls > self.after;
    }
    fn hook(self: *Stop) markup.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "runtime cancellation policy controls supplied hooks across operations and reset" {
    inline for (.{ false, true }) |baseline| inline for (.{ false, true }) |metered| {
        const P = markup.Profile(.{ .runtime_policy = true, .policy = .{ .execution = .{ .cancellation = baseline, .metering = metered } } });
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
        const memory: markup.ParseMemory = .{ .document = nodes.storage() };
        var stop: Stop = .{ .after = 0 };
        // Both inherited and explicitly overridden cancellation settings apply.
        for ([_]?bool{ null, !baseline }) |patch| {
            const enabled = patch orelse baseline;
            const expected: markup.Outcome = if (enabled) .cancelled else .success;
            const options: P.Options = .{ .policy = .{ .execution = .{ .cancellation = patch } }, .cancellation = stop.hook() };
            stop.polls = 0;
            try equal(expected, P.measureIn("<a/>", .{}, discard, options).outcome);
            try equal(@as(u32, if (enabled) 1 else 0), stop.polls);
            stop.polls = 0;
            try equal(expected, P.measure(std.testing.allocator, "<a/>", discard, options).outcome);
            try equal(@as(u32, if (enabled) 1 else 0), stop.polls);
            stop.polls = 0;
            try equal(expected, P.parseBorrowedIn("<a/>", memory, discard, options).outcome);
            try equal(@as(u32, if (enabled) 1 else 0), stop.polls);
            stop.polls = 0;
            var owned = P.parseBorrowed(std.testing.allocator, "<a/>", discard, .{ .policy = options.policy, .cancellation = options.cancellation });
            defer owned.deinit();
            try equal(expected, owned.outcome);
            try equal(@as(u32, if (enabled) 1 else 0), stop.polls);
            stop.polls = 0;
            var session = P.Session.init("<a/>", memory, discard, options);
            try equal(@as(u32, 0), stop.polls);
            if (metered) {
                const first = try session.advance(0);
                try equal(@as(u32, 0), first.work_used);
                if (enabled) try equal(markup.Outcome.cancelled, first.outcome.?) else try expect(first.outcome == null);
            }
            try equal(expected, session.run().outcome);
            try equal(@as(u32, if (enabled) 1 else 0), stop.polls);
            stop.polls = 0;
            session.reset("<a/>", discard, .{ .policy = .{ .execution = .{ .cancellation = !enabled } }, .cancellation = stop.hook() });
            const reset_expected: markup.Outcome = if (enabled) .success else .cancelled;
            try equal(reset_expected, session.run().outcome);
            try equal(@as(u32, if (enabled) 0 else 1), stop.polls);
            session.reset("<a/>", discard, options);
            try equal(markup.Outcome.cancelled, session.cancel().outcome);
            session.deinit();
        }
    };
    const Active = markup.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } });
    try equal(markup.Outcome.success, Active.measureIn("<a/>", .{}, discard, .{}).outcome);
}

test "cancellation before each step, zero budget, relocation and terminal idempotence" {
    const P = markup.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    for (0..120) |after| {
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 4 }) = .{};
        var frames: markup.FixedParseScratch(2) = .{};
        var stop: Stop = .{ .after = @intCast(after) };
        var first = P.Session.init("<long-name><b/>text</long-name>", .{ .document = nodes.storage(), .scratch = frames.storage() }, discard, .{ .cancellation = stop.hook() });
        _ = first.advance(3);
        // A move between calls must not retain pointers into the old session.
        var moved = first;
        const r = moved.run();
        try expect(r.outcome == .success or r.outcome == .cancelled);
        if (r.outcome == .cancelled) try expect(r.document == null);
        const polls = stop.polls;
        _ = moved.run();
        _ = moved.advance(1);
        moved.deinit();
        try equal(polls, stop.polls);
    }
    var stop: Stop = .{ .after = 0 };
    var zero = P.Session.init("", .{}, discard, .{ .cancellation = stop.hook() });
    const p = zero.advance(0);
    try equal(markup.Outcome.cancelled, p.outcome.?);
    try equal(@as(u32, 0), p.work_used);
}

test "explicit fail-fast syntax cause survives stopped, empty, or failing diagnostic destinations" {
    const P = markup.Profile(.{ .policy = .{ .recovery = .fail_fast } });
    const Reject = struct {
        fn emit(_: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            return error.DiagnosticSinkFailure;
        }
    };
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 4 }) = .{};
    var frames: markup.FixedParseScratch(2) = .{};
    const memory: markup.ParseMemory = .{ .document = nodes.storage(), .scratch = frames.storage() };
    var full: markup.FixedDiagnosticBag(0) = .{};
    var last: markup.FixedDiagnosticBag(1) = .{};
    for ([_]markup.DiagnosticSink{ full.sink(), .{ .context = null, .emit_fn = Reject.emit } }) |sink| {
        const r = P.parseBorrowedIn("<a></b>", memory, sink, .{});
        try equal(markup.Outcome.invalid_syntax, r.outcome);
        try equal(markup.reporting.Delivery.failed, r.diagnostic_delivery);
    }
    const r = P.parseBorrowedIn("<a></b>", memory, last.sink(), .{});
    try equal(markup.Outcome.invalid_syntax, r.outcome);
    try equal(markup.reporting.Delivery.complete, r.diagnostic_delivery);
    try equal(markup.location.Span{ .start = 5, .len = 1 }, last.items()[0].span);
    try equal(markup.location.Span{ .start = 1, .len = 1 }, last.items()[0].related.?);
}

fn allocationCase(allocator: std.mem.Allocator, source: []const u8) !void {
    var parsed = markup.parseBorrowed(allocator, source, discard, .{});
    defer parsed.deinit();
    if (parsed.outcome == .out_of_memory) return error.OutOfMemory;
    try expect(parsed.outcome == .success or parsed.outcome == .invalid_syntax);
}
test "all allocation failures release grown output and nesting, including later syntax failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{"<a><b><c><d/><e/><f/><g/><h/><i/><j/><k/><l/></c></b></a>"});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{"<a><b><c><d/><e/><f/><g/><h/><i/><j/><k/><l/></wrong>"});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{"<!--start--><a x='&custom;'><b><![CDATA[<raw>]]>&amp;<c/></b></a><!--end-->"});
}

test "owned results trim in place or retain visible slack without allocation or failure" {
    inline for (.{ false, true }) |refuse_resize| {
        var buffer: [1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        // Exactly one allocation can succeed; finalization must never attempt
        // another allocation, even when every resize is refused.
        var tracked = std.testing.FailingAllocator.init(fixed.allocator(), .{
            .fail_index = 1,
            .resize_fail_index = if (refuse_resize) 0 else std.math.maxInt(usize),
        });
        var parsed = markup.parseBorrowed(tracked.allocator(), "<a/>", discard, .{});
        try equal(markup.Outcome.success, parsed.outcome);
        try equal(@as(usize, 1), tracked.allocations);
        try expect(!tracked.has_induced_failure);
        try strings("<a/>", parsed.document.?.node(@enumFromInt(0)).?.raw());
        try equal(tracked.allocated_bytes - tracked.freed_bytes, parsed.retainedBytes());
        if (refuse_resize) {
            try expect(parsed.retainedBytes() > @sizeOf(markup.Node));
        } else {
            try equal(@sizeOf(markup.Node), parsed.retainedBytes());
            try equal(@as(usize, 1), tracked.resize_index);
        }
        parsed.deinit();
        try equal(@as(usize, 0), parsed.retainedBytes());
        try equal(tracked.allocated_bytes, tracked.freed_bytes);
    }
    for ([_][]const u8{ "", "<a>" }) |source| {
        var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        try equal(@as(usize, 0), parsed.retainedBytes());
    }
}

fn comparePartition(source: []const u8) !void {
    var a: markup.FixedDocumentStorage(.{ .nodes = 256, .attributes = 256 }) = .{};
    var b: markup.FixedDocumentStorage(.{ .nodes = 256, .attributes = 256 }) = .{};
    var af: markup.FixedParseScratch(64) = .{};
    var bf: markup.FixedParseScratch(64) = .{};
    var ab: markup.FixedDiagnosticBag(1) = .{};
    var bb: markup.FixedDiagnosticBag(1) = .{};
    const direct = markup.parseBorrowedIn(source, .{ .document = a.storage(), .scratch = af.storage() }, ab.sink(), .{});
    var session = markup.BoundedSession.init(source, .{ .document = b.storage(), .scratch = bf.storage() }, bb.sink(), .{});
    var work: u64 = 0;
    while (session.result() == null) {
        const p = session.advance(1);
        work += p.work_used;
        try expect(work <= @as(u64, source.len) * 12 + 32);
    }
    const bounded = session.result().?;
    try equal(direct.outcome, bounded.outcome);
    try equal(direct.counts, bounded.counts);
    try std.testing.expectEqualDeep(ab.items(), bb.items());
    if (direct.document) |doc| {
        try std.testing.expectEqualDeep(doc.records, bounded.document.?.records);
        try std.testing.expectEqualDeep(doc.attributes, bounded.document.?.attributes);
        for (doc.records, 0..) |node, i| {
            try expect(node.span.endOffset() <= source.len);
            try expect(node.subtree_end > i and node.subtree_end <= doc.records.len);
        }
    }
}
test "every truncation and deterministic arbitrary bytes are safe and partition invariant" {
    const source = "\xef\xbb\xbftext&amp;<namespace:long-name x = 'v>\"&custom;' y=\"&#x41;\" x='2'><!-- & <hi/> --><é A='é'/><![CDATA[&<raw>]]>\r\nother</namespace:long-name>end";
    for (0..source.len + 1) |end| try comparePartition(source[0..end]);
    var random = std.Random.DefaultPrng.init(0x4d41524b5550);
    var bytes: [128]u8 = undefined;
    const alphabet = "<>/aAb: _.19-\r\n\t&!?=\"'[]#;xCDAT\xff\x00";
    for (0..1000) |_| {
        const len = random.random().uintLessThan(usize, bytes.len + 1);
        for (bytes[0..len]) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        try comparePartition(bytes[0..len]);
    }
}

test "long names and text resume in linear work with constant continuation" {
    const len = 32_768;
    const source = try std.testing.allocator.alloc(u8, 3 * len + 5);
    defer std.testing.allocator.free(source);
    source[0] = '<';
    @memset(source[1..][0..len], 'a');
    source[len + 1] = '>';
    @memset(source[len + 2 ..][0..len], 't');
    @memcpy(source[2 * len + 2 ..][0..2], "</");
    @memset(source[2 * len + 4 ..][0..len], 'a');
    source[source.len - 1] = '>';
    try comparePartition(source);
}

test "quoted attributes preserve order, duplicate occurrences, quotes, bytes and ownership" {
    const source = "text<a x = '1' X=\"\" x='two>\"' ns:é = '\xff\t\r\n'><b y=\"'\\\"/><c/></a><d x='3'/>tail";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    try equal(markup.Counts{ .nodes = 6, .elements = 4, .attributes = 6, .max_depth = 2 }, parsed.counts);
    const doc = parsed.document.?;
    try equal(@as(usize, 20), @sizeOf(markup.Node));
    try equal(@as(usize, 20), @sizeOf(markup.Attribute));
    var roots = doc.roots();
    var no_attributes = roots.next().?.attributes();
    try expect(no_attributes.next() == null);
    const a = roots.next().?;
    var attributes = a.attributes();
    const x = attributes.next().?;
    try strings("x", x.name());
    try strings("x = '1'", x.raw());
    try strings("'1'", x.rawValue());
    try strings("1", x.value());
    try equal(a.id, x.record().owner);
    const cap = attributes.next().?;
    try strings("X", cap.name());
    try strings("", cap.value());
    try strings("two>\"", attributes.next().?.value());
    const ns = attributes.next().?;
    try strings("ns:é", ns.name());
    try strings("\xff\t\r\n", ns.value());
    try expect(attributes.next() == null);
    var children = a.children();
    var b_attributes = children.next().?.attributes();
    try strings("'\\", b_attributes.next().?.value());
    var c_attributes = children.next().?.attributes();
    try expect(c_attributes.next() == null);
    var d_attributes = roots.next().?.attributes();
    try strings("3", d_attributes.next().?.value());
    try expect(d_attributes.next() == null);
    var tail_attributes = roots.next().?.attributes();
    try expect(tail_attributes.next() == null);
    const measured = markup.measure(std.testing.allocator, source, discard, .{});
    try equal(parsed.counts, measured.counts);
    var output: markup.FixedDocumentStorage(.{ .nodes = 6, .attributes = 6 }) = .{};
    var frames: markup.FixedParseScratch(1) = .{};
    const fixed = markup.parseBorrowedIn(source, .{ .document = output.storage(), .scratch = frames.storage() }, discard, .{});
    try equal(markup.Outcome.success, fixed.outcome);
    try std.testing.expectEqualDeep(doc.records, fixed.document.?.records);
    try std.testing.expectEqualDeep(doc.attributes, fixed.document.?.attributes);
    try comparePartition(source);
}

test "attribute token stream, grammar boundaries and precise truncation expectations" {
    const source = "<a x='1' y = \"2\"/><b a=''><c/></b>";
    var lexer = markup.lexer.Lexer.init(source);
    inline for (.{ .open_head, .attribute, .attribute, .empty_end, .open_head, .attribute, .head_end, .empty, .close, .eof }) |kind| {
        const item = lexer.next();
        try expect(item == .token);
        try equal(kind, item.token.kind);
        if (kind == .attribute) try expect(item.token.span.len >= 2);
    }
    for ([_][]const u8{ "<a x/>", "<a x=>", "<a x=no/>", "<a x='1'y='2'/>", "<a x='<'/>", "<a x='\x00'/>", "<a x='1'/ >", "<a x='1' = '2'/>", "</a x='1'>", "<a x='1' 1y='2'/>", "<a x='1'//>" }) |invalid| {
        var parsed = markup.parseBorrowed(std.testing.allocator, invalid, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try expect(parsed.document == null);
        try comparePartition(invalid);
    }
    for ([_]struct { source: []const u8, expected: markup.diagnostic.Expected }{
        .{ .source = "<a x", .expected = .equal_sign },
        .{ .source = "<a x ", .expected = .equal_sign },
        .{ .source = "<a x=", .expected = .opening_quote },
        .{ .source = "<a x='v", .expected = .closing_quote },
        .{ .source = "<a x='v'/", .expected = .closing_angle },
    }) |case| {
        var bag: markup.FixedDiagnosticBag(1) = .{};
        var parsed = markup.parseBorrowed(std.testing.allocator, case.source, bag.sink(), .{});
        defer parsed.deinit();
        try equal(markup.Outcome.invalid_syntax, parsed.outcome);
        try equal(case.expected, bag.items()[0].details.expected);
        try equal(case.source.len, bag.items()[0].span.start);
    }
}

test "attribute capacities, policy parity and self-closing headers without nesting frames" {
    const source = "<a x='1' y='2'/>";
    var output: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 2 }) = .{};
    const memory: markup.ParseMemory = .{ .document = output.storage() };
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    inline for (.{ 0, 1, 2 }) |limit| {
        const Fixed = markup.Profile(.{ .policy = .{ .limits = .{ .max_attributes = limit } } });
        const a = Fixed.parseBorrowedIn(source, memory, discard, .{});
        const b = Dynamic.parseBorrowedIn(source, memory, discard, .{ .policy = .{ .limits = .{ .max_attributes = limit } } });
        try equal(a.outcome, b.outcome);
        try equal(a.counts, b.counts);
        try equal(@as(u32, limit), a.counts.attributes);
        try equal(a.outcome, Fixed.measureIn(source, .{}, discard, .{}).outcome);
        if (limit < 2) {
            try equal(markup.Outcome{ .resource_limit = .{ .resource = .attributes, .limit = limit } }, a.outcome);
            try expect(a.document == null);
        } else try equal(markup.Outcome.success, a.outcome);
    }
    var small: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 1 }) = .{};
    const exhausted = markup.parseBorrowedIn(source, .{ .document = small.storage() }, discard, .{});
    try equal(markup.Outcome{ .storage_exhausted = .attribute_pool }, exhausted.outcome);
    try equal(@as(u32, 1), exhausted.counts.attributes);
    try expect(exhausted.document == null);
    try equal(markup.Outcome.success, markup.measureIn(source, .{}, discard, .{}).outcome);
    try equal(markup.Outcome{ .storage_exhausted = .nesting_frames }, markup.parseBorrowedIn("<a x='1'></a>", memory, discard, .{}).outcome);
}

test "independent duplicate validation, case-sensitive scope, first occurrence and policy parity" {
    const source = "<a z='1' a='2' z='3' a='4' Z='5' z='6'><b z='7' z='8'/></a><a z='9'/>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    const doc = parsed.document.?;
    try equal(@as(u32, 6), markup.requiredValidationScratch(&doc));
    var scratch: markup.FixedValidationScratch(6) = .{};
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{ .duplicate_attribute = .off } } });
    inline for (.{ .err, .warning, .off }) |severity| {
        const Fixed = markup.Profile(.{ .policy = .{ .validation = .{ .duplicate_attribute = severity } } });
        bag.reset();
        const checked = Fixed.validateIn(&doc, scratch.storage(), bag.sink(), .{});
        try expect(checked.completion == .complete);
        try equal(if (severity == .err) .invalid else .valid, checked.validity);
        try equal(if (severity == .off) .not_run else .complete, checked.checks.duplicate_attribute);
        try equal(@as(u32, if (severity == .err) 4 else 0), checked.errors);
        try equal(@as(u32, if (severity == .warning) 4 else 0), checked.warnings);
        try equal(@as(usize, if (severity == .off) 0 else 4), bag.items().len);
        if (severity != .off) {
            for ([_]u32{ 2, 3, 5, 7 }, [_]u32{ 0, 1, 0, 6 }, bag.items()) |index, first, finding| {
                try equal(doc.attributes[index].name, finding.span);
                try equal(doc.attributes[first].name, finding.related.?);
                try equal(if (severity == .err) .err else .warning, finding.code.severity());
            }
        }
        // Hiding findings never changes validity; runtime patch equals fixed policy.
        try equal(checked, Dynamic.validateIn(&doc, scratch.storage(), discard, .{ .policy = .{ .validation = .{ .duplicate_attribute = severity } } }));
        try equal(checked, Fixed.validate(std.testing.allocator, &doc, discard, .{}));
        try equal(@as(usize, 9), doc.attributes.len);
    }
    const Off = markup.Profile(.{ .policy = .{ .validation = .{ .duplicate_attribute = .off } } });
    try expect(Off.validate(std.testing.failing_allocator, &doc, discard, .{}).completion == .complete);
    try expect(Dynamic.validateIn(&doc, .{}, discard, .{}).checks.duplicate_attribute == .not_run);
    try expect(markup.validateIn(&doc, .{}, discard, .{}).completion == .storage_exhausted);
    try expect(markup.validate(std.testing.failing_allocator, &doc, discard, .{}).completion == .out_of_memory);
    // Parsing under a validation-error policy still retains the complete syntax.
    try strings(source, doc.source);
}

test "validation stops immediately on diagnostic backpressure with truthful partial results" {
    var parsed = markup.parseBorrowed(std.testing.allocator, "<a x='1' x='2' x='3'/><b y='4' y='5'/>", discard, .{});
    defer parsed.deinit();
    const doc = parsed.document.?;
    var scratch: markup.FixedValidationScratch(3) = .{};
    var one: markup.FixedDiagnosticBag(1) = .{};
    var zero: markup.FixedDiagnosticBag(0) = .{};
    const Warning = markup.Profile(.{ .policy = .{ .validation = .{ .duplicate_attribute = .warning } } });
    const stopped = Warning.validateIn(&doc, scratch.storage(), one.sink(), .{});
    try equal(@as(u32, 1), stopped.warnings);
    try equal(.unknown, stopped.validity);
    try equal(.incomplete, stopped.checks.duplicate_attribute);
    try expect(stopped.completion == .diagnostic_stopped);
    try equal(markup.reporting.StopReason.requested, stopped.completion.diagnostic_stopped);
    try equal(markup.reporting.Delivery.complete, stopped.diagnostic_delivery);
    const failed = markup.validateIn(&doc, scratch.storage(), zero.sink(), .{});
    try equal(.invalid, failed.validity);
    try equal(@as(u32, 1), failed.errors);
    try equal(markup.reporting.StopReason.capacity, failed.completion.diagnostic_stopped);
    try equal(markup.reporting.Delivery.failed, failed.diagnostic_delivery);
    var failed_bag = markup.GrowableDiagnosticBag.init(std.testing.failing_allocator, .{});
    defer failed_bag.deinit();
    const oom = markup.validateIn(&doc, scratch.storage(), failed_bag.sink(), .{});
    try equal(markup.reporting.StopReason.out_of_memory, oom.completion.diagnostic_stopped);
    try equal(@as(u32, 1), oom.errors);
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    var stop: Stop = .{ .after = 0 };
    try expect(Dynamic.validateIn(&doc, scratch.storage(), discard, .{ .cancellation = stop.hook() }).completion == .complete);
    try equal(@as(u32, 0), stop.polls);
    const cancelled = Dynamic.validateIn(&doc, scratch.storage(), discard, .{ .cancellation = stop.hook(), .policy = .{ .execution = .{ .cancellation = true } } });
    try expect(cancelled.completion == .cancelled);
    try equal(.unknown, cancelled.validity);
}

fn attributeAllocationCase(allocator: std.mem.Allocator) !void {
    var parsed = markup.parseBorrowed(allocator, "<a x='1' x='2'><b y='3'/></a>", discard, .{});
    defer parsed.deinit();
    if (parsed.outcome == .out_of_memory) return error.OutOfMemory;
    try equal(markup.Outcome.success, parsed.outcome);
    const doc = parsed.document.?;
    const checked = markup.validate(allocator, &doc, discard, .{});
    if (checked.completion == .out_of_memory) return error.OutOfMemory;
    try equal(.invalid, checked.validity);
}
test "attribute allocation failures, validation scratch and long values are safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, attributeAllocationCase, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{"<a x='1' y='2' z='3' a='4' b='5' c='6' d='7' e='8' f='9' g='10' h='11' i='12'><b/></wrong>"});
    const len = 32_768;
    const source = try std.testing.allocator.alloc(u8, len + 9);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..6], "<a x='");
    @memset(source[6..][0..len], 'v');
    @memcpy(source[6 + len ..], "'/>");
    try comparePartition(source);
    for (0..130) |after| {
        const P = markup.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
        var output: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 1 }) = .{};
        var stop: Stop = .{ .after = @intCast(after) };
        var session = P.Session.init(source, .{ .document = output.storage() }, discard, .{ .cancellation = stop.hook() });
        while (session.result() == null) _ = session.advance(1);
        try equal(markup.Outcome.cancelled, session.result().?.outcome);
        try expect(session.result().?.document == null);
    }
}

test "sparse attribute capacity accounting includes retained slack in both owned pools" {
    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var parsed = markup.parseBorrowed(tracked.allocator(), "<a x='1' y='2'/>", discard, .{});
    try equal(markup.Outcome.success, parsed.outcome);
    try equal(@as(usize, 2), tracked.allocations);
    try equal(tracked.allocated_bytes - tracked.freed_bytes, parsed.retainedBytes());
    try expect(parsed.retainedBytes() >= @sizeOf(markup.Node) + 2 * @sizeOf(markup.Attribute));
    parsed.deinit();
    try equal(@as(usize, 0), parsed.retainedBytes());
    try equal(tracked.allocated_bytes, tracked.freed_bytes);
}

test "duplicate validator agrees with a simple reference across random lists and owners" {
    var random = std.Random.DefaultPrng.init(0x41545452);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    for (0..100) |_| {
        source.clearRetainingCapacity();
        bag.reset();
        for (0..5) |_| {
            try source.appendSlice(std.testing.allocator, "<a");
            const count = random.random().uintLessThan(u32, 20);
            for (0..count) |_| {
                const name = ([_][]const u8{ "z", "a", "Z", "aa", "é", "\xff" })[random.random().uintLessThan(u32, 6)];
                try source.append(std.testing.allocator, ' ');
                try source.appendSlice(std.testing.allocator, name);
                try source.appendSlice(std.testing.allocator, "='value'");
            }
            try source.appendSlice(std.testing.allocator, "/>");
        }
        var parsed = markup.parseBorrowed(std.testing.allocator, source.items, discard, .{});
        defer parsed.deinit();
        try equal(markup.Outcome.success, parsed.outcome);
        const doc = parsed.document.?;
        const checked = markup.validate(std.testing.allocator, &doc, bag.sink(), .{});
        try expect(checked.completion == .complete);
        var duplicates: u32 = 0;
        for (doc.attributes, 0..) |attribute, index| {
            for (doc.attributes[0..index]) |previous| {
                if (previous.owner == attribute.owner and std.mem.eql(u8, previous.name.slice(doc.source), attribute.name.slice(doc.source))) {
                    const finding = bag.items()[duplicates];
                    try equal(attribute.name, finding.span);
                    try equal(previous.name, finding.related.?);
                    duplicates += 1;
                    break;
                }
            }
        }
        try equal(duplicates, checked.errors);
        try equal(duplicates, bag.items().len);
    }
}

test "validation resource diagnostics identify the first largest attribute owner" {
    const source = "prefix<small x='1'/><large z='1' z='2' y='3'/><tie x='1' x='2' x='3'/>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    const doc = parsed.document.?;
    try equal(@as(u32, 3), markup.requiredValidationScratch(&doc));
    const expected: markup.location.Span = .{ .start = @intCast(std.mem.indexOf(u8, source, "large").?), .len = 5 };
    var keys: markup.FixedValidationScratch(2) = .{};
    var bag: markup.FixedDiagnosticBag(1) = .{};
    const fixed = markup.validateIn(&doc, keys.storage(), bag.sink(), .{});
    try equal(@as(u32, 3), fixed.completion.storage_exhausted);
    try equal(.unknown, fixed.validity);
    try equal(.incomplete, fixed.checks.duplicate_attribute);
    try equal(.complete, fixed.diagnostic_delivery); // accepted-stop preserves cause
    try equal(expected, bag.items()[0].span);
    try equal(@as(u32, 2), bag.items()[0].details.capacity.limit);
    try equal(.attribute_keys, bag.items()[0].details.capacity.resource);
    bag.reset();
    const allocated = markup.validate(std.testing.failing_allocator, &doc, bag.sink(), .{});
    try expect(allocated.completion == .out_of_memory);
    try equal(.unknown, allocated.validity);
    try equal(expected, bag.items()[0].span);
    var zero: markup.FixedDiagnosticBag(0) = .{};
    const rejected = markup.validate(std.testing.failing_allocator, &doc, zero.sink(), .{});
    try expect(rejected.completion == .out_of_memory);
    try equal(.failed, rejected.diagnostic_delivery);
    for ([_][]const u8{ "", "text", "<a/>", "<a x='1'/><b x='2'/>" }) |small| {
        var r = markup.parseBorrowed(std.testing.allocator, small, discard, .{});
        defer r.deinit();
        const document = r.document.?;
        try equal(@as(u32, 0), markup.requiredValidationScratch(&document));
        const checked = markup.validate(std.testing.failing_allocator, &document, discard, .{});
        try expect(checked.completion == .complete);
        try equal(.valid, checked.validity);
    }
}

test "linear duplicate scattering preserves source order across large scrambled lists" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "<a");
    for (0..128) |_| try source.appendSlice(std.testing.allocator, " z='1' a='2' m='3'");
    try source.appendSlice(std.testing.allocator, "/><b z='4' a='5' z='6'/>");
    var parsed = markup.parseBorrowed(std.testing.allocator, source.items, discard, .{});
    defer parsed.deinit();
    const doc = parsed.document.?;
    var scratch: markup.FixedValidationScratch(384) = .{};
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    const checked = markup.validateIn(&doc, scratch.storage(), bag.sink(), .{});
    try equal(.invalid, checked.validity);
    try equal(@as(u32, 382), checked.errors);
    try equal(@as(usize, 382), bag.items().len);
    for (bag.items()[0..381], 3..) |finding, index| {
        try equal(doc.attributes[index].name, finding.span);
        try equal(doc.attributes[index % 3].name, finding.related.?);
    }
    try equal(doc.attributes[386].name, bag.items()[381].span);
    try equal(doc.attributes[384].name, bag.items()[381].related.?);
    try equal(@as(usize, 8), @sizeOf(markup.AttributeKeyScratch));
}
