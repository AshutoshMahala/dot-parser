//! Opening-header synchronization rejects the input; it never repairs attributes.
const std = @import("std");
const markup = @import("markup_parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const deep = std.testing.expectEqualDeep;
const discard = markup.diagnostic.discard;

const headers = [_][]const u8{
    "<server port=8080/>",
    "<server port=8080><child/></server>",
    "<server id='s' port=8080/>",
    "<server port '8080'/>",
    "<server port=/>",
    "<server enabled/>",
    "<server a='1'b='2'/>",
    "<server a='1' ?bad/>",
    "<server port=8080 title='a > b / >' other=\"/>'\"/>",
    "<server port=8080 title='>'></server>",
    "<server port=8080 &bad; another=bad/>",
    "<server port=8080\n\t/>",
    "<server port=8080><child x=0/></server>",
};

test "unquoted header value does not hide a later independent reference error" {
    const source = "<config>\n  <server port=8080/>\n  <name>fish & chips</name>\n</config>\n";
    var bag: markup.FixedDiagnosticBag(8) = .{};
    var parsed = markup.parseBorrowed(std.testing.allocator, source, bag.sink(), .{});
    defer parsed.deinit();
    try equal(markup.Outcome.invalid_syntax, parsed.outcome);
    try equal(markup.Completion.complete, parsed.completion);
    try expect(parsed.document == null);
    try equal(@as(u32, 2), parsed.syntax_errors);
    try equal(@as(usize, 2), bag.items().len);
    try equal(markup.diagnostic.Code.unexpected_byte, bag.items()[0].code);
    try equal(markup.diagnostic.Expected.opening_quote, bag.items()[0].details.expected);
    try equal(std.mem.indexOf(u8, source, "8080").?, bag.items()[0].span.start);
    try equal(markup.diagnostic.Code.malformed_reference, bag.items()[1].code);
    try equal(std.mem.indexOfScalar(u8, source, '&').?, bag.items()[1].span.start);
}

test "header recovery preserves actual open and empty boundaries across execution policies" {
    inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| inline for (.{ .fail_fast, .collect }) |recovery| inline for (.{ false, true }) |metered| {
        const p: markup.Policy = .{ .scanner = backend, .on_error = recovery, .execution = .{ .metering = metered } };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{ .on_error = .fail_fast } else p });
        const options: P.Options = if (runtime) .{ .policy = p } else .{};
        for (headers, 0..) |header, index| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "<root>{s}<later>fish & chips</later></root>\n", .{header});
            defer std.testing.allocator.free(source);
            var frames: markup.FixedParseScratch(8) = .{};
            var bag: markup.FixedDiagnosticBag(16) = .{};
            const measured = P.measureIn(source, frames.storage(), bag.sink(), options);
            try equal(markup.Outcome.invalid_syntax, measured.outcome);
            try equal(if (recovery == .collect) markup.Completion.complete else .incomplete, measured.completion);
            const errors: u32 = if (recovery == .fail_fast) 1 else if (index == headers.len - 1) 3 else 2;
            try equal(errors, measured.syntax_errors);
            try equal(@as(usize, errors), bag.items().len);
            try equal(@as(u32, 0), measured.accepted_deviations);
            try equal(markup.diagnostic.Code.unexpected_byte, bag.items()[0].code);
            if (recovery == .collect) try equal(markup.diagnostic.Code.malformed_reference, bag.items()[errors - 1].code);

            var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 8 }) = .{};
            var session_bag: markup.FixedDiagnosticBag(16) = .{};
            var session = P.Session.init(source, .{ .document = nodes.storage(), .scratch = frames.storage() }, session_bag.sink(), options);
            defer session.deinit();
            if (metered) {
                var work: u64 = 0;
                while (session.result() == null) {
                    const progress = if (runtime) try session.advance(1) else session.advance(1);
                    work += progress.work_used;
                    try expect(progress.work_used <= 1);
                    try expect(work <= source.len * 20 + 100);
                    try expect(progress.source_frontier <= source.len);
                }
            } else _ = session.run();
            const result = session.result().?;
            try equal(measured.outcome, result.outcome);
            try equal(measured.completion, result.completion);
            try equal(measured.syntax_errors, result.syntax_errors);
            try deep(measured.counts, result.counts);
            try expect(result.document == null);
            try std.testing.expectEqualSlices(markup.Diagnostic, bag.items(), session_bag.items());
            try deep(result, session.run());
            try deep(result, session.cancel());
            session.reset("<ok/>", discard, .{});
            try equal(markup.Outcome.success, session.run().outcome);
        }
    };
}

