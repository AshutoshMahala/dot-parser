const std = @import("std");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const discard = markup.diagnostic.discard;
const Span = markup.location.Span;
fn span(source: []const u8, needle: []const u8) Span {
    return .{ .start = @intCast(std.mem.indexOf(u8, source, needle).?), .len = @intCast(needle.len) };
}
const All = markup.Profile(.{ .policy = .{ .validation = .{
    .invalid_utf8 = .err,
    .names = .{ .severity = .err },
    .references = .{ .severity = .err },
} } });

test "local attribute value validation is independent of outer syntax and excludes surrounding bytes" {
    const source = "\xff<x a='&bogus;\xff' broken </wrong>\xff";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const checked = All.validateScopeIn(source, .{ .attribute_value = span(source, "&bogus;\xff") }, .{}, bag.sink(), .{});
    try equal(.complete, checked.completion);
    try equal(.invalid, checked.validity);
    try equal(@as(u64, 2), checked.errors);
    try equal(.not_run, checked.checks.duplicate_attribute);
    try equal(.complete, checked.checks.invalid_utf8);
    try equal(.complete, checked.checks.names);
    try equal(.complete, checked.checks.references);
    try equal(markup.diagnostic.Code.unknown_reference, bag.items()[0].code);
    try equal(markup.diagnostic.Code.invalid_utf8, bag.items()[1].code);
    try equal(span(source, "&bogus;").start + 7, bag.items()[1].span.start);
    const P = markup.Profile(.{ .policy = .{ .validation = .{ .invalid_utf8 = .err } } });
    var truncated: markup.FixedDiagnosticBag(8) = .{};
    // A local boundary cannot borrow continuation bytes from an adjacent scope.
    const r = P.validateScopeIn("\xc3\xa9", .{ .bytes = .{ .start = 0, .len = 1 } }, .{}, truncated.sink(), .{});
    try equal(@as(u64, 1), r.errors);
    try equal(@as(u32, 0), truncated.items()[0].span.start);
}

test "headers names and content can be validated without a tree" {
    const source = "<x a='&bogus;' a='2'";
    const attributes = [_]markup.ScopeAttribute{
        .{ .name = .{ .start = 3, .len = 1 }, .value = span(source, "'&bogus;'") },
        .{ .name = .{ .start = 15, .len = 1 }, .value = span(source, "'2'") },
    };
    const header: markup.HeaderScope = .{ .span = .{ .start = 0, .len = source.len }, .name = .{ .start = 1, .len = 1 }, .attributes = &attributes, .complete = false };
    var keys: markup.FixedValidationScratch(2) = .{};
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const checked = All.validateScopeIn(source, .{ .opening_header = header }, keys.storage(), bag.sink(), .{});
    try equal(@as(u32, source.len), checked.completion.incomplete);
    try equal(.invalid, checked.validity);
    try equal(@as(u64, 2), checked.errors);
    try equal(.incomplete, checked.checks.duplicate_attribute);
    try equal(markup.diagnostic.Code.unknown_reference, bag.items()[0].code);
    try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[1].code);
    try equal(attributes[0].name, bag.items()[1].related.?);
    const Names = markup.Profile(.{ .policy = .{ .validation = .{ .names = .{ .severity = .err } } } });
    inline for (.{ "opening_name", "closing_name", "attribute_name" }) |kind| {
        var names: markup.FixedDiagnosticBag(4) = .{};
        const r = Names.validateScopeIn("·", @unionInit(markup.ValidationScope, kind, .{ .start = 0, .len = 2 }), .{}, names.sink(), .{});
        try equal(.complete, r.completion);
        try equal(@as(u64, 1), r.errors);
        try equal(.not_run, r.checks.duplicate_attribute);
        try equal(.not_run, r.checks.references);
        try equal(if (std.mem.eql(u8, kind, "attribute_name")) markup.diagnostic.NameContext.attribute else .element, names.items()[0].details.name.context);
    }
}

