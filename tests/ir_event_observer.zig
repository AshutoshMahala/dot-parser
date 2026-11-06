const std = @import("std");
const dot = @import("dot_parser");
const a = std.testing.allocator;
const IR = dot.ir.Lowering(.{});
const Dot = dot.Profile(.{});
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const expect = std.testing.expect;
const Record = union(enum) { event: dot.events.Event, abort: dot.events.Abort, save: u32, restore: u32 };
const Selection = struct {
    begin: bool = true,
    recovery: bool = true,
    observations: dot.events.Observations = .all,
    extents: bool = true,
};
fn Recorder(comptime selection: Selection) type {
    return struct {
        pub const wants_begin_statement = selection.begin;
        pub const recover_statements = selection.recovery;
        pub const observations = selection.observations;
        pub const statement_extents = selection.extents;
        pub const coverage = true;
        pub const ScopeContext = u32;
        pub const Error = error{ ObserverFailure, OutOfMemory, ValidationStopped, Cancelled };
        records: [512]Record = undefined,
        len: u32 = 0,
        deliveries: u32 = 0,
        stop_at: ?u32 = null,
        fail_at: ?u32 = null,
        failure: Error = error.ObserverFailure,
        context: u32 = 0,

        fn append(self: *@This(), record: Record) void {
            self.records[self.len] = record;
            self.len += 1;
        }
        pub fn onEvent(self: *@This(), event: dot.events.Event) Error!dot.events.Action {
            self.append(.{ .event = event });
            self.deliveries += 1;
            if (event == .begin_scope) self.context = @backingInt(event.begin_scope.id);
            if (self.deliveries == self.fail_at) return self.failure;
            return if (self.deliveries == self.stop_at) .stop else .proceed;
        }
        pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
            self.append(.{ .abort = abort });
        }
        pub fn suspendScope(self: *@This()) u32 {
            self.append(.{ .save = self.context });
            return self.context;
        }
        pub fn restoreScope(self: *@This(), context: u32) void {
            self.append(.{ .restore = context });
            self.context = context;
        }
        fn items(self: *const @This()) []const Record {
            return self.records[0..self.len];
        }
    };
}

fn parity(comptime P: type, comptime R: type, source: []const u8, options: P.Events(R).ParseOptions) !void {
    var standalone: R = .{};
    var observed: R = .{};
    const call = P.Events(R).parse(a, source, &standalone, dot.diagnostic.discard, options);
    const expected = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
    const Lower = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 } });
    var result = try Lower.FromEvents(P).Observe(R).parse(a, source, .{ .observer = &observed, .dot = options });
    defer result.deinit();
    try deep(standalone.items(), observed.items());
    try equal(expected.completion, result.checking.completion);
    try equal(expected.syntax_errors, result.checking.syntax_errors);
    try deep(expected.coverage, result.checking.coverage);
    try equal(expected.outcome == .success, result.ir() != null);
}

test "event IR observers match standalone selection, extents, recovery and scope context" {
    const inputs = [_][]const u8{
        "digraph G { a:p:n[x=y][]; a->b->c; subgraph s{d; {e}}; x=y; edge[color=red]; }",
        "// before\ndigraph G { /* inside */ a; # line\nb; } // after\n",
        "digraph G { a [label=; b; }",
        "digraph { a->subgraph s{b; bad[x=];c} -> {d}; e; }",
        "digraph { a[x=] { q [ ] }; b; subgraph s{c} bad[x= }",
        "digraph {a; b[label=\"unfinished",
        "digraph {a; /* unfinished",
        "digraph {a; b->}",
        "digraph",
        "digraph \"unfinished",
        "",
    };
    inline for (.{ .scalar, .block }) |scanner| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .retention = .{ .comments = true } } });
        inline for (.{ Selection{}, Selection{ .begin = false }, Selection{ .recovery = false }, Selection{ .begin = false, .recovery = false, .observations = .{ .delimiter = true } }, Selection{ .begin = false, .recovery = false, .observations = .none, .extents = false } }) |selection| {
            for (inputs) |source| try parity(P, Recorder(selection), source, .{});
            const truncated = inputs[0];
            for (0..truncated.len) |end| try parity(P, Recorder(selection), truncated[0..end], .{});
        }
    }
}

