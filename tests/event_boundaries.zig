const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const discard = dot.diagnostic.discard;
const Record = union(enum) { event: dot.events.Event, abort: dot.events.Abort };

fn Recorder(comptime boundaries: bool, comptime metadata: bool) type {
    return struct {
        pub const observations: dot.events.Observations = .{ .delimiter = boundaries };
        pub const statement_extents = metadata;
        pub const coverage = metadata;
        records: [512]Record = undefined,
        len: usize = 0,
        calls: usize = 0,
        stop_at: ?usize = null,
        fail_at: ?usize = null,
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
            self.records[self.len] = .{ .event = event };
            self.len += 1;
            self.calls += 1;
            if (self.fail_at == self.calls) return error.Refused;
            return if (self.stop_at == self.calls) .stop else .proceed;
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
const All = Recorder(true, true);
fn commit(event: dot.events.Event) ?struct { owner: dot.events.Owner, extent: ?dot.Span } {
    return switch (event) {
        inline .commit_node, .commit_edge, .commit_edge_chain, .commit_subgraph, .commit_assignment, .commit_attribute_statement => |v| .{ .owner = v.owner, .extent = v.extent },
        else => null,
    };
}
const source = "digraph G { a:p:n [] /* gap */ [x=y]; a -> b -> c [z=w]; key=\"a\" + \"b\"; node []; subgraph s { d } -> e:q; subgraph t { f; } /* tail */ }";

test "extents and coverage can each be selected without other observations" {
    inline for (.{ false, true }) |with_extents| {
        const C = struct {
            pub const statement_extents = with_extents;
            pub const coverage = !with_extents;
            pub const wants_begin_statement = false;
            pub const recover_statements = false;
            log: All = .{},
            pub fn onEvent(self: *@This(), e: dot.events.Event) error{Refused}!dot.events.Action {
                return self.log.onEvent(e);
            }
            pub fn onAbort(self: *@This(), e: dot.events.Abort) void {
                self.log.onAbort(e);
            }
        };
        const P = dot.Events(C);
        const input = "graph { a [x=y]; }";
        var consumer: C = .{};
        const result = P.parseIn(input, .{}, &consumer, discard, .{});
        try equal(.success, result.outcome);
        try equal(!with_extents, @hasField(P.Result, "coverage"));
        if (!with_extents) try deep(dot.events.Coverage{ .retained_end = input.len, .root_closed = true }, result.coverage);
        var commits: u32 = 0;
        for (consumer.log.items()) |record| {
            try expect(record == .event);
            try expect(record.event != .delimiter and record.event != .begin_statement);
            if (commit(record.event)) |v| {
                commits += 1;
                try equal(with_extents, v.extent != null);
                if (with_extents) try std.testing.expectEqualStrings("a [x=y]", v.extent.?.slice(input));
            }
        }
        try equal(@as(u32, 1), commits);
    }
}

test "commit extents include full declarations but no trailing trivia or semicolons" {
    const expected = [_][]const u8{
        "a:p:n [] /* gap */ [x=y]",
        "a -> b -> c [z=w]",
        "key=\"a\" + \"b\"",
        "node []",
        "d",
        "subgraph s { d } -> e:q",
        "f",
        "subgraph t { f; }",
    };
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .comments = true } } }).Events(All);
        var log: All = .{};
        const result = P.parse(std.testing.allocator, source, &log, discard, .{});
        try equal(.success, result.outcome);
        try deep(dot.events.Coverage{ .retained_end = source.len, .root_closed = true }, result.coverage);
        var n: usize = 0;
        for (log.items()) |record| {
            if (record != .event) continue;
            if (commit(record.event)) |v| {
                try expect(n < expected.len);
                try equal(@backingInt(v.owner.statement), v.extent.?.start);
                try std.testing.expectEqualStrings(expected[n], v.extent.?.slice(source));
                n += 1;
            }
        }
        try equal(expected.len, n);
    }
    try expect(!@hasField(dot.Events(Recorder(false, false)).Result, "coverage"));
    try equal(@as(usize, 116), @sizeOf(dot.events.Event));
}

