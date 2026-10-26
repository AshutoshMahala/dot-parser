const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const s = @import("string_processor");
const t = std.testing;

test "logical equality and membership use decoded contents, not spelling" {
    const P = s.Profile(.{ .policy = .{ .validation = .{
        .equals = .{ .expected = "A&B", .severity = .err },
        .one_of = .{ .values = &.{ "wrong", "A&B" }, .severity = .err },
    } } });
    const M = P.WithReader(markup.LogicalReader(.utf8));
    for ([_][]const u8{ "A&amp;B", "A&#38;B", "A&#x26;B", "A&B" }) |text| {
        const result = try M.parseAndValidate(try markup.LogicalReader(.utf8).init(.{ .bytes = text, .origin = 71 }, .{ .malformed_reference = .accept }), P.Sink.discard, .{});
        try t.expect(result.valid());
    }
    const D = P.WithReader(dot.identifier.LogicalReader(.utf8));
    for ([_][]const u8{ "A&B", "\"A&B\"", "\"A\" /*glue*/ + \"&B\"", "\"A\\\r\n&B\"" }) |text| {
        const result = try D.parseAndValidate(try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = text, .origin = 71 }), P.Sink.discard, .{});
        try t.expect(result.valid());
    }
    var bag: P.FixedDiagnosticBag(4) = .{};
    const bad = try D.parseAndValidate(try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"X\" + \"Y\"", .origin = 71 }), bag.sink(), .{});
    try t.expect(!bad.valid());
    try t.expectEqual(@as(u64, 2), bad.errors);
    try t.expectEqualDeep(s.Span{ .start = 71, .len = 9 }, bag.items()[0].span);
}

fn partition(comptime P: type, reader: anytype, options: P.Options) !void {
    const B = P.WithReader(@TypeOf(reader));
    var expected_bag: P.FixedDiagnosticBag(16) = .{};
    const expected = try B.parseAndValidate(reader, expected_bag.sink(), options);
    var credits: ?u64 = null;
    for ([_]u32{ 1, 2, 3, 7, 64, 1000 }) |budget| {
        var bag: P.FixedDiagnosticBag(16) = .{};
        var session = try B.Session.init(reader, bag.sink(), options);
        defer session.deinit();
        const zero = try session.advance(0);
        try t.expectEqual(@as(u32, 0), zero.work_used);
        try t.expectEqual(null, zero.outcome);
        var total: u64 = 0;
        var frontier: u32 = 0;
        while (true) {
            var moved = session;
            const progress = try moved.advance(budget);
            session = moved;
            try t.expect(progress.work_used > 0 and progress.work_used <= budget);
            try t.expect(progress.source_frontier >= frontier and progress.source_frontier <= reader.fragment().bytes.len);
            frontier = progress.source_frontier;
            total += progress.work_used;
            try t.expect(total < 100_000);
            if (progress.outcome != null) break;
        }
        if (credits) |previous| try t.expectEqual(previous, total) else credits = total;
        try t.expectEqualDeep(expected, session.result().?);
        try t.expectEqualDeep(expected_bag.items(), bag.items());
        try t.expectEqual(@as(u32, 0), (try session.advance(100)).work_used);
        try t.expectEqualDeep(expected, session.cancel());
    }
}

/// Same reader without its optional batch service: a semantic/credit oracle.
fn ScalarOnly(comptime R: type) type {
    return struct {
        inner: R,
        pub const encoding_kind = R.encoding_kind;
        pub fn fragment(self: *const @This()) s.Fragment {
            return self.inner.fragment();
        }
        pub fn restarted(self: *const @This()) s.Fragment.Error!@This() {
            return .{ .inner = try self.inner.restarted() };
        }
        pub fn location(self: *const @This()) s.logical.SourceLocation {
            return self.inner.location();
        }
        pub fn contiguous(self: *const @This()) ?s.logical.BorrowedContents {
            return self.inner.contiguous();
        }
        pub fn position(self: *const @This()) u32 {
            return self.inner.position();
        }
        pub fn step(self: *@This()) s.logical.Step {
            return self.inner.step();
        }
    };
}

