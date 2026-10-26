//! Explicit caller-owned IR pools. Layout/binding does no input walk, clearing,
//! allocation or edge expansion. Every descriptor is checked before use.
const std = @import("std");
const t = @import("topology.zig");
const a = @import("attributes.zig");
const c = @import("coverage.zig");
const records = @import("lowering_types.zig");
const syntax = @import("../dot/syntax.zig");
const r = @import("resources.zig");

pub const GraphCapacities = struct {
    nodes: u32 = 0,
    scopes: u32 = 0,
    occurrences: u32 = 0,
    mentions: u32 = 0,
    connections: u32 = 0,
    declarations: u32 = 0,
    attributes: u32 = 0,
    attribute_keys: u32 = 0,
    attribute_states: u32 = 0,
    coverage_gaps: u32 = 0,
};
pub const LoweringScratchCapacities = struct {
    nesting: u32 = 0,
    edge_nesting: u32 = 0,
    pending_endpoints: u32 = 0,
};
pub const Resource = enum {
    node_pool,
    scope_pool,
    occurrence_pool,
    mention_pool,
    connection_pool,
    declaration_pool,
    attribute_pool,
    attribute_key_pool,
    attribute_state_pool,
    coverage_gap_pool,
    nesting_frames,
    edge_frames,
    pending_endpoints,
    members,
    strict_pairs,
    attribute_winners,
};
pub const StorageShortfall = struct { resource: Resource, limit: u32, required_at_least: u32 };
pub const Bounds = struct { graph: GraphCapacities, scratch: LoweringScratchCapacities };

// These schemas are private. Descriptors expose byte regions, not record types.
const Retained = struct {
    nodes: []t.Node,
    scopes: []t.Scope,
    occurrences: []t.Occurrence,
    mentions: []t.Mention,
    connections: []t.Connection,
    declarations: []t.Declaration,
    attributes: []syntax.Attribute,
    keys: []a.Key,
    cells: []a.Cell,
    gaps: []c.Entry,
    bodies: []t.Body,
    meta: []a.Meta,
    attribute_scopes: []a.Scope,
    connection_defaults: []u32,
    offsets: []u32,
    positions: []u32,
    node_slots: []u32,
    key_slots: []u32,
};
const Scratch = struct {
    cursors: []records.ScopeCursor,
    scope_slots: []u32,
    stack: []records.Frame,
    edge_stack: []records.EdgeFrame,
    pending: []records.Pending,
};
pub const GraphStorage = struct { bytes: []u8, capacities: GraphCapacities };
pub const LoweringScratch = struct { bytes: []u8, graph_capacities: GraphCapacities, capacities: LoweringScratchCapacities };
pub const LoweringMemory = struct { graph: GraphStorage, scratch: LoweringScratch };

/// A successful fixed graph always has its root scope. Nodes are the first
/// retained region, scopes the second: when the node envelope is empty, scopes
/// begin at offset zero instead. Recover the complete borrowed reservation,
/// including unused pools/padding, without enlarging ordinary Graph records.
pub fn borrowedGraphBytes(graph: anytype) []const u8 {
    if (graph.borrowed_bytes == 0) return &.{};
    const start: [*]const u8 = if (graph.node_storage.len != 0)
        @ptrCast(graph.node_storage.ptr)
    else
        @ptrCast(graph.scope_storage.ptr);
    return start[0..graph.borrowed_bytes];
}

