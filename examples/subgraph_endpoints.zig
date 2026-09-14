//! Syntactic endpoints, not an eagerly expanded node-to-node edge product.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var result = dot.parseBorrowed(allocator, "digraph { a:out -> { b; c } -> d [color=blue] }", dot.diagnostic.discard, .{});
    defer result.deinit(allocator);
    if (result.outcome != .success) return error.ParseFailed;
    const document = &result.document.?;
    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    var edges = document.edgeIterator();
    while (edges.next()) |edge| {
        try writeEndpoint(document, edge.left, writer);
        try writer.print(" {s} ", .{edge.operator.lexeme()});
        try writeEndpoint(document, edge.right, writer);
        try writer.writeByte('\n');
    }
    var scopes = document.subgraphs();
    while (scopes.next()) |scope| {
        try writer.print("scope {d} written nodes:", .{@intFromEnum(scope.id)});
        var references = scope.nodeReferences(.recursive);
        while (references.next()) |reference| {
            try writer.print(" {s}", .{document.text(document.nodeReference(reference).?.identifier)});
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}

fn writeEndpoint(document: *const dot.Document, endpoint: dot.Endpoint, writer: *std.Io.Writer) !void {
    switch (endpoint) {
        .node => |reference| {
            const node = document.nodeReference(reference).?;
            try writer.writeAll(document.text(node.identifier));
            if (node.port) |port| {
                try writer.print(":{s}", .{document.text(port.first)});
                if (port.second) |second| try writer.print(":{s}", .{document.text(second)});
            }
        },
        .subgraph => |id| try writer.print("scope#{d}", .{@intFromEnum(id)}),
    }
}
