//! Differential scanner tests through the standalone public API.
const std = @import("std");
const m = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const Storage = m.FixedDocumentStorage(.{ .nodes = 64, .attributes = 32 });
const Scratch = m.FixedParseScratch(16);
const Dynamic = m.Profile(.{ .runtime_policy = true });

fn lexers(source: []const u8) !void {
    var scalar = m.lexer.For(.scalar).init(source);
    var block = m.lexer.For(.block).init(source);
    var steps: usize = 0;
    while (true) {
        const a = scalar.next();
        const b = block.next();
        try deep(a, b);
        steps += 1;
        try expect(steps <= source.len * 2 + 2);
        if (a == .problem or a.token.kind == .eof) {
            try deep(a, scalar.next());
            try deep(b, block.next());
            break;
        }
    }
}

fn compare(comptime acceptance: m.Acceptance, source: []const u8) !void {
    const Reference = m.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = acceptance } } });
    var storage: Storage = .{};
    var scratch: Scratch = .{};
    var bag: m.FixedDiagnosticBag(512) = .{};
    const reference = Reference.parseBorrowedIn(source, .{ .document = storage.storage(), .scratch = scratch.storage() }, bag.sink(), .{});
    inline for (.{ .scalar, .block }) |backend| {
        const Fixed = m.Profile(.{ .policy = .{ .scanner = backend, .syntax = .{ .malformed_reference = acceptance } } });
        var fixed_storage: Storage = .{};
        var fixed_scratch: Scratch = .{};
        var fixed_bag: m.FixedDiagnosticBag(512) = .{};
        const fixed = Fixed.parseBorrowedIn(source, .{ .document = fixed_storage.storage(), .scratch = fixed_scratch.storage() }, fixed_bag.sink(), .{});
        try deep(reference.outcome, fixed.outcome);
        try equal(reference.counts, fixed.counts);
        try equal(reference.accepted_deviations, fixed.accepted_deviations);
        try deep(bag.items(), fixed_bag.items());
        if (reference.document) |doc| {
            try deep(doc.records, fixed.document.?.records);
            try deep(doc.attributes, fixed.document.?.attributes);
        }
        var work_reference: ?u64 = null;
        inline for (.{ false, true }) |cancellable| {
            // Run-to-completion and differently partitioned bounded execution.
            for ([_]u32{ 0, 1, 7, 128 }) |budget| {
                var output: Storage = .{};
                var frames: Scratch = .{};
                var findings: m.FixedDiagnosticBag(512) = .{};
                const patch: m.Policy = .{
                    .scanner = backend,
                    .syntax = .{ .malformed_reference = acceptance },
                    .execution = .{ .metering = budget != 0, .cancellation = cancellable },
                };
                var session = Dynamic.Session.init(source, .{ .document = output.storage(), .scratch = frames.storage() }, findings.sink(), .{ .policy = patch });
                defer session.deinit();
                if (budget == 0) {
                    try std.testing.expectError(error.MeteringDisabled, session.advance(1));
                    _ = session.run();
                } else {
                    try equal(@as(u32, 0), (try session.advance(0)).work_used);
                    var work: u64 = 0;
                    var frontier: u32 = 0;
                    while (session.result() == null) {
                        const progress = try session.advance(budget);
                        work += progress.work_used;
                        try expect(progress.work_used > 0 and progress.work_used <= budget);
                        try expect(progress.source_frontier >= frontier and progress.source_frontier <= source.len);
                        // Includes lookahead; vector steps inspect up to 64 bytes.
                        try expect(progress.source_frontier - frontier <= @as(u64, budget) * (if (backend == .block) @as(u32, 64) else 1));
                        frontier = progress.source_frontier;
                        try expect(work <= source.len * 12 + 32);
                    }
                    if (work_reference) |w| try equal(w, work) else work_reference = work;
                }
                const got = session.result().?;
                try deep(reference.outcome, got.outcome);
                try deep(reference.counts, got.counts);
                try equal(reference.accepted_deviations, got.accepted_deviations);
                try equal(reference.warnings, got.warnings);
                try equal(reference.diagnostic_delivery, got.diagnostic_delivery);
                try deep(bag.items(), findings.items());
                if (reference.document) |document| {
                    try deep(document.records, got.document.?.records);
                    try deep(document.attributes, got.document.?.attributes);
                } else try expect(got.document == null);
                try deep(got, session.run());
                try deep(got, session.cancel());
            }
        }
    }
}

test "backends agree on every prefix, arbitrary bytes, and reference policies" {
    const cases = [_][]const u8{
        "",                                                                      "\xef\xbb\xbf<a/>",                                      "\xff\xfe<a/>",    "\x00\x00\xfe\xff",
        "<a aa='x' b=\"&bad\">text&amp;<!-- x-y --><![CDATA[xx]]]></a>&#xD800;", "<long-name attr = 'long-value'>x</wrong-name>",         "<a x='1'x='2'/>", "<!--x--y-->",
        "<![CDATA[",                                                             "&foo<&bar;&#x; &; &name &#99999999999999999999999999;", "<a><b></a>",      "<?pi?>",
        "<!DOCTYPE x>",                                                          "<a>\x00</a>",
    };
    inline for (.{ .reject, .warn, .accept }) |acceptance| {
        for (cases) |source| for (0..source.len + 1) |end| {
            try lexers(source[0..end]);
            try compare(acceptance, source[0..end]);
        };
        var random = std.Random.DefaultPrng.init(0x626c6f636b);
        var bytes: [160]u8 = undefined;
        for (0..300) |_| {
            const len = random.random().uintLessThan(usize, bytes.len + 1);
            random.random().bytes(bytes[0..len]);
            try lexers(bytes[0..len]);
            try compare(acceptance, bytes[0..len]);
        }
    }
}

