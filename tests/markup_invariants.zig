//! Safety-build assertion probes, each run in its own process. A completed
//! validation of corrupt metadata is failure, not a supported repair contract.
const std = @import("std");
const markup = @import("markup_parser");
var armed = false;
pub const panic = std.debug.FullPanic(asserted);
fn asserted(_: []const u8, _: ?usize) noreturn {
    std.process.exit(if (armed) 0 else 2);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const case = try std.fmt.parseInt(u8, args[1], 10);
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
