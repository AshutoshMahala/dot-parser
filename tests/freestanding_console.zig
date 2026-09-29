//! Optional shared presentation also works without an OS or an allocator.
const std = @import("std");
const markup = @import("markup_parser");

export fn render_markup(source: [*]const u8, len: u32, output: [*]u8, capacity: u32) u32 {
    var writer = std.Io.Writer.fixed(output[0..capacity]);
    const finding: markup.Diagnostic = .{
        .code = .mismatched_tag,
        .span = .{ .start = len, .len = 0 },
        .related = .{ .start = 0, .len = @min(len, 1) },
    };
    markup.console.renderBoxedList(&.{finding}, 0, .{ .source = source[0..len], .style = .ascii, .verbose = true }, &writer) catch return 0;
    return @intCast(writer.buffered().len);
}
