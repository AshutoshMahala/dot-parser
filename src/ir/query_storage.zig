//! Caller-owned query scratch. Binding checks descriptors without walking input
//! or clearing storage. Initialization belongs to the direct/session driver.
const std = @import("std");
const r = @import("resources.zig");
const t = @import("topology.zig");
const fixed = @import("fixed_storage.zig");
const execution = @import("execution_policy.zig");

pub const EdgeScratchCapacities = struct { members: u32 = 0, strict_pairs: u32 = 0 };
pub const AttributeScratchCapacities = struct { winners: u32 = 0 };
pub const Winner = struct { key: u32, attribute: u32 = @import("attributes.zig").none, connection: t.ConnectionId = undefined };
pub const EdgeScratch = struct { bytes: []u8, node_capacity: u32, capacities: EdgeScratchCapacities };
pub const AttributeScratch = struct { bytes: []u8, capacities: AttributeScratchCapacities };
pub const alignment = @max(@alignOf(Winner), @alignOf(t.NodeId));

/// Validate before checking owner aliases; excess caller bytes are not borrowed.
pub fn checkedBytes(memory: anytype) r.Error![]u8 {
    const layout = if (@TypeOf(memory) == EdgeScratch)
        try edgeLayoutFor(memory.node_capacity, memory.capacities)
    else
        try attributeScratchLayout(memory.capacities);
    return (try layout.bind(memory.bytes)).bytes;
}

fn appendRegion(total: *usize, comptime T: type, count: usize) r.Error!usize {
    const start = std.math.add(usize, total.*, @alignOf(T) - 1) catch return error.IndexLimit;
    const offset = start & ~@as(usize, @alignOf(T) - 1);
    total.* = std.math.add(usize, offset, std.math.mul(usize, count, @sizeOf(T)) catch return error.IndexLimit) catch return error.IndexLimit;
    return offset;
}
fn slotCount(count: u32) r.Error!u32 {
    if (count == 0) return 0;
    const twice = std.math.mul(usize, count, 2) catch return error.IndexLimit;
    const slots = std.math.ceilPowerOfTwo(usize, @max(16, twice)) catch return error.IndexLimit;
    return r.index(slots);
}
fn region(comptime T: type, bytes: []u8, offset: usize, count: usize) []T {
    if (count == 0) return &.{};
    return @as([*]T, @ptrCast(@alignCast(bytes.ptr + offset)))[0..count];
}
fn checkedBuffer(buffer: []u8, bytes: usize) r.Error![]u8 {
    if (buffer.len < bytes) return error.BufferTooSmall;
    const bound = buffer[0..bytes];
    if (bytes != 0) {
        if (@intFromPtr(bound.ptr) % alignment != 0) return error.InvalidStorage;
        _ = std.math.add(usize, @intFromPtr(bound.ptr), bytes) catch return error.InvalidStorage;
    }
    return bound;
}
fn disjoint(buffer: []u8, input: anytype) r.Error!void {
    const bytes = std.mem.sliceAsBytes(input);
    if (buffer.len == 0 or bytes.len == 0) return;
    const a = @intFromPtr(buffer.ptr);
    const b = @intFromPtr(bytes.ptr);
    if (if (a <= b) b - a < buffer.len else a - b < bytes.len) return error.InvalidStorage;
}
pub fn data(graph: anytype) if (@hasField(@TypeOf(graph.*), "_data")) *const @FieldType(@TypeOf(graph.*), "_data") else @TypeOf(graph) {
    return if (@hasField(@TypeOf(graph.*), "_data")) &graph._data else graph;
}
/// Check known owners/pools, including unused retained capacity. Lifetimes and
/// scratch simultaneously lent to another operation remain caller obligations.
pub fn checkGraph(buffer: []u8, graph: anytype) r.Error!void {
    try disjoint(buffer, @as([*]const @TypeOf(graph.*), @ptrCast(graph))[0..1]);
    if (@hasField(@TypeOf(graph.*), "_coverage")) try disjoint(buffer, graph._coverage.entries.allocatedSlice());
    const g = data(graph);
    try disjoint(buffer, fixed.borrowedGraphBytes(g));
    inline for (.{ "source", "node_storage", "scope_storage", "declaration_storage", "nodes", "scopes", "declarations", "occurrences", "mentions", "connections", "attributes", "bodies", "node_slots", "posting_offsets", "posting_positions" }) |field| try disjoint(buffer, @field(g, field));
    const a = &g.attribute_data;
    try disjoint(buffer, a.keys.allocatedSlice());
    try disjoint(buffer, a.cells.allocatedSlice());
    inline for (.{ "meta", "scopes", "connection_defaults" }) |field| try disjoint(buffer, @field(a, field));
    try disjoint(buffer, a.table.slots);
}
pub fn checkMaterialized(buffer: []u8, owner: anytype) r.Error!void {
    try disjoint(buffer, @as([*]const @TypeOf(owner.*), @ptrCast(owner))[0..1]);
    try disjoint(buffer, owner.storage);
    inline for (.{ "roots", "cells", "keys" }) |field| try disjoint(buffer, @field(owner.folded, field).allocatedSlice());
}

