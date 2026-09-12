//! Raw spelling and explicit value decoding with caller-owned storage.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "digraph { \"sen\" /* join */ + \"sor\" -> -00.50; }";
    var storage: dot.FixedDocumentStorage(.{ .statements = 1, .edges = 1 }) = .{};
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const parsed = dot.parseBorrowedIn(source, storage.storage(), bag.sink(), .{});
    var stdout_buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &output.interface;
    if (parsed.outcome != .success) {
        try dot.console.renderBoxedList(bag.items(), bag.omitted, .{ .source = source }, writer);
        try writer.flush();
        return;
    }
    const document = &parsed.document.?;
    const edge = document.edges[0];
    var decoded: [16]u8 = undefined;
    try writer.print("raw: {s}\nvalue: {s}\n", .{
        document.text(edge.left),
        try document.decodeIdentifier(edge.left, &decoded),
    });
    try writer.writeAll("numeral value (no conversion): ");
    try document.writeIdentifier(edge.right, writer);
    try writer.writeAll("\n");
    try writer.flush();
}
