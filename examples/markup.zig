//! Standalone structural fragments; import only markup_parser.
const std = @import("std");
const markup = @import("markup_parser");

pub fn main(init: std.process.Init) !void {
    const source = "Hello &amp; <widget name='demo' name=\"retained too\"><B>world</B><br/></widget><!-- retained --><![CDATA[<raw>&text]]>!";
    var bag = markup.GrowableDiagnosticBag.init(init.arena.allocator(), .{});
    defer bag.deinit();
    var parsed = markup.parseBorrowed(init.arena.allocator(), source, bag.sink(), .{});
    defer parsed.deinit();
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (parsed.document) |doc| {
        try writer.print("{d} nodes, {d} elements, {d} attributes, depth {d}\n", .{ parsed.counts.nodes, parsed.counts.elements, parsed.counts.attributes, parsed.counts.max_depth });
        var roots = doc.roots();
        while (roots.next()) |node| {
            try writer.print("{s}: {s}\n", .{ @tagName(node.kind()), node.raw() });
            var attributes = node.attributes();
            while (attributes.next()) |attribute| try writer.print("  {s} = {s}\n", .{ attribute.name(), attribute.rawValue() });
        }
        // Parsing retains every occurrence; later validation leaves that tree intact.
        const checked = markup.validate(init.arena.allocator(), &doc, bag.sink(), .{});
        try writer.print("validation {s}: {d} errors, {d} warnings\n", .{ @tagName(checked.validity), checked.errors, checked.warnings });
        if (checked.completion != .complete) return error.ValidationIncomplete;
        for (bag.items()) |finding| try writer.print("{s}:{s} at byte {d}\n", .{ markup.diagnostic.namespace, finding.code.structured(), finding.span.start });
    } else {
        for (bag.items()) |finding| try writer.print("{s}:{s} at byte {d}\n", .{ markup.diagnostic.namespace, finding.code.structured(), finding.span.start });
        return error.ParseFailed;
    }
    try writer.flush();
}
