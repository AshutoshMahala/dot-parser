const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const discard = dot.diagnostic.discard;
const Record = union(enum) { event: dot.events.Event, abort: dot.events.Abort };
const Recorder = struct {
    records: [256]Record = undefined,
    len: u32 = 0,
    stop_at: ?u32 = null,
    fail_at: ?u32 = null,
    pub fn onEvent(self: *@This(), value: dot.events.Event) error{OutputFailure}!dot.events.Action {
        self.records[self.len] = .{ .event = value };
        self.len += 1;
        if (self.fail_at == self.len) return error.OutputFailure;
        return if (self.stop_at == self.len) .stop else .proceed;
    }
    pub fn onAbort(self: *@This(), value: dot.events.Abort) void {
        self.records[self.len] = .{ .abort = value };
        self.len += 1;
    }
    fn items(self: *const @This()) []const Record {
        return self.records[0..self.len];
    }
};
const input = "digraph G { a:p -> b -> c [x=y]; bad [x=]; d; subgraph s { e -> ; f; } g; }";

test "public events commit statements after recovery without document pools" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner } }).Events(Recorder);
        var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var log: Recorder = .{};
        const result = P.parseIn(input, frames.storage(), &log, discard, .{});
        try equal(dot.events.Outcome.invalid_syntax, result.outcome);
        try equal(dot.Completion.complete, result.completion);
        try equal(@as(u32, 2), result.syntax_errors);
        var commits: u32 = 0;
        var statement_aborts: u32 = 0;
        var gaps: u32 = 0;
        var ends: u32 = 0;
        for (log.items()) |record| switch (record) {
            .event => |event| switch (event) {
                .commit_node, .commit_edge, .commit_edge_chain, .commit_subgraph, .commit_assignment, .commit_attribute_statement => commits += 1,
                .skipped => |value| {
                    try std.testing.expectEqualStrings(if (gaps == 0) "bad [x=];" else "e -> ;", value.span.slice(input));
                    gaps += 1;
                },
                .end_document => return error.UnexpectedCommit,
                else => {},
            },
            .abort => |abort| switch (abort) {
                .statement => statement_aborts += 1,
                .document => ends += 1,
            },
        };
        try equal(@as(u32, 5), commits);
        try equal(@as(u32, 2), statement_aborts);
        try equal(@as(u32, 2), gaps);
        try equal(@as(u32, 1), ends);
        try expect(log.records[log.len - 1].abort == .document);
    }
}

test "event sessions preserve ordering at every work partition and reset" {
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true } } }).Events(Recorder);
        var reference: Recorder = .{};
        _ = P.parse(std.testing.allocator, input, &reference, discard, .{});
        for ([_]usize{ 1, 2, 3, 7, 31, 1024 }) |budget| {
            var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
            var log: Recorder = .{};
            var session = P.Session.init(input, frames.storage(), &log, discard, .{});
            defer session.deinit();
            try expect(session.result() == null);
            var steps: usize = 0;
            while (session.result() == null) : (steps += 1) {
                const progress = session.advance(budget);
                try expect(progress.work_used <= budget);
                try expect(steps < input.len * 20);
            }
            try std.testing.expectEqualDeep(reference.items(), log.items());
            const terminal_count = log.len;
            _ = session.advance(0);
            _ = session.cancel();
            try equal(terminal_count, log.len);
            log = .{};
            session.reset("graph { z; }", &log, discard, .{});
            try expect(session.run().outcome == .success);
            try expect(log.records[log.len - 1].event == .end_document);
        }
    }
}

test "event failure and accepted stop are not storage failures" {
    const P = dot.Events(Recorder);
    for (1..12) |stop| {
        inline for (.{ false, true }) |fail| {
            var log: Recorder = if (fail) .{ .fail_at = @intCast(stop) } else .{ .stop_at = @intCast(stop) };
            const result = P.parse(std.testing.allocator, "graph { a:p [x=y]; b; }", &log, discard, .{});
            if (result.outcome != .success) {
                if (fail) try equal(error.OutputFailure, result.outcome.event_failure) else try expect(result.outcome == .event_stopped);
                try expect(log.records[log.len - 1].abort == .document);
            }
        }
    }
}

test "event runtime policy fail-fast and explicit cancellation" {
    const P = dot.Profile(.{ .runtime_policy = true }).Events(Recorder);
    var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
    var log: Recorder = .{};
    var session = try P.Session.init(input, frames.storage(), &log, discard, .{ .policy = .{ .on_error = .fail_fast, .execution = .{ .metering = true } } });
    defer session.deinit();
    while (session.result() == null) _ = try session.advance(1);
    try equal(@as(u32, 1), session.result().?.syntax_errors);
    log = .{};
    try session.reset(input, &log, discard, .{ .policy = .{ .execution = .{ .metering = true } } });
    _ = try session.advance(32);
    try expect(session.cancel().outcome == .cancelled);
    const len = log.len;
    _ = session.run();
    try equal(len, log.len);
}

