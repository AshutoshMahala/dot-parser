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

test "native one-shot readers carry fixed and runtime cancellation intervals" {
    inline for (.{ dot, markup }) |api| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |block| inline for (.{ .utf16le, .utf32be }) |actual| {
        const width = if (actual == .utf16le) 2 else 4;
        const source = if (api == markup) "<!--" ++ "x" ** 8192 ++ "-->" else "graph{/*" ++ "x" ** 8192 ++ "*/a;}";
        var bytes: [source.len * width]u8 = undefined;
        for (source, 0..) |byte, i| {
            if (width == 2) std.mem.writeInt(u16, bytes[i * width ..][0..2], byte, .little) else std.mem.writeInt(u32, bytes[i * width ..][0..4], byte, .big);
        }
        const P = api.Profile(.{ .runtime_policy = runtime, .source_encodings = &.{ .utf16, .utf32 }, .policy = comptime policyFor(api, block, 4) });
        var request: Request = .{ .stop_after = 2 }; // native admission, parse entry, then interval
        const measured = try P.measureIn(&bytes, .{}, api.diagnostic.discard, if (runtime)
            .{ .encoding = actual, .policy = .{ .execution = .{ .cancellation_interval = 16 } }, .cancellation = request.hook() }
        else
            .{ .encoding = actual, .cancellation = request.hook() });
        try expect(measured.outcome == .cancelled);
        try equal(@as(usize, 3), request.polls);
        if (runtime) {
            try std.testing.expectError(error.InvalidCancellationInterval, P.measureIn(&bytes, .{}, api.diagnostic.discard, .{ .encoding = actual, .policy = .{ .execution = .{ .cancellation_interval = 0 } } }));
        }
    };
}
