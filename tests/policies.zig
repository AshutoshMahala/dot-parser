const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "public graph policy matrix: fixed and runtime have identical semantics" {
    inline for ([_]dot.GraphTreatment{ .undigraph, .digraph, .generic, .auto }) |treatment| {
        inline for (.{ .err, .warning, .off }) |severity| {
            inline for (.{ .as_written, .conform_to_kind }) |reading| {
                const flexible = treatment == .generic or treatment == .auto;
                const input: dot.Policy = .{ .validation = .{
                    .graph = .{
                        .treated_as = treatment,
                        .operator_mismatch = if (flexible) null else severity,
                        .operator_reading = if (flexible) null else reading,
                    },
                    .digraph = .{ .operator_mismatch = severity, .operator_reading = reading },
                } };
                const Fixed = dot.Profile(.{ .policy = input });
                const Runtime = dot.Profile(.{ .runtime_policy = true });
                try expect((comptime Fixed.validatePolicy(.{})) == .valid);
                try expect(Runtime.validatePolicy(input) == .valid);

                for ([_][]const u8{
                    "graph {}",                                       "digraph {}",
                    "graph { a -> b }",                               "graph { a -- b -- c }",
                    "graph { a -- b; b -> c }",                       "digraph { a -- b -> c -- d }",
                    "graph { { a -> b } -- { c -- d } -- e }",        "graph { a -- { b -> c } }",
                    "graph { subgraph x { subgraph y { a -> b } } }", "graph { a:p -- b:q -> c:r }",
                    "digraph { { a -- b } -- { c -> d } -> e }",      "graph { a [label=\"->\"]; // ->\n b -- c }",
                }) |source| {
                    var fixed_bag: dot.FixedDiagnosticBag(16) = .{};
                    var runtime_bag: dot.FixedDiagnosticBag(16) = .{};
                    var fixed = Fixed.parseAndValidate(std.testing.allocator, source, fixed_bag.sink(), .{});
                    defer fixed.deinit(std.testing.allocator);
                    var runtime = try Runtime.parseAndValidate(std.testing.allocator, source, runtime_bag.sink(), .{ .policy = input });
                    defer runtime.deinit(std.testing.allocator);
                    try expectEqual(dot.ParseOutcome.success, fixed.outcome);
                    try std.testing.expectEqualDeep(fixed.validation, runtime.validation);
                    try std.testing.expectEqualSlices(dot.Diagnostic, fixed_bag.items(), runtime_bag.items());

                    const document = &fixed.document.?;
                    const original_kind: dot.DeclaredGraphKind = if (std.mem.startsWith(u8, source, "digraph")) .digraph else .undigraph;
                    try expectEqual(original_kind, document.kind);
                    try std.testing.expectEqualStrings(source, document.source);
                    var has_directed = false;
                    var scan = document.edgeIterator();
                    while (scan.next()) |edge| {
                        has_directed = has_directed or edge.operator == .directed;
                    }
                    const target: dot.GraphKind = if (original_kind == .digraph) .digraph else switch (treatment) {
                        .undigraph => .undigraph,
                        .digraph => .digraph,
                        .generic => .generic,
                        .auto => if (has_directed) .generic else .undigraph,
                    };
                    const view = Fixed.interpretation(document, .{});
                    const dynamic_view = try Runtime.interpretation(document, .{ .policy = input });
                    try expectEqual(target, document.effectiveKind(view));
                    try expectEqual(target, document.effectiveKind(dynamic_view));

                    const unconstrained = original_kind == .undigraph and flexible;
                    var mismatches: usize = 0;
                    var edges = document.edgeIterator();
                    const expected: dot.EdgeOperator = if (target == .digraph) .directed else .undirected;
                    while (edges.next()) |edge| {
                        try std.testing.expectEqualStrings(if (edge.operator == .directed) "->" else "--", document.text(edge.operator_range));
                        if (!unconstrained and edge.operator != expected) mismatches += 1;
                        const effective = if (unconstrained or reading == .as_written) edge.operator else expected;
                        try expectEqual(effective, edge.effectiveOperator(document, view));
                        try expectEqual(effective, edge.effectiveOperator(document, dynamic_view));
                    }
                    try expectEqual(severity != .err or mismatches == 0, fixed.documentValid());
                    try expectEqual(if (severity == .err) mismatches else 0, fixed.validation.?.outcome.completed.violations);
                    try expectEqual(if (severity == .warning) mismatches else 0, fixed.validation.?.outcome.completed.warnings);
                    try expectEqual(if (severity == .off) 0 else mismatches, fixed_bag.items().len);
                    var previous: usize = 0;
                    for (fixed_bag.items()) |d| {
                        try expect(d.span.start >= previous);
                        previous = d.span.start;
                        try expectEqual(if (severity == .warning) dot.Code.validation_operator_tolerated else dot.Code.validation_operator_mismatch, d.code);
                        try expectEqual(if (reading == .conform_to_kind) dot.diagnostic.Applicability.machine_applicable else dot.diagnostic.Applicability.maybe, d.fix.?.applicability);
                        try expectEqual(original_kind == .undigraph and treatment == .digraph, d.details.operator_mismatch.kind_overridden);
                    }
                }
            }
        }
    }
}