fn slotCount(count: u32) r.Error!usize {
    if (count == 0) return 0;
    const twice = std.math.mul(usize, count, 2) catch return error.IndexLimit;
    const result = std.math.ceilPowerOfTwo(usize, @max(16, twice)) catch return error.IndexLimit;
    if (result > std.math.maxInt(u32)) return error.IndexLimit;
    return result;
}
fn countFor(comptime field: []const u8, g: GraphCapacities, s: LoweringScratchCapacities) r.Error!usize {
    if (@hasField(GraphCapacities, field)) return @field(g, field);
    if (comptime std.mem.eql(u8, field, "keys")) return g.attribute_keys;
    if (comptime std.mem.eql(u8, field, "cells")) return g.attribute_states;
    if (comptime std.mem.eql(u8, field, "gaps")) return g.coverage_gaps;
    if (comptime std.mem.eql(u8, field, "bodies")) return g.occurrences;
    if (comptime std.mem.eql(u8, field, "meta")) return g.attributes;
    if (comptime std.mem.eql(u8, field, "attribute_scopes")) return if (g.attributes == 0) 0 else g.scopes;
    if (comptime std.mem.eql(u8, field, "connection_defaults")) return if (g.attributes == 0) 0 else g.connections;
    if (comptime std.mem.eql(u8, field, "offsets")) return std.math.add(usize, g.nodes, 1) catch error.IndexLimit;
    if (comptime std.mem.eql(u8, field, "positions")) return g.mentions;
    if (comptime std.mem.eql(u8, field, "node_slots")) return slotCount(g.nodes);
    if (comptime std.mem.eql(u8, field, "key_slots")) return slotCount(g.attribute_keys);
    if (comptime std.mem.eql(u8, field, "scope_slots")) return slotCount(g.scopes);
    if (comptime std.mem.eql(u8, field, "cursors")) return g.scopes;
    if (comptime std.mem.eql(u8, field, "stack")) return s.nesting;
    if (comptime std.mem.eql(u8, field, "edge_stack")) return s.edge_nesting;
    if (comptime std.mem.eql(u8, field, "pending")) return s.pending_endpoints;
    @compileError("unknown fixed IR pool: " ++ field);
}
pub const alignment = blk: {
    var result: usize = 1;
    for (.{ Retained, Scratch }) |Pools| for (std.meta.fieldNames(Pools)) |field| {
        result = @max(result, @alignOf(std.meta.Elem(@FieldType(Pools, field))));
    };
    break :blk result;
};
fn aligned(value: usize, by: usize) r.Error!usize {
    const plus = std.math.add(usize, value, by - 1) catch return error.IndexLimit;
    return plus & ~(by - 1);
}
fn Regions(comptime Pools: type) type {
    return struct {
        offsets: [std.meta.fieldNames(Pools).len]usize,
        counts: [std.meta.fieldNames(Pools).len]usize,
        bytes: usize,
        fn init(g: GraphCapacities, s: LoweringScratchCapacities) r.Error!@This() {
            var result: @This() = undefined;
            var at: usize = 0;
            inline for (comptime std.meta.fieldNames(Pools), 0..) |field, i| {
                const T = std.meta.Elem(@FieldType(Pools, field));
                at = try aligned(at, @alignOf(T));
                result.offsets[i] = at;
                result.counts[i] = try countFor(field, g, s);
                const size = std.math.mul(usize, result.counts[i], @sizeOf(T)) catch return error.IndexLimit;
                at = std.math.add(usize, at, size) catch return error.IndexLimit;
            }
            result.bytes = try aligned(at, alignment);
            return result;
        }
        fn bind(self: @This(), bytes: []u8, comptime field: []const u8) @FieldType(Pools, field) {
            const T = std.meta.Elem(@FieldType(Pools, field));
            const i = comptime std.meta.fieldIndex(Pools, field).?;
            if (self.counts[i] == 0) return &.{};
            const pointer: [*]T = @ptrCast(@alignCast(bytes.ptr + self.offsets[i]));
            return pointer[0..self.counts[i]];
        }
    };
}
pub const Layout = struct {
    graph_bytes: usize,
    scratch_bytes: usize,
    alignment: usize = @import("fixed_storage.zig").alignment,
    graph_capacities: GraphCapacities,
    scratch_capacities: LoweringScratchCapacities,
    retained: Regions(Retained),
    temporary: Regions(Scratch),

    pub fn bind(self: Layout, graph_buffer: []u8, scratch_buffer: []u8) r.Error!LoweringMemory {
        // Recompute rather than trusting caller-modifiable derived metadata.
        const checked = try loweringLayout(self.graph_capacities, self.scratch_capacities);
        if (!std.meta.eql(self, checked)) return error.InvalidStorage;
        if (graph_buffer.len < self.graph_bytes or scratch_buffer.len < self.scratch_bytes) return error.BufferTooSmall;
        const graph = graph_buffer[0..self.graph_bytes];
        const scratch = scratch_buffer[0..self.scratch_bytes];
        try checkRegion(graph);
        try checkRegion(scratch);
        if (overlaps(graph, scratch)) return error.InvalidStorage;
        return .{
            .graph = .{ .bytes = graph, .capacities = self.graph_capacities },
            .scratch = .{ .bytes = scratch, .graph_capacities = self.graph_capacities, .capacities = self.scratch_capacities },
        };
    }
};
pub fn loweringLayout(g: GraphCapacities, s: LoweringScratchCapacities) r.Error!Layout {
    @setEvalBranchQuota(20_000);
    inline for (comptime std.meta.fieldNames(GraphCapacities)) |field| _ = try r.index(@field(g, field));
    inline for (comptime std.meta.fieldNames(LoweringScratchCapacities)) |field| _ = try r.index(@field(s, field));
    if (g.nodes >= t.node_bit or g.scopes >= t.node_bit or g.occurrences >= t.node_bit or g.attributes >= @import("ports.zig").right) return error.IndexLimit;
    const retained = try Regions(Retained).init(g, s);
    const temporary = try Regions(Scratch).init(g, s);
    _ = std.math.add(usize, retained.bytes, temporary.bytes) catch return error.IndexLimit;
    return .{ .graph_bytes = retained.bytes, .scratch_bytes = temporary.bytes, .graph_capacities = g, .scratch_capacities = s, .retained = retained, .temporary = temporary };
}
pub fn FixedGraphStorage(comptime capacities: GraphCapacities) type {
    const layout = comptime loweringLayout(capacities, .{}) catch @compileError("invalid IR storage capacities");
    return struct {
        pub const graph_capacities = capacities;
        pub const byte_size = layout.graph_bytes;
        bytes: [byte_size]u8 align(alignment) = undefined,
        pub fn storage(self: *@This()) GraphStorage {
            return .{ .bytes = &self.bytes, .capacities = capacities };
        }
    };
}
pub fn FixedLoweringScratch(comptime GraphStorageType: type, comptime capacities: LoweringScratchCapacities) type {
    const graph = GraphStorageType.graph_capacities;
    const layout = comptime loweringLayout(graph, capacities) catch @compileError("invalid IR scratch capacities");
    return struct {
        pub const byte_size = layout.scratch_bytes;
        bytes: [byte_size]u8 align(alignment) = undefined,
        pub fn storage(self: *@This()) LoweringScratch {
            return .{ .bytes = &self.bytes, .graph_capacities = graph, .capacities = capacities };
        }
    };
}
fn checkRegion(bytes: []const u8) r.Error!void {
    if (bytes.len == 0) return;
    if (@intFromPtr(bytes.ptr) % alignment != 0) return error.InvalidStorage;
    _ = std.math.add(usize, @intFromPtr(bytes.ptr), bytes.len) catch return error.InvalidStorage;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const x = @intFromPtr(left.ptr);
    const y = @intFromPtr(right.ptr);
    // Difference form avoids overflowing pointer+length even for forged input.
    return if (x <= y) y - x < left.len else x - y < right.len;
}

