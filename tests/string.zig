const std = @import("std");
const s = @import("string_processor");
const testing = std.testing;
test {
    _ = @import("string_sessions.zig");
}

test "consumer string views expose checked local spans" {
    const value: s.Value(.utf8) = .{ .bytes = "abc", .origin = 90 };
    try testing.expectEqual(@as(u32, 0), (try value.span()).start);
    try testing.expectEqual(@as(u32, 3), (try value.span()).len);
}
test "borrowed exact and membership use all checks, warning does not reject" {
    const P = s.Profile(.{ .policy = .{ .validation = .{
        .equals = .{ .expected = "SF", .severity = .warning },
        .one_of = .{ .values = &.{ "SF", "Seattle" }, .severity = .err },
    } } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    const result = try P.parseAndValidate(.{ .bytes = "Seattle", .origin = 13 }, bag.sink(), .{});
    try testing.expect(result.valid());
    try testing.expectEqual(@as(u64, 1), result.warnings);
    try testing.expectEqual(@as(u32, 13), bag.items()[0].span.start);
    try testing.expectEqual(.complete, result.checks.one_of);
}
test "Unicode full folding is optional, expanding, and not normalization" {
    const P = s.Profile(.{ .unicode_case_folding = true, .runtime_policy = true });
    for ([_]struct { a: []const u8, b: []const u8, equal: bool }{
        .{ .a = "Straße", .b = "STRASSE", .equal = true },
        .{ .a = "Σςσ", .b = "σσσ", .equal = true },
        .{ .a = "İ", .b = "i\u{307}", .equal = true },
        .{ .a = "ﬃ", .b = "FFI", .equal = true },
        .{ .a = "é", .b = "e\u{301}", .equal = false },
        .{ .a = "I", .b = "ı", .equal = false },
        .{ .a = "中文", .b = "中文", .equal = true },
        .{ .a = "ellipſe", .b = "ellipse", .equal = true },
    }) |case| {
        const result = try P.parseAndValidate(.{ .bytes = case.a, .origin = 0 }, P.Sink.discard, .{ .policy = .{
            .comparison = .case_insensitive,
            .validation = .{ .equals = .{ .expected = case.b, .severity = .err } },
        } });
        try testing.expectEqual(case.equal, result.valid());
    }
}

test "ASCII folding is opt-in, table-free and independently overridden per check" {
    const Exact = s.Profile(.{ .policy = .{ .validation = .{ .equals = .{ .expected = "Seattle", .severity = .err } } } });
    try testing.expectEqual(.case_sensitive, Exact.Policies.baseline.comparison);
    try testing.expect(!(try Exact.parseAndValidate(.{ .bytes = "SEATTLE", .origin = 0 }, Exact.Sink.discard, .{})).valid());
    const P = s.Profile(.{ .custom = s.validators.Equals, .policy = .{
        .comparison = .ascii_case_insensitive,
        .custom = "Seattle",
        .validation = .{
            .equals = .{ .expected = "Seattle", .severity = .err },
            .one_of = .{ .values = &.{"Seattle"}, .comparison = .case_sensitive, .severity = .warning },
            .custom = .err,
        },
    } });
    const result = try P.parseAndValidate(.{ .bytes = "SEATTLE", .origin = 17 }, P.Sink.discard, .{});
    try testing.expect(result.valid());
    try testing.expectEqual(@as(u64, 1), result.warnings);
    try testing.expectEqual(.complete, result.checks.custom);

    const Runtime = s.Profile(.{ .runtime_policy = true });
    try testing.expectEqual(.valid, Runtime.validatePolicy(.{ .comparison = .ascii_case_insensitive }));
    try testing.expectEqual(.unicode_folding_disabled, Runtime.validatePolicy(.{ .comparison = .case_insensitive }).invalid);
    try testing.expectError(error.UnicodeFoldingDisabled, Runtime.Session.init(.{ .bytes = "Seattle", .origin = 0 }, Runtime.Sink.discard, .{ .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .equals = .{ .expected = "Seattle", .comparison = .case_insensitive, .severity = .err } },
    } }));
    const PerCheck = s.Profile(.{ .policy = .{ .validation = .{
        .equals = .{ .expected = "Seattle", .comparison = .ascii_case_insensitive, .severity = .err },
    } } });
    try testing.expect((try PerCheck.parseAndValidate(.{ .bytes = "SEATTLE", .origin = 0 }, PerCheck.Sink.discard, .{})).valid());
    const Both = s.Profile(.{ .unicode_case_folding = true, .policy = .{
        .comparison = .case_insensitive,
        .validation = .{
            .equals = .{ .expected = "ellipse", .severity = .err },
            .one_of = .{ .values = &.{"ellipse"}, .comparison = .ascii_case_insensitive, .severity = .warning },
        },
    } });
    const distinct = try Both.parseAndValidate(.{ .bytes = "ellipſe", .origin = 0 }, Both.Sink.discard, .{});
    try testing.expect(distinct.valid());
    try testing.expectEqual(@as(u64, 1), distinct.warnings);
}