test "source scopes report duplicate attributes despite closing tag errors with policy parity" {
    const source = "<x a='1' a='2'>&bogus;</wrong>";
    var parsed = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer parsed.deinit();
    try equal(markup.Outcome.invalid_syntax, parsed.outcome);
    try expect(parsed.document == null);
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |cancellable| {
        const p: markup.Policy = .{ .scanner = backend, .validation = .{ .references = .{ .severity = .err } }, .execution = .{ .cancellation = cancellable } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{ .validation = .{ .duplicate_attribute = .off } } else p });
        const options: P.Options = if (runtime) .{ .policy = .{ .scanner = backend, .validation = .{ .duplicate_attribute = .err, .references = .{ .severity = .err } }, .execution = .{ .cancellation = cancellable } } } else .{};
        var scratch: markup.FixedSourceValidationScratch(2) = .{};
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = P.validateSourceIn(source, scratch.storage(), bag.sink(), options);
        try equal(.complete, r.completion); // Local coverage, NOT balanced elements.
        try equal(.invalid, r.validity);
        try equal(@as(u64, 2), r.errors);
        try equal(.complete, r.checks.duplicate_attribute);
        try equal(.complete, r.checks.references);
        try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[0].code);
        try equal(markup.diagnostic.Code.unknown_reference, bag.items()[1].code);
        const allocated = P.validateSource(std.testing.allocator, source, discard, options);
        try std.testing.expectEqualDeep(r, allocated);
    };
}

test "partial header validation survives missing delimiters and safely resumes other scopes" {
    const P = markup.Profile(.{ .policy = .{ .validation = .{ .references = .{ .severity = .err } } } });
    for ([_][]const u8{
        "<x a='1' a='2'>", "<x a='1' a='2'></x", "<x a='1' a='2'", "<x a='1' a='2' </x>",
    }, 0..) |source, index| {
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = P.validateSource(std.testing.allocator, source, bag.sink(), .{});
        try equal(@as(u64, 1), r.errors);
        try equal(.invalid, r.validity);
        if (index == 0) try equal(.complete, r.completion) else try expect(r.completion == .incomplete);
        try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[0].code);
    }
    const source = "<a x='1' x='2' bad=0/><b y='1' y='2'/><c>&bogus;</c>";
    var scratch: markup.FixedSourceValidationScratch(3) = .{};
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const recovered = P.validateSourceIn(source, scratch.storage(), bag.sink(), .{});
    try equal(span(source, "0").start, recovered.completion.incomplete);
    try equal(@as(u64, 3), recovered.errors);
    try equal(.incomplete, recovered.checks.duplicate_attribute);
    const Fast = markup.Profile(.{ .policy = .{ .recovery = .fail_fast } });
    const fast = Fast.validateSourceIn(source, scratch.storage(), discard, .{});
    try equal(recovered.completion.incomplete, fast.completion.incomplete);
    try equal(@as(u64, 1), fast.errors);
    const quoted = P.validateSourceIn("<x good='&bogus;' bad='unfinished", scratch.storage(), discard, .{});
    try expect(quoted.completion == .incomplete);
    try equal(@as(u64, 1), quoted.errors);
}

test "encoding remains independent of terminal syntax while local coverage stays incomplete" {
    const source = "<x bad='unterminated\xff";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const r = All.validateSource(std.testing.allocator, source, bag.sink(), .{});
    try equal(@as(u32, source.len), r.completion.incomplete);
    try equal(.complete, r.checks.invalid_utf8);
    try equal(.incomplete, r.checks.references);
    try equal(.invalid, r.validity);
    try equal(@as(u64, 1), r.errors);
    var scratch: markup.FixedSourceValidationScratch(1) = .{};
    const empty = markup.validateSourceIn("<x bad='unfinished", scratch.storage(), discard, .{});
    try equal(@as(u32, "<x bad='unfinished".len), empty.completion.incomplete);
    try equal(.unknown, empty.validity);
}

