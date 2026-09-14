//! Hierarchical syntax views, without resolved membership or inherited defaults.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "digraph { subgraph cluster_a { a:p->b->c; { c->d } rank=same } e }";
    var pools: dot.FixedDocumentStorage(.{
        .statements = 6,
        .subgraphs = 2,
        .nodes = 1,
        .edges = 1,
        .edge_chains = 1,
        .edge_links = 1,
        .ported_references = 1,
        .assignments = 1,
    }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 2 }) = .{};
    const parsed = dot.parseBorrowedIn(source, .{
        .document = pools.storage(),
        .scratch = scratch.storage(),
    }, dot.diagnostic.discard, .{});
    const document = parsed.document orelse return error.ParseFailed;
    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &output.interface;

    var scopes = document.subgraphs();
    while (scopes.next()) |scope| {
        try writer.print("scope {d}, parent {d}, name {s}\n", .{
            @intFromEnum(scope.id),                                          @intFromEnum(scope.parent().?),
            if (scope.name()) |name| document.text(name) else "(anonymous)",
        });
        // Direct edges exclude nested scopes; recursive edges include them.
        var edges = scope.edges(.direct);
        while (edges.next()) |edge| {
            try writer.print("  {s} -> {s}\n", .{
                document.text(document.nodeReference(edge.left.node).?.identifier),
                document.text(document.nodeReference(edge.right.node).?.identifier),
            });
        }
    }
    // Global source order is unchanged; scope context is available on demand.
    var statements = document.statements();
    while (statements.nextScoped()) |item| {
        try writer.print("{s} in scope {d}\n", .{
            @tagName(item.statement), @intFromEnum(item.scope),
        });
    }
    try writer.flush();
}