test "event-only parsing does not allocate flat output or emit before a malformed header" {
    const P = dot.Events(Recorder);
    var log: Recorder = .{};
    const valid = P.parse(std.testing.failing_allocator, "graph { a:p [x=y]; a -- b -- c; }", &log, discard, .{});
    try expect(valid.outcome == .success);
    log = .{};
    const invalid = P.parse(std.testing.failing_allocator, "graph", &log, discard, .{});
    try expect(invalid.outcome == .invalid_syntax);
    try equal(@as(u32, 0), log.len);
}

test "native events preserve byte coordinates through recovery" {
    const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } }).Events(Recorder);
    inline for (.{ dot.InputEncoding.utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const Reader = dot.encoding.Reader(actual);
        const text = "graph { bad [x=]; after; }";
        var bytes: [text.len * Reader.width]u8 = undefined;
        for (text, 0..) |byte, i| std.mem.writeInt(if (Reader.width == 2) u16 else u32, bytes[i * Reader.width ..][0..Reader.width], byte, if (actual == .utf16le or actual == .utf32le) .little else .big);
        var log: Recorder = .{};
        const result = try P.parse(std.testing.allocator, &bytes, &log, discard, .{ .encoding = actual });
        try equal(actual, result.source_info.encoding);
        try equal(dot.events.Outcome.invalid_syntax, result.outcome);
        var found = false;
        for (log.items()) |record| if (record == .event and record.event == .commit_node) {
            const span = record.event.commit_node.value.identifier;
            try equal(@as(u32, @intCast(std.mem.indexOf(u8, text, "after").? * Reader.width)), span.start);
            try equal(@as(u32, 5 * Reader.width), span.len);
            found = true;
        };
        try equal(actual, log.records[0].event.begin_document.source_info.encoding);
        try expect(found);
    }
}

test "public event recovery agrees across scanners on mutated input" {
    const Scalar = dot.Profile(.{ .policy = .{ .scanner = .scalar } }).Events(Recorder);
    const Block = dot.Profile(.{ .policy = .{ .scanner = .block } }).Events(Recorder);
    var random = std.Random.DefaultPrng.init(0xabe10);
    const alphabet = "{}[];:=><-/\"+ab /*\n";
    for (0..1000) |_| {
        var bytes: [input.len]u8 = undefined;
        @memcpy(&bytes, input);
        for (0..3) |_| bytes[random.random().uintLessThan(usize, bytes.len)] = alphabet[random.random().uintLessThan(usize, alphabet.len)];
        var first: Recorder = .{};
        var second: Recorder = .{};
        const a = Scalar.parse(std.testing.allocator, &bytes, &first, discard, .{});
        const b = Block.parse(std.testing.allocator, &bytes, &second, discard, .{});
        try std.testing.expectEqualDeep(a, b);
        try std.testing.expectEqualDeep(first.items(), second.items());
    }
}

test "scope and reference identities belong to the shared syntax stream" {
    const P = dot.Events(Recorder);
    const source = "digraph { a:p -> { b:q; { c:r; } } -> d:s; }";
    var log: Recorder = .{};
    try expect(P.parse(std.testing.allocator, source, &log, discard, .{}).outcome == .success);
    var scope_count: u32 = 0;
    var reference_count: u32 = 0;
    for (log.items()) |record| if (record == .event) switch (record.event) {
        .begin_scope => |scope| {
            scope_count += 1;
            try equal(scope_count, @intFromEnum(scope.id));
            try equal(if (scope_count == 1) @as(u32, 0) else 1, @intFromEnum(scope.parent));
            if (scope.role == .right) {
                try equal(@intFromEnum(scope.id), scope.edge.?.right_scope.?);
                try equal(scope.start, scope.edge.?.right);
                try equal(@as(?u32, 0), scope.edge.?.left_port);
            }
        },
        .ported_reference => |reference| {
            try equal(reference_count, @intFromEnum(reference.id));
            reference_count += 1;
        },
        .commit_edge_chain => |commit| {
            try equal(@as(u32, 0), commit.value.left_port.?);
            try equal(@as(u32, 1), commit.value.right_scope.?);
        },
        else => {},
    };
    try equal(@as(u32, 2), scope_count);
    try equal(@as(u32, 4), reference_count);
    try expect(dot.ScopeId == dot.events.ScopeId);
    try expect(P.FixedParseScratch(.{ .nesting = 1 }).byte_size < dot.FixedParseScratch(.{ .nesting = 1 }).byte_size);
}

