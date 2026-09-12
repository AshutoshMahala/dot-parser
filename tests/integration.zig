//! Public integration tests. These import only the `dot_parser` module,
//! exactly like an external consumer (PROJECT_STRUCTURE.md, test level 2).

const std = @import("std");
const dot = @import("dot_parser");

test {
    _ = @import("attributes.zig");
}

const Rejecting = struct {
    fn emit(_: ?*anyopaque, _: dot.Diagnostic) dot.DiagnosticSinkError!void {
        return error.DiagnosticSinkFailure;
    }
};

test "identifier spelling and value agree across allocator and fixed storage" {
    const source = "strict digraph \"G\"+\"raph\" { \"gr\"/**/+\"aph\"; -00.50 -> \"a\\\"b\"; }";
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var parsed = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.documentValid());
    const doc = &parsed.document.?;
    var pools: dot.FixedDocumentStorage(.{ .statements = 2, .nodes = 1, .edges = 1 }) = .{};
    const fixed = dot.parseBorrowedIn(source, pools.storage(), bag.sink(), .{});
    try std.testing.expect(fixed.outcome == .success);
    try std.testing.expectEqualSlices(dot.StatementId, doc.order, fixed.document.?.order);
    try std.testing.expectEqualSlices(dot.NodeStatement, doc.nodes, fixed.document.?.nodes);
    try std.testing.expectEqualSlices(dot.EdgeStatement, doc.edges, fixed.document.?.edges);
    try std.testing.expectEqual(doc.name, fixed.document.?.name);
    var decoded: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Graph", try doc.decodeIdentifier(doc.name.?, &decoded));
    try std.testing.expectEqualStrings("\"gr\"/**/+\"aph\"", doc.text(doc.nodes[0].identifier));
    try std.testing.expectEqualStrings("graph", try doc.decodeIdentifier(doc.nodes[0].identifier, &decoded));
    try std.testing.expectEqualStrings("-00.50", try doc.decodeIdentifier(doc.edges[0].left, &decoded));
    var writer = std.Io.Writer.fixed(&decoded);
    try doc.writeIdentifier(doc.edges[0].right, &writer);
    try std.testing.expectEqualStrings("a\"b", writer.buffered());
    try std.testing.expectError(error.NoSpaceLeft, doc.decodeIdentifier(doc.nodes[0].identifier, decoded[0..1]));
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);
}

test "identifier failures preserve diagnostic delivery and fixed-pool reuse" {
    inline for (.{ "graph { \"x\"; \"a\"+", "graph { \"x\"; \"a", "graph { \"x\"; \"a\x00b\" }" }) |source| {
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expect(parsed.outcome == .invalid_syntax);
        try std.testing.expect(parsed.document == null);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        var pools: dot.FixedDocumentStorage(.{ .statements = 2, .nodes = 2 }) = .{};
        var fixed_bag: dot.FixedDiagnosticBag(1) = .{};
        const fixed = dot.parseBorrowedIn(source, pools.storage(), fixed_bag.sink(), .{});
        try std.testing.expect(fixed.document == null);
        try std.testing.expectEqualSlices(dot.Diagnostic, bag.items(), fixed_bag.items());
        const rejected = dot.parseBorrowedIn(source, pools.storage(), .{ .context = null, .emit_fn = Rejecting.emit }, .{});
        try std.testing.expect(rejected.outcome == .invalid_syntax);
        try std.testing.expectEqual(dot.diagnostic.Delivery.failed, rejected.diagnostic_delivery);
        var empty_bag: dot.FixedDiagnosticBag(0) = .{};
        const omitted = dot.parseBorrowedIn(source, pools.storage(), empty_bag.sink(), .{});
        try std.testing.expect(omitted.outcome == .invalid_syntax);
        try std.testing.expectEqual(@as(usize, 1), empty_bag.omitted);
        const reused = dot.parseBorrowedIn("graph { 1; }", pools.storage(), dot.diagnostic.discard, .{});
        try std.testing.expect(reused.outcome == .success);
    }
}

