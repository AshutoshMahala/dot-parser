//! Public integration tests. These import only the `dot_parser` module,
//! exactly like an external consumer (PROJECT_STRUCTURE.md, test level 2).

const std = @import("std");
const dot = @import("dot_parser");

test "consumer can collect diagnostics through a fixed bag" {
    var bag: dot.FixedDiagnosticBag(16) = .{};
    const sink = bag.sink();

    // Simulate what validating `graph { a -> b; c -> d; }` will emit.
    try sink.emit(.{
        .code = .validation_operator_mismatch,
        .span = .{
            .start = .{ .byte_offset = 10, .line = 2, .byte_column = 7 },
            .byte_len = 2,
        },
        .details = .{ .expected_found = .{ .expected = "'--'", .found = "'->'" } },
    });
    try sink.emit(.{
        .code = .validation_operator_mismatch,
        .span = .{
            .start = .{ .byte_offset = 21, .line = 3, .byte_column = 7 },
            .byte_len = 2,
        },
        .details = .{ .expected_found = .{ .expected = "'--'", .found = "'->'" } },
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
        .details = .{ .unsupported_feature = "digraph document" },
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
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "┌─ Error 1 ─── [dot_parser:E.Parser.Syntax.003]") != null);

    var ascii_writer = std.Io.Writer.fixed(&buffer);
    try dot.console.renderBoxedList(&diagnostics, 0, .{ .source_name = "pipe", .style = .ascii }, &ascii_writer);
    try std.testing.expect(std.mem.indexOf(u8, ascii_writer.buffered(), "-- Error 1 - [dot_parser:E.Parser.Syntax.003]") != null);
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

test "location tracking is exposed for consumers" {
    var tracker: dot.location.Tracker = .{};
    tracker.advanceSlice("graph {\r\n  a;\n");
    try std.testing.expectEqual(@as(usize, 3), tracker.location.line);
    try std.testing.expectEqual(@as(usize, 1), tracker.location.byte_column);
}
