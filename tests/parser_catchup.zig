const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "failed bounded operand traversal leaves the next operand intact" {
    const source = "\"a\\q\" /* gap */ + <b> + \"c\"";
    const Work = struct {
        remaining: u64,
        pub fn spend(self: *@This(), n: u64) error{Stopped}!void {
            if (n > self.remaining) return error.Stopped;
            self.remaining -= n;
        }
    };
    var reference = try dot.identifier.parts(source, .{ .start = 0, .len = source.len });
    while (true) {
        const before = reference;
        const expected = reference.next() orelse break;
        for (0..100) |grant| {
            var parts = before;
            var work: Work = .{ .remaining = grant };
            const actual = parts.nextWith(&work) catch {
                try equal(before.offset, parts.offset);
                try std.testing.expectEqualDeep(expected, parts.next().?);
                continue;
            };
            try std.testing.expectEqualDeep(expected, actual.?);
        }
    }
}

test "cancellation after a root closer retains that consumed delimiter" {
    const source = "graph {a}";
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true }, .execution = .{ .metering = true } } });
    var saw_closed = false;
    for (1..60) |budget| {
        var storage: dot.FixedDocumentStorage(.{ .statements = 1, .nodes = 1 }) = .{};
        var session = P.Session.init(source, .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
        defer session.deinit();
        const p = session.advance(budget);
        if (p.outcome != null) continue;
        const result = session.cancel();
        if (result.document) |doc| if (doc.root_closed) {
            saw_closed = true;
            try equal(@as(u32, source.len), doc.retained_end);
            try expect(doc.unrepresented() == null);
        };
    }
    try expect(saw_closed);
}

test "undirected edges preserve adjacent negative numeral endpoints" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |lenient| {
        comptime var policy = if (lenient) dot.presets.lenient else dot.presets.standard;
        policy.scanner = scanner;
        policy.execution = .{ .metering = true };
        const P = dot.Profile(.{ .policy = policy });
        for ([_][]const u8{ "-1", "-.5", "-1.5" }) |name| for ([_]usize{ 0, 58, 59, 60, 61, 62, 63, 64 }) |padding| {
            var bytes: [160]u8 = undefined;
            @memset(bytes[0..padding], ' ');
            const tail = try std.fmt.bufPrint(bytes[padding..], "graph {{ a--{s} }}", .{name});
            const source = bytes[0 .. padding + tail.len];
            var storage: dot.FixedDocumentStorage(.{ .statements = 1, .edges = 1 }) = .{};
            var bag: dot.FixedDiagnosticBag(4) = .{};
            var session = P.Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{});
            defer session.deinit();
            while (session.result() == null) try expect(session.advance(1).work_used <= 1);
            const result = session.result().?;
            try expect(result.outcome == .success);
            try equal(@as(usize, 0), bag.items().len);
            const doc = &result.document.?;
            try std.testing.expectEqualStrings(name, doc.text(doc.nodeReference(doc.edges[0].right).?.identifier));
        };
    };
}

test "parser hooks may cancel their own session without returning true" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ 1, 4 }) |interval| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval } } });
        const Stop = struct {
            session: ?*P.Session = null,
            calls: usize = 0,
            at: usize,
            fn poll(raw: ?*anyopaque) bool {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.calls += 1;
                if (self.calls == self.at) if (self.session) |session| {
                    _ = session.cancel();
                };
                return false;
            }
        };
        for (1..32) |at| {
            var storage: dot.FixedDocumentStorage(.{ .statements = 3, .nodes = 2, .edges = 1 }) = .{};
            var stop: Stop = .{ .at = at };
            var session = P.Session.init("graph { a; b; a--b; }", .{ .document = storage.storage() }, dot.diagnostic.discard, .{ .cancellation = .{ .context = &stop, .is_requested = Stop.poll } });
            defer session.deinit();
            stop.session = &session;
            while (session.result() == null) try expect(session.advance(3).work_used <= 3);
            if (stop.calls >= at) try expect(session.result().?.outcome == .cancelled);
            const calls = stop.calls;
            try equal(@as(usize, 0), session.advance(10).work_used);
            try equal(calls, stop.calls);
        }
    };
}

test "cancel preserves a numeral finding queued behind a token preview" {
    const Sink = struct {
        pub const observations: dot.events.Observations = .{ .token_preview = true };
        pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    inline for (.{ .warning, .err }) |severity| inline for (.{ .collect, .fail_fast }) |on_error| {
        const P = dot.Profile(.{ .policy = .{ .scanner = .scalar, .validation = .{ .ambiguous_numeral = severity }, .on_error = on_error, .execution = .{ .metering = true } } }).Events(Sink);
        const source = "graph { a[x=2px] }";
        const boundary = std.mem.indexOf(u8, source, "px").? + 1;
        var sink: Sink = .{};
        var bag: dot.FixedDiagnosticBag(8) = .{};
        var session = P.Session.init(source, .{}, &sink, bag.sink(), .{});
        defer session.deinit();
        var stopped = false;
        while (session.result() == null) {
            const progress = session.advance(1);
            try expect(progress.work_used <= 1);
            if (progress.phase == .dispatch and progress.source_frontier == boundary and bag.items().len == 0) {
                _ = session.cancel();
                stopped = true;
                break;
            }
        }
        try expect(stopped);
        try equal(@as(usize, 1), bag.items().len);
        try equal(if (severity == .err) dot.Code.syntax_ambiguous_numeral_rejected else dot.Code.syntax_ambiguous_numeral, bag.items()[0].code);
        try expect(session.result().?.outcome == if (severity == .err and on_error == .fail_fast) .invalid_syntax else .cancelled);
    };
}
