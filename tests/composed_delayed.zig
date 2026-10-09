const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const gpa = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const Child = markup.Profile(.{ .policy = .{ .mode = .structural, .retention = .{ .partial = true } } });
const P = dot.Profile(.{
    .policy = .{ .markup = .passthrough, .retention = .{ .markup = true, .partial = true } },
    .processors = .{ .markup = Child },
});

fn span(source: []const u8, raw: []const u8) dot.location.Span {
    return .{ .start = @intCast(std.mem.indexOf(u8, source, raw).?), .len = @intCast(raw.len) };
}

test "delayed selection attaches independent child trees and marks pending work" {
    const source = "graph { a [label=<<ok/>>+\"tail\"+<<r><i/></wrong>> other=<<unchecked/>>]; }";
    var bag: P.FixedDiagnosticBag(16) = .{};
    var result = try P.parseAndValidate(gpa, source, bag.sink(), .{});
    defer result.deinit(gpa);
    const before = result.dot.document.?.nodes.ptr;
    try expect(result.documentValid() and result.subtreeComplete());
    try expect(!result.markup.requested and result.markupResults() == null);
    try result.requestMarkup(gpa, result.dot.document.?.attributes[0].value);
    try equal(@as(usize, 2), result.pendingMarkup().len);
    try equal(@as(usize, 0), result.markupResults().?.len);
    try equal(@as(usize, 0), bag.items().len);
    try expect(result.scopeComplete() and !result.subtreeComplete() and !result.documentValid());
    try equal(dot.Completeness.not_processed, result.state());
    try P.processPendingMarkup(gpa, &result, bag.sink(), .{});
    try expect(result.markup.complete and result.markup.selection == .selected_operands);
    try equal(@as(u32, 2), result.markup.visited);
    try equal(@as(usize, 0), result.pendingMarkup().len);
    try expect(result.scopeComplete() and result.dot.documentValid() and !result.subtreeComplete());
    try equal(dot.Completeness.partial, result.state());
    try equal(before, result.dot.document.?.nodes.ptr);
    const children = result.markupResults().?;
    try expect(children[0].result.subtreeComplete() and !children[1].result.subtreeComplete());
    try std.testing.expectEqualStrings("r", children[1].result.parse.document.?.node(@enumFromInt(0)).?.name().?);
    for (bag.items()) |item| {
        try expect(item == .markup);
        try expect(item.span().start >= children[1].input.origin);
        try expect(item.span().endOffset() <= children[1].envelope.endOffset());
    }
    try std.testing.expectError(error.SelectionClosed, result.requestMarkup(gpa, result.dot.document.?.attributes[1].value));
    try std.testing.expectError(error.SelectionClosed, P.processPendingMarkup(gpa, &result, bag.sink(), .{}));
}

test "delayed complete representation is independent of validity and unselected operands" {
    const source = "graph { a [x=<<a x='1' x='2'/>> y=<<unclosed>>]; }";
    var result = try P.parseAndValidate(gpa, source, P.DiagnosticSink.discard, .{});
    defer result.deinit(gpa);
    try result.requestMarkup(gpa, result.dot.document.?.attributes[0].value);
    try P.processPendingMarkup(gpa, &result, P.DiagnosticSink.discard, .{});
    try expect(result.subtreeComplete() and !result.documentValid());
    try equal(@as(u32, 1), result.markup.rejected);
    try equal(.selected_operands, result.markup.selection);
}

test "delayed admission checks bounds spelling ordering and leaves state unchanged on error" {
    const source = "graph { a [x=<<b/>> y=<<i/>>]; }";
    var result = try P.parseAndValidate(gpa, source, P.DiagnosticSink.discard, .{});
    defer result.deinit(gpa);
    for ([_]dot.location.Span{
        .{ .start = std.math.maxInt(u32), .len = 1 },
        .{ .start = 0, .len = std.math.maxInt(u32) },
        .{ .start = @intCast(source.len), .len = 1 },
    }) |range| try std.testing.expectError(error.InvalidSpan, result.requestMarkup(gpa, range));
    try std.testing.expectError(error.InvalidIdentifier, result.requestMarkup(gpa, .{ .start = 0, .len = 0 }));
    try std.testing.expectError(error.InvalidIdentifier, result.requestMarkup(gpa, span(source, "<<b/>")));
    try equal(@as(usize, 0), result.pendingMarkup().len);
    try expect(!result.markup.requested and result.markupResults() == null);
    try result.requestMarkup(gpa, span(source, "a")); // non-HTML identifiers do nothing
    try expect(!result.markup.requested);
    try result.requestMarkup(gpa, span(source, "<<i/>>"));
    try std.testing.expectError(error.SelectionOutOfOrder, result.requestMarkup(gpa, span(source, "<<i/>>")));
    try std.testing.expectError(error.SelectionOutOfOrder, result.requestMarkup(gpa, span(source, "<<b/>>")));
    try equal(@as(usize, 1), result.pendingMarkup().len);
    try P.processPendingMarkup(gpa, &result, P.DiagnosticSink.discard, .{});
    try expect(result.documentValid() and result.subtreeComplete());
}

