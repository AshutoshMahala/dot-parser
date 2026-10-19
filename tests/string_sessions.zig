const std = @import("std");
const s = @import("string_processor");
const t = std.testing;

test "all encodings and malformed runs agree under every budget partition" {
    const P = s.Profile(.{ .runtime_policy = true, .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 }, .unicode_case_folding = true, .policy = .{
        .execution = .{ .metering = true },
        .comparison = .case_insensitive,
        .validation = .{
            .equals = .{ .expected = "STRASSE", .severity = .warning },
            .one_of = .{ .values = &.{ "wrong", "STRASSE", "FFI", "" }, .severity = .err },
        },
    } });
    const cases = [_]struct { encoding: s.ActualEncoding, bytes: []const u8 }{
        .{ .encoding = .utf8, .bytes = "Straße" },
        .{ .encoding = .utf8, .bytes = "ﬃ" },
        .{ .encoding = .utf8, .bytes = "😀" },
        .{ .encoding = .utf8, .bytes = "\xff\xffa\xff\xc0" },
        .{ .encoding = .utf8, .bytes = "\xf0\x9f" },
        .{ .encoding = .utf8, .bytes = "" },
        .{ .encoding = .ascii, .bytes = "STRASSE" },
        .{ .encoding = .ascii, .bytes = "\x80\xffx" },
        .{ .encoding = .utf16le, .bytes = "S\x00t\x00r\x00a\x00\xdf\x00e\x00" },
        .{ .encoding = .utf16be, .bytes = "\x00S\x00t\x00r\x00a\x00\xdf\x00e" },
        .{ .encoding = .utf16le, .bytes = "\x00\xd8\x00\xd8a\x00x" },
        .{ .encoding = .utf16be, .bytes = "\xd8\x3d\xde\x00" },
        .{ .encoding = .utf32le, .bytes = "S\x00\x00\x00T\x00\x00\x00R\x00\x00\x00A\x00\x00\x00S\x00\x00\x00S\x00\x00\x00E\x00\x00\x00" },
        .{ .encoding = .utf32be, .bytes = "\x00\x01\xf6\x00" },
        .{ .encoding = .utf32le, .bytes = "\x00\x00\x11\x00\xff" },
    };
    for (cases) |case| {
        var reference: P.FixedDiagnosticBag(16) = .{};
        const expected = try P.parseAndValidate(.{ .bytes = case.bytes, .origin = 29 }, reference.sink(), .{ .encoding = case.encoding, .policy = .{ .execution = .{ .metering = false } } });
        var credits: ?u64 = null;
        for ([_]u32{ 1, 2, 3, 7, 64, 999 }) |budget| {
            var bag: P.FixedDiagnosticBag(16) = .{};
            var session = try P.Session.init(.{ .bytes = case.bytes, .origin = 29 }, bag.sink(), .{ .encoding = case.encoding });
            defer session.deinit();
            try t.expectEqual(null, session.result());
            const zero = try session.advance(0);
            try t.expectEqual(@as(u32, 0), zero.work_used);
            try t.expectEqual(@as(u32, 0), zero.source_frontier);
            try t.expectEqual(null, zero.outcome);
            var total: u64 = 0;
            var frontier: u32 = 0;
            while (true) {
                // Moving a session must not leave pointers into its old address.
                var moved = session;
                const progress = try moved.advance(budget);
                session = moved;
                try t.expect(progress.work_used <= budget and progress.work_used > 0);
                try t.expect(progress.source_frontier >= frontier and progress.source_frontier <= case.bytes.len);
                frontier = progress.source_frontier;
                total += progress.work_used;
                try t.expect(total < 10_000);
                if (progress.outcome != null) break;
                try t.expectEqual(null, session.result());
            }
            if (credits) |previous| try t.expectEqual(previous, total) else credits = total;
            try t.expectEqualDeep(expected, session.result().?);
            try t.expectEqualSlices(P.Diagnostic, reference.items(), bag.items());
            try t.expectEqual(@as(u32, 0), (try session.advance(5)).work_used);
            try t.expectEqualDeep(expected, session.cancel());
        }
    }
}