fn compareBatches(comptime P: type, reader: anytype, options: P.Options, budget: u32) !void {
    const R = @TypeOf(reader);
    var a_bag: P.FixedDiagnosticBag(16) = .{};
    var b_bag: P.FixedDiagnosticBag(16) = .{};
    var batched = try P.WithReader(R).Session.init(reader, a_bag.sink(), options);
    defer batched.deinit();
    var scalar = try P.WithReader(ScalarOnly(R)).Session.init(.{ .inner = reader }, b_bag.sink(), options);
    defer scalar.deinit();
    while (true) {
        const a = try batched.advance(budget);
        const b = try scalar.advance(budget);
        try t.expectEqualDeep(b, a); // stage, frontier, stop and credits at EVERY yield
        try t.expectEqualDeep(b_bag.items(), a_bag.items());
        if (a.outcome != null) break;
    }
    try t.expectEqualDeep(scalar.result(), batched.result());
}

test "logical ASCII batches match scalar steps at boundaries, failures and folds" {
    const P = s.Profile(.{ .runtime_policy = true, .unicode_case_folding = true, .custom = s.validators.Equals, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = &@as([80]u8, @splat('a')), .severity = .err }, .one_of = .{ .values = &.{ &@as([80]u8, @splat('b')), &@as([80]u8, @splat('a')) }, .severity = .warning }, .custom = .warning },
        .custom = &@as([80]u8, @splat('a')),
    } });
    const sources = [_][]const u8{
        &@as([80]u8, @splat('a')),
        &@as([80]u8, @splat('A')),
        &@as([32]u8, @splat('a')) ++ "ß" ++ &@as([48]u8, @splat('a')),
        &@as([16]u8, @splat('a')) ++ "&amp;" ++ &@as([48]u8, @splat('a')),
        &@as([32]u8, @splat('a')) ++ "&#65;" ++ &@as([48]u8, @splat('a')),
        &@as([48]u8, @splat('a')) ++ "&" ++ &@as([32]u8, @splat('z')) ++ " x", // accepted malformed spelling replay
        &@as([48]u8, @splat('a')) ++ "&unknown;",
        &@as([48]u8, @splat('a')) ++ "\xff",
        &@as([80]u8, @splat('a')) ++ "\xe2\x82", // buffered, truncated scalar at EOF
        &@as([16]u8, @splat('a')) ++ "\t\r\n" ++ &@as([48]u8, @splat('a')),
    };
    for (sources) |source| {
        for ([_]u32{ 1, 15, 16, 17, 31, 64, 257 }) |budget| {
            for ([_]s.Comparison{ .case_sensitive, .ascii_case_insensitive, .case_insensitive }) |comparison| {
                const options: P.Options = .{ .policy = .{ .comparison = comparison } };
                try compareBatches(P, try s.LogicalReader(.utf8).init(.{ .bytes = source, .origin = 7 }), options, budget);
                try compareBatches(P, try markup.LogicalReader(.utf8).init(.{ .bytes = source, .origin = 7 }, .{ .malformed_reference = .accept, .normalize_attribute_whitespace = true }), options, budget);
            }
        }
    }
    for ([_][]const u8{
        "\"" ++ &@as([80]u8, @splat('a')) ++ "\"",
        "\"" ++ &@as([32]u8, @splat('a')) ++ "\" + /* glue */ \"" ++ &@as([48]u8, @splat('a')) ++ "\"",
        "\"" ++ &@as([16]u8, @splat('a')) ++ "\\\r\n" ++ &@as([64]u8, @splat('a')) ++ "\"",
        "\"" ++ &@as([16]u8, @splat('a')) ++ "\\\"" ++ &@as([64]u8, @splat('a')) ++ "\"",
        "\"" ++ &@as([16]u8, @splat('a')) ++ "\\n" ++ &@as([64]u8, @splat('a')) ++ "\"",
        "\"" ++ &@as([80]u8, @splat('a')), // missing quote remains a prerequisite failure
    }) |source| {
        for ([_]u32{ 1, 15, 16, 17, 64, 257 }) |budget| {
            try compareBatches(P, try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = source, .origin = 7 }), .{}, budget);
        }
    }
}

