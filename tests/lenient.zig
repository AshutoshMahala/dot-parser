//! Syntax acceptance is ordinary policy, independent of graph validation/recovery.
const std = @import("std");
const dot = @import("dot_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const Runtime = dot.Profile(.{ .runtime_policy = true });
const Lenient = dot.Profile(.{ .policy = dot.presets.lenient });
const Storage = dot.FixedDocumentStorage(.{ .statements = 32, .nodes = 32, .edges = 32, .attributes = 32, .subgraphs = 16, .scoped_edges = 16, .scoped_edge_links = 16, .edge_chains = 16, .edge_links = 32, .ported_references = 32, .assignments = 16, .attribute_statements = 16 });

test "standard and lenient are editable Policy values, not independent modes" {
    try expect(@TypeOf(dot.presets.standard) == dot.Policy);
    try expect(@TypeOf(dot.presets.lenient) == dot.Policy);
    try deep(dot.Profile(.{}).baseline, dot.Profile(.{ .policy = dot.presets.standard }).baseline);
    var strict_syntax = dot.presets.lenient;
    strict_syntax.syntax = dot.presets.standard.syntax;
    try deep(dot.presets.standard, strict_syntax);
    try expect(comptime dot.validatePolicy(dot.presets.standard) == .valid);
    try expect(comptime dot.validatePolicy(dot.presets.lenient) == .valid);
    try expect(tryValid(dot.presets.lenient));
    try expect(@FieldType(dot.ParseResult, "accepted_deviations") == u32);
    try expect(@FieldType(dot.ParseResult, "warnings") == u32);
}

fn tryValid(input: dot.Policy) bool {
    return Runtime.validatePolicy(input) == .valid;
}

test "each acceptance value has fixed runtime scanner and execution parity" {
    inline for (.{ .scalar, .block }) |scanner| {
        inline for (.{ false, true }) |metering| {
            inline for (.{ false, true }) |cancellation| {
                inline for (.{ .reject, .warn, .accept }) |acceptance| {
                    const input: dot.Policy = .{
                        .scanner = scanner,
                        .execution = .{ .metering = metering, .cancellation = cancellation },
                        .syntax = .{ .empty_statement = acceptance, .long_operator = acceptance, .bare_dash = .{ .acceptance = acceptance, .interpretation = .from_keyword } },
                    };
                    const Fixed = dot.Profile(.{ .policy = input });
                    for ([_][]const u8{
                        "graph { ; }",                                               "graph { a;; }",                                             "graph { a --- b }",
                        "digraph { a --> b }",                                       "graph { a - b }",                                           "digraph { a - b }",
                        "graph { { ; a:p --- b:q:n - c:r } - { d } --- e -- f; ; }", "digraph { a:p:e --> b:q - c:r --> { ; d --> e } -> f; ; }",
                    }) |source| {
                        var fixed_bag: dot.FixedDiagnosticBag(32) = .{};
                        var runtime_bag: dot.FixedDiagnosticBag(32) = .{};
                        var fixed = Fixed.parseAndValidate(std.testing.allocator, source, fixed_bag.sink(), .{});
                        defer fixed.deinit(std.testing.allocator);
                        var dynamic = try Runtime.parseAndValidate(std.testing.allocator, source, runtime_bag.sink(), .{ .policy = input });
                        defer dynamic.deinit(std.testing.allocator);
                        try deep(fixed, dynamic);
                        try deep(fixed_bag.items(), runtime_bag.items());
                        try equal(acceptance != .reject, fixed.documentValid());
                        if (acceptance == .reject) {
                            try equal(@as(u32, 0), fixed.accepted_deviations);
                            try equal(@as(u32, 0), fixed.warnings);
                        } else {
                            try expect(fixed.accepted_deviations > 0);
                            try equal(if (acceptance == .warn) fixed.accepted_deviations else 0, fixed.warnings);
                        }
                        const counts = Fixed.measure(std.testing.allocator, source, dot.diagnostic.discard, .{});
                        const runtime_counts = try Runtime.measure(std.testing.allocator, source, dot.diagnostic.discard, .{ .policy = input });
                        try deep(counts, runtime_counts);
                        try deep(counts.outcome, fixed.outcome);
                        try equal(fixed.accepted_deviations, counts.accepted_deviations);
                        try equal(fixed.warnings, counts.warnings);
                        var pools: Storage = .{};
                        var scratch: dot.FixedParseScratch(.{ .nesting = 16 }) = .{};
                        const memory: dot.ParseMemory = .{ .document = pools.storage(), .scratch = scratch.storage() };
                        try deep(counts, Fixed.measureIn(source, scratch.storage(), dot.diagnostic.discard, .{}));
                        try deep(counts, try Runtime.measureIn(source, scratch.storage(), dot.diagnostic.discard, .{ .policy = input }));
                        const retained = Fixed.parseBorrowedIn(source, memory, dot.diagnostic.discard, .{});
                        try deep(fixed.document, retained.document);
                        try equal(fixed.accepted_deviations, retained.accepted_deviations);
                        try equal(fixed.warnings, retained.warnings);
                        const runtime_retained = try Runtime.parseBorrowedIn(source, memory, dot.diagnostic.discard, .{ .policy = input });
                        try deep(retained, runtime_retained);
                    }
                }
            }
        }
    }
}

test "syntax leaves inherit independently and do not alter validation or recovery" {
    const Custom = dot.Profile(.{
        .runtime_policy = true,
        .policy = .{ .syntax = dot.presets.lenient.syntax, .scanner = .block, .limits = .{ .max_statements = 3 } },
    });
    var accepted = try Custom.parseBorrowed(std.testing.allocator, "graph { ; a --- b - c }", dot.diagnostic.discard, .{
        .policy = .{ .syntax = .{ .long_operator = .accept } },
    });
    defer accepted.deinit(std.testing.allocator);
    try expect(accepted.outcome == .success);
    try equal(@as(u32, 3), accepted.accepted_deviations);
    try equal(@as(u32, 2), accepted.warnings);
    var rejected = try Custom.parseBorrowed(std.testing.allocator, "graph { a --- b }", dot.diagnostic.discard, .{
        .policy = .{ .syntax = .{ .long_operator = .reject } },
    });
    defer rejected.deinit(std.testing.allocator);
    try expect(rejected.outcome == .invalid_syntax);
    var mismatch = Lenient.parseAndValidate(std.testing.allocator, "graph { a --> b }", dot.diagnostic.discard, .{});
    defer mismatch.deinit(std.testing.allocator);
    try expect(mismatch.outcome == .success and !mismatch.documentValid());
    try equal(@as(u32, 1), mismatch.warnings);
    try equal(@as(usize, 1), mismatch.validation.?.outcome.completed.violations);
    // Partial syntax patches preserve limits; complete presets explicitly reset them.
    var limited = try Custom.parseBorrowed(std.testing.allocator, "graph { a b c d }", dot.diagnostic.discard, .{ .policy = .{ .syntax = dot.presets.lenient.syntax } });
    defer limited.deinit(std.testing.allocator);
    try expect(limited.outcome == .resource_exhausted);
    var reset = try Custom.parseBorrowed(std.testing.allocator, "graph { a b c d }", dot.diagnostic.discard, .{ .policy = dot.presets.standard });
    defer reset.deinit(std.testing.allocator);
    try expect(reset.outcome == .success);
}

test "each syntax rule is independent of the other two" {
    const sources = [_][]const u8{ "graph { ; }", "graph { a --- b }", "graph { a - b }" };
    for ([_]dot.Acceptance{ .reject, .warn, .accept }) |empty| {
        for ([_]dot.Acceptance{ .reject, .warn, .accept }) |long| {
            for ([_]dot.Acceptance{ .reject, .warn, .accept }) |bare| {
                const input: dot.Policy = .{ .syntax = .{ .empty_statement = empty, .long_operator = long, .bare_dash = .{ .acceptance = bare } } };
                for (sources, [_]dot.Acceptance{ empty, long, bare }) |source, acceptance| {
                    var result = try Runtime.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{ .policy = input });
                    defer result.deinit(std.testing.allocator);
                    try equal(acceptance != .reject, result.outcome == .success);
                    try equal(@as(u32, if (acceptance == .reject) 0 else 1), result.accepted_deviations);
                    try equal(@as(u32, if (acceptance == .warn) 1 else 0), result.warnings);
                }
            }
        }
    }
}

