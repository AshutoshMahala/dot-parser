const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");

// One-credit execution is the oracle. Compare every pause, not merely the final
// tree: batching must not hide lookahead, diagnostics or output behind a yield.
fn compare(comptime api: type, comptime runtime: bool, comptime block: bool, source: []const u8, budgets: []const u32) !void {
    const is_markup = api == markup;
    comptime var policy: api.Policy = .{ .scanner = if (block) .block else .scalar, .execution = .{ .metering = true } };
    if (is_markup) policy.mode = .structural;
    const P = api.Profile(.{ .policy = policy, .runtime_policy = runtime });
    const Storage = if (is_markup) api.FixedDocumentStorage(.{ .nodes = 32, .attributes = 32 }) else api.FixedDocumentStorage(.{ .statements = 32, .nodes = 32, .attributes = 32 });
    const Scratch = if (is_markup) api.FixedParseScratch(8) else api.FixedParseScratch(.{ .nesting = 8 });
    var a_storage: Storage = .{};
    var b_storage: Storage = .{};
    var a_scratch: Scratch = .{};
    var b_scratch: Scratch = .{};
    var a_bag: api.FixedDiagnosticBag(32) = .{};
    var b_bag: api.FixedDiagnosticBag(32) = .{};
    const a_init = P.Session.init(source, .{ .document = a_storage.storage(), .scratch = a_scratch.storage() }, a_bag.sink(), .{});
    const b_init = P.Session.init(source, .{ .document = b_storage.storage(), .scratch = b_scratch.storage() }, b_bag.sink(), .{});
    var a = if (runtime) try a_init else a_init;
    var b = if (runtime) try b_init else b_init;
    defer a.deinit();
    defer b.deinit();
    for (0..16 * source.len + 128) |turn| {
        const budget = budgets[turn % budgets.len];
        const actual = b.advance(budget);
        const got = if (runtime) try actual else actual;
        const zero = a.advance(0);
        var expected = if (runtime) try zero else zero;
        var used: @TypeOf(got.work_used) = 0;
        for (0..budget) |_| {
            if (expected.outcome != null) break;
            const step = a.advance(1);
            expected = if (runtime) try step else step;
            used += expected.work_used;
        }
        expected.work_used = used;
        try std.testing.expectEqualDeep(expected, got);
        try std.testing.expectEqualDeep(a_bag.items(), b_bag.items());
        if (got.outcome != null) {
            try std.testing.expectEqualDeep(a.result(), b.result());
            return;
        }
    }
    return error.DidNotFinish;
}

test "bounded runs preserve every public pause across quote text and reference boundaries" {
    inline for (.{ dot, markup }) |api| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |block| {
        for ([_][]const u8{ "plain", "Straße 中文 😀", "\"", "\\", "&amp;", "&bogus", "<", "\x00", "\x01", "\xff" }) |insert| {
            for ([_]usize{ 0, 1, 14, 15, 16, 17, 31, 32, 63, 64, 65 }) |offset| {
                var bytes: [512]u8 = undefined;
                const open = if (api == markup) "<a>" else "graph{a[x=\"";
                const close = if (api == markup) "</a><b/>" else "\"];b;}";
                const tail = "z" ** 80;
                @memcpy(bytes[0..open.len], open);
                @memset(bytes[open.len..][0..offset], 'a');
                @memcpy(bytes[open.len + offset ..][0..insert.len], insert);
                const at = open.len + offset + insert.len;
                @memcpy(bytes[at..][0..tail.len], tail);
                @memcpy(bytes[at + tail.len ..][0..close.len], close);
                const source = bytes[0 .. at + tail.len + close.len];
                try compare(api, runtime, block, source, &.{ 0, 1, 15, 16, 17, 31, 64, 65, 4096 });
                try compare(api, runtime, block, source, &.{64});
                try compare(api, runtime, block, source[0..at], &.{17});
            }
        }
    };
}

test "bounded text runs stop at the original cancellation boundary" {
    @setEvalBranchQuota(10_000);
    const Request = struct {
        polls: u32 = 0,
        stop_after: u32,
        fn poll(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const stop = self.polls == self.stop_after;
            self.polls += 1;
            return stop;
        }
    };
    inline for (.{ dot, markup }) |api| inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |block| inline for (.{ 1, 17, 64 }) |interval| {
        comptime var policy: api.Policy = .{ .scanner = if (block) .block else .scalar, .execution = .{
            .metering = true,
            .cancellation = true,
            .cancellation_interval = interval,
        } };
        if (api == markup) policy.mode = .structural;
        const P = api.Profile(.{ .policy = policy, .runtime_policy = runtime });
        const Storage = if (api == markup) api.FixedDocumentStorage(.{ .nodes = 32, .attributes = 32 }) else api.FixedDocumentStorage(.{ .statements = 32, .nodes = 32, .attributes = 32 });
        const Scratch = if (api == markup) api.FixedParseScratch(8) else api.FixedParseScratch(.{ .nesting = 8 });
        const source = if (api == markup) "<a>" ++ "x" ** 100 ++ "&amp;" ++ "z" ** 256 ++ "</a>" else "graph{a[x=\"" ++ "x" ** 100 ++ "\\\"" ++ "z" ** 256 ++ "\"];}";
        for (1..5) |stop| {
            var a_storage: Storage = .{};
            var b_storage: Storage = .{};
            var a_scratch: Scratch = .{};
            var b_scratch: Scratch = .{};
            var a_bag: api.FixedDiagnosticBag(32) = .{};
            var b_bag: api.FixedDiagnosticBag(32) = .{};
            var request: Request = .{ .stop_after = @intCast(stop) };
            const a_init = P.Session.init(source, .{ .document = a_storage.storage(), .scratch = a_scratch.storage() }, a_bag.sink(), .{});
            const b_init = P.Session.init(source, .{ .document = b_storage.storage(), .scratch = b_scratch.storage() }, b_bag.sink(), .{ .cancellation = .{ .context = &request, .is_requested = Request.poll } });
            var a = if (runtime) try a_init else a_init;
            var b = if (runtime) try b_init else b_init;
            defer a.deinit();
            defer b.deinit();
            const paused = a.advance(@intCast(stop * interval));
            const expected = if (runtime) try paused else paused;
            _ = a.cancel();
            const running = b.advance(std.math.maxInt(u32));
            const actual = if (runtime) try running else running;
            try std.testing.expectEqual(expected.work_used, actual.work_used);
            try std.testing.expectEqual(expected.source_frontier, actual.source_frontier);
            try std.testing.expectEqualDeep(a.result(), b.result());
            try std.testing.expectEqualDeep(a_bag.items(), b_bag.items());
            if (expected.outcome == null) try std.testing.expectEqual(stop + 1, request.polls);
        }
    };
}