test "logical batching preserves cancellation polls and exact stopping frontiers" {
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{
        .execution = .{ .metering = true, .cancellation = true },
        .validation = .{ .equals = .{ .expected = &@as([160]u8, @splat('a')), .severity = .err } },
    } });
    const Probe = struct {
        calls: u32 = 0,
        stop: u32,
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls == self.stop;
        }
    };
    const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = &@as([160]u8, @splat('a')), .origin = 13 }, .{});
    for ([_]u32{ 1, 7, 16, 17, 32, 65 }) |interval| {
        for ([_]u32{ 1, 15, 16, 17, 64, 1024 }) |budget| {
            for ([_]u32{ 1, 2, 3, 7, 13, 40, 1000 }) |stop| {
                var pa: Probe = .{ .stop = stop };
                var pb: Probe = .{ .stop = stop };
                var a = try P.WithReader(@TypeOf(reader)).Session.init(reader, P.Sink.discard, .{
                    .policy = .{ .execution = .{ .cancellation_interval = interval } },
                    .cancellation = .{ .context = &pa, .is_requested = Probe.requested },
                });
                var b = try P.WithReader(ScalarOnly(@TypeOf(reader))).Session.init(.{ .inner = reader }, P.Sink.discard, .{
                    .policy = .{ .execution = .{ .cancellation_interval = interval } },
                    .cancellation = .{ .context = &pb, .is_requested = Probe.requested },
                });
                while (true) {
                    const x = try a.advance(budget);
                    const y = try b.advance(budget);
                    try t.expectEqualDeep(y, x);
                    try t.expectEqual(pb.calls, pa.calls);
                    if (x.outcome != null) break;
                }
                try t.expectEqualDeep(b.result(), a.result());
            }
        }
    }
}

test "logical ASCII batches resume after Unicode fold expansions on either side" {
    inline for (comptime .{
        .{ &@as([32]u8, @splat('a')) ++ "ß" ++ &@as([64]u8, @splat('a')), &@as([32]u8, @splat('A')) ++ "SS" ++ &@as([64]u8, @splat('A')) },
        .{ &@as([32]u8, @splat('a')) ++ "SS" ++ &@as([64]u8, @splat('a')), &@as([32]u8, @splat('A')) ++ "ß" ++ &@as([64]u8, @splat('A')) },
    }) |pair| {
        const P = s.Profile(.{ .runtime_policy = true, .unicode_case_folding = true, .policy = .{
            .execution = .{ .metering = true },
            .comparison = .case_insensitive,
            .validation = .{ .equals = .{ .expected = pair[1], .severity = .err } },
        } });
        const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = pair[0], .origin = 13 }, .{});
        for ([_]u32{ 1, 16, 17, 64, 257 }) |budget| try compareBatches(P, reader, .{}, budget);
        try t.expect((try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, P.Sink.discard, .{})).valid());
    }
}

test "batch fallback cannot hide an invalid dynamic pattern suffix" {
    const Dynamic = struct {
        pub const Settings = []const u8;
        pub const defaults: Settings = &@as([64]u8, @splat('a')) ++ "\xff";
        pub const uses_comparison = true;
        pub const State = s.validators.Equals.State;
        pub const step = s.validators.Equals.step;
        pub const batch = s.validators.Equals.batch;
        // Deliberately dynamic: no validateSettings prerequisite.
    };
    const P = s.Profile(.{ .custom = Dynamic, .runtime_policy = true, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .custom = .err },
    } });
    const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = &@as([96]u8, @splat('b')), .origin = 9 }, .{});
    for ([_]u32{ 1, 16, 64, 4096 }) |budget| try compareBatches(P, reader, .{}, budget);
    const result = try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, P.Sink.discard, .{});
    try t.expectEqual(.invalid_validator, result.completion);
}

test "ASCII reader commits are checked and leave rejected runs untouched" {
    var plain = try s.LogicalReader(.utf8).init(.{ .bytes = &@as([16]u8, @splat('a')) ++ "\xff", .origin = 0 });
    try t.expect(!plain.skipAscii(17));
    try t.expect(!plain.skipAscii(0));
    try t.expectEqual(0, plain.position());
    try t.expect(plain.skipAscii(16));
    try t.expect(!plain.skipAscii(1));
    try t.expectEqual(16, plain.position());
    try t.expectEqual(.failure, std.meta.activeTag(plain.step()));
    var normalized = try markup.LogicalReader(.utf8).init(.{ .bytes = &@as([15]u8, @splat('a')) ++ "\t", .origin = 0 }, .{ .normalize_attribute_whitespace = true });
    try t.expect(!normalized.skipAscii(16));
    try t.expectEqual(0, normalized.position());
    var quoted = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"" ++ &@as([15]u8, @splat('a')) ++ "\\n\"", .origin = 0 });
    _ = quoted.step(); // opening delimiter
    try t.expect(!quoted.skipAscii(16));
    try t.expectEqual(1, quoted.position());
}

