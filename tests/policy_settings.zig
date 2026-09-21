const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const Runtime = dot.Profile(.{ .runtime_policy = true });
const Storage = dot.FixedDocumentStorage(.{ .statements = 16, .nodes = 16, .edges = 16, .attributes = 16, .subgraphs = 8, .scoped_edges = 8, .scoped_edge_links = 8, .edge_chains = 8, .edge_links = 16, .ported_references = 16, .assignments = 8, .attribute_statements = 8 });

const Request = struct {
    polls: usize = 0,
    stop: bool = false,
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.polls += 1;
        return self.stop;
    }
    fn hook(self: *@This()) dot.Cancellation {
        return .{ .context = self, .is_requested = poll };
    }
};

test "all scanner recovery and execution combinations agree at both binding times" {
    inline for (.{ .scalar, .block }) |scanner| {
        inline for (.{ .fail_fast, .statements }) |recovery| {
            inline for (.{ false, true }) |metering| {
                inline for (.{ false, true }) |cancellation| {
                    const input: dot.Policy = .{
                        .scanner = scanner,
                        .recovery = recovery,
                        .execution = .{ .metering = metering, .cancellation = cancellation },
                        .limits = .{ .max_statements = 5, .max_attributes = 2, .max_nesting = 1 },
                        .validation = .{ .graph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind } },
                    };
                    const Fixed = dot.Profile(.{ .policy = input });
                    for ([_][]const u8{
                        "graph {}",
                        "graph { a:p -> b:q -- c:r[x=1,y=2] }",
                        "graph { a; b; c; d; e; f; }",
                        "graph { a[x=1,y=2,z=3] }",
                        "graph { { { a } } }",
                        "graph { a[x=]; b[y=]; c -- d }",
                        "graph { a --> b; c - d; e }",
                        "graph { a[label=\"a\"+ /* comment */\"b\"]; café }",
                    }) |source| {
                        var fixed_bag: dot.FixedDiagnosticBag(16) = .{};
                        var dynamic_bag: dot.FixedDiagnosticBag(16) = .{};
                        var fixed_request: Request = .{};
                        var dynamic_request: Request = .{};
                        var fixed = Fixed.parseAndValidate(std.testing.allocator, source, fixed_bag.sink(), .{ .cancellation = if (cancellation) fixed_request.hook() else {} });
                        defer fixed.deinit(std.testing.allocator);
                        var dynamic = try Runtime.parseAndValidate(std.testing.allocator, source, dynamic_bag.sink(), .{ .policy = input, .cancellation = dynamic_request.hook() });
                        defer dynamic.deinit(std.testing.allocator);
                        try deep(fixed, dynamic);
                        try std.testing.expectEqualSlices(dot.Diagnostic, fixed_bag.items(), dynamic_bag.items());
                        try equal(fixed_request.polls, dynamic_request.polls);
                        if (!cancellation) try equal(@as(usize, 0), dynamic_request.polls);

                        const measured = Fixed.measure(std.testing.allocator, source, dot.diagnostic.discard, .{});
                        const dynamic_measured = try Runtime.measure(std.testing.allocator, source, dot.diagnostic.discard, .{ .policy = input });
                        try deep(measured, dynamic_measured);
                        try deep(fixed.outcome, measured.outcome);
                        var pools: Storage = .{};
                        var scratch: dot.FixedParseScratch(.{ .nesting = 8 }) = .{};
                        const fixed_counts = Fixed.measureIn(source, scratch.storage(), dot.diagnostic.discard, .{});
                        try deep(measured, fixed_counts);
                        try deep(measured, try Runtime.measureIn(source, scratch.storage(), dot.diagnostic.discard, .{ .policy = input }));
                        const retained = try Runtime.parseBorrowedIn(source, .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{ .policy = input });
                        try deep(fixed.document, retained.document);
                        try deep(fixed.outcome, retained.outcome);
                    }
                }
            }
        }
    }
}