test "optional Policy inherits per leaf and branches never leak between calls" {
    const Runtime = dot.Profile(.{
        .policy = .{ .validation = .{
            .graph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind },
            .digraph = .{ .operator_mismatch = .off },
        } },
        .runtime_policy = true,
    });
    var parsed = dot.parseBorrowed(std.testing.allocator, "graph { a -> b }", dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    const document = &parsed.document.?;

    const inherited = try Runtime.validate(document, dot.diagnostic.discard, .{});
    try expect(inherited.documentValid());
    try expectEqual(@as(usize, 1), inherited.outcome.completed.warnings);
    const explicit_default: Runtime.Options = .{ .policy = .{ .validation = .{ .graph = .{ .operator_mismatch = .err } } } };
    try expect(!(try Runtime.validate(document, dot.diagnostic.discard, .{ .policy = explicit_default.policy })).documentValid());
    var edges = document.edgeIterator();
    const edge = edges.next().?;
    try expectEqual(dot.EdgeOperator.undirected, edge.effectiveOperator(document, try Runtime.interpretation(document, explicit_default)));
    try expectEqual(dot.EdgeOperator.directed, edge.operator);
    try expectEqual(@as(usize, 1), (try Runtime.validate(document, dot.diagnostic.discard, .{})).outcome.completed.warnings);
    try expectEqual(dot.DeclaredGraphKind.undigraph, document.kind);

    // Treatment follows the graph branch even when its result is a digraph.
    const redirected: Runtime.Options = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .digraph } } } };
    var undirected = dot.parseBorrowed(std.testing.allocator, "graph { a -- b }", dot.diagnostic.discard, .{});
    defer undirected.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 1), (try Runtime.validate(&undirected.document.?, dot.diagnostic.discard, .{ .policy = redirected.policy })).outcome.completed.warnings);
    var directed = dot.parseBorrowed(std.testing.allocator, "digraph { a -- b }", dot.diagnostic.discard, .{});
    defer directed.deinit(std.testing.allocator);
    const checked = try Runtime.validate(&directed.document.?, dot.diagnostic.discard, .{ .policy = explicit_default.policy });
    try expect(checked.documentValid());
    try expectEqual(@as(usize, 0), checked.outcome.completed.warnings);
    var directed_edges = directed.document.?.edgeIterator();
    try expectEqual(dot.EdgeOperator.undirected, directed_edges.next().?.effectiveOperator(&directed.document.?, try Runtime.interpretation(&directed.document.?, explicit_default)));
}

test "warnings count occurrences regardless of retention or delivery failure" {
    const Profile = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .operator_mismatch = .warning } } } });
    var parsed = dot.parseBorrowed(std.testing.allocator, "graph { a -> b -> c; c -> d }", dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const result = Profile.validate(&parsed.document.?, bag.sink(), .{});
    try expect(result.documentValid());
    try expectEqual(@as(usize, 3), result.outcome.completed.warnings);
    try expectEqual(@as(usize, 0), result.outcome.completed.violations);
    try expectEqual(@as(usize, 2), bag.omitted);
    const Rejecting = struct {
        fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
            return error.DiagnosticSinkFailure;
        }
    };
    const rejected = Profile.validate(&parsed.document.?, .{ .context = null, .emit_fn = Rejecting.emit }, .{});
    try expect(rejected.documentValid());
    try expectEqual(@as(usize, 3), rejected.outcome.completed.warnings);
    try expectEqual(dot.diagnostic.Delivery.failed, rejected.diagnostic_delivery);
    const Silent = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .operator_mismatch = .off } } } });
    try expectEqual(dot.diagnostic.Delivery.complete, Silent.validate(&parsed.document.?, .{ .context = null, .emit_fn = Rejecting.emit }, .{}).diagnostic_delivery);
}