test "identifier document truncation never commits partial syntax" {
    const source = "digraph \"na\"+\"me\" { \"a\\\"b\" + /* \" */ \"c\" -> -.5; }";
    for (0..source.len) |end| {
        var bag: dot.FixedDiagnosticBag(1) = .{};
        var parsed = dot.parseBorrowed(std.testing.allocator, source[0..end], bag.sink(), .{});
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expect(parsed.outcome != .success);
        try std.testing.expect(parsed.document == null);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        var pools: dot.FixedDocumentStorage(.{ .statements = 1, .edges = 1 }) = .{};
        var fixed_bag: dot.FixedDiagnosticBag(1) = .{};
        const fixed = dot.parseBorrowedIn(source[0..end], pools.storage(), fixed_bag.sink(), .{});
        try std.testing.expect(fixed.document == null);
        try std.testing.expectEqualSlices(dot.Diagnostic, bag.items(), fixed_bag.items());
    }
}

test "quoted identifiers do not hide validation mismatches or unsafe excerpt bytes" {
    const source = "graph { \"\xff\x1b[31m\" -> \"b\"; }";
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try std.testing.expect(checked.outcome == .success);
    try std.testing.expect(!checked.documentValid());
    const d = bag.items()[0];
    const at = std.mem.indexOf(u8, source, "->").?;
    try std.testing.expectEqual(dot.location.locate(source, at), d.span.start);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxed(d, 1, .{ .source = source, .style = .ascii }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\\xFF\\x1B[31m") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, writer.buffered(), 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "^^ expected '--'") != null);
}

test "comments work through fixed storage and preserve validation positions" {
    const source = "# 99 \"ignored\"\r\n/* header */graph {\r\na /* -> ignored */ -> // endpoint\r\nb; }# eof";
    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .edges = 1 }) = .{};
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{ .max_statements = 1 });
    try std.testing.expect(parsed.outcome == .success);
    const document = parsed.document.?;
    try std.testing.expectEqual(@as(usize, 1), document.statementCount());
    try std.testing.expectEqualStrings("a", document.text(document.edges[0].left));
    try std.testing.expectEqualStrings("b", document.text(document.edges[0].right));
    const validation = dot.validate(&document, bag.sink(), .{});
    try std.testing.expect(!validation.documentValid());
    try std.testing.expectEqual(@as(usize, 1), bag.items().len);
    const failure = bag.items()[0];
    try std.testing.expectEqual(dot.Code.validation_operator_mismatch, failure.code);
    try std.testing.expectEqual(@as(usize, 3), failure.span.start.line);
    try std.testing.expectEqualStrings("->", failure.span.slice(source));
    try std.testing.expectEqual(@as(usize, 2), failure.details.operator_mismatch.declaration.start.line);

    var empty: dot.FixedDocumentStorage(.{}) = .{};
    const only_comments = dot.parseBorrowedIn("/* before */graph {// body\n}# after", empty.storage(), dot.diagnostic.discard, .{ .max_statements = 0 });
    try std.testing.expect(only_comments.outcome == .success);
    try std.testing.expectEqual(@as(usize, 0), only_comments.document.?.statementCount());
}

