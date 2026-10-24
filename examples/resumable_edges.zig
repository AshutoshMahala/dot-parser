//! Use bounded turns when an application needs control during edge expansion.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "strict digraph { edge[color=red]; a->{b c}; a->b[label=updated] }";
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

    var operation = try ir.materializationSession(.{});
    defer operation.deinit();
    while (operation.advance(64).outcome == null) {
        // An event-driven application can return to its scheduler here and
        // call advance again later, keeping the operation, IR and source alive.
    }
    // Transfers ownership once, or returns the actual terminal error.
    var graph = try operation.takeResult();
    defer graph.deinit();
    var edges = graph.edgeIterator();
    while (edges.next()) |edge| {
        std.debug.print("{f} -> {f}: color={?f}, label={?f}\n", .{
            edge.from().name(), edge.to().name(), edge.attribute("color"), edge.attribute("label"),
        });
    }
}
