//! Editor snapshots retain useful facts without pretending missing input is valid.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source =
        \\digraph {
        \\    a [color=red];
        \\    broken -> ;
        \\    b [color=blue];
        \\}
    ;
    // Keep the first 100 findings, count further ones, and continue analysis.
    var bag: dot.reporting.FixedBag(dot.Diagnostic, 100, .omit) = .{};
    const printed = printSnapshot(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    if (bag.omitted != 0) std.debug.print("{d} more diagnostics omitted\n", .{bag.omitted});
    return printed;
}

fn printSnapshot(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parsePartial(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;

    var nodes = ir.nodeIterator();
    while (nodes.next()) |node| {
        // The gap could update a. It cannot override b's later explicit blue.
        switch (node.attribute("color")) {
            .known => |color| std.debug.print("node {f}: color={?f}\n", .{ node.name(), color }),
            .unknown => |answer| std.debug.print("node {f}: color={?f} (may change)\n", .{ node.name(), answer.retained }),
        }
    }
}

// Before the diagnostic:
// node a: color=red (may change)
// node b: color=blue
