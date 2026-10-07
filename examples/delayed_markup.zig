//! Explicit delayed selection: no markup dependency in ordinary DOT parsing.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const source = "digraph { a [label=<<FONT COLOR='red' COLOR='blue'>Hello</FONT>> + \" literal \" + <<i>world</i>>]; }";
    const outer_on_error: dot.OnError = .collect;
    const Outer = dot.Profile(.{ .policy = .{ .on_error = outer_on_error, .limits = .{ .max_nesting = 64, .max_statements = 1000, .max_attributes = 1000 } } });
    const Inner = markup.Profile(.{ .policy = markup.presets.untrusted });
    var outer_bag = dot.GrowableDiagnosticBag.init(allocator, .{});
    defer outer_bag.deinit();
    var outer = Outer.parseAndValidate(allocator, source, outer_bag.sink(), .{});
    defer outer.deinit(allocator);
    // A retained outer document can have validation findings. Operational stops
    // must not start more work in this requested operation.
    if (outer.outcome != .success or outer.validation == null) return error.OuterStopped;
    switch (outer.validation.?.outcome) {
        .completed => {},
        else => return error.OuterStopped,
    }
    const document = &outer.document.?;
    var bag = markup.GrowableDiagnosticBag.init(allocator, .{});
    defer bag.deinit();
    const ready = Inner.prepare(.{}); // reuse for every selected operand
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    var halted = false;
    // Application selection, not a library rule: process only literal `label`
    // keys in this example. No case folding or decoded-key matching is implied.
    for (document.attributes) |attribute| {
        if (!std.mem.eql(u8, document.text(attribute.key), "label")) continue;
        var operands = try dot.identifier.parts(source, attribute.value);
        while (operands.next()) |part| {
            if (part.form != .html) continue;
            var checked = try ready.parseAndValidate(allocator, try part.fragment(source), bag.sink(), .{});
            defer checked.deinit();
            try writer.print("operand at byte {d}: valid={any}, nodes={d}\n", .{ part.raw.start, checked.documentValid(), checked.parse.counts.nodes });
            // Parent policy applies after this complete child invocation. Its
            // own fail-fast/collect setting never overrides the child's setting.
            if (checked.shouldStop(outer_on_error)) {
                halted = true;
                break;
            }
            // Ordinary findings do not prevent checking the next operand.
        }
        if (halted) break;
    }
    const locations = try allocator.alloc(markup.location.Location, try markup.console.locationCapacity(bag.items()));
    defer allocator.free(locations);
    // All primary/related/fix spans refer to the original DOT file.
    try markup.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "example.dot" }, locations, writer);
    try writer.flush();
    if (halted) return error.InnerStopped;
}
