const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "one composed call and one bag retain independent outer and inner findings" {
    const P = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const source = "digraph { a -- b [label=<<b x='1' x='2'>text</wrong>>]; c [label=<<i>ok</i>>]; }";
    var bag = P.GrowableDiagnosticBag.init(gpa, .{});
    defer bag.deinit();
    var checked = try P.parseAndValidate(gpa, source, bag.sink(), .{});
    defer checked.deinit(gpa);
    try equal(dot.ParseOutcome.success, checked.dot.outcome);
    try expect(checked.dot.document != null);
    try expect(!checked.documentValid());
    try equal(@as(u32, 2), checked.markup.visited);
    try equal(@as(u32, 1), checked.markup.valid);
    try expect(checked.markup.complete);
    var outer = false;
    var duplicate = false;
    var mismatch = false;
    for (bag.items()) |item| switch (item) {
        .dot => |d| {
            outer = true;
            try expect(d.span.start < source.len);
        },
        .markup => |d| {
            duplicate = duplicate or d.code == .duplicate_attribute;
            mismatch = mismatch or d.code == .mismatched_tag;
            try expect(d.span.start >= 24 and d.span.endOffset() <= source.len);
        },
    };
    try expect(outer and duplicate and mismatch);
    try expect(bag.items()[0] == .markup); // child findings precede outer validation
    var bytes: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const locations = try gpa.alloc(dot.location.Location, try P.console.locationCapacity(bag.items()));
    defer gpa.free(locations);
    try P.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "input.dot", .style = .ascii }, locations, &writer);
    try expect(std.mem.indexOf(u8, writer.buffered(), "dot_parser:") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "markup_parser:") != null);
    try expect(std.mem.indexOf(u8, writer.buffered(), "Summary") != null);
}

test "all HTML operand positions and concatenations are processed once on both backends" {
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |controlled| {
        const Inner = markup.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .cancellation = controlled } } });
        const P = dot.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .cancellation = controlled } }, .processors = .{ .markup = Inner } });
        const source = "digraph <name> { <a>:<port>:<n> -> <b>; subgraph <s> { <x>; } <key>=<value>; a [<attr>=<<b/>>+\"quoted\"+<<i/>>]; }";
        var checked = try P.parseAndValidate(gpa, source, P.DiagnosticSink.discard, .{});
        defer checked.deinit(gpa);
        try expect(checked.documentValid());
        try equal(@as(u32, 12), checked.markup.visited);
        try equal(checked.markup.visited, checked.markup.valid);
    };
}

test "outer and inner fail-fast are independent and a child stops outer parsing immediately" {
    inline for (.{ dot.OnError.collect, .fail_fast }) |outer| inline for (.{ markup.OnError.collect, .fail_fast }) |inner| {
        const P = dot.Profile(.{ .policy = .{ .on_error = outer }, .processors = .{ .markup = markup.Profile(.{ .policy = .{ .on_error = inner } }) } });
        var bag: P.FixedDiagnosticBag(32) = .{};
        var checked = try P.parseAndValidate(gpa, "digraph { a [label=<<a x='1' x='2'><b></c>>]; b [label=<<i/>>]; }", bag.sink(), .{});
        defer checked.deinit(gpa);
        try equal(@as(u32, if (outer == .collect) 2 else 1), checked.markup.visited);
        try equal(outer == .collect, checked.dot.document != null);
        if (outer == .fail_fast) {
            try equal(dot.ParseOutcome.processor_stopped, checked.dot.outcome);
            try equal(.parent_error, checked.markup.stop.?);
            try expect(!checked.markup.complete);
        }
        var duplicate = false;
        for (bag.items()) |item| if (item == .markup and item.markup.code == .duplicate_attribute) {
            duplicate = true;
        };
        try equal(inner == .collect, duplicate);
    };
}

test "one bag capacity stops child then outer without delivering anything else" {
    const P = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const source = "digraph { a [label=<<a x='1' x='2'><b></c>>]; b -- c; }";
    inline for (.{ 0, 1, 2 }) |capacity| {
        var bag: P.FixedDiagnosticBag(capacity) = .{};
        var checked = try P.parseAndValidate(gpa, source, bag.sink(), .{});
        defer checked.deinit(gpa);
        try equal(dot.ParseOutcome.processor_stopped, checked.dot.outcome);
        try expect(checked.dot.document == null and checked.dot.validation == null);
        try equal(@as(usize, capacity), bag.items().len);
        try equal(if (capacity == 0) dot.diagnostic.StopReason.capacity else .requested, checked.dot.diagnostic_stop.?);
        try equal(if (capacity == 0) dot.diagnostic.Delivery.failed else .complete, checked.dot.diagnostic_delivery);
    }
}

