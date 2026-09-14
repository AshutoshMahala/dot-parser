//! Consumed compile probes, not hardware/runtime or whole-application size tests.
const dot = @import("dot_parser");
const std = @import("std");
const features = @import("execution_features");

fn requested(context: ?*anyopaque) bool {
    // Volatile preserves an external input for code generation. This probe is
    // not a cross-thread/signal adapter and makes no synchronization guarantee.
    const flag: *volatile u8 = @ptrCast(context.?);
    return flag.* != 0;
}

fn consume(comptime metering: bool, comptime cancellation: bool, source: [*]const u8, len: usize, flag: *u8) usize {
    var storage: dot.FixedDocumentStorage(.{ .statements = 8, .subgraphs = 8, .nodes = 8, .edges = 8, .edge_chains = 4, .edge_links = 8, .ported_references = 16, .attributes = 8, .assignments = 8, .attribute_statements = 8 }) = .{};
    var scratch: dot.FixedParseScratch(.{ .nesting = 8 }) = .{};
    const Session = dot.FixedSession(.{ .metering = metering, .cancellation = cancellation });
    var session = Session.init(source[0..len], .{ .document = storage.storage(), .scratch = scratch.storage() }, dot.diagnostic.discard, .{
        .cancellation = if (cancellation) .{ .context = flag, .is_requested = requested } else {},
    });
    defer session.deinit();
    if (metering) {
        while (session.advance(1).outcome == null) {}
    } else {
        _ = session.run();
    }
    const result = session.result().?;
    return @intFromEnum(std.meta.activeTag(result.outcome)) + if (result.document) |doc| doc.statementCount() else @as(usize, 0);
}

export fn parse_session(source: [*]const u8, len: usize, flag: *u8) usize {
    return consume(features.metering, features.cancellation, source, len, flag);
}