test "ASCII comparison leaves non-ASCII and punctuation unchanged in every encoding and execution path" {
    const P = s.Profile(.{ .runtime_policy = true, .custom = s.validators.Equals, .source_encodings = &.{ .ascii, .utf8, .utf16, .utf32 } });
    const cases = [_]struct { text: []const u8, pattern: []const u8, equal: bool }{
        .{ .text = "", .pattern = "", .equal = true },
        .{ .text = "TrUe", .pattern = "true", .equal = true },
        .{ .text = "aZ[\\]^_`\x00", .pattern = "Az[\\]^_`\x00", .equal = true },
        .{ .text = "@" ** 32, .pattern = "`" ** 32, .equal = false },
        .{ .text = "[\\]^" ** 16, .pattern = "{|}~" ** 16, .equal = false },
        .{ .text = "AaZz" ** 32, .pattern = "aAzZ" ** 32, .equal = true },
        .{ .text = "AZ" ** 32 ++ "!", .pattern = "az" ** 32 ++ "?", .equal = false },
        .{ .text = "AZ" ** 32, .pattern = "az" ** 32 ++ "!", .equal = false },
        .{ .text = "éAz😀中文", .pattern = "éaZ😀中文", .equal = true },
        .{ .text = "\u{10ffff}\x00AZ", .pattern = "\u{10ffff}\x00az", .equal = true },
        .{ .text = "\u{10ffff}", .pattern = "", .equal = false },
        .{ .text = "ellipſe", .pattern = "ellipse", .equal = false },
        .{ .text = "Straße", .pattern = "STRASSE", .equal = false },
        .{ .text = "É", .pattern = "é", .equal = false },
        .{ .text = "K", .pattern = "k", .equal = false },
        .{ .text = "İ", .pattern = "i\u{307}", .equal = false },
        .{ .text = "Σ", .pattern = "σ", .equal = false },
    };
    inline for (.{ s.ActualEncoding.ascii, .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        case_loop: for (cases) |case| {
            if (actual == .ascii) {
                for (case.text) |byte| if (!std.ascii.isAscii(byte)) continue :case_loop;
            }
            var buffer: [1024]u8 = undefined;
            const input: s.Fragment = .{ .bytes = encoded(actual, case.text, &buffer), .origin = 17 };
            const values = [_][]const u8{ "not a match", case.pattern };
            const policy: P.Policy = .{
                .comparison = .ascii_case_insensitive,
                .validation = .{
                    .equals = .{ .expected = case.pattern, .severity = .warning },
                    .one_of = .{ .values = &values, .severity = .err },
                    .custom = .warning,
                },
                .custom = case.pattern,
            };
            var bag: P.FixedDiagnosticBag(8) = .{};
            const expected = try P.parseAndValidate(input, bag.sink(), .{ .encoding = actual, .policy = policy });
            try testing.expectEqual(case.equal, expected.valid());
            if (!case.equal) {
                try testing.expectEqual(@as(u64, 1), expected.errors);
                try testing.expectEqual(@as(u64, 2), expected.warnings);
                for (bag.items()) |d| try testing.expectEqual(s.Span{ .start = 17, .len = @intCast(input.bytes.len) }, d.span);
            }
            var credits: ?u32 = null;
            for ([_]u32{ 1, 2, 15, 16, 17, 64, 4096 }) |budget| {
                var stepped_bag: P.FixedDiagnosticBag(8) = .{};
                var patch = policy;
                patch.execution.metering = true;
                var session = try P.Session.init(input, stepped_bag.sink(), .{ .encoding = actual, .policy = patch });
                defer session.deinit();
                var total: u32 = 0;
                while (true) {
                    const progress = try session.advance(budget);
                    try testing.expect(progress.work_used <= budget);
                    total += progress.work_used;
                    try testing.expect(total < 5000);
                    if (progress.outcome != null) break;
                }
                if (credits) |n| try testing.expectEqual(n, total) else credits = total;
                try testing.expectEqualDeep(expected, session.result().?);
                try testing.expectEqualSlices(P.Diagnostic, bag.items(), stepped_bag.items());
            }
            var cancel_policy = policy;
            cancel_policy.execution.cancellation = true;
            try testing.expectEqualDeep(expected, try P.parseAndValidate(input, P.Sink.discard, .{ .encoding = actual, .policy = cancel_policy }));
        }
    }
}

test "fixed native metered custom-only ASCII comparisons need no Unicode capability" {
    const P = s.Profile(.{ .custom = s.validators.Equals, .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{
        .comparison = .ascii_case_insensitive,
        .execution = .{ .metering = true },
        .custom = "TRUEé😀",
        .validation = .{ .custom = .err },
    } });
    inline for (.{ s.ActualEncoding.utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var buffer: [64]u8 = undefined;
        var session = try P.Session.init(.{ .bytes = encoded(actual, "trueé😀", &buffer), .origin = 13 }, P.Sink.discard, .{ .encoding = actual });
        defer session.deinit();
        while (session.advance(1).outcome == null) {}
        try testing.expect(session.result().?.valid());
        try testing.expectEqual(.complete, session.result().?.checks.custom);
    }
}

test "contents stay literal, borrowed, and include BOM characters" {
    const P = s.Profile(.{ .runtime_policy = true });
    inline for (.{ "", "\"SF\"", "&amp;", "\\n", "\xef\xbb\xbfabc", "\x00" }) |text| {
        const r = try P.parseAndValidate(.{ .bytes = text, .origin = 4 }, P.Sink.discard, .{
            .policy = .{ .validation = .{ .equals = .{ .expected = text, .severity = .err } } },
        });
        try testing.expect(r.valid());
    }
    var input = [_]u8{ 'S', 'F' };
    const r = try s.parseAndValidate(.{ .bytes = &input, .origin = 0 }, s.Sink.discard, .{});
    try testing.expect(r.valid());
    try testing.expectEqualStrings("SF", &input);
    try testing.expectEqual(.disabled, r.checks.equals);
}

test "fixed and runtime policies, per-check overrides, no unavailable capability fallback" {
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{ .equals = .{ .expected = "SF", .severity = .err } } } });
    try testing.expectEqual(.valid, P.validatePolicy(.{}));
    try testing.expectEqual(.unicode_folding_disabled, P.validatePolicy(.{ .comparison = .case_insensitive }).invalid);
    try testing.expectEqual(.invalid_pattern_encoding, P.validatePolicy(.{ .validation = .{ .equals = .{ .expected = "\xff", .severity = .err } } }).invalid);
    try testing.expectEqual(.custom_validator_required, P.validatePolicy(.{ .validation = .{ .custom = .err } }).invalid);
    try testing.expectError(error.CustomValidatorRequired, P.parseAndValidate(.{ .bytes = "SF", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .validation = .{ .custom = .err } } }));
    try testing.expectError(error.UnicodeFoldingDisabled, P.parseAndValidate(.{ .bytes = "SF", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .comparison = .case_insensitive } }));
    const inherited = try P.parseAndValidate(.{ .bytes = "SF", .origin = 0 }, P.Sink.discard, .{});
    try testing.expect(inherited.valid());
    const off = try P.parseAndValidate(.{ .bytes = "other", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .validation = .{ .equals = .{ .severity = .off } } } });
    try testing.expectEqual(.disabled, off.checks.equals);
    try testing.expect(off.valid());
    const Q = s.Profile(.{ .unicode_case_folding = true, .policy = .{
        .comparison = .case_insensitive,
        .validation = .{
            .equals = .{ .expected = "SF", .severity = .err },
            .one_of = .{ .values = &.{"SF"}, .severity = .warning, .comparison = .case_sensitive },
        },
    } });
    const r = try Q.parseAndValidate(.{ .bytes = "sf", .origin = 0 }, Q.Sink.discard, .{});
    try testing.expect(r.valid());
    try testing.expectEqual(@as(u64, 1), r.warnings);
}

