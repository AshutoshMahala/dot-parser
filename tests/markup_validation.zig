//! Independent encoding checks; no DOT dependency or implicit parse-time pass.
const std = @import("std");
const markup = @import("markup_parser");
// These fixtures exercise vocabulary-independent structural behavior.
const Structural = markup.Profile(.{ .policy = .{ .mode = .structural } });
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const discard = markup.diagnostic.discard;
const Encoding = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = .err } } });

test "UTF-8 is opt-in, independent of parsing, and covers every raw source context" {
    const source = "\xef\xbb\xbf<\xff \xff='\xff'>\xff<!--\xff--><![CDATA[\xff]]></\xff>\xff";
    var parsed = Encoding.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.success, parsed.outcome);
    const document = parsed.document.?;
    const retained = parsed.retainedBytes();
    const default = Structural.validateIn(&document, .{}, discard, .{});
    try equal(.valid, default.validity);
    try equal(.not_run, default.checks.invalid_utf8);
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    // Encoding-only validation needs no allocator, even with the owned API.
    const checked = Encoding.validate(std.testing.failing_allocator, &document, bag.sink(), .{});
    try equal(.complete, checked.completion);
    try equal(.invalid, checked.validity);
    try equal(.not_run, checked.checks.duplicate_attribute);
    try equal(.complete, checked.checks.invalid_utf8);
    try equal(@as(u64, 8), checked.errors);
    var index: usize = 0;
    for (source, 0..) |byte, offset| if (byte == 0xff) {
        const finding = bag.items()[index];
        try equal(markup.diagnostic.Code.invalid_utf8, finding.code);
        try equal(markup.location.Span{ .start = @intCast(offset), .len = 1 }, finding.span);
        try equal(byte, finding.details.byte);
        try expect(finding.related == null);
        index += 1;
    };
    try equal(index, bag.items().len);
    try expect(document.source.ptr == source.ptr);
    try equal(retained, parsed.retainedBytes());
    try equal(@as(usize, 20), @sizeOf(markup.Node));
    try equal(@as(usize, 20), @sizeOf(markup.Attribute));
    try equal(@as(usize, 36), @sizeOf(markup.Diagnostic));
    try equal(@sizeOf(markup.Profile(.{ .policy = .{ .mode = .structural } }).Session), @sizeOf(Encoding.Session));
}

