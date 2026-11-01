//! Walk the edges at a node. Adjacency is built only when explicitly requested.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "strict digraph { a -> { b c }; a -> b; b -> b; isolated; }";
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const printed = printGraph(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printGraph(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;
    // Expands edges and builds adjacency; the result borrows ir's names/values.
    var graph = try ir.materialize(.{ .adjacency = .all });
    defer graph.deinit();

    var nodes = graph.nodeIterator();
    while (nodes.next()) |node| {
        std.debug.print("{f}: {} incident edges\n", .{ node.name(), node.edgeCount(.{}) });
        // Follow arrows, and also undirected edges if the graph has any.
        var edges = node.edges(.{ .direction = .forward });
        while (edges.next()) |entry|
            std.debug.print("  forward to {f}\n", .{entry.neighbor().name()});
    }
}

// Output:
// a: 2 incident edges
//   forward to b
//   forward to c
// b: 2 incident edges
//   forward to b
// c: 1 incident edges
// isolated: 0 incident edges