test "logical batches and scalar readers agree around every block boundary" {
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = &@as([96]u8, @splat('a')), .severity = .err } },
    } });
    var source: [98]u8 = @splat('a');
    source[0] = '"';
    source[97] = '"';
    for (0..96) |index| {
        for ([_]u8{ 0, '"', '\\', '&', '\t', '\r', 0xc3, 0xff }) |byte| {
            source[index + 1] = byte;
            try compareBatches(P, try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = &source, .origin = 11 }), .{}, 31);
            try compareBatches(P, try markup.LogicalReader(.utf8).init(.{ .bytes = source[1..97], .origin = 11 }, .{ .malformed_reference = .accept, .normalize_attribute_whitespace = true }), .{}, 31);
            source[index + 1] = 'a';
        }
    }
}

test "logical budgets, moving sessions, runtime overrides, and folding agree" {
    const P = s.Profile(.{ .runtime_policy = true, .unicode_case_folding = true, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = "STRASSE😀", .severity = .err } },
    } });
    const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "Stra&#223;e&#x1f600;", .origin = 35 }, .{});
    try partition(P, reader, .{ .policy = .{ .comparison = .case_insensitive } });
    try t.expect((try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, P.Sink.discard, .{ .policy = .{ .comparison = .case_insensitive } })).valid());
    try partition(P, reader, .{}); // ordinary case-sensitive mismatch
    try partition(P, reader, .{ .policy = .{ .comparison = .ascii_case_insensitive } });
    const long = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"STR\" + /*" ++ &@as([800]u8, @splat('x')) ++ "*/ \"ASSE😀\"", .origin = 11 });
    try partition(P, long, .{});
    const replay = try markup.LogicalReader(.utf8).init(.{ .bytes = "x&" ++ &@as([800]u8, @splat('a')) ++ " z", .origin = 5 }, .{ .malformed_reference = .accept });
    try partition(P, replay, .{});
    const Empty = s.Profile(.{ .runtime_policy = true, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .equals = .{ .expected = "", .severity = .err }, .one_of = .{ .values = &.{}, .severity = .warning } } } });
    try partition(Empty, try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"\" + \"\"", .origin = 0 }), .{});
}

test "native logical findings retain physical offsets" {
    const P = s.Profile(.{ .runtime_policy = true, .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = "B", .severity = .warning } },
    } });
    inline for (comptime .{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var bytes: [24]u8 = @splat(0);
        for ("&#65;", 0..) |byte, i| {
            const index = i * E.width + if (actual == .utf16be or actual == .utf32be) E.width - 1 else 0;
            bytes[index] = byte;
        }
        const reader = try markup.LogicalReader(actual).init(.{ .bytes = bytes[0 .. 5 * E.width], .origin = 15 }, .{});
        try partition(P, reader, .{});
        var bag: P.FixedDiagnosticBag(2) = .{};
        const result = try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, bag.sink(), .{});
        try t.expect(result.valid()); // warning doesn't reject
        try t.expectEqualDeep(s.Span{ .start = 15, .len = 5 * E.width }, bag.items()[0].span);
    }
}

const NoAmpersands = struct {
    pub const Settings = void;
    pub const defaults = {};
    pub const uses_comparison = false;
    pub const Detail = enum { ampersand };
    pub fn State(comptime Context: type) type {
        return struct { cursor: Context.Cursor = .{}, previous: ?s.logical.SourceLocation = null };
    }
    pub fn step(state: anytype, value: anytype, _: Settings, context: anytype) s.Step {
        return switch (context.readStep(&state.cursor, value)) {
            .pending => .pending,
            .stopped => .stopped,
            .end => .passed, // detailed reports survive even a passed outcome
            .scalar => |item| blk: {
                if (item.codepoint == '&') {
                    if (!context.report(.{ .at = item.location, .related_at = state.previous, .detail = .ampersand })) break :blk .stopped;
                }
                state.previous = item.location;
                break :blk .pending;
            },
        };
    }
};