test "UTF-8 valid boundaries and bytewise recovery do not reinterpret content" {
    // Noncharacters are valid UTF-8: this check is not XML Char/Name validation.
    for ([_][]const u8{ "", "\xef\xbb\xbf", "ASCII", "\xc2\x80\xdf\xbf\xe0\xa0\x80\xed\x9f\xbf\xef\xbf\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf" }) |source| {
        var parsed = Structural.parseBorrowed(std.testing.allocator, source, discard, .{});
        defer parsed.deinit();
        const document = parsed.document.?;
        const result = Encoding.validateIn(&document, .{}, discard, .{});
        try equal(.valid, result.validity);
        try equal(.complete, result.checks.invalid_utf8);
        try equal(@as(u64, 0), result.errors);
    }
    // Every byte of these encodings is invalid when visited as the next lead.
    for ([_][]const u8{ "\x80", "\xc0\xaf", "\xc1\xbf", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", "\xe2\x82", "\xf0\x90\x80" }) |bad| {
        var source: [32]u8 = undefined;
        source[0] = 'x'; // Do not accidentally construct a leading UTF-16 signature.
        @memcpy(source[1..][0..bad.len], bad);
        @memcpy(source[1 + bad.len ..][0..4], "éok");
        var parsed = Structural.parseBorrowed(std.testing.allocator, source[0 .. bad.len + 5], discard, .{});
        defer parsed.deinit();
        const document = parsed.document.?;
        var bag: markup.FixedDiagnosticBag(32) = .{};
        const result = Encoding.validateIn(&document, .{}, bag.sink(), .{});
        try equal(.complete, result.completion);
        try equal(@as(u64, bad.len), result.errors);
        for (bag.items(), 1..) |finding, offset| {
            try equal(@as(u32, @intCast(offset)), finding.span.start);
            try equal(source[offset], finding.details.byte);
        }
        // A truly truncated final sequence behaves identically, without suffix.
        var tail = Structural.parseBorrowed(std.testing.allocator, source[0 .. bad.len + 1], discard, .{});
        defer tail.deinit();
        try equal(result, Encoding.validateIn(&tail.document.?, .{}, discard, .{}));
    }
}

test "combined check policies have fixed-runtime parity and globally source-ordered findings" {
    const source = "\xff<a \xff='1' \xff='2' z='\xff' z='4'/>\xff";
    var parsed = Structural.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    const document = parsed.document.?;
    var scratch: markup.FixedValidationScratch(4) = .{};
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .structural, .validation = .{ .invalid_utf8 = .warning } } });
    inline for (.{ .err, .warning, .off }) |duplicate| {
        inline for (.{ .err, .warning, .off }) |encoding| {
            const patch: markup.Policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = duplicate, .invalid_utf8 = encoding } };
            const Fixed = markup.Profile(.{ .policy = patch });
            var bag: markup.FixedDiagnosticBag(16) = .{};
            const checked = Fixed.validateIn(&document, scratch.storage(), bag.sink(), .{});
            try equal(.complete, checked.completion);
            try equal(@as(u64, (if (duplicate == .err) @as(u64, 2) else 0) + (if (encoding == .err) @as(u64, 5) else 0)), checked.errors);
            try equal(@as(u64, (if (duplicate == .warning) @as(u64, 2) else 0) + (if (encoding == .warning) @as(u64, 5) else 0)), checked.warnings);
            try equal(@as(@TypeOf(checked.validity), if (checked.errors == 0) .valid else .invalid), checked.validity);
            try equal(if (duplicate == .off) .not_run else .complete, checked.checks.duplicate_attribute);
            try equal(if (encoding == .off) .not_run else .complete, checked.checks.invalid_utf8);
            try equal(checked, Dynamic.validateIn(&document, scratch.storage(), discard, .{ .policy = patch }));
            try equal(checked, Fixed.validate(std.testing.allocator, &document, discard, .{}));
            // Omission is successful delivery, never a change in validity/counts.
            var omitted: markup.reporting.FixedBag(markup.Diagnostic, 0, .omit) = .{};
            try equal(checked, Fixed.validateIn(&document, scratch.storage(), omitted.sink(), .{}));
            for (bag.items(), 0..) |finding, i| {
                if (i == 0) continue;
                const previous = bag.items()[i - 1];
                try expect(previous.span.start <= finding.span.start);
                if (previous.span.start == finding.span.start) {
                    try expect(previous.code == .invalid_utf8 or previous.code == .invalid_utf8_tolerated);
                    try expect(finding.code == .duplicate_attribute or finding.code == .duplicate_attribute_tolerated);
                }
            }
        }
    }
    const inherited = Dynamic.validateIn(&document, scratch.storage(), discard, .{});
    try equal(@as(u64, 5), inherited.warnings);
    const reset = Dynamic.validateIn(&document, scratch.storage(), discard, .{ .policy = markup.presets.standard });
    try equal(.not_run, reset.checks.invalid_utf8);
    try equal(markup.validateIn(&document, scratch.storage(), discard, .{}), reset);
    try equal(.valid, Dynamic.validatePolicy(.{ .validation = .{ .invalid_utf8 = .err } }));
}