pub const EdgeLayout = struct {
    byte_size: usize,
    alignment: usize = @import("query_storage.zig").alignment,
    node_capacity: u32,
    capacities: EdgeScratchCapacities,
    marks_offset: usize,
    members_offset: usize,
    pairs_offset: usize,
    slots_offset: usize,
    slots_count: u32,
    pub fn bind(self: EdgeLayout, buffer: []u8) r.Error!EdgeScratch {
        if (!std.meta.eql(self, try edgeLayoutFor(self.node_capacity, self.capacities))) return error.InvalidStorage;
        return .{ .bytes = try checkedBuffer(buffer, self.byte_size), .node_capacity = self.node_capacity, .capacities = self.capacities };
    }
};
fn edgeLayoutFor(nodes: u32, capacities: EdgeScratchCapacities) r.Error!EdgeLayout {
    _ = try r.index(capacities.members);
    _ = try r.index(capacities.strict_pairs);
    if (nodes >= t.node_bit) return error.IndexLimit;
    const slots = try slotCount(capacities.strict_pairs);
    var bytes: usize = 0;
    const marks_offset = try appendRegion(&bytes, u32, if (capacities.members == 0) 0 else nodes);
    const members_offset = try appendRegion(&bytes, t.NodeId, capacities.members);
    const pairs_offset = try appendRegion(&bytes, [2]u32, capacities.strict_pairs);
    const slots_offset = try appendRegion(&bytes, u32, slots);
    return .{ .byte_size = bytes, .node_capacity = nodes, .capacities = capacities, .marks_offset = marks_offset, .members_offset = members_offset, .pairs_offset = pairs_offset, .slots_offset = slots_offset, .slots_count = slots };
}
pub fn edgeScratchLayout(graph: anytype, capacities: EdgeScratchCapacities) r.Error!EdgeLayout {
    return edgeLayoutFor(try r.index(data(graph).nodes.len), capacities);
}
pub fn FixedEdgeScratch(comptime Retained: type, comptime capacities: EdgeScratchCapacities) type {
    const layout = comptime edgeLayoutFor(Retained.graph_capacities.nodes, capacities) catch @compileError("invalid IR edge scratch capacities");
    return struct {
        pub const byte_size = layout.byte_size;
        bytes: [byte_size]u8 align(alignment) = undefined,
        pub fn storage(self: *@This()) EdgeScratch {
            return .{ .bytes = &self.bytes, .node_capacity = layout.node_capacity, .capacities = capacities };
        }
    };
}
pub const AttributeLayout = struct {
    byte_size: usize,
    alignment: usize = @import("query_storage.zig").alignment,
    capacities: AttributeScratchCapacities,
    pub fn bind(self: AttributeLayout, buffer: []u8) r.Error!AttributeScratch {
        if (!std.meta.eql(self, try attributeScratchLayout(self.capacities))) return error.InvalidStorage;
        return .{ .bytes = try checkedBuffer(buffer, self.byte_size), .capacities = self.capacities };
    }
};
pub fn attributeScratchLayout(capacities: AttributeScratchCapacities) r.Error!AttributeLayout {
    _ = try r.index(capacities.winners);
    return .{ .byte_size = std.math.mul(usize, capacities.winners, @sizeOf(Winner)) catch return error.IndexLimit, .capacities = capacities };
}
pub fn FixedAttributeScratch(comptime capacities: AttributeScratchCapacities) type {
    const layout = comptime attributeScratchLayout(capacities) catch @compileError("invalid IR attribute scratch capacities");
    return struct {
        pub const byte_size = layout.byte_size;
        bytes: [byte_size]u8 align(alignment) = undefined,
        pub fn storage(self: *@This()) AttributeScratch {
            return .{ .bytes = &self.bytes, .capacities = capacities };
        }
    };
}
/// Arithmetic-only upper bound. Does not walk connections, call hooks or reserve.
pub fn edgeScratchBounds(graph: anytype, options: anytype) r.Error!EdgeScratchCapacities {
    comptime for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
        if (!std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !std.mem.eql(u8, field, "policy")) @compileError("unknown IR edge scratch sizing option: " ++ field);
    };
    const g = data(graph);
    const limits = if (@hasField(@TypeOf(options), "limits")) (execution.option(?r.Limits, options.limits) orelse g.limits) else g.limits;
    if (g.connections.len == 0) return .{};
    const n: u64 = @intCast(g.nodes.len);
    const members = std.math.mul(u64, n, 2) catch return error.IndexLimit;
    var pairs: u64 = 0;
    if (g.strict) {
        const undirected = g.kind == .undigraph;
        pairs = if (undirected) (std.math.mul(u64, n, std.math.add(u64, n, 1) catch return error.IndexLimit) catch return error.IndexLimit) / 2 else std.math.mul(u64, n, n) catch return error.IndexLimit;
        pairs = @min(pairs, limits.max_edges, limits.max_pairs);
    }
    if (members >= std.math.maxInt(u32) or pairs >= std.math.maxInt(u32)) return error.IndexLimit;
    return .{ .members = @intCast(members), .strict_pairs = @intCast(pairs) };
}
pub fn attributeScratchBounds(graph: anytype) AttributeScratchCapacities {
    const g = data(graph);
    return .{ .winners = if (g.strict) @intCast(g.attribute_data.keys.items.len) else 0 };
}

