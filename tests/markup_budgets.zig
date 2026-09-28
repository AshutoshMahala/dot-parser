//! Resource budgets bound adversarial shapes independently of diagnostic severity.
const std = @import("std");
const markup = @import("markup_parser");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const discard = markup.diagnostic.discard;
const Untrusted = markup.Profile(.{ .policy = markup.presets.untrusted });

test "16 MiB invalid-byte floods retain at most 1024 diagnostics, including alternating bytes" {
    const source = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(source);
    inline for (.{ false, true }) |alternating| {
        @memset(source, 0xff);
        if (alternating) {
            var index: usize = 0;
            while (index < source.len) : (index += 2) source[index] = 'x';
        }
        var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
        const parsed = markup.parseBorrowedIn(source, .{ .document = output.storage() }, discard, .{});
        try equal(markup.Outcome.success, parsed.outcome);
        const document = parsed.document.?;
        const P = markup.Profile(.{ .runtime_policy = alternating, .policy = .{ .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = .err } } });
        // Track only diagnostic allocations, not the caller's input buffer.
        var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var bag = markup.GrowableDiagnosticBag.init(tracked.allocator(), .{});
        const checked = P.validateIn(&document, .{}, bag.sink(), .{});
        try equal(markup.reporting.StopReason.requested, checked.completion.diagnostic_stopped);
        try equal(.invalid, checked.validity);
        try equal(.complete, checked.diagnostic_delivery);
        try equal(.incomplete, checked.checks.invalid_utf8);
        try equal(@as(u64, 1024), checked.errors);
        try equal(@as(usize, 1024), bag.items().len);
        try expect(bag.storage.capacity <= 1024);
        try equal(@as(usize, 1024 * 36), tracked.allocated_bytes - tracked.freed_bytes);
        for (bag.items(), 0..) |finding, index| {
            try equal(@as(u32, @intCast(if (alternating) 2 * index + 1 else index)), finding.span.start);
            try equal(@as(u32, 1), finding.span.len);
        }
        bag.deinit();
        try equal(tracked.allocated_bytes, tracked.freed_bytes);
        // Wide factual counts remain available with a non-retaining destination.
        const prefix = markup.parseBorrowedIn(source[0..70_000], .{ .document = output.storage() }, discard, .{});
        const complete = P.validateIn(&prefix.document.?, .{}, discard, .{});
        try equal(.complete, complete.completion);
        try equal(@as(u64, if (alternating) 35_000 else 70_000), complete.errors);
    }
}

test "default bag bounds duplicate floods without mutating the completed tree" {
    const source = "<a " ++ "x='0' " ** 2049 ++ "/>";
    var output: markup.FixedDocumentStorage(.{ .nodes = 1, .attributes = 2049 }) = .{};
    var scratch: markup.FixedValidationScratch(2049) = .{};
    const parsed = markup.parseBorrowedIn(source, .{ .document = output.storage() }, discard, .{});
    const document = parsed.document.?;
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    const checked = markup.validateIn(&document, scratch.storage(), bag.sink(), .{});
    try equal(markup.reporting.StopReason.requested, checked.completion.diagnostic_stopped);
    try equal(.incomplete, checked.checks.duplicate_attribute);
    try equal(@as(u64, 1024), checked.errors);
    try equal(@as(usize, 1024), bag.items().len);
    try equal(@as(usize, 2049), document.attributes.len);
    var unlimited = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{ .max_entries = .unlimited });
    defer unlimited.deinit();
    const complete = markup.validateIn(&document, scratch.storage(), unlimited.sink(), .{});
    try equal(.complete, complete.completion);
    try equal(@as(u64, 2048), complete.errors);
    try equal(@as(usize, 2048), unlimited.items().len);
}

test "default bag bounds tolerated-reference floods and latched sessions do no more work" {
    const P = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .warn }, .execution = .{ .metering = true } } });
    var bag = markup.GrowableDiagnosticBag.init(std.testing.allocator, .{});
    defer bag.deinit();
    var output: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    var session = P.Session.init("& " ** 2048, .{ .document = output.storage() }, bag.sink(), .{});
    while (session.result() == null) _ = session.advance(7);
    const result = session.result().?;
    try equal(markup.reporting.StopReason.requested, result.outcome.diagnostic_stopped);
    try equal(@as(u32, 1024), result.accepted_deviations);
    try equal(@as(u32, 1024), result.warnings);
    try expect(result.document == null);
    try equal(@as(usize, 1024), bag.items().len);
    try equal(@as(u32, 0), session.advance(100).work_used);
    try equal(result, session.run());
    try equal(@as(usize, 1024), bag.items().len);
}