const NoDigits = struct {
    pub const Settings = void;
    pub const defaults = {};
    pub const uses_comparison = false;
    pub fn State(comptime _: type) type {
        return struct { offset: u32 = 0, failed: bool = false };
    }
    pub fn step(state: anytype, value: anytype, _: void, context: anytype) s.Step {
        var cursor = value.cursor();
        cursor.offset = state.offset;
        const start = state.offset;
        const cp = cursor.next() catch {
            context.invalidValidator();
            return .stopped;
        } orelse return if (state.failed) .failed else .passed;
        state.offset = cursor.offset;
        if (cp >= '0' and cp <= '9') {
            state.failed = true;
            if (!context.report(.{ .span = .{ .start = start, .len = state.offset - start } })) return .stopped;
        }
        return .pending;
    }
};

test "custom step-only validators share sessions, reports and unmetered execution" {
    const P = s.Profile(.{ .custom = NoDigits, .runtime_policy = true, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .custom = .warning },
    } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    var session = try P.Session.init(.{ .bytes = "a1b2c3", .origin = 20 }, bag.sink(), .{});
    defer session.deinit();
    while ((try session.advance(1)).outcome == null) {}
    try t.expect(session.result().?.valid());
    try t.expectEqual(@as(u64, 3), session.result().?.warnings);
    try t.expectEqual(@as(usize, 3), bag.items().len); // no generic fourth finding
    try t.expectEqual(@as(u32, 21), bag.items()[0].span.start);
    const expected = try P.parseAndValidate(.{ .bytes = "a1b2c3", .origin = 20 }, P.Sink.discard, .{ .policy = .{ .execution = .{ .metering = false } } });
    try t.expectEqualDeep(expected, session.result().?);
    const Shared = s.Profile(.{ .custom = s.validators.Equals, .unicode_case_folding = true, .policy = .{
        .execution = .{ .metering = true },
        .comparison = .case_insensitive,
        .custom = "STRASSE",
        .validation = .{ .custom = .err },
    } });
    var shared = try Shared.Session.init(.{ .bytes = "Straße", .origin = 0 }, Shared.Sink.discard, .{});
    while (shared.advance(1).outcome == null) {}
    try t.expect(shared.result().?.valid());
}

test "runtime execution is latched, invalid reset preserves work, synchronous checks cannot be metered" {
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{ .execution = .{ .metering = true } } });
    var session = try P.Session.init(.{ .bytes = "abc", .origin = 0 }, P.Sink.discard, .{});
    defer session.deinit();
    _ = try session.advance(1);
    try t.expectError(error.InvalidCancellationInterval, session.reset(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    try t.expectError(error.InvalidFragment, session.reset(.{ .bytes = "x", .origin = std.math.maxInt(u32) }, P.Sink.discard, .{}));
    try t.expectEqual(@as(u32, 1), (try session.advance(0)).source_frontier);
    try t.expect(session.run().valid());
    try session.reset(.{ .bytes = "abc", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .execution = .{ .metering = false } } });
    try t.expectError(error.MeteringDisabled, session.advance(1));
    try t.expect(session.run().valid());
    try session.reset(.{ .bytes = "", .origin = 0 }, P.Sink.discard, .{});
    while ((try session.advance(1)).outcome == null) {}
    try t.expect(session.result().?.valid());

    const Predicate = s.validators.Predicate(void, {}, struct {
        fn check(_: anytype, _: void) bool {
            return true;
        }
    }.check);
    const Q = s.Profile(.{ .custom = Predicate, .runtime_policy = true, .policy = .{ .validation = .{ .custom = .err } } });
    try t.expectEqual(.non_resumable_validator, Q.validatePolicy(.{ .execution = .{ .metering = true } }).invalid);
    try t.expectError(error.NonResumableValidator, Q.Session.init(.{ .bytes = "x", .origin = 0 }, Q.Sink.discard, .{ .policy = .{ .execution = .{ .metering = true } } }));
    // A bound but disabled synchronous validator does not prevent metering.
    var disabled = try Q.Session.init(.{ .bytes = "x", .origin = 0 }, Q.Sink.discard, .{ .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .off } } });
    while ((try disabled.advance(1)).outcome == null) {}
    try t.expect(disabled.result().?.valid());
}