pub const EdgeState = struct {
    marks: []u32,
    members: []t.NodeId,
    pairs: [][2]u32,
    slots: []u32,
    peak: usize,
    used: EdgeScratchCapacities = .{},
    shortfall: ?fixed.StorageShortfall = null,
    pub fn init(memory: EdgeScratch, graph: anytype, limits: r.Limits) r.Error!EdgeState {
        const layout = try edgeLayoutFor(memory.node_capacity, memory.capacities);
        const bound = try layout.bind(memory.bytes);
        const n = data(graph).nodes.len;
        if (memory.capacities.members != 0 and n > memory.node_capacity) return error.InvalidStorage;
        try checkGraph(bound.bytes, graph);
        if (layout.byte_size > limits.max_bytes) return error.MemoryLimit;
        return .{
            .marks = region(u32, bound.bytes, layout.marks_offset, if (memory.capacities.members == 0) 0 else n),
            .members = region(t.NodeId, bound.bytes, layout.members_offset, memory.capacities.members),
            .pairs = region([2]u32, bound.bytes, layout.pairs_offset, memory.capacities.strict_pairs),
            .slots = region(u32, bound.bytes, layout.slots_offset, layout.slots_count),
            .peak = layout.byte_size,
        };
    }
    pub fn needMembers(self: *EdgeState, count: usize) r.Error!void {
        if (count > self.members.len) return self.missing(.members, self.members.len, count);
        self.used.members = @max(self.used.members, @as(u32, @intCast(count)));
    }
    pub fn needPair(self: *EdgeState, count: usize) r.Error!void {
        if (count > self.pairs.len) return self.missing(.strict_pairs, self.pairs.len, count);
    }
    fn missing(self: *EdgeState, resource: fixed.Resource, capacity: usize, count: usize) r.Error {
        if (count > std.math.maxInt(u32)) return error.IndexLimit;
        self.shortfall = .{ .resource = resource, .limit = @intCast(capacity), .required_at_least = @intCast(count) };
        return error.PoolExhausted;
    }
    pub fn failure(_: *const EdgeState, err: r.Error) r.Error {
        return err;
    }
};
pub const AttributeState = struct {
    winners: []Winner,
    peak: usize,
    used: AttributeScratchCapacities = .{},
    shortfall: ?fixed.StorageShortfall = null,
    pub fn init(memory: AttributeScratch, graph: anytype, limits: r.Limits) r.Error!AttributeState {
        const layout = try attributeScratchLayout(memory.capacities);
        const bound = try layout.bind(memory.bytes);
        try checkGraph(bound.bytes, graph);
        if (layout.byte_size > limits.max_bytes) return error.MemoryLimit;
        return .{ .winners = region(Winner, bound.bytes, 0, memory.capacities.winners), .peak = layout.byte_size };
    }
    pub fn take(self: *AttributeState, count: u32) r.Error![]Winner {
        if (count > self.winners.len) {
            self.shortfall = .{ .resource = .attribute_winners, .limit = @intCast(self.winners.len), .required_at_least = count };
            return error.PoolExhausted;
        }
        self.used.winners = @max(self.used.winners, count);
        return self.winners[0..count];
    }
    pub fn failure(_: *const AttributeState, err: r.Error) r.Error {
        return err;
    }
};
