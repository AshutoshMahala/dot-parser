//! Inspect written attributes without applying defaults or interpreting values.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "digraph { rankdir=LR; node [shape=box]; a [label=\"Bu\"+\"ild\"][color=red color=blue]; a -> b [weight=2]; }";
    var storage: dot.FixedDocumentStorage(.{
        .statements = 4,
        .nodes = 1,
        .edges = 1,
        .assignments = 1,
        .attribute_statements = 1,
        .attributes = 5,
    }) = .{};
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{});
    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (parsed.outcome != .success) {
        try dot.console.renderBoxedList(bag.items(), bag.omitted, .{ .source = source }, writer);
        try writer.flush();
        return;
    }
    const document = &parsed.document.?;
    var statements = document.statements();
    while (statements.next()) |statement| {
        const range: dot.AttributeRange = switch (statement) {
            .edge_chain => |chain| blk: {
                try writer.print("chain {s}: {d} edges\n", .{ document.text(chain.first.left), @as(usize, chain.links.len) + 1 });
                break :blk chain.first.attributes;
            },
            .assignment => |assignment| {
                try writer.print("assignment {s} = {s}\n", .{ document.text(assignment.key), document.text(assignment.value) });
                continue;
            },
            .attribute_statement => |defaults| blk: {
                try writer.print("{s} attributes (written here):\n", .{@tagName(defaults.target)});
                break :blk defaults.attributes;
            },
            .node => |node| blk: {
                try writer.print("node {s}:\n", .{document.text(node.identifier)});
                break :blk node.attributes;
            },
            .edge => |edge| blk: {
                try writer.print("edge {s} {s} {s}:\n", .{ document.text(edge.left), edge.operator.lexeme(), document.text(edge.right) });
                break :blk edge.attributes;
            },
        };
        for (document.attributeSlice(range).?) |attribute| {
            try writer.print("  {s} = ", .{document.text(attribute.key)});
            try document.writeIdentifier(attribute.value, writer);
            try writer.writeAll("\n");
        }
    }
    try writer.flush();
}