test "bare dash follows the written header and normalization precedes graph interpretation" {
    inline for ([_]dot.GraphTreatment{ .undigraph, .digraph, .generic, .auto }) |treatment| {
        const input: dot.Policy = .{ .syntax = dot.presets.lenient.syntax, .validation = .{ .graph = .{ .treated_as = treatment } } };
        const Fixed = dot.Profile(.{ .policy = input });
        for ([_][]const u8{ "graph { a - b; b -> c }", "graph { a - b; b --> c }" }) |source| {
            var bag: dot.FixedDiagnosticBag(8) = .{};
            var checked = Fixed.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
            defer checked.deinit(std.testing.allocator);
            try expect(checked.outcome == .success);
            const doc = &checked.document.?;
            const view = Fixed.interpretation(doc, .{});
            try equal(dot.DeclaredGraphKind.undigraph, doc.kind);
            try equal(@as(dot.GraphKind, switch (treatment) {
                .undigraph => .undigraph,
                .digraph => .digraph,
                .generic, .auto => .generic,
            }), doc.effectiveKind(view));
            var edges = doc.edgeIterator();
            const first = edges.next().?;
            try equal(dot.EdgeOperator.undirected, first.operator);
            try std.testing.expectEqualStrings("-", doc.text(first.operator_range));
            try equal(dot.EdgeOperator.directed, edges.next().?.operator);
            try equal(dot.Code.syntax_operator_accepted, bag.items()[0].code);
            try equal(.from_keyword, bag.items()[0].details.accepted_operator.reason);
            try equal(.undirected, bag.items()[0].details.accepted_operator.operator);
        }
        var only_dash = Fixed.parseBorrowed(std.testing.allocator, "graph { a - b }", dot.diagnostic.discard, .{});
        defer only_dash.deinit(std.testing.allocator);
        if (treatment == .auto) try equal(dot.GraphKind.undigraph, only_dash.document.?.effectiveKind(Fixed.interpretation(&only_dash.document.?, .{})));
        var directed = Fixed.parseBorrowed(std.testing.allocator, "digraph { a - b }", dot.diagnostic.discard, .{});
        defer directed.deinit(std.testing.allocator);
        try equal(dot.EdgeOperator.directed, directed.document.?.edges[0].operator);
    }
    const Conform = dot.Profile(.{ .policy = .{ .syntax = dot.presets.lenient.syntax, .validation = .{ .graph = .{
        .treated_as = .digraph,
        .operator_mismatch = .warning,
        .operator_reading = .conform_to_kind,
    } } } });
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = Conform.parseAndValidate(std.testing.allocator, "graph { a - b }", bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try expect(checked.documentValid());
    try equal(@as(u32, 1), checked.accepted_deviations);
    try equal(@as(u32, 2), checked.warnings);
    try equal(dot.Code.syntax_operator_accepted, bag.items()[0].code);
    try equal(dot.Code.validation_operator_tolerated, bag.items()[1].code);
    const doc = &checked.document.?;
    var edges = doc.edgeIterator();
    const edge = edges.next().?;
    try equal(dot.EdgeOperator.undirected, edge.operator);
    try equal(dot.EdgeOperator.directed, edge.effectiveOperator(doc, Conform.interpretation(doc, .{})));
}

test "leniency does not rewrite numerals strings comments or accept other malformed syntax" {
    const valid = "graph { -5; -.5 -- -2; a-5; \"- --->\"; \"x\" + \"-\"; /* --- */ // -->\n a[x=\"-\"]; }";
    var standard = dot.parseBorrowed(std.testing.allocator, valid, dot.diagnostic.discard, .{});
    defer standard.deinit(std.testing.allocator);
    var lenient = Lenient.parseBorrowed(std.testing.allocator, valid, dot.diagnostic.discard, .{});
    defer lenient.deinit(std.testing.allocator);
    try expect(standard.outcome == .success);
    try deep(standard, lenient);
    for ([_][]const u8{
        "graph { a - > b }",          "graph { a - - b }",        "graph { a -\n> b }",
        "graph { a ---- b }",         "graph { a ---> b }",       "graph { a ->> b }",
        "graph { - b }",              "graph { --- b }",          "graph { a -> - b }",
        "graph { a[x=-] }",           "graph { a[x=---] }",       "graph { a = - b }",
        "graph { a:- b }",            "graph { a[x=1] - b }",     "graph - { a }",
        "graph { subgraph - { a } }", "graph { a, b }",           "graph { a[x=1 }",
        "graph { node; }",            "graph { edge=red }",       "digraph strict {}",
        "graph {} graph {}",          "graph { \"unterminated }", "graph {};",
    }) |source| {
        inline for (.{ .scalar, .block }) |scanner| {
            const Fixed = dot.Profile(.{ .policy = .{ .syntax = dot.presets.lenient.syntax, .scanner = scanner } });
            var result = Fixed.parseBorrowed(std.testing.allocator, source, dot.diagnostic.discard, .{});
            defer result.deinit(std.testing.allocator);
            errdefer std.debug.print("incorrectly accepted: {s}\n", .{source});
            try expect(result.outcome == .invalid_syntax);
        }
    }
}

const Rejecting = struct {
    fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
        return error.DiagnosticSinkFailure;
    }
};

