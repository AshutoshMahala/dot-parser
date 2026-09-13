const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const Storage = dot.FixedDocumentStorage(.{ .statements = 32, .nodes = 16, .edges = 16, .attributes = 32, .assignments = 16, .attribute_statements = 16 });

const Request = struct {
    flag: bool = false,
    polls: usize = 0,
    stop_after: usize = std.math.maxInt(usize),
    fn hook(self: *@This()) dot.Cancellation {
        return .{ .context = self, .is_requested = poll };
    }
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const stop = self.flag or self.polls >= self.stop_after;
        self.polls += 1;
        return stop;
    }
};

fn partition(source: []const u8, budgets: []const usize, comptime cancellable: bool) !usize {
    var expected_storage: Storage = .{};
    var expected_bag: dot.FixedDiagnosticBag(4) = .{};
    const expected = dot.parseBorrowedIn(source, expected_storage.storage(), expected_bag.sink(), .{});
    var storage: Storage = .{};
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var request: Request = .{};
    const Session = dot.FixedSession(.{ .cancellation = cancellable });
    var session = Session.init(source, storage.storage(), bag.sink(), .{ .cancellation = if (cancellable) request.hook() else {} });
    defer session.deinit();
    var total: usize = 0;
    var calls: usize = 0;
    var frontier: usize = 0;
    var last = session.advance(0);
    try expect(last.outcome == null);
    while (true) : (calls += 1) {
        try expect(calls < 16 * source.len + 64);
        const budget = budgets[calls % budgets.len];
        const polls = request.polls;
        const progress = session.advance(budget);
        try expect(progress.work_used <= budget);
        if (cancellable) try expect(request.polls - polls <= progress.work_used + 1);
        try expect(progress.source_frontier >= frontier and progress.source_frontier <= source.len);
        if (budget == 0) {
            last.work_used = 0;
            try deep(last, progress);
        }
        total += progress.work_used;
        frontier = progress.source_frontier;
        last = progress;
        if (progress.outcome != null) break;
        try expect(session.result() == null);
    }
    const result = session.result().?;
    try deep(expected, result);
    try deep(expected_bag.items(), bag.items());
    try equal(dot.ExecutionPhase.terminal, last.phase);
    const polls = request.polls;
    request.flag = true;
    inline for (.{ 0, 1, std.math.maxInt(usize) }) |budget| {
        const again = session.advance(budget);
        try equal(@as(usize, 0), again.work_used);
        try deep(result, session.result().?);
    }
    try deep(result, session.run());
    try deep(result, session.cancel());
    try equal(polls, request.polls);
    return total;
}

test "fixed sessions preserve documents diagnostics and work across partitions" {
    const sources = [_][]const u8{
        "graph{}",
        "strict digraph \"g\" { a[x=1][y=2] node[] z=3 a->b[w=\"v\"+\"x\"] }",
        "#pre\r\n graph {-.5 -- \"b\\\"c\" /*tail*/}",
        "graph { a[x=] }",
        "graph {a b @}",
        "graph {a--b--c}",
        "graph { subgraph{} }",
        "graph{/*",
        "",
    };
    for (sources) |source| {
        const total = try partition(source, &.{std.math.maxInt(usize)}, false);
        inline for (.{ false, true }) |cancellable| {
            try equal(total, try partition(source, &.{1}, cancellable));
            try equal(total, try partition(source, &.{ 0, 2, 7, 1 }, cancellable));
        }
    }
    const source = "graph { a[k=\"x\"/*glue*/+\"y\"] b--c; key=-.5 }";
    for (0..source.len + 1) |end| _ = try partition(source[0..end], &.{ 0, 1, 3 }, true);
}

test "cancellation at every work boundary exposes no partial document" {
    const source = "graph { a[k=\"x\"/*glue*/+\"y\"] b--c key=-.5 }";
    const total = try partition(source, &.{1}, false);
    for (0..total) |stop| {
        var storage: Storage = .{};
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var request: Request = .{ .stop_after = stop };
        var session = dot.FixedSession(.{ .cancellation = true }).init(source, storage.storage(), bag.sink(), .{ .cancellation = request.hook() });
        const progress = session.advance(std.math.maxInt(usize));
        try equal(stop, progress.work_used);
        try expect(progress.outcome.? == .cancelled);
        try expect(session.result().?.document == null);
        try equal(@as(usize, 0), bag.items().len);
        try equal(stop + 1, request.polls);
        session.deinit();
        try equal(stop + 1, request.polls);
    }
}

test "zero-budget cancellation cleanup and reset reuse caller pools" {
    var storage: Storage = .{};
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var request: Request = .{};
    const Session = dot.FixedSession(.{ .cancellation = true });
    var session = Session.init("graph {a[x=1]}", storage.storage(), bag.sink(), .{ .cancellation = request.hook() });
    while (session.advance(1).completed_pairs == 0) {}
    try expect(session.result() == null);
    request.flag = true;
    const cancelled = session.advance(0);
    try equal(@as(usize, 0), cancelled.work_used);
    try expect(cancelled.outcome.? == .cancelled);
    try equal(@as(usize, 0), bag.items().len);
    session.reset("graph {ok}", bag.sink(), .{});
    const result = session.run();
    try expect(result.outcome == .success);
    try equal(@as(usize, 1), result.document.?.nodes.len);
    try expect(result.document.?.nodes.ptr == &storage.nodes);
    // Reset also terminates an abandoned, yielded parse before reusing pools.
    session.reset("graph { a[x=1] }", bag.sink(), .{});
    while (session.advance(1).completed_pairs == 0) {}
    session.reset("graph{}", bag.sink(), .{});
    try equal(@as(usize, 0), session.run().document.?.statementCount());
}