test "fixed storage and bounded sessions compose with policy without retained settings" {
    const Auto = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } } });
    const source = "graph { a -> b -- c }";
    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 1, .edges = 1 }) = .{};
    const parsed = Auto.parseBorrowedIn(source, .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
    try expectEqual(dot.ParseOutcome.success, parsed.outcome);
    try expect(Auto.validate(&parsed.document.?, dot.diagnostic.discard, .{}).documentValid());
    try expectEqual(dot.GraphKind.generic, parsed.document.?.effectiveKind(Auto.interpretation(&parsed.document.?, .{})));
    var session = dot.BoundedSession.init(source, .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
    defer session.deinit();
    while (session.advance(1).outcome == null) {}
    var completed = session.result().?;
    try expect(Auto.validate(&completed.document.?, dot.diagnostic.discard, .{}).documentValid());
    try expect(!dot.validate(&completed.document.?, dot.diagnostic.discard, .{}).documentValid());
    try expectEqual(dot.GraphKind.generic, completed.document.?.effectiveKind(Auto.interpretation(&completed.document.?, .{})));
    session.reset("graph { a -- b }", dot.diagnostic.discard, .{});
    while (session.advance(2).outcome == null) {}
    completed = session.result().?;
    try expectEqual(dot.GraphKind.undigraph, completed.document.?.effectiveKind(Auto.interpretation(&completed.document.?, .{})));
}

test "fixed profiles have no override fields or runtime policy state" {
    const Fixed = dot.Profile(.{});
    const Auto = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } } });
    const Runtime = dot.Profile(.{ .runtime_policy = true });
    try expect(!@hasField(Fixed.Options, "policy"));
    try expect(!@hasField(Fixed.CheckOptions, "policy"));
    try expect(!@hasField(dot.Policy.Operators, "treated_as"));
    try expect(@hasField(Runtime.Options, "policy"));
    try expect(@hasField(Runtime.CheckOptions, "policy"));
    try expectEqual(@as(usize, 0), @sizeOf(Fixed.Options));
    try expectEqual(@as(usize, 0), @sizeOf(Fixed.Interpretation));
    try expectEqual(@sizeOf(dot.GraphKind), @sizeOf(Auto.Interpretation));
    try expect(@sizeOf(Runtime.Interpretation) <= 2);
    try expect((comptime dot.validatePolicy(.{})) == .valid);
}

test "policy check cannot mistake source or storage failure for invalid configuration" {
    const Runtime = dot.Profile(.{ .runtime_policy = true });
    try expect(Runtime.validatePolicy(.{ .validation = .{ .graph = .{ .treated_as = .generic } } }) == .valid);
    var broken = try Runtime.parseAndValidate(std.testing.allocator, "graph { a ->", dot.diagnostic.discard, .{});
    defer broken.deinit(std.testing.allocator);
    try expect(broken.document == null);
    try expect(broken.validation == null);
    try expect(broken.outcome == .invalid_syntax);
    try expect(!broken.documentValid());
}

test "renderers explain severity reading and overridden graph kind" {
    inline for (.{ .as_written, .conform_to_kind }) |reading| {
        inline for (.{ .err, .warning }) |severity| {
            const Profile = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{
                .treated_as = .digraph,
                .operator_mismatch = severity,
                .operator_reading = reading,
            } } } });
            const source = "graph { a -- b }";
            var bag: dot.FixedDiagnosticBag(1) = .{};
            var result = Profile.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
            defer result.deinit(std.testing.allocator);
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try dot.console.render(bag.items()[0], .{ .source = source }, &writer);
            try dot.console.renderBoxed(bag.items()[0], 1, .{ .source = source, .style = .ascii }, &writer);
            const assumption = if (reading == .conform_to_kind) "policy interprets this edge as '->'" else if (severity == .warning) "policy preserves the written operator" else "policy treats 'graph' as a digraph";
            try expectEqual(@as(usize, 2), std.mem.count(u8, writer.buffered(), assumption));
            try expect(std.mem.indexOf(u8, writer.buffered(), "written as 'graph'; policy treats it as a digraph") != null);
            try expect(std.mem.indexOf(u8, writer.buffered(), "declare the document with 'graph'") == null);
        }
    }
}

