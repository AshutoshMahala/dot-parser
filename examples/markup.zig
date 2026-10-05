//! Standalone structural fragments; import only markup_parser.
const std = @import("std");
const markup = @import("markup_parser");

pub fn main(init: std.process.Init) !void {
    const source = "Hello &amp; <widget name='demo' name=\"retained too\"><B>world</B><br/></widget><!-- retained --><![CDATA[<raw>&text]]>!";
    // This profile bounds parsing; the default bag independently caps findings at 1024.
    // Bound input acquisition before parsing too; this example uses a fixed string.
    const Reader = markup.Profile(.{ .policy = markup.presets.untrusted });
    var bag = markup.GrowableDiagnosticBag.init(init.arena.allocator(), .{});
    defer bag.deinit();
    var parsed = Reader.parseBorrowed(init.arena.allocator(), source, bag.sink(), .{});
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
        // UTF-8 is opt-in and checks the entire source, including comments/CDATA.
        // Name rules and reference catalogs are independent of structural syntax.
        const Checked = markup.Profile(.{ .policy = .{ .validation = .{
            .invalid_utf8 = .err,
            .names = .{ .rule = .xml_1_0, .severity = .err },
            .references = .{ .catalog = .xml_predefined, .severity = .warning },
        } } });
        const checked = Checked.validate(init.arena.allocator(), &doc, bag.sink(), .{});
        try writer.print("validation {s}: {d} errors, {d} warnings\n", .{ @tagName(checked.validity), checked.errors, checked.warnings });
        if (checked.completion != .complete) return error.ValidationIncomplete;
        const locations = try init.arena.allocator().alloc(markup.location.Location, try markup.console.locationCapacity(bag.items()));
        defer init.arena.allocator().free(locations);
        try markup.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "example.markup" }, locations, writer);
    } else {
        const locations = try init.arena.allocator().alloc(markup.location.Location, try markup.console.locationCapacity(bag.items()));
        defer init.arena.allocator().free(locations);
        try markup.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "example.markup" }, locations, writer);
        try writer.flush();
        return error.ParseFailed;
    }
    try writer.flush();
}
