//! Explicit output/scratch reservations. No allocation, input walk or clearing
//! during binding. Fixed and growable drivers share the semantic algorithms.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const q = @import("query_storage.zig");
const f = @import("fixed_storage.zig");
const folded = @import("materialized_attributes.zig");
const choices = @import("materialization_options.zig");

pub const Capacities = struct { edges: u32 = 0, attribute_states: u32 = 0, attribute_keys: u32 = 0, adjacency_offsets: u32 = 0, adjacency_entries: u32 = 0 };
pub const ScratchCapacities = struct { members: u32 = 0 };
pub const Bounds = struct { output: Capacities, scratch: ScratchCapacities };
/// Only result construction/destruction consults ownership; never edge lookup.
pub const Ownership = union(enum) {
    // The edge pointer already lives in the public used slice. Store only the
    // allocation capacity here, keeping the owning handle's footprint unchanged.
    allocated: struct { allocator: std.mem.Allocator, capacity: usize },
    borrowed: []u8,
    pub fn edgeStorage(self: Ownership, edges: []const t.Edge) []const t.Edge {
        return edges.ptr[0..if (self == .allocated) self.allocated.capacity else edges.len];
    }
};
pub fn Output(comptime attributes: bool) type {
    return struct {
        pub const with_attributes = attributes;
        pub const selection: choices.Selection = .{ .attributes = attributes };
        bytes: []u8,
        capacities: Capacities,
    };
}
pub const Scratch = struct {
    bytes: []u8,
    node_capacity: u32,
    output_capacities: Capacities,
    capacities: ScratchCapacities,
    strict: bool,
};
pub fn Memory(comptime attributes: bool) type {
    return struct { output: Output(attributes), scratch: Scratch };
}
pub fn selected(comptime M: type) choices.Selection {
    return @FieldType(M, "output").selection;
}
const OutputLayout = struct {
    bytes: usize,
    roots: usize,
    cells: usize,
    keys: usize,
};
fn outputLayout(comptime attributes: bool, counts: Capacities) r.Error!OutputLayout {
    if (counts.adjacency_offsets != 0 or counts.adjacency_entries != 0) return error.InvalidStorage;
    if (!attributes and (counts.attribute_states != 0 or counts.attribute_keys != 0)) return error.InvalidStorage;
    inline for (comptime @typeInfo(Capacities).@"struct".field_names) |field| _ = try r.index(@field(counts, field));
    var bytes: usize = 0;
    _ = try q.appendRegion(&bytes, t.Edge, counts.edges);
    const roots = try q.appendRegion(&bytes, u32, if (counts.attribute_states == 0) 0 else counts.edges);
    const cells = try q.appendRegion(&bytes, folded.Cell, counts.attribute_states);
    const keys = try q.appendRegion(&bytes, u32, counts.attribute_keys);
    return .{ .bytes = bytes, .roots = roots, .cells = cells, .keys = keys };
}
const ScratchLayout = struct { bytes: usize, members: usize, slots: usize, slot_count: u32 };
fn scratchLayout(nodes: u32, output: Capacities, counts: ScratchCapacities, strict: bool) r.Error!ScratchLayout {
    if (nodes >= t.node_bit) return error.IndexLimit;
    _ = try r.index(counts.members);
    const slots = if (strict) try q.slotCount(output.edges) else 0;
    var bytes: usize = 0;
    _ = try q.appendRegion(&bytes, u32, if (counts.members == 0) 0 else nodes);
    const members = try q.appendRegion(&bytes, t.NodeId, counts.members);
    const offset = try q.appendRegion(&bytes, u32, slots);
    return .{ .bytes = bytes, .members = members, .slots = offset, .slot_count = slots };
}
pub fn Layout(comptime attributes: bool) type {
    return struct {
        output_bytes: usize,
        scratch_bytes: usize,
        alignment: usize = q.alignment,
        node_capacity: u32,
        output_capacities: Capacities,
        scratch_capacities: ScratchCapacities,
        strict: bool,
        retained: OutputLayout,
        temporary: ScratchLayout,
        pub fn bind(self: @This(), output: []u8, scratch: []u8) r.Error!Memory(attributes) {
            const checked = try layoutFor(attributes, self.node_capacity, self.output_capacities, self.scratch_capacities, self.strict);
            if (!std.meta.eql(self, checked)) return error.InvalidStorage;
            const retained = try q.checkedBuffer(output, self.output_bytes);
            const temporary = try q.checkedBuffer(scratch, self.scratch_bytes);
            try q.disjoint(retained, temporary);
            return .{
                .output = .{ .bytes = retained, .capacities = self.output_capacities },
                .scratch = .{ .bytes = temporary, .node_capacity = self.node_capacity, .output_capacities = self.output_capacities, .capacities = self.scratch_capacities, .strict = self.strict },
            };
        }
    };
}
fn layoutFor(comptime attributes: bool, nodes: u32, output: Capacities, scratch: ScratchCapacities, strict: bool) r.Error!Layout(attributes) {
    const retained = try outputLayout(attributes, output);
    const temporary = try scratchLayout(nodes, output, scratch, strict);
    _ = std.math.add(usize, retained.bytes, temporary.bytes) catch return error.IndexLimit;
    return .{ .output_bytes = retained.bytes, .scratch_bytes = temporary.bytes, .node_capacity = nodes, .output_capacities = output, .scratch_capacities = scratch, .strict = strict, .retained = retained, .temporary = temporary };
}
pub fn API(comptime rep: @import("representation.zig").Identity) type {
    return struct {
        inline fn selection(value: anytype) choices.Selection {
            return choices.selection(rep.attributes, value);
        }
        pub fn MaterializedStorage(comptime config: anytype) type {
            choices.checkSelection(config);
            return OutputFor(selection(config));
        }
        pub fn MaterializationScratch(comptime config: anytype) type {
            choices.checkSelection(config);
            return ScratchFor(selection(config));
        }
        pub fn MaterializationMemory(comptime config: anytype) type {
            choices.checkSelection(config);
            return MemoryFor(selection(config));
        }
        pub fn FixedMaterializedStorage(comptime capacities: Capacities, comptime config: anytype) type {
            comptime for (@typeInfo(@TypeOf(config)).@"struct".field_names) |field| {
                if (!std.mem.eql(u8, field, "attributes") and !std.mem.eql(u8, field, "adjacency")) @compileError("unknown fixed materialized storage option: " ++ field);
            };
            const selected_output = selection(config);
            const layout = outputLayoutFor(selected_output, capacities) catch @compileError("invalid materialized storage capacities");
            return struct {
                pub const with_attributes = selected_output.attributes;
                pub const selection = selected_output;
                pub const output_capacities = capacities;
                pub const byte_size = layout.bytes;
                bytes: [byte_size]u8 align(q.alignment) = undefined,
                pub fn storage(self: *@This()) OutputFor(selected_output) {
                    return .{ .bytes = &self.bytes, .capacities = capacities };
                }
            };
        }
        pub fn FixedMaterializationScratch(comptime Retained: type, comptime OutputStorage: type, comptime capacities: ScratchCapacities, comptime config: anytype) type {
            comptime for (@typeInfo(@TypeOf(config)).@"struct".field_names) |field| {
                if (!std.mem.eql(u8, field, "strict")) @compileError("unknown fixed materialization scratch option: " ++ field);
            };
            const strict = if (@hasField(@TypeOf(config), "strict")) config.strict else true;
            const layout = scratchLayout(Retained.graph_capacities.nodes, OutputStorage.output_capacities, capacities, strict) catch @compileError("invalid materialization scratch capacities");
            return struct {
                pub const byte_size = layout.bytes;
                bytes: [byte_size]u8 align(q.alignment) = undefined,
                pub fn storage(self: *@This()) ScratchFor(OutputStorage.selection) {
                    return .{ .bytes = &self.bytes, .node_capacity = Retained.graph_capacities.nodes, .output_capacities = OutputStorage.output_capacities, .capacities = capacities, .strict = strict };
                }
            };
        }
        pub inline fn materializationLayout(graph: anytype, output: Capacities, scratch: ScratchCapacities, config: anytype) r.Error!LayoutFor(.{ .attributes = if (@hasField(@TypeOf(config), "attributes")) config.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(config), "adjacency")) config.adjacency else .none }) {
            const selected_output: choices.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(config), "attributes")) config.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(config), "adjacency")) config.adjacency else .none };
            _ = choices.options(selected_output, config); // No cancellation callback.
            const g = q.data(graph);
            if (selected_output.attributes) comptime @import("representation.zig").requireAttributes(@TypeOf(g.*).capabilities.attributes);
            return layoutSelected(selected_output, try r.index(g.nodes.len), output, scratch, g.strict);
        }
        pub inline fn materializationBounds(graph: anytype, config: anytype) r.Error!Bounds {
            const selected_output: choices.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(config), "attributes")) config.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(config), "adjacency")) config.adjacency else .none };
            return @import("materialization_bounds.zig").bounds(selected_output, graph, choices.options(selected_output, config), false);
        }
        pub inline fn scanMaterializationBounds(graph: anytype, config: anytype) r.Error!Bounds {
            const selected_output: choices.Selection = comptime .{ .attributes = if (@hasField(@TypeOf(config), "attributes")) config.attributes else rep.attributes, .adjacency = if (@hasField(@TypeOf(config), "adjacency")) config.adjacency else .none };
            return @import("materialization_bounds.zig").bounds(selected_output, graph, choices.options(selected_output, config), true);
        }
    };
}