test "one custom contract works for standalone, plain, DOT and markup readers" {
    const P = s.Profile(.{ .custom = NoAmpersands, .runtime_policy = true, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "A&amp;B&#38;", .origin = 109 }, .{});
    try partition(P, reader, .{});
    try partition(P, try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"A\" + \"&\"", .origin = 109 }), .{});
    try partition(P, try s.LogicalReader(.utf8).init(.{ .bytes = "A&B&", .origin = 109 }), .{});
    var bag: P.FixedDiagnosticBag(4) = .{};
    const result = try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, bag.sink(), .{});
    try t.expectEqual(@as(u64, 2), result.errors);
    try t.expectEqualDeep(s.Span{ .start = 110, .len = 5 }, bag.items()[0].span);
    try t.expectEqualDeep(s.Span{ .start = 109, .len = 1 }, bag.items()[0].related.?);
    try t.expectEqualDeep(s.Span{ .start = 116, .len = 5 }, bag.items()[1].span);
    bag = .{};
    const raw = try P.parseAndValidate(.{ .bytes = "A&B&", .origin = 109 }, bag.sink(), .{});
    try t.expectEqual(@as(u64, 2), raw.errors);
    try t.expectEqualDeep(s.Span{ .start = 110, .len = 1 }, bag.items()[0].span);
    var ordinary = try P.Session.init(.{ .bytes = "A&B&", .origin = 109 }, P.Sink.discard, .{});
    while ((try ordinary.advance(1)).outcome == null) {}
    try t.expectEqualDeep(raw, ordinary.result().?);
}

test "custom batches use the same portable value contract as custom steps" {
    const Match = struct {
        pub const Settings = struct { expected: []const u8 = "", batches: ?*usize = null };
        pub const defaults: Settings = .{};
        pub const uses_comparison = true;
        pub const State = s.validators.Equals.State;
        pub fn step(state: anytype, value: anytype, settings: Settings, context: anytype) s.Step {
            return context.equalsStep(&state.comparison, value, settings.expected);
        }
        pub fn batch(state: anytype, value: anytype, settings: Settings, context: anytype, allowance: u32) u32 {
            // No value.bytes assumption: this also receives LogicalValue.
            const used = context.equalsBatch(&state.comparison, value, settings.expected, allowance);
            if (used != 0) if (settings.batches) |count| {
                count.* += 1;
            };
            return used;
        }
    };
    const P = s.Profile(.{ .runtime_policy = true, .custom = Match, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    const text = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    inline for (.{ .standalone, .plain, .dot, .markup }) |host| {
        const input = switch (host) {
            .standalone => try s.Fragment.init(text, 23),
            .plain => try s.LogicalReader(.utf8).init(try s.Fragment.init(text, 23)),
            .dot => try dot.identifier.LogicalReader(.utf8).init(try s.Fragment.init("\"" ++ text ++ "\"", 23)),
            .markup => try markup.LogicalReader(.utf8).init(try s.Fragment.init(text, 23), .{}),
            else => unreachable,
        };
        const Bound = if (host == .standalone) P else P.WithReader(@TypeOf(input));
        var expected_work: ?u64 = null;
        for ([_]u32{ 1, 4096 }) |budget| {
            var batches: usize = 0;
            var session = try Bound.Session.init(input, P.Sink.discard, .{ .policy = .{ .custom = .{ .expected = text, .batches = &batches } } });
            defer session.deinit();
            var total: u64 = 0;
            while (session.result() == null) {
                const progress = try session.advance(budget);
                try t.expect(progress.work_used <= budget);
                total += progress.work_used;
            }
            try t.expect(session.result().?.valid());
            if (budget == 1) try t.expectEqual(@as(usize, 0), batches) else try t.expect(batches > 0);
            if (expected_work) |work| try t.expectEqual(work, total);
            expected_work = total;
        }
    }
}

test "reader prerequisites fail truthfully without inventing duplicate host errors" {
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{ .execution = .{ .metering = true }, .validation = .{
        .equals = .{ .expected = "wrong", .severity = .err },
        .one_of = .{ .values = &.{}, .severity = .err },
    } } });
    for ([_][]const u8{ "x&bogus;", "x&amp", "x\xff" }, [_]@FieldType(s.logical.Failure, "reason"){ .unresolved_reference, .invalid_syntax, .invalid_encoding }) |text, reason| {
        const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = text, .origin = 20 }, .{});
        try partition(P, reader, .{});
        var bag: P.FixedDiagnosticBag(4) = .{};
        const result = try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, bag.sink(), .{});
        try t.expectEqual(.input_unavailable, result.completion);
        try t.expectEqual(reason, result.input_failure.?.reason);
        try t.expectEqual(@as(u32, 21), result.input_failure.?.location.span.start);
        try t.expectEqual(.unavailable, result.checks.equals);
        try t.expectEqual(.unavailable, result.checks.one_of);
        try t.expectEqual(.incomplete, result.checks.encoding);
        try t.expect(!result.valid());
        try t.expectEqual(@as(usize, 0), bag.items().len);
    }
    const reader = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"x\" + <B/>", .origin = 0 });
    const result = try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, P.Sink.discard, .{});
    try t.expectEqual(.unsupported_form, result.input_failure.?.reason);
}

