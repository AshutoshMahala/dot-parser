//! Safety-build assertion probes, each run in its own process. A completed
//! validation/traversal of the selected corrupt metadata is failure, not repair.
const std = @import("std");
const markup = @import("markup_parser");
var armed = false;
pub const panic = std.debug.FullPanic(asserted);
fn asserted(message: []const u8, _: ?usize) noreturn {
    // An out-of-bounds panic is not evidence that the precondition caught it.
    std.process.exit(if (armed and std.mem.eql(u8, message, "reached unreachable code")) 0 else 2);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const case = try std.fmt.parseInt(u8, args[1], 10);
    if (case >= 5) {
        var nodes = [_]markup.Node{
            .{ .span = .{ .start = 0, .len = 15 }, .name = .{ .start = 1, .len = 1 }, .subtree_end = 3 },
            .{ .span = .{ .start = 3, .len = 8 }, .name = .{ .start = 4, .len = 1 }, .subtree_end = 3 },
            .{ .span = .{ .start = 6, .len = 1 }, .name = .{ .start = @intFromEnum(markup.NodeKind.text), .len = 0 }, .subtree_end = 3 },
        };
        const document: markup.Document = .{ .source = "<a><b>x</b></a>", .records = &nodes, .attributes = &.{} };
        switch (case) {
            5 => nodes[0].subtree_end = 2, // child escapes its parent's interval
            6 => nodes[1].subtree_end = 1, // non-advancing iterator
            7 => nodes[0].subtree_end = 4, // end outside the pool
            else => return error.UnknownCase,
        }
        var children = document.node(@enumFromInt(0)).?.children();
        armed = true;
        _ = children.next(); // Must assert on the first step, not a later OOB read.
        std.process.exit(1);
    }
    const P = markup.Profile(.{ .policy = .{ .validation = .{
        .duplicate_attribute = .off,
        .names = .{ .severity = .err },
        .references = .{ .severity = .err },
    } } });
    var output: markup.FixedDocumentStorage(.{ .nodes = 2, .attributes = 2 }) = .{};
    var frames: markup.FixedParseScratch(2) = .{};
    const parsed = P.parseBorrowedIn("<a x='&bad;'><\xff y='&worse;'/></a>", .{ .document = output.storage(), .scratch = frames.storage() }, markup.diagnostic.discard, .{});
    const document = parsed.document orelse return error.ParseFailed;
    if (P.validateIn(&document, .{}, markup.diagnostic.discard, .{}).errors != 3) return error.ValidationFailed;
    switch (case) {
        0 => std.mem.swap(markup.Attribute, &output.attributes[0], &output.attributes[1]),
        1 => output.attributes[0].value.len = 1,
        2 => output.nodes[1].name = .{ .start = 5, .len = 0 },
        3 => output.nodes[1].span.len = std.math.maxInt(u32),
        4 => output.attributes[1].owner = @enumFromInt(99),
        else => return error.UnknownCase,
    }
    armed = true;
    _ = P.validateIn(&document, .{}, markup.diagnostic.discard, .{});
    std.process.exit(1);
}