test "shared events retain comment boundaries without statement ownership" {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .comments = true } } }).Events(Recorder);
    const source = "//before\ngraph { \"a\" /*join*/ + \"\"; /*body*/ b; }\n#after\n";
    var log: Recorder = .{};
    try expect(P.parse(std.testing.failing_allocator, source, &log, discard, .{}).outcome == .success);
    try expect(log.records[0].event == .comment);
    var count: u32 = 0;
    const expected = [_][]const u8{ "//before", "/*join*/", "/*body*/", "#after" };
    for (log.items()) |record| if (record == .event and record.event == .comment) {
        try std.testing.expectEqualStrings(expected[count], record.event.comment.raw(source));
        count += 1;
    };
    try equal(@as(u32, expected.len), count);
    try expect(log.records[log.len - 1].event == .end_document);
}

test "private scope continuations are not public event payloads" {
    const Consumer = struct {
        pub const ScopeContext = dot.events.ScopeId;
        current: ScopeContext = .root,
        suspended: ScopeContext = .root,
        entered: u32 = 0,
        restored: u32 = 0,
        pub fn onEvent(self: *@This(), value: dot.events.Event) error{WrongScope}!dot.events.Action {
            switch (value) {
                .begin_scope => |scope| {
                    if (scope.parent != self.current) return error.WrongScope;
                    self.suspended = self.current;
                    self.current = scope.id;
                    self.entered += 1;
                },
                .end_scope => |scope| if (scope.id != self.current) {
                    return error.WrongScope;
                },
                inline .commit_node, .commit_edge, .commit_edge_chain, .commit_subgraph, .commit_assignment, .commit_attribute_statement => |commit| if (commit.owner.scope != self.current) {
                    return error.WrongScope;
                },
                else => {},
            }
            return .proceed;
        }
        pub fn suspendScope(self: *@This()) ScopeContext {
            return self.suspended;
        }
        pub fn restoreScope(self: *@This(), saved: ScopeContext) void {
            self.current = saved;
            self.restored += 1;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    const P = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Events(Consumer);
    const source = "graph { { a; { b; } c; } { d; } }";
    for ([_]usize{ 1, 2, 7, 1024 }) |budget| {
        var frames: P.FixedParseScratch(.{ .nesting = 2 }) = .{};
        var consumer: Consumer = .{};
        var session = P.Session.init(source, frames.storage(), &consumer, discard, .{});
        defer session.deinit();
        while (session.result() == null) _ = session.advance(budget);
        try expect(session.result().?.outcome == .success);
        try equal(dot.events.ScopeId.root, consumer.current);
        try equal(@as(u32, 3), consumer.entered);
        try equal(consumer.entered, consumer.restored);
    }
}

test "unacknowledged scope entry aborts its parent statement without fabricated events" {
    const P = dot.Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Events(Recorder);
    const source = "graph { { a; } }";
    var frames: P.FixedParseScratch(.{ .nesting = 1 }) = .{};
    var log: Recorder = .{};
    var session = P.Session.init(source, frames.storage(), &log, discard, .{});
    defer session.deinit();
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        try expect(attempts < 100);
        const progress = session.advance(1);
        if (progress.phase == .dispatch and log.len == 2) break;
    }
    try expect(log.records[1].event == .begin_statement);
    try expect(session.cancel().outcome == .cancelled);
    try equal(dot.events.ScopeId.root, log.records[2].abort.statement.owner.scope);
    try equal(@as(u32, 4), log.len);
    log = .{ .stop_at = 3 };
    try expect(P.parse(std.testing.allocator, source, &log, discard, .{}).outcome == .event_stopped);
    try expect(log.records[2].event == .begin_scope);
    try equal(dot.events.ScopeId.root, log.records[3].abort.statement.owner.scope);
}

test "an error named EventStopped is still a consumer failure" {
    const Refuse = struct {
        pub fn onEvent(_: *@This(), _: dot.events.Event) error{EventStopped}!dot.events.Action {
            return error.EventStopped;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    var consumer: Refuse = .{};
    const result = dot.Events(Refuse).parse(std.testing.failing_allocator, "graph {}", &consumer, discard, .{});
    try equal(error.EventStopped, result.outcome.event_failure);
}

test "statement begin and output recovery are independent selections" {
    const Consumer = struct {
        pub const recover_statements = false;
        log: Recorder = .{},
        pub fn onEvent(self: *@This(), value: dot.events.Event) error{OutputFailure}!dot.events.Action {
            return self.log.onEvent(value);
        }
        pub fn onAbort(self: *@This(), value: dot.events.Abort) void {
            self.log.onAbort(value);
        }
    };
    var consumer: Consumer = .{};
    const result = dot.Events(Consumer).parse(std.testing.allocator, "graph { bad [x=]; later; other [x=]; }", &consumer, discard, .{});
    try expect(result.outcome == .invalid_syntax);
    try equal(dot.Completion.complete, result.completion);
    try equal(@as(u32, 2), result.syntax_errors);
    try equal(@as(u32, 4), consumer.log.len);
    try expect(consumer.log.records[1].event == .begin_statement);
    try expect(consumer.log.records[2].abort == .statement);
    try expect(consumer.log.records[3].abort == .document);
}
