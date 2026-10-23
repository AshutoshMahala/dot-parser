//! DOT names and edge sets, resolved: `a` and `"a"` are one node, and
//! `a -> { b c }` becomes individual edges only when you ask.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source =
        \\digraph {
        \\    a -> { b c };
        \\    "a" -> d;
        \\    subgraph s { x }
        \\}
    ;
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();

    const printed = printGraph(init.gpa, source, bag.sink());
    // Show warnings too, not just diagnostics from failed input.
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printGraph(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;

    // a and "a" are one node; x is a node with no edges.
    var nodes = ir.nodeIterator();
    while (nodes.next()) |node| std.debug.print("node {f}\n", .{node.name()});

    // Expand one edge at a time, without storing the whole edge list.
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |edge|
        std.debug.print("edge {f} {s} {f}\n", .{ edge.from().name(), edge.edge.operator.lexeme(), edge.to().name() });
}

// Output:
// node a
// node b
// node c
// node d
// node x
// edge a -> b
// edge a -> c
// edge a -> d
