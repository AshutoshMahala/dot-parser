const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const discard = dot.diagnostic.discard;
const Record = union(enum) { event: dot.events.Event, abort: dot.events.Abort };

fn Recorder(comptime previews: bool) type {
    return struct {
        pub const observations: dot.events.Observations = .{ .token_preview = previews };
        records: [4096]Record = undefined,
        len: usize = 0,
        callbacks: usize = 0,
        stop: bool = false,
        fail: bool = false,
        ends_only: bool = false,
        cancel: ?*bool = null,
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
            self.records[self.len] = .{ .event = event };
            self.len += 1;
            self.callbacks += 1;
            if (event == .token_preview_end or (event == .token_preview and !self.ends_only)) {
                if (self.cancel) |flag| flag.* = true;
                if (self.fail) return error.Refused;
                if (self.stop) return .stop;
            }
            return .proceed;
        }
        pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
            self.records[self.len] = .{ .abort = abort };
            self.len += 1;
        }
        fn items(self: *const @This()) []const Record {
            return self.records[0..self.len];
        }
    };
}

test "preview retirement obeys stop failure and cancellation at each polling interval" {
    const Poll = struct {
        fn requested(raw: ?*anyopaque) bool {
            return @as(*bool, @ptrCast(@alignCast(raw.?))).*;
        }
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ 1, 64 }) |interval| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } }).Events(Sink);
        inline for (.{ .stop, .fail, .cancel }) |mode| {
            var flag = false;
            var sink: Sink = .{ .ends_only = true, .stop = mode == .stop, .fail = mode == .fail, .cancel = if (mode == .cancel) &flag else null };
            var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var session = P.Session.init("graph { \"hello\"; }", frames.storage(), &sink, discard, .{ .cancellation = .{ .context = &flag, .is_requested = Poll.requested } });
            defer session.deinit();
            while (session.result() == null) try expect(session.advance(1).work_used <= 1);
            const expected: dot.events.Outcome = switch (mode) {
                .stop => dot.events.Outcome.event_stopped,
                .fail => .{ .event_failure = error.Refused },
                .cancel => .cancelled,
                else => unreachable,
            };
            try equal(expected, session.result().?.outcome);
            var ended = false;
            for (sink.items()) |record| if (record == .event) {
                try expect(!ended);
                ended = record.event == .token_preview_end;
            };
            try expect(ended);
            try expect(sink.records[sink.len - 1].abort == .document);
        }
    };
}

test "previews compose with early events and never follow document abort" {
    const EarlyNoRecovery = struct {
        pub const observations = dot.events.Observations.all;
        pub const wants_begin_statement = false;
        pub const recover_statements = false;
        log: Sink = .{},
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
            return self.log.onEvent(event);
        }
        pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
            self.log.onAbort(abort);
        }
    };
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(EarlyNoRecovery);
        var sink: EarlyNoRecovery = .{};
        var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var session = P.Session.init("graph G { a[x=]; b[\"unfinished", frames.storage(), &sink, discard, .{});
        defer session.deinit();
        while (session.result() == null) _ = session.advance(1);
        try expect(session.result().?.outcome == .invalid_syntax);
        var aborted = false;
        var early = false;
        for (sink.log.items()) |record| {
            try expect(!aborted);
            switch (record) {
                .event => |event| {
                    if (event == .identifier) early = true;
                },
                .abort => |abort| {
                    if (abort == .document) aborted = true;
                },
            }
        }
        try expect(aborted and early);
    }
}

test "queued previews remain silent on zero budget and cancel before delivery" {
    const P = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Events(Sink);
    var sink: Sink = .{};
    var session = P.Session.init("graph \"unfinished", .{}, &sink, discard, .{});
    defer session.deinit();
    // First scalar credit consumes 'g', then queues a raw word observation.
    const first = session.advance(1);
    try equal(@as(usize, 1), first.work_used);
    try expect(first.phase == .dispatch);
    try equal(@as(usize, 0), sink.len);
    _ = session.advance(0);
    try equal(@as(usize, 0), sink.len);
    _ = session.cancel();
    try equal(@as(usize, 0), sink.len); // no output was delivered, no abort owed
}
const Sink = Recorder(true);
const Ordinary = Recorder(false);
fn previewEvent(event: dot.events.Event) bool {
    return event == .token_preview or event == .token_preview_end;
}