test "event IR observer native spans, runtime policies, metering and fail fast match DOT" {
    const R = Recorder(.{});
    const text = "digraph G{a:p[x=y];subgraph s{b} a[x=];c;}";
    inline for (.{ .collect, .fail_fast }) |on_error| {
        const P = dot.Profile(.{ .source_encodings = &.{ .utf8, .utf16, .utf32 }, .policy = .{
            .execution = .{ .metering = true },
            .on_error = on_error,
        } });
        inline for (.{ .utf8, .utf16le, .utf16be, .utf32le, .utf32be }) |encoding| {
            const width = switch (encoding) {
                .utf8 => 1,
                .utf16le, .utf16be => 2,
                else => 4,
            };
            var bytes: [text.len * width]u8 = @splat(0);
            const big = encoding == .utf16be or encoding == .utf32be;
            for (text, 0..) |byte, i| bytes[i * width + (if (big) width - 1 else 0)] = byte;
            try parity(P, R, &bytes, .{ .encoding = encoding });
        }
        inline for (.{ .scalar, .block }) |scanner| try parity(dot.Profile(.{ .runtime_policy = true }), R, text, .{
            .policy = .{ .scanner = scanner, .execution = .{ .metering = true }, .on_error = on_error },
        });
    }
}

test "event IR observer stop and typed failures preserve every standalone callback prefix" {
    const source = "digraph G { a:p[x=y]; subgraph s{ b->c; } a->d; }";
    const R = Recorder(.{});
    const E = IR.FromEvents(Dot).Observe(R);
    var complete: R = .{};
    _ = Dot.Events(R).parse(a, source, &complete, dot.diagnostic.discard, .{});
    for (1..complete.deliveries + 1) |at| inline for (.{ false, true }) |fail| {
        var standalone: R = .{ .stop_at = if (fail) null else @intCast(at), .fail_at = if (fail) @intCast(at) else null };
        var observed = standalone;
        _ = Dot.Events(R).parse(a, source, &standalone, dot.diagnostic.discard, .{});
        try std.testing.expectError(if (fail) error.ObserverFailure else error.ObserverStopped, E.parse(a, source, .{ .observer = &observed }));
        try deep(standalone.items(), observed.items());
    };
    inline for (.{ error.OutOfMemory, error.ValidationStopped, error.Cancelled }) |failure| {
        var observed: R = .{ .fail_at = 4, .failure = failure };
        try std.testing.expectError(failure, E.parse(a, source, .{ .observer = &observed }));
    }
    try expect(@typeInfo(E.Error).error_set.error_names != null);
    for (@typeInfo(IR.FromEvents(Dot).Error).error_set.error_names.?) |name| try expect(!std.mem.eql(u8, name, "ObserverStopped"));
}

test "event IR forwards commits before validation and resource work" {
    const R = Recorder(.{});
    const E = IR.FromEvents(dot.Profile(.{ .policy = .{ .on_error = .fail_fast } })).Observe(R);
    var observed: R = .{};
    var bag: dot.FixedDiagnosticBag(8) = .{};
    var result = try E.parse(a, "digraph { a--b; c; }", .{ .observer = &observed, .diagnostics = bag.sink() });
    defer result.deinit();
    try expect(result.ir() == null);
    try equal(.processor_stopped, result.checking.outcome);
    try equal(@as(usize, 1), bag.items().len);
    var committed = false;
    for (observed.items()) |record| if (record == .event and record.event == .commit_edge) {
        committed = true;
    };
    try expect(committed);

    observed = .{};
    try std.testing.expectError(error.NodeLimit, E.parse(a, "digraph {a}", .{ .observer = &observed, .lowering = .{ .limits = .{ .max_nodes = 0 } } }));
    committed = false;
    for (observed.items()) |record| if (record == .event and record.event == .commit_node) {
        committed = true;
    };
    try expect(committed);
}