test "runtime sessions latch policy through yields and switch all variants on reset" {
    const source = "graph { a -- b -> c[x=1]; { d } }";
    var pools: Storage = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 8 }) = .{};
    var request: Request = .{};
    var options: Runtime.FixedParseOptions = .{
        .policy = .{ .execution = .{ .metering = true }, .validation = .{ .graph = .{ .treated_as = .auto } } },
        .cancellation = request.hook(),
    };
    var session = try Runtime.Session.init(source, .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, options);
    defer session.deinit();
    try expect(session.validate(dot.diagnostic.discard) == null);
    try expect(session.interpretation() == null);
    try equal(@as(usize, 0), (try session.advance(0)).source_frontier);
    // The caller's input is not retained by reference.
    options.policy.validation.graph.treated_as = .undigraph;
    options.policy.limits.max_statements = 0;
    options.policy.execution.metering = false;
    while ((try session.advance(1)).outcome == null) {}
    try expect(session.validate(dot.diagnostic.discard).?.documentValid());
    try equal(dot.GraphKind.generic, session.result().?.document.?.effectiveKind(session.interpretation().?));

    for ([_]dot.ScannerBackend{ .scalar, .block }) |scanner| {
        for ([_]bool{ false, true }) |metering| {
            for ([_]bool{ false, true }) |cancellation| {
                request = .{};
                const input: dot.Policy = .{
                    .scanner = scanner,
                    .execution = .{ .metering = metering, .cancellation = cancellation },
                    .limits = .{ .max_statements = 1 },
                    .validation = .{ .graph = .{ .treated_as = .auto } },
                };
                try session.reset("graph { a -- b }", dot.diagnostic.discard, .{ .policy = input, .cancellation = request.hook() });
                if (metering) {
                    var progress = try session.advance(0);
                    try equal(@as(usize, 0), progress.work_used);
                    var i: usize = 0;
                    while (progress.outcome == null) : (i += 1) {
                        const budget = ([_]usize{ 1, 0, 3, 17 })[i % 4];
                        progress = try session.advance(budget);
                        try expect(progress.work_used <= budget);
                    }
                } else {
                    try std.testing.expectError(error.MeteringDisabled, session.advance(0));
                    try expect(session.result() == null);
                    _ = session.run();
                }
                const terminal = session.result().?;
                try expect(terminal.outcome == .success);
                try equal(dot.GraphKind.undigraph, terminal.document.?.effectiveKind(session.interpretation().?));
                try expect(session.validate(dot.diagnostic.discard).?.documentValid());
                const polls = request.polls;
                if (cancellation) try expect(polls > 0) else try equal(@as(usize, 0), polls);
                request.stop = true;
                try deep(terminal, session.run());
                try deep(terminal, session.cancel());
                try equal(polls, request.polls);
            }
        }
    }
}

test "fixed and runtime-baseline sessions have identical bounded progress and diagnostics" {
    inline for (.{ .scalar, .block }) |scanner| {
        inline for (.{ false, true }) |cancellable| {
            const input: dot.Policy = .{
                .scanner = scanner,
                .execution = .{ .metering = true, .cancellation = cancellable },
                .limits = .{ .max_statements = 4, .max_attributes = 2, .max_nesting = 2 },
                .recovery = .statements,
                .validation = .{ .graph = .{ .treated_as = .auto } },
            };
            const Fixed = dot.Profile(.{ .policy = input });
            const Dynamic = dot.Profile(.{ .policy = input, .runtime_policy = true });
            for ([_][]const u8{
                "graph {a -- b -> c[x=1]; {d}}",
                "graph {a[x=]; b[y=]; c -- d}",
                "graph {a[x=1,y=2,z=3]}",
                "graph {a; b; c; d; e}",
                "graph {{{{a}}}}",
            }) |source| {
                for ([_][]const usize{ &.{1}, &.{ 0, 1, 2, 31 } }) |budgets| {
                    var a_pools: Storage = .{};
                    var b_pools: Storage = .{};
                    var a_scratch: dot.FixedParseScratch(.{ .nesting = 4 }) = .{};
                    var b_scratch: dot.FixedParseScratch(.{ .nesting = 4 }) = .{};
                    var a_bag: dot.FixedDiagnosticBag(16) = .{};
                    var b_bag: dot.FixedDiagnosticBag(16) = .{};
                    var a_request: Request = .{};
                    var b_request: Request = .{};
                    var a = Fixed.Session.init(source, .{ .document = a_pools.storage(), .scratch = a_scratch.storage() }, a_bag.sink(), .{ .cancellation = if (cancellable) a_request.hook() else {} });
                    defer a.deinit();
                    // No override must inherit every leaf of the custom baseline.
                    var b = try Dynamic.Session.init(source, .{ .document = b_pools.storage(), .scratch = b_scratch.storage() }, b_bag.sink(), .{ .cancellation = b_request.hook() });
                    defer b.deinit();
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const budget = budgets[i % budgets.len];
                        const progress = a.advance(budget);
                        try deep(progress, try b.advance(budget));
                        try expect(progress.work_used <= budget);
                        if (progress.outcome != null) break;
                    }
                    try deep(a.result(), b.result());
                    try deep(a.validate(dot.diagnostic.discard), b.validate(dot.diagnostic.discard));
                    try equal(a_request.polls, b_request.polls);
                    try std.testing.expectEqualSlices(dot.Diagnostic, a_bag.items(), b_bag.items());
                }
            }
        }
    }
}