test "EOF previews expose raw prefixes with known context but no invented identifier" {
    const cases = .{
        .{ "graph { \"serv", "\"serv", .quoted, .statement_start },
        .{ "graph \"G", "\"G", .quoted, .document_name },
        .{ "graph { subgraph \"cl", "\"cl", .quoted, .subgraph_name },
        .{ "graph { a -- <<B>x", "<<B>x", .html, .edge_right },
        .{ "graph { a -- b -- \"c", "\"c", .quoted, .edge_link },
        .{ "graph { a[\"ke", "\"ke", .quoted, .attribute_key },
        .{ "graph { a[label=\"x\\", "\"x\\", .quoted, .attribute_value },
        .{ "graph { a = \"x\" +", "\"x\" +", .concatenation, .assignment_value },
        .{ "graph { a:\"po", "\"po", .quoted, .port },
        .{ "graph { \"a\" /*x*/ + <b", "\"a\" /*x*/ + <b", .concatenation, .statement_start },
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (cases) |case| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner } }).Events(Sink);
        var sink: Sink = .{};
        const result = P.parse(std.testing.allocator, case[0], &sink, discard, .{});
        try expect(result.outcome == .invalid_syntax);
        var count: usize = 0;
        for (sink.items()) |record| if (record == .event and record.event == .token_preview) {
            const p = record.event.token_preview;
            try std.testing.expectEqualStrings(case[1], p.span.slice(case[0]));
            try equal(@as(dot.events.PreviewKind, case[2]), p.kind);
            try equal(@as(dot.events.PreviewContext, case[3]), p.context);
            try expect(p.reason == .eof);
            count += 1;
        };
        try equal(@as(usize, 1), count);
        try expect(sink.records[sink.len - 1].abort == .document);
    };
}

const PreviewOnly = struct {
    pub const observations: dot.events.Observations = .{ .token_preview = true };
    pub const wants_begin_statement = false;
    pub const recover_statements = false;
    log: Sink = .{},
    pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
        return self.log.onEvent(event);
    }
    pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
        self.log.onAbort(abort);
    }
    fn items(self: *const @This()) []const Record {
        return self.log.items();
    }
};

test "preview ownership and contexts do not depend on separators or begin notifications" {
    const cases = .{
        .{ "graph { a\n \"next", .statement_start },
        .{ "graph { a -- b \"next", .statement_start },
        .{ "graph { a -- b -- c \"next", .statement_start },
        .{ "graph { a[x=1] \"next", .statement_start },
        .{ "graph { subgraph s {} \"next", .statement_start },
        .{ "graph { a:p \"next", .statement_start },
        .{ "graph { a:p:n -- b:q:s \"next", .statement_start },
        .{ "graph { a[x=1 \"next", .attribute_key },
        .{ "graph { a -- \"next", .edge_right },
        .{ "graph { a[label=\"next", .attribute_value },
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ Sink, PreviewOnly }) |Consumer| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner } }).Events(Consumer);
        const Metered = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Consumer);
        inline for (cases) |case| {
            inline for (.{ false, true }) |metered| {
                const sink = try std.testing.allocator.create(Consumer);
                defer std.testing.allocator.destroy(sink);
                sink.* = .{};
                const source = case[0];
                if (metered) {
                    var frames: Metered.FixedParseScratch(.{ .nesting = 2 }) = .{};
                    var session = Metered.Session.init(source, frames.storage(), sink, discard, .{});
                    defer session.deinit();
                    while (session.result() == null) try expect(session.advance(1).work_used <= 1);
                    try expect(session.result().?.outcome == .invalid_syntax);
                } else try expect(P.parse(std.testing.allocator, source, sink, discard, .{}).outcome == .invalid_syntax);
                const start = std.mem.indexOf(u8, source, "\"next").?;
                var seen = false;
                for (sink.items()) |record| if (record == .event and record.event == .token_preview) {
                    const p = record.event.token_preview;
                    if (p.span.start != start) continue;
                    seen = true;
                    try equal(@as(dot.events.PreviewContext, case[1]), p.context);
                    if (case[1] == .statement_start) {
                        try expect(p.owner == null);
                    } else {
                        try equal(@as(u32, 8), @backingInt(p.owner.?.statement));
                        try equal(p.scope, p.owner.?.scope);
                    }
                };
                try expect(seen);
            }
        }
    };
}