test "header recovery stops on ambiguous boundaries without parent EOF cascades" {
    const cases = [_][]const u8{
        "<a x=0",        "<a x=0 q='unfinished", "<a x=0 q=\"unfinished",
        "<a x=0<next/>", "<a x=0 q='<next/>'/>", "<a x=0 / >",
        "<a x=0 //>",    "<a x=0\x00/>",         "<a x=0 q='\x01'/>",
        "<a x=0 /",
        // These never enter header recovery: no known pending opening header,
        // errors within quoted values, malformed close, or malformed slash.
             "<1bad/>",              "<a 1bad='0'/>",
        "<a / >",        "<a x='0'/ >",          "<a x='<next/>'/>",
        "</root junk>",  "<a x='unterminated",
    };
    inline for (.{ .scalar, .block }) |backend| {
        const P = markup.Profile(.{ .policy = .{ .scanner = backend } });
        for (cases) |tail| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "<root>{s}", .{tail});
            defer std.testing.allocator.free(source);
            var bag: markup.FixedDiagnosticBag(16) = .{};
            const result = P.measure(std.testing.allocator, source, bag.sink(), .{});
            try equal(markup.Outcome.invalid_syntax, result.outcome);
            try equal(markup.Completion.incomplete, result.completion);
            try equal(@as(u32, 1), result.syntax_errors);
            try equal(@as(usize, 1), bag.items().len);
            try expect(bag.items()[0].code != .unclosed_element);
        }
    }
}

test "header recovery counts only recognized attributes and retains no document" {
    const source = "<a before='yes' bad=0 after='skipped'><b/></a><c ok='yes'/>";
    var result = markup.parseBorrowed(std.testing.allocator, source, discard, .{});
    defer result.deinit();
    try equal(markup.Outcome.invalid_syntax, result.outcome);
    try equal(markup.Completion.complete, result.completion);
    try equal(@as(u32, 1), result.syntax_errors);
    try equal(markup.Counts{ .nodes = 3, .elements = 3, .attributes = 2, .max_depth = 2 }, result.counts);
    try expect(result.document == null);
    // Strict standalone tokenization continues to latch the original failure.
    var lexer = markup.lexer.Lexer.init(source);
    while (true) switch (lexer.next()) {
        .token => |t| try expect(t.kind != .eof),
        .problem => |p| {
            try equal(markup.diagnostic.Expected.opening_quote, p.diagnostic.details.expected);
            try deep(p, lexer.next().problem);
            break;
        },
    };
}

test "header synchronization preserves earlier reference findings without checking skipped ones" {
    inline for (.{ .reject, .warn, .accept }) |acceptance| {
        const P = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = acceptance } } });
        var bag: markup.FixedDiagnosticBag(8) = .{};
        const r = P.measure(std.testing.allocator, "<a good='&;' bad=0 skipped='&;'/><b>&;</b>", bag.sink(), .{});
        try equal(markup.Outcome.invalid_syntax, r.outcome);
        try equal(markup.Completion.complete, r.completion);
        try equal(@as(u32, if (acceptance == .reject) 3 else 1), r.syntax_errors);
        try equal(@as(u32, if (acceptance == .reject) 0 else 2), r.accepted_deviations);
        try equal(@as(u32, if (acceptance == .warn) 2 else 0), r.warnings);
        try equal(@as(u32, 1), r.counts.attributes);
        try equal(@as(usize, if (acceptance == .accept) 1 else 3), bag.items().len);
    }
}

test "header synchronization respects diagnostic stops before scanning its tail" {
    const P = markup.Profile(.{ .policy = .{ .execution = .{ .metering = true } } });
    const Reject = struct {
        fn emit(_: ?*anyopaque, _: markup.Diagnostic) markup.reporting.SinkError!markup.reporting.Action {
            return error.DiagnosticSinkFailure;
        }
    };
    inline for (.{ false, true }) |reject| {
        var bag: markup.FixedDiagnosticBag(1) = .{};
        var nodes: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
        const sink: markup.DiagnosticSink = if (reject) .{ .context = null, .emit_fn = Reject.emit } else bag.sink();
        var session = P.Session.init("<a x=0" ++ "x" ** 512 ++ "/>", .{ .document = nodes.storage() }, sink, .{});
        defer session.deinit();
        var last: markup.Progress = undefined;
        while (session.result() == null) last = session.advance(1);
        try equal(@as(u32, 6), last.source_frontier);
        const r = session.result().?;
        try equal(if (reject) markup.reporting.StopReason.failure else .requested, r.outcome.diagnostic_stopped);
        try equal(@as(u32, 1), r.syntax_errors);
        try equal(markup.Completion.incomplete, r.completion);
        try equal(@as(u32, 0), session.advance(1).work_used);
    }
}

