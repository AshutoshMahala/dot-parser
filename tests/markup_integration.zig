const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const allocator = std.testing.allocator;
const discard = markup.diagnostic.discard;

fn span(source: []const u8, needle: []const u8) dot.Span {
    return .{ .start = @intCast(std.mem.indexOf(u8, source, needle).?), .len = @intCast(needle.len) };
}

test "operand views preserve mixed expressions and original coordinates without decoding" {
    const source = "prefix \"<not markup>\\\"\\\r\n\" + /* <> */ <<b/>text> + // glue\n <> + \"\" suffix";
    const expression = source[7 .. source.len - 7];
    var parts = try dot.identifier.parts(source, .{ .start = 7, .len = @intCast(expression.len) });
    const first = parts.next().?;
    try equal(dot.identifier.Part.Form.quoted, first.form);
    try strings("<not markup>\\\"\\\r\n", first.inner.slice(source));
    const html = parts.next().?;
    try equal(dot.identifier.Part.Form.html, html.form);
    try strings("<<b/>text>", html.raw.slice(source));
    try strings("<b/>text", (try html.fragment(source)).bytes);
    try equal(html.inner.start, (try html.fragment(source)).origin);
    try equal(@as(u32, 0), parts.next().?.inner.len);
    try equal(dot.identifier.Part.Form.quoted, parts.next().?.form);
    try expect(parts.next() == null and parts.next() == null);
    inline for (.{ "abc", "中文", "-.4", "\"\"", "<>", "<x>" }) |raw| {
        var one = try dot.identifier.parts(raw, .{ .start = 0, .len = raw.len });
        try strings(raw, one.next().?.raw.slice(raw));
        try expect(one.next() == null);
    }
    for ([_][]const u8{ "", "<x", "\"bad", "x y", "<a> +", "<a> + x", "\"a\" /* missing" }) |bad| {
        try std.testing.expectError(error.InvalidIdentifier, dot.identifier.parts(bad, .{ .start = 0, .len = @intCast(bad.len) }));
    }
    try std.testing.expectError(error.InvalidSpan, dot.identifier.parts("<x>", .{ .start = 2, .len = 2 }));
    try std.testing.expectError(error.InvalidSpan, dot.identifier.parts("<x>", .{ .start = std.math.maxInt(u32), .len = 2 }));
}

test "delayed selected operands keep outer validity independent and continue after inner errors" {
    const source = "graph { a -> b [label=<<b a='1' a='2'/>> + \"<not markup>\" + <<i>ok</i>>]; }";
    var outer_bag = dot.GrowableDiagnosticBag.init(allocator, .{});
    defer outer_bag.deinit();
    var outer = dot.parseAndValidate(allocator, source, outer_bag.sink(), .{});
    defer outer.deinit(allocator);
    try expect(outer.document != null and !outer.documentValid()); // operator mismatch
    const doc = &outer.document.?;
    var parts = try dot.identifier.parts(doc.source, doc.attributes[0].value);
    var bag = markup.GrowableDiagnosticBag.init(allocator, .{});
    defer bag.deinit();
    const ready = markup.prepare(.{});
    var count: u32 = 0;
    while (parts.next()) |part| {
        if (part.form != .html) continue;
        var inner = try ready.parseAndValidateFragment(allocator, try part.fragment(source), bag.sink(), .{});
        defer inner.deinit();
        try expect(!inner.stopped());
        try expect(inner.documentValid() == (count == 1));
        try equal(markup.Outcome.success, inner.parse.outcome);
        try equal(@as(u32, 0), inner.parse.document.?.records[0].span.start);
        try strings(part.inner.slice(source), inner.parse.document.?.source);
        count += 1;
    }
    try equal(@as(u32, 2), count);
    try equal(@as(usize, 1), bag.items().len);
    try equal(span(source, "a='2'").start, bag.items()[0].span.start);
    try equal(span(source, "a='1'").start, bag.items()[0].related.?.start);
    try equal(@as(usize, 1), outer_bag.items().len);
    try strings(source, doc.source);
}