test "delayed fixed and runtime policies agree across scanners and latch the parent" {
    const source = "graph { a [x=<<a x='1' x='2'/>> y=<<i/>>]; }";
    inline for (.{ false, true }) |runtime| inline for (.{ .scalar, .block }) |backend| inline for (.{ .collect, .fail_fast }) |parent| {
        const R = dot.Profile(.{
            .runtime_policy = runtime,
            .policy = .{ .scanner = backend, .markup = .passthrough, .retention = .{ .markup = true }, .on_error = if (runtime) .collect else parent },
            .processors = .{ .markup = markup.Profile(.{ .runtime_policy = runtime, .policy = .{ .mode = .structural, .scanner = backend } }) },
        });
        var result = try R.parseAndValidate(gpa, source, R.DiagnosticSink.discard, .{
            .dot = if (runtime) .{ .policy = .{ .on_error = parent } } else .{},
            // This unused child option must not leak into the later operation.
            .markup = if (runtime) .{ .policy = .{ .validation = .{ .duplicate_attribute = .off } } } else .{},
        });
        defer result.deinit(gpa);
        for (result.dot.document.?.attributes) |attribute| try result.requestMarkup(gpa, attribute.value);
        try R.processPendingMarkup(gpa, &result, R.DiagnosticSink.discard, .{});
        try equal(@as(u32, if (parent == .collect) 2 else 1), result.markup.visited);
        try equal(parent == .collect, result.markup.complete);
        try equal(@as(usize, if (parent == .collect) 0 else 1), result.pendingMarkup().len);
        if (parent == .fail_fast) {
            try equal(.parent_error, result.markup.stop.?);
            try equal(dot.Completeness.not_processed, result.state());
        }
    };
}

test "delayed runtime retention and none cannot be bypassed and unused retention allocates nothing" {
    const R = dot.Profile(.{ .runtime_policy = true, .processors = .{ .markup = Child } });
    const source = "graph { a [x=<<b/>>]; }";
    for ([_]dot.Policy{
        .{ .markup = .passthrough },
        .{ .markup = .none, .retention = .{ .markup = true } },
        .{ .retention = .{ .markup = true } },
    }, 0..) |policy, index| {
        var result = try R.parseAndValidate(gpa, source, R.DiagnosticSink.discard, .{ .dot = .{ .policy = policy } });
        defer result.deinit(gpa);
        const err = if (index == 0) error.MarkupRetentionDisabled else error.MarkupNotPassthrough;
        try std.testing.expectError(err, result.requestMarkup(gpa, span(source, "<<b/>>")));
        try std.testing.expectError(err, R.processPendingMarkup(gpa, &result, R.DiagnosticSink.discard, .{}));
    }
    const Plain = dot.Profile(.{ .policy = .{ .markup = .passthrough }, .processors = .{ .markup = Child } });
    var a = std.testing.FailingAllocator.init(gpa, .{});
    var b = std.testing.FailingAllocator.init(gpa, .{});
    var plain = try Plain.parseAndValidate(a.allocator(), source, Plain.DiagnosticSink.discard, .{});
    defer plain.deinit(a.allocator());
    const Keep = dot.Profile(.{ .policy = .{ .markup = .passthrough, .retention = .{ .markup = true } }, .processors = .{ .markup = Child } });
    var kept = try Keep.parseAndValidate(b.allocator(), source, Keep.DiagnosticSink.discard, .{});
    defer kept.deinit(b.allocator());
    try equal(a.allocations, b.allocations);
    try equal(a.allocated_bytes, b.allocated_bytes);
    try std.testing.expectError(error.MarkupRetentionDisabled, plain.requestMarkup(a.allocator(), span(source, "<<b/>>")));
    try std.testing.expectError(error.MarkupRetentionDisabled, Plain.processPendingMarkup(a.allocator(), &plain, Plain.DiagnosticSink.discard, .{}));
    try Keep.processPendingMarkup(b.allocator(), &kept, Keep.DiagnosticSink.discard, .{}); // no selection, no work
    try expect(!kept.markup.requested);
}

