//! Pause an existence query without expanding or retaining individual edges.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

pub fn main(init: std.process.Init) !void {
    const source = "digraph { a -> { b c }; }";
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const printed = printAnswer(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printAnswer(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const graph = result.ir() orelse return error.InvalidInput;
    const from = (try graph.findNode("a")) orelse return error.MissingNode;
    const to = (try graph.findNode("c")) orelse return error.MissingNode;
    var query = try IR.hasEdgeSession(graph, from, to, .{});
    defer query.deinit();
    while (true) {
        const progress = query.advance(64);
        if (progress.outcome) |outcome| switch (outcome) {
            .success => |found| {
                std.debug.print("a -> c: {}\n", .{found});
                break;
            },
            .failure => |err| return err,
        };
        // Yield to your scheduler. No outcome yet does not mean "no edge".
    }
}

// Output:
// a -> c: true