test "untrusted is a complete resource-only preset with runtime inheritance and reset" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true, .policy = markup.presets.untrusted });
    const HostileBaseline = markup.Profile(.{ .runtime_policy = true, .policy = .{
        .scanner = .block,
        .syntax = .{ .malformed_reference = .accept },
        .validation = .{ .duplicate_attribute = .off, .invalid_utf8 = .err },
        .execution = .{ .metering = true, .cancellation = true },
    } });
    const prepared = try HostileBaseline.Policies.prepare(.{ .policy = markup.presets.untrusted });
    try std.testing.expectEqualDeep(Untrusted.baseline, prepared);
    try equal(@as(u32, 8 * 1024 * 1024), Untrusted.baseline.limits.max_source_bytes);
    try equal(@as(u32, 100_000), Untrusted.baseline.limits.max_nodes);
    try equal(@as(u32, 200_000), Untrusted.baseline.limits.max_attributes);
    try equal(@as(u32, 256), Untrusted.baseline.limits.max_nesting);
    // The preset does not turn byte-oriented parsing into an encoding dialect.
    try equal(markup.Outcome.success, Untrusted.measureIn("\xff", .{}, discard, .{}).outcome);
    try equal(.off, Untrusted.baseline.validation.invalid_utf8);
    const patched = try Dynamic.Policies.prepare(.{ .policy = .{ .limits = .{ .max_nodes = 7 } } });
    try equal(@as(u32, 7), patched.limits.max_nodes);
    try equal(Untrusted.baseline.limits.max_source_bytes, patched.limits.max_source_bytes);
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    var session = Dynamic.Session.init("<x/>", .{ .document = nodes.storage() }, discard, .{ .policy = .{ .limits = .{ .max_nodes = 0 } } });
    try expect(session.run().outcome == .resource_limit);
    session.reset("<x/>", discard, .{});
    try equal(markup.Outcome.success, session.run().outcome);
}

test "untrusted source preflight rejects without reading or allocating; exact limit accepts" {
    const max = Untrusted.baseline.limits.max_source_bytes;
    const unreadable = @as([*]const u8, @ptrFromInt(1))[0 .. @as(usize, max) + 1];
    const expected: markup.Outcome = .{ .resource_limit = .{ .resource = .source_bytes, .limit = max } };
    var owned = Untrusted.parseBorrowed(std.testing.failing_allocator, unreadable, discard, .{});
    defer owned.deinit();
    try equal(expected, owned.outcome);
    try expect(owned.document == null);
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    try equal(expected, Dynamic.measureIn(unreadable, .{}, discard, .{ .policy = markup.presets.untrusted }).outcome);
    const source = try std.testing.allocator.alloc(u8, max);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    try equal(markup.Outcome.success, Untrusted.measureIn(source, .{}, discard, .{}).outcome);
}

fn repeated(prefix: []const u8, item: []const u8, count: usize, suffix: []const u8) ![]u8 {
    const source = try std.testing.allocator.alloc(u8, prefix.len + count * item.len + suffix.len);
    @memcpy(source[0..prefix.len], prefix);
    for (0..count) |index| @memcpy(source[prefix.len + index * item.len ..][0..item.len], item);
    @memcpy(source[prefix.len + count * item.len ..], suffix);
    return source;
}

test "untrusted count and nesting budgets accept exact boundaries and reject the next item" {
    const Dynamic = markup.Profile(.{ .runtime_policy = true });
    const max_nodes = Untrusted.baseline.limits.max_nodes;
    const nodes = try repeated("", "<a/>", max_nodes + 1, "");
    defer std.testing.allocator.free(nodes);
    try equal(markup.Outcome.success, Untrusted.measureIn(nodes[0 .. nodes.len - 4], .{}, discard, .{}).outcome);
    const node_limit = Untrusted.measureIn(nodes, .{}, discard, .{});
    try equal(markup.Outcome{ .resource_limit = .{ .resource = .nodes, .limit = max_nodes } }, node_limit.outcome);
    try equal(node_limit, Dynamic.measureIn(nodes, .{}, discard, .{ .policy = markup.presets.untrusted }));
    const max_attrs = Untrusted.baseline.limits.max_attributes;
    const attrs = try repeated("<a ", "x='' ", max_attrs + 1, "/>");
    defer std.testing.allocator.free(attrs);
    const attr_limit = Untrusted.measureIn(attrs, .{}, discard, .{});
    try equal(markup.Outcome{ .resource_limit = .{ .resource = .attributes, .limit = max_attrs } }, attr_limit.outcome);
    try equal(attr_limit, Dynamic.measureIn(attrs, .{}, discard, .{ .policy = markup.presets.untrusted }));
    // Turn the final pair into trailing whitespace, keeping the exact source size.
    @memset(attrs[3 + max_attrs * 5 ..][0..5], ' ');
    try equal(markup.Outcome.success, Untrusted.measureIn(attrs, .{}, discard, .{}).outcome);
    var frames: markup.FixedParseScratch(256) = .{};
    try equal(markup.Outcome.success, Untrusted.measureIn("<a>" ** 256 ++ "</a>" ** 256, frames.storage(), discard, .{}).outcome);
    const deep = "<a>" ** 257 ++ "</a>" ** 257;
    const depth_limit = Untrusted.measureIn(deep, frames.storage(), discard, .{});
    try equal(markup.Outcome{ .resource_limit = .{ .resource = .nesting_depth, .limit = 256 } }, depth_limit.outcome);
    try equal(depth_limit, Dynamic.measureIn(deep, frames.storage(), discard, .{ .policy = markup.presets.untrusted }));
}