test "unsupported child severity never turns passthrough into a validation success" {
    inline for (.{ dot.reporting.Unsupported.err, .warning, .silent }) |severity| {
        const P = dot.Profile(.{ .policy = .{ .on_error = .fail_fast }, .processors = .{ .markup = markup.Profile(.{ .policy = .{ .diagnostics = .{ .unsupported = severity } } }) } });
        var bag: P.FixedDiagnosticBag(16) = .{};
        var checked = try P.parseAndValidate(gpa, "digraph { a [x=<<?pi?>>]; b [x=<<i/>>]; }", bag.sink(), .{});
        defer checked.deinit(gpa);
        try equal(@as(u32, if (severity == .err) 1 else 2), checked.markup.visited);
        try expect(!checked.documentValid());
        try equal(severity != .err, checked.dot.document != null);
        if (severity == .silent) try equal(@as(usize, 0), bag.items().len);
    }
}

test "runtime policies preflight before any processing and own their independent options" {
    const P = dot.Profile(.{ .runtime_policy = true, .processors = .{ .markup = markup.Profile(.{ .runtime_policy = true }) } });
    var bag: P.FixedDiagnosticBag(32) = .{};
    try std.testing.expectError(error.GraphOperatorMismatchNotApplicable, P.parseAndValidate(gpa, "digraph { a [x=<<b></a>>]; }", bag.sink(), .{
        .dot = .{ .policy = .{ .validation = .{ .graph = .{ .treated_as = .generic, .operator_mismatch = .err } } } },
    }));
    try equal(@as(usize, 0), bag.items().len);
    var checked = try P.parseAndValidate(gpa, "digraph { a [x=<<b x='1' x='2'/> >]; }", bag.sink(), .{
        .dot = .{ .policy = .{ .scanner = .block } },
        .markup = .{ .policy = .{ .scanner = .block, .validation = .{ .duplicate_attribute = .off } } },
    });
    defer checked.deinit(gpa);
    try expect(checked.documentValid());
}

test "outer none never invokes a child and outer recovery still finds later inner errors" {
    const P = dot.Profile(.{ .policy = .{ .markup = .none }, .processors = .{ .markup = markup.Profile(.{}) } });
    var bag: P.FixedDiagnosticBag(16) = .{};
    var checked = try P.parseAndValidate(gpa, "digraph { a [x=<<b/> >]; }", bag.sink(), .{});
    defer checked.deinit(gpa);
    try equal(@as(u32, 0), checked.markup.visited);
    try expect(!checked.documentValid());
    for (bag.items()) |item| try expect(item == .dot);
    const Collect = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    var bag2: Collect.FixedDiagnosticBag(32) = .{};
    var recovered = try Collect.parseAndValidate(gpa, "digraph { a [x=]; b [x=<<b></wrong>>]; }", bag2.sink(), .{});
    defer recovered.deinit(gpa);
    try expect(recovered.dot.document == null);
    try equal(@as(u32, 1), recovered.markup.visited);
    try expect(recovered.markup.has_errors);
}

test "a consumer processor runs before a document exists without runtime discovery" {
    const Consumer = struct {
        const Base = markup.Profile(.{});
        pub const Policies = Base.Policies;
        pub const Options = Base.Options;
        pub const Diagnostic = markup.Diagnostic;
        pub const DiagnosticSink = markup.DiagnosticSink;
        pub const InputError = markup.Fragment.Error;
        pub const CheckResult = markup.FragmentResult;
        pub const ParseResources = struct { calls: ?*u32 = null };
        pub const Prepared = struct {
            inner: Base.Prepared,
            pub fn parseAndValidate(self: @This(), allocator: std.mem.Allocator, input: markup.Fragment, sink: DiagnosticSink, resources: ParseResources) InputError!CheckResult {
                if (resources.calls) |calls| calls.* += 1;
                return self.inner.parseAndValidate(allocator, input, sink, .{});
            }
        };
        pub fn prepare(options: Options) Prepared {
            return .{ .inner = Base.prepare(options) };
        }
    };
    const P = dot.Profile(.{ .processors = .{ .markup = Consumer } });
    try expect(!@hasDecl(P, "Session")); // never disguise unbounded child work as advance()
    var calls: u32 = 0;
    // No complete DOT document can be published; child already ran at its token.
    var checked = try P.parseAndValidate(gpa, "digraph { a [x=<<b/>>];", P.DiagnosticSink.discard, .{ .markup_resources = .{ .calls = &calls } });
    defer checked.deinit(gpa);
    try equal(@as(u32, 1), calls);
    try expect(checked.dot.document == null and !checked.markup.complete);
    try equal(@as(u32, 1), checked.markup.valid);
}

