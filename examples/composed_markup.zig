//! One invocation, one diagnostic bag, independent DOT/markup validity.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const Parser = dot.Profile(.{
    .policy = .{ .limits = .{ .max_nesting = 64, .max_statements = 1000, .max_attributes = 1000 } },
    .processors = .{ .markup = markup.Profile(.{ .policy = markup.presets.untrusted }) },
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const source = "digraph { a [label=<<b title='one' title='two'>Hello</b>>]; a -- b; }";
    var bag = Parser.GrowableDiagnosticBag.init(allocator, .{});
    defer bag.deinit();
    var result = try Parser.parseAndValidate(allocator, source, bag.sink(), .{});
    defer result.deinit(allocator);
    var bytes: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &bytes);
    const writer = &output.interface;
    try writer.print("DOT retained={any}, markup checked={d}, combined valid={any}\n", .{ result.dot.document != null, result.markup.visited, result.documentValid() });
    const locations = try allocator.alloc(dot.location.Location, try Parser.console.locationCapacity(bag.items()));
    defer allocator.free(locations);
    try Parser.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "example.dot" }, locations, writer);
    try writer.flush();
}