pub fn OutputFor(comptime selected_output: choices.Selection) type {
    if (selected_output.adjacency == .none) return Output(selected_output.attributes);
    return struct {
        pub const with_attributes = selected_output.attributes;
        pub const selection = selected_output;
        bytes: []u8,
        capacities: Capacities,
    };
}
pub fn ScratchFor(comptime selected_output: choices.Selection) type {
    if (selected_output.adjacency == .none) return Scratch;
    return struct {
        pub const selection = selected_output;
        bytes: []u8,
        node_capacity: u32,
        output_capacities: Capacities,
        capacities: ScratchCapacities,
        strict: bool,
    };
}
pub fn MemoryFor(comptime selection: choices.Selection) type {
    if (selection.adjacency == .none) return Memory(selection.attributes);
    return struct { output: OutputFor(selection), scratch: ScratchFor(selection) };
}
fn coreCounts(counts: Capacities) Capacities {
    var result = counts;
    result.adjacency_offsets = 0;
    result.adjacency_entries = 0;
    return result;
}
const AdjacencyOutputLayout = struct { bytes: usize, base: OutputLayout, offsets: usize, entries: usize };
fn outputLayoutFor(comptime selection: choices.Selection, counts: Capacities) r.Error!AdjacencyOutputLayout {
    const base = try outputLayout(selection.attributes, if (selection.adjacency == .none) counts else coreCounts(counts));
    _ = try r.index(counts.adjacency_offsets);
    _ = try r.index(counts.adjacency_entries);
    var bytes = base.bytes;
    const offsets = try q.appendRegion(&bytes, u32, counts.adjacency_offsets);
    const entries = try q.appendRegion(&bytes, u32, counts.adjacency_entries);
    return .{ .bytes = bytes, .base = base, .offsets = offsets, .entries = entries };
}
pub fn LayoutFor(comptime selection: choices.Selection) type {
    if (selection.adjacency == .none) return Layout(selection.attributes);
    return struct {
        output_bytes: usize,
        scratch_bytes: usize,
        alignment: usize = q.alignment,
        node_capacity: u32,
        output_capacities: Capacities,
        scratch_capacities: ScratchCapacities,
        strict: bool,
        retained: AdjacencyOutputLayout,
        temporary: ScratchLayout,
        pub fn bind(self: @This(), output: []u8, scratch: []u8) r.Error!MemoryFor(selection) {
            const checked = try layoutSelected(selection, self.node_capacity, self.output_capacities, self.scratch_capacities, self.strict);
            if (!std.meta.eql(self, checked)) return error.InvalidStorage;
            const retained = try q.checkedBuffer(output, self.output_bytes);
            const temporary = try q.checkedBuffer(scratch, self.scratch_bytes);
            try q.disjoint(retained, temporary);
            return .{
                .output = .{ .bytes = retained, .capacities = self.output_capacities },
                .scratch = .{ .bytes = temporary, .node_capacity = self.node_capacity, .output_capacities = self.output_capacities, .capacities = self.scratch_capacities, .strict = self.strict },
            };
        }
    };
}
fn layoutSelected(comptime selection: choices.Selection, nodes: u32, output: Capacities, scratch: ScratchCapacities, strict: bool) r.Error!LayoutFor(selection) {
    if (selection.adjacency == .none) return layoutFor(selection.attributes, nodes, output, scratch, strict);
    const retained = try outputLayoutFor(selection, output);
    const temporary = try scratchLayout(nodes, output, scratch, strict);
    _ = std.math.add(usize, retained.bytes, temporary.bytes) catch return error.IndexLimit;
    return .{ .output_bytes = retained.bytes, .scratch_bytes = temporary.bytes, .node_capacity = nodes, .output_capacities = output, .scratch_capacities = scratch, .strict = strict, .retained = retained, .temporary = temporary };
}
pub fn Prepared(comptime selection: choices.Selection) type {
    return struct { core: Memory(selection.attributes), pools: @import("adjacency_rows.zig").Pools, output: []u8, reserved: usize };
}
/// Admit the entire reservation and all aliases before expansion writes. The
/// ordinary engine then receives its prefix with unchanged descriptor/layout.
pub fn prepare(comptime selection: choices.Selection, memory: MemoryFor(selection), graph: anytype, limits: r.Limits) r.Error!Prepared(selection) {
    if (!std.meta.eql(memory.output.capacities, memory.scratch.output_capacities)) return error.InvalidStorage;
    const layout = try layoutSelected(selection, memory.scratch.node_capacity, memory.output.capacities, memory.scratch.capacities, memory.scratch.strict);
    const bound = try layout.bind(memory.output.bytes, memory.scratch.bytes);
    try q.checkGraph(bound.output.bytes, graph);
    try q.checkGraph(bound.scratch.bytes, graph);
    const reserved = layout.output_bytes + layout.scratch_bytes;
    if (reserved > limits.max_bytes) return error.MemoryLimit;
    const counts = coreCounts(bound.output.capacities);
    return .{
        .core = .{
            .output = .{ .bytes = bound.output.bytes[0..layout.retained.base.bytes], .capacities = counts },
            .scratch = .{ .bytes = bound.scratch.bytes, .node_capacity = bound.scratch.node_capacity, .output_capacities = counts, .capacities = bound.scratch.capacities, .strict = bound.scratch.strict },
        },
        .pools = .{ .offsets = q.region(u32, bound.output.bytes, layout.retained.offsets, bound.output.capacities.adjacency_offsets), .entries = q.region(u32, bound.output.bytes, layout.retained.entries, bound.output.capacities.adjacency_entries) },
        .output = bound.output.bytes,
        .reserved = reserved,
    };
}

