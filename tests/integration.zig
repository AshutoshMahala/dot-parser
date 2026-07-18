//! Public integration tests. These import only the `dot_parser` module,
//! exactly like an external consumer (PROJECT_STRUCTURE.md, test level 2).

const std = @import("std");
const dot = @import("dot_parser");

test "consumer can collect diagnostics through a fixed bag" {
    var bag: dot.FixedDiagnosticBag(16) = .{};
    const sink = bag.sink();

    // Simulate what validating `graph { a -> b; c -> d; }` will emit.
    const declaration: dot.Span = .{
        .start = .{ .byte_offset = 0, .line = 1, .byte_column = 1 },
        .byte_len = 5,
    };
    try sink.emit(.{
        .code = .validation_operator_mismatch,
        .span = .{
            .start = .{ .byte_offset = 10, .line = 2, .byte_column = 7 },
            .byte_len = 2,
        },
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = declaration,
        } },
    });
    try sink.emit(.{
        .code = .validation_operator_mismatch,
        .span = .{
            .start = .{ .byte_offset = 21, .line = 3, .byte_column = 7 },
            .byte_len = 2,
        },
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = declaration,
        } },
    });

    try std.testing.expectEqual(@as(usize, 2), bag.items().len);
    try std.testing.expectEqual(@as(usize, 0), bag.omitted);

    // Diagnostics arrive in source order with full identity and location.
    const first = bag.items()[0];
    try std.testing.expectEqualStrings(
        "E.Validation.Operator.002",
        first.code.structured(),
    );
    try std.testing.expectEqual(dot.Severity.err, first.code.severity());
    try std.testing.expect(first.code.severity().isBlocking());
    try std.testing.expectEqual(@as(usize, 2), first.span.start.line);
    try std.testing.expect(
        bag.items()[0].span.start.byte_offset < bag.items()[1].span.start.byte_offset,
    );
}

test "consumer can render a diagnostic into caller-owned memory" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try dot.console.render(.{
        .code = .profile_unsupported_feature,
        .span = .{
            .start = .{ .byte_offset = 0, .line = 1, .byte_column = 1 },
            .byte_len = 7,
        },
        .details = .{ .unsupported_feature = .digraph_document },
    }, &writer);

    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "dot_parser:E.Profile.Feature.009") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "digraph document") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "help:") != null);
}

test "consumer can render boxed output in unicode and ascii styles" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const diagnostics = [_]dot.Diagnostic{.{
        .code = .parser_unexpected_token,
        .span = .{
            .start = .{ .byte_offset = 4, .line = 1, .byte_column = 5 },
            .byte_len = 1,
        },
    }};

    try dot.console.renderBoxedList(&diagnostics, 0, .{ .source_name = "pipe" }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "┌─ Error 1 ─── [dot_parser:E.Parser.Syntax.003 (INVALID)]") != null);

    var ascii_writer = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxedList(&diagnostics, 0, .{ .source_name = "pipe", .style = .ascii }, &ascii_writer);
    try std.testing.expect(std.mem.indexOf(u8, ascii_writer.buffered(), "-- Error 1 - [dot_parser:E.Parser.Syntax.003 (INVALID)]") != null);
}

test "consumer can bring their own reporter through the sink interface" {
    // A custom Sink that forwards diagnostics into the consumer's own
    // logging system — here, one line per diagnostic into a fixed buffer.
    const LineLogger = struct {
        writer: *std.Io.Writer,
        fn emit(context: ?*anyopaque, d: dot.Diagnostic) dot.DiagnosticSinkError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.writer.print("{s} at {d}:{d}\n", .{
                d.code.structured(), d.span.start.line, d.span.start.byte_column,
            }) catch return error.DiagnosticSinkFailure;
        }
    };

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var logger: LineLogger = .{ .writer = &writer };
    const sink: dot.DiagnosticSink = .{ .context = &logger, .emit_fn = LineLogger.emit };

    try sink.emit(.{
        .code = .parser_unexpected_end,
        .span = .{ .start = .{ .byte_offset = 9, .line = 4, .byte_column = 2 }, .byte_len = 0 },
    });

    try std.testing.expectEqualStrings("E.Parser.Syntax.031 at 4:2\n", writer.buffered());
}

