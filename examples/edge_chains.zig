//! Source-shaped chains or an allocation-free pairwise traversal.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "digraph { a -> b -> c [color=red] }";
    // One chain owner, one continuation after its first edge; no single-edge pool.
    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .edge_chains = 1, .edge_links = 1, .attributes = 1 }) = .{};
    const parsed = dot.parseBorrowedIn(source, .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
    if (parsed.outcome != .success) return error.ParseFailed;
    const document = &parsed.document.?;
    if (!dot.validate(document, dot.diagnostic.discard, .{}).documentValid()) return error.InvalidDocument;
    const chain = document.statementAt(0).?.edge_chain;
    std.debug.assert(document.edgeLinkSlice(chain.links).?.len == 1);
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    var edges = document.edgeIterator();
    while (edges.next()) |edge| {
        try output.interface.print("{s} {s} {s}: {d} shared attributes\n", .{
            document.text(document.nodeReference(edge.left).?.identifier),  edge.operator.lexeme(),
            document.text(document.nodeReference(edge.right).?.identifier), document.attributeSlice(edge.attributes).?.len,
        });
    }
    try output.interface.flush();
}