test "collect, fail-fast, empty membership and discard preserve factual validity" {
    const P = s.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{
        .equals = .{ .expected = "SF", .severity = .err },
        .one_of = .{ .values = &.{}, .severity = .err },
    } } });
    const a = try P.parseAndValidate(.{ .bytes = "Seattle", .origin = 0 }, P.Sink.discard, .{});
    try testing.expectEqual(@as(u64, 2), a.errors);
    try testing.expectEqual(.complete, a.completion);
    try testing.expect(!a.valid());
    const b = try P.parseAndValidate(.{ .bytes = "Seattle", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .on_error = .fail_fast } });
    try testing.expectEqual(@as(u64, 1), b.errors);
    try testing.expectEqual(.fail_fast, b.completion);
    try testing.expectEqual(.not_run, b.checks.one_of);
}

fn encoded(comptime actual: s.ActualEncoding, source: []const u8, buffer: []u8) []const u8 {
    var cursor = s.Value(.utf8){ .bytes = source, .origin = 0 };
    var it = cursor.cursor();
    var at: usize = 0;
    while (it.next() catch unreachable) |cp| {
        switch (actual) {
            .ascii, .utf8 => {
                const len = std.unicode.utf8Encode(cp, buffer[at..][0..4]) catch unreachable;
                at += len;
            },
            .utf16le, .utf16be => {
                const endian: std.builtin.Endian = if (actual == .utf16le) .little else .big;
                if (cp < 0x10000) {
                    std.mem.writeInt(u16, buffer[at..][0..2], @intCast(cp), endian);
                    at += 2;
                } else {
                    std.mem.writeInt(u16, buffer[at..][0..2], @intCast(0xd800 + ((cp - 0x10000) >> 10)), endian);
                    std.mem.writeInt(u16, buffer[at + 2 ..][0..2], @intCast(0xdc00 + ((cp - 0x10000) & 1023)), endian);
                    at += 4;
                }
            },
            .utf32le, .utf32be => {
                std.mem.writeInt(u32, buffer[at..][0..4], cp, if (actual == .utf32le) .little else .big);
                at += 4;
            },
        }
    }
    return buffer[0..at];
}

