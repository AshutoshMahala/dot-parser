const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;

const Request = struct {
    polls: usize = 0,
    stop_after: usize = std.math.maxInt(usize),
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const stop = self.polls >= self.stop_after;
        self.polls += 1;
        return stop;
    }
    fn hook(self: *@This()) dot.Cancellation {
        return .{ .context = self, .is_requested = poll };
    }
};

fn Storage(comptime is_markup: bool) type {
    return if (is_markup) markup.FixedDocumentStorage(.{ .nodes = 32, .attributes = 32 }) else dot.FixedDocumentStorage(.{
        .statements = 32,
        .nodes = 16,
        .edges = 8,
        .attributes = 32,
        .subgraphs = 8,
    });
}
fn Scratch(comptime is_markup: bool) type {
    return if (is_markup) markup.FixedParseScratch(16) else dot.FixedParseScratch(.{ .nesting = 16 });
}
fn policyFor(comptime api: type, comptime block: bool, comptime interval: u32) api.Policy {
    var p: api.Policy = .{
        .scanner = if (block) .block else .scalar,
        .retention = .{ .partial = true },
        .execution = .{ .metering = true, .cancellation = true, .cancellation_interval = interval },
    };
    if (api == markup) p.mode = .structural;
    return p;
}

fn partitions(comptime is_markup: bool, comptime block: bool, comptime interval: u32, comptime runtime: bool, source: []const u8) !void {
    const api = if (is_markup) markup else dot;
    const p = comptime policyFor(api, block, interval);
    const P = api.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) comptime policyFor(api, !block, 3) else p });
    const Reference = api.Profile(.{ .policy = comptime policyFor(api, block, 1) });
    var reference_storage: Storage(is_markup) = .{};
    var reference_scratch: Scratch(is_markup) = .{};
    var reference_bag: api.FixedDiagnosticBag(32) = .{};
    var reference = Reference.Session.init(source, .{ .document = reference_storage.storage(), .scratch = reference_scratch.storage() }, reference_bag.sink(), .{});
    defer reference.deinit();
    const whole = reference.advance(std.math.maxInt(u32));
    try expect(whole.outcome != null);

    for ([_][]const u32{ &.{std.math.maxInt(u32)}, &.{1}, &.{ 0, 2, 7, 1, 63 } }) |budgets| {
        var storage: Storage(is_markup) = .{};
        var scratch: Scratch(is_markup) = .{};
        var bag: api.FixedDiagnosticBag(32) = .{};
        var request: Request = .{};
        const options: (if (is_markup) P.Options else P.FixedParseOptions) = if (runtime) .{ .policy = p, .cancellation = request.hook() } else .{ .cancellation = request.hook() };
        const started = P.Session.init(source, .{ .document = storage.storage(), .scratch = scratch.storage() }, bag.sink(), options);
        var session = if (runtime) try started else started;
        defer session.deinit();
        var total: usize = 0;
        var calls: usize = 0;
        while (session.result() == null) : (calls += 1) {
            const budget = budgets[calls % budgets.len];
            const before = request.polls;
            const advancing = session.advance(budget);
            const progress = if (runtime) try advancing else advancing;
            try expect(progress.work_used <= budget);
            try expect(request.polls > before); // every entry, including zero
            try expect(request.polls - before <= progress.work_used / interval + 1);
            total += progress.work_used;
        }
        try equal(whole.work_used, total);
        try deep(reference.result().?, session.result().?);
        try deep(reference_bag.items(), bag.items());
        const polls = request.polls;
        _ = session.run();
        _ = session.cancel();
        const again = session.advance(0);
        if (runtime) _ = try again;
        try equal(polls, request.polls); // terminal results never repoll
    }
}

test "intervals preserve exact work totals, documents and diagnostics across partitions" {
    inline for (.{ false, true }) |is_markup| inline for (.{ false, true }) |block| inline for (.{ false, true }) |runtime| inline for (.{ 1, 4, 64, std.math.maxInt(u32) }) |interval| {
        const sources = if (is_markup) [_][]const u8{
            "<root a='1'><child/>text<!-- note --></root>",
            "<root><child bad=0/><other>&;</other></root>",
            "<root><server></servr><other/></root>",
            "<root a='unfinished",
        } else [_][]const u8{
            "graph { a[x=1]; { b; } a--c; }",
            "graph { a[x=]; b; c; }",
            "graph { a; /* note */ b[x=\"long\"+\"value\"]; }",
            "graph { a; b[x=\"unfinished",
        };
        for (sources) |source| try partitions(is_markup, block, interval, runtime, source);
    };
}

