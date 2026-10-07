const std = @import("std");
const markup = @import("markup_parser");
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

const inputs = [_][]const u8{
    "<a x='1' y='2'><b/>text</a>",
    "<a x='1' x='2'><b></wrong>",
    "<a x=1/><b y='1' y='2'/>",
    "<?pi?>",
    "<a x='1' x='2'/><!DOCTYPE x>",
    "<a><b><c/></b></a>",
    "<1bad a='&bogus;'/>\xff",
    "<a a='0' b='1' c='2' d='3' e='4' f='5' g='6' h='7' i='8' a='9'/>",
    "<a a='0' b='1' c='2' d='3' e='4' f='5' g='6' h='7' i='8' a='9'></bad>",
    "<a x='unterminated",
    "<!--comment--><![CDATA[text]]>",
    "",
};

test "all fragment storage paths agree across resets origins backends and policy variants" {
    inline for (.{ .scalar, .block }) |scanner| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |controlled| inline for (.{ .collect, .fail_fast }) |on_error| {
        const patch: markup.Policy = .{
            .mode = .structural,
            .scanner = scanner,
            .on_error = on_error,
            .execution = .{ .cancellation = controlled },
            .diagnostics = .{ .unsupported = .silent },
            .validation = .{ .invalid_utf8 = .err },
        };
        const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{
            .mode = .structural,
        } else patch });
        const ready = P.prepare(if (runtime) .{ .policy = patch } else .{});
        var workspace = ready.initWorkspace(gpa, .{});
        defer workspace.deinit();
        var storage: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 16 }) = .{};
        var frames: markup.FixedParseScratch(8) = .{};
        var scratch: markup.FixedSourceValidationScratch(16) = .{};
        for (0..2) |_| for (inputs, 0..) |bytes, index| {
            const fragment = try markup.Fragment.init(bytes, @intCast(31 * index));
            var expected_bag: markup.FixedDiagnosticBag(64) = .{};
            var actual_bag: markup.FixedDiagnosticBag(64) = .{};
            var fixed_bag: markup.FixedDiagnosticBag(64) = .{};
            var owned = try ready.parseAndValidate(gpa, fragment, expected_bag.sink(), .{});
            defer owned.deinit();
            const reused = try workspace.parseAndValidate(fragment, actual_bag.sink());
            const fixed = try ready.parseAndValidateIn(fragment, .{ .document = storage.storage(), .scratch = frames.storage() }, scratch.storage(), fixed_bag.sink());
            try std.testing.expectEqualDeep(fixed, reused);
            try std.testing.expectEqualDeep(expected_bag.items(), fixed_bag.items());
            inline for (@typeInfo(markup.FixedParseResult).@"struct".fields) |field| {
                try std.testing.expectEqualDeep(@field(owned.parse, field.name), @field(reused.parse, field.name));
            }
            try std.testing.expectEqualDeep(owned.validation, reused.validation);
            try equal(owned.has_errors, reused.has_errors);
            try equal(owned.documentValid(), reused.documentValid());
            try equal(owned.stopped(), reused.stopped());
            try std.testing.expectEqualDeep(expected_bag.items(), actual_bag.items());
        };
    };
}

test "warm workspace makes no allocator calls for repeated trees or source fallback" {
    var tracked = std.testing.FailingAllocator.init(gpa, .{});
    var nesting = std.testing.FailingAllocator.init(gpa, .{});
    const P = markup.Profile(.{ .policy = .{ .mode = .structural } });
    var workspace = P.prepare(.{}).initWorkspace(tracked.allocator(), .{ .scratch_allocator = nesting.allocator() });
    try equal(@as(usize, 0), tracked.allocated_bytes + nesting.allocated_bytes);
    try equal(@as(usize, 0), workspace.reservedBytes());
    for (inputs) |bytes| _ = try workspace.parseAndValidate(.{ .bytes = bytes, .origin = 0 }, markup.diagnostic.discard);
    const reserved = workspace.reservedBytes();
    try expect(reserved != 0 and nesting.allocated_bytes != 0);
    try equal(reserved, tracked.allocated_bytes - tracked.freed_bytes + nesting.allocated_bytes - nesting.freed_bytes);
    // Any alloc/remap/resize attempted after warmup must fail. Repeated work
    // must still succeed or reject exactly as its input, never exhaust storage.
    tracked.fail_index = tracked.alloc_index;
    tracked.resize_fail_index = tracked.resize_index;
    nesting.fail_index = nesting.alloc_index;
    nesting.resize_fail_index = nesting.resize_index;
    for (0..100) |_| for (inputs) |bytes| {
        const result = try workspace.parseAndValidate(.{ .bytes = bytes, .origin = 0 }, markup.diagnostic.discard);
        try expect(!result.stopped());
        try equal(reserved, workspace.reservedBytes());
    };
    try expect(!tracked.has_induced_failure and !nesting.has_induced_failure);
    workspace.deinit();
    try equal(tracked.allocated_bytes, tracked.freed_bytes);
    try equal(nesting.allocated_bytes, nesting.freed_bytes);
}

