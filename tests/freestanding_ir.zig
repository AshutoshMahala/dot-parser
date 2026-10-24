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
    var graph = ir.materialize(.{ .attributes = false }) catch return 0;
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
    while (nodes.next()) |node| {
        var name: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&name);
        writer.print("{f}", .{node.name()}) catch return 0;
        count += 1;
    }
    return count;
}

export fn materialized_attributes(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    var result = dot.ir.parse(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var graph = ir.materialize(.{}) catch return 0;
    defer graph.deinit();
    var edges = graph.edgeIterator();
    var count: u32 = 0;
    while (edges.next()) |edge| {
        if (edge.attribute("color") != null) count +%= 1;
        var values = edge.attributes();
        while (values.next()) |attribute| count +%= attribute.resolved.attribute orelse 0;
    }
    return count;
}

export fn streaming(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    var result = dot.ir.parse(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var edges = ir.edgeIterator(.{}) catch return 0;
    defer edges.deinit();
    var count: u32 = 0;
    while (edges.next() catch return 0) |_| count += 1;
    return count;
}

export fn port_views(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    var result = dot.ir.parse(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var edges = ir.edgeIterator(.{}) catch return 0;
    defer edges.deinit();
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    if ((edges.next() catch return 0)) |edge| {
        if ((edge.tailPort() catch return 0)) |port| {
            if (port.syntax()) |syntax| {
                syntax.first().writeLogicalWith(&writer, .{}) catch return 0;
                _ = syntax.compassWith(.{}) catch return 0;
            }
            const parts = port.graphvizPartsWith(.{}) catch return 0;
            parts.name().writeLogicalWith(&writer, .{}) catch return 0;
            _ = parts.compassWith(.{}) catch return 0;
            _ = parts.asCompassWith(.{}) catch return 0;
        }
    }
    return @intCast(writer.buffered().len);
}

export fn attributes(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    var result = dot.ir.parse(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    if ((ir.findNode("a") catch return 0)) |id| {
        const node = ir.nodeView(id) catch return 0;
        if (node.attribute("color")) |value|
            writer.print("{f}", .{value.value()}) catch return 0;
        var values = node.attributes(.{}) catch return 0;
        defer values.deinit();
        while (values.next() catch return 0) |entry|
            writer.print("{f}={f}", .{ entry.key(), entry.value() }) catch return 0;
    }
    const root = ir.scopeView(.root) catch return 0;
    var graph_values = root.attributes(.{}) catch return 0;
    defer graph_values.deinit();
    while (graph_values.next() catch return 0) |entry|
        writer.print("{f}={f}", .{ entry.key(), entry.value() }) catch return 0;
    var edges = ir.edgeIterator(.{}) catch return 0;
    defer edges.deinit();
    if ((edges.next() catch return 0)) |edge| {
        const view = edge;
        if ((view.attribute("weight") catch return 0)) |value|
            writer.print("{f}", .{value.value()}) catch return 0;
        var values = view.attributes(.{}) catch return 0;
        defer values.deinit();
        while (values.next() catch return 0) |entry|
            writer.print("{f}={f}", .{ entry.key(), entry.value() }) catch return 0;
    }
    return @intCast(writer.buffered().len);
}

export fn value_parts(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory[0..capacity]);
    var result = dot.ir.parse(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var nodes = ir.nodeIterator();
    var count: u32 = 0;
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    while (nodes.next()) |node| {
        const label = node.attribute("label") orelse continue;
        const value = label.value();
        var parts = value.partsWith(.{}) catch return 0;
        while (parts.next() catch return 0) |part| {
            if (part.fragment()) |fragment| count += @intCast(fragment.input.bytes.len);
            count += @intFromBool(part.kind() == .string);
        }
        value.writeLogicalWith(&writer, .{}) catch return 0;
        const copy = value.toString(fixed.allocator()) catch return 0;
        defer fixed.allocator().free(copy);
        count += @intCast(copy.len);
    }
    return count;
}
