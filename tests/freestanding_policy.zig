//! Consumed code-generation probe; no host runtime, allocator or renderer.
const dot = @import("dot_parser");
const features = @import("policy_features");
const Profile = dot.Profile(.{
    .runtime_policy = features.runtime_policy,
    .policy = .{ .validation = .{ .graph = .{ .treated_as = .auto } } },
});

export fn check_graph(source: [*]const u8, len: usize, choice: u8) usize {
    const input: dot.Policy = .{ .validation = .{
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
    const parsed = Profile.parseBorrowedIn(source[0..len], .{ .document = storage.storage() }, bag.sink(), .{});
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
