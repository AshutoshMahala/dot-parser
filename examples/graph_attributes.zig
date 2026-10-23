//! Defaults apply when an object is created. Later explicit attributes update
//! only their own keys, and values retain their source locations.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source =
        \\digraph {
        \\    node [color=red];
        \\    a;
        \\    node [color=blue];
        \\    b;
        \\    a [shape=box];
        \\    a -> b [weight=2];
        \\}
    ;
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();

    const printed = printAttributes(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printAttributes(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;

    var nodes = ir.nodeIterator();
    while (nodes.next()) |node| {
        // Effective values include defaults and b's implicit empty shape.
        var attributes = try node.attributes(.{});
        defer attributes.deinit();
        while (try attributes.next()) |attribute|
            std.debug.print("node {f}: {f}=\"{f}\"\n", .{
                node.name(), attribute.key(), attribute.value(),
            });
    }
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |edge| {
        const weight = (try edge.attribute("weight")).?;
        std.debug.print("edge {f} -> {f}: weight={f}\n", .{
            edge.from().name(), edge.to().name(), weight.value(),
        });
    }
}

// Output:
// node a: color="red"
// node a: shape="box"
// node b: color="blue"
// node b: shape=""
// edge a -> b: weight=2