test "bad runtime configuration precedes input allocation diagnostics and document inspection" {
    const Runtime = dot.Profile(.{ .runtime_policy = true });
    inline for ([_]dot.Policy{
        .{ .validation = .{ .graph = .{ .treated_as = .auto, .operator_mismatch = .warning } } },
        .{ .validation = .{ .graph = .{ .treated_as = .generic, .operator_reading = .as_written } } },
    }) |invalid| {
        const checked = Runtime.validatePolicy(invalid);
        try expect(checked == .invalid);
        const failure = checked.invalid.asError();
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var bag: dot.FixedDiagnosticBag(4) = .{};
        // Invalid DOT would emit a diagnostic if parsing were attempted first.
        try std.testing.expectError(failure, Runtime.parseAndValidate(allocator.allocator(), "@", bag.sink(), .{ .policy = invalid }));
        try expectEqual(@as(usize, 0), allocator.allocations);
        try expect(!allocator.has_induced_failure);
        try expectEqual(@as(usize, 0), bag.items().len);
        // Neither staged operation may inspect the document before checking.
        var unread: dot.Document = undefined;
        try std.testing.expectError(failure, Runtime.validate(&unread, bag.sink(), .{ .policy = invalid }));
        try std.testing.expectError(failure, Runtime.interpretation(&unread, .{ .policy = invalid }));
    }
}

test "generic baseline checks explicit fields against the inherited treatment" {
    const Config: dot.PolicyConfig = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic } } }, .runtime_policy = true };
    const Runtime = dot.Profile(Config);
    const mismatch: dot.Policy = .{ .validation = .{ .graph = .{ .operator_mismatch = .err } } };
    const reading: dot.Policy = .{ .validation = .{ .graph = .{ .operator_reading = .as_written } } };
    try expectEqual(dot.PolicyIssue.graph_operator_mismatch_not_applicable, Runtime.validatePolicy(mismatch).invalid);
    try expectEqual(dot.PolicyIssue.graph_operator_reading_not_applicable, Runtime.validatePolicy(reading).invalid);
    const Fixed = dot.Profile(.{ .policy = Config.policy });
    try expectEqual(dot.PolicyIssue.graph_operator_mismatch_not_applicable, (comptime Fixed.validatePolicy(mismatch)).invalid);
    try expect(Runtime.validatePolicy(.{ .validation = .{ .graph = .{ .treated_as = .undigraph, .operator_mismatch = .warning } } }) == .valid);
    try expect(Runtime.validatePolicy(.{ .validation = .{ .digraph = .{ .operator_mismatch = .off, .operator_reading = .conform_to_kind } } }) == .valid);
}

test "auto override leaves inherited concrete settings dormant and later calls unchanged" {
    const Runtime = dot.Profile(.{ .runtime_policy = true, .policy = .{ .validation = .{ .graph = .{
        .operator_mismatch = .warning,
        .operator_reading = .conform_to_kind,
    } } } });
    const options: Runtime.Options = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } } };
    var parsed = dot.parseBorrowed(std.testing.allocator, "graph { a -- b -> c }", dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    const doc = &parsed.document.?;
    const checked = try Runtime.validate(doc, dot.diagnostic.discard, .{ .policy = options.policy });
    try expect(checked.documentValid());
    try expectEqual(@as(usize, 0), checked.outcome.completed.warnings);
    const view = try Runtime.interpretation(doc, options);
    try expectEqual(dot.GraphKind.generic, doc.effectiveKind(view));
    var edges = doc.edgeIterator();
    while (edges.next()) |edge| try expectEqual(edge.operator, edge.effectiveOperator(doc, view));
    try expectEqual(@as(usize, 1), (try Runtime.validate(doc, dot.diagnostic.discard, .{})).outcome.completed.warnings);
    try expectEqual(dot.GraphKind.undigraph, doc.effectiveKind(try Runtime.interpretation(doc, .{})));
}

test "strict profile matches the default facade and header advice respects both branches" {
    const Fixed = dot.Profile(.{});
    const source = "digraph { a -- b }";
    var bag: dot.FixedDiagnosticBag(2) = .{};
    var parsed = dot.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
    defer parsed.deinit(std.testing.allocator);
    const doc = &parsed.document.?;
    try std.testing.expectEqualDeep(dot.validate(doc, dot.diagnostic.discard, .{}), Fixed.validate(doc, dot.diagnostic.discard, .{}));
    const BothDirected = dot.Profile(.{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .digraph } } } });
    _ = BothDirected.validate(doc, bag.sink(), .{});
    try expect(!bag.items()[0].details.operator_mismatch.suggest_header_change);
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dot.console.render(bag.items()[0], .{ .source = source }, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "or declare") == null);
}