test "preview-only consumers get statement aborts and pre-header previews get document aborts" {
    const P = dot.Profile(.{}).Events(PreviewOnly);
    var body: PreviewOnly = .{};
    _ = P.parse(std.testing.allocator, "graph { a[x=\"unfinished", &body, discard, .{});
    const items = body.items();
    try expect(items[items.len - 2].abort == .statement);
    try equal(@as(u32, 8), @backingInt(items[items.len - 2].abort.statement.owner.statement));
    try expect(items[items.len - 1].abort == .document);
    var header: PreviewOnly = .{};
    _ = P.parse(std.testing.allocator, "\"not a graph", &header, discard, .{});
    try equal(@as(usize, 2), header.items().len);
    try expect(header.items()[0].event == .token_preview);
    try expect(header.items()[1].abort == .document);
}

test "concatenation previews exclude trailing trivia without rescanning it" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |comments| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .comments = comments }, .execution = .{ .metering = true } } }).Events(Sink);
        const sources = .{
            "graph { a=\"a\" +    ",
            "graph { a=\"a\" + /* gap */ \n ",
            "graph { a=\"a\" + // gap\n    ",
            "graph { a=\"a\" + # gap\n    ",
            "graph { a=\"a\" +    \"b\"; }",
        };
        inline for (sources) |source| for ([_]usize{ 1, 2, 7, 64, 4096 }) |budget| {
            const sink = try std.testing.allocator.create(Sink);
            defer std.testing.allocator.destroy(sink);
            sink.* = .{};
            var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var session = P.Session.init(source, frames.storage(), sink, discard, .{});
            defer session.deinit();
            while (session.result() == null) try expect(session.advance(budget).work_used <= budget);
            const plus_end = std.mem.indexOfScalar(u8, source, '+').? + 1;
            const next_operand = std.mem.indexOf(u8, source, "\"b\"") orelse source.len;
            var previous: ?dot.events.TokenPreview = null;
            for (sink.items()) |record| if (record == .event and record.event == .token_preview) {
                const p = record.event.token_preview;
                if (p.kind != .concatenation) continue;
                const end = p.span.endOffset();
                try expect(end <= plus_end or end > next_operand);
                if (previous) |old| if (p.reason == .pause) {
                    try expect(!std.meta.eql(old.span, p.span) or old.kind != p.kind);
                };
                previous = p;
            };
        };
    };
}