test "fragment parsing validates recognizable scopes after syntax rejection with backend and runtime parity" {
    const source = "prefix <a x='1' x='2'>&bogus;</wrong> suffix";
    const input = try markup.Fragment.fromSource(source, span(source, "<a x='1' x='2'>&bogus;</wrong>"));
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| {
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else .{ .scanner = backend, .validation = .{ .references = .{ .severity = .err } } } });
        const options: P.Options = if (runtime) .{ .policy = .{ .scanner = backend, .validation = .{ .references = .{ .severity = .err } } } } else .{};
        const ready = P.prepare(options);
        var bag: markup.FixedDiagnosticBag(16) = .{};
        var parsed = try ready.parseAndValidateFragment(allocator, input, bag.sink(), .{});
        defer parsed.deinit();
        try equal(markup.Outcome.invalid_syntax, parsed.parse.outcome);
        try expect(parsed.parse.document == null and !parsed.stopped());
        try equal(@as(u64, 2), parsed.validation.?.errors);
        try equal(.complete, parsed.validation.?.completion);
        const findings = bag.items();
        try equal(markup.diagnostic.Code.duplicate_attribute, findings[findings.len - 2].code);
        try equal(span(source, "x='2'").start, findings[findings.len - 2].span.start);
        try equal(markup.diagnostic.Code.unknown_reference, findings[findings.len - 1].code);
        var storage: markup.FixedDocumentStorage(.{ .nodes = 8, .attributes = 4 }) = .{};
        var frames: markup.FixedParseScratch(4) = .{};
        var scratch: markup.FixedSourceValidationScratch(2) = .{};
        var fixed_bag: markup.FixedDiagnosticBag(16) = .{};
        const fixed = try ready.parseAndValidateFragmentIn(input, .{ .document = storage.storage(), .scratch = frames.storage() }, scratch.storage(), fixed_bag.sink());
        try std.testing.expectEqualDeep(parsed.validation, fixed.validation);
        try std.testing.expectEqualSlices(markup.Diagnostic, findings, fixed_bag.items());
    };
}

test "fragment fixes related spans EOF and coverage gaps map once while resource counts do not" {
    const input = try markup.Fragment.init("<a>&amp</b>", 100);
    const P = markup.Profile(.{ .policy = .{ .diagnostics = .{ .fixes = .all } } });
    var bag: markup.FixedDiagnosticBag(16) = .{};
    var r = try P.parseAndValidateFragment(allocator, input, bag.sink(), .{});
    defer r.deinit();
    try equal(@as(u32, 103), bag.items()[0].span.start);
    try equal(@as(u32, 107), bag.items()[0].suggestedFix().?.span.start);
    for (bag.items()) |d| {
        try expect(d.span.start >= 100 and d.span.endOffset() <= 111);
        if (d.related) |related| try expect(related.start >= 100);
    }
    var unfinished = try markup.parseAndValidateFragment(allocator, try markup.Fragment.init("<a x='1'", 73), discard, .{});
    defer unfinished.deinit();
    try equal(@as(u32, 81), unfinished.validation.?.completion.incomplete);
    var storage: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 2 }) = .{};
    const stopped = try markup.parseAndValidateFragmentIn(try markup.Fragment.init("<a x='1' x='2'/>", 100), .{ .document = storage.storage() }, .{}, discard, .{});
    try expect(stopped.stopped());
    try equal(@as(u32, 2), stopped.validation.?.completion.storage_exhausted);
}

fn requested(_: ?*anyopaque) bool {
    return true;
}