test "compact IDs are exposed and match the WDP spec vectors" {
    // Authoritative vectors from wdp-specs/test-vectors/data/.
    const id = dot.diagnostic.computeCompactId("E.AUTH.TOKEN.001");
    try std.testing.expectEqualStrings("V6a0B", &id);
    const ns = dot.diagnostic.computeNamespaceHash("auth_lib");
    try std.testing.expectEqualStrings("05o5h", &ns);

    // Registry codes carry precomputed qualified compact IDs (part 7 §5.2).
    const qualified = dot.Code.validation_operator_mismatch.qualifiedCompactId();
    try std.testing.expectEqual(@as(usize, 11), qualified.len);
    try std.testing.expectEqual(@as(u8, '-'), qualified[5]);
}

test "consumer can lex the milestone document from caller-supplied bytes" {
    const source = "graph { a -- b; }";
    var lexer = dot.lexer.Lexer.init(source);

    const expected = [_]dot.lexer.Token.Tag{
        .keyword_graph, .left_brace, .identifier,  .edge_undirected,
        .identifier,    .semicolon,  .right_brace, .eof,
    };
    for (expected) |tag| {
        const result = lexer.next();
        try std.testing.expect(result == .token);
        try std.testing.expectEqual(tag, result.token.tag);
    }
}

test "consumer sees a structured failure for deferred DOT features" {
    var lexer = dot.lexer.Lexer.init("digraph D { a -> b; }");
    const result = lexer.next();
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(dot.Code.profile_unsupported_feature, result.failure.code);
    try std.testing.expectEqual(
        dot.diagnostic.Feature.digraph_document,
        result.failure.details.unsupported_feature,
    );
}

test "milestone acceptance through the public façade" {
    const source = "graph {\n    a -> b;\n    c -> d;\n}";
    var bag: dot.FixedDiagnosticBag(8) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);

    // Parsing succeeds (the engine is kind-agnostic) …
    try std.testing.expect(checked.outcome == .success);
    try std.testing.expectEqual(@as(usize, 2), checked.document.?.statementCount());

    // … and validation completes with both violations, in source order.
    try std.testing.expect(!checked.documentValid());
    try std.testing.expect(checked.validation.?.outcome == .completed);
    try std.testing.expectEqual(@as(usize, 2), checked.validation.?.outcome.completed.violations);
    try std.testing.expectEqual(@as(usize, 2), bag.items().len);

    const first = bag.items()[0];
    try std.testing.expectEqualStrings("E.Validation.Operator.002", first.code.structured());
    try std.testing.expectEqualStrings("->", first.span.slice(source));
    try std.testing.expectEqual(@as(usize, 2), first.span.start.line);
    try std.testing.expect(
        first.span.start.byte_offset < bag.items()[1].span.start.byte_offset,
    );
}

test "parseBorrowed returns a caller-owned document over borrowed source" {
    const source = "graph { a; a -- b; }";
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var parsed = dot.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.outcome == .success);
    const document = parsed.document.?;
    try std.testing.expectEqual(dot.GraphKind.undigraph, document.kind);
    try std.testing.expectEqual(@as(usize, 2), document.statementCount());
    try std.testing.expectEqualStrings(
        "a",
        document.statementAt(0).?.node.identifier.slice(source),
    );
    const edge = document.statementAt(1).?.edge;
    try std.testing.expectEqual(dot.EdgeOperator.undirected, edge.operator);
    try std.testing.expectEqualStrings("b", edge.right.slice(source));
}

test "façade surfaces parse failures with a null document and a filled bag" {
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var parsed = dot.parseBorrowed(std.testing.allocator, "digraph { a -> b; }", bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.outcome == .unsupported_feature);
    try std.testing.expect(parsed.document == null);
    try std.testing.expectEqual(
        dot.diagnostic.Feature.digraph_document,
        bag.items()[0].details.unsupported_feature,
    );

    // The one-shot reports the same failure with no validation attempted.
    var check_bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, "digraph {}", check_bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try std.testing.expect(checked.outcome == .unsupported_feature);
    try std.testing.expect(checked.validation == null);
    try std.testing.expect(!checked.documentValid());
}

test "a fully valid document checks clean through the façade" {
    const source = "graph { a; b; a -- b; }";
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);

    try std.testing.expect(checked.outcome == .success);
    try std.testing.expect(checked.documentValid());
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
    try std.testing.expectEqual(dot.diagnostic.Delivery.complete, checked.diagnostic_delivery);
}

test "capacity hints enable fixed-buffer parsing through the façade" {
    const source = "graph { a; a -- b; b; }";
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(fba.allocator(), source, bag.sink(), .{
        .parse = .{
            .max_statements = 3,
            .document_capacities = .{ .statements = 3, .nodes = 2, .edges = 1 },
        },
    });

    try std.testing.expect(checked.outcome == .success);
    try std.testing.expect(checked.documentValid());
    try std.testing.expectEqual(@as(usize, 3), checked.document.?.statementCount());
    // Fixed-buffer bulk release: reset the allocator instead of deinit.
    fba.reset();
}