test "a queued lexical failure wins over a later explicit or polled cancellation" {
    const Poll = struct {
        flag: bool = false,
        calls: usize = 0,
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.flag;
        }
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ 1, 64 }) |interval| inline for (.{ .collect, .fail_fast }) |on_error| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .on_error = on_error, .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } }).Events(Sink);
        for ([_][]const u8{ "graph { \"serv", "graph { a=<<b>x", "graph { a=\"x\" + /* bad" }) |source| {
            // Find the final failure-dispatch credit, not merely a byte frontier:
            // consuming the last byte alone need not have examined EOF yet.
            const full_sink = try std.testing.allocator.create(Sink);
            defer std.testing.allocator.destroy(full_sink);
            full_sink.* = .{};
            var full_frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var full = P.Session.init(source, full_frames.storage(), full_sink, discard, .{});
            defer full.deinit();
            var steps: usize = 0;
            while (full.result() == null) : (steps += 1) _ = full.advance(1);
            inline for (.{ false, true }) |explicit| {
                var hook: Poll = .{};
                const sink = try std.testing.allocator.create(Sink);
                defer std.testing.allocator.destroy(sink);
                sink.* = .{};
                var bag: dot.FixedDiagnosticBag(4) = .{};
                var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
                var session = P.Session.init(source, frames.storage(), sink, bag.sink(), .{ .cancellation = .{ .context = &hook, .is_requested = Poll.requested } });
                defer session.deinit();
                for (0..steps - 1) |_| try expect(session.advance(1).result == null);
                try equal(@as(usize, 0), bag.items().len);
                const callbacks = sink.callbacks;
                hook.flag = true;
                if (explicit) _ = session.cancel() else try equal(@as(usize, 0), session.advance(0).work_used);
                try expect(session.result().?.outcome == .invalid_syntax);
                try equal(@as(u32, 1), session.result().?.syntax_errors);
                try equal(@as(usize, 1), bag.items().len);
                try equal(callbacks, sink.callbacks); // the preview was abandoned
                const polls = hook.calls;
                const records = sink.len;
                _ = session.run();
                _ = session.cancel();
                try equal(@as(usize, 0), session.advance(1).work_used);
                try equal(polls, hook.calls);
                try equal(records, sink.len);
                try equal(@as(usize, 1), bag.items().len);
            }
        }
    };
}

test "failure precedence also holds inside a single runtime-policy run" {
    const Poll = struct {
        calls: usize = 0,
        stop_at: usize = std.math.maxInt(usize),
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls >= self.stop_at;
        }
    };
    const P = dot.Profile(.{ .runtime_policy = true }).Events(Sink);
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |metered| {
        var last_poll: usize = 0;
        for (0..2) |pass| {
            var hook: Poll = .{ .stop_at = if (pass == 0) std.math.maxInt(usize) else last_poll };
            var sink: Sink = .{};
            var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var bag: dot.FixedDiagnosticBag(4) = .{};
            var session = try P.Session.init("graph { \"serv", frames.storage(), &sink, bag.sink(), .{
                .policy = .{ .scanner = scanner, .execution = .{ .metering = metered, .cancellation = true } },
                .cancellation = .{ .context = &hook, .is_requested = Poll.requested },
            });
            defer session.deinit();
            try expect(session.run().outcome == .invalid_syntax);
            try equal(@as(u32, 1), session.result().?.syntax_errors);
            try equal(@as(usize, 1), bag.items().len);
            last_poll = hook.calls;
        }
    };
}

test "cancellation retains a recoverable scanner finding without resuming recovery" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Sink);
        const source = "graph { a=\"x\" + b; after; }";
        var full_sink: Sink = .{};
        var full_frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var full = P.Session.init(source, full_frames.storage(), &full_sink, discard, .{});
        defer full.deinit();
        var steps: usize = 0;
        reject: while (full.result() == null) {
            const before = full_sink.len;
            _ = full.advance(1);
            steps += 1;
            for (full_sink.items()[before..]) |record| if (record == .event and record.event == .token_preview_end and record.event.token_preview_end.reason == .rejected) break :reject;
        }
        try expect(full.result() == null); // the ordinary parser could recover
        var sink: Sink = .{};
        var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var bag: dot.FixedDiagnosticBag(4) = .{};
        var session = P.Session.init(source, frames.storage(), &sink, bag.sink(), .{});
        defer session.deinit();
        for (0..steps - 1) |_| _ = session.advance(1);
        try equal(@as(usize, 0), bag.items().len);
        const callbacks = sink.callbacks;
        const result = session.cancel();
        try expect(result.outcome == .cancelled);
        try equal(@as(u32, 1), result.syntax_errors);
        try equal(@as(usize, 1), bag.items().len);
        try equal(callbacks, sink.callbacks);
        try expect(sink.items()[sink.len - 1].abort == .document);
    }
}