test "encoding and duplicate findings continue independently but sink stop ends the prefix" {
    const Both = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .invalid_utf8 = .err } } });
    var parsed = Structural.parseBorrowed(std.testing.allocator, "\xff<a x='1' x='2'/>\xff", discard, .{});
    defer parsed.deinit();
    const document = parsed.document.?;
    var scratch: markup.FixedValidationScratch(2) = .{};
    var first: markup.FixedDiagnosticBag(1) = .{};
    const stopped = Both.validateIn(&document, scratch.storage(), first.sink(), .{});
    try equal(markup.reporting.StopReason.requested, stopped.completion.diagnostic_stopped);
    try equal(.invalid, stopped.validity);
    try equal(@as(u64, 1), stopped.errors); // Duplicate not yet visited.
    try equal(.incomplete, stopped.checks.invalid_utf8);
    try equal(.incomplete, stopped.checks.duplicate_attribute);
    var none: markup.FixedDiagnosticBag(0) = .{};
    const failed = Both.validateIn(&document, scratch.storage(), none.sink(), .{});
    try equal(markup.reporting.StopReason.capacity, failed.completion.diagnostic_stopped);
    try equal(.failed, failed.diagnostic_delivery);
    try equal(stopped.checks, failed.checks);
    var oom_bag = markup.GrowableDiagnosticBag.init(std.testing.failing_allocator, .{});
    defer oom_bag.deinit();
    const oom = Both.validateIn(&document, scratch.storage(), oom_bag.sink(), .{});
    try equal(markup.reporting.StopReason.out_of_memory, oom.completion.diagnostic_stopped);
    try equal(@as(u64, 1), oom.errors);
    var last: markup.FixedDiagnosticBag(3) = .{};
    const final_stop = Both.validateIn(&document, scratch.storage(), last.sink(), .{});
    try equal(.complete, final_stop.checks.duplicate_attribute);
    try equal(.incomplete, final_stop.checks.invalid_utf8);
    try equal(@as(u64, 3), final_stop.errors);
    const complete = Both.validateIn(&document, scratch.storage(), discard, .{});
    try equal(.complete, complete.completion);
    try equal(@as(u64, 3), complete.errors);
    try equal(.complete, complete.checks.invalid_utf8);
}

test "resource preflight precedes checks, but encoding alone never needs duplicate scratch" {
    const Both = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .invalid_utf8 = .err } } });
    var parsed = Structural.parseBorrowed(std.testing.allocator, "\xff<a x='1' x='2'/>", discard, .{});
    defer parsed.deinit();
    const document = parsed.document.?;
    var bag: markup.FixedDiagnosticBag(4) = .{};
    const capacity = Both.validateIn(&document, .{}, bag.sink(), .{});
    try equal(@as(u32, 2), capacity.completion.storage_exhausted);
    try equal(.unknown, capacity.validity);
    try equal(.incomplete, capacity.checks.invalid_utf8);
    try equal(.incomplete, capacity.checks.duplicate_attribute);
    try equal(@as(u64, 0), capacity.errors);
    try equal(@as(usize, 1), bag.items().len);
    try equal(markup.diagnostic.Code.capacity_exhausted, bag.items()[0].code);
    try equal(document.records[1].name, bag.items()[0].span);
    var empty: markup.FixedDiagnosticBag(0) = .{};
    const oom = Both.validate(std.testing.failing_allocator, &document, empty.sink(), .{});
    try equal(.out_of_memory, oom.completion);
    try equal(.failed, oom.diagnostic_delivery);
    try equal(capacity.checks, oom.checks);
    try equal(.complete, Encoding.validate(std.testing.failing_allocator, &document, discard, .{}).completion);
    // No enabled checks: even cancellation and the document are not inspected.
    const Off = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = .off }, .execution = .{ .cancellation = true } } });
    var stop: Stop = .{ .after = 0 };
    try equal(.valid, Off.validate(std.testing.failing_allocator, &document, discard, .{ .cancellation = stop.hook() }).validity);
    try equal(@as(u32, 0), stop.polls);
}

const Stop = struct {
    polls: u32 = 0,
    after: u32,
    fn requested(raw: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.polls += 1;
        return self.polls > self.after;
    }
    fn hook(self: *@This()) markup.Cancellation {
        return .{ .context = self, .is_requested = requested };
    }
};

test "UTF-8 chunk cancellation preserves known invalidity" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = .warning } } });
    const source = "\xff" ++ "東京" ** 1000;
    var parsed = Structural.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    const document = parsed.document.?;
    var inactive: Stop = .{ .after = 0 };
    try equal(.complete, Dynamic.validateIn(&document, .{}, discard, .{ .cancellation = inactive.hook() }).completion);
    try equal(@as(u32, 0), inactive.polls);
    inline for (.{ .err, .warning }) |severity| {
        const Fixed = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = severity }, .execution = .{ .cancellation = true } } });
        for ([_]u32{ 0, 1, 2, 10, 50 }) |after| {
            var stop: Stop = .{ .after = after };
            const checked = Fixed.validateIn(&document, .{}, discard, .{ .cancellation = stop.hook() });
            try equal(.cancelled, checked.completion);
            try equal(after + 1, stop.polls);
            try equal(.incomplete, checked.checks.invalid_utf8);
            try equal(@as(@TypeOf(checked.validity), if (after >= 2 and severity == .err) .invalid else .unknown), checked.validity);
            try equal(@as(u64, if (after >= 2) 1 else 0), checked.errors + checked.warnings);
            var dynamic_stop: Stop = .{ .after = after };
            try equal(checked, Dynamic.validateIn(&document, .{}, discard, .{ .cancellation = dynamic_stop.hook(), .policy = .{ .validation = .{ .invalid_utf8 = severity }, .execution = .{ .cancellation = true } } }));
        }
    }
}

