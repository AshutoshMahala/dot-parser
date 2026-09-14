//! The embedded story: the complete pipeline with zero heap (milestone 1,
//! step 9). Every byte of storage is a variable in this file — no
//! allocator exists anywhere in the program's parsing path, capacity is
//! visible in the declarations, and there is nothing to free afterwards.

const std = @import("std");
const dot = @import("dot_parser");

const source = "graph { sensor; gateway; sensor -- gateway; }";

pub fn main(init: std.process.Init) !void {
    // Fixed pools: committed eagerly, sized from the same budget as
    // `max_statements`. `byte_size` makes the cost inspectable.
    var storage: dot.FixedDocumentStorage(.{
        .statements = 8,
        .nodes = 8,
        .edges = 4,
    }) = .{};
    var bag: dot.FixedDiagnosticBag(4) = .{};

    const parsed = dot.parseBorrowedIn(source, .{ .document = storage.storage() }, bag.sink(), .{
        .max_statements = 8,
    });

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (parsed.outcome != .success) {
        // A terminal without box-drawing support would use `.style = .ascii`.
        try dot.console.renderBoxedList(bag.items(), bag.omitted, .{}, stdout);
        try stdout.flush();
        return;
    }

    const document = parsed.document.?;
    const validation = dot.validate(&document, bag.sink(), .{});

    try stdout.print("storage: {d} bytes, statements: {d}, valid: {}\n", .{
        @TypeOf(storage).byte_size,
        document.statementCount(),
        validation.documentValid(),
    });

    var statements = document.statements();
    while (statements.next()) |statement| switch (statement) {
        .subgraph => |id| try stdout.print("subgraph scope {d}\n", .{@intFromEnum(id)}),
        .edge_chain => |chain| try stdout.print("chain {s}: {d} edges\n", .{ document.text(document.nodeReference(chain.first.left).?.identifier), @as(usize, chain.links.len) + 1 }),
        .assignment => |assignment| try stdout.print("assignment {s} = {s}\n", .{ document.text(assignment.key), document.text(assignment.value) }),
        .attribute_statement => |attributes| try stdout.print("{s} attributes: {d}\n", .{ @tagName(attributes.target), attributes.attributes.len }),
        .node => |node| try stdout.print("node  {s}\n", .{document.text(document.nodeReference(node.reference).?.identifier)}),
        .edge => |edge| try stdout.print("edge  {s} {s} {s}\n", .{
            document.text(document.nodeReference(edge.left).?.identifier),
            edge.operator.lexeme(),
            document.text(document.nodeReference(edge.right).?.identifier),
        }),
    };
    // Nothing to free: reuse or discard `storage`.
    try stdout.flush();
}