test "workspace resets after sink stop cancellation and local limits" {
    const Cancellation = struct {
        stop: bool = false,
        fn poll(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.stop;
        }
    };
    const P = markup.Profile(.{ .policy = .{ .mode = .structural, .execution = .{ .cancellation = true }, .limits = .{ .max_nodes = 2 } } });
    var cancellation: Cancellation = .{};
    var workspace = P.prepare(.{ .cancellation = .{ .context = &cancellation, .is_requested = Cancellation.poll } }).initWorkspace(gpa, .{});
    defer workspace.deinit();
    var bag: markup.FixedDiagnosticBag(0) = .{};
    const stopped = try workspace.parseAndValidate(.{ .bytes = "<a></b>", .origin = 0 }, bag.sink());
    try expect(stopped.stopped());
    cancellation.stop = true;
    const cancelled = try workspace.parseAndValidate(.{ .bytes = "<a/>", .origin = 0 }, markup.diagnostic.discard);
    try equal(markup.Outcome.cancelled, cancelled.parse.outcome);
    cancellation.stop = false;
    const limited = try workspace.parseAndValidate(.{ .bytes = "<a><b/><c/></a>", .origin = 0 }, markup.diagnostic.discard);
    try expect(limited.parse.outcome == .resource_limit);
    const valid = try workspace.parseAndValidate(.{ .bytes = "<ok/>", .origin = 0 }, markup.diagnostic.discard);
    try expect(valid.documentValid());
    try equal(@as(u32, 1), valid.parse.counts.nodes);
    try equal(@as(u32, 0), valid.parse.syntax_errors);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const P = markup.Profile(.{ .policy = .{ .mode = .structural } });
    var workspace = P.prepare(.{}).initWorkspace(allocator, .{});
    defer workspace.deinit();
    for (inputs) |bytes| {
        const result = try workspace.parseAndValidate(.{ .bytes = bytes, .origin = 0 }, markup.diagnostic.discard);
        if (result.stopped()) return error.OutOfMemory;
    }
}

test "all workspace growth failures release retained buffers exactly once" {
    try std.testing.checkAllAllocationFailures(gpa, allocationCase, .{});
}

test "a reusable workspace survives failed growth and rejects bad origins before processing" {
    var tracked = std.testing.FailingAllocator.init(gpa, .{});
    const P = markup.Profile(.{ .policy = .{ .mode = .structural } });
    var workspace = P.prepare(.{}).initWorkspace(tracked.allocator(), .{});
    defer workspace.deinit();
    const first = try workspace.parseAndValidate(.{ .bytes = "<a/>", .origin = 0 }, markup.diagnostic.discard);
    try expect(first.documentValid());
    const reserved = workspace.reservedBytes();
    tracked.fail_index = tracked.alloc_index;
    tracked.resize_fail_index = tracked.resize_index;
    const failed = try workspace.parseAndValidate(.{ .bytes = "<b/>" ** 100, .origin = 0 }, markup.diagnostic.discard);
    try expect(failed.stopped() and failed.parse.document == null);
    try equal(reserved, workspace.reservedBytes());
    var bag: markup.FixedDiagnosticBag(8) = .{};
    try std.testing.expectError(error.InvalidFragment, workspace.parseAndValidate(.{ .bytes = "<a/>", .origin = std.math.maxInt(u32) }, bag.sink()));
    try equal(@as(usize, 0), bag.items().len);
    // Kept capacity is still usable even though new allocations remain forbidden.
    const next = try workspace.parseAndValidate(.{ .bytes = "<c/>", .origin = 71 }, bag.sink());
    try expect(next.documentValid());
    try equal(@as(u32, 1), next.parse.counts.nodes);
    try equal(reserved, workspace.reservedBytes());
}