test "factual counters survive silent acceptance discarded full or failing diagnostic sinks" {
    const source = "graph { ; a --- b - c; ; }";
    var tiny: dot.FixedDiagnosticBag(1) = .{};
    for ([_]dot.DiagnosticSink{ dot.diagnostic.discard, tiny.sink(), .{ .context = null, .emit_fn = Rejecting.emit } }) |sink| {
        var parsed = Lenient.parseBorrowed(std.testing.allocator, source, sink, .{});
        defer parsed.deinit(std.testing.allocator);
        try expect(parsed.outcome == .success);
        try equal(@as(u32, 4), parsed.accepted_deviations);
        try equal(@as(u32, 4), parsed.warnings);
        if (sink.emit_fn == Rejecting.emit) try equal(dot.diagnostic.Delivery.failed, parsed.diagnostic_delivery);
    }
    try equal(@as(usize, 1), tiny.items().len);
    const Silent = dot.Profile(.{ .policy = .{ .syntax = .{ .empty_statement = .accept, .long_operator = .accept, .bare_dash = .{ .acceptance = .accept } } } });
    var parsed = Silent.parseBorrowed(std.testing.allocator, source, .{ .context = null, .emit_fn = Rejecting.emit }, .{});
    defer parsed.deinit(std.testing.allocator);
    try equal(@as(u32, 4), parsed.accepted_deviations);
    try equal(@as(u32, 0), parsed.warnings);
    try equal(dot.diagnostic.Delivery.complete, parsed.diagnostic_delivery);
    var numeral = dot.parseAndValidate(std.testing.allocator, "graph { 1e3 }", dot.diagnostic.discard, .{});
    defer numeral.deinit(std.testing.allocator);
    try equal(@as(u32, 0), numeral.accepted_deviations);
    try equal(@as(u32, 1), numeral.warnings);
}

