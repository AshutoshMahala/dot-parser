const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const discard = dot.diagnostic.discard;
const Record = union(enum) { event: dot.events.Event, abort: dot.events.Abort };

fn Recorder(comptime early: bool, comptime begins: bool) type {
    return struct {
        pub const observations: dot.events.Observations = if (early) .early else .none;
        pub const wants_begin_statement = begins;
        records: [512]Record = undefined,
        len: usize = 0,
        calls: usize = 0,
        stop_at: ?usize = null,
        fail_at: ?usize = null,
        cancel_flag: ?*bool = null,
        cancel_at: ?usize = null,

        pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
            self.records[self.len] = .{ .event = event };
            self.len += 1;
            self.calls += 1;
            if (self.cancel_at == self.calls) self.cancel_flag.?.* = true;
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
const Early = Recorder(true, true);

test "observation kinds share dispatch but are independently selected and charged" {
    const input = "digraph G { subgraph s { a; } a -> b -> c; x=y; node[k=v]; }";
    inline for (.{ .scalar, .block }) |scanner| {
        const Base = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } });
        var baseline: Recorder(false, true) = .{};
        const B = Base.Events(@TypeOf(baseline));
        var base_frames: B.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var base_session = B.Session.init(input, base_frames.storage(), &baseline, discard, .{});
        defer base_session.deinit();
        var base_work: usize = 0;
        while (base_session.result() == null) base_work += base_session.advance(1).work_used;

        inline for (.{
            dot.events.Observations.none,
            dot.events.Observations{ .identifier = true },
            dot.events.Observations{ .statement_head = true },
            dot.events.Observations{ .document_name = true },
            dot.events.Observations{ .subgraph_name = true },
            dot.events.Observations.previews,
            dot.events.Observations.all,
        }) |selected| {
            const Consumer = struct {
                pub const observations = selected;
                log: Recorder(false, true) = .{},
                pub fn onEvent(self: *@This(), e: dot.events.Event) error{Refused}!dot.events.Action {
                    return self.log.onEvent(e);
                }
                pub fn onAbort(self: *@This(), e: dot.events.Abort) void {
                    self.log.onAbort(e);
                }
            };
            const P = Base.Events(Consumer);
            for ([_]usize{ 1, 64, 4096 }) |budget| {
                var sink: Consumer = .{};
                var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
                var session = P.Session.init(input, frames.storage(), &sink, discard, .{});
                defer session.deinit();
                var work: usize = 0;
                while (session.result() == null) {
                    const p = session.advance(budget);
                    try expect(p.work_used <= budget);
                    work += p.work_used;
                }
                try expect(session.result().?.outcome == .success);
                var base_index: usize = 0;
                var observed: usize = 0;
                for (sink.log.items()) |record| {
                    const selected_event = if (record == .event) switch (record.event) {
                        .identifier => selected.identifier,
                        .statement_head => selected.statement_head,
                        .document_name => selected.document_name,
                        .subgraph_name => selected.subgraph_name,
                        .token_preview, .token_preview_end => selected.token_preview,
                        else => false,
                    } else false;
                    if (selected_event) {
                        observed += 1;
                    } else {
                        try expect(base_index < baseline.len);
                        try std.testing.expectEqualDeep(baseline.records[base_index], record);
                        base_index += 1;
                    }
                }
                try equal(baseline.len, base_index);
                try equal(base_work + observed, work);
            }
        }
    }
}

