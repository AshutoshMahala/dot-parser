//! Opt-in, borrowed DOT comment records. No comment processor is involved.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const Parser = dot.Profile(.{ .policy = .{
        .retention = .{ .comments = true },
        .limits = .{ .max_comments = 1000 },
    } });
    const source = "// file note\ngraph { a /* link note */ -- b; } # end\n";
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    var parsed = Parser.parseAndValidate(init.gpa, source, bag.sink(), .{});
    defer parsed.deinit(init.gpa);
    if (!parsed.documentValid()) return error.InvalidDocument;
    const document = &parsed.document.?;
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    var positions: dot.location.PositionCursor = .{};
    for (document.comments.?) |comment| {
        const at = positions.locate(source, comment.span.start);
        try output.interface.print("{s} at {d}:{d}: {s}\n", .{ @tagName(comment.kind), at.line, at.byte_column, comment.body(source) });
    }
    try output.interface.flush();
}