test "terminal diagnostic acknowledgment survives parsing and forbids a second fragment stage" {
    const Destination = struct {
        mode: enum { stop, failure, capacity, oom },
        calls: u32 = 0,
        fn emit(context: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return switch (self.mode) {
                .stop => .stop,
                .failure => error.DiagnosticSinkFailure,
                .capacity => error.DiagnosticCapacityExceeded,
                .oom => error.OutOfMemory,
            };
        }
        fn sink(self: *@This()) markup.DiagnosticSink {
            return .{ .context = self, .emit_fn = emit };
        }
    };
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| inline for (.{ .fail_fast, .collect }) |recovery| {
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = .{ .scanner = backend, .recovery = recovery, .execution = .{ .metering = true } } });
        for ([_][]const u8{ "<a x='1' x='2'><", "<a x='1' x='2'></b>" }, 0..) |source, i| {
            inline for (.{ .stop, .failure, .capacity, .oom }) |mode| {
                const reason: markup.reporting.StopReason = switch (@as(@FieldType(Destination, "mode"), mode)) {
                    .stop => .requested,
                    .failure => .failure,
                    .capacity => .capacity,
                    .oom => .out_of_memory,
                };
                var destination: Destination = .{ .mode = mode };
                var grown = try P.parseAndValidateFragment(allocator, try markup.Fragment.init(source, 17), destination.sink(), .{});
                defer grown.deinit();
                try equal(@as(u32, 1), destination.calls);
                try equal(reason, grown.parse.diagnostic_stop.?);
                try equal(if (mode == .stop) markup.reporting.Delivery.complete else .failed, grown.parse.diagnostic_delivery);
                try expect(grown.validation == null and grown.stopped());
                try equal(@as(u32, 1), grown.parse.syntax_errors);
                if (i == 0 or recovery == .fail_fast) try equal(markup.Outcome.invalid_syntax, grown.parse.outcome);
                var storage: markup.FixedDocumentStorage(.{ .nodes = 4, .attributes = 2 }) = .{};
                var frames: markup.FixedParseScratch(2) = .{};
                var scratch: markup.FixedSourceValidationScratch(2) = .{};
                const memory: markup.ParseMemory = .{ .document = storage.storage(), .scratch = frames.storage() };
                destination.calls = 0;
                const fixed = try P.parseAndValidateFragmentIn(try markup.Fragment.init(source, 17), memory, scratch.storage(), destination.sink(), .{});
                try equal(@as(u32, 1), destination.calls);
                try equal(grown.parse.diagnostic_stop, fixed.parse.diagnostic_stop);
                try expect(fixed.validation == null and fixed.stopped());
                destination.calls = 0;
                var session = P.Session.init(source, memory, destination.sink(), .{});
                defer session.deinit();
                while (session.result() == null) {
                    _ = if (runtime) try session.advance(1) else session.advance(1);
                }
                try equal(reason, session.run().diagnostic_stop.?);
                try std.testing.expectEqualDeep(session.run(), session.cancel());
                try equal(@as(u32, 1), destination.calls);
                destination.calls = 0;
                const measured = P.measureIn(source, frames.storage(), destination.sink(), .{});
                try equal(reason, measured.diagnostic_stop.?);
                try equal(@as(u32, 1), destination.calls);
            }
        }
    };
    const Fast = markup.Profile(.{ .policy = .{ .recovery = .fail_fast } });
    var full: markup.FixedDiagnosticBag(1) = .{};
    var once = try Fast.parseAndValidateFragment(allocator, try markup.Fragment.init("<a x='1' x='2'></b>", 0), full.sink(), .{});
    defer once.deinit();
    try equal(@as(usize, 1), full.items().len);
    try equal(markup.reporting.Delivery.complete, once.parse.diagnostic_delivery);
    try expect(once.validation == null);
}

test "fragment route does not duplicate an element name finding when syntax elsewhere fails" {
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| {
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = .{ .scanner = backend, .validation = .{ .names = .{ .severity = .err } } } });
        for ([_][]const u8{ "<a×></a×>", "<a×></a×></x>" }) |source| {
            var bag: markup.FixedDiagnosticBag(8) = .{};
            var checked = try P.parseAndValidateFragment(allocator, try markup.Fragment.init(source, 30), bag.sink(), .{});
            defer checked.deinit();
            try equal(@as(u64, 1), checked.validation.?.errors);
            var names: u32 = 0;
            for (bag.items()) |finding| if (finding.code == .invalid_name) {
                names += 1;
                try equal(@as(u32, 32), finding.span.start); // invalid scalar, not the whole name
            };
            try equal(@as(u32, 1), names);
        }
    };
}