test "all compiled native readers compare logical scalars without transcoding" {
    const P = s.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .unicode_case_folding = true, .runtime_policy = true });
    inline for (.{ s.ActualEncoding.utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        var buffer: [128]u8 = undefined;
        const text = encoded(actual, "Straße 😀 中文", &buffer);
        const r = try P.parseAndValidate(.{ .bytes = text, .origin = 17 }, P.Sink.discard, .{ .encoding = actual, .policy = .{
            .validation = .{ .equals = .{ .expected = "STRASSE 😀 中文", .comparison = .case_insensitive, .severity = .err } },
        } });
        try testing.expect(r.valid());
        const exact = try P.parseAndValidate(.{ .bytes = text, .origin = 17 }, P.Sink.discard, .{ .encoding = actual, .policy = .{
            .validation = .{ .equals = .{ .expected = "Straße 😀 中文", .severity = .err } },
        } });
        try testing.expect(exact.valid());
    }
    const Only = s.Profile(.{ .source_encodings = &.{.utf32} });
    try testing.expectError(error.EncodingRequired, Only.parseAndValidate(.{ .bytes = "", .origin = 0 }, Only.Sink.discard, .{}));
    try testing.expectError(error.UnsupportedEncoding, s.parseAndValidate(.{ .bytes = "", .origin = 0 }, s.Sink.discard, .{ .encoding = .utf32be }));
    const Ascii = s.Profile(.{ .source_encodings = &.{} });
    const r = try Ascii.parseAndValidate(.{ .bytes = "café", .origin = 0 }, Ascii.Sink.discard, .{});
    try testing.expect(!r.valid());
    try testing.expectEqual(@as(u64, 1), r.errors);
}

