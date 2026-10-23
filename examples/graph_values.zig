//! Preserve a value's spelling, print its joined contents, or visit each operand.
const std = @import("std");
const dot = @import("dot_parser");

pub fn main(init: std.process.Init) !void {
    const source =
        \\digraph {
        \\    a [label="first " + "second"];
        \\    b [label=<<b><i>bee</i></b>>];
        \\}
    ;
    var bag = dot.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();

    const printed = printValues(init.gpa, source, bag.sink());
    try dot.console.printDiagnostics(init.io, bag.items(), .{ .source = source });
    return printed;
}

fn printValues(gpa: std.mem.Allocator, source: []const u8, sink: dot.DiagnosticSink) !void {
    var result = try dot.ir.parse(gpa, source, .{ .diagnostics = sink });
    defer result.deinit();
    const ir = result.ir() orelse return error.GraphUnavailable;

    var nodes = ir.nodeIterator();
    while (nodes.next()) |node| {
        const label = node.attribute("label") orelse continue;
        const value = label.value();
        // raw() is the original spelling, in the source's encoding (UTF-8 here).
        std.debug.print("kind: {t}\nraw: {s}\njoined: {f}\n", .{
            value.kind(), value.raw() orelse "(implicit empty)", value,
        });
        var parts = value.parts();
        while (parts.next()) |part|
            std.debug.print("{t} operand: \"{f}\"\n", .{ part.kind(), part });
    }
}

// Output:
// kind: concatenation
// raw: "first " + "second"
// joined: first second
// string operand: "first "
// string operand: "second"
// kind: markup
// raw: <<b><i>bee</i></b>>
// joined: <b><i>bee</i></b>
// markup operand: "<b><i>bee</i></b>"