test "prefix facts survive later syntax capacity recovery and cancellation failure" {
    inline for (.{ .fail_fast, .statements }) |recovery| {
        const Fixed = dot.Profile(.{ .policy = .{ .syntax = dot.presets.lenient.syntax, .recovery = recovery } });
        const source = "graph { ; a - b; c[x=]; }";
        var checked = Fixed.parseAndValidate(std.testing.allocator, source, dot.diagnostic.discard, .{});
        defer checked.deinit(std.testing.allocator);
        try expect(checked.outcome == .invalid_syntax and checked.document == null);
        try equal(@as(u32, 2), checked.accepted_deviations);
        try equal(@as(u32, 2), checked.warnings);
        try equal(@as(u32, 2), Fixed.measure(std.testing.allocator, source, dot.diagnostic.discard, .{}).accepted_deviations);
    }
    var no_pools: dot.FixedDocumentStorage(.{}) = .{};
    const exhausted = Lenient.parseBorrowedIn("graph { ; a - b }", .{ .document = no_pools.storage() }, dot.diagnostic.discard, .{});
    try expect(exhausted.outcome == .storage_failure);
    try equal(@as(u32, 2), exhausted.accepted_deviations);
    try equal(@as(u32, 2), exhausted.warnings);
    const Bounded = dot.Profile(.{ .policy = .{ .syntax = dot.presets.lenient.syntax, .execution = .{ .metering = true } } });
    var pools: Storage = .{};
    var session = Bounded.Session.init("graph { ; a - b }", .{ .document = pools.storage() }, .{ .context = null, .emit_fn = Rejecting.emit }, .{});
    defer session.deinit();
    var progress = session.advance(0);
    while (progress.accepted_deviations == 0) progress = session.advance(1);
    try equal(dot.diagnostic.Delivery.failed, progress.diagnostic_delivery);
    const cancelled = session.cancel();
    try expect(cancelled.outcome == .cancelled);
    try equal(@as(u32, 1), cancelled.accepted_deviations);
    try equal(@as(u32, 1), cancelled.warnings);
    try deep(cancelled, session.cancel());
    try deep(cancelled, session.run());
}

