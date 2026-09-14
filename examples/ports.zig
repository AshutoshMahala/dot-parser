//! Raw port syntax, not layout or port-declaration resolution.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "digraph { sensor:out:e -> relay:in -> display; sensor:n }";
    var pools: dot.FixedDocumentStorage(.{
        .statements = 2,
        .nodes = 1,
        .edge_chains = 1,
        .edge_links = 1,
        .ported_references = 3,
    }) = .{};
    const parsed = dot.parseBorrowedIn(source, .{ .document = pools.storage() }, dot.diagnostic.discard, .{});
    const document = parsed.document orelse return error.ParseFailed;
    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &output.interface;

    var edges = document.edgeIterator();
    while (edges.next()) |edge| {
        try writeReference(&document, edge.left, writer);
        try writer.print(" {s} ", .{edge.operator.lexeme()});
        try writeReference(&document, edge.right, writer);
        try writer.writeAll("\n");
    }
    // Source-written qualified occurrences, not unique ports or declarations.
    for (document.ported_references) |reference| {
        try writer.print("written suffix on {s}: {s}\n", .{
            document.text(reference.identifier), document.text(reference.port.first),
        });
    }
    try writer.flush();
}

fn writeReference(document: *const dot.Document, reference: dot.NodeReference, writer: *std.Io.Writer) !void {
    const view = document.nodeReference(reference) orelse return error.InvalidReference;
    try writer.writeAll(document.text(view.identifier));
    if (view.port) |port| {
        try writer.print(":{s}", .{document.text(port.first)});
        if (port.second) |second| try writer.print(":{s}", .{document.text(second)});
    }
}
