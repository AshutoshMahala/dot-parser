//! Editor snapshots retain useful facts without pretending missing input is valid.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source =
        \\digraph {
        \\    a -> b [color=red];
        \\    broken -> ;
        \\    b -> c [color=blue];
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

    // Same API on complete input. Exhaustion visits retained edges, not missing input.
    var edges = try ir.edgeIterator(.{});
    defer edges.deinit();
    while (try edges.next()) |edge| {
        // These non-strict occurrences keep their own explicit colors.
        switch (try edge.attribute("color")) {
            .known => |color| std.debug.print("{f} -> {f}: color={?f}\n", .{ edge.from().name(), edge.to().name(), color }),
            .unknown => |answer| std.debug.print("{f} -> {f}: color={?f} (may change)\n", .{ edge.from().name(), edge.to().name(), answer.retained }),
        }
    }
    std.debug.print("coverage: {t}\n", .{ir.state()});
}

// Before the diagnostic:
// a -> b: color=red
// b -> c: color=blue
// coverage: partial