test "event IR stopped observer wins over subsequent node-limit work" {
    const Stop = struct {
        pub fn onEvent(_: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            return if (event == .commit_node) .stop else .proceed;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    var observer: Stop = .{};
    try std.testing.expectError(error.ObserverStopped, IR.FromEvents(Dot).Observe(Stop).parse(a, "digraph{a}", .{
        .observer = &observer,
        .lowering = .{ .limits = .{ .max_nodes = 0 } },
    }));
}

const Quiet = struct {
    pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
        return .proceed;
    }
    pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
};
fn allocationProbe(allocator: std.mem.Allocator) !void {
    var observer: Quiet = .{};
    var result = try IR.FromEvents(Dot).Observe(Quiet).parse(allocator, "digraph{node[color=red];a:p->subgraph s{b;c};subgraph s{d};a->b[x=y]}", .{ .observer = &observer });
    defer result.deinit();
    if (result.checking.outcome == .storage_failure) return error.OutOfMemory;
    try expect(result.ir() != null);
}
test "event IR observer allocation cleanup and coverage without subscription" {
    try std.testing.checkAllAllocationFailures(a, allocationProbe, .{});
    var observer: Quiet = .{};
    var result = try IR.FromEvents(Dot).Observe(Quiet).parse(a, "digraph{}", .{ .observer = &observer });
    defer result.deinit();
    try equal(@as(u32, 9), result.checking.coverage.retained_end);
    try expect(result.checking.coverage.root_closed);
}

test "event IR observer cancellation after a callback ends delivery and keeps its observations" {
    const Cancelling = struct {
        log: Recorder(.{}) = .{},
        cancelled: bool = false,
        pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
            self.log.append(.{ .event = event });
            if (event == .commit_node) self.cancelled = true;
            return .proceed;
        }
        pub fn onAbort(self: *@This(), abort: dot.events.Abort) void {
            self.log.append(.{ .abort = abort });
        }
        fn requested(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.cancelled;
        }
    };
    inline for (.{ false, true }) |dot_cancellation| {
        const P = dot.Profile(.{ .policy = .{ .execution = .{ .cancellation = dot_cancellation, .metering = true } } });
        const L = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .cancellation = !dot_cancellation, .metering = true } } });
        var observer: Cancelling = .{};
        const hook: dot.Cancellation = .{ .context = &observer, .is_requested = Cancelling.requested };
        try std.testing.expectError(error.Cancelled, L.FromEvents(P).Observe(Cancelling).parse(a, "digraph{a;b}", .{
            .observer = &observer,
            .dot = .{ .cancellation = if (dot_cancellation) hook else {} },
            .lowering = .{ .cancellation = if (dot_cancellation) {} else hook },
        }));
        var commits: u32 = 0;
        var terminal = false;
        for (observer.log.items()) |record| switch (record) {
            .event => |event| {
                try expect(!terminal);
                if (event == .commit_node) commits += 1;
            },
            .abort => |abort| if (abort == .document) {
                try expect(!terminal);
                try equal(.sink_failure, abort.document);
                terminal = true;
            },
            else => unreachable,
        };
        try expect(terminal);
        try equal(@as(u32, 1), commits);
    }
}

test "event IR work limits never append an abort after successful observer termination" {
    const R = Recorder(.{});
    const E = IR.FromEvents(Dot).Observe(R);
    var success = false;
    var failed_after_end = false;
    for (0..300) |budget| {
        var observer: R = .{};
        const source = "digraph{a->b}";
        var result = E.parse(a, source, .{ .observer = &observer, .lowering = .{ .limits = .{ .max_work = budget } } }) catch |err| {
            try equal(error.WorkLimit, err);
            var ended = false;
            var started = false;
            var begun: [source.len]bool = @splat(false);
            for (observer.items()) |record| {
                try expect(!ended);
                switch (record) {
                    .event => |event| {
                        started = true;
                        if (event == .end_document) ended = true;
                        if (event == .begin_statement) begun[@backingInt(event.begin_statement.owner.statement)] = true;
                    },
                    .abort => |abort| {
                        try expect(started);
                        if (abort == .statement) try expect(begun[@backingInt(abort.statement.owner.statement)]);
                    },
                    else => {},
                }
            }
            failed_after_end = failed_after_end or ended;
            continue;
        };
        result.deinit();
        success = true;
        break;
    }
    try expect(success);
    try expect(failed_after_end);
}