test "invalid custom coordinates and raw host edits are contract failures" {
    const Bad = struct {
        pub const Settings = enum { before, after, overflow, segment, ambiguous, raw, fix, related };
        pub const defaults: Settings = .before;
        pub const uses_comparison = false;
        pub fn State(comptime _: type) type {
            return struct {};
        }
        pub fn step(_: anytype, value: anytype, mode: Settings, ctx: anytype) s.Step {
            var loc = value.location();
            switch (mode) {
                .before => loc.span.start -= 1,
                .after => loc.span.len += 1,
                .overflow => {
                    loc.span.start = std.math.maxInt(u32);
                    loc.span.len = std.math.maxInt(u32);
                },
                .segment => loc.segment_start = loc.span.start + 1,
                .ambiguous => {
                    _ = ctx.report(.{ .at = loc, .span = .{ .start = 0, .len = 0 } });
                    return .stopped;
                },
                .raw => {
                    _ = ctx.report(.{ .span = .{ .start = 0, .len = 1 } });
                    return .stopped;
                },
                .fix => {
                    _ = ctx.report(.{ .at = loc, .fix = .{ .span = .{ .start = 0, .len = 1 }, .edit = .delete, .applicability = .machine_applicable } });
                    return .stopped;
                },
                .related => {
                    loc.span.len += 1;
                    _ = ctx.report(.{ .related_at = loc });
                    return .stopped;
                },
            }
            _ = ctx.report(.{ .at = loc });
            return .stopped;
        }
    };
    const P = s.Profile(.{ .custom = Bad, .runtime_policy = true, .policy = .{ .validation = .{ .custom = .err } } });
    const reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "&amp;", .origin = 5 }, .{});
    for (std.enums.values(Bad.Settings)) |mode| {
        var bag: P.FixedDiagnosticBag(2) = .{};
        const result = try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, bag.sink(), .{ .policy = .{ .custom = mode } });
        try t.expectEqual(.invalid_validator, result.completion);
        try t.expectEqual(@as(usize, 0), bag.items().len);
    }
}