test "unterminated comments abort both storage paths after partial construction" {
    const source = "graph {\r\n  a; /* x";
    var bag: dot.FixedDiagnosticBag(1) = .{};
    var parsed = dot.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.outcome == .invalid_syntax);
    try std.testing.expect(parsed.document == null);
    try std.testing.expectEqual(dot.diagnostic.Delivery.complete, parsed.diagnostic_delivery);
    try std.testing.expectEqual(@as(usize, 1), bag.items().len);
    try std.testing.expectEqual(dot.Code.lexer_unterminated_construct, bag.items()[0].code);
    try std.testing.expectEqual(dot.diagnostic.UnterminatedConstruct.block_comment, bag.items()[0].details.unterminated);
    try std.testing.expectEqualStrings("/*", bag.items()[0].span.slice(source));
    try std.testing.expectEqual(@as(usize, 2), bag.items()[0].span.start.line);
    try std.testing.expectEqual(@as(usize, 6), bag.items()[0].span.start.byte_column);

    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .nodes = 1 }) = .{};
    var fixed_bag: dot.FixedDiagnosticBag(1) = .{};
    const fixed = dot.parseBorrowedIn(source, storage.storage(), fixed_bag.sink(), .{});
    try std.testing.expect(fixed.outcome == .invalid_syntax);
    try std.testing.expect(fixed.document == null);
    try std.testing.expectEqualSlices(dot.Diagnostic, bag.items(), fixed_bag.items());
    const reused = dot.parseBorrowedIn("graph { b; }", storage.storage(), dot.diagnostic.discard, .{});
    try std.testing.expect(reused.outcome == .success);

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxedList(bag.items(), 0, .{ .source = source, .style = .ascii }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "E.Lexer.Syntax.031") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "close the block comment") != null);
}

test "comment failure reporting honors rejected sinks and zero capacity bags" {
    var storage: dot.FixedDocumentStorage(.{}) = .{};
    const rejected = dot.parseBorrowedIn("graph {} /*", storage.storage(), .{ .context = null, .emit_fn = Rejecting.emit }, .{});
    try std.testing.expect(rejected.outcome == .invalid_syntax);
    try std.testing.expectEqual(dot.diagnostic.Delivery.failed, rejected.diagnostic_delivery);
    var bag: dot.FixedDiagnosticBag(0) = .{};
    const omitted = dot.parseBorrowedIn("/*", storage.storage(), bag.sink(), .{});
    try std.testing.expect(omitted.outcome == .invalid_syntax);
    try std.testing.expectEqual(@as(usize, 1), bag.omitted);
    try std.testing.expectEqual(dot.diagnostic.Delivery.complete, omitted.diagnostic_delivery);
}

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
            .byte_len = 8,
        },
        .details = .{ .unsupported_feature = .subgraph },
    }, &writer);

    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "dot_parser:E.Profile.Feature.009") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "subgraph") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "help:") != null);
}

test "consumer can render boxed output in unicode and ascii styles" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const source = "graph} a; }";
    const diagnostics = [_]dot.Diagnostic{.{
        .code = .parser_unexpected_token,
        .span = .{
            .start = .{ .byte_offset = 5, .line = 1, .byte_column = 6 },
            .byte_len = 1,
        },
    }};

    try dot.console.renderBoxedList(&diagnostics, 0, .{ .source_name = "pipe", .source = source }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "┌─ Error 1: unexpected token") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "│ pipe:1:6") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "│ 1 │ graph} a; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "└─ E1 ─ [dot_parser:E.Parser.Syntax.003]") != null);

    var ascii_writer = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxedList(&diagnostics, 0, .{ .source_name = "pipe", .style = .ascii }, &ascii_writer);
    try std.testing.expect(std.mem.indexOf(u8, ascii_writer.buffered(), "-- Error 1: unexpected token") != null);
    try std.testing.expect(std.mem.indexOf(u8, ascii_writer.buffered(), "-- E1 - [dot_parser:E.Parser.Syntax.003]") != null);
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
    var lexer = dot.lexer.Lexer.init("<html>");
    const result = lexer.next();
    try std.testing.expect(result == .failure);
    try std.testing.expectEqual(dot.Code.profile_unsupported_feature, result.failure.code);
    try std.testing.expectEqual(
        dot.diagnostic.Feature.html_identifier,
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
    var parsed = dot.parseBorrowed(std.testing.allocator, "graph { { a } }", bag.sink(), .{});
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.outcome == .unsupported_feature);
    try std.testing.expect(parsed.document == null);
    try std.testing.expectEqual(
        dot.diagnostic.Feature.subgraph,
        bag.items()[0].details.unsupported_feature,
    );

    // The one-shot reports the same failure with no validation attempted.
    var check_bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, "graph { subgraph s; }", check_bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);
    try std.testing.expect(checked.outcome == .unsupported_feature);
    try std.testing.expect(checked.validation == null);
    try std.testing.expect(!checked.documentValid());
}