test "pause previews have separately charged lifecycle events and unchanged core work" {
    const input = "digraph G { \"alpha\" /*join*/ + <b>:p -> beta [label=\"Straße 中文 😀\"]; x=12.5; bad[x=]; after; }";
    inline for (.{ .scalar, .block }) |scanner| {
        const policy: dot.Policy = .{ .scanner = scanner, .execution = .{ .metering = true }, .retention = .{ .comments = true } };
        const Base = dot.Profile(.{ .policy = policy }).Events(Ordinary);
        var base: Ordinary = .{};
        var base_frames: Base.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var plain = Base.Session.init(input, base_frames.storage(), &base, discard, .{});
        defer plain.deinit();
        const base_work = plain.advance(1_000_000).work_used;
        const P = dot.Profile(.{ .policy = policy }).Events(Sink);
        for ([_]usize{ 1, 2, 3, 7, 64, 4096 }) |budget| {
            var sink: Sink = .{};
            var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var session = P.Session.init(input, frames.storage(), &sink, discard, .{});
            defer session.deinit();
            var used: usize = 0;
            var frontier: usize = 0;
            var count: usize = 0;
            while (session.result() == null) {
                const before = sink.len;
                try equal(@as(usize, 0), session.advance(0).work_used);
                try equal(before, sink.len);
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                try expect(progress.source_frontier >= frontier);
                frontier = progress.source_frontier;
                used += progress.work_used;
                try expect(used < 10_000);
                for (sink.items()[before..]) |record| if (record == .event and record.event == .token_preview) {
                    const span = record.event.token_preview.span;
                    try expect(span.len != 0 and span.start + span.len <= frontier);
                    count += 1;
                };
            }
            try std.testing.expectEqualDeep(plain.result().?, session.result().?);
            var index: usize = 0;
            var extra: usize = 0;
            var active: ?u32 = null;
            for (sink.items()) |record| {
                if (record == .event and previewEvent(record.event)) {
                    extra += 1;
                    switch (record.event) {
                        .token_preview => |p| {
                            if (active) |start| try equal(start, p.span.start);
                            active = p.span.start;
                        },
                        .token_preview_end => |end| {
                            try equal(active.?, end.start);
                            active = null;
                        },
                        else => unreachable,
                    }
                    continue;
                }
                try std.testing.expectEqualDeep(base.records[index], record);
                index += 1;
            }
            try expect(active == null);
            try equal(base.len, index);
            try equal(base_work + extra, used);
            if (budget == 1) try expect(count > 0);
        }
    }
}

test "preview EOF, reset, stop failure and cancellation work with runtime policies" {
    const Cancel = struct {
        fn poll(raw: ?*anyopaque) bool {
            return @as(*bool, @ptrCast(@alignCast(raw.?))).*;
        }
    };
    const P = dot.Profile(.{ .runtime_policy = true }).Events(Sink);
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |metered| {
        var cancelled = false;
        var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
        inline for (.{ .normal, .stop, .fail, .cancel }) |mode| {
            cancelled = false;
            var sink: Sink = .{ .stop = mode == .stop, .fail = mode == .fail, .cancel = if (mode == .cancel) &cancelled else null };
            var session = try P.Session.init("graph \"unfinished", frames.storage(), &sink, discard, .{
                .policy = .{ .scanner = scanner, .execution = .{ .metering = metered, .cancellation = true } },
                .cancellation = .{ .context = &cancelled, .is_requested = Cancel.poll },
            });
            defer session.deinit();
            if (metered) {
                while (session.result() == null) try expect((try session.advance(1)).work_used <= 1);
            } else _ = session.run();
            switch (mode) {
                .normal => try expect(session.result().?.outcome == .invalid_syntax),
                .stop => try expect(session.result().?.outcome == .event_stopped),
                .fail => try equal(dot.events.Outcome{ .event_failure = error.Refused }, session.result().?.outcome),
                // At EOF the syntax failure latches in the same dispatch;
                // otherwise the following credit polls before more work.
                .cancel => try expect(session.result().?.outcome == (if (metered) dot.events.Outcome.cancelled else .invalid_syntax)),
                else => unreachable,
            }
            try expect(sink.records[sink.len - 1].abort == .document);
            const len = sink.len;
            _ = session.run();
            _ = session.cancel();
            try equal(len, sink.len);
            var fresh: Sink = .{};
            try session.reset("graph{}", &fresh, discard, .{});
            try expect(session.run().outcome == .success);
        }
    };
}