test "delayed sink stop preserves outer facts and never invokes the next child" {
    const source = "graph { a [x=<<a x='1' x='2'/>> y=<<i/>>]; }";
    var bag: P.FixedDiagnosticBag(0) = .{};
    var result = try P.parseAndValidate(gpa, source, bag.sink(), .{});
    defer result.deinit(gpa);
    for (result.dot.document.?.attributes) |attribute| try result.requestMarkup(gpa, attribute.value);
    try P.processPendingMarkup(gpa, &result, bag.sink(), .{});
    try equal(.diagnostic_stop, result.markup.stop.?);
    try equal(dot.reporting.Delivery.failed, result.markup.diagnostic_delivery);
    try equal(dot.reporting.StopReason.capacity, result.markup.diagnostic_stop.?);
    try equal(@as(u32, 1), result.markup.visited);
    try equal(@as(usize, 1), result.pendingMarkup().len);
    try expect(result.dot.documentValid() and result.dot.diagnostic_stop == null);
    try expect(!result.documentValid() and !result.subtreeComplete());
}

test "delayed storage finding keeps sink failure distinct from allocation failure" {
    const source = "graph { a [x=<<b/>>]; }";
    var allocator = std.testing.FailingAllocator.init(gpa, .{});
    var result = try P.parseAndValidate(allocator.allocator(), source, P.DiagnosticSink.discard, .{});
    defer result.deinit(allocator.allocator());
    try result.requestMarkup(allocator.allocator(), result.dot.document.?.attributes[0].value);
    allocator.fail_index = allocator.alloc_index;
    var bag: P.FixedDiagnosticBag(0) = .{};
    try P.processPendingMarkup(allocator.allocator(), &result, bag.sink(), .{});
    try equal(.retention_storage, result.markup.stop.?);
    try equal(dot.reporting.Delivery.failed, result.markup.diagnostic_delivery);
    try equal(dot.reporting.StopReason.capacity, result.markup.diagnostic_stop.?);
    try equal(@as(u32, 0), result.markup.visited);
    try equal(@as(usize, 1), result.pendingMarkup().len);
    try expect(result.markup.has_errors and result.dot.documentValid());
}

test "delayed selection uses only retained DOT prefix and does not bypass outer stops" {
    const source = "graph { a [x=<<b/>>]; b [x=]; later [x=<<i/>>]; }";
    var result = try P.parseAndValidate(gpa, source, P.DiagnosticSink.discard, .{});
    defer result.deinit(gpa);
    try expect(!result.scopeComplete());
    try result.requestMarkup(gpa, span(source, "<<b/>>"));
    try std.testing.expectError(error.InvalidSpan, result.requestMarkup(gpa, span(source, "<<i/>>")));
    try P.processPendingMarkup(gpa, &result, P.DiagnosticSink.discard, .{});
    try expect(result.markup.allValid() and !result.subtreeComplete());
    var bag: P.FixedDiagnosticBag(0) = .{};
    var stopped = try P.parseAndValidate(gpa, source, bag.sink(), .{});
    defer stopped.deinit(gpa);
    try std.testing.expectError(error.CompositionStopped, stopped.requestMarkup(gpa, span(source, "<<b/>>")));
    const Fast = dot.Profile(.{ .policy = .{ .markup = .passthrough, .on_error = .fail_fast, .retention = .{ .markup = true } }, .processors = .{ .markup = Child } });
    var invalid = try Fast.parseAndValidate(gpa, "graph { a -> b [x=<<b/>>]; }", Fast.DiagnosticSink.discard, .{});
    defer invalid.deinit(gpa);
    try std.testing.expectError(error.CompositionStopped, invalid.requestMarkup(gpa, .{ .start = 0, .len = 0 }));
}

