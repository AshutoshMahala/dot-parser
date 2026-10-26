//! Consumed lowering/query/materialization with an explicit fixed-buffer
//! allocator: no libc, OS, global allocator, recursion, or renderer required.
const std = @import("std");
const dot = @import("dot_parser");
// Parse storage remains independently supplied. Neither fixed IR route below
// calls an allocator or expands edges during construction.
export fn fixed_ir(source: [*]const u8, length: u32, parse_memory: [*]u8, parse_capacity: u32, resumable: bool) u32 {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    var parse_storage = std.heap.FixedBufferAllocator.init(parse_memory[0..parse_capacity]);
    var parsed = P.parseAndValidate(parse_storage.allocator(), source[0..length], dot.diagnostic.discard, .{});
    defer parsed.deinit(parse_storage.allocator());
    const doc = if (parsed.document) |*value| value else return 0;
    const Retained = IR.FixedGraphStorage(.{
        .nodes = 32,
        .scopes = 8,
        .occurrences = 16,
        .mentions = 128,
        .connections = 64,
        .declarations = 64,
        .attributes = 128,
        .attribute_keys = 32,
        .attribute_states = 1024,
        .coverage_gaps = 16,
    });
    const Scratch = IR.FixedLoweringScratch(Retained, .{ .nesting = 32, .edge_nesting = 8, .pending_endpoints = 64 });
    var retained: Retained = .{};
    var scratch: Scratch = .{};
    const memory: IR.LoweringMemory = .{ .graph = retained.storage(), .scratch = scratch.storage() };
    const options = .{ .interpretation = P.interpretation(doc, .{}) };
    if (resumable) {
        var operation = IR.partialLoweringSessionIn(doc, memory, options) catch return 0;
        defer operation.deinit();
        while (operation.advance(7).outcome == null) {}
        const graph = operation.takeResult() catch return 0;
        return graph.nodeCount();
    }
    const lowered = IR.lowerPartialIn(doc, memory, options);
    return if (lowered.graph) |graph| graph.nodeCount() else 0;
}
export fn resumable_attributes(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var result = dot.ir.parsePartial(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const graph = result.ir() orelse return 0;
    var edges = graph.edgeIterator(.{}) catch return 0;
    defer edges.deinit();
    const edge = (edges.next() catch return 0) orelse return 0;
    var stream = IR.attributesSession(edge, .{}) catch return 0;
    defer stream.deinit();
    var query = IR.attributeSession(edge, "color", .{}) catch return 0;
    defer query.deinit();
    while (query.advance(7).outcome == null) {}
    if (query.outcome.? == .failure) return 0;
    var count: u32 = 0;
    while (true) {
        const progress = stream.advance(7);
        if (progress.attribute) |entry| {
            const value = switch (entry) {
                .known => |v| v,
                .unknown => |u| u.retained.?,
            };
            count +%= value.resolved.attribute orelse 1;
        }
        if (progress.outcome) |outcome| return switch (outcome) {
            .success => count,
            .failure => 0,
        };
    }
}
export fn resumable_query(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var result = dot.ir.parsePartial(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const graph = result.ir() orelse return 0;
    var nodes = graph.nodeIterator();
    const from = nodes.next() orelse return 0;
    const to = nodes.next() orelse return 0;
    var query = IR.hasEdgeSession(graph, from.id, to.id, .{}) catch return 0;
    defer query.deinit();
    while (true) {
        const p = query.advance(7);
        if (p.outcome) |outcome| return switch (outcome) {
            .success => |answer| switch (answer) {
                .known => |found| if (found) 1 else 2,
                .unknown => 3,
            },
            .failure => 0,
        };
    }
}
export fn resumable_edge_stream(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var result = dot.ir.parsePartial(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const graph = result.ir() orelse return 0;
    var stream = IR.edgeSession(graph, .{}) catch return 0;
    defer stream.deinit();
    var count: u32 = 0;
    while (true) {
        const p = stream.advance(7);
        if (p.edge != null) count += 1;
        if (p.outcome) |outcome| return switch (outcome) {
            .success => count,
            .failure => 0,
        };
    }
}
export fn resumable_lowering(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    const P = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
    const IR = dot.ir.Lowering(.{ .policy = .{ .execution = .{ .metering = true } } });
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var parsed = P.parseAndValidate(fixed.allocator(), source[0..length], dot.diagnostic.discard, .{});
    defer parsed.deinit(fixed.allocator());
    const doc = if (parsed.document) |*doc| doc else return 0;
    var session = IR.partialLoweringSession(fixed.allocator(), doc, .{ .interpretation = P.interpretation(doc, .{}) }) catch return 0;
    defer session.deinit();
    while (session.advance(7).outcome == null) {}
    var ir = session.takeResult() catch return 0;
    defer ir.deinit();
    return @intCast(ir._data.nodes.len);
}
export fn resumable_edges(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var result = dot.ir.parsePartial(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var session = ir.materializationSession(.{}) catch return 0;
    defer session.deinit();
    while (session.advance(7).outcome == null) {}
    var graph = session.takeResult() catch return 0;
    defer graph.deinit();
    var iterator = graph.edgeIterator();
    var count: u32 = 0;
    while (iterator.next()) |edge| {
        var values = edge.attributes();
        while (values.next()) |_| count +%= 1;
        count +%= 1;
    }
    return count;
}
export fn retained_snapshot(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var result = dot.ir.parsePartial(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var nodes = ir.nodeIterator();
    var count: u32 = 0;
    while (nodes.next()) |node| {
        var mentions = node.mentions();
        while (mentions.next()) |_| count +%= 1;
        const value = switch (node.attribute("color")) {
            .known => |v| v,
            .unknown => |u| u.retained,
        };
        if (value != null) count +%= 1;
        var values = node.attributes(.{}) catch return 0;
        defer values.deinit();
        while (values.next() catch return 0) |answer| {
            const retained = switch (answer) {
                .known => |v| v,
                .unknown => |u| u.retained.?,
            };
            count +%= retained.resolved.attribute orelse 1;
        }
    }
    var scopes = ir.scopeIterator();
    while (scopes.next()) |scope| {
        var values = scope.attributes(.{}) catch return 0;
        defer values.deinit();
        while (values.next() catch return 0) |_| count +%= 1;
    }
    return count;
}
export fn retained_edges(source: [*]const u8, length: u32, memory: [*]u8, capacity: u32) u32 {
    var fixed = std.heap.FixedBufferAllocator.init(memory[0..capacity]);
    var result = dot.ir.parsePartial(fixed.allocator(), source[0..length], .{}) catch return 0;
    defer result.deinit();
    const ir = result.ir() orelse return 0;
    var graph = ir.materialize(.{}) catch return 0;
    defer graph.deinit();
    var edges = graph.edgeIterator();
    var count: u32 = 0;
    while (edges.next()) |edge| {
        var values = edge.attributes();
        while (values.next()) |answer| {
            const value = switch (answer) {
                .known => |v| v,
                .unknown => |u| u.retained.?,
            };
            count +%= value.resolved.attribute orelse 1;
        }
        count +%= 1;
    }
    return count;
}
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