test "child policy limits continue in a collecting parent and cancellation stops the batch" {
    const Limited = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{ .policy = .{ .limits = .{ .max_nodes = 1 } } }) } });
    var limited = try Limited.parseAndValidate(gpa, "digraph { a [x=<<b><i/></b>>]; b [x=<<i/>>]; }", Limited.DiagnosticSink.discard, .{});
    defer limited.deinit(gpa);
    try equal(@as(u32, 2), limited.markup.visited);
    try equal(@as(u32, 1), limited.markup.valid);
    try expect(limited.dot.document != null);
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    const P = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } }) } });
    var checked = try P.parseAndValidate(gpa, "digraph { a [x=<<b/>>]; b [x=<<i/>>]; }", P.DiagnosticSink.discard, .{ .markup = .{ .cancellation = .{ .context = null, .is_requested = Stop.poll } } });
    defer checked.deinit(gpa);
    try equal(dot.ParseOutcome.processor_stopped, checked.dot.outcome);
    try equal(.child_stop, checked.markup.stop.?);
    try equal(@as(u32, 1), checked.markup.visited);
    try expect(checked.dot.document == null);
}

test "streaming failure is terminal and explicit omission does not suppress findings" {
    const P = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const Failing = struct {
        calls: u32 = 0,
        fn emit(raw: ?*anyopaque, _: P.Diagnostic) dot.reporting.SinkError!dot.reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return error.DiagnosticSinkFailure;
        }
    };
    var fail: Failing = .{};
    var failed = try P.parseAndValidate(gpa, "digraph { a [x=<<a></b>>]; c -- d; }", .{ .context = &fail, .emit_fn = Failing.emit }, .{});
    defer failed.deinit(gpa);
    try equal(@as(u32, 1), fail.calls);
    try equal(dot.diagnostic.Delivery.failed, failed.dot.diagnostic_delivery);
    try equal(dot.diagnostic.StopReason.failure, failed.dot.diagnostic_stop.?);
    var bag: P.PrefixDiagnosticBag(0) = .{};
    var omitted = try P.parseAndValidate(gpa, "digraph { a [x=<<b x='1' x='2'/>>]; c -- d; }", bag.sink(), .{});
    defer omitted.deinit(gpa);
    try expect(bag.omitted >= 2);
    try expect(omitted.dot.document != null and !omitted.documentValid());
    try expect(omitted.markup.has_errors);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const P = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const Track = struct {
        oom: bool = false,
        fn emit(raw: ?*anyopaque, item: P.Diagnostic) dot.reporting.SinkError!dot.reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.oom = self.oom or switch (item) {
                .dot => |d| d.code == .resource_memory_exhausted,
                .markup => |d| d.code == .out_of_memory,
            };
            return .proceed;
        }
    };
    var track: Track = .{};
    var checked = try P.parseAndValidate(allocator, "digraph { a [x=<<a x='1' y='2'><b/><c/><d/><e/><f/><g/><h/><i/><j/></a>>]; a -> b; }", .{ .context = &track, .emit_fn = Track.emit }, .{});
    defer checked.deinit(allocator);
    if (track.oom) return error.OutOfMemory;
    try expect(checked.documentValid());
}
test "every composed allocation failure frees active child and outer storage" {
    try std.testing.checkAllAllocationFailures(gpa, allocationCase, .{});
}