test "cancellation is bounded by the interval and checked on every resume" {
    inline for (.{ false, true }) |is_markup| inline for (.{ false, true }) |block| inline for (.{ false, true }) |runtime| inline for (.{ 1, 4, 64 }) |interval| {
        const api = if (is_markup) markup else dot;
        const p = comptime policyFor(api, block, interval);
        const P = api.Profile(.{ .runtime_policy = runtime, .policy = p });
        const source = if (is_markup) "<!--" ++ "x" ** 8192 ++ "--><a/>" else "graph{/*" ++ "x" ** 8192 ++ "*/a;}";
        var storage: Storage(is_markup) = .{};
        var scratch: Scratch(is_markup) = .{};
        var request: Request = .{ .stop_after = 1 };
        const started = P.Session.init(source, .{ .document = storage.storage(), .scratch = scratch.storage() }, api.diagnostic.discard, .{ .cancellation = request.hook() });
        var session = if (runtime) try started else started;
        defer session.deinit();
        const advancing = session.advance(std.math.maxInt(u32));
        const stopped = if (runtime) try advancing else advancing;
        try expect(stopped.outcome.? == .cancelled);
        try equal(@as(usize, interval), stopped.work_used);
        try equal(@as(usize, 2), request.polls);

        request = .{};
        const reset = session.reset(source, api.diagnostic.discard, .{ .cancellation = request.hook() });
        if (runtime) try reset;
        const one = session.advance(1);
        if (runtime) _ = try one;
        request.stop_after = request.polls;
        const zero = session.advance(0);
        const cancelled = if (runtime) try zero else zero;
        try expect(cancelled.outcome.? == .cancelled);
        try equal(@as(usize, 0), cancelled.work_used);
    };
}

test "DOT interval one cancellation matches an exact-budget pause at every phase" {
    inline for (.{ false, true }) |block| inline for (.{ false, true }) |runtime| {
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = comptime policyFor(dot, block, 1) });
        for ([_][]const u8{
            "digraph { a[x=1]; { b; } a->b; }",
            "graph { a[x=]; b; c; }",
            "graph { a; b[x=\"unfinished",
        }) |source| {
            var full_storage: Storage(false) = .{};
            var full_scratch: Scratch(false) = .{};
            const started = P.Session.init(source, .{ .document = full_storage.storage(), .scratch = full_scratch.storage() }, dot.diagnostic.discard, .{});
            var full = if (runtime) try started else started;
            defer full.deinit();
            const advancing = full.advance(std.math.maxInt(u32));
            const complete = if (runtime) try advancing else advancing;
            try expect(complete.outcome != null);

            // Cross lexical, grammar, event and recovery boundaries. A poll
            // requesting cancellation after N credits must observe precisely
            // the state obtained by advance(N), then explicit cancellation.
            for (0..complete.work_used + 1) |stop| {
                var expected_storage: Storage(false) = .{};
                var expected_scratch: Scratch(false) = .{};
                var expected_bag: dot.FixedDiagnosticBag(32) = .{};
                const expected_start = P.Session.init(source, .{ .document = expected_storage.storage(), .scratch = expected_scratch.storage() }, expected_bag.sink(), .{});
                var expected = if (runtime) try expected_start else expected_start;
                defer expected.deinit();
                const paused = expected.advance(stop);
                if (runtime) _ = try paused;
                const expected_result = expected.cancel();

                var actual_storage: Storage(false) = .{};
                var actual_scratch: Scratch(false) = .{};
                var actual_bag: dot.FixedDiagnosticBag(32) = .{};
                var request: Request = .{ .stop_after = stop };
                const actual_start = P.Session.init(source, .{ .document = actual_storage.storage(), .scratch = actual_scratch.storage() }, actual_bag.sink(), .{ .cancellation = request.hook() });
                var actual = if (runtime) try actual_start else actual_start;
                defer actual.deinit();
                const running = actual.advance(std.math.maxInt(u32));
                const stopped = if (runtime) try running else running;
                try equal(stop, stopped.work_used);
                try deep(expected_result, actual.result().?);
                try deep(expected_bag.items(), actual_bag.items());
                // A concrete terminal outcome wins at the last credit; no
                // final poll may replace it with cancellation.
                try equal(stop + @intFromBool(stop < complete.work_used), request.polls);
            }
        }
    };
}

test "invalid intervals reject before work and resets preserve the existing session" {
    inline for (.{ dot, markup }) |api| {
        const P = api.Profile(.{ .runtime_policy = true, .policy = comptime policyFor(api, false, 4) });
        const invalid: api.Policy = .{ .execution = .{ .cancellation_interval = 0 } };
        try expect(P.validatePolicy(invalid) == .invalid);
        try std.testing.expectError(error.InvalidCancellationInterval, P.Policies.prepare(.{ .policy = invalid }));
        const source = if (api == markup) "<a/>" else "graph{a;}";
        var storage: Storage(api == markup) = .{};
        var scratch: Scratch(api == markup) = .{};
        const memory: api.ParseMemory = .{ .document = storage.storage(), .scratch = scratch.storage() };
        var request: Request = .{};
        const options: (if (api == markup) P.Options else P.FixedParseOptions) = .{ .policy = invalid, .cancellation = request.hook() };
        try std.testing.expectError(error.InvalidCancellationInterval, P.parseBorrowed(std.testing.failing_allocator, source, api.diagnostic.discard, .{ .policy = invalid, .cancellation = request.hook() }));
        try std.testing.expectError(error.InvalidCancellationInterval, P.measureIn(source, scratch.storage(), api.diagnostic.discard, options));
        try std.testing.expectError(error.InvalidCancellationInterval, P.Session.init(source, memory, api.diagnostic.discard, options));
        try equal(@as(usize, 0), request.polls);
        var session = try P.Session.init(source, memory, api.diagnostic.discard, .{});
        defer session.deinit();
        _ = try session.advance(1);
        try std.testing.expectError(error.InvalidCancellationInterval, session.reset("", api.diagnostic.discard, options));
        try expect(session.run().outcome == .success);
        try equal(@as(usize, 0), request.polls);
        const prepared = try P.Policies.prepare(.{});
        try equal(@as(u32, 4), prepared.execution.cancellation_interval);
        const standard = try P.Policies.prepare(.{ .policy = api.presets.standard });
        try equal(@as(u32, 1), standard.execution.cancellation_interval);
    }
}