test "malformed runs, truncations and early mismatch never hide encoding failures" {
    const P = s.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .validation = .{ .equals = .{ .expected = "z", .severity = .err } } } });
    for ([_]struct { text: []const u8, actual: s.ActualEncoding, start: u32, len: u32 }{
        .{ .text = "abc\xff\xff", .actual = .utf8, .start = 3, .len = 2 },
        .{ .text = "a\xed\xa0\x80", .actual = .utf8, .start = 1, .len = 3 },
        .{ .text = "\x00\xd8x\x00", .actual = .utf16le, .start = 0, .len = 2 },
        .{ .text = "\x00\x61\x00", .actual = .utf16be, .start = 2, .len = 1 },
        .{ .text = "\x00\x00\x11\x00", .actual = .utf32le, .start = 0, .len = 4 },
        .{ .text = "\x00\x00\x00", .actual = .utf32be, .start = 0, .len = 3 },
    }) |case| {
        var bag: P.FixedDiagnosticBag(8) = .{};
        const r = try P.parseAndValidate(.{ .bytes = case.text, .origin = 10 }, bag.sink(), .{ .encoding = case.actual });
        try testing.expect(!r.valid());
        try testing.expectEqual(.complete, r.completion);
        try testing.expectEqual(.unavailable, r.checks.equals);
        try testing.expectEqual(@as(usize, 1), bag.items().len);
        try testing.expectEqual(s.Span{ .start = 10 + case.start, .len = case.len }, bag.items()[0].span);
    }
    try testing.expectError(error.InvalidFragment, s.parseAndValidate(.{ .bytes = "a", .origin = std.math.maxInt(u32) }, s.Sink.discard, .{}));
}

const Detailed = struct {
    pub const Settings = struct { multiple: bool = false, bad_span: bool = false, bad_related: bool = false, bad_fix: bool = false };
    pub const defaults: Settings = .{};
    pub const uses_comparison = false;
    pub const Detail = enum { missing_prefix, missing_suffix };
    pub fn check(_: anytype, settings: Settings, ctx: anytype) s.Outcome {
        if (!ctx.report(.{
            .span = if (settings.bad_span) .{ .start = 100, .len = 1 } else .{ .start = 0, .len = 1 },
            .related = .{ .start = if (settings.bad_related) 200 else 1, .len = 1 },
            .detail = .missing_prefix,
            .fix = .{ .span = .{ .start = if (settings.bad_fix) 300 else 0, .len = 0 }, .edit = .{ .insert_before = .{ .bytes = "A" } }, .applicability = .maybe },
        })) return .stopped;
        if (settings.multiple and !ctx.report(.{ .detail = .missing_suffix })) return .stopped;
        return .failed;
    }
    pub fn message(detail: Detail, writer: anytype) !void {
        try writer.writeAll(@tagName(detail));
    }
    pub fn hint(_: Detail, writer: anytype) !void {
        try writer.writeAll("use the required prefix or suffix");
    }
};