pub fn State(comptime attributes: bool) type {
    return struct {
        const Self = @This();
        output: []u8,
        edges: []t.Edge,
        roots: if (attributes) []u32 else void,
        cells: if (attributes) []folded.Cell else void,
        keys: if (attributes) []u32 else void,
        marks: []u32,
        members: []t.NodeId,
        slots: []u32,
        peak: usize,
        used: ScratchCapacities = .{},
        shortfall: ?f.StorageShortfall = null,
        pub fn init(memory: Memory(attributes), graph: anytype, limits: r.Limits) r.Error!Self {
            if (!std.meta.eql(memory.output.capacities, memory.scratch.output_capacities)) return error.InvalidStorage;
            const g = q.data(graph);
            if (attributes) comptime @import("representation.zig").requireAttributes(@TypeOf(g.*).capabilities.attributes);
            if ((memory.scratch.capacities.members != 0 and g.nodes.len > memory.scratch.node_capacity) or (g.strict and !memory.scratch.strict)) return error.InvalidStorage;
            const layout = try layoutFor(attributes, memory.scratch.node_capacity, memory.output.capacities, memory.scratch.capacities, memory.scratch.strict);
            const bound = try layout.bind(memory.output.bytes, memory.scratch.bytes);
            try q.checkGraph(bound.output.bytes, graph);
            try q.checkGraph(bound.scratch.bytes, graph);
            const bytes = layout.output_bytes + layout.scratch_bytes;
            if (bytes > limits.max_bytes) return error.MemoryLimit;
            const o = bound.output.bytes;
            const s = bound.scratch.bytes;
            const counts = bound.output.capacities;
            return .{
                .output = o,
                .edges = q.region(t.Edge, o, 0, counts.edges),
                .roots = if (attributes) q.region(u32, o, layout.retained.roots, if (counts.attribute_states == 0) 0 else counts.edges) else {},
                .cells = if (attributes) q.region(folded.Cell, o, layout.retained.cells, counts.attribute_states) else {},
                .keys = if (attributes) q.region(u32, o, layout.retained.keys, counts.attribute_keys) else {},
                .marks = q.region(u32, s, 0, if (bound.scratch.capacities.members == 0) 0 else g.nodes.len),
                .members = q.region(t.NodeId, s, layout.temporary.members, bound.scratch.capacities.members),
                .slots = q.region(u32, s, layout.temporary.slots, layout.temporary.slot_count),
                .peak = bytes,
            };
        }
        pub fn maps(self: *const Self, comptime with_ports: bool, limit: u32) folded.Builder(with_ports) {
            return .{ .limit = limit, .roots = .initBuffer(self.roots), .cells = .initBuffer(self.cells), .keys = .initBuffer(self.keys) };
        }
        pub fn needPair(self: *Self, count: usize) r.Error!void {
            if (count > self.edges.len) return self.missing(.materialized_edges, self.edges.len, count);
        }
        pub fn needMembers(self: *Self, count: usize) r.Error!void {
            if (count > self.members.len) return self.missing(.members, self.members.len, count);
            self.used.members = @max(self.used.members, @as(u32, @intCast(count)));
        }
        pub fn ensure(self: *Self, comptime field: []const u8, count: usize) r.Error!void {
            const pool = @field(self, field);
            if (count <= pool.len) return;
            if (comptime std.mem.eql(u8, field, "roots")) return error.InvalidStorage;
            const resource: f.Resource = if (comptime std.mem.eql(u8, field, "cells")) .materialized_attribute_states else .materialized_attribute_keys;
            return self.missing(resource, pool.len, count);
        }
        pub fn observe(_: *Self, comptime _: []const u8, _: usize) void {}
        fn missing(self: *Self, resource: f.Resource, limit: usize, count: usize) r.Error {
            const needed = r.index(count) catch return error.IndexLimit;
            if (self.shortfall == null) self.shortfall = .{ .resource = resource, .limit = @intCast(limit), .required_at_least = needed };
            return error.PoolExhausted;
        }
        pub fn failure(_: *const Self, err: r.Error) r.Error {
            return err;
        }
    };
}