test "source scope buffers are explicit reusable bounded and optional" {
    const source = "<a x='1' x='2'/><b y='1' y='2'/>";
    var attrs: [2]markup.ScopeAttribute = undefined;
    var keys: [2]markup.AttributeKeyScratch = undefined;
    const good = markup.validateSourceIn(source, .{ .attributes = &attrs, .attribute_keys = &keys }, discard, .{});
    try equal(.complete, good.completion);
    try equal(@as(u64, 2), good.errors);
    inline for (.{ false, true }) |key_shortage| {
        var bag: markup.FixedDiagnosticBag(4) = .{};
        const bad = markup.validateSourceIn(source, .{ .attributes = attrs[0..if (key_shortage) 2 else 1], .attribute_keys = keys[0..if (key_shortage) 1 else 2] }, bag.sink(), .{});
        try equal(@as(u32, 2), bad.completion.storage_exhausted);
        try equal(.unknown, bad.validity);
        try equal(if (key_shortage) markup.diagnostic.Resource.attribute_keys else .header_attributes, bag.items()[0].details.capacity.resource);
    }
    const P = markup.Profile(.{ .policy = .{ .validation = .{ .duplicate_attribute = .off, .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
    const no_alloc = P.validateSource(std.testing.failing_allocator, "<x a='&bogus;' b='2'></bad>", discard, .{});
    try equal(.complete, no_alloc.completion);
    try equal(@as(u64, 1), no_alloc.errors);
    try equal(.not_run, no_alloc.checks.duplicate_attribute);
    try equal(@as(usize, 24), markup.FixedSourceValidationScratch(1).byte_size);
    try equal(@as(usize, 32), @sizeOf(markup.ValidationResult));
}

test "scope validation stops immediately for diagnostic stops failures and cancellation" {
    const source = "<x a='1' a='2'/><y b='1' b='2'/>";
    var scratch: markup.FixedSourceValidationScratch(2) = .{};
    var bag: markup.FixedDiagnosticBag(1) = .{};
    const stopped = markup.validateSourceIn(source, scratch.storage(), bag.sink(), .{});
    try equal(markup.reporting.StopReason.requested, stopped.completion.diagnostic_stopped);
    try equal(@as(u64, 1), stopped.errors);
    try equal(.invalid, stopped.validity);
    try equal(.incomplete, stopped.checks.duplicate_attribute);
    const Reject = struct {
        fn emit(_: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            return error.DiagnosticSinkFailure;
        }
    };
    const failed = markup.validateSourceIn(source, scratch.storage(), .{ .context = null, .emit_fn = Reject.emit }, .{});
    try equal(markup.reporting.StopReason.failure, failed.completion.diagnostic_stopped);
    try equal(.failed, failed.diagnostic_delivery);
    try equal(@as(u64, 1), failed.errors);
    const Stop = struct {
        fn poll(_: ?*anyopaque) bool {
            return true;
        }
    };
    const P = markup.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } });
    const cancelled = P.validateSourceIn(source, .{}, discard, .{ .cancellation = .{ .context = null, .is_requested = Stop.poll } });
    try equal(.cancelled, cancelled.completion);
    try equal(.unknown, cancelled.validity);
    try equal(.incomplete, cancelled.checks.duplicate_attribute);
}

test "source validation honors source limits before dereferencing descriptors" {
    const P = markup.Profile(.{ .policy = .{ .limits = .{ .max_source_bytes = 3 } } });
    const unreadable = @as([*]const u8, @ptrFromInt(1))[0..4];
    const r = P.validateSourceIn(unreadable, .{}, discard, .{});
    try equal(@as(u32, 3), r.completion.source_limit);
    try equal(.incomplete, r.checks.duplicate_attribute);
}

fn allocatedScopes(allocator: std.mem.Allocator) !void {
    const source = "<x a='1' a='2'/><x a='1' b='2' c='3' d='4' e='5' f='6' a='7'>";
    const r = markup.validateSource(allocator, source, discard, .{});
    if (r.completion == .out_of_memory) return error.OutOfMemory;
    try equal(.complete, r.completion);
    try equal(@as(u64, 2), r.errors);
}
test "source scope allocation failures release both reusable buffers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatedScopes, .{});
}

