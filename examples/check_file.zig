//! Check a DOT file from the command line and render every diagnostic:
//!
//! ```text
//! zig build examples && ./zig-out/bin/check_file path/to/graph.dot
//! ```
//!
//! Without an argument it checks a built-in (deliberately broken) sample and
//! always exits 0, so `zig build examples` can run it unattended. With a
//! file, the exit status is 0 when the document parsed and validated
//! cleanly (warnings allowed) and 1 otherwise. The rendering is the
//! library's out-of-the-box console renderer; `--compact` selects the
//! one-line-per-field log style instead of boxes with source excerpts;
//! `--fail-fast` stops at the first syntax error, the library default.

const std = @import("std");
const dot = @import("dot_parser");

const sample =
    \\digraph {
    \\  subgraph cluster_a {
    \\    a -> b;
    \\  b -> c
    \\}
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(allocator);

    var path: ?[]const u8 = null;
    var compact = false;
    var recovery: dot.Recovery = .statements;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--compact")) {
            compact = true;
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            recovery = .fail_fast;
        } else {
            path = arg;
        }
    }
    const source = if (path) |p|
        try std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .unlimited)
    else
        sample;

    var bag: dot.FixedDiagnosticBag(32) = .{};
    // Keep going after a syntax error so one run shows every problem
    // (`--fail-fast` stops at the first, the library default).
    const Parser = dot.Profile(.{ .runtime_policy = true });
    var checked = try Parser.parseAndValidate(allocator, source, bag.sink(), .{
        .policy = .{ .recovery = recovery },
    });
    defer checked.deinit(allocator);

    const stdout_file: std.Io.File = .stdout();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(stdout_file, io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const color: dot.console.RenderOptions.Color =
        if (stdout_file.supportsAnsiEscapeCodes(io) catch false) .ansi else .none;

    if (compact) {
        for (bag.items()) |d| try dot.console.render(d, .{ .source = source }, stdout);
    } else {
        try dot.console.renderBoxedList(bag.items(), bag.omitted, .{
            .source_name = if (path) |p| std.fs.path.basename(p) else "sample.dot",
            .source = source,
            .color = color,
        }, stdout);
    }
    try stdout.print("{s}: {s}{s}\n", .{
        if (path) |p| p else "sample",                                                                        @tagName(checked.outcome),
        if (checked.documentValid()) "" else if (checked.outcome == .success) " (validation failed)" else "",
    });
    return if (path == null or checked.documentValid()) 0 else 1;
}
