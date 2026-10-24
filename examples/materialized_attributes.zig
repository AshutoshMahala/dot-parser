//! Resolve all edge contributions once; then read effective attributes directly.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source =
        \\strict digraph {
        \\    edge [color=red];
        \\    a -> { b c };
        \\    edge [color=blue];
        \\    a -> b [label=updated];
        \\    a -> c [color=green];
        \\}
    ;
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const printed = printEdges(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printEdges(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;

    // Explicit expansion and attribute folding; the result borrows ir's values.
    var graph = try ir.materialize(.{});
    defer graph.deinit();
    // a -> b exists before the blue default, so it keeps red:
    // later defaults never update existing edges; explicit assignments do.
    var edges = graph.edgeIterator();
    while (edges.next()) |edge| {
        std.debug.print("{f} -> {f}: color={?f}, label=\"{?f}\"\n", .{
            edge.from().name(), edge.to().name(), edge.attribute("color"), edge.attribute("label"),
        });
    }
}

// Output:
// a -> b: color=red, label="updated"
// a -> c: color=green, label=""