test "scope scanning is invariant across every source truncation and backend" {
    const source = "<x good='&bogus;' a='1' a='2' bad=0 title='>'/><y>&amp;</wrong>";
    for (0..source.len + 1) |end| {
        var scalar: markup.FixedDiagnosticBag(16) = .{};
        var block: markup.FixedDiagnosticBag(16) = .{};
        const a = All.validateSource(std.testing.allocator, source[0..end], scalar.sink(), .{});
        inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |cancellable| {
            block.reset();
            const B = markup.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .cancellation = cancellable }, .validation = .{ .invalid_utf8 = .err, .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
            const b = B.validateSource(std.testing.allocator, source[0..end], block.sink(), .{});
            try std.testing.expectEqualDeep(a, b);
            try std.testing.expectEqualSlices(markup.Diagnostic, scalar.items(), block.items());
        };
    }

    // Mutate both delimiters and content: lexical failures must never expose
    // an out-of-range or misordered local view to the shared validation rules.
    var random = std.Random.DefaultPrng.init(0x53434f504553);
    var bytes: [source.len]u8 = undefined;
    const Block = markup.Profile(.{ .policy = .{ .scanner = .block, .execution = .{ .cancellation = true }, .validation = .{
        .invalid_utf8 = .err,
        .names = .{ .severity = .err },
        .references = .{ .severity = .err },
    } } });
    for (0..2048) |_| {
        @memcpy(&bytes, source);
        for (0..1 + random.random().uintLessThan(usize, 4)) |_| {
            bytes[random.random().uintLessThan(usize, bytes.len)] = random.random().int(u8);
        }
        var scalar: markup.FixedDiagnosticBag(64) = .{};
        var block: markup.FixedDiagnosticBag(64) = .{};
        var scratch: markup.FixedSourceValidationScratch(16) = .{};
        const a = All.validateSourceIn(&bytes, scratch.storage(), scalar.sink(), .{});
        const b = Block.validateSourceIn(&bytes, scratch.storage(), block.sink(), .{});
        try std.testing.expectEqualDeep(a, b);
        try std.testing.expectEqualSlices(markup.Diagnostic, scalar.items(), block.items());
    }
}

fn allocatedHeaderScope(allocator: std.mem.Allocator) !void {
    const source = "<x a='1' a='2'/>";
    const attributes = [_]markup.ScopeAttribute{
        .{ .name = .{ .start = 3, .len = 1 }, .value = .{ .start = 5, .len = 3 } },
        .{ .name = .{ .start = 9, .len = 1 }, .value = .{ .start = 11, .len = 3 } },
    };
    const r = markup.validateScope(allocator, source, .{ .opening_header = .{ .span = .{ .start = 0, .len = source.len }, .name = .{ .start = 1, .len = 1 }, .attributes = &attributes } }, discard, .{});
    if (r.completion == .out_of_memory) return error.OutOfMemory;
    try equal(.complete, r.completion);
    try equal(@as(u64, 1), r.errors);
}
test "standalone header scope allocation is optional and failure safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatedHeaderScope, .{});
    const r = All.validateScope(std.testing.failing_allocator, "&bogus;", .{ .attribute_value = .{ .start = 0, .len = 7 } }, discard, .{});
    try equal(.complete, r.completion);
    try equal(@as(u64, 1), r.errors);
}

