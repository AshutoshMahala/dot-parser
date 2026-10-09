//! Independent DOT/markup prefix retention for an editor; one diagnostic bag.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");
const Editor = dot.Profile(.{
    .policy = .{
        .retention = .{ .partial = true, .markup = true },
        .limits = .{ .max_nesting = 64, .max_statements = 1000, .max_attributes = 1000 },
    },
    .processors = .{ .markup = markup.Profile(.{ .policy = blk: {
        var policy = markup.presets.untrusted;
        policy.retention.partial = true;
        break :blk policy;
    } }) },
});

pub fn main(init: std.process.Init) !void {
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    for ([_][]const u8{
        "digraph { a [label=<<B><I>text</I></wrong>>]; }",
        "digraph { a [label=<<B>text</B>>]; subgraph unfinished { b;",
    }) |source| {
        var bag = Editor.GrowableDiagnosticBag.init(init.gpa, .{});
        defer bag.deinit();
        var result = try Editor.parseAndValidate(init.gpa, source, bag.sink(), .{});
        defer result.deinit(init.gpa);
        try writer.print("DOT complete={any}, subtree complete={any}, valid={any}\n", .{ result.scopeComplete(), result.subtreeComplete(), result.documentValid() });
        if (result.dot.document) |*document| {
            var subgraphs = document.subgraphs();
            while (subgraphs.next()) |scope| {
                try writer.print("  scope {s}: {s}\n", .{ if (scope.name()) |name| document.text(name) else "anonymous", @tagName(scope.state()) });
            }
        }
        for (result.markupResults() orelse &.{}) |child| {
            try writer.print("  label at byte {d}: complete={any}\n", .{ child.envelope.start, child.result.subtreeComplete() });
            if (child.result.parse.document) |document| {
                for (0..document.nodeCount()) |index| {
                    const node = document.node(@enumFromInt(index)).?;
                    try writer.print("    {s}: {s}\n", .{ node.name() orelse "text", @tagName(node.state()) });
                }
            }
        }
    }
    try writer.flush();
}