pub const Context = struct {
    layout: Layout,
    memory: LoweringMemory,
    query_allocator: ?std.mem.Allocator,
    shortfall: ?StorageShortfall = null,
    peak: LoweringScratchCapacities = .{},

    pub fn init(memory: LoweringMemory, doc: *const syntax.Document, limits: r.Limits, query_allocator: ?std.mem.Allocator) r.Error!Context {
        if (!std.meta.eql(memory.graph.capacities, memory.scratch.graph_capacities)) return error.InvalidStorage;
        const layout = try loweringLayout(memory.graph.capacities, memory.scratch.capacities);
        const bound = try layout.bind(memory.graph.bytes, memory.scratch.bytes);
        if (layout.graph_bytes + layout.scratch_bytes > limits.max_bytes) return error.MemoryLimit;
        // A fixed number of descriptor checks; no source or pool-content scan.
        try disjoint(bound, std.mem.asBytes(doc));
        inline for (comptime std.meta.fieldNames(syntax.Document)) |field| {
            const T = @FieldType(syntax.Document, field);
            if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice) {
                try disjoint(bound, std.mem.sliceAsBytes(@field(doc, field)));
            }
        }
        if (doc.comments) |comments| try disjoint(bound, std.mem.sliceAsBytes(comments));
        return .{ .layout = layout, .memory = bound, .query_allocator = query_allocator };
    }
    fn disjoint(memory: LoweringMemory, input: []const u8) r.Error!void {
        if (overlaps(memory.graph.bytes, input) or overlaps(memory.scratch.bytes, input)) return error.InvalidStorage;
    }
    pub fn slice(self: *const Context, comptime field: []const u8) (if (@hasField(Retained, field)) @FieldType(Retained, field) else @FieldType(Scratch, field)) {
        return if (@hasField(Retained, field)) self.layout.retained.bind(self.memory.graph.bytes, field) else self.layout.temporary.bind(self.memory.scratch.bytes, field);
    }
    pub fn list(self: *const Context, comptime field: []const u8) std.ArrayList(std.meta.Elem(@TypeOf(self.slice(field)))) {
        const items = self.slice(field);
        var result: std.ArrayList(std.meta.Elem(@TypeOf(items))) = .empty;
        result.items = items[0..0];
        result.capacity = items.len;
        return result;
    }
    fn resource(comptime field: []const u8) Resource {
        const pairs = .{
            .{ "nodes", "node_pool" },                     .{ "node_slots", "node_pool" },          .{ "offsets", "node_pool" },
            .{ "scopes", "scope_pool" },                   .{ "scope_slots", "scope_pool" },        .{ "cursors", "scope_pool" },
            .{ "attribute_scopes", "scope_pool" },         .{ "occurrences", "occurrence_pool" },   .{ "bodies", "occurrence_pool" },
            .{ "mentions", "mention_pool" },               .{ "positions", "mention_pool" },        .{ "connections", "connection_pool" },
            .{ "connection_defaults", "connection_pool" }, .{ "declarations", "declaration_pool" }, .{ "attributes", "attribute_pool" },
            .{ "meta", "attribute_pool" },                 .{ "keys", "attribute_key_pool" },       .{ "key_slots", "attribute_key_pool" },
            .{ "cells", "attribute_state_pool" },          .{ "gaps", "coverage_gap_pool" },        .{ "stack", "nesting_frames" },
            .{ "edge_stack", "edge_frames" },              .{ "pending", "pending_endpoints" },
        };
        inline for (pairs) |pair| if (comptime std.mem.eql(u8, field, pair[0])) return @field(Resource, pair[1]);
        @compileError("unknown fixed IR resource");
    }
    pub fn ensure(self: *Context, comptime field: []const u8, needed: usize) r.Error!void {
        if (needed <= self.slice(field).len) return;
        const subtract: usize = if (comptime std.mem.eql(u8, field, "offsets")) 1 else 0;
        return self.fail(resource(field), self.slice(field).len - subtract, needed - subtract);
    }
    pub fn ensureTable(self: *Context, comptime field: []const u8, needed: usize) r.Error!void {
        const limit = if (comptime std.mem.eql(u8, field, "node_slots")) self.layout.graph_capacities.nodes else if (comptime std.mem.eql(u8, field, "scope_slots")) self.layout.graph_capacities.scopes else self.layout.graph_capacities.attribute_keys;
        if (needed > limit) return self.fail(resource(field), limit, needed);
    }
    fn fail(self: *Context, which: Resource, limit: usize, needed: usize) r.Error {
        const count = r.index(needed) catch return error.IndexLimit;
        if (self.shortfall == null) self.shortfall = .{ .resource = which, .limit = @intCast(limit), .required_at_least = count };
        return error.PoolExhausted;
    }
    pub fn observe(self: *Context, comptime field: []const u8, used: usize) void {
        if (comptime std.mem.eql(u8, field, "stack")) self.peak.nesting = @max(self.peak.nesting, @as(u32, @intCast(used)));
        if (comptime std.mem.eql(u8, field, "edge_stack")) self.peak.edge_nesting = @max(self.peak.edge_nesting, @as(u32, @intCast(used)));
        if (comptime std.mem.eql(u8, field, "pending")) self.peak.pending_endpoints = @max(self.peak.pending_endpoints, @as(u32, @intCast(used)));
    }
};

