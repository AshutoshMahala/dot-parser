//! Demonstrates the WDP diagnostic primitives: a fixed-capacity bag fed
//! through a sink, then rendered to stdout with the out-of-the-box console
//! renderer. The renderer is just one consumer — any application can
//! implement `DiagnosticSink` instead and route diagnostics into its own
//! logging or reporting system.
//!
//! The diagnostics below are hand-built for now; once the milestone-1 parser
//! and validator exist they will produce the same values for this input:
//!
//! ```dot
//! graph {
//!     a -> b;
//! }
//! ```

const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    var bag: dot.FixedDiagnosticBag(8) = .{};
    const sink = bag.sink();

    // What validation will report for `a -> b;` inside an undirected graph.
    try sink.emit(.{
        .code = .validation_operator_mismatch,
        .span = .{
            .start = .{ .byte_offset = 14, .line = 2, .byte_column = 7 },
            .byte_len = 2,
        },
        .details = .{ .operator_mismatch = .{
            .expected = .undirected,
            .found = .directed,
            .declaration = .{
                .start = .{ .byte_offset = 0, .line = 1, .byte_column = 1 },
                .byte_len = 5,
            },
        } },
    });

    // What the parser will report when the input ends inside the body.
    try sink.emit(.{
        .code = .parser_unexpected_end,
        .span = .{
            .start = .{ .byte_offset = 21, .line = 2, .byte_column = 14 },
            .byte_len = 0,
        },
        .details = .{ .unexpected = .{
            .expected = dot.diagnostic.ExpectedSet.init(.{
                .semicolon = true,
                .undirected_operator = true,
                .directed_operator = true,
            }),
            .found = .end_of_input,
            .context = .statement,
            .related = .{
                .span = .{
                    .start = .{ .byte_offset = 6, .line = 1, .byte_column = 7 },
                    .byte_len = 1,
                },
                .role = .opened_here,
            },
        } },
    });

    // What the lexer will report for a byte it cannot start a token with.
    try sink.emit(.{
        .code = .lexer_invalid_byte,
        .span = .{
            .start = .{ .byte_offset = 22, .line = 3, .byte_column = 1 },
            .byte_len = 1,
        },
        .details = .{ .invalid_byte = '@' },
    });

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try dot.console.renderBoxedList(
        bag.items(),
        bag.omitted,
        .{ .source_name = "example.dot" },
        stdout,
    );
    try stdout.flush();
}