test "custom structured findings share severity, remap spans/fixes and do not duplicate generic failure" {
    const P = s.Profile(.{ .custom = Detailed, .runtime_policy = true, .policy = .{ .validation = .{ .custom = .warning }, .custom = .{ .multiple = true } } });
    var bag: P.FixedDiagnosticBag(8) = .{};
    const r = try P.parseAndValidate(.{ .bytes = "xx", .origin = 5 }, bag.sink(), .{});
    try testing.expect(r.valid());
    try testing.expectEqual(@as(u64, 2), r.warnings);
    try testing.expectEqual(@as(usize, 2), bag.items().len);
    try testing.expectEqual(@as(u32, 5), bag.items()[0].span.start);
    try testing.expectEqual(@as(u32, 6), bag.items()[0].related.?.start);
    try testing.expectEqual(@as(u32, 5), bag.items()[0].fix.?.span.start);
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try P.console.render(bag.items()[0], .{ .source = ".....xx", .source_name = "value.txt" }, &writer.writer);
    try P.console.renderBoxed(bag.items()[0], 1, .{ .source = ".....xx" }, &writer.writer);
    try testing.expect(std.mem.indexOf(u8, writer.written(), "missing_prefix") != null);
    try testing.expect(std.mem.indexOf(u8, writer.written(), "use the required prefix") != null);
    bag.reset();
    _ = try P.parseAndValidate(.{ .bytes = "xx", .origin = 0 }, bag.sink(), .{ .policy = .{ .diagnostics = .{ .fixes = .machine_applicable } } });
    try testing.expectEqual(null, bag.items()[0].fix);
    inline for (.{ "bad_span", "bad_related", "bad_fix" }) |field| {
        var settings: Detailed.Settings = .{};
        @field(settings, field) = true;
        const stopped = try P.parseAndValidate(.{ .bytes = "xx", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .custom = settings } });
        try testing.expectEqual(.invalid_validator, stopped.completion);
        try testing.expect(!stopped.valid());
    }
}

test "simple predicates and comparison participation reuse the validator contract" {
    const Predicate = s.validators.Predicate(u32, 2, struct {
        fn check(value: anytype, minimum: u32) bool {
            return value.bytes.len >= minimum;
        }
    }.check);
    const Simple = s.Profile(.{ .custom = Predicate, .policy = .{ .validation = .{ .custom = .err } } });
    var bag: Simple.FixedDiagnosticBag(2) = .{};
    const r = try Simple.parseAndValidate(.{ .bytes = "x", .origin = 9 }, bag.sink(), .{});
    try testing.expect(!r.valid());
    try testing.expectEqual(.custom_check_failed, bag.items()[0].code);
    try testing.expectEqual(@as(usize, 1), bag.items().len);
    const Shared = s.Profile(.{ .custom = s.validators.Equals, .unicode_case_folding = true, .policy = .{
        .custom = "STRASSE",
        .comparison = .case_insensitive,
        .validation = .{ .custom = .err },
    } });
    try testing.expect((try Shared.parseAndValidate(.{ .bytes = "Straße", .origin = 0 }, Shared.Sink.discard, .{})).valid());
    const Off = s.Profile(.{ .custom = struct {
        pub const Settings = void;
        pub const defaults = {};
        pub const uses_comparison = false;
        pub fn check(_: anytype, _: Settings, _: anytype) s.Outcome {
            @panic("off validator invoked");
        }
    } });
    try testing.expect((try Off.parseAndValidate(.{ .bytes = "x", .origin = 0 }, Off.Sink.discard, .{})).valid());
}

test "sink stops, capacity, allocation failure and callback failures are not valid results" {
    const P = s.Profile(.{ .policy = .{ .validation = .{ .equals = .{ .severity = .err } } } });
    var one: P.FixedDiagnosticBag(1) = .{};
    const stopped = try P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, one.sink(), .{});
    try testing.expectEqual(.requested, stopped.completion.diagnostic_stop);
    try testing.expectEqual(@as(u64, 1), stopped.errors);
    try testing.expectEqual(.complete, stopped.delivery);
    var zero: P.FixedDiagnosticBag(0) = .{};
    const full = try P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, zero.sink(), .{});
    try testing.expectEqual(.capacity, full.completion.diagnostic_stop);
    try testing.expectEqual(.failed, full.delivery);
    var failed = P.GrowableDiagnosticBag.init(testing.failing_allocator, .{});
    defer failed.deinit();
    const oom = try P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, failed.sink(), .{});
    try testing.expectEqual(.out_of_memory, oom.completion.diagnostic_stop);
    const sink: P.Sink = .{ .context = null, .emit_fn = struct {
        fn emit(_: ?*anyopaque, _: P.Diagnostic) s.reporting.SinkError!s.reporting.Action {
            return error.DiagnosticSinkFailure;
        }
    }.emit };
    try testing.expectEqual(.failure, (try P.parseAndValidate(.{ .bytes = "x", .origin = 0 }, sink, .{})).completion.diagnostic_stop);
}