test "cancellation entry, intervals, terminal results and no cancellation diagnostics" {
    const Hook = struct {
        calls: u32 = 0,
        stop: bool = false,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.stop;
        }
        fn token(self: *@This()) s.Cancellation {
            return .{ .context = self, .is_requested = poll };
        }
    };
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    var hook: Hook = .{};
    var session = try P.Session.init(.{ .bytes = "a" ** 100, .origin = 0 }, P.Sink.discard, .{ .cancellation = hook.token(), .policy = .{ .execution = .{ .cancellation_interval = 8 } } });
    try t.expectEqual(@as(u32, 0), hook.calls); // init does not scan or poll
    _ = try session.advance(3);
    try t.expectEqual(@as(u32, 1), hook.calls);
    _ = try session.advance(3);
    try t.expectEqual(@as(u32, 2), hook.calls); // every resume polls
    hook.stop = true;
    const stopped = try session.advance(0);
    try t.expectEqual(.cancelled, stopped.outcome.?);
    try t.expectEqual(@as(u32, 0), stopped.work_used);
    try t.expectEqual(@as(u64, 0), session.result().?.errors);
    const calls = hook.calls;
    _ = try session.advance(50);
    _ = session.run();
    try t.expectEqual(calls, hook.calls);
    hook.stop = false;
    try session.reset(.{ .bytes = "", .origin = 0 }, P.Sink.discard, .{ .cancellation = hook.token() });
    try t.expect(session.run().valid());
    hook.stop = true;
    try t.expect(session.cancel().valid());
}

test "sink stops, fail fast and abandoning a session preserve incomplete coverage" {
    const P = s.Profile(.{ .custom = NoDigits, .runtime_policy = true, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    var bag: P.FixedDiagnosticBag(1) = .{};
    var session = try P.Session.init(.{ .bytes = "123", .origin = 0 }, bag.sink(), .{});
    while ((try session.advance(1)).outcome == null) {}
    try t.expectEqual(.requested, session.result().?.completion.diagnostic_stop);
    try t.expectEqual(.incomplete, session.result().?.checks.custom);
    try t.expectEqual(@as(u64, 1), session.result().?.errors);
    try session.reset(.{ .bytes = "123", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .on_error = .fail_fast } });
    try t.expectEqual(.fail_fast, session.run().completion);
    try session.reset(.{ .bytes = "123", .origin = 0 }, P.Sink.discard, .{});
    session.deinit();
    try t.expectEqual(.cancelled, session.result().?.completion);
}

test "cancellation stops expected scans, folding, membership and custom steps" {
    const Hook = struct {
        calls: u32 = 0,
        stop_at: u32 = std.math.maxInt(u32),
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls >= self.stop_at;
        }
    };
    const P = s.Profile(.{ .custom = s.validators.Equals, .unicode_case_folding = true, .policy = .{
        .execution = .{ .metering = true, .cancellation = true },
        .comparison = .case_insensitive,
        .validation = .{
            .equals = .{ .expected = "FFIFFIFFI", .severity = .err },
            .one_of = .{ .values = &.{ "wrong", "FFIFFIFFI" }, .severity = .err },
            .custom = .err,
        },
        .custom = "FFIFFIFFI",
    } });
    // Compare steps include the expected UTF-8 pass and pending fold expansions.
    inline for (.{ .{ s.Stage.equals, 0 }, .{ s.Stage.equals, 12 }, .{ s.Stage.one_of, 3 }, .{ s.Stage.custom, 12 } }) |target| {
        var hook: Hook = .{};
        var session = try P.Session.init(.{ .bytes = "ﬃﬃﬃ", .origin = 0 }, P.Sink.discard, .{ .cancellation = .{ .context = &hook, .is_requested = Hook.poll } });
        defer session.deinit();
        var progress = session.advance(0);
        while (progress.stage != target[0]) {
            progress = session.advance(1);
            try t.expectEqual(null, progress.outcome);
        }
        if (target[1] != 0) {
            progress = session.advance(target[1]);
            try t.expectEqual(target[0], progress.stage);
            try t.expectEqual(null, progress.outcome);
        }
        try t.expectEqual(@as(u32, "ﬃﬃﬃ".len), progress.source_frontier);
        hook.stop_at = hook.calls + 3;
        const stopped = session.advance(100);
        try t.expectEqual(.cancelled, stopped.outcome.?);
        try t.expectEqual(@as(u32, 2), stopped.work_used);
        try t.expectEqual(.incomplete, @field(session.result().?.checks, @tagName(target[0])));
        try t.expectEqual(@as(u64, 0), session.result().?.errors);
    }
}

