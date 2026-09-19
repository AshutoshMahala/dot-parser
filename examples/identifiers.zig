//! Raw spelling and explicit value decoding with caller-owned storage.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source = "digraph { \"sen\" /* join */ + \"sor\" -> -00.50; café -> 東京; }";
    var storage: dot.FixedDocumentStorage(.{ .statements = 2, .edges = 2 }) = .{};
    var bag: dot.FixedDiagnosticBag(1) = .{};
    const parsed = dot.parseBorrowedIn(source, .{ .document = storage.storage() }, bag.sink(), .{});
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
        document.text(document.nodeReference(edge.left).?.identifier),
        try document.decodeIdentifier(document.nodeReference(edge.left).?.identifier, &decoded),
    });
    try writer.writeAll("numeral value (no conversion): ");
    try document.writeIdentifier(document.nodeReference(edge.right).?.identifier, writer);
    try writer.writeAll("\n");
    try writer.writeAll("bare identifiers (bytes preserved): ");
    const bare_edge = document.edges[1];
    try document.writeIdentifier(document.nodeReference(bare_edge.left).?.identifier, writer);
    try writer.writeAll(" -> ");
    try document.writeIdentifier(document.nodeReference(bare_edge.right).?.identifier, writer);
    try writer.writeAll("\n");
    try writer.flush();
}