test "operational parse stops skip validation and validation stops keep committed inner tree" {
    const input = try markup.Fragment.init("<a x='1' x='2'/>", 10);
    var full: markup.FixedDiagnosticBag(1) = .{};
    var checked = try markup.parseAndValidateFragment(allocator, input, full.sink(), .{});
    defer checked.deinit();
    try expect(checked.stopped() and checked.parse.document != null);
    try equal(.diagnostic_stopped, std.meta.activeTag(checked.validation.?.completion));
    var fail_bag = markup.GrowableDiagnosticBag.init(std.testing.failing_allocator, .{});
    defer fail_bag.deinit();
    var delivery = try markup.parseAndValidateFragment(allocator, input, fail_bag.sink(), .{});
    defer delivery.deinit();
    try expect(delivery.stopped());
    try equal(.failed, delivery.validation.?.diagnostic_delivery);
    var bad: markup.FixedDiagnosticBag(1) = .{};
    var rejected = try markup.parseAndValidateFragment(allocator, try markup.Fragment.init("<a x=1/>", 10), bad.sink(), .{});
    defer rejected.deinit();
    try expect(rejected.stopped() and rejected.validation == null);
    var oom = try markup.parseAndValidateFragment(std.testing.failing_allocator, input, discard, .{});
    defer oom.deinit();
    try expect(oom.stopped() and oom.validation == null);
    const limited = try markup.parseAndValidateFragmentIn(input, .{}, .{}, discard, .{});
    try expect(limited.stopped() and limited.validation == null);
    const Cancel = markup.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } });
    var cancelled = try Cancel.parseAndValidateFragment(allocator, input, discard, .{ .cancellation = .{ .context = null, .is_requested = requested } });
    defer cancelled.deinit();
    try equal(markup.Outcome.cancelled, cancelled.parse.outcome);
    try expect(cancelled.validation == null);
    const Limits = markup.Profile(.{ .policy = .{ .limits = .{ .max_nodes = 0 } } });
    var limit = try Limits.parseAndValidateFragment(allocator, input, discard, .{});
    defer limit.deinit();
    try expect(limit.stopped() and limit.validation == null);
    try std.testing.expectError(error.InvalidFragment, markup.parseAndValidateFragment(allocator, .{ .bytes = "xx", .origin = std.math.maxInt(u32) }, discard, .{}));
}

test "origin sink supports caller-driven bounded parsing and rejects malformed local diagnostic ranges" {
    const input = try markup.Fragment.init("<a></b>", 41);
    var bag: markup.FixedDiagnosticBag(8) = .{};
    var mapped = try markup.diagnostic.OriginSink.init(input, bag.sink());
    var storage: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    var frames: markup.FixedParseScratch(1) = .{};
    var session = markup.BoundedSession.init(input.bytes, .{ .document = storage.storage(), .scratch = frames.storage() }, mapped.sink(), .{});
    defer session.deinit();
    while (session.result() == null) {
        const p = session.advance(1);
        try expect(p.work_used <= 1);
    }
    try expect(bag.items().len != 0);
    try equal(@as(u32, 46), bag.items()[0].span.start);
    try equal(@as(u32, 42), bag.items()[0].related.?.start);
    const count = bag.items().len;
    _ = session.run();
    try equal(count, bag.items().len);
    try std.testing.expectError(error.DiagnosticSinkFailure, mapped.sink().emit(.{ .code = .invalid_name, .span = .{ .start = 8, .len = 1 } }));
    try equal(count, bag.items().len);
}

fn allocations(a: std.mem.Allocator) !void {
    for ([_][]const u8{ "<a x='1' x='2'><b/></wrong>", "<a x='1' x='2'><b/></a>" }) |source| {
        var result = try markup.parseAndValidateFragment(a, try markup.Fragment.init(source, 90), discard, .{});
        defer result.deinit();
        if (result.parse.outcome == .out_of_memory or (result.validation != null and result.validation.?.completion == .out_of_memory)) return error.OutOfMemory;
        try equal(@as(u64, 1), result.validation.?.errors);
    }
}
test "delayed integration releases all storage at every allocation failure point" {
    try std.testing.checkAllAllocationFailures(allocator, allocations, .{});
}

test "fragment validation cancellation preserves the parsed document" {
    const Probe = struct {
        calls: u32 = 0,
        stop_after: u32 = std.math.maxInt(u32),
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return self.calls > self.stop_after;
        }
    };
    const P = markup.Profile(.{ .runtime_policy = true });
    const input = try markup.Fragment.init("<a x='1' x='2'/>", 90);
    var probe: Probe = .{};
    const hook: markup.Cancellation = .{ .context = &probe, .is_requested = Probe.poll };
    var plain = P.parseBorrowed(allocator, input.bytes, discard, .{ .policy = .{ .execution = .{ .cancellation = true } }, .cancellation = hook });
    defer plain.deinit();
    probe.stop_after = probe.calls;
    probe.calls = 0;
    var checked = try P.parseAndValidateFragment(allocator, input, discard, .{ .policy = .{ .execution = .{ .cancellation = true } }, .cancellation = hook });
    defer checked.deinit();
    try expect(checked.stopped() and checked.parse.document != null);
    try equal(.cancelled, checked.validation.?.completion);
    try equal(@as(u64, 0), checked.validation.?.errors);
}