test "invalid custom comparison suffix and changing operands cannot hide across pauses" {
    const Custom = struct {
        pub const Settings = bool;
        pub const defaults = false;
        pub const uses_comparison = true;
        pub fn State(comptime Context: type) type {
            return struct { comparison: Context.ComparisonState = .{}, calls: u32 = 0 };
        }
        pub fn step(state: anytype, value: anytype, change: bool, context: anytype) s.Step {
            state.calls += 1;
            return context.equalsStep(&state.comparison, value, if (change and state.calls > 1) "other" else "different\xff");
        }
    };
    const P = s.Profile(.{ .custom = Custom, .runtime_policy = true, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    for ([_]bool{ false, true }) |change| {
        var session = try P.Session.init(.{ .bytes = "x", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .custom = change } });
        defer session.deinit();
        while ((try session.advance(1)).outcome == null) {}
        try t.expectEqual(.invalid_validator, session.result().?.completion);
        try t.expectEqual(.incomplete, session.result().?.checks.custom);
        try t.expectEqual(@as(u64, 0), session.result().?.errors);
    }
}

test "seeded arbitrary inputs have identical fast and stepped results and diagnostics" {
    const P = s.Profile(.{ .runtime_policy = true, .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 }, .unicode_case_folding = true, .policy = .{
        .comparison = .case_insensitive,
        .validation = .{ .equals = .{ .expected = "ffi", .severity = .warning }, .one_of = .{ .values = &.{ "", "ffi", "Straße" }, .severity = .err } },
    } });
    var random = std.Random.DefaultPrng.init(0x71ea39);
    var bytes: [64]u8 = undefined;
    for (0..2000) |_| {
        random.random().bytes(&bytes);
        const length = random.random().uintLessThan(usize, bytes.len + 1);
        const actual = random.random().enumValue(s.ActualEncoding);
        var fast_bag: P.FixedDiagnosticBag(66) = .{};
        var slow_bag: P.FixedDiagnosticBag(66) = .{};
        const fragment = s.Fragment{ .bytes = bytes[0..length], .origin = 13 };
        const expected = try P.parseAndValidate(fragment, fast_bag.sink(), .{ .encoding = actual });
        var session = try P.Session.init(fragment, slow_bag.sink(), .{ .encoding = actual, .policy = .{ .execution = .{ .metering = true } } });
        defer session.deinit();
        var total: u32 = 0;
        while (true) {
            const budget = random.random().uintLessThan(u32, 16) + 1;
            const progress = try session.advance(budget);
            try t.expect(progress.work_used <= budget);
            total += progress.work_used;
            try t.expect(total < 1000);
            if (progress.outcome != null) break;
        }
        try t.expectEqualDeep(expected, session.result().?);
        try t.expectEqualSlices(P.Diagnostic, fast_bag.items(), slow_bag.items());
    }
}

test "interval changes do not change credits and disabled hooks stay unused" {
    const Hook = struct {
        calls: u32 = 0,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return false;
        }
    };
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = "x" ** 100, .severity = .err } },
    } });
    var total: ?u32 = null;
    for ([_]bool{ false, true }) |enabled| {
        for ([_]u32{ 1, 4, 64, std.math.maxInt(u32) }) |interval| {
            var hook: Hook = .{};
            var session = try P.Session.init(.{ .bytes = "x" ** 100, .origin = 0 }, P.Sink.discard, .{
                .policy = .{ .execution = .{ .cancellation = enabled, .cancellation_interval = interval } },
                .cancellation = .{ .context = &hook, .is_requested = Hook.poll },
            });
            defer session.deinit();
            const progress = try session.advance(1000);
            try t.expect(session.result().?.valid());
            if (total) |n| try t.expectEqual(n, progress.work_used) else total = progress.work_used;
            const expected_calls = if (enabled) (progress.work_used - 1) / interval + 1 else 0;
            try t.expectEqual(expected_calls, hook.calls);
        }
    }
}