test "mixed rendering keeps original fix coordinates and works with incomplete source" {
    const P = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const source = "digraph {\n a [label=<<b>&amp</b>>];\n a -- b;\n}";
    var bag: P.FixedDiagnosticBag(16) = .{};
    var checked = try P.parseAndValidate(gpa, source, bag.sink(), .{});
    defer checked.deinit(gpa);
    try equal(@as(usize, 2), bag.items().len);
    const fix = bag.items()[0].markup.suggestedFix().?;
    try equal(@as(u32, @intCast(std.mem.indexOf(u8, source, "</b>").?)), fix.span.start);
    try equal(@as(u32, 0), fix.span.len);
    const locations = try gpa.alloc(dot.location.Location, try P.console.locationCapacity(bag.items()));
    defer gpa.free(locations);
    inline for (.{ .unicode, .ascii }) |style| {
        for ([_]?[]const u8{ source, source[0..4], null }) |bytes| {
            var buffer: [8192]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            const options: dot.presentation.RenderOptions = .{ .source = bytes, .source_name = "labels.dot", .style = style, .verbose = true };
            try P.console.renderList(bag.items(), options, locations, &writer);
            if (bytes != null and bytes.?.len == source.len) {
                try expect(std.mem.indexOf(u8, writer.buffered(), "labels.dot:2:") != null);
                try expect(std.mem.indexOf(u8, writer.buffered(), "labels.dot:3:") != null);
            }
            writer.end = 0;
            try P.console.renderBoxedList(bag.items(), 3, options, locations, &writer);
            try expect(std.mem.indexOf(u8, writer.buffered(), "3 more omitted") != null);
            writer.end = 0;
            try P.console.render(bag.items()[0], options, &writer);
            try P.console.renderBoxed(bag.items()[1], 2, options, &writer);
        }
    }
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.LocationScratchTooSmall, P.console.renderBoxedList(bag.items(), 0, .{ .source = source }, &.{}, &writer));
    try equal(@as(usize, 0), writer.buffered().len);
}

test "during-DOT scanner differential covers malformed boundaries and recovery" {
    const Scalar = dot.Profile(.{ .processors = .{ .markup = markup.Profile(.{}) } });
    const Block = dot.Profile(.{ .policy = .{ .scanner = .block }, .processors = .{ .markup = markup.Profile(.{ .policy = .{ .scanner = .block } }) } });
    const seed = "digraph <g> { a [label=<<b x='1' x='2'>&amp;</b>>+\"text\"+<<i/>>]; a -- b; c [x=<<x>text</wrong>>]; }";
    const alphabet = "<>/'\"&;[]{}=+!-abc \n\xff";
    var prng = std.Random.DefaultPrng.init(0x1eafa113);
    const random = prng.random();
    for (0..512) |_| {
        var source: [seed.len]u8 = seed.*;
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| source[random.uintLessThan(usize, source.len)] = alphabet[random.uintLessThan(usize, alphabet.len)];
        const len = if (random.boolean()) source.len else random.intRangeAtMost(usize, 0, source.len);
        var left_bag: Scalar.FixedDiagnosticBag(64) = .{};
        var right_bag: Block.FixedDiagnosticBag(64) = .{};
        var left = try Scalar.parseAndValidate(gpa, source[0..len], left_bag.sink(), .{});
        defer left.deinit(gpa);
        var right = try Block.parseAndValidate(gpa, source[0..len], right_bag.sink(), .{});
        defer right.deinit(gpa);
        try std.testing.expectEqualDeep(left.dot.outcome, right.dot.outcome);
        try equal(left.dot.completion, right.dot.completion);
        try equal(left.dot.syntax_errors, right.dot.syntax_errors);
        try std.testing.expectEqualDeep(left.dot.validation, right.dot.validation);
        try equal(left.documentValid(), right.documentValid());
        try equal(left.markup.visited, right.markup.visited);
        try equal(left.markup.valid, right.markup.valid);
        try equal(left.markup.rejected, right.markup.rejected);
        try equal(left.markup.unprocessed, right.markup.unprocessed);
        try equal(left.markup.complete, right.markup.complete);
        try equal(left_bag.items().len, right_bag.items().len);
        for (left_bag.items(), right_bag.items()) |a, b| switch (a) {
            inline else => |d, tag| {
                try expect(std.mem.eql(u8, @tagName(a), @tagName(b)));
                try std.testing.expectEqualDeep(d, @field(b, @tagName(tag)));
            },
        };
    }
}
