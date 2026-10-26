//! Caller-owned query scratch works with either IR storage backend.
const std = @import("std");
const dot = @import("dot_parser");
const IR = dot.ir.Lowering(.{});

pub fn main(init: std.process.Init) !void {
    const source = "strict digraph { a -> { b c } [color=red]; a->b[color=blue] }";
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

    // Explicit bounds; only this application chooses to allocate these buffers.
    const layout = try IR.edgeScratchLayout(graph, try IR.edgeScratchBounds(graph, .{}));
    const bytes = try gpa.alignedAlloc(u8, .@"16", layout.byte_size);
    defer gpa.free(bytes);
    var edges = try graph.edgeIteratorIn(try layout.bind(bytes), .{});
    defer edges.deinit();
    var attributes: IR.FixedAttributeScratch(.{ .winners = 1 }) = .{};
    while (try edges.next()) |edge| {
        std.debug.print("{f} -> {f}\n", .{ edge.from().name(), edge.to().name() });
        // Reuse attribute scratch while the separate edge stream is paused.
        var values = try edge.attributesIn(attributes.storage(), .{});
        defer values.deinit();
        while (try values.next()) |value|
            std.debug.print("  {f}={f}\n", .{ value.key(), value });
    }
    // Output is incremental. If a pool/limit stops iteration, prior lines are
    // still usable, but they are not a completed export. Restart may replay them.
}
