//! Consumed code-generation probe; no host runtime, allocator or renderer.
const dot = @import("dot_parser");
const features = @import("policy_features");
const Profile = dot.Profile(.{
    .runtime_policy = features.runtime_policy,
    .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } },
});

export fn check_graph(source: [*]const u8, len: usize, choice: u8) usize {
    const input: dot.Policy = .{ .scanner = if (choice & 1 == 0) .scalar else .block, .execution = .{ .metering = choice & 2 != 0, .cancellation = choice & 4 != 0 }, .limits = .{ .max_statements = @as(usize, choice) + 1, .max_attributes = choice }, .recovery = if (choice & 8 == 0) .fail_fast else .statements, .validation = .{
        .graph = .{
            .treated_as = switch (choice % 4) {
                0 => .undigraph,
                1 => .digraph,
                2 => .generic,
                else => .auto,
            },
            .operator_mismatch = if (choice & 4 != 0) switch ((choice >> 4) % 3) {
                0 => .err,
                1 => .warning,
                else => .off,
            } else null,
            .operator_reading = if (choice & 8 != 0) (if (choice & 64 != 0) .conform_to_kind else .as_written) else null,
        },
        .digraph = .{
            .operator_mismatch = switch ((choice >> 4) % 3) {
                0 => .err,
                1 => .warning,
                else => .off,
            },
            .operator_reading = if (choice & 128 != 0) .conform_to_kind else .as_written,
        },
    } };
    if (features.runtime_policy and Profile.validatePolicy(input) != .valid) return 100;
    var storage: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8, .edge_chains = 8, .edge_links = 8 }) = .{};
    var bag: dot.FixedDiagnosticBag(4) = .{};
    const parsed = if (features.runtime_policy)
        Profile.parseBorrowedIn(source[0..len], .{ .document = storage.storage() }, bag.sink(), .{ .policy = input }) catch return 104
    else
        Profile.parseBorrowedIn(source[0..len], .{ .document = storage.storage() }, bag.sink(), .{});
    const doc = &(parsed.document orelse return 101);
    const options: Profile.Options = if (features.runtime_policy) .{ .policy = input } else .{};
    const checked = if (features.runtime_policy)
        Profile.validate(doc, bag.sink(), options) catch return 102
    else
        Profile.validate(doc, bag.sink(), options);
    const view = if (features.runtime_policy)
        Profile.interpretation(doc, options) catch return 103
    else
        Profile.interpretation(doc, options);
    var total: usize = @intFromEnum(doc.effectiveKind(view));
    var edges = doc.edgeIterator();
    while (edges.next()) |edge| total +%= @intFromEnum(edge.effectiveOperator(doc, view));
    return total +% checked.outcome.completed.violations +% checked.outcome.completed.warnings +% bag.items().len;
}

fn cancelled(context: ?*anyopaque) bool {
    const flag: *volatile u8 = @ptrCast(context.?);
    return flag.* != 0;
}

// Exercise runtime variant selection, persistent storage and reset in emitted
// freestanding objects, with genuinely external choices and cancellation input.
export fn session_policy(source: [*]const u8, len: usize, choice: u8, limit: usize, stop: *u8) usize {
    if (!features.runtime_policy) return 0;
    const Dynamic = dot.Profile(.{ .runtime_policy = true });
    var storage: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8, .edge_chains = 8, .edge_links = 8 }) = .{};
    const input: dot.Policy = .{
        .syntax = .{
            .empty_statement = if (choice & 16 == 0) .reject else .warn,
            .long_operator = if (choice & 32 == 0) .reject else .accept,
            .bare_dash = .{ .acceptance = if (choice & 64 == 0) .reject else .warn, .interpretation = .from_keyword },
        },
        .scanner = if (choice & 1 == 0) .scalar else .block,
        .execution = .{ .metering = choice & 2 != 0, .cancellation = choice & 4 != 0 },
        .limits = .{ .max_statements = limit, .max_attributes = limit, .max_nesting = limit },
        .recovery = if (choice & 8 == 0) .fail_fast else .statements,
        .validation = .{ .graph = .{ .treated_as = .auto } },
    };
    var session = Dynamic.Session.init(source[0..len], .{ .document = storage.storage() }, dot.diagnostic.discard, .{ .policy = input, .cancellation = .{ .context = stop, .is_requested = cancelled } }) catch return 100;
    defer session.deinit();
    if (input.execution.metering.?) {
        while ((session.advance(1) catch return 101).outcome == null) {}
    } else _ = session.run();
    const result = session.result().?;
    const count = if (result.document) |doc| doc.statementCount() else 0;
    // Clear overrides: this must start from the compiled defaults again.
    session.reset("graph {}", dot.diagnostic.discard, .{}) catch return 102;
    if (session.run().outcome != .success) return 103;
    return count + result.accepted_deviations + result.warnings + @intFromEnum(session.result().?.document.?.effectiveKind(session.interpretation().?));
}

// Compile and consume a fixed lenient profile on both freestanding targets too.
export fn lenient_graph(source: [*]const u8, len: usize) usize {
    const Lenient = dot.Profile(.{ .policy = dot.presets.lenient });
    var storage: dot.FixedDocumentStorage(.{ .statements = 8, .nodes = 8, .edges = 8, .edge_chains = 8, .edge_links = 8 }) = .{};
    const parsed = Lenient.parseBorrowedIn(source[0..len], .{ .document = storage.storage() }, dot.diagnostic.discard, .{});
    return parsed.accepted_deviations +% parsed.warnings +% (if (parsed.document) |doc| doc.statementCount() else 0);
}