test "delimiters report recognized and skipped boundaries once and in scope order" {
    const input = "digraph G { a [x=] { q [ ] }; b [label=\"{}[]\" html=<<B>[]</B>>]; subgraph s { c; } bad [x= }";
    const expected = [_]struct { text: u8, scope: u32, skipped: bool }{
        .{ .text = '{', .scope = 0, .skipped = false },
        .{ .text = '[', .scope = 0, .skipped = false },
        .{ .text = ']', .scope = 0, .skipped = true },
        .{ .text = '{', .scope = 0, .skipped = true },
        .{ .text = '[', .scope = 0, .skipped = true },
        .{ .text = ']', .scope = 0, .skipped = true },
        .{ .text = '}', .scope = 0, .skipped = true },
        .{ .text = '[', .scope = 0, .skipped = false },
        .{ .text = ']', .scope = 0, .skipped = false },
        .{ .text = '{', .scope = 1, .skipped = false },
        .{ .text = '}', .scope = 1, .skipped = false },
        .{ .text = '[', .scope = 0, .skipped = false },
        .{ .text = '}', .scope = 0, .skipped = false },
    };
    var log: All = .{};
    const result = dot.Events(All).parse(std.testing.allocator, input, &log, discard, .{});
    try equal(.invalid_syntax, result.outcome);
    try expect(result.coverage.root_closed);
    try equal(input.len, result.coverage.retained_end);
    var n: usize = 0;
    var previous: u32 = 0;
    var opened: [2]bool = .{ false, false };
    var closed: [2]bool = .{ false, false };
    for (log.items()) |record| {
        if (record != .event) continue;
        switch (record.event) {
            .begin_document => opened[0] = true,
            .begin_scope => |v| opened[@backingInt(v.id)] = true,
            .end_scope => |v| try expect(closed[@backingInt(v.id)]),
            .delimiter => |v| {
                try expect(n < expected.len);
                const e = expected[n];
                try equal(e.text, input[v.span.start]);
                try equal(@as(u32, 1), v.span.len);
                try equal(e.scope, @backingInt(v.scope));
                try equal(e.skipped, v.skipped);
                try expect(v.span.start > previous);
                previous = v.span.start;
                try equal(e.text == '{' or e.text == '}', v.kind == .brace);
                try equal(e.text == '{' or e.text == '[', v.side == .open);
                if (!v.skipped and v.kind == .brace) {
                    if (v.side == .open) try expect(opened[@backingInt(v.scope)]) else closed[@backingInt(v.scope)] = true;
                }
                n += 1;
            },
            else => {},
        }
    }
    try equal(expected.len, n);
    try expect(closed[0]);
}

test "delimiters alone do not enable statement aborts or observations after document abort" {
    const C = struct {
        pub const observations: dot.events.Observations = .{ .delimiter = true };
        pub const wants_begin_statement = false;
        pub const recover_statements = false;
        pub const statement_extents = true;
        pub const coverage = true;
        log: All = .{},
        pub fn onEvent(self: *@This(), e: dot.events.Event) error{Refused}!dot.events.Action {
            return self.log.onEvent(e);
        }
        pub fn onAbort(self: *@This(), e: dot.events.Abort) void {
            self.log.onAbort(e);
        }
    };
    var consumer: C = .{};
    const result = dot.Events(C).parse(std.testing.allocator, "graph { a[x=]; b; }", &consumer, discard, .{});
    try equal(.invalid_syntax, result.outcome);
    try expect(!result.coverage.root_closed);
    var aborted = false;
    for (consumer.log.items()) |record| {
        try expect(!aborted);
        if (record == .abort) {
            try expect(record.abort == .document);
            aborted = true;
        } else try expect(record.event != .begin_statement);
    }
    try expect(aborted);
}

test "metadata adds no credits and delimiters add exactly one dispatch credit" {
    inline for (.{ .scalar, .block }) |scanner| {
        var base_work: usize = 0;
        inline for (.{ false, true }) |metadata| inline for (.{ false, true }) |boundaries| {
            const C = Recorder(boundaries, metadata);
            const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true, .cancellation = true } } }).Events(C);
            var reference: C = .{};
            var reference_result: P.Result = undefined;
            for ([_]usize{ 1, 7, 64, 4096 }) |budget| {
                var log: C = .{};
                var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
                var session = P.Session.init(source, frames.storage(), &log, discard, .{});
                defer session.deinit();
                try equal(@as(usize, 0), session.advance(0).work_used);
                try equal(@as(usize, 0), log.len);
                var work: usize = 0;
                while (session.result() == null) {
                    const p = session.advance(budget);
                    try expect(p.work_used <= budget);
                    work += p.work_used;
                }
                try equal(.success, session.result().?.outcome);
                if (budget == 1) {
                    reference = log;
                    reference_result = session.result().?;
                } else {
                    try deep(reference.items(), log.items());
                    try deep(reference_result, session.result().?);
                }
                var delimiter_count: usize = 0;
                for (log.items()) |record| if (record == .event) {
                    if (record.event == .delimiter) delimiter_count += 1;
                    if (commit(record.event)) |v| try equal(metadata, v.extent != null);
                };
                if (!metadata and !boundaries and budget == 1) base_work = work;
                try equal(base_work + delimiter_count, work);
                try equal(@as(usize, 0), session.advance(1).work_used);
            }
        };
    }
}