test "operand traversal handles every truncation without unchecked rejected input" {
    for ([_][]const u8{ "<<a x='1'>text</a>> + /*glue*/ <> + \"\\\"x\"", "\"x\\\r\ny\" + #comment\r\n <z>", "name", "-0.25" }) |source| {
        for (0..source.len + 1) |end| {
            const prefix = source[0..end];
            var parts = dot.identifier.parts(prefix, .{ .start = 0, .len = @intCast(end) }) catch continue;
            var previous: u32 = 0;
            while (parts.next()) |part| {
                try expect(part.raw.start >= previous and part.raw.endOffset() <= end);
                try expect(part.inner.start >= part.raw.start and part.inner.endOffset() <= part.raw.endOffset());
                _ = try part.fragment(prefix);
                previous = @intCast(part.raw.endOffset());
            }
            try equal(end, previous);
        }
    }
    const edge = try markup.Fragment.init("x", std.math.maxInt(u32) - 1);
    const eof = try edge.child(.{ .start = 1, .len = 0 });
    try equal(std.math.maxInt(u32), eof.origin);
    var empty = try markup.parseAndValidateFragment(allocator, eof, discard, .{});
    defer empty.deinit();
    try expect(empty.documentValid());
}

// This is a consumer-owned byte check, not a built-in string implementation.
const StringSchema = struct {
    pub const Policy = struct { reject: ?u8 = null };
    pub const Effective = struct { reject: u8 };
    pub const defaults: Effective = .{ .reject = '!' };
    pub const Error = error{InvalidByte};
    pub const Issue = enum {
        invalid_byte,
        pub fn asError(_: @This()) Error {
            return error.InvalidByte;
        }
    };
    pub const Check = union(enum) { valid, invalid: Issue };
    pub fn resolve(base: Effective, patch: Policy) Effective {
        return .{ .reject = patch.reject orelse base.reject };
    }
    pub fn check(effective: Effective, _: Policy) Check {
        return if (effective.reject == 0) .{ .invalid = .invalid_byte } else .valid;
    }
};
fn StringReader(comptime runtime: bool) type {
    return struct {
        pub const Policies = dot.processor.PolicyBinding(StringSchema, .{ .runtime_policy = runtime });
        pub fn first(input: markup.Fragment, policy: Policies.State) !?dot.Span {
            const effective = if (runtime) policy else Policies.baseline;
            const index = std.mem.indexOfScalar(u8, input.bytes, effective.reject) orelse return null;
            return try input.rebase(.{ .start = @intCast(index), .len = 1 });
        }
    };
}
test "nested policies support DOT to markup to consumer string and an independent sibling string" {
    const M = markup.Profile(.{ .runtime_policy = true });
    const S = StringReader(true);
    const Inner = dot.processor.PolicySet(.{ .parser = M, .string = S });
    const Root = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}), .markup = Inner, .string = S });
    const state = try Root.prepare(.{
        .markup = .{ .string = .{ .policy = .{ .reject = '?' } } },
        .string = .{ .policy = .{ .reject = '!' } },
    });
    const ready: M.Prepared = .{ .policies = state.markup.parser };
    const source = "graph { a [label=<<b x='?'>!</b>>]; }";
    var parts = try dot.identifier.parts(source, span(source, "<<b x='?'>!</b>>"));
    const fragment = try parts.next().?.fragment(source);
    var inner = try ready.parseAndValidateFragment(allocator, fragment, discard, .{});
    defer inner.deinit();
    try expect(inner.documentValid());
    const attribute = inner.parse.document.?.attributes[0];
    const child = try fragment.child(.{ .start = attribute.value.start + 1, .len = attribute.value.len - 2 });
    try equal(span(source, "?"), (try S.first(child, state.markup.string)).?);
    try expect(try S.first(child, state.string) == null);
    try equal(span(source, "!"), (try S.first(fragment, state.string)).?);
    try std.testing.expectError(error.InvalidByte, Root.prepare(.{ .markup = .{ .string = .{ .policy = .{ .reject = 0 } } } }));
    try std.testing.expectError(error.InvalidSpan, fragment.child(.{ .start = 1000, .len = 1 }));
    const Fixed = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}), .markup = dot.processor.PolicySet(.{ .parser = markup.Profile(.{}), .string = StringReader(false) }), .string = StringReader(false) });
    try equal(@as(usize, 0), @sizeOf(Fixed.State));
    try equal(@as(usize, 0), @sizeOf(Fixed.Options));
    try equal(@as(usize, 0), @sizeOf(markup.Profile(.{}).Prepared));
    _ = try Fixed.prepare(.{});
}
