//! Caller-owned IR storage; the accepting Document is built separately.
const std = @import("std");
const dot = @import("dot_parser");
const Dot = dot.Profile(.{});
const IR = dot.ir.Lowering(.{});

pub fn main(init: std.process.Init) !void {
    const source = "digraph { a->b; b->c }";
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

    // Our application's envelope, not an automatic reservation or sizing pass.
    const Retained = IR.FixedGraphStorage(.{
        .nodes = 8,
        .scopes = 1,
        .occurrences = 1,
        .mentions = 16,
        .connections = 8,
        .declarations = 8,
    });
    const Scratch = IR.FixedLoweringScratch(Retained, .{
        .nesting = 2,
        .edge_nesting = 1,
        .pending_endpoints = 2,
    });
    var retained: Retained = .{};
    var scratch: Scratch = .{};
    const lowered = IR.lowerCompleteIn(doc, .{
        .graph = retained.storage(),
        .scratch = scratch.storage(),
    }, .{ .interpretation = Dot.interpretation(doc, .{}) });
    if (lowered.outcome == .failure) {
        if (lowered.shortfall) |missing|
            std.debug.print("{t}: capacity {d}, needs at least {d}\n", .{
                missing.resource, missing.limit, missing.required_at_least,
            });
        return lowered.outcome.failure;
    }
    // Borrows source and retained storage. Scratch is now reusable; no deinit
    // is needed for the fixed result, which owns no allocations.
    var nodes = lowered.graph.?.nodeIterator();
    while (nodes.next()) |node| std.debug.print("node {f}\n", .{node.name()});
}
