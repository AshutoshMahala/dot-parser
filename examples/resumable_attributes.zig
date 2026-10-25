//! Pause while resolving a strict edge's attributes, without expanding the graph.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

pub fn main(init: std.process.Init) !void {
    const source = "strict digraph { edge[color=red]; a->b; edge[color=blue]; a->b[label=updated]; }";
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const printed = printAttributes(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printAttributes(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const graph = result.ir() orelse return error.InvalidInput;
    var edges = try graph.edgeIterator(.{});
    defer edges.deinit();
    const edge = (try edges.next()) orelse return;
    // The existing edge keeps its creation-time red default and receives the label update.
    var stream = try IR.attributesSession(edge, .{});
    defer stream.deinit();
    while (true) {
        const progress = stream.advance(64);
        if (progress.attribute) |attribute|
            std.debug.print("{f}={f}\n", .{ attribute.key(), attribute.value() });
        if (progress.outcome) |outcome| switch (outcome) {
            .success => break,
            .failure => |err| return err,
        };
        // Yield to your scheduler here, even if an entry was delivered.
    }
}

// Output:
// color=red
// label=updated