test "aborted consumers do not schedule unused early observations" {
    const input = "graph { a[x=]; b; c; d -- e; f=g; h -- i -- j; subgraph s { k; } l[x=y]; node [x=1]; graph [y=2]; edge [z=3]; }";
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |begins| {
        var work: [2]usize = .{ 0, 0 };
        var observation_count: usize = 0;
        inline for (.{ false, true }, 0..) |early, index| {
            const Consumer = struct {
                pub const recover_statements = false;
                pub const wants_begin_statement = begins;
                pub const observations: dot.events.Observations = if (early) .early else .none;
                log: Recorder(early, begins) = .{},
                pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
                    return self.log.onEvent(event);
                }
                pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
                    self.log.onAbort(abort);
                }
            };
            const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Consumer);
            var sink: Consumer = .{};
            var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var session = P.Session.init(input, frames.storage(), &sink, discard, .{});
            defer session.deinit();
            while (session.result() == null) work[index] += session.advance(1).work_used;
            try expect(session.result().?.outcome == .invalid_syntax);
            var aborted = false;
            for (sink.log.items()) |record| {
                try expect(!aborted);
                if (record == .event and isEarly(record.event)) observation_count += 1;
                if (record == .abort and record.abort == .document) aborted = true;
            }
            try expect(aborted);
        }
        try equal(work[0] + observation_count, work[1]);
    };
}
fn isEarly(event: dot.events.Event) bool {
    return switch (event) {
        .identifier, .statement_head, .document_name, .subgraph_name => true,
        else => false,
    };
}
fn parse(comptime Sink: type, input: []const u8, sink: *Sink) dot.events.Result {
    const P = dot.Events(Sink);
    var frames: P.FixedParseScratch(.{ .nesting = 8 }) = .{};
    return P.parseIn(input, frames.storage(), sink, discard, .{});
}

test "early observations expose complete names and heads without unfinished-token guesses" {
    const cases = .{
        .{ "graph { a [label=\"unfinished", .statement_start, "a", .node },
        .{ "digraph { a -> b [label=", .edge_right, "b", .edge },
        .{ "digraph { a -> b -> c:", .edge_link, "c", .edge },
        .{ "graph { key =", .statement_start, "key", .assignment },
    };
    inline for (cases) |case| {
        var sink: Early = .{};
        try expect(parse(Early, case[0], &sink).outcome == .invalid_syntax);
        var name_seen = false;
        var head_seen = false;
        for (sink.items()) |record| if (record == .event) switch (record.event) {
            .identifier => |name| if (name.role == case[1]) {
                try std.testing.expectEqualStrings(case[2], name.name.slice(case[0]));
                // Only complete identifiers qualify, even if their statement fails.
                try equal(try dot.identifier.hash(case[2]), try dot.identifier.fromName(case[0], name.name).hash());
                name_seen = true;
            },
            .statement_head => |head| {
                try equal(@as(dot.events.StatementKind, case[3]), head.kind);
                try equal(dot.events.ScopeId.root, head.owner.scope);
                head_seen = true;
            },
            .commit_node, .commit_edge, .commit_edge_chain, .commit_assignment => return error.UnexpectedCommit,
            else => {},
        };
        try expect(name_seen and head_seen);
    }
    for ([_][]const u8{ "graph { \"unfinished", "graph { \"a\"+\"unfinished", "graph { <<B>unfinished" }) |input| {
        var sink: Early = .{};
        try expect(parse(Early, input, &sink).outcome == .invalid_syntax);
        for (sink.items()) |record| if (record == .event) try expect(record.event != .identifier);
    }
    var unresolved: Early = .{};
    _ = parse(Early, "graph { a", &unresolved);
    var names: usize = 0;
    for (unresolved.items()) |record| if (record == .event) {
        if (record.event == .identifier) names += 1;
        try expect(record.event != .statement_head); // a could still become a key/endpoint
    };
    try equal(@as(usize, 1), names);
}