test "event IR inferred and broad observer errors are preserved without classification by name" {
    const Inferred = struct {
        pub fn onEvent(_: *@This(), _: dot.events.Event) !dot.events.Action {
            return error.ApplicationFailure;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    const Broad = struct {
        pub fn onEvent(_: *@This(), _: dot.events.Event) anyerror!dot.events.Action {
            return error.ApplicationFailure;
        }
        pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
    };
    inline for (.{ Inferred, Broad }) |Observer| {
        const E = IR.FromEvents(Dot).Observe(Observer);
        try equal(Observer == Broad, @typeInfo(E.Error).error_set.error_names == null);
        var observer: Observer = .{};
        try std.testing.expectError(error.ApplicationFailure, E.parse(a, "digraph{}", .{ .observer = &observer }));
    }
}

fn partialParity(comptime P: type, comptime R: type, source: []const u8) !void {
    errdefer std.debug.print("partial observer input: {s}\n", .{source});
    var standalone: R = .{};
    var observed: R = .{};
    const call = P.Events(R).parse(a, source, &standalone, dot.diagnostic.discard, .{});
    _ = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
    var expected = try IR.FromEvents(P).parsePartial(a, source, .{});
    defer expected.deinit();
    var result = try IR.FromEvents(P).Observe(R).parsePartial(a, source, .{ .observer = &observed });
    defer result.deinit();
    try deep(standalone.items(), observed.items());
    try deep(expected.checking, result.checking);
    try equal(expected.ir() == null, result.ir() == null);
    if (expected.ir()) |graph| {
        try equal(graph.nodeCount(), result.ir().?.nodeCount());
        try deep(graph._coverage.entries.items, result.ir().?._coverage.entries.items);
        try deep(graph._data.connections, result.ir().?._data.connections);
    }
}
test "partial event IR observer recovery is independent of retained facts" {
    const inputs = [_][]const u8{
        "digraph G{a[label=;b;}",
        "digraph {; a;}",
        "digraph {; {a;} b;}",
        "digraph {a; bad@ {x} b;}",
        "digraph {a->subgraph s{b;bad[x=];c}->{d};e;}",
        "digraph {a->{b} ->; subgraph s{d} e;}",
        "digraph {a; b[label=\"unfinished",
        "digraph {a; /*unfinished",
        "digraph {a; b->}",
        "// before\ndigraph G{/*inside*/a;#line\nb[x=]; c;}//after",
        "digraph",
        "digraph \"unfinished",
        "",
    };
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ .collect, .fail_fast }) |on_error| {
        const P = dot.Profile(.{ .policy = .{ .scanner = scanner, .on_error = on_error, .retention = .{ .comments = true } } });
        inline for (.{ Selection{}, Selection{ .begin = false }, Selection{ .recovery = false }, Selection{ .begin = false, .recovery = false, .observations = .{ .delimiter = true } }, Selection{ .begin = false, .recovery = false, .observations = .none, .extents = false } }) |selection| {
            for (inputs) |source| try partialParity(P, Recorder(selection), source);
        }
    };
    const source = "digraph G{a:p->{b;bad[x=];c}->{d}[label=\"x\"];e}";
    for (0..source.len + 1) |end| try partialParity(Dot, Recorder(.{ .recovery = false }), source[0..end]);
    inline for (.{ .silent, .warning, .err }) |unsupported| {
        const P = dot.Profile(.{ .policy = .{ .markup = .none, .diagnostics = .{ .unsupported = unsupported } } });
        try partialParity(P, Recorder(.{ .recovery = false }), "digraph {a;<b>;c;}");
    }
}
test "partial event IR explicit observer stop and failure still stop construction" {
    const R = Recorder(.{ .recovery = false });
    const E = IR.FromEvents(Dot).Observe(R);
    const source = "digraph {a;bad[x=];b;}";
    var observer: R = .{ .stop_at = 4 };
    try std.testing.expectError(error.ObserverStopped, E.parsePartial(a, source, .{ .observer = &observer }));
    observer = .{ .fail_at = 4, .failure = error.Cancelled };
    try std.testing.expectError(error.Cancelled, E.parsePartial(a, source, .{ .observer = &observer }));
    observer = .{};
    var result = try E.parsePartial(a, source, .{ .observer = &observer });
    defer result.deinit();
    try expect((try result.ir().?.findNode("b")) == .known);
    try equal(dot.events.AbortReason.invalid_syntax, observer.items()[observer.len - 1].abort.document);
}

test "partial event IR later work failures never revive a terminated observer" {
    const R = Recorder(.{ .recovery = false });
    const E = IR.FromEvents(Dot).Observe(R);
    var success = false;
    for (0..512) |budget| {
        var observer: R = .{};
        var result = E.parsePartial(a, "digraph{a;bad[x=];b->c;}", .{ .observer = &observer, .lowering = .{ .limits = .{ .max_work = budget } } }) catch |err| {
            try equal(error.WorkLimit, err);
            var terminal = false;
            for (observer.items()) |record| {
                try expect(!terminal);
                if (record == .abort and record.abort == .document) terminal = true;
            }
            continue;
        };
        defer result.deinit();
        try expect(result.ir() != null);
        success = true;
        break;
    }
    try expect(success);
}