test "header recovery keeps nesting scratch limits and later parse limits enforced" {
    var node: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    const empty = markup.parseBorrowedIn("<a x=0/>", .{ .document = node.storage() }, discard, .{});
    try equal(markup.Completion.complete, empty.completion); // no nesting scratch
    const open = markup.parseBorrowedIn("<a x=0></a>", .{ .document = node.storage() }, discard, .{});
    try equal(markup.Outcome{ .storage_exhausted = .nesting_frames }, open.outcome);
    try equal(@as(u32, 1), open.syntax_errors);
    try equal(markup.Completion.incomplete, open.completion);
    inline for (.{ .{ "max_nodes", "<a x=0/><b/>" }, .{ "max_attributes", "<a x=0/><b y='1'/>" }, .{ "max_nesting", "<a x=0><b/></a>" } }) |case| {
        const P = markup.Profile(.{ .policy = .{ .limits = limits: {
            var limits: @FieldType(markup.Policy, "limits") = .{};
            @field(limits, case[0]) = if (std.mem.eql(u8, case[0], "max_attributes")) 0 else 1;
            break :limits limits;
        } } });
        const r = P.measure(std.testing.allocator, case[1], discard, .{});
        try expect(r.outcome == .resource_limit);
        try equal(@as(u32, 1), r.syntax_errors);
        try equal(markup.Completion.incomplete, r.completion);
    }
}

test "header recovery cancellation and partitions remain bounded on long tails" {
    const P = markup.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } });
    const Request = struct {
        stop: bool = false,
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.stop;
        }
    };
    const source = "<a x=0 q='" ++ ">" ** 4096 ++ "'/><b/>";
    var request: Request = .{};
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 1 }) = .{};
    var bag: markup.FixedDiagnosticBag(4) = .{};
    var session = P.Session.init(source, .{ .document = nodes.storage() }, bag.sink(), .{ .cancellation = .{ .context = &request, .is_requested = Request.poll } });
    defer session.deinit();
    while (bag.items().len == 0) _ = session.advance(1);
    const mid = session.advance(100);
    try equal(@as(u32, 100), mid.work_used);
    try expect(mid.outcome == null and mid.source_frontier < 200);
    request.stop = true;
    try equal(@as(u32, 0), session.advance(1).work_used);
    try equal(markup.Outcome.cancelled, session.result().?.outcome);
    try equal(@as(u32, 1), session.result().?.syntax_errors);
    var reference_work: ?u64 = null;
    for ([_]u32{ 1, 7, 64, 1024 }) |budget| {
        session.reset(source, discard, .{});
        var total: u64 = 0;
        while (session.result() == null) {
            const p = session.advance(budget);
            try expect(p.work_used <= budget);
            total += p.work_used;
            try expect(total < source.len * 4);
        }
        if (reference_work) |work| try equal(work, total) else reference_work = total;
        try equal(markup.Completion.complete, session.result().?.completion);
        try equal(@as(u32, 2), session.result().?.counts.elements);
    }
}

test "header recovery is invariant across every truncation and block alignment" {
    const body = "<outer><ns:入口 good='x' broken=0 data=\"/>\" extra='>'></ns:入口><ok/></outer>";
    var buffer: [256]u8 = undefined;
    for (0..64) |padding| {
        @memset(buffer[0..padding], ' ');
        @memcpy(buffer[padding..][0..body.len], body);
        const whole = buffer[0 .. padding + body.len];
        const start = if (padding == 0) 0 else whole.len;
        for (start..whole.len + 1) |end| {
            const input = whole[0..end];
            var scalar_bag: markup.FixedDiagnosticBag(16) = .{};
            const expected = markup.measure(std.testing.allocator, input, scalar_bag.sink(), .{});
            inline for (.{ .scalar, .block }) |backend| {
                const P = markup.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .metering = true } } });
                var frames: markup.FixedParseScratch(8) = .{};
                var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 8 }) = .{};
                var bag: markup.FixedDiagnosticBag(16) = .{};
                var session = P.Session.init(input, .{ .document = nodes.storage(), .scratch = frames.storage() }, bag.sink(), .{});
                defer session.deinit();
                var work: u64 = 0;
                while (session.result() == null) {
                    const progress = session.advance(1);
                    work += progress.work_used;
                    try expect(work < input.len * 20 + 100);
                }
                const r = session.result().?;
                try equal(expected.outcome, r.outcome);
                try equal(expected.completion, r.completion);
                try equal(expected.syntax_errors, r.syntax_errors);
                try deep(expected.counts, r.counts);
                try std.testing.expectEqualSlices(markup.Diagnostic, scalar_bag.items(), bag.items());
            }
        }
    }
}

fn allocationRecovery(allocator: std.mem.Allocator) !void {
    const source = "<a x=0>" ** 32 ++ "</a>" ** 32;
    var r = markup.parseBorrowed(allocator, source, discard, .{});
    defer r.deinit();
    if (r.outcome == .out_of_memory) return error.OutOfMemory;
    try equal(markup.Outcome.invalid_syntax, r.outcome);
    try equal(markup.Completion.complete, r.completion);
    try equal(@as(u32, 32), r.syntax_errors);
    try expect(r.document == null);
}

test "allocation failures during recovered header nesting release all scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRecovery, .{});
}
