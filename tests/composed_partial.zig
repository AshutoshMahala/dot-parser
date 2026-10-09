const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const Child = markup.Profile(.{ .policy = .{ .mode = .structural, .retention = .{ .partial = true } } });
const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true, .markup = true } }, .processors = .{ .markup = Child } });

test "composed partial child leaves outer syntax complete and retains independent trees" {
    const source = "graph { a [label=<<root><done/></wrong>>+\"tail\"+<<ok/>>]; }";
    var checked = try P.parseAndValidate(gpa, source, P.DiagnosticSink.discard, .{});
    defer checked.deinit(gpa);
    try expect(checked.scopeComplete() and checked.dot.documentValid());
    try expect(!checked.subtreeComplete() and !checked.documentValid());
    try equal(dot.Completeness.partial, checked.state());
    const children = checked.markupResults().?;
    try equal(@as(usize, 2), children.len);
    try strings("<<root><done/></wrong>>", children[0].envelope.slice(source));
    try strings("<root><done/></wrong>", children[0].input.bytes);
    try equal(children[0].envelope.start + 1, children[0].input.origin);
    try equal(markup.Completeness.partial, children[0].result.parse.document.?.state);
    try equal(markup.Completeness.complete, children[1].result.parse.document.?.state);
    try strings("root", children[0].result.parse.document.?.node(@enumFromInt(0)).?.name().?);
    try strings("ok", children[1].result.parse.document.?.node(@enumFromInt(0)).?.name().?);
}

test "composed representation completeness is not validation success" {
    var checked = try P.parseAndValidate(gpa, "graph { a [label=<<r x='1' x='2'/>>]; }", P.DiagnosticSink.discard, .{});
    defer checked.deinit(gpa);
    try expect(checked.scopeComplete() and checked.subtreeComplete());
    try equal(dot.Completeness.complete, checked.state());
    try expect(!checked.documentValid());
    try equal(@as(u32, 1), checked.markup.rejected);
}

test "outer partial retention preserves completed child results without guessing later DOT" {
    var checked = try P.parseAndValidate(gpa, "graph { a [label=<<ok/>>]; b [x=]; later [label=<<after/>>]; }", P.DiagnosticSink.discard, .{});
    defer checked.deinit(gpa);
    try expect(!checked.scopeComplete() and !checked.subtreeComplete());
    try equal(dot.Completeness.partial, checked.dot.document.?.state);
    try equal(@as(usize, 1), checked.dot.document.?.nodes.len);
    // The child pass follows scanner-recognized operands, including recovery.
    // Results are mapped by source spans, not presumed DOT statement handles.
    try equal(@as(usize, checked.markup.visited), checked.markupResults().?.len);
    try expect(checked.markupResults().?[0].result.parse.document.?.scopeComplete());
}

test "composed parent fail fast keeps child prefix and skips outer validation" {
    const Fast = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true, .markup = true }, .on_error = .fail_fast }, .processors = .{ .markup = Child } });
    var checked = try Fast.parseAndValidate(gpa, "graph { first; a [label=<<b></wrong>>]; next; }", Fast.DiagnosticSink.discard, .{});
    defer checked.deinit(gpa);
    try equal(dot.ParseOutcome.processor_stopped, checked.dot.outcome);
    try expect(checked.dot.document != null and checked.dot.validation == null);
    try equal(@as(usize, 1), checked.dot.document.?.nodes.len);
    try equal(@as(usize, 1), checked.markupResults().?.len);
    try equal(markup.Completeness.partial, checked.markupResults().?[0].result.parse.document.?.state);
}

test "runtime child retention is independent of processing and outer partial retention" {
    const R = dot.Profile(.{ .runtime_policy = true, .processors = .{ .markup = Child } });
    const source = "graph { a [label=<<b></wrong>>]; }";
    for ([_]dot.Policy{
        .{},
        .{ .retention = .{ .markup = true } },
        .{ .retention = .{ .markup = true }, .markup = .passthrough },
        .{ .retention = .{ .markup = false } },
    }, 0..) |policy, index| {
        var checked = try R.parseAndValidate(gpa, source, R.DiagnosticSink.discard, .{ .dot = .{ .policy = policy } });
        defer checked.deinit(gpa);
        try equal(index == 1, checked.markupResults() != null);
        try expect(checked.scopeComplete());
        try equal(index == 2, checked.subtreeComplete());
        try equal(index == 2, checked.documentValid());
        try equal(index != 2, checked.markup.requested);
    }
    var empty = try P.parseAndValidate(gpa, "graph {}", P.DiagnosticSink.discard, .{});
    defer empty.deinit(gpa);
    try equal(@as(usize, 0), empty.markupResults().?.len);
    try expect(empty.subtreeComplete());
    const Plain = dot.Profile(.{ .processors = .{ .markup = Child } });
    try equal(@as(usize, 0), @sizeOf(Plain.MarkupResult));
    var unclosed = try R.parseAndValidate(gpa, "graph { a [label=<<b>>];", R.DiagnosticSink.discard, .{ .dot = .{ .policy = .{ .retention = .{ .markup = true } } } });
    defer unclosed.deinit(gpa);
    try expect(unclosed.dot.document == null);
    try equal(@as(usize, 1), unclosed.markupResults().?.len);
}

test "composed sink stops do not run another stage after retaining partial trees" {
    var bag: P.FixedDiagnosticBag(0) = .{};
    var checked = try P.parseAndValidate(gpa, "graph { a [label=<<b></wrong>>]; }", bag.sink(), .{});
    defer checked.deinit(gpa);
    try expect(checked.dot.document != null);
    try expect(checked.dot.validation == null and checked.dot.diagnostic_stop != null);
    try equal(@as(usize, 1), checked.markupResults().?.len);
    try expect(checked.markupResults().?[0].result.validation == null);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var checked = try P.parseAndValidate(allocator, "graph { a [label=<<b/>>+<<r><i/></wrong>>]; b [label=<<ok/>>]; }", P.DiagnosticSink.discard, .{});
    defer checked.deinit(allocator);
    if (checked.dot.outcome == .storage_failure and checked.dot.outcome.storage_failure == .out_of_memory) return error.OutOfMemory;
    if (checked.markup.stop == .retention_storage) return error.OutOfMemory;
    for (checked.markupResults().?) |child| {
        if (child.result.parse.outcome == .out_of_memory) return error.OutOfMemory;
        if (child.result.validation) |v| if (v.completion == .out_of_memory) return error.OutOfMemory;
    }
    try expect(checked.scopeComplete());
    try equal(@as(usize, 3), checked.markupResults().?.len);
}

test "composed child and outer buffers survive all allocation failure sites" {
    try std.testing.checkAllAllocationFailures(gpa, allocationProbe, .{});
}