test "a broken attribute value does not hide its name or completed references in its prefix" {
    const P = markup.Profile(.{ .policy = .{ .validation = .{ .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
    const source = "<x a='1' a='&bogus;";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    const r = P.validateSource(std.testing.allocator, source, bag.sink(), .{});
    try equal(@as(u32, source.len), r.completion.incomplete);
    try equal(@as(u64, 2), r.errors);
    try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[0].code);
    try equal(markup.diagnostic.Code.unknown_reference, bag.items()[1].code);
    for ([_][]const u8{ "<x \xff=0>", "<x \xff='unfinished", "<\xff </x>", "<x></\xff" }) |input| {
        var names: markup.FixedDiagnosticBag(8) = .{};
        const checked = P.validateSource(std.testing.allocator, input, names.sink(), .{});
        try expect(checked.completion == .incomplete);
        try equal(@as(u64, 1), checked.errors);
        try equal(markup.diagnostic.Code.invalid_name, names.items()[0].code);
    }
}

test "scope severities have fixed runtime and disabled-check parity" {
    inline for (.{ .err, .warning, .off }) |severity| inline for (.{ false, true }) |runtime| {
        const p: markup.Policy = .{ .validation = .{ .duplicate_attribute = severity, .references = .{ .severity = severity } } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else p });
        var scratch: markup.FixedSourceValidationScratch(2) = .{};
        const r = P.validateSourceIn("<x a='1' a='2'>&bogus;</wrong>", scratch.storage(), discard, if (runtime) .{ .policy = p } else .{});
        try equal(.complete, r.completion);
        try equal(@as(u64, if (severity == .err) 2 else 0), r.errors);
        try equal(@as(u64, if (severity == .warning) 2 else 0), r.warnings);
        try equal(if (severity == .err) @TypeOf(r.validity).invalid else .valid, r.validity);
        try equal(if (severity == .off) @TypeOf(r.checks.duplicate_attribute).not_run else .complete, r.checks.duplicate_attribute);
    };
}

test "source scopes and retained validation share diagnostic kernels" {
    const P = markup.Profile(.{ .policy = .{ .validation = .{ .names = .{ .severity = .err }, .references = .{ .severity = .err } } } });
    for ([_][]const u8{
        "<x a='1' a='2' a='3'/>",
        "<x b='&bogus;' a='2' b='3' c='4' d='5' e='6' a='7' b='8' f='9'/>",
        "<x \xff='&\xff;' a='&bogus;'/>text &unknown;<!--&not_checked;-->",
    }) |input| {
        var parsed = markup.parseBorrowed(std.testing.allocator, input, discard, .{});
        defer parsed.deinit();
        const document = parsed.document.?;
        var retained: markup.FixedDiagnosticBag(32) = .{};
        var streamed: markup.FixedDiagnosticBag(32) = .{};
        const a = P.validate(std.testing.allocator, &document, retained.sink(), .{});
        const b = P.validateSource(std.testing.allocator, input, streamed.sink(), .{});
        try std.testing.expectEqualDeep(a, b);
        try std.testing.expectEqualSlices(markup.Diagnostic, retained.items(), streamed.items());
    }
}

fn expectInvalidScope(comptime P: type, source: []const u8, scope: markup.ValidationScope, options: P.Options) !void {
    var bag: markup.FixedDiagnosticBag(4) = .{};
    const expected: markup.ValidationResult = .{ .completion = .invalid_scope };
    const fixed = P.validateScopeIn(source, scope, .{}, bag.sink(), options);
    try std.testing.expectEqualDeep(expected, fixed);
    // Invalid metadata wins before either allocation or content diagnostics.
    const allocated = P.validateScope(std.testing.failing_allocator, source, scope, bag.sink(), options);
    try std.testing.expectEqualDeep(expected, allocated);
    try equal(@as(usize, 0), bag.items().len);
}

test "public scope metadata is checked with fixed runtime and disabled content policies" {
    const source = "<x a='1' b='2'/>";
    inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |enabled| {
        const p: markup.Policy = .{ .validation = .{
            .duplicate_attribute = if (enabled) .err else .off,
            .invalid_utf8 = if (enabled) .err else .off,
            .names = .{ .severity = if (enabled) .err else .off },
            .references = .{ .severity = if (enabled) .err else .off },
        } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else p });
        const options: P.Options = if (runtime) .{ .policy = p } else .{};
        inline for (.{ "opening_name", "closing_name", "attribute_name", "attribute_value", "text", "bytes" }) |kind| {
            for ([_]Span{
                .{ .start = source.len + 1, .len = 0 },
                .{ .start = source.len, .len = 1 },
                .{ .start = 1, .len = std.math.maxInt(u32) },
                .{ .start = std.math.maxInt(u32), .len = std.math.maxInt(u32) },
            }) |bad| try expectInvalidScope(P, source, @unionInit(markup.ValidationScope, kind, bad), options);
        }
        inline for (.{ "opening_name", "closing_name", "attribute_name" }) |kind|
            try expectInvalidScope(P, source, @unionInit(markup.ValidationScope, kind, .{ .start = 1, .len = 0 }), options);
        for (0..13) |case| {
            var attributes = [_]markup.ScopeAttribute{
                .{ .name = .{ .start = 3, .len = 1 }, .value = .{ .start = 5, .len = 3 } },
                .{ .name = .{ .start = 9, .len = 1 }, .value = .{ .start = 11, .len = 3 } },
            };
            var header: markup.HeaderScope = .{ .span = .{ .start = 0, .len = source.len }, .name = .{ .start = 1, .len = 1 }, .attributes = &attributes };
            switch (case) {
                0 => attributes[0].value.len = 0,
                1 => attributes[0].value.len = 1,
                2 => attributes[0].value.len = 2, // quotes do not match
                3 => std.mem.swap(markup.ScopeAttribute, &attributes[0], &attributes[1]),
                4 => header.name.len = 0,
                5 => header.span = .{ .start = 2, .len = source.len - 2 },
                6 => header.span.len = 10, // attributes inside source, outside header
                7 => attributes[0].name = .{ .start = 1, .len = 1 },
                8 => attributes[0].value.start = 3,
                9 => attributes[1].value.len = std.math.maxInt(u32),
                10 => attributes[0].value = .{ .start = 6, .len = 2 }, // not a quoted value
                11 => attributes[0].name.len = 0,
                12 => {
                    header.complete = false;
                    attributes[0].value = .{ .start = std.math.maxInt(u32), .len = 0 };
                },
                else => unreachable,
            }
            try expectInvalidScope(P, source, .{ .opening_header = header }, options);
        }
        // Empty content at EOF is a valid region, unlike an empty name.
        const empty = P.validateScopeIn(source, .{ .bytes = .{ .start = source.len, .len = 0 } }, .{}, discard, options);
        try equal(.complete, empty.completion);
        try equal(.valid, empty.validity);
    };
}

test "oversized scope descriptors are rejected before source or attribute reads" {
    if (@sizeOf(usize) <= 4) return error.SkipZigTest;
    const oversized: usize = @as(usize, std.math.maxInt(u32)) + 1;
    const source = @as([*]const u8, @ptrFromInt(1))[0..oversized];
    try expectInvalidScope(All, source, .{ .bytes = .{ .start = 0, .len = 1 } }, .{});
    const attributes = @as([*]const markup.ScopeAttribute, @ptrFromInt(@alignOf(markup.ScopeAttribute)))[0..oversized];
    try expectInvalidScope(All, "<x/>", .{ .opening_header = .{
        .span = .{ .start = 0, .len = 4 },
        .name = .{ .start = 1, .len = 1 },
        .attributes = attributes,
    } }, .{});
}

test "public metadata audit honors cancellation even with content checks off" {
    const source = [_]u8{'x'} ** 257;
    var attributes: [256]markup.ScopeAttribute = undefined;
    for (&attributes, 1..) |*a, index| a.* = .{ .name = .{ .start = @intCast(index), .len = 1 } };
    const Stop = struct {
        calls: u32 = 0,
        fn requested(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return self.calls == 3;
        }
    };
    const P = markup.Profile(.{ .policy = .{ .validation = .{ .duplicate_attribute = .off }, .execution = .{ .cancellation = true } } });
    var stop: Stop = .{};
    const r = P.validateScope(std.testing.failing_allocator, &source, .{ .opening_header = .{
        .span = .{ .start = 0, .len = source.len },
        .name = .{ .start = 0, .len = 1 },
        .attributes = &attributes,
        .complete = false,
    } }, discard, .{ .cancellation = .{ .context = &stop, .is_requested = Stop.requested } });
    try equal(.cancelled, r.completion);
    try equal(.unknown, r.validity);
    try equal(@as(u32, 3), stop.calls);
}

test "incomplete offsets retain the earliest lexical gap despite later checks" {
    const source = "ok<a bad=0/><b other=1/><c x='1' x='2'>&bogus;</c>\xff";
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| {
        const p: markup.Policy = .{ .scanner = backend, .validation = .{ .invalid_utf8 = .err, .references = .{ .severity = .err } } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else p });
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = P.validateSource(std.testing.allocator, source, bag.sink(), if (runtime) .{ .policy = p } else .{});
        try equal(span(source, "0").start, r.completion.incomplete);
        try equal(.complete, r.checks.invalid_utf8);
        try equal(.incomplete, r.checks.references);
        try equal(@as(u64, 3), r.errors);
        try equal(.invalid, r.validity);
        // Encoding ran first; later local checks ran beyond the first gap.
        try equal(markup.diagnostic.Code.invalid_utf8, bag.items()[0].code);
        try equal(markup.diagnostic.Code.duplicate_attribute, bag.items()[1].code);
        try expect(bag.items()[1].span.start > r.completion.incomplete);
    };
    const prefix = "prefix<?unsupported?>";
    const unsupported = All.validateSourceIn(prefix, .{}, discard, .{});
    try equal(@as(u32, "prefix".len), unsupported.completion.incomplete);
    const unfinished = "prefix<x bad='unfinished";
    var scratch: markup.FixedSourceValidationScratch(1) = .{};
    const eof = All.validateSourceIn(unfinished, scratch.storage(), discard, .{});
    try equal(@as(u32, unfinished.len), eof.completion.incomplete);
    try equal(.unknown, eof.validity);
    const terminal = "<a bad=0/><b unfinished='";
    const later = All.validateSourceIn(terminal, scratch.storage(), discard, .{});
    try equal(span(terminal, "0").start, later.completion.incomplete);
    // A later operational stop keeps its cause instead of returning the gap.
    var stopped_bag: markup.FixedDiagnosticBag(1) = .{};
    const stopped = markup.validateSource(std.testing.allocator, "<a bad=0/><b x='1' x='2'/>", stopped_bag.sink(), .{});
    try equal(markup.reporting.StopReason.requested, stopped.completion.diagnostic_stopped);
    try equal(@as(usize, 32), @sizeOf(markup.ValidationResult));
}

test "incomplete header scope offsets identify unavailable values or the prefix boundary" {
    const source = "prefix<x a='1' b='unfinished";
    const attrs = [_]markup.ScopeAttribute{
        .{ .name = .{ .start = span(source, "a=").start, .len = 1 }, .value = span(source, "'1'") },
        .{ .name = .{ .start = span(source, "b=").start, .len = 1 } },
    };
    var header: markup.HeaderScope = .{
        .span = .{ .start = 6, .len = source.len - 6 },
        .name = .{ .start = 7, .len = 1 },
        .attributes = &attrs,
        .complete = false,
    };
    const missing = markup.validateScope(std.testing.allocator, source, .{ .opening_header = header }, discard, .{});
    try equal(@as(u32, @intCast(attrs[1].name.endOffset())), missing.completion.incomplete);
    try equal(.unknown, missing.validity);
    header.attributes = attrs[0..1];
    header.span.len = @intCast(attrs[0].value.endOffset() - header.span.start);
    const prefix = markup.validateScopeIn(source, .{ .opening_header = header }, .{}, discard, .{});
    try equal(@as(u32, @intCast(header.span.endOffset())), prefix.completion.incomplete);
}
