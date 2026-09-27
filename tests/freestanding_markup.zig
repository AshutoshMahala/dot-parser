//! Consumed independently: no DOT, allocator, renderer, OS or processor registry.
const markup = @import("markup_parser");
const features = @import("policy_features");
comptime {
    if (@sizeOf(markup.Node) != 20 or @sizeOf(markup.Attribute) != 20 or markup.FixedParseScratch(1).byte_size != 12 or markup.FixedValidationScratch(1).byte_size != 8)
        @compileError("review markup retained/scratch layout costs");
}
const P = markup.Profile(.{
    .runtime_policy = features.runtime_policy,
    .policy = .{ .execution = .{ .metering = true, .cancellation = true } },
});
fn stopped(context: ?*anyopaque) bool {
    const flag: *volatile u8 = @ptrCast(context.?);
    return flag.* != 0;
}
export fn parse_markup(source: [*]const u8, len: usize, limit: u32, stop: *u8) u32 {
    var storage: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 32 }) = .{};
    var frames: markup.FixedParseScratch(8) = .{};
    var keys: markup.FixedValidationScratch(32) = .{};
    const hook: markup.Cancellation = .{ .context = stop, .is_requested = stopped };
    var session = P.Session.init(source[0..len], .{ .document = storage.storage(), .scratch = frames.storage() }, markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .limits = .{ .max_nodes = limit } }, .cancellation = hook } else .{ .cancellation = hook });
    defer session.deinit();
    while (true) {
        const p = if (features.runtime_policy) session.advance(1) catch return 0 else session.advance(1);
        if (p.outcome != null) break;
    }
    const r = session.result().?;
    if (r.outcome != .success) return 0;
    var total = r.counts.nodes;
    var roots = r.document.?.roots();
    while (roots.next()) |node| {
        total +%= node.span().len;
        var attributes = node.attributes();
        while (attributes.next()) |attribute| total +%= @intCast(attribute.value().len);
    }
    const doc = r.document.?;
    const checked = P.validateIn(&doc, keys.storage(), markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .validation = .{ .duplicate_attribute = .warning } }, .cancellation = hook } else .{ .cancellation = hook });
    if (checked.completion != .complete) return 0;
    total +%= checked.errors +% checked.warnings;
    session.reset("<x/>", markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .execution = .{ .metering = false } } } else .{});
    return total +% session.run().counts.nodes;
}
