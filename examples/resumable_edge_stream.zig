//! Bounded edge streaming, without retaining a materialized edge array.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

pub fn main(init: std.process.Init) !void {
    const source = "strict digraph { a -> { b c }; a -> b; }";
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const printed = printEdges(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printEdges(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const graph = result.ir() orelse return error.InvalidInput;
    var stream = try IR.edgeSession(graph, .{});
    defer stream.deinit();
    while (true) {
        const progress = stream.advance(64);
        if (progress.edge) |edge|
            std.debug.print("{f} -> {f}\n", .{ edge.from().name(), edge.to().name() });
        if (progress.outcome) |outcome| switch (outcome) {
            .success => break,
            .failure => |err| return err,
        };
        // Yield to your scheduler here. No edge does not mean end of stream.
    }
}

// Output:
// a -> b
// a -> c