fn index64(value: u64) r.Error!u32 {
    if (value >= std.math.maxInt(u32)) return error.IndexLimit;
    return @intCast(value);
}
fn avlHeight(keys: u64) u64 {
    var previous: u64 = 0;
    var minimum: u64 = 1;
    var height: u64 = 0;
    while (minimum <= keys) {
        height += 1;
        const next = 1 + minimum + previous;
        previous = minimum;
        minimum = next;
    }
    return height;
}
/// Arithmetic only; never automatically called by lowering.
pub fn loweringBounds(comptime partial: bool, counts: syntax.Capacities, limits: r.Limits) r.Error!Bounds {
    const A = @as(u64, counts.attributes) + counts.assignments;
    const S = @as(u64, counts.subgraphs);
    const owners = @as(u64, counts.edges) + counts.edge_chains + counts.scoped_edges;
    const links = @as(u64, counts.edge_links) + counts.scoped_edge_links;
    const endpoints = 2 * owners + links;
    // Saturate at the enforced semantic cap using division, never overflowing.
    var cells: u64 = @min(A, limits.max_attribute_states);
    for ([_]u64{ S + 2, avlHeight(A) + 5 }) |factor| {
        cells = if (cells > limits.max_attribute_states / factor) limits.max_attribute_states else cells * factor;
    }
    return .{ .graph = .{
        .nodes = try index64(@as(u64, counts.nodes) + endpoints),
        .scopes = try index64(S + 1),
        .occurrences = try index64(S + 1),
        .mentions = try index64(@as(u64, counts.nodes) + endpoints),
        .connections = try index64(owners + links),
        .declarations = try index64(@as(u64, counts.nodes) + counts.attribute_statements + counts.assignments),
        .attributes = try index64(A),
        .attribute_keys = try index64(A),
        .attribute_states = try index64(cells),
        .coverage_gaps = if (partial) try index64(@as(u64, counts.statements) / 2 + 1) else 0,
    }, .scratch = .{
        .nesting = try index64(S + 1 + owners),
        .edge_nesting = try index64(owners),
        .pending_endpoints = try index64(endpoints),
    } };
}
