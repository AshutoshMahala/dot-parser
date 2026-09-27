//! Standalone structural fragments; import only markup_parser.
const std = @import("std");
const markup = @import("markup_parser");

pub fn main(init: std.process.Init) !void {
    const source = "Hello <widget><B>world</B><br/></widget>!";
    var bag = markup.GrowableDiagnosticBag.init(init.arena.allocator(), .{});
    defer bag.deinit();
    var parsed = markup.parseBorrowed(init.arena.allocator(), source, bag.sink(), .{});
    defer parsed.deinit();
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (parsed.document) |doc| {
        try writer.print("{d} nodes, {d} elements, depth {d}\n", .{ parsed.counts.nodes, parsed.counts.elements, parsed.counts.max_depth });
        var roots = doc.roots();
        while (roots.next()) |node| try writer.print("{s}: {s}\n", .{ @tagName(node.kind()), node.raw() });
    } else {
        for (bag.items()) |finding| try writer.print("{s}:{s} at byte {d}\n", .{ markup.diagnostic.namespace, finding.code.structured(), finding.span.start });
        return error.ParseFailed;
    }
    try writer.flush();
}