test "native EOF previews retain physical source coordinates" {
    const text = "graph { a[label=\"abc";
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{ .scanner = scanner } }).Events(Sink);
        inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
            const E = dot.encoding.Reader(actual);
            var bytes: [text.len * E.width]u8 = undefined;
            for (text, 0..) |byte, i| std.mem.writeInt(if (E.width == 2) u16 else u32, bytes[i * E.width ..][0..E.width], byte, E.endian);
            var sink: Sink = .{};
            const result = try P.parse(std.testing.allocator, &bytes, &sink, discard, .{ .encoding = actual });
            try expect(result.outcome == .invalid_syntax);
            var seen = false;
            for (sink.items()) |record| if (record == .event and record.event == .token_preview) {
                const p = record.event.token_preview;
                try equal(@as(u32, 16 * E.width), p.span.start);
                try equal(@as(u32, 4 * E.width), p.span.len);
                try equal(actual, p.source_info.encoding);
                seen = true;
            };
            try expect(seen);
        }
    }
}

test "preview prefixes and failures agree on truncations and deterministic mutations" {
    const input = "graph { \"a\" /*join*/ + <b>:p -- c [x=1e3]; d=\"q\"; subgraph s { e; } f[x=]; g; }";
    var random = std.Random.DefaultPrng.init(58739);
    var bytes: [input.len]u8 = undefined;
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |comments| {
        const policy: dot.Policy = .{ .scanner = scanner, .execution = .{ .metering = true }, .retention = .{ .comments = comments }, .validation = .{ .ambiguous_numeral = .err } };
        const Base = dot.Profile(.{ .policy = policy }).Events(Ordinary);
        const P = dot.Profile(.{ .policy = policy }).Events(Sink);
        for (0..input.len + 300) |iteration| {
            bytes = input.*;
            const source = if (iteration <= input.len) bytes[0..iteration] else blk: {
                bytes[random.random().uintLessThan(usize, bytes.len)] = random.random().int(u8);
                break :blk &bytes;
            };
            var plain: Ordinary = .{};
            var sink: Sink = .{};
            var base_frames: Base.FixedParseScratch(.{ .nesting = 4 }) = .{};
            var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
            var base = Base.Session.init(source, base_frames.storage(), &plain, discard, .{});
            defer base.deinit();
            const baseline = base.advance(100_000);
            var session = P.Session.init(source, frames.storage(), &sink, discard, .{});
            defer session.deinit();
            var used: usize = 0;
            while (session.result() == null) {
                const budget = 1 + iteration % 7;
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                used += progress.work_used;
                try expect(used < 10_000);
            }
            try std.testing.expectEqualDeep(base.result().?, session.result().?);
            var active: ?u32 = null;
            var extra: usize = 0;
            var base_events: usize = 0;
            for (sink.items()) |record| switch (record) {
                .event => |event| switch (event) {
                    .token_preview => |p| {
                        if (active) |start| try equal(start, p.span.start);
                        active = p.span.start;
                        try expect(p.span.len > 0 and p.span.endOffset() <= source.len);
                        extra += 1;
                    },
                    .token_preview_end => |end| {
                        try equal(active.?, end.start);
                        active = null;
                        extra += 1;
                    },
                    else => {
                        while (plain.records[base_events] == .abort) base_events += 1;
                        try std.testing.expectEqualDeep(plain.records[base_events].event, event);
                        base_events += 1;
                    },
                },
                .abort => |a| if (a == .document) {
                    active = null;
                },
            };
            try expect(active == null);
            try equal(baseline.work_used + extra, used);
        }
    };
}