test "bound fail-fast sink stops cancellation and transactional reset" {
    const P = s.Profile(.{ .custom = NoAmpersands, .runtime_policy = true, .policy = .{ .execution = .{ .metering = true, .cancellation = true }, .validation = .{ .custom = .err } } });
    const R = markup.LogicalReader(.utf8);
    const B = P.WithReader(R);
    const reader = try R.init(.{ .bytes = "&amp;&amp;", .origin = 0 }, .{});
    try t.expectEqual(.fail_fast, (try B.parseAndValidate(reader, P.Sink.discard, .{ .policy = .{ .on_error = .fail_fast } })).completion);
    var bag: P.FixedDiagnosticBag(1) = .{};
    const result = try B.parseAndValidate(reader, bag.sink(), .{});
    try t.expectEqual(.requested, result.completion.diagnostic_stop);
    try t.expectEqual(@as(u64, 1), result.errors);
    const Hook = struct {
        calls: u32 = 0,
        stop: bool = false,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.stop;
        }
    };
    var hook: Hook = .{};
    var session = try B.Session.init(try R.init(.{ .bytes = "&#" ++ &@as([200]u8, @splat('0')) ++ "65;", .origin = 0 }, .{}), P.Sink.discard, .{ .cancellation = .{ .context = &hook, .is_requested = Hook.poll } });
    _ = try session.advance(10);
    try t.expectEqual(@as(u32, 10), hook.calls);
    try t.expectError(error.InvalidCancellationInterval, session.reset(reader, P.Sink.discard, .{ .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
    hook.stop = true;
    const stopped = try session.advance(0);
    try t.expectEqual(.cancelled, stopped.outcome.?);
    try t.expectEqual(@as(u32, 0), stopped.work_used);
    try t.expectEqual(@as(u32, 10), stopped.source_frontier);
    const calls = hook.calls;
    _ = session.run();
    try t.expectEqual(calls, hook.calls);
    try session.reset(reader, P.Sink.discard, .{ .policy = .{ .execution = .{ .metering = false } } });
    try t.expectError(error.MeteringDisabled, session.advance(1));
    try t.expectEqual(@as(u64, 2), session.run().errors);
}

test "bound readers restart even when supplied after traversal" {
    const P = s.Profile(.{ .custom = s.validators.Equals, .policy = .{ .custom = "A&B", .validation = .{ .custom = .err } } });
    var reader = try markup.LogicalReader(.utf8).init(.{ .bytes = "A&amp;B", .origin = 8 }, .{});
    _ = reader.step();
    try t.expect((try P.WithReader(@TypeOf(reader)).parseAndValidate(reader, P.Sink.discard, .{})).valid());
}

test "synchronous portable comparison and borrowed fast paths" {
    const Custom = struct {
        pub const Settings = []const u8;
        pub const defaults: Settings = "A&B";
        pub const uses_comparison = true;
        pub fn check(value: anytype, expected: Settings, ctx: anytype) s.Outcome {
            _ = value.contiguous();
            return if (ctx.equals(value, expected) orelse return .stopped) .passed else .failed;
        }
    };
    const P = s.Profile(.{ .custom = Custom, .policy = .{ .validation = .{ .custom = .err } } });
    const R = markup.LogicalReader(.utf8);
    const result = try P.WithReader(R).parseAndValidate(try R.init(.{ .bytes = "A&amp;B", .origin = 0 }, .{}), P.Sink.discard, .{});
    try t.expect(result.valid());
    try t.expect((try P.parseAndValidate(.{ .bytes = "A&B", .origin = 0 }, P.Sink.discard, .{})).valid());
}

test "one bounded read per custom step is enforced" {
    const Bad = struct {
        pub const Settings = void;
        pub const defaults = {};
        pub const uses_comparison = false;
        pub fn State(comptime Context: type) type {
            return struct { cursor: Context.Cursor = .{} };
        }
        pub fn step(state: anytype, value: anytype, _: Settings, ctx: anytype) s.Step {
            _ = ctx.readStep(&state.cursor, value);
            _ = ctx.readStep(&state.cursor, value);
            return .passed;
        }
    };
    const P = s.Profile(.{ .custom = Bad, .policy = .{ .execution = .{ .metering = true }, .validation = .{ .custom = .err } } });
    const R = dot.identifier.LogicalReader(.utf8);
    const result = try P.WithReader(R).parseAndValidate(try R.init(.{ .bytes = "\"abc\"", .origin = 0 }), P.Sink.discard, .{});
    try t.expectEqual(.invalid_validator, result.completion);
    try t.expectEqual(.invalid_validator, (try P.parseAndValidate(.{ .bytes = "abc", .origin = 0 }, P.Sink.discard, .{})).completion);
}

test "generated entity streams match standalone comparison results" {
    const P = s.Profile(.{ .runtime_policy = true, .unicode_case_folding = true, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = "", .severity = .err } },
    } });
    const R = markup.LogicalReader(.utf8);
    const B = P.WithReader(R);
    var random = std.Random.DefaultPrng.init(72641);
    const pieces = [_][]const u8{ "A", "a", "ß", "ſ", "ﬃ", "&", "😀", "中", "" };
    const spellings = [_][]const u8{ "&#65;", "a", "&#xDF;", "&#383;", "&#64259;", "&amp;", "&#128512;", "中", "" };
    for (0..300) |_| {
        var plain: std.Io.Writer.Allocating = .init(t.allocator);
        defer plain.deinit();
        var encoded: std.Io.Writer.Allocating = .init(t.allocator);
        defer encoded.deinit();
        var expected: std.Io.Writer.Allocating = .init(t.allocator);
        defer expected.deinit();
        for (0..random.random().uintLessThan(u8, 12)) |_| {
            const index = random.random().uintLessThan(usize, pieces.len);
            try plain.writer.writeAll(pieces[index]);
            try encoded.writer.writeAll(spellings[index]);
            const match = random.random().boolean();
            try expected.writer.writeAll(pieces[if (match) index else random.random().uintLessThan(usize, pieces.len)]);
        }
        for ([_]s.Comparison{ .case_sensitive, .ascii_case_insensitive, .case_insensitive }) |comparison| {
            const options: P.Options = .{ .policy = .{ .comparison = comparison, .validation = .{ .equals = .{ .expected = expected.written(), .severity = .err } } } };
            const raw = try P.parseAndValidate(.{ .bytes = plain.written(), .origin = 17 }, P.Sink.discard, options);
            const bound = try B.parseAndValidate(try R.init(.{ .bytes = encoded.written(), .origin = 17 }, .{}), P.Sink.discard, options);
            try t.expectEqual(raw.valid(), bound.valid());
            try t.expectEqual(raw.errors, bound.errors);
            try t.expectEqualDeep(raw.checks, bound.checks);
        }
    }
}

