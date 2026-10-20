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