test "coverage agrees with retained Documents at every truncated prefix and recovery boundary" {
    const input = "digraph G { a; bad[x=]; subgraph s { b; c[z=]; d; } e:p -> f; } // tail";
    inline for (.{ .scalar, .block }) |scanner| {
        const D = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .partial = true } } });
        const P = D.Events(All);
        for (0..input.len + 1) |end| {
            const bytes = input[0..end];
            var parsed = D.parseBorrowed(std.testing.allocator, bytes, discard, .{});
            defer parsed.deinit(std.testing.allocator);
            var log: All = .{};
            const result = P.parse(std.testing.allocator, bytes, &log, discard, .{});
            const expected: dot.events.Coverage = if (parsed.document) |doc| .{
                .retained_end = if (doc.state == .complete) @intCast(bytes.len) else doc.retained_end,
                .root_closed = doc.root_closed,
            } else .{};
            try deep(expected, result.coverage);
        }
    }
}

test "cancellation and sink stops latch between delimiter and continuation dispatches" {
    const P = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } }).Events(All);
    var reference: All = .{};
    const done = P.parse(std.testing.allocator, source, &reference, discard, .{});
    try equal(.success, done.outcome);
    for (1..reference.calls + 1) |at| inline for (.{ false, true }) |fail| {
        var log: All = if (fail) .{ .fail_at = at } else .{ .stop_at = at };
        var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
        var session = P.Session.init(source, frames.storage(), &log, discard, .{});
        defer session.deinit();
        while (session.result() == null) _ = session.advance(1);
        try equal(at, log.calls);
        if (fail) try equal(error.Refused, session.result().?.outcome.event_failure) else try equal(.event_stopped, session.result().?.outcome);
        const saved = log.len;
        try equal(@as(usize, 0), session.advance(100).work_used);
        _ = session.cancel();
        try equal(saved, log.len);
    };
    var terminal_at: usize = 0;
    while (true) : (terminal_at += 1) {
        var log: All = .{};
        var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
        var session = P.Session.init(source, frames.storage(), &log, discard, .{});
        defer session.deinit();
        for (0..terminal_at) |_| _ = session.advance(1);
        if (session.result() != null) break;
        const calls = log.calls;
        _ = session.cancel();
        try equal(.cancelled, session.result().?.outcome);
        try equal(calls, log.calls);
        try equal(@as(usize, 0), session.advance(100).work_used);
        try expect(session.result().?.coverage.retained_end <= source.len);
    }
    try expect(terminal_at > source.len);
}

test "native and runtime event metadata uses source byte offsets" {
    const text = "digraph { a:p [x=y]; subgraph s { b; } }";
    inline for (.{ false, true }) |runtime| {
        const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .runtime_policy = runtime }).Events(All);
        inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
            const E = dot.encoding.Reader(actual);
            var bytes: [text.len * E.width]u8 = undefined;
            for (text, 0..) |byte, i| std.mem.writeInt(if (E.width == 2) u16 else u32, bytes[i * E.width ..][0..E.width], byte, if (actual == .utf16le or actual == .utf32le) .little else .big);
            var log: All = .{};
            const result = try P.parse(std.testing.allocator, &bytes, &log, discard, .{ .encoding = actual });
            try equal(.success, result.outcome);
            try equal(bytes.len, result.coverage.retained_end);
            try expect(result.coverage.root_closed);
            for (log.items()) |record| if (record == .event) {
                if (record.event == .delimiter) try equal(E.width, record.event.delimiter.span.len);
                if (commit(record.event)) |v| {
                    try equal(@backingInt(v.owner.statement), v.extent.?.start);
                    try equal(@as(u32, 0), v.extent.?.start % E.width);
                    try equal(@as(u32, 0), v.extent.?.len % E.width);
                }
            };
        }
    }
}

