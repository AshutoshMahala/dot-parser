//! Consumed lowering/query/materialization with an explicit fixed-buffer
//! allocator: no libc, OS, global allocator, recursion, or renderer required.
const std = @import("std");
const dot = @import("dot_parser");
export fn topology(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    const a = fixed.allocator();
    var parsed = dot.parseAndValidate(a, source[0..length], dot.diagnostic.discard, .{});
    defer parsed.deinit(a);
    if (!parsed.documentValid()) return 0;
    const doc = &parsed.document.?;
    var ir = dot.ir.Lowering(.{}).lowerComplete(a, doc, .{ .interpretation = dot.Profile(.{}).interpretation(doc, .{}) }) catch return 0;
    defer ir.deinit();
    if ((ir.findNode("a") catch return 0)) |from| {
        var name: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&name);
        ir.writeNodeName(from, &writer) catch return 0;
        if (!std.mem.eql(u8, writer.buffered(), "a")) return 0;
        if ((ir.findNode("b") catch return 0)) |to| {
            if (!(ir.hasEdge(from, to) catch return 0)) return 0;
        }
    }
    var graph = ir.materialize(.{}) catch return 0;
    defer graph.deinit();
    return @intCast(graph.edges.len);
}

export fn convenient(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    var result = dot.ir.parse(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var nodes = ir.nodeIterator();
    var count: u32 = 0;
    while (nodes.next()) |id| {
        var name: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&name);
        writer.print("{f}", .{ir.nodeName(id) catch return 0}) catch return 0;
        count += 1;
    }
    return count;
}