test "early named headers do not invent body or scope entries" {
    var root: Early = .{};
    try expect(parse(Early, "strict digraph \"G\"", &root).outcome == .invalid_syntax);
    try equal(@as(usize, 2), root.len);
    const name = root.records[0].event.document_name;
    try expect(name.strict and name.kind == .digraph);
    try std.testing.expectEqualStrings("\"G\"", name.name.slice("strict digraph \"G\""));
    try expect(root.records[1].abort == .document);

    for ([_][]const u8{ "graph { subgraph cluster_x", "digraph { a -> subgraph cluster_x" }, 0..) |input, i| {
        var sink: Early = .{};
        try expect(parse(Early, input, &sink).outcome == .invalid_syntax);
        var found = false;
        for (sink.items()) |record| if (record == .event) {
            try expect(record.event != .begin_scope and record.event != .end_scope);
            if (record.event == .subgraph_name) {
                const sub = record.event.subgraph_name;
                try std.testing.expectEqualStrings("cluster_x", sub.name.slice(input));
                try equal(if (i == 0) dot.events.ScopeRole.left else .right, sub.role);
                try equal(dot.events.ScopeId.root, sub.owner.scope);
                found = true;
            }
        };
        try expect(found);
    }
}

const source = "digraph G { node [x=y]; graph [x=y]; edge [x=y]; a:p -> b -> c [x=y]; key=value; subgraph s { x; } -> { y; } -> z; bad[x=]; after; }";

test "early events preserve existing stream and owner identities through nested recovery" {
    inline for (.{ false, true }) |begins| {
        const E = Recorder(true, begins);
        const B = Recorder(false, begins);
        var early: E = .{};
        var baseline: B = .{};
        try std.testing.expectEqualDeep(parse(B, source, &baseline), parse(E, source, &early));
        var at: usize = 0;
        var heads: [source.len]?dot.events.StatementKind = @splat(null);
        for (early.items()) |record| {
            if (record == .event and isEarly(record.event)) {
                if (record.event == .statement_head) {
                    const head = record.event.statement_head;
                    const id = @backingInt(head.owner.statement);
                    try expect(heads[id] == null); // no duplicate head after nested scopes/attributes
                    heads[id] = head.kind;
                    try equal(head.start.start, id);
                }
                continue;
            }
            try expect(at < baseline.len);
            try std.testing.expectEqualDeep(baseline.records[at], record);
            at += 1;
        }
        try equal(baseline.len, at);
        try equal(dot.events.StatementKind.edge, heads[std.mem.indexOf(u8, source, "subgraph").?].?);
        try equal(dot.events.StatementKind.node, heads[std.mem.indexOf(u8, source, "after").?].?);
        try equal(dot.events.StatementKind.assignment, heads[std.mem.indexOf(u8, source, "key=").?].?);
    }
}

test "each early callback consumes one additional dispatch credit across pause partitions" {
    inline for (.{ .scalar, .block }) |scanner| {
        const E = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Early);
        const Baseline = Recorder(false, true);
        const B = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Baseline);
        var base: Baseline = .{};
        var frames_b: B.FixedParseScratch(.{ .nesting = 8 }) = .{};
        var session_b = B.Session.init(source, frames_b.storage(), &base, discard, .{});
        defer session_b.deinit();
        var base_work: usize = 0;
        while (session_b.result() == null) base_work += session_b.advance(1).work_used;
        var reference: Early = .{};
        _ = parse(Early, source, &reference);
        var extra: usize = 0;
        for (reference.items()) |record| if (record == .event and isEarly(record.event)) {
            extra += 1;
        };
        for ([_]usize{ 1, 2, 3, 7, 64, 4096 }) |budget| {
            var sink: Early = .{};
            var frames: E.FixedParseScratch(.{ .nesting = 8 }) = .{};
            var session = E.Session.init(source, frames.storage(), &sink, discard, .{});
            defer session.deinit();
            var used: usize = 0;
            while (session.result() == null) {
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                used += progress.work_used;
                try expect(used <= base_work + extra);
            }
            try equal(base_work + extra, used);
            try std.testing.expectEqualDeep(reference.items(), sink.items());
            try equal(session_b.result().?.syntax_errors, session.result().?.syntax_errors);
            const len = sink.len;
            try equal(@as(usize, 0), session.advance(0).work_used);
            _ = session.cancel();
            try equal(len, sink.len);
            sink = .{};
            session.reset("graph G", &sink, discard, .{});
            try expect(session.run().outcome == .invalid_syntax);
            try expect(sink.records[0].event == .document_name);
            try expect(sink.records[sink.len - 1].abort == .document);
        }
    }
}