test "directed documents check clean end-to-end through the façade" {
    const source = "strict digraph Routes {\n    hub -> a\n    hub -> b;\n}";
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);

    try std.testing.expect(checked.outcome == .success);
    try std.testing.expect(checked.documentValid());
    try std.testing.expectEqual(@as(usize, 0), bag.items().len);

    const document = checked.document.?;
    try std.testing.expectEqual(dot.GraphKind.digraph, document.kind);
    try std.testing.expect(document.strict);
    try std.testing.expectEqualStrings("Routes", document.text(document.name.?));
    try std.testing.expectEqual(@as(usize, 2), document.edges.len);
}

test "a directed document with the wrong operator is flagged by validation" {
    const source = "digraph { a -- b; }";
    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(std.testing.allocator, source, bag.sink(), .{});
    defer checked.deinit(std.testing.allocator);

    try std.testing.expect(checked.outcome == .success);
    try std.testing.expect(!checked.documentValid());
    const failure = bag.items()[0];
    try std.testing.expectEqualStrings("--", failure.span.slice(source));
    try std.testing.expectEqual(
        dot.diagnostic.OperatorMismatch.Operator.directed,
        failure.details.operator_mismatch.expected,
    );
    try std.testing.expectEqualStrings("digraph", failure.details.operator_mismatch.declaration.slice(source));
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

test "parseBorrowedIn carries the full document header" {
    // The fixed builder stores kind/strict/name through its own path;
    // cover it directly, not just via the allocator builder.
    const source = "strict digraph Name { a -> b }";
    var storage: dot.FixedDocumentStorage(.{ .statements = 4, .nodes = 4, .edges = 4 }) = .{};
    var bag: dot.FixedDiagnosticBag(4) = .{};

    const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{});
    try std.testing.expect(parsed.outcome == .success);

    const document = parsed.document.?;
    try std.testing.expectEqual(dot.GraphKind.digraph, document.kind);
    try std.testing.expect(document.strict);
    try std.testing.expectEqualStrings("Name", document.text(document.name.?));
    try std.testing.expectEqual(@as(usize, 1), document.edges.len);
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

// ---------------------------------------------------------------------------
// Corpus tests (PROJECT_STRUCTURE.md test level 3): reusable DOT inputs,
// grouped by expected outcome class.
// ---------------------------------------------------------------------------

/// A well-formed fixture with its expected parse, so a regression that
/// silently drops or reorders statements cannot pass on outcome class alone.
const ValidEntry = struct {
    name: []const u8,
    source: []const u8,
    /// Statement kinds: 'n' node, 'e' edge, 'a' assignment, 'd' attribute statement.
    shape: []const u8,
    nodes: usize,
    edges: usize,
    /// Text of the first statement's identifier/left endpoint (null when
    /// the document is empty).
    first_text: ?[]const u8,
    // Expected document header.
    kind: dot.GraphKind = .undigraph,
    strict: bool = false,
    /// Expected graph-name text (null for anonymous documents).
    graph_name: ?[]const u8 = null,
};

const valid_corpus = [_]ValidEntry{
    .{ .name = "attributes", .source = @embedFile("corpus/valid/attributes.dot"), .shape = "adddnen", .nodes = 2, .edges = 1, .first_text = "rankdir", .kind = .digraph, .graph_name = "G" },
    .{ .name = "node_attribute", .source = @embedFile("corpus/valid/node_attribute.dot"), .shape = "d", .nodes = 0, .edges = 0, .first_text = "node" },
    .{ .name = "numeral_identifiers", .source = @embedFile("corpus/valid/numeral_identifiers.dot"), .shape = "nne", .nodes = 2, .edges = 1, .first_text = "0", .kind = .digraph, .graph_name = "-0.5" },
    .{ .name = "quoted_identifiers", .source = @embedFile("corpus/valid/quoted_identifiers.dot"), .shape = "ne", .nodes = 1, .edges = 1, .first_text = "\"node\"", .graph_name = "\"graph\"" },
    .{ .name = "quoted_concatenation", .source = @embedFile("corpus/valid/quoted_concatenation.dot"), .shape = "e", .nodes = 0, .edges = 1, .first_text = "\"a\" /* between parts */ + \"b\"", .kind = .digraph, .graph_name = "\"G\" + \"raph\"" },
    .{ .name = "comments", .source = @embedFile("corpus/valid/comments.dot"), .shape = "nne", .nodes = 2, .edges = 1, .first_text = "a", .kind = .digraph, .strict = true, .graph_name = "G" },
    .{ .name = "minimal", .source = @embedFile("corpus/valid/minimal.dot"), .shape = "", .nodes = 0, .edges = 0, .first_text = null },
    .{ .name = "digraph", .source = @embedFile("corpus/valid/digraph.dot"), .shape = "e", .nodes = 0, .edges = 1, .first_text = "a", .kind = .digraph },
    .{ .name = "graph_name", .source = @embedFile("corpus/valid/graph_name.dot"), .shape = "n", .nodes = 1, .edges = 0, .first_text = "a", .graph_name = "G" },
    .{ .name = "optional_semicolon", .source = @embedFile("corpus/valid/optional_semicolon.dot"), .shape = "n", .nodes = 1, .edges = 0, .first_text = "a" },
    .{ .name = "strict", .source = @embedFile("corpus/valid/strict.dot"), .shape = "e", .nodes = 0, .edges = 1, .first_text = "a", .strict = true },
    .{ .name = "no_semicolons", .source = @embedFile("corpus/valid/no_semicolons.dot"), .shape = "ee", .nodes = 0, .edges = 2, .first_text = "a", .kind = .digraph, .graph_name = "G" },
    .{ .name = "nodes", .source = @embedFile("corpus/valid/nodes.dot"), .shape = "nnn", .nodes = 3, .edges = 0, .first_text = "alpha" },
    .{ .name = "edges", .source = @embedFile("corpus/valid/edges.dot"), .shape = "eee", .nodes = 0, .edges = 3, .first_text = "a" },
    .{ .name = "mixed", .source = @embedFile("corpus/valid/mixed.dot"), .shape = "neen", .nodes = 2, .edges = 2, .first_text = "hub" },
    .{ .name = "crlf", .source = @embedFile("corpus/valid/crlf.dot"), .shape = "ne", .nodes = 1, .edges = 1, .first_text = "a" },
};

/// A malformed fixture with the exact diagnostic it must produce.
const InvalidEntry = struct {
    name: []const u8,
    source: []const u8,
    code: dot.Code,
    /// Byte offset of the diagnostic's primary span.
    offset: usize,
    construct: ?dot.diagnostic.UnterminatedConstruct = null,
};

const invalid_corpus = [_]InvalidEntry{
    .{ .name = "missing_attribute_value", .source = @embedFile("corpus/invalid/missing_attribute_value.dot"), .code = .parser_unexpected_token, .offset = 13 },
    .{ .name = "missing_attribute_equals", .source = @embedFile("corpus/invalid/missing_attribute_equals.dot"), .code = .parser_unexpected_token, .offset = 12 },
    .{ .name = "truncated_attribute", .source = @embedFile("corpus/invalid/truncated_attribute.dot"), .code = .parser_unexpected_end, .offset = 15 },
    .{ .name = "unterminated_comment", .source = @embedFile("corpus/invalid/unterminated_comment.dot"), .code = .lexer_unterminated_construct, .offset = 11, .construct = .block_comment },
    .{ .name = "unterminated_comment_before_header", .source = @embedFile("corpus/invalid/unterminated_comment_before_header.dot"), .code = .lexer_unterminated_construct, .offset = 0, .construct = .block_comment },
    .{ .name = "unterminated_comment_after_document", .source = @embedFile("corpus/invalid/unterminated_comment_after_document.dot"), .code = .lexer_unterminated_construct, .offset = 9, .construct = .block_comment },
    .{ .name = "unterminated_quoted_identifier", .source = @embedFile("corpus/invalid/unterminated_quoted_identifier.dot"), .code = .lexer_unterminated_construct, .offset = 8, .construct = .quoted_identifier },
    .{ .name = "invalid_quoted_concatenation", .source = @embedFile("corpus/invalid/invalid_quoted_concatenation.dot"), .code = .lexer_invalid_concatenation, .offset = 14 },
    .{ .name = "truncated", .source = @embedFile("corpus/invalid/truncated.dot"), .code = .parser_unexpected_end, .offset = 7 },
    .{ .name = "missing_brace", .source = @embedFile("corpus/invalid/missing_brace.dot"), .code = .parser_unexpected_token, .offset = 6 },
    .{ .name = "invalid_byte", .source = @embedFile("corpus/invalid/invalid_byte.dot"), .code = .lexer_invalid_byte, .offset = 8 },
    .{ .name = "trailing", .source = @embedFile("corpus/invalid/trailing.dot"), .code = .parser_unexpected_token, .offset = 13 },
    .{ .name = "missing_endpoint", .source = @embedFile("corpus/invalid/missing_endpoint.dot"), .code = .parser_unexpected_token, .offset = 13 },
};

/// A valid-but-deferred fixture with the exact feature it must name.
const UnsupportedEntry = struct {
    name: []const u8,
    source: []const u8,
    feature: dot.diagnostic.Feature,
};

const unsupported_corpus = [_]UnsupportedEntry{
    .{ .name = "subgraph", .source = @embedFile("corpus/unsupported/subgraph.dot"), .feature = .subgraph },
    .{ .name = "edge_chain", .source = @embedFile("corpus/unsupported/edge_chain.dot"), .feature = .edge_chain },
};

fn documentShape(document: *const dot.Document, buffer: []u8) []const u8 {
    var length: usize = 0;
    var statements = document.statements();
    while (statements.next()) |statement| : (length += 1) {
        buffer[length] = switch (statement) {
            .node => 'n',
            .edge => 'e',
            .assignment => 'a',
            .attribute_statement => 'd',
        };
    }
    return buffer[0..length];
}

test "valid corpus parses to the expected statements, deterministically" {
    for (valid_corpus) |entry| {
        errdefer std.debug.print("corpus fixture: valid/{s}\n", .{entry.name});

        var bag: dot.FixedDiagnosticBag(4) = .{};
        var checked = dot.parseAndValidate(std.testing.allocator, entry.source, bag.sink(), .{});
        defer checked.deinit(std.testing.allocator);
        try std.testing.expect(checked.outcome == .success);
        try std.testing.expect(checked.documentValid());
        try std.testing.expectEqual(@as(usize, 0), bag.items().len);

        // Semantic expectations, not just the outcome class.
        const document = &checked.document.?;
        try std.testing.expectEqual(entry.kind, document.kind);
        try std.testing.expectEqual(entry.strict, document.strict);
        if (entry.graph_name) |expected_name| {
            try std.testing.expectEqualStrings(expected_name, document.text(document.name.?));
        } else {
            try std.testing.expect(document.name == null);
        }
        var shape_buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings(entry.shape, documentShape(document, &shape_buffer));
        try std.testing.expectEqual(entry.nodes, document.nodes.len);
        try std.testing.expectEqual(entry.edges, document.edges.len);
        if (entry.first_text) |expected_text| {
            const actual = switch (document.statementAt(0).?) {
                .node => |node| document.text(node.identifier),
                .edge => |edge| document.text(edge.left),
                .assignment => |assignment| document.text(assignment.key),
                .attribute_statement => |statement| document.text(statement.keyword),
            };
            try std.testing.expectEqualStrings(expected_text, actual);
        }

        // Determinism: a second run reproduces the identical document —
        // order, pools, and borrowed ranges, not just the shape.
        var second_bag: dot.FixedDiagnosticBag(4) = .{};
        var second = dot.parseAndValidate(std.testing.allocator, entry.source, second_bag.sink(), .{});
        defer second.deinit(std.testing.allocator);
        const second_document = &second.document.?;
        try std.testing.expectEqualSlices(dot.Attribute, document.attributes, second_document.attributes);
        try std.testing.expectEqualSlices(dot.Assignment, document.assignments, second_document.assignments);
        try std.testing.expectEqualSlices(dot.AttributeStatement, document.attribute_statements, second_document.attribute_statements);
        try std.testing.expectEqualSlices(dot.StatementId, document.order, second_document.order);
        try std.testing.expectEqualSlices(dot.NodeStatement, document.nodes, second_document.nodes);
        try std.testing.expectEqualSlices(dot.EdgeStatement, document.edges, second_document.edges);
        var pools: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8, .attributes = 16, .assignments = 8, .attribute_statements = 8 }) = .{};
        const fixed = dot.parseBorrowedIn(entry.source, pools.storage(), dot.diagnostic.discard, .{});
        try std.testing.expect(fixed.outcome == .success);
        try std.testing.expectEqualSlices(dot.StatementId, document.order, fixed.document.?.order);
        try std.testing.expectEqualSlices(dot.NodeStatement, document.nodes, fixed.document.?.nodes);
        try std.testing.expectEqualSlices(dot.EdgeStatement, document.edges, fixed.document.?.edges);
        try std.testing.expectEqualSlices(dot.Attribute, document.attributes, fixed.document.?.attributes);
        try std.testing.expectEqualSlices(dot.Assignment, document.assignments, fixed.document.?.assignments);
        try std.testing.expectEqualSlices(dot.AttributeStatement, document.attribute_statements, fixed.document.?.attribute_statements);
    }
}

