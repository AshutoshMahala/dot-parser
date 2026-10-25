//! Lower an existing Document in bounded turns; ordinary lowering stays direct.
const std = @import("std");
const dot = @import("dot_parser");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });

pub fn main(init: std.process.Init) !void {
    const source = "digraph { node[color=red]; a->{b c}; \"a\"[color=blue] }";
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const printed = printGraph(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printGraph(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var parsed = Dot.parseAndValidate(gpa, source, sink, .{});
    defer parsed.deinit(gpa);
    if (!parsed.documentValid()) return error.InvalidInput;
    const doc = &parsed.document.?;

    var operation = try IR.loweringSession(gpa, doc, .{ .interpretation = Dot.interpretation(doc, .{}) });
    defer operation.deinit();
    while (operation.advance(64).outcome == null) {
        // Return to your scheduler here. Keep the operation, Document and source
        // alive and unmoved until a later call to advance finishes lowering.
    }
    var ir = try operation.takeResult();
    defer ir.deinit();
    var nodes = ir.nodeIterator();
    while (nodes.next()) |node|
        std.debug.print("{f}: color={?f}\n", .{ node.name(), node.attribute("color") });
}