test "cancellation before work and inside checks" {
    const Token = struct {
        remaining: u32,
        fn requested(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
        fn token(self: *@This()) s.Cancellation {
            return .{ .context = self, .is_requested = requested };
        }
    };
    const P = s.Profile(.{ .policy = .{ .execution = .{ .cancellation = true }, .validation = .{ .equals = .{ .expected = "abcd", .severity = .err } } } });
    for (0..10) |polls| {
        var token: Token = .{ .remaining = @intCast(polls) };
        const r = try P.parseAndValidate(.{ .bytes = "abcd", .origin = 0 }, P.Sink.discard, .{ .cancellation = token.token() });
        try testing.expectEqual(.cancelled, r.completion);
        try testing.expect(!r.valid());
    }
    try testing.expect(@hasDecl(P, "Session"));
}

test "custom result cannot erase reported failure, silently stop or bypass settings verification" {
    const Custom = struct {
        pub const Settings = enum { accepted, rejected, silent_stop, report_then_pass, bad_pattern };
        pub const defaults: Settings = .accepted;
        pub const uses_comparison = true;
        pub fn validateSettings(settings: Settings) bool {
            return settings != .rejected;
        }
        pub fn check(value: anytype, settings: Settings, ctx: anytype) s.Outcome {
            switch (settings) {
                .silent_stop => return .stopped,
                .report_then_pass => {
                    _ = ctx.report(.{});
                    return .passed;
                },
                .bad_pattern => {
                    _ = ctx.equals(value, "z\xff");
                    return .passed;
                },
                else => return .passed,
            }
        }
    };
    const P = s.Profile(.{ .custom = Custom, .runtime_policy = true, .policy = .{ .validation = .{ .custom = .err } } });
    try testing.expectEqual(.invalid_custom_settings, P.validatePolicy(.{ .custom = .rejected }).invalid);
    for ([_]Custom.Settings{ .silent_stop, .report_then_pass, .bad_pattern }) |settings| {
        const r = try P.parseAndValidate(.{ .bytes = "a", .origin = 0 }, P.Sink.discard, .{ .policy = .{ .custom = settings } });
        try testing.expect(!r.valid());
        if (settings == .report_then_pass) {
            try testing.expectEqual(@as(u64, 1), r.errors);
            try testing.expectEqual(.complete, r.completion);
        } else try testing.expectEqual(.invalid_validator, r.completion);
    }
}

test "deterministic malformed UTF-8 differential coverage and zero hidden allocations" {
    var random = std.Random.DefaultPrng.init(0x6d492);
    var buffer: [32]u8 = undefined;
    for (0..20_000) |_| {
        const len = random.random().uintLessThan(usize, buffer.len + 1);
        random.random().bytes(buffer[0..len]);
        const input = buffer[0..len];
        const r = try s.parseAndValidate(.{ .bytes = input, .origin = 7 }, s.Sink.discard, .{});
        try testing.expectEqual(std.unicode.utf8ValidateSlice(input), r.valid());
        try testing.expectEqual(.complete, r.checks.encoding);
        try testing.expectEqual(.complete, r.completion);
    }
    // Even a growable destination needs no allocation if nothing is reported.
    var bag = s.GrowableDiagnosticBag.init(testing.failing_allocator, .{});
    defer bag.deinit();
    try testing.expect((try s.parseAndValidate(.{ .bytes = "valid 😀", .origin = 0 }, bag.sink(), .{})).valid());
    try testing.expectEqual(@as(usize, 0), bag.storage.capacity);
}