test "runtime sessions latch syntax policy and reset from the compiled baseline" {
    inline for (.{ .scalar, .block }) |scanner| {
        var pools: Storage = .{};
        var scratch: dot.FixedParseScratch(.{ .nesting = 16 }) = .{};
        var input: dot.Policy = .{ .syntax = dot.presets.lenient.syntax, .scanner = scanner, .execution = .{ .metering = true } };
        const source = "graph { ; a:p --- b:q - c:r -- { ; d } }";
        var session = try Runtime.Session.init(source, .{ .document = pools.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{ .policy = input });
        defer session.deinit();
        input.syntax = dot.presets.standard.syntax;
        while ((try session.advance(1)).outcome == null) {}
        const parsed = session.result().?;
        try expect(parsed.outcome == .success);
        try equal(@as(u32, 4), parsed.accepted_deviations);
        try equal(@as(u32, 4), parsed.warnings);
        try session.reset(source, dot.diagnostic.discard, .{});
        try expect(session.run().outcome == .invalid_syntax);
        try equal(@as(u32, 0), session.result().?.accepted_deviations);
        try session.reset("graph { ; }", dot.diagnostic.discard, .{ .policy = .{ .syntax = .{ .empty_statement = .accept } } });
        try equal(@as(u32, 1), session.run().accepted_deviations);
        try equal(@as(u32, 0), session.result().?.warnings);
    }
}

test "warning fixes preserve original spans and reparse under standard syntax" {
    const source = "digraph { ; a --> b - c; ; }";
    var bag: dot.FixedDiagnosticBag(8) = .{};
    var parsed = Lenient.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try expect(parsed.outcome == .success);
    try equal(@as(u32, 4), parsed.accepted_deviations);
    try std.testing.expectEqualStrings("W.Syntax.Operator.003", dot.Code.syntax_operator_accepted.structured());
    try std.testing.expectEqualStrings("W.Syntax.Grammar.034", dot.Code.syntax_empty_statement.structured());
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var offset: usize = 0;
    for (bag.items()) |d| {
        const fix = d.fix.?;
        try equal(dot.diagnostic.Applicability.machine_applicable, fix.applicability);
        try deep(d.span, fix.span);
        try output.appendSlice(std.testing.allocator, source[offset..fix.span.start]);
        switch (fix.edit) {
            .delete => try std.testing.expectEqualStrings(";", d.span.slice(source)),
            .replace => |replacement| try output.appendSlice(std.testing.allocator, replacement.text()),
            else => return error.UnexpectedEdit,
        }
        offset = @intCast(fix.span.endOffset());
        inline for (.{ .ascii, .unicode }) |style| {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            try dot.console.renderBoxed(d, 1, .{ .source = source, .style = style }, &writer);
            try expect(std.mem.indexOf(u8, writer.buffered(), "Fix:") != null);
            if (d.details == .accepted_operator) {
                try expect(std.mem.indexOf(u8, writer.buffered(), "read as '->'") != null);
                if (d.details.accepted_operator.reason == .from_keyword)
                    try expect(std.mem.indexOf(u8, writer.buffered(), "from_keyword") != null);
            }
        }
        var compact_buffer: [2048]u8 = undefined;
        var compact = std.Io.Writer.fixed(&compact_buffer);
        try dot.console.render(d, .{ .source = source }, &compact);
        try expect(std.mem.indexOf(u8, compact.buffered(), "fix:") != null);
        if (d.details == .accepted_operator)
            try expect(std.mem.indexOf(u8, compact.buffered(), "read as '->'") != null);
    }
    try output.appendSlice(std.testing.allocator, source[offset..]);
    var clean = dot.parseAndValidate(std.testing.allocator, output.items, dot.diagnostic.discard, .{});
    defer clean.deinit(std.testing.allocator);
    try expect(clean.documentValid());
    try equal(@as(u32, 0), clean.accepted_deviations);
    try equal(@as(u32, 0), clean.warnings);
}