test "early callback refusal stop and cancellation prevent later dispatch" {
    const text = "graph G { a; subgraph s { b; } c -- d; }";
    var reference: Early = .{};
    _ = parse(Early, text, &reference);
    const Stop = struct {
        fn requested(context: ?*anyopaque) bool {
            return @as(*bool, @ptrCast(@alignCast(context.?))).*;
        }
    };
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true, .cancellation = true } } }).Events(Early);
        for (1..reference.calls) |call| {
            inline for ([_]enum { stop, fail, cancel }{ .stop, .fail, .cancel }) |mode| {
                var cancelled = false;
                var sink: Early = switch (mode) {
                    .stop => .{ .stop_at = call },
                    .fail => .{ .fail_at = call },
                    .cancel => .{ .cancel_at = call, .cancel_flag = &cancelled },
                };
                var frames: P.FixedParseScratch(.{ .nesting = 8 }) = .{};
                var session = P.Session.init(text, frames.storage(), &sink, discard, .{ .cancellation = .{ .context = &cancelled, .is_requested = Stop.requested } });
                defer session.deinit();
                while (session.result() == null) try expect(session.advance(1).work_used <= 1);
                try equal(call, sink.calls);
                const expected: dot.events.Outcome = switch (mode) {
                    .stop => dot.events.Outcome.event_stopped,
                    .fail => .{ .event_failure = error.Refused },
                    .cancel => .cancelled,
                };
                try equal(expected, session.result().?.outcome);
                try expect(sink.records[sink.len - 1].abort == .document);
                const len = sink.len;
                _ = session.advance(100);
                _ = session.cancel();
                try equal(len, sink.len);
            }
        }
    }
}

test "early observations are invariant across runtime execution selection" {
    const P = dot.Profile(.{ .runtime_policy = true }).Events(Early);
    var reference: Early = .{};
    _ = parse(Early, source, &reference);
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |metered| inline for (.{ false, true }) |cancellable| {
        var sink: Early = .{};
        var frames: P.FixedParseScratch(.{ .nesting = 8 }) = .{};
        var session = try P.Session.init(source, frames.storage(), &sink, discard, .{ .policy = .{ .scanner = scanner, .execution = .{ .metering = metered, .cancellation = cancellable } } });
        defer session.deinit();
        if (metered) {
            while (session.result() == null) try expect((try session.advance(1)).work_used <= 1);
        } else _ = session.run();
        try std.testing.expectEqualDeep(reference.items(), sink.items());
    };
}

test "early native headers and identifiers use original coordinates and encoding" {
    const text = "graph G { a -- b [x=]; subgraph s";
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } }).Events(Early);
    inline for (.{ .utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const E = dot.encoding.Reader(actual);
        var bytes: [text.len * E.width]u8 = undefined;
        for (text, 0..) |byte, i| std.mem.writeInt(if (E.width == 2) u16 else u32, bytes[i * E.width ..][0..E.width], byte, E.endian);
        var sink: Early = .{};
        const result = try P.parse(std.testing.allocator, &bytes, &sink, discard, .{ .encoding = actual });
        try expect(result.outcome == .invalid_syntax);
        try equal(result.source_info, sink.records[0].event.document_name.source_info);
        var names: usize = 0;
        for (sink.items()) |record| if (record == .event) switch (record.event) {
            .identifier => |id| {
                try equal(@as(u32, E.width), id.name.len);
                try equal(@as(u32, if (id.role == .statement_start) 10 else 15) * E.width, id.name.start);
                names += 1;
            },
            .subgraph_name => |name| try equal(@as(u32, text.len - 1) * E.width, name.name.start),
            else => {},
        };
        try equal(@as(usize, 2), names);
    }
}