test "session supports movement between calls and explicit cleanup without hooks" {
    var storage: Storage = .{};
    var session = dot.BoundedSession.init("graph {a[x=1]}", storage.storage(), dot.diagnostic.discard, .{});
    _ = session.advance(12);
    var moved = session;
    session = undefined; // Ownership is transferred, not duplicated.
    try expect(moved.run().outcome == .success);
    moved.deinit();
    try expect(moved.result().?.outcome == .success);
    moved.reset("graph {a[x=1]}", dot.diagnostic.discard, .{});
    while (moved.advance(1).completed_pairs == 0) {}
    moved.deinit();
    try expect(moved.result().?.outcome == .cancelled);
    try expect(moved.result().?.document == null);
}

test "metering and cancellation are independently selectable" {
    inline for (.{ false, true }) |metering| inline for (.{ false, true }) |cancellation| {
        const Session = dot.FixedSession(.{ .metering = metering, .cancellation = cancellation });
        var storage: Storage = .{};
        var request: Request = .{ .stop_after = 12 };
        var session = Session.init("graph { a[x=1] }", storage.storage(), dot.diagnostic.discard, .{
            .cancellation = if (cancellation) request.hook() else {},
        });
        const result = session.run();
        try expect(result.outcome == (if (cancellation) .cancelled else .success));
        const Driver = @FieldType(Session, "machine");
        if (!cancellation) try expect(@FieldType(Driver, "cancellation") == void);
        if (!metering) {
            try expect(@FieldType(@FieldType(Driver, "tokens"), "source_frontier") == void);
            if (!cancellation) try expect(@FieldType(Driver, "work") == void);
        }
    };
}

test "fixed-pool failure after yield emits once and wins over late cancellation" {
    const Reject = struct {
        request: *Request,
        count: usize = 0,
        fn emit(context: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            self.request.flag = true;
            return error.DiagnosticSinkFailure;
        }
    };
    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .nodes = 1 }) = .{};
    var request: Request = .{};
    var reject: Reject = .{ .request = &request };
    var session = dot.FixedSession(.{ .cancellation = true }).init("graph {a b}", storage.storage(), .{ .context = &reject, .emit_fn = Reject.emit }, .{ .cancellation = request.hook() });
    while (session.advance(1).outcome == null) {}
    const result = session.result().?;
    try expect(result.outcome == .storage_failure);
    try equal(dot.StorageFailure.pool_exhausted, result.outcome.storage_failure);
    try equal(dot.diagnostic.Delivery.failed, result.diagnostic_delivery);
    try expect(result.document == null);
    try equal(@as(usize, 1), reject.count);
    _ = session.advance(1);
    try equal(@as(usize, 1), reject.count);
    try deep(result, session.cancel());
}

test "statement and attribute limits stay distinct from per-call budgets" {
    inline for (.{ dot.BoundedSession.Options{ .max_statements = 0 }, dot.BoundedSession.Options{ .max_attributes = 0 } }) |options| {
        var storage: Storage = .{};
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var session = dot.BoundedSession.init("graph {a[x=1]}", storage.storage(), bag.sink(), options);
        while (session.advance(1).outcome == null) {}
        try expect(session.result().?.outcome == .resource_exhausted);
        try expect(session.result().?.document == null);
        try equal(@as(usize, 1), bag.items().len);
    }
}

test "long lexical scans yield and cancel without allocating parser storage" {
    const n = 1024 * 1024;
    const bytes = try std.testing.allocator.alloc(u8, n + 32);
    defer std.testing.allocator.free(bytes); // Caller-owned input, not session allocation.
    const cases = .{
        .{ "graph {/*", "*/}", 'a' },
        .{ "graph {a[x=\"", "\"]}", 'a' },
        .{ "graph {", "}", 'a' },
        .{ "graph {", "}", ' ' },
    };
    inline for (cases) |parts| {
        @memcpy(bytes[0..parts[0].len], parts[0]);
        @memset(bytes[parts[0].len..][0..n], parts[2]);
        @memcpy(bytes[parts[0].len + n ..][0..parts[1].len], parts[1]);
        const source = bytes[0 .. parts[0].len + n + parts[1].len];
        var storage: Storage = .{};
        var request: Request = .{};
        var session = dot.FixedSession(.{ .cancellation = true }).init(source, storage.storage(), dot.diagnostic.discard, .{ .cancellation = request.hook() });
        const yielded = session.advance(64);
        try expect(yielded.outcome == null);
        try expect(yielded.source_frontier <= 64);
        request.flag = true;
        try expect(session.advance(0).outcome.? == .cancelled);
        session.reset(source, dot.diagnostic.discard, .{});
        var total: usize = 0;
        while (true) {
            const progress = session.advance(257);
            total += progress.work_used;
            try expect(progress.work_used <= 257);
            if (progress.outcome) |outcome| {
                try expect(outcome == .success);
                break;
            }
        }
        try expect(total < 2 * source.len + 64);
    }
}