test "encoding chunk boundaries preserve whole scalars and immediate sink stops" {
    const P = markup.Profile(.{ .policy = .{ .mode = .structural, .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = .err }, .execution = .{ .cancellation = true } } });
    inline for (.{ "x", "é", "東", "😀" }) |scalar| {
        inline for (.{ 61, 62, 63, 64, 65 }) |padding| {
            const source = "x" ** padding ++ scalar ++ "\xff" ++ "x" ** 256;
            var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
            const parsed = P.parseBorrowedIn(source, .{ .document = output.storage() }, discard, .{});
            var stop: Stop = .{ .after = 2 };
            var bag: markup.FixedDiagnosticBag(2) = .{};
            const checked = P.validateIn(&parsed.document.?, .{}, bag.sink(), .{ .cancellation = stop.hook() });
            try equal(.cancelled, checked.completion);
            try equal(@as(u32, 3), stop.polls);
            try equal(@as(u64, if (padding + scalar.len < 64) 1 else 0), checked.errors);
            // A sink stop within a chunk must not wait for its next poll.
            var one: markup.FixedDiagnosticBag(1) = .{};
            var never: Stop = .{ .after = std.math.maxInt(u32) };
            const sink_stop = P.validateIn(&parsed.document.?, .{}, one.sink(), .{ .cancellation = never.hook() });
            try equal(markup.reporting.StopReason.requested, sink_stop.completion.diagnostic_stopped);
            try equal(@as(u32, padding + scalar.len), one.items()[0].span.start);
            try equal(@as(u64, 1), sink_stop.errors);
            try std.testing.expect(never.polls <= 3);
        }
    }
    const source = "x" ** 100_000;
    var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    const parsed = P.parseBorrowedIn(source, .{ .document = output.storage() }, discard, .{});
    var never: Stop = .{ .after = std.math.maxInt(u32) };
    try equal(.complete, P.validateIn(&parsed.document.?, .{}, discard, .{ .cancellation = never.hook() }).completion);
    try equal(@as(u32, 1 + (source.len + 63) / 64), never.polls);
}

test "random raw bytes agree with a UTF-8 oracle across scalar and bounded block parsing" {
    var random = std.Random.DefaultPrng.init(0x55544638);
    var source: [260]u8 = undefined;
    source[0] = 'x';
    for (0..100) |_| {
        const len = random.random().uintLessThan(usize, source.len - 1) + 1;
        for (source[1..len]) |*byte| byte.* = if (random.random().boolean()) 'x' else random.random().int(u8) | 0x80;
        var expected: [260]u32 = undefined;
        var count: usize = 0;
        var at: usize = 0;
        while (at < len) {
            const width = std.unicode.utf8ByteSequenceLength(source[at]) catch 0;
            if (width != 0 and width <= len - at and std.unicode.utf8ValidateSlice(source[at..][0..width])) {
                at += width;
            } else {
                expected[count] = @intCast(at);
                count += 1;
                at += 1;
            }
        }
        inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |cancellable| {
            const P = markup.Profile(.{ .policy = .{ .mode = .structural, .scanner = backend, .execution = .{ .metering = true, .cancellation = cancellable }, .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = .err } } });
            var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
            var session = P.Session.init(source[0..len], .{ .document = output.storage() }, discard, .{});
            while (session.result() == null) _ = session.advance(1);
            const document = session.result().?.document.?;
            var bag: markup.FixedDiagnosticBag(260) = .{};
            const checked = P.validateIn(&document, .{}, bag.sink(), .{});
            try equal(.complete, checked.completion);
            try equal(@as(u64, count), checked.errors);
            try equal(count, bag.items().len);
            for (bag.items(), expected[0..count]) |finding, offset| try equal(offset, finding.span.start);
        };
    }
}