test "event-only DOT uses the same polling interval and exact budget" {
    const Sink = struct {
        pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |block| {
        const P = dot.Profile(.{ .runtime_policy = runtime, .policy = comptime policyFor(dot, block, 64) }).Events(Sink);
        var sink: Sink = .{};
        var request: Request = .{ .stop_after = 1 };
        const started = P.Session.init("graph{/*" ++ "x" ** 8192 ++ "*/a;}", .{}, &sink, dot.diagnostic.discard, .{ .cancellation = request.hook() });
        var session = if (runtime) try started else started;
        defer session.deinit();
        const advancing = session.advance(1000);
        const progress = if (runtime) try advancing else advancing;
        try equal(@as(usize, 64), progress.work_used);
        try expect(progress.result.?.outcome == .cancelled);
        try equal(@as(usize, 2), request.polls);
    };
}

test "DOT runtime reset switches between one-credit and batched drivers" {
    const Sink = struct {
        pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
            return .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    const P = dot.Profile(.{ .runtime_policy = true, .policy = comptime policyFor(dot, false, 1) });
    inline for (.{ false, true }) |event_only| {
        const API = if (event_only) P.Events(Sink) else P;
        const source = "graph{/*" ++ "x" ** 8192 ++ "*/a;}";
        var storage: Storage(false) = .{};
        var sink: Sink = .{};
        var session = if (event_only)
            try API.Session.init(source, .{}, &sink, dot.diagnostic.discard, .{})
        else
            try API.Session.init(source, .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
        defer session.deinit();
        for ([_]u32{ 4, 1, 64, 1 }) |interval| for ([_]dot.ScannerBackend{ .scalar, .block }) |backend| {
            var request: Request = .{ .stop_after = 1 };
            const patch: dot.Policy = .{ .scanner = backend, .execution = .{ .cancellation_interval = interval } };
            if (event_only)
                try session.reset(source, &sink, dot.diagnostic.discard, .{ .policy = patch, .cancellation = request.hook() })
            else
                try session.reset(source, dot.diagnostic.discard, .{ .policy = patch, .cancellation = request.hook() });
            const progress = try session.advance(1000);
            try equal(@as(usize, interval), progress.work_used);
            try equal(@as(usize, 2), request.polls);
            if (event_only) try expect(progress.result.?.outcome == .cancelled) else try expect(progress.outcome.? == .cancelled);
        };
    }
}

test "native one-shot readers carry fixed and runtime cancellation intervals" {
    inline for (.{ dot, markup }) |api| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |block| inline for (.{ .utf16le, .utf32be }) |actual| inline for (.{ 1, 16 }) |interval| {
        const width = if (actual == .utf16le) 2 else 4;
        const source = if (api == markup) "<!--" ++ "x" ** 8192 ++ "-->" else "graph{/*" ++ "x" ** 8192 ++ "*/a;}";
        var bytes: [source.len * width]u8 = undefined;
        for (source, 0..) |byte, i| {
            if (width == 2) std.mem.writeInt(u16, bytes[i * width ..][0..2], byte, .little) else std.mem.writeInt(u32, bytes[i * width ..][0..4], byte, .big);
        }
        const P = api.Profile(.{ .runtime_policy = runtime, .source_encodings = &.{ .utf16, .utf32 }, .policy = comptime policyFor(api, block, interval) });
        var request: Request = .{ .stop_after = 2 }; // native admission, parse entry, then interval
        const measured = try P.measureIn(&bytes, .{}, api.diagnostic.discard, if (runtime)
            .{ .encoding = actual, .policy = .{ .execution = .{ .cancellation_interval = interval } }, .cancellation = request.hook() }
        else
            .{ .encoding = actual, .cancellation = request.hook() });
        try expect(measured.outcome == .cancelled);
        try equal(@as(usize, 3), request.polls);
        if (runtime) {
            try std.testing.expectError(error.InvalidCancellationInterval, P.measureIn(&bytes, .{}, api.diagnostic.discard, .{ .encoding = actual, .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
        }
    };
}
