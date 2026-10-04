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
        try equal(dot.ParseOutcome{ .diagnostic_stopped = if (capacity == 0) .capacity else .requested }, checked.dot.outcome);
        try expect(checked.dot.document == null and checked.dot.validation == null);
        try equal(@as(usize, capacity), bag.items().len);
        try equal(if (capacity == 0) dot.diagnostic.StopReason.capacity else .requested, checked.dot.diagnostic_stop.?);
        try equal(if (capacity == 0) dot.diagnostic.Delivery.failed else .complete, checked.dot.diagnostic_delivery);
    }
}

test "shared diagnostic stops have the same cause for outer and child emitters" {
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |controlled| {
        const P = dot.Profile(.{
            .policy = .{ .scanner = backend, .execution = .{ .cancellation = controlled } },
            .processors = .{ .markup = markup.Profile(.{ .policy = .{ .scanner = backend } }) },
        });
        const Destination = struct {
            reason: dot.reporting.StopReason,
            calls: u32 = 0,
            child: bool = false,
            fn emit(raw: ?*anyopaque, item: P.Diagnostic) dot.reporting.SinkError!dot.reporting.Action {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.calls += 1;
                self.child = item == .markup;
                return switch (self.reason) {
                    .requested => .stop,
                    .capacity => error.DiagnosticCapacityExceeded,
                    .failure => error.DiagnosticSinkFailure,
                    .out_of_memory => error.OutOfMemory,
                };
            }
        };
        const inputs = [_][]const u8{
            "digraph { a -> ; b [label=<<i>ok</i>>]; }",
            "digraph { b [label=<<i>>]; a -> ; }",
            // A child validation finding, not only child syntax failure.
            "digraph { b [label=<<i x='1' x='2'/>>]; a -> ; }",
        };
        for (std.enums.values(dot.reporting.StopReason)) |reason| {
            for (inputs, 0..) |source, index| {
                var destination: Destination = .{ .reason = reason };
                var checked = try P.parseAndValidate(gpa, source, .{ .context = &destination, .emit_fn = Destination.emit }, .{});
                defer checked.deinit(gpa);
                try equal(dot.ParseOutcome{ .diagnostic_stopped = reason }, checked.dot.outcome);
                try equal(reason, checked.dot.diagnostic_stop.?);
                try equal(if (reason == .requested) dot.reporting.Delivery.complete else .failed, checked.dot.diagnostic_delivery);
                try equal(@as(u32, 1), destination.calls);
                try equal(index != 0, destination.child);
                try expect(checked.dot.document == null and checked.dot.validation == null);
                try equal(dot.Completion.incomplete, checked.dot.completion);
                try expect(!checked.markup.complete);
                if (index != 0) try equal(.diagnostic_stop, checked.markup.stop.?);
            }
        }
    };
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

test "composed and standalone renderers agree on list locations and summaries" {
    const P = dot.Profile(.{
        .policy = .{ .validation = .{ .digraph = .{ .operator_mismatch = .warning } } },
        .processors = .{ .markup = markup.Profile(.{}) },
    });
    const source = "digraph {\n a [label=<<b x='1' x='2'/> + <i y='1' y='2'/>>];\n a -- b;\n b -- c;\n}";
    var bag: P.FixedDiagnosticBag(16) = .{};
    var checked = try P.parseAndValidate(gpa, source, bag.sink(), .{});
    defer checked.deinit(gpa);
    inline for (.{ .dot, .markup }) |tag| {
        const Provider = if (tag == .dot) dot else markup;
        var plain_items: [16]Provider.Diagnostic = undefined;
        var mixed_items: [16]P.Diagnostic = undefined;
        var count: usize = 0;
        // Reverse source order and duplicate each finding: both renderers must
        // sort/de-duplicate their location queries without reordering output.
        var index = bag.items().len;
        while (index > 0) {
            index -= 1;
            const item = bag.items()[index];
            if (!std.mem.eql(u8, @tagName(item), @tagName(tag))) continue;
            for (0..2) |_| {
                plain_items[count] = @field(item, @tagName(tag));
                mixed_items[count] = item;
                count += 1;
            }
        }
        try expect(count >= 4);
        var locations: [128]dot.location.Location = undefined;
        inline for (.{ .unicode, .ascii }) |style| inline for (.{ .none, .ansi }) |color| {
            for ([_]?[]const u8{ source, source[0..4], null }) |bytes| {
                for ([_]usize{ 0, 1, count }) |length| {
                    var plain_buffer: [16_384]u8 = undefined;
                    var mixed_buffer: [16_384]u8 = undefined;
                    var plain_writer = std.Io.Writer.fixed(&plain_buffer);
                    var mixed_writer = std.Io.Writer.fixed(&mixed_buffer);
                    const options: dot.presentation.RenderOptions = .{ .source = bytes, .source_name = "labels.dot", .style = style, .color = color, .verbose = true };
                    try Provider.console.renderList(plain_items[0..length], options, &locations, &plain_writer);
                    try P.console.renderList(mixed_items[0..length], options, &locations, &mixed_writer);
                    try std.testing.expectEqualStrings(plain_writer.buffered(), mixed_writer.buffered());
                    for ([_]u64{ 0, 3 }) |omitted| {
                        plain_writer.end = 0;
                        mixed_writer.end = 0;
                        try Provider.console.renderBoxedList(plain_items[0..length], omitted, options, &locations, &plain_writer);
                        try P.console.renderBoxedList(mixed_items[0..length], omitted, options, &locations, &mixed_writer);
                        try std.testing.expectEqualStrings(plain_writer.buffered(), mixed_writer.buffered());
                    }
                }
            }
        };
    }
}

test "during-DOT scanner and plain-profile parity cover boundaries and recovery" {
    inline for (.{ dot.OnError.collect, .fail_fast }) |on_error| inline for (.{ false, true }) |controlled| {
        const scalar_policy: dot.Policy = .{ .on_error = on_error, .execution = .{ .cancellation = controlled } };
        const block_policy: dot.Policy = .{ .on_error = on_error, .scanner = .block, .execution = .{ .cancellation = controlled } };
        const PlainScalar = dot.Profile(.{ .policy = scalar_policy });
        const PlainBlock = dot.Profile(.{ .policy = block_policy });
        const Scalar = dot.Profile(.{ .policy = scalar_policy, .processors = .{ .markup = markup.Profile(.{}) } });
        const Block = dot.Profile(.{ .policy = block_policy, .processors = .{ .markup = markup.Profile(.{ .policy = .{ .scanner = .block } }) } });
        const seeds = [_][]const u8{
            "digraph <g> { a [label=<<b x='1' x='2'>&amp;</b>>+\"text\"+<<i/>>]; a -- b; c [x=<<x>text</wrong>>]; }",
            "digraph <g> { a [label=<<b x='1'>&amp;</b>>+\"text\"+<<i/>>]; a -> b; }",
            "digraph { subgraph <s> { <a>:<p> -> <b>; } -> <c>:<q>; <key>=<value>; }",
            "graph { a; b -- c; node [x=y]; }",
            "digraph { a [x=]; b [label=<<b/>>]; c -> ; }",
        };
        const alphabet = "<>/'\"&;[]{}=+!-abc \n\xff";
        var prng = std.Random.DefaultPrng.init(0x1eafa113);
        const random = prng.random();
        var compared: u32 = 0;
        for (0..512) |iteration| {
            const seed = seeds[iteration % seeds.len];
            var storage: [256]u8 = undefined;
            const source = storage[0..seed.len];
            @memcpy(source, seed);
            if (iteration >= seeds.len) {
                for (0..random.intRangeAtMost(usize, 1, 4)) |_| source[random.uintLessThan(usize, source.len)] = alphabet[random.uintLessThan(usize, alphabet.len)];
            }
            const len = if (iteration < seeds.len or random.boolean()) source.len else random.intRangeAtMost(usize, 0, source.len);
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
            // A child rejection intentionally stops a fail-fast parent earlier.
            // Otherwise the DOT result (including retained pools) and its diagnostic
            // subsequence must match the corresponding ordinary profile exactly.
            if (left.dot.outcome == .processor_stopped) {
                try equal(dot.OnError.fail_fast, on_error);
                try equal(.parent_error, left.markup.stop.?);
                try equal(.parent_error, right.markup.stop.?);
            } else {
                try expect(left.dot.diagnostic_stop == null and right.dot.diagnostic_stop == null);
                try expectPlainParity(PlainScalar, source[0..len], left.dot, left_bag.items());
                try expectPlainParity(PlainBlock, source[0..len], right.dot, right_bag.items());
                compared += 1;
            }
        }
        try expect(compared > 100);
    };
}

fn expectPlainParity(comptime Plain: type, source: []const u8, composed_dot: dot.CheckResult, mixed: anytype) !void {
    var bag: dot.FixedDiagnosticBag(64) = .{};
    var plain = Plain.parseAndValidate(gpa, source, bag.sink(), .{});
    defer plain.deinit(gpa);
    try std.testing.expectEqualDeep(plain, composed_dot);
    var index: usize = 0;
    for (mixed) |item| if (item == .dot) {
        try expect(index < bag.items().len);
        try std.testing.expectEqualDeep(bag.items()[index], item.dot);
        index += 1;
    };
    try equal(bag.items().len, index);
}
