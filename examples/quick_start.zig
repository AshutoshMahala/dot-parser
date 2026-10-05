//! The README quick start: parse, report problems, then read the edges.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const source =
        \\digraph {
        \\    a -> b;
        \\    b -> c [color=red];
        \\}
    ;

    // Problems are collected here instead of being printed or thrown.
    var bag = dot.GrowableDiagnosticBag.init(allocator, .{});
    defer bag.deinit();

    // Parse the text, then check it (for example, `--` inside a digraph).
    var result = dot.parseAndValidate(allocator, source, bag.sink(), .{});
    defer result.deinit(allocator);

    if (!result.documentValid()) {
        for (bag.items(), 1..) |problem, number| {
            try dot.console.renderBoxed(problem, number, .{ .source = source, .source_name = "graph.dot" }, stdout);
        }
        return;
    }

    const document = result.document.?;
    var edges = document.edgeIterator();
    while (edges.next()) |edge| {
        // An edge end is a node or a whole subgraph (`a -> { b c }`).
        if (edge.left != .node or edge.right != .node) continue;
        const from = document.nodeReference(edge.left.node).?.identifier;
        const to = document.nodeReference(edge.right.node).?.identifier;
        try stdout.print("{s} {s} {s}\n", .{
            document.text(from), edge.operator.lexeme(), document.text(to),
        });
    }
}