test "invalid corpus fails with the expected diagnostic and terminates" {
    for (invalid_corpus) |entry| {
        errdefer std.debug.print("corpus fixture: invalid/{s}\n", .{entry.name});

        var bag: dot.FixedDiagnosticBag(4) = .{};
        var checked = dot.parseAndValidate(std.testing.allocator, entry.source, bag.sink(), .{});
        defer checked.deinit(std.testing.allocator);
        try std.testing.expect(checked.outcome == .invalid_syntax);
        try std.testing.expect(checked.document == null);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);

        const failure = bag.items()[0];
        try std.testing.expectEqual(entry.code, failure.code);
        try std.testing.expectEqual(entry.offset, failure.span.start.byte_offset);
        if (failure.code == .lexer_unterminated_construct) {
            try std.testing.expectEqual(entry.construct.?, failure.details.unterminated);
        }
        var pools: dot.FixedDocumentStorage(.{ .statements = 4, .nodes = 4, .edges = 4, .attributes = 8, .assignments = 4, .attribute_statements = 4 }) = .{};
        var fixed_bag: dot.FixedDiagnosticBag(1) = .{};
        const fixed = dot.parseBorrowedIn(entry.source, pools.storage(), fixed_bag.sink(), .{});
        try std.testing.expect(fixed.outcome == .invalid_syntax);
        try std.testing.expect(fixed.document == null);
        try std.testing.expectEqualSlices(dot.Diagnostic, bag.items(), fixed_bag.items());
    }
}