test "delimiters extents and coverage agree across mutations and budget-one execution" {
    const S = dot.Profile(.{ .policy = .{ .scanner = .scalar } }).Events(All);
    const B = dot.Profile(.{ .policy = .{ .scanner = .block } }).Events(All);
    const M = dot.Profile(.{ .policy = .{ .scanner = .block, .execution = .{ .metering = true } } }).Events(All);
    const input = "digraph G { a:p -> { b[]; { c[x=y] } } -> d:q [x=y]; e=f; subgraph s { g; } }";
    const alphabet = "{}[];=:/\" abc+-<>\n";
    var random = std.Random.DefaultPrng.init(0x3a);
    for (0..1000) |_| {
        var bytes: [input.len]u8 = undefined;
        @memcpy(&bytes, input);
        for (0..3) |_| bytes[random.random().uintLessThan(usize, bytes.len)] = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        var a: All = .{};
        var b: All = .{};
        var c: All = .{};
        const first = S.parse(std.testing.allocator, &bytes, &a, discard, .{});
        const second = B.parse(std.testing.allocator, &bytes, &b, discard, .{});
        var frames: M.FixedParseScratch(.{ .nesting = input.len }) = .{};
        var session = M.Session.init(&bytes, frames.storage(), &c, discard, .{});
        defer session.deinit();
        while (session.result() == null) try expect(session.advance(1).work_used <= 1);
        try deep(first, second);
        try deep(first, session.result().?);
        try deep(a.items(), b.items());
        try deep(a.items(), c.items());
        var last: ?u32 = null;
        for (a.items()) |record| if (record == .event) {
            if (commit(record.event)) |v| {
                try equal(@backingInt(v.owner.statement), v.extent.?.start);
                try expect(v.extent.?.endOffset() <= bytes.len);
                try expect(v.extent.?.len > 0);
            }
            if (record.event == .delimiter) {
                const v = record.event.delimiter;
                if (last) |offset| try expect(offset < v.span.start);
                last = v.span.start;
            }
        };
    }
}

test "runtime sessions reset metadata and stop on cancellation fail-fast and scratch shortage" {
    const P = dot.Profile(.{ .runtime_policy = true }).Events(All);
    var log: All = .{};
    var frames: P.FixedParseScratch(.{ .nesting = 4 }) = .{};
    var session = try P.Session.init(source, frames.storage(), &log, discard, .{
        .policy = .{ .execution = .{ .metering = true } },
    });
    defer session.deinit();
    while (session.result() == null) _ = try session.advance(1);
    try expect(session.result().?.coverage.root_closed);
    log = .{};
    try session.reset("digraph { a[x=]; b; }", &log, discard, .{
        .policy = .{ .on_error = .fail_fast, .execution = .{ .metering = true } },
    });
    const failed = session.run();
    try equal(.invalid_syntax, failed.outcome);
    try expect(!failed.coverage.root_closed);
    try equal(@as(u32, 9), failed.coverage.retained_end);
    for (log.items()) |record| if (record == .event and record.event == .delimiter) try expect(record.event.delimiter.span.start < 13);

    log = .{};
    const stopped = try P.parseIn(source, .{}, &log, discard, .{});
    try equal(.pool_exhausted, stopped.outcome.storage_failure);
    try expect(!stopped.coverage.root_closed);
    try expect(stopped.coverage.retained_end < source.len);

    const Stop = struct {
        fn requested(_: ?*anyopaque) bool {
            return true;
        }
    };
    log = .{};
    try session.reset(source, &log, discard, .{
        .policy = .{ .execution = .{ .metering = true, .cancellation = true } },
        .cancellation = .{ .context = null, .is_requested = Stop.requested },
    });
    try equal(@as(usize, 0), (try session.advance(0)).work_used);
    try equal(.cancelled, session.result().?.outcome);
    try deep(dot.events.Coverage{}, session.result().?.coverage);
    try equal(@as(usize, 0), log.len);
}

test "previews and early names compose with exact commit extents and coverage" {
    const Consumer = struct {
        pub const observations = dot.events.Observations.all;
        pub const statement_extents = true;
        pub const coverage = true;
        log: All = .{},
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
            return self.log.onEvent(event);
        }
        pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
            self.log.onAbort(abort);
        }
    };
    const input = "digraph G { a [x=\"left\" /* interior */ + \"right\"]; b -> c; }";
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true }, .retention = .{ .comments = true } } }).Events(Consumer);
        var consumer: Consumer = .{};
        var frames: P.FixedParseScratch(.{ .nesting = 1 }) = .{};
        var session = P.Session.init(input, frames.storage(), &consumer, discard, .{});
        defer session.deinit();
        while (session.result() == null) _ = session.advance(1);
        try equal(.success, session.result().?.outcome);
        try equal(input.len, session.result().?.coverage.retained_end);
        var n: usize = 0;
        var previews: usize = 0;
        for (consumer.log.items()) |record| if (record == .event) {
            if (record.event == .token_preview) previews += 1;
            if (commit(record.event)) |v| {
                try std.testing.expectEqualStrings(
                    ([_][]const u8{ "a [x=\"left\" /* interior */ + \"right\"]", "b -> c" })[n],
                    v.extent.?.slice(input),
                );
                n += 1;
            }
        };
        try equal(@as(usize, 2), n);
        try expect(previews > 0);
    }
}
