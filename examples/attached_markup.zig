//! Select label operands now, attach their owned markup results later.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const Editor = dot.Profile(.{
    .policy = .{ .markup = .passthrough, .retention = .{ .partial = true, .markup = true } },
    .processors = .{ .markup = markup.Profile(.{ .policy = .{ .retention = .{ .partial = true } } }) },
});

pub fn main(init: std.process.Init) !void {
    const source = "digraph { a [label=<<B>text</B>>]; b [label=<<I>unfinished>]; }";
    var bag = Editor.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    var result = try Editor.parseAndValidate(init.gpa, source, bag.sink(), .{});
    defer result.deinit(init.gpa); // owns DOT, queue and every attached child
    const document = result.dot.document orelse return error.NoDocument;
    for (document.attributes) |attribute| {
        // This example matches only the literal key spelling "label".
        if (std.mem.eql(u8, document.text(attribute.key), "label"))
            try result.requestMarkup(init.gpa, attribute.value);
    }
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    if (result.state() != .not_processed or !result.scopeComplete()) return error.UnexpectedResult;
    try writer.print("Before: {s}, pending operands={d}\n", .{ @tagName(result.state()), result.pendingMarkup().len });
    try Editor.processPendingMarkup(init.gpa, &result, bag.sink(), .{});
    if (result.state() != .partial or !result.scopeComplete()) return error.UnexpectedResult;
    try writer.print("After: {s}, DOT complete={any}, valid={any}\n", .{ @tagName(result.state()), result.scopeComplete(), result.documentValid() });
    for (result.markupResults() orelse &.{}) |child| {
        try writer.print("  byte {d}: subtree complete={any}\n", .{ child.envelope.start, child.result.subtreeComplete() });
    }
    const locations = try init.gpa.alloc(dot.location.Location, try Editor.console.locationCapacity(bag.items()));
    defer init.gpa.free(locations);
    try Editor.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "example.dot" }, locations, writer);
    try writer.flush();
}