test "native custom locations include entire reference and surrogate pair" {
    const P = s.Profile(.{ .custom = NoAmpersands, .source_encodings = &.{ .utf16, .utf32 }, .policy = .{ .validation = .{ .custom = .err } } });
    inline for (comptime .{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var bytes: [20]u8 = @splat(0);
        for ("&amp;", 0..) |byte, i| bytes[i * E.width + if (actual == .utf16be or actual == .utf32be) E.width - 1 else 0] = byte;
        const R = markup.LogicalReader(actual);
        var bag: P.FixedDiagnosticBag(2) = .{};
        const result = try P.WithReader(R).parseAndValidate(try R.init(.{ .bytes = bytes[0 .. 5 * E.width], .origin = 107 }, .{}), bag.sink(), .{});
        try t.expectEqual(@as(u64, 1), result.errors);
        try t.expectEqualDeep(s.Span{ .start = 107, .len = 5 * E.width }, bag.items()[0].span);
    }
    const Emoji = s.Profile(.{ .source_encodings = &.{.utf16}, .policy = .{ .validation = .{ .equals = .{ .expected = "😀", .severity = .err } } } });
    const R = dot.identifier.LogicalReader(.utf16le);
    try t.expect((try Emoji.WithReader(R).parseAndValidate(try R.init(.{ .bytes = "\"\x00\x3d\xd8\x00\xde\"\x00", .origin = 3 }), Emoji.Sink.discard, .{})).valid());
}

test "host catalog and normalization options survive binding and resetting" {
    const P = s.Profile(.{ .policy = .{ .validation = .{ .equals = .{ .expected = " \u{a0}\t", .severity = .err } } } });
    const R = markup.LogicalReader(.utf8);
    const reader = try R.init(.{ .bytes = "\t&nbsp;&#9;", .origin = 0 }, .{ .references = .graphviz, .normalize_attribute_whitespace = true });
    var session = try P.WithReader(R).Session.init(reader, P.Sink.discard, .{});
    try t.expect(session.run().valid());
    try session.reset(reader, P.Sink.discard, .{});
    try t.expect(session.run().valid());
    try t.expectError(error.UnsupportedEncoding, session.reset(reader, P.Sink.discard, .{ .encoding = .utf16le }));
    try t.expect(session.result().?.valid());
}

test "comparison stops while still inside reference spelling" {
    const P = s.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true }, .validation = .{ .equals = .{ .expected = "A", .severity = .err } } } });
    const R = markup.LogicalReader(.utf8);
    const Hook = struct {
        calls: u32 = 0,
        stop: bool = false,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.stop;
        }
    };
    var hook: Hook = .{};
    var session = try P.WithReader(R).Session.init(try R.init(.{ .bytes = "&#" ++ &@as([200]u8, @splat('0')) ++ "65;", .origin = 0 }, .{}), P.Sink.discard, .{ .cancellation = .{ .context = &hook, .is_requested = Hook.poll } });
    while (session.advance(1).stage == .encoding) {}
    const before = hook.calls;
    try t.expectEqual(null, session.advance(10).outcome); // pattern + prefix of reference
    try t.expectEqual(before + 10, hook.calls);
    hook.stop = true;
    const progress = session.advance(100);
    try t.expectEqual(@as(u32, 0), progress.work_used);
    try t.expectEqual(.cancelled, session.result().?.completion);
    try t.expectEqual(.incomplete, session.result().?.checks.equals);
}
