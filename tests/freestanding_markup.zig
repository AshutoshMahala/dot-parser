//! Consumed independently: no DOT, allocator, renderer, OS or processor registry.
const markup = @import("markup_parser");
const features = @import("policy_features");

export fn partial_markup(source: [*]const u8, len: usize, enabled: bool) u32 {
    const Partial = markup.Profile(.{ .runtime_policy = features.runtime_policy, .policy = .{ .retention = .{ .partial = true } } });
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 16 }) = .{};
    var frames: markup.FixedParseScratch(8) = .{};
    var keys: markup.FixedValidationScratch(16) = .{};
    const options: Partial.Options = if (features.runtime_policy) .{ .policy = .{ .retention = .{ .partial = enabled } } } else .{};
    const parsed = Partial.parseBorrowedIn(source[0..len], .{ .document = nodes.storage(), .scratch = frames.storage() }, markup.diagnostic.discard, options);
    const document = parsed.document orelse return 0;
    var result: u32 = @intFromBool(document.subtreeComplete());
    var roots = document.roots();
    while (roots.next()) |node| result +%= node.span().len +% @intFromBool(node.scopeComplete());
    const checked = Partial.validateIn(&document, keys.storage(), markup.diagnostic.discard, options);
    return result +% @as(u32, @truncate(checked.errors));
}
comptime {
    if (@sizeOf(markup.Diagnostic) != 36) @compileError("review markup diagnostic retention cost");
    if (@sizeOf(markup.Node) != 20 or @sizeOf(markup.Attribute) != 20 or markup.FixedParseScratch(1).byte_size != 12 or markup.FixedValidationScratch(1).byte_size != 8)
        @compileError("review markup retained/scratch layout costs");
}
const P = markup.Profile(.{
    .runtime_policy = features.runtime_policy,
    .policy = .{ .scanner = .block, .syntax = .{ .malformed_reference = .warn }, .validation = .{ .invalid_utf8 = .err, .names = .{ .severity = .err }, .references = .{ .severity = .warning } }, .execution = .{ .metering = true, .cancellation = true } },
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
    var session = P.Session.init(source[0..len], .{ .document = storage.storage(), .scratch = frames.storage() }, markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .on_error = @enumFromInt(limit % 2), .diagnostics = .{ .unsupported = @enumFromInt(limit % 3) }, .limits = .{ .max_nodes = limit }, .syntax = .{ .malformed_reference = @enumFromInt(limit % 3) } }, .cancellation = hook } else .{ .cancellation = hook });
    defer session.deinit();
    while (true) {
        const p = if (features.runtime_policy) session.advance(1) catch return 0 else session.advance(1);
        if (p.outcome != null) break;
    }
    const r = session.result().?;
    if (r.outcome != .success) return r.syntax_errors +% @intFromEnum(r.completion);
    var total = r.counts.nodes +% r.accepted_deviations +% r.warnings;
    var roots = r.document.?.roots();
    while (roots.next()) |node| {
        total +%= node.span().len;
        if (node.content()) |body| total +%= @intCast(body.len);
        var attributes = node.attributes();
        while (attributes.next()) |attribute| total +%= @intCast(attribute.value().len);
    }
    const doc = r.document.?;
    const checked = P.validateIn(&doc, keys.storage(), markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .validation = .{ .duplicate_attribute = .warning, .invalid_utf8 = @enumFromInt(limit % 3), .names = .{ .severity = @enumFromInt(limit % 3) }, .references = .{ .severity = @enumFromInt(limit % 3) } } }, .cancellation = hook } else .{ .cancellation = hook });
    if (checked.completion != .complete) return 0;
    total +%= @truncate(checked.errors +% checked.warnings);
    session.reset("<x/>", markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .execution = .{ .metering = false } } } else .{});
    return total +% session.run().counts.nodes;
}

export fn validate_markup_scopes(source: [*]const u8, len: usize, stop: *u8) u32 {
    var scratch: markup.FixedSourceValidationScratch(8) = .{};
    const options: P.Options = .{ .cancellation = .{ .context = stop, .is_requested = stopped } };
    const checked = P.validateSourceIn(source[0..len], scratch.storage(), markup.diagnostic.discard, options);
    if (checked.completion != .complete) return 0;
    const local = P.validateScopeIn(source[0..len], .{ .bytes = .{ .start = 0, .len = @intCast(len) } }, .{}, markup.diagnostic.discard, options);
    return @truncate(checked.errors +% checked.warnings +% local.errors);
}

export fn check_markup_fragment(source: [*]const u8, len: usize, origin: u32, stop: *u8) u32 {
    var storage: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 16 }) = .{};
    var frames: markup.FixedParseScratch(8) = .{};
    var scratch: markup.FixedSourceValidationScratch(16) = .{};
    const input = markup.Fragment.init(source[0..len], origin) catch return 0;
    const checked = P.parseAndValidateIn(input, .{ .document = storage.storage(), .scratch = frames.storage() }, scratch.storage(), markup.diagnostic.discard, .{ .cancellation = .{ .context = stop, .is_requested = stopped } }) catch return 0;
    return if (checked.documentValid()) checked.parse.counts.nodes else 0;
}

export fn check_graphviz_vocabulary(source: [*]const u8, len: usize, severity: u32) u32 {
    const G = markup.Profile(.{ .runtime_policy = features.runtime_policy, .policy = .{ .mode = .graphviz, .validation = .{ .duplicate_attribute = .off } } });
    const checked = G.validateSourceIn(source[0..len], .{}, markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .validation = .{ .graphviz = .{ .unknown_element = @enumFromInt(severity % 3), .invalid_attribute = @enumFromInt(severity % 3) } } } } else .{});
    return if (checked.completion == .complete) @truncate(checked.errors +% checked.warnings) else 0;
}

export fn parse_graphviz_fragment(source: [*]const u8, len: usize, mode: u32) u32 {
    const G = markup.Profile(.{ .runtime_policy = features.runtime_policy, .policy = .{ .mode = .graphviz } });
    var nodes: markup.FixedDocumentStorage(.{ .nodes = 16, .attributes = 16 }) = .{};
    var frames: markup.FixedParseScratch(8) = .{};
    const parsed = G.parseBorrowedIn(source[0..len], .{ .document = nodes.storage(), .scratch = frames.storage() }, markup.diagnostic.discard, if (features.runtime_policy) .{ .policy = .{ .mode = @enumFromInt(mode % 2) } } else .{});
    return if (parsed.outcome == .success) parsed.counts.nodes else 0;
}
