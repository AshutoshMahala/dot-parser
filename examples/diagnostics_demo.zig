//! End-to-end pipeline demo: parse a real DOT document, validate it, and
//! render every collected diagnostic with the out-of-the-box console
//! renderer. The renderer is just one consumer — any application can
//! implement `DiagnosticSink` instead and route diagnostics into its own
//! logging or reporting system.

const std = @import("std");
const dot = @import("dot_parser");

const source =
    \\graph {
    \\    a -- b;
    \\    a -> b;
    \\    b -> c;
    \\}
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var bag: dot.FixedDiagnosticBag(8) = .{};
    var checked = dot.parseAndValidate(allocator, source, bag.sink(), .{});
    defer checked.deinit(allocator);

    const stdout_file: std.Io.File = .stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(stdout_file, init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // Terminal capability is the presenter's decision, never the library's:
    // detect it here and opt in, so pipes and logs stay escape-free.
    const color: dot.console.RenderOptions.Color =
        if (stdout_file.supportsAnsiEscapeCodes(init.io) catch false) .ansi else .none;

    try stdout.print("parsed: {s}, document valid: {}\n\n", .{
        @tagName(checked.outcome), checked.documentValid(),
    });
    try dot.console.renderBoxedList(
        bag.items(),
        bag.omitted,
        .{ .source_name = "example.dot", .source = source, .color = color },
        stdout,
    );
    try stdout.flush();
}