test "early observations agree across truncated mutated and metered input" {
    const fixture = "digraph \"G\" { \"a\" /*join*/ + \"b\":p -> <<B>x</B>> -> c; key=value; subgraph s { node [x=y]; d; } -- {e;} f[x=]; later; }";
    var random = std.Random.DefaultPrng.init(0xea417);
    const alphabet = "{}[];:=><-/\"+ab /*\n";
    // Every prefix models a typing pause; mutations exercise recovery/replay.
    for (0..fixture.len + 1 + 1000) |iteration| {
        var bytes: [fixture.len]u8 = undefined;
        @memcpy(&bytes, fixture);
        const len = if (iteration <= fixture.len) iteration else fixture.len;
        if (iteration > fixture.len) for (0..3) |_| {
            bytes[random.random().uintLessThan(usize, bytes.len)] = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        };
        var reference: Early = .{};
        const expected = parse(Early, bytes[0..len], &reference);
        for (reference.items()) |record| if (record == .event and record.event == .identifier) {
            const span = record.event.identifier.name;
            try expect(span.start <= len and span.len <= len - span.start);
            const raw = span.slice(bytes[0..len]);
            try equal(try dot.identifier.hash(raw), try dot.identifier.fromName(bytes[0..len], span).hash());
        };
        inline for (.{ .scalar, .block }) |scanner| {
            const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Early);
            var sink: Early = .{};
            var frames: P.FixedParseScratch(.{ .nesting = 8 }) = .{};
            var session = P.Session.init(bytes[0..len], frames.storage(), &sink, discard, .{});
            defer session.deinit();
            var work: usize = 0;
            const budget: usize = if (iteration % 2 == 0) 1 else 7;
            while (session.result() == null) {
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                work += progress.work_used;
                try expect(work < 10_000);
            }
            try std.testing.expectEqualDeep(expected, session.result().?);
            try std.testing.expectEqualDeep(reference.items(), sink.items());
        }
    }
}

test "undelivered early header does not require abort and zero budget delivers nothing" {
    const P = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Events(Early);
    var frames: P.FixedParseScratch(.{ .nesting = 0 }) = .{};
    var sink: Early = .{};
    var session = P.Session.init("graph G", frames.storage(), &sink, discard, .{});
    defer session.deinit();
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        try expect(attempts < 100);
        if (session.advance(1).phase == .dispatch) break;
        try equal(@as(usize, 0), sink.len);
    }
    try equal(@as(usize, 0), sink.len);
    try equal(@as(usize, 0), session.advance(0).work_used);
    try equal(@as(usize, 0), sink.len);
    try expect(session.cancel().outcome == .cancelled);
    try equal(@as(usize, 0), sink.len);
    session.reset("graph G", &sink, discard, .{});
    while (sink.len == 0) _ = session.advance(1);
    try expect(sink.records[0].event == .document_name);
    try expect(session.cancel().outcome == .cancelled);
    try equal(@as(usize, 2), sink.len);
    try expect(sink.records[1].abort == .document);
}

test "early-only consumer keeps rejection lifecycle without begin or recovery notifications" {
    const Consumer = struct {
        pub const observations: dot.events.Observations = .early;
        pub const wants_begin_statement = false;
        pub const recover_statements = false;
        log: Early = .{},
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{Refused}!dot.events.Action {
            return self.log.onEvent(event);
        }
        pub fn onAbort(self: *@This(), reason: dot.events.Abort) void {
            self.log.onAbort(reason);
        }
    };
    var sink: Consumer = .{};
    const result = dot.Events(Consumer).parse(std.testing.failing_allocator, "graph { a[x=]; later; b[y=]; }", &sink, discard, .{});
    try expect(result.outcome == .invalid_syntax);
    try equal(@as(u32, 2), result.syntax_errors);
    try equal(@as(usize, 5), sink.log.len);
    try expect(sink.log.records[0].event == .begin_document);
    try expect(sink.log.records[1].event == .identifier);
    try expect(sink.log.records[2].event == .statement_head);
    try expect(sink.log.records[3].abort == .statement);
    try expect(sink.log.records[4].abort == .document);
}