test "storage failures surface as the public taxonomy, not sink errors" {
    const source = "graph { a; b; c; d; e; f; g; h; }";
    var buffer: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    var bag: dot.FixedDiagnosticBag(4) = .{};
    var parsed = dot.parseBorrowed(fba.allocator(), source, bag.sink(), .{});
    defer parsed.deinit(fba.allocator());

    try std.testing.expect(parsed.outcome == .storage_failure);
    try std.testing.expectEqual(dot.StorageFailure.out_of_memory, parsed.outcome.storage_failure);
    try std.testing.expect(parsed.document == null);

    // Storage failures are explained through the sink like any failure.
    try std.testing.expectEqual(@as(usize, 1), bag.items().len);
    try std.testing.expectEqual(dot.Code.resource_memory_exhausted, bag.items()[0].code);
}

test "a rejecting sink during validation merges into the one-shot delivery" {
    const Rejecting = struct {
        fn emit(context: ?*anyopaque, d: dot.Diagnostic) dot.DiagnosticSinkError!void {
            _ = context;
            _ = d;
            return error.DiagnosticSinkFailure;
        }
    };
    const sink: dot.DiagnosticSink = .{ .context = null, .emit_fn = Rejecting.emit };

    // Parsing succeeds (emits nothing); validation emits one mismatch that
    // the sink rejects — the loss must surface in the merged delivery.
    var checked = dot.parseAndValidate(std.testing.allocator, "graph { a -> b; }", sink, .{});
    defer checked.deinit(std.testing.allocator);

    try std.testing.expect(checked.outcome == .success);
    try std.testing.expect(!checked.documentValid());
    try std.testing.expectEqual(dot.diagnostic.Delivery.failed, checked.diagnostic_delivery);
}

test "parseBorrowedIn parses into caller slices with no allocator" {
    const source = "graph { a; a -- b; b; }";
    var storage: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8 }) = .{};
    var bag: dot.FixedDiagnosticBag(4) = .{};

    const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{});
    try std.testing.expect(parsed.outcome == .success);

    const document = parsed.document.?;
    try std.testing.expectEqual(@as(usize, 3), document.statementCount());

    var iterator = document.statements();
    try std.testing.expectEqualStrings("a", document.text(iterator.next().?.node.identifier));
    try std.testing.expect(iterator.next().? == .edge);

    // Validation works identically on fixed-storage documents.
    const validation = dot.validate(&document, bag.sink(), .{});
    try std.testing.expect(validation.documentValid());
}

test "parseBorrowedIn reports pool exhaustion as a storage failure" {
    var ids: [1]dot.StatementId = undefined;
    var nodes: [1]dot.NodeStatement = undefined;
    var edges: [1]dot.EdgeStatement = undefined;

    var bag: dot.FixedDiagnosticBag(4) = .{};
    const parsed = dot.parseBorrowedIn("graph { a; b; }", .{
        .statement_ids = &ids,
        .nodes = &nodes,
        .edges = &edges,
    }, bag.sink(), .{});

    try std.testing.expect(parsed.outcome == .storage_failure);
    try std.testing.expectEqual(dot.StorageFailure.pool_exhausted, parsed.outcome.storage_failure);
    try std.testing.expect(parsed.document == null);

    // The diagnostic names the exhausted pool and its capacity.
    try std.testing.expectEqual(@as(usize, 1), bag.items().len);
    const failure = bag.items()[0];
    try std.testing.expectEqual(dot.Code.resource_capacity_exhausted, failure.code);
    try std.testing.expectEqual(
        dot.diagnostic.Capacity.Resource.node_pool,
        failure.details.capacity.resource,
    );
    try std.testing.expectEqual(@as(usize, 1), failure.details.capacity.limit);
}

test "the discard sink makes ignoring diagnostics explicit" {
    var parsed = dot.parseBorrowed(
        std.testing.allocator,
        "graph {",
        dot.diagnostic.discard,
        .{},
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.outcome == .invalid_syntax);
}

test "location tracking is exposed for consumers" {
    var tracker: dot.location.Tracker = .{};
    tracker.advanceSlice("graph {\r\n  a;\n");
    try std.testing.expectEqual(@as(usize, 3), tracker.location.line);
    try std.testing.expectEqual(@as(usize, 1), tracker.location.byte_column);
}