test "unsupported corpus names the exact deferred feature" {
    for (unsupported_corpus) |entry| {
        errdefer std.debug.print("corpus fixture: unsupported/{s}\n", .{entry.name});

        var bag: dot.FixedDiagnosticBag(4) = .{};
        var checked = dot.parseAndValidate(std.testing.allocator, entry.source, bag.sink(), .{});
        defer checked.deinit(std.testing.allocator);
        try std.testing.expect(checked.outcome == .unsupported_feature);
        try std.testing.expectEqual(@as(usize, 1), bag.items().len);
        try std.testing.expectEqual(entry.feature, bag.items()[0].details.unsupported_feature);
    }
}

// ---------------------------------------------------------------------------
// Fuzzing (PROJECT_STRUCTURE.md test level 4). Runs as a smoke test in a
// normal `zig build test`. Verified real-fuzzing invocation on Zig 0.16.0:
//
//     zig build -Doptimize=ReleaseFast test --fuzz=1000
//
// (The Debug fuzz runner in Zig 0.16.0 fails with a StackTrace type
// mismatch inside std's test runner — a toolchain issue, not a library
// one; use the ReleaseFast form above.)
// ---------------------------------------------------------------------------

test "fuzz: arbitrary bytes terminate without crashing, leaking, or diverging" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    const gpa = std.testing.allocator;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    while (!smith.eos()) {
        const chunk = try input.addManyAsSlice(gpa, smith.value(u6));
        smith.bytes(chunk);
        // Defense-in-depth input cap: Zig's fuzz engine bounds input size
        // implicitly, but this harness may also run under other engines
        // (libFuzzer, AFL) that do not.
        if (input.items.len >= 1 << 20) break;
    }

    var bag: dot.FixedDiagnosticBag(4) = .{};
    var checked = dot.parseAndValidate(gpa, input.items, bag.sink(), .{
        .parse = .{ .max_statements = 4096, .max_attributes = 4096 },
    });
    defer checked.deinit(gpa);

    // Invariants: reaching here means termination; failures explain
    // themselves; success produces a document.
    switch (checked.outcome) {
        .success => try std.testing.expect(checked.document != null),
        .invalid_syntax, .unsupported_feature, .resource_exhausted => {
            try std.testing.expect(checked.document == null);
            try std.testing.expect(bag.items().len >= 1);
        },
        .storage_failure => {},
    }

    // Determinism: a second run over the same bytes agrees — not just on
    // the outcome class and count, but on every diagnostic's identity and
    // position, and on the parsed statements when both succeed.
    var second_bag: dot.FixedDiagnosticBag(4) = .{};
    var second = dot.parseAndValidate(gpa, input.items, second_bag.sink(), .{
        .parse = .{ .max_statements = 4096, .max_attributes = 4096 },
    });
    defer second.deinit(gpa);
    try std.testing.expectEqual(
        std.meta.activeTag(checked.outcome),
        std.meta.activeTag(second.outcome),
    );
    try std.testing.expectEqual(bag.items().len, second_bag.items().len);
    for (bag.items(), second_bag.items()) |first_diag, second_diag| {
        try std.testing.expectEqual(first_diag.code, second_diag.code);
        try std.testing.expectEqual(first_diag.span.start, second_diag.span.start);
        try std.testing.expectEqual(first_diag.span.byte_len, second_diag.span.byte_len);
        // The typed payload too: same code at the same position with a
        // different Feature or Capacity resource is still a regression.
        try std.testing.expectEqual(first_diag.details, second_diag.details);
    }
    if (checked.document) |*first_document| {
        try std.testing.expectEqualSlices(dot.Attribute, first_document.attributes, second.document.?.attributes);
        try std.testing.expectEqualSlices(dot.Assignment, first_document.assignments, second.document.?.assignments);
        try std.testing.expectEqualSlices(dot.AttributeStatement, first_document.attribute_statements, second.document.?.attribute_statements);
        try std.testing.expectEqualSlices(
            dot.StatementId,
            first_document.order,
            second.document.?.order,
        );
    }

    // The fixed-storage twin must terminate on the same bytes too.
    var pools: dot.FixedDocumentStorage(.{ .statements = 64, .nodes = 64, .edges = 64, .attributes = 64, .assignments = 64, .attribute_statements = 64 }) = .{};
    var fixed_bag: dot.FixedDiagnosticBag(4) = .{};
    _ = dot.parseBorrowedIn(input.items, pools.storage(), fixed_bag.sink(), .{});
}

test "location tracking is exposed for consumers" {
    var tracker: dot.location.Tracker = .{};
    tracker.advanceSlice("graph {\r\n  a;\n");
    try std.testing.expectEqual(@as(usize, 3), tracker.location.line);
    try std.testing.expectEqual(@as(usize, 1), tracker.location.byte_column);
}