test "every boundary byte at each block alignment and short tail" {
    var bytes: [160]u8 = undefined;
    for (0..129) |offset| {
        @memset(&bytes, 'x');
        for ("<&\x00\x01\t\r\n\xff") |byte| {
            bytes[offset] = byte;
            try lexers(bytes[0 .. offset + 1]);
            try lexers(&bytes);
            try compare(.warn, bytes[0 .. offset + 1]);
        }
    }
    inline for (.{ "<a {s}='x'/>", "<{s}></{s}>", "<a x='{s}'/>", "<a x=\"{s}\"/>", "<!--{s}-->", "<![CDATA[{s}]]>", "&{s};", "<a{s}x='v'/>" }) |format| {
        for (0..130) |len| {
            @memset(&bytes, if (comptime std.mem.eql(u8, format, "<a{s}x='v'/>")) ' ' else 'x');
            const source = try std.fmt.allocPrint(std.testing.allocator, format, if (comptime std.mem.eql(u8, format, "<{s}></{s}>")) .{ bytes[0..len], bytes[0..len] } else .{bytes[0..len]});
            defer std.testing.allocator.free(source);
            try lexers(source);
            try compare(.warn, source);
        }
    }
}

test "block policy fixed runtime owned count-only and reset agree" {
    const P = m.Profile(.{ .policy = .{ .scanner = .block, .syntax = .{ .malformed_reference = .warn } } });
    const source = "<a x='&bad'>text<!--x--><![CDATA[<x>]]>&amp;</a>";
    var owned = P.parseBorrowed(std.testing.allocator, source, m.diagnostic.discard, .{});
    defer owned.deinit();
    try equal(m.Outcome.success, owned.outcome);
    try equal(owned.counts, P.measure(std.testing.allocator, source, m.diagnostic.discard, .{}).counts);
    var scratch: Scratch = .{};
    try equal(owned.counts, P.measureIn(source, scratch.storage(), m.diagnostic.discard, .{}).counts);
    const R = m.Profile(.{ .runtime_policy = true, .policy = .{ .scanner = .block, .execution = .{ .metering = true } } });
    var storage: Storage = .{};
    var session = R.Session.init("<a/>", .{ .document = storage.storage(), .scratch = scratch.storage() }, m.diagnostic.discard, .{ .policy = .{ .scanner = .scalar, .execution = .{ .metering = false } } });
    try std.testing.expectError(error.MeteringDisabled, session.advance(1));
    try equal(m.Outcome.success, session.run().outcome);
    session.reset("long plain text", m.diagnostic.discard, .{});
    while ((try session.advance(1)).outcome == null) {}
    try equal(m.Outcome.success, session.result().?.outcome);
    session.reset("<a/>", m.diagnostic.discard, .{ .policy = m.presets.standard });
    try std.testing.expectError(error.MeteringDisabled, session.advance(1));
    try equal(m.Outcome.success, session.run().outcome);
}

test "block cancellation and diagnostic stop do not scan the remainder" {
    const Stop = struct {
        calls: u32 = 0,
        after: u32,
        fn requested(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return self.calls > self.after;
        }
    };
    const P = m.Profile(.{ .policy = .{ .scanner = .block, .syntax = .{ .malformed_reference = .warn }, .execution = .{ .metering = true, .cancellation = true } } });
    const source = "<a x='&bad'><!--text--><![CDATA[body]]>abcdefghijklmnopqrstuvwxyz&;</a>";
    var succeeded = false;
    for (0..source.len * 12 + 32) |after| {
        var storage: Storage = .{};
        var scratch: Scratch = .{};
        var stop: Stop = .{ .after = @intCast(after) };
        var session = P.Session.init(source, .{ .document = storage.storage(), .scratch = scratch.storage() }, m.diagnostic.discard, .{ .cancellation = .{ .context = &stop, .is_requested = Stop.requested } });
        _ = session.advance(3);
        var moved = session;
        const got = moved.run();
        const calls = stop.calls;
        try deep(got, moved.run());
        try equal(calls, stop.calls);
        if (got.outcome == .success) {
            succeeded = true;
            break;
        }
        try equal(m.Outcome.cancelled, got.outcome);
        try expect(got.document == null);
    }
    try expect(succeeded);
    var no_room: m.FixedDiagnosticBag(0) = .{};
    const got = P.measureIn("&;<!bad", .{}, no_room.sink(), .{});
    try expect(got.outcome == .diagnostic_stopped);
    try equal(@as(u32, 1), got.accepted_deviations);
}
