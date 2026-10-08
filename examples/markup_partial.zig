//! Opt-in editor-oriented prefix retention; no inferred closing delimiters.
const std = @import("std");
const markup = @import("markup_parser");

pub fn main(init: std.process.Init) !void {
    const Editor = markup.Profile(.{ .policy = blk: {
        var policy = markup.presets.untrusted;
        policy.mode = .structural;
        policy.retention.partial = true;
        break :blk policy;
    } });
    const source = "<root><done/><child x='known' y='unfinished";
    var bag = markup.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    var parsed = Editor.parseBorrowed(init.gpa, source, bag.sink(), .{});
    defer parsed.deinit();
    const document = parsed.document orelse return error.NoRetainedPrefix;
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    try writer.print("outcome={s}, tree={s}, syntax errors={d}\n", .{ @tagName(parsed.outcome), @tagName(document.state), parsed.syntax_errors });
    // Source-order inspection. Node views also support safe child/root traversal;
    // don't interpret unfinished raw pool intervals as completed subtrees.
    for (0..document.nodeCount()) |index| {
        const node = document.node(@enumFromInt(index)).?;
        try writer.print("  {s}: {s}, observed bytes {d}..{d}\n", .{ node.name() orelse "text", @tagName(node.state()), node.span().start, node.span().endOffset() });
    }
    if (document.unrepresented()) |tail| try writer.print("unrepresented: {s}\n", .{tail.slice(source)});
    try writer.flush();
}
