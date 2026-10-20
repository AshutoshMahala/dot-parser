//! Consumed readers, including native code units, without allocator or OS.
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const strings = @import("string_processor");

fn checksum(reader: anytype, steps: u32) u32 {
    var result: u32 = 0;
    for (0..steps) |_| switch (reader.step()) {
        .pending => {},
        .scalar => |item| result +%= item.codepoint +% item.location.span.start +% item.location.span.len +% item.location.segment_start,
        .end => return result,
        .failure => |f| return f.location.span.start,
    };
    return result;
}
export fn read_logical(source: [*]const u8, length: u32, origin: u32, actual: u8, kind: u8, steps: u32) u32 {
    const selected: strings.ActualEncoding = switch (actual) {
        0 => .ascii,
        1 => .utf8,
        2 => .utf16le,
        3 => .utf16be,
        4 => .utf32le,
        5 => .utf32be,
        else => return 0,
    };
    const input = strings.Fragment.init(source[0..length], origin) catch return 0;
    switch (selected) {
        inline else => |encoding| switch (kind) {
            0 => {
                var reader = strings.LogicalReader(encoding).init(input) catch return 0;
                return checksum(&reader, steps);
            },
            1 => {
                var reader = dot.identifier.LogicalReader(encoding).init(input) catch return 0;
                return checksum(&reader, steps);
            },
            else => {
                var reader = markup.LogicalReader(encoding).init(input, .{ .references = if (kind == 2) .xml_predefined else .graphviz, .malformed_reference = .accept }) catch return 0;
                return checksum(&reader, steps);
            },
        },
    }
}

export fn validate_logical(source: [*]const u8, length: u32, origin: u32, budget: u32) u32 {
    const P = strings.Profile(.{ .policy = .{ .execution = .{ .metering = true }, .validation = .{
        .equals = .{ .expected = "A&B", .severity = .err },
    } } });
    const R = markup.LogicalReader(.utf8);
    const B = P.WithReader(R);
    const reader = R.init(.{ .bytes = source[0..length], .origin = origin }, .{}) catch return 0;
    var session = B.Session.init(reader, P.Sink.discard, .{}) catch return 0;
    const progress = session.advance(budget);
    return progress.work_used +% progress.source_frontier;
}

export fn validate_markup_strings(source: [*]const u8, length: u32) u32 {
    const P = markup.Profile(.{
        .processors = .{ .string = strings.Profile(.{}) },
        .policy = .{ .mode = .structural, .attributes = .{
            .label = .{ .string = .{ .process = .{ .validation = .{ .equals = .{ .expected = "A&B", .severity = .err } } } } },
        } },
    });
    var storage: markup.FixedDocumentStorage(.{ .nodes = 8, .attributes = 8 }) = .{};
    var scratch: markup.FixedParseScratch(8) = .{};
    var keys: [8]markup.AttributeKeyScratch = undefined;
    const result = P.parseAndValidateIn(.{ .bytes = source[0..length], .origin = 0 }, .{
        .document = storage.storage(),
        .scratch = scratch.storage(),
    }, .{ .attribute_keys = &keys }, P.DiagnosticSink.discard, .{}) catch return 0;
    return result.string.processed +% @intFromBool(result.documentValid());
}