test "runtime session rejection is atomic and cancellation resources are independent" {
    const Parser = dot.Profile(.{ .runtime_policy = true, .policy = .{
        .execution = .{ .metering = true, .cancellation = true },
        .limits = .{ .max_statements = 1 },
        .validation = .{ .graph = .{ .operator_mismatch = .warning } },
    } });
    var pools: Storage = .{};
    var request: Request = .{};
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var session = try Parser.Session.init("graph {a->b}", .{ .document = pools.storage() }, bag.sink(), .{ .cancellation = request.hook() });
    defer session.deinit();
    _ = try session.advance(3);
    const polls = request.polls;
    const bad: Parser.FixedParseOptions = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto, .operator_reading = .as_written } } } };
    try std.testing.expectError(error.GraphOperatorReadingNotApplicable, session.reset("@", bag.sink(), bad));
    try equal(polls, request.polls);
    try equal(@as(usize, 0), bag.items().len);
    try expect(session.run().outcome == .success);
    try equal(@as(usize, 1), session.validate(dot.diagnostic.discard).?.outcome.completed.warnings);
    const old = session.result().?;
    try std.testing.expectError(error.GraphOperatorReadingNotApplicable, session.reset("@", bag.sink(), bad));
    try deep(old, session.result().?);
    // A successful reset resolves from the compiled baseline, not the last call.
    try session.reset("graph {a; b}", bag.sink(), .{ .policy = .{ .limits = .{ .max_statements = 2 }, .scanner = .block } });
    try expect(session.run().outcome == .success);
    try session.reset("graph {a; b}", bag.sink(), .{});
    try expect(session.run().outcome == .resource_exhausted);
    request.stop = true;
    try session.reset("graph {}", bag.sink(), .{ .cancellation = request.hook() });
    const progress = try session.advance(0);
    try equal(@as(usize, 0), progress.source_frontier);
    try expect(progress.outcome.? == .cancelled);
    try expect(session.interpretation() == null);
}

test "runtime preflight protects every parsing entry point" {
    const invalid: dot.Policy = .{ .validation = .{ .graph = .{ .treated_as = .auto, .operator_mismatch = .off } } };
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var pools: Storage = .{};
    var request: Request = .{ .stop = true };
    var bag: dot.FixedDiagnosticBag(2) = .{};
    const failure = error.GraphOperatorMismatchNotApplicable;
    try std.testing.expectError(failure, Runtime.parseBorrowed(allocator.allocator(), "@", bag.sink(), .{ .policy = invalid, .cancellation = request.hook() }));
    try std.testing.expectError(failure, Runtime.parseBorrowedIn("@", .{ .document = pools.storage() }, bag.sink(), .{ .policy = invalid, .cancellation = request.hook() }));
    try std.testing.expectError(failure, Runtime.measure(allocator.allocator(), "@", bag.sink(), .{ .policy = invalid }));
    try std.testing.expectError(failure, Runtime.measureIn("@", .{}, bag.sink(), .{ .policy = invalid }));
    try std.testing.expectError(failure, Runtime.Session.init("@", .{ .document = pools.storage() }, bag.sink(), .{ .policy = invalid, .cancellation = request.hook() }));
    try expect(!allocator.has_induced_failure);
    try equal(@as(usize, 0), request.polls);
    try equal(@as(usize, 0), bag.items().len);
}

test "one-shot and measurement cancellation do not publish staged output" {
    const Parser = dot.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } });
    var request: Request = .{ .stop = true };
    var bag: dot.FixedDiagnosticBag(2) = .{};
    var parsed = Parser.parseAndValidate(std.testing.allocator, "graph {a}", bag.sink(), .{ .cancellation = request.hook() });
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .cancelled);
    try expect(parsed.document == null and parsed.validation == null);
    const measured = Parser.measureIn("graph {a}", .{}, bag.sink(), .{ .cancellation = request.hook() });
    try expect(measured.outcome == .cancelled and measured.capacities == null);
    try equal(@as(usize, 0), bag.items().len);
}

test "fixed settings have no runtime storage and disabled controls are absent" {
    const Fixed = dot.Profile(.{ .policy = .{ .limits = .{ .max_statements = 3 }, .recovery = .fail_fast } });
    const Driver = @FieldType(@FieldType(Fixed.Session, "driver"), "machine");
    try expect(@FieldType(Driver, "settings") == void);
    try expect(@FieldType(Driver, "cancellation") == void);
    try expect(@FieldType(Driver, "work") == void);
    try expect(@FieldType(Driver, "skip_depth") == void);
    try expect(@FieldType(Fixed.Session, "interpretation_policy") == void);
    try equal(@as(usize, 0), @sizeOf(Fixed.FixedParseOptions));
    try expect(!@hasField(Fixed.ParseOptions, "policy"));
    const Variants = @FieldType(Runtime.Session, "driver");
    var total: usize = 0;
    var largest: usize = 0;
    inline for (std.meta.fields(Variants)) |field| {
        total += @sizeOf(field.type);
        largest = @max(largest, @sizeOf(field.type));
    }
    try expect(@sizeOf(Runtime.Session) < total);
    // A tag, validation settings and alignment padding; no eightfold state copy.
    try expect(@sizeOf(Runtime.Session) <= largest + 2 * @alignOf(Runtime.Session));
}