test "delayed cancellation stops a batch while policy limits can continue" {
    const R = dot.Profile(.{ .policy = .{ .markup = .passthrough, .retention = .{ .markup = true } }, .processors = .{ .markup = markup.Profile(.{ .runtime_policy = true, .policy = .{ .mode = .structural } }) } });
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    inline for (.{ false, true }) |cancel| {
        var result = try R.parseAndValidate(gpa, "graph { a [x=<<b/>> y=<<i/>>]; }", R.DiagnosticSink.discard, .{});
        defer result.deinit(gpa);
        for (result.dot.document.?.attributes) |attribute| try result.requestMarkup(gpa, attribute.value);
        try R.processPendingMarkup(gpa, &result, R.DiagnosticSink.discard, .{ .markup = .{
            .policy = if (cancel) .{ .execution = .{ .cancellation = true } } else .{ .limits = .{ .max_nodes = 0 } },
            .cancellation = if (cancel) .{ .context = null, .is_requested = Stop.poll } else null,
        } });
        try equal(@as(u32, if (cancel) 1 else 2), result.markup.visited);
        try equal(!cancel, result.markup.complete);
        try expect(result.dot.documentValid() and !result.documentValid());
        if (cancel) try equal(.child_stop, result.markup.stop.?);
    }
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var result = try P.parseAndValidate(allocator, "graph { a [x=<<b/>>+<<r x='1' x='2'><i/></wrong>>]; }", P.DiagnosticSink.discard, .{});
    defer result.deinit(allocator);
    if (result.dot.outcome == .storage_failure) return error.OutOfMemory;
    const range = result.dot.document.?.attributes[0].value;
    result.requestMarkup(allocator, range) catch |err| {
        try expect(!result.markup.requested and result.pendingMarkup().len == 0 and result.markupResults() == null);
        return err;
    };
    try P.processPendingMarkup(allocator, &result, P.DiagnosticSink.discard, .{});
    if (result.markup.stop == .retention_storage) return error.OutOfMemory;
    for (result.markupResults().?) |child| {
        if (child.result.parse.outcome == .out_of_memory) return error.OutOfMemory;
        if (child.result.validation) |v| if (v.completion == .out_of_memory) return error.OutOfMemory;
    }
    try equal(@as(u32, 2), result.markup.visited);
}

test "delayed queues and child ownership survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(gpa, allocationProbe, .{});
}

test "delayed custom owning processor preflights policy and preserves input failures" {
    const Consumer = struct {
        pub const Policies = struct {
            pub const Error = error{BadPolicy};
        };
        pub const Options = struct { reject: bool = false };
        pub const Diagnostic = Child.Diagnostic;
        pub const DiagnosticSink = Child.DiagnosticSink;
        pub const console = Child.console;
        pub const InputError = Child.InputError || error{CustomInputFailure};
        pub const CheckResult = Child.CheckResult;
        pub const Workspace = Child.Workspace;
        pub const ParseResources = struct { fail_input: bool = false, calls: ?*u32 = null };
        pub const Prepared = struct {
            pub fn initWorkspace(_: @This(), allocator: std.mem.Allocator, _: ParseResources) Workspace {
                return Child.prepare(.{}).initWorkspace(allocator, .{});
            }
            pub fn parseAndValidate(_: @This(), allocator: std.mem.Allocator, input: markup.Fragment, diagnostics: DiagnosticSink, resources: ParseResources) InputError!CheckResult {
                if (resources.calls) |calls| calls.* += 1;
                if (resources.fail_input) return error.CustomInputFailure;
                return Child.prepare(.{}).parseAndValidate(allocator, input, diagnostics, .{});
            }
        };
        pub fn prepare(options: Options) Policies.Error!Prepared {
            if (options.reject) return error.BadPolicy;
            return .{};
        }
    };
    const Custom = dot.Profile(.{ .policy = .{ .markup = .passthrough, .retention = .{ .markup = true } }, .processors = .{ .markup = Consumer } });
    inline for (.{ false, true }) |fail_input| {
        var result = try Custom.parseAndValidate(gpa, "graph { a [x=<<b/>> y=<<i/>>]; }", Custom.DiagnosticSink.discard, .{});
        defer result.deinit(gpa);
        try result.requestMarkup(gpa, result.dot.document.?.attributes[0].value);
        var calls: u32 = 0;
        try std.testing.expectError(error.BadPolicy, Custom.processPendingMarkup(gpa, &result, Custom.DiagnosticSink.discard, .{
            .markup = .{ .reject = true },
            .markup_resources = .{ .calls = &calls },
        }));
        try expect(result.pendingMarkup().len == 1 and result.markup.stop == null and calls == 0);
        try result.requestMarkup(gpa, result.dot.document.?.attributes[1].value);
        const processing = Custom.processPendingMarkup(gpa, &result, Custom.DiagnosticSink.discard, .{ .markup_resources = .{ .calls = &calls, .fail_input = fail_input } });
        if (fail_input) {
            try std.testing.expectError(error.CustomInputFailure, processing);
            try equal(.input_error, result.markup.stop.?);
            try equal(@as(usize, 2), result.pendingMarkup().len);
            try equal(@as(u32, 1), calls);
            try expect(!result.documentValid() and !result.subtreeComplete());
        } else {
            try processing;
            try equal(@as(u32, 2), calls);
            try expect(result.documentValid() and result.subtreeComplete());
        }
    }
}
