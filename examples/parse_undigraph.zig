//! The "hello world" of the library: parse a document, validate it, and
//! print every statement (milestone 1, step 9).

const std = @import("std");
const dot = @import("dot_parser");

const source =
    \\graph {
    \\    a;
    \\    b;
    \\    a -- b;
    \\}
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var bag: dot.FixedDiagnosticBag(8) = .{};
    var checked = dot.parseAndValidate(allocator, source, bag.sink(), .{});
    defer checked.deinit(allocator);

    if (!checked.documentValid()) {
        try dot.console.renderBoxedList(
            bag.items(),
            bag.omitted,
            .{ .source_name = "example.dot" },
            stdout,
        );
        try stdout.flush();
        return;
    }

    const document = checked.document.?;
    try stdout.print("kind: {s}, statements: {d}\n", .{
        @tagName(document.kind), document.statementCount(),
    });

    var statements = document.statements();
    while (statements.next()) |statement| switch (statement) {
        .assignment => |assignment| try stdout.print("assignment {s} = {s}\n", .{ document.text(assignment.key), document.text(assignment.value) }),
        .attribute_statement => |attributes| try stdout.print("{s} attributes: {d}\n", .{ @tagName(attributes.target), attributes.attributes.len }),
        .node => |node| try stdout.print("node  {s}\n", .{
            document.text(node.identifier),
        }),
        .edge => |edge| try stdout.print("edge  {s} {s} {s}\n", .{
            document.text(edge.left),
            edge.operator.lexeme(),
            document.text(edge.right),
        }),
    };
    try stdout.flush();
}
