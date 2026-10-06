//! Standalone Graphviz vocabulary, not full Graphviz label validation.
const std = @import("std");
const markup = @import("markup_parser");

pub fn main(init: std.process.Init) !void {
    const Labels = markup.Profile(.{ .policy = blk: {
        var policy = markup.presets.untrusted;
        policy.mode = .graphviz;
        break :blk policy;
    } });
    const source = "<TABLE BORDER=\"0\"><TR><TD PORT=\"p\"><B>Hello</B><BR/>world</TD></TR></TABLE>";
    const allocator = init.arena.allocator();
    var bag = markup.GrowableDiagnosticBag.init(allocator, .{});
    defer bag.deinit();
    var result = try Labels.parseAndValidate(allocator, .{ .bytes = source, .origin = 0 }, bag.sink(), .{});
    defer result.deinit();

    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    try writer.print("Graphviz vocabulary: {s}\n", .{if (result.documentValid()) "valid" else "not accepted"});
    try writer.writeAll("Coverage: tag and attribute names; placement, values and reference catalog are not checked yet.\n");
    const locations = try allocator.alloc(markup.location.Location, try markup.console.locationCapacity(bag.items()));
    defer allocator.free(locations);
    try markup.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "label.markup" }, locations, writer);
    try writer.flush();
    if (!result.documentValid()) return error.VocabularyCheckFailed;
}
