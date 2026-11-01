//! Optional CSR categories. Every builder step does bounded work, shared by
//! direct and session drivers; no allocation or filtering during row reads.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const options = @import("materialization_options.zig");
const fixed = @import("fixed_storage.zig");
const none = std.math.maxInt(u32);

pub const Rows = struct {
    offsets: []u32 = &.{},
    entries: []u32 = &.{},
    tables: [4]u32 = .{ none, none, none, none },
    pub fn range(self: *const Rows, category: u2, node: u32) struct { start: u32, end: u32 } {
        const table = self.tables[category];
        return if (table == none) .{ .start = 0, .end = 0 } else .{ .start = self.offsets[table + node], .end = self.offsets[table + node + 1] };
    }
    pub fn deinit(self: *Rows, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.entries);
        self.* = .{};
    }
    pub fn bytes(self: *const Rows) usize {
        return (self.offsets.len + self.entries.len) * @sizeOf(u32);
    }
};
pub const Pools = struct { offsets: []u32, entries: []u32 };
const Incidences = struct { count: u2, nodes: [2]u32, categories: [2]u2 };
fn incidences(comptime selection: options.Adjacency, edge: t.Edge) Incidences {
    const from = @backingInt(edge.from);
    const to = @backingInt(edge.to);
    if (edge.operator == .undirected) return .{ .count = if (from == to) 1 else 2, .nodes = .{ from, to }, .categories = .{ 2, 2 } };
    if (from == to) return .{ .count = 1, .nodes = .{ from, to }, .categories = .{ 3, 3 } };
    return switch (selection) {
        .all => .{ .count = 2, .nodes = .{ from, to }, .categories = .{ 0, 1 } },
        .forward => .{ .count = 1, .nodes = .{ from, to }, .categories = .{ 0, 0 } },
        .backward => .{ .count = 1, .nodes = .{ to, from }, .categories = .{ 1, 1 } },
        .none => unreachable,
    };
}
fn count(value: u64) r.Error!u32 {
    if (value >= none) return error.IndexLimit;
    return @intCast(value);
}
pub const Builder = struct {
    pub const Phase = enum { count, prepare, offsets, entries, clear, degrees, prefix, fill, restore, done };
    phase: Phase = .count,
    rows: Rows = .{},
    counts: [4]u32 = @splat(0),
    offset_count: u32 = 0,
    entry_count: u32 = 0,
    cursor: u32 = 0,
    category: u3 = 0,
    sum: u32 = 0,
    shortfall: ?fixed.StorageShortfall = null,

    fn missing(self: *Builder, resource: fixed.Resource, limit: usize, needed: u32) r.Error {
        if (self.shortfall == null) self.shortfall = .{ .resource = resource, .limit = @intCast(limit), .required_at_least = needed };
        return error.PoolExhausted;
    }
    /// A record touches at most two incidences; other steps handle one u32 or
    /// one allocation. The caller charges/polls before every call.
    pub fn step(self: *Builder, comptime selection: options.Adjacency, edges: []const t.Edge, nodes: u32, allocator: std.mem.Allocator, pools: ?Pools) r.Error!void {
        switch (self.phase) {
            .count => {
                if (self.cursor == edges.len) {
                    self.phase = .prepare;
                    return;
                }
                const found = incidences(selection, edges[self.cursor]);
                for (0..found.count) |i| {
                    const category = found.categories[i];
                    self.counts[category] = try count(@as(u64, self.counts[category]) + 1);
                }
                self.cursor += 1;
            },
            .prepare => {
                for (self.counts, 0..) |n, i| if (n != 0) {
                    self.rows.tables[i] = self.offset_count;
                    self.offset_count = try count(@as(u64, self.offset_count) + nodes + 1);
                    self.entry_count = try count(@as(u64, self.entry_count) + n);
                };
                self.phase = .offsets;
            },
            .offsets => {
                if (pools) |p| {
                    if (self.offset_count > p.offsets.len) return self.missing(.adjacency_offsets, p.offsets.len, self.offset_count);
                    self.rows.offsets = p.offsets[0..self.offset_count];
                } else self.rows.offsets = try @import("session_storage.zig").allocate(u32, allocator, self.offset_count);
                self.phase = .entries;
            },
            .entries => {
                if (pools) |p| {
                    if (self.entry_count > p.entries.len) return self.missing(.adjacency_entries, p.entries.len, self.entry_count);
                    self.rows.entries = p.entries[0..self.entry_count];
                } else self.rows.entries = try @import("session_storage.zig").allocate(u32, allocator, self.entry_count);
                self.cursor = 0;
                self.phase = .clear;
            },
            .clear => {
                if (self.cursor == self.rows.offsets.len) {
                    self.cursor = 0;
                    self.phase = .degrees;
                    return;
                }
                self.rows.offsets[self.cursor] = 0;
                self.cursor += 1;
            },
            .degrees => {
                if (self.cursor == edges.len) {
                    self.cursor = 0;
                    self.phase = .prefix;
                    return;
                }
                const found = incidences(selection, edges[self.cursor]);
                for (0..found.count) |i| self.rows.offsets[self.rows.tables[found.categories[i]] + found.nodes[i]] += 1;
                self.cursor += 1;
            },
            .prefix => {
                if (self.category == 4) {
                    self.cursor = 0;
                    self.phase = .fill;
                    return;
                }
                const table = self.rows.tables[self.category];
                if (table == none) {
                    self.category += 1;
                    return;
                }
                const index = table + self.cursor;
                const degree = self.rows.offsets[index];
                self.rows.offsets[index] = self.sum;
                self.sum += degree; // Admitted aggregate entry_count bounds every sum.
                if (self.cursor == nodes) {
                    self.category += 1;
                    self.cursor = 0;
                } else self.cursor += 1;
            },
            .fill => {
                if (self.cursor == edges.len) {
                    self.cursor = nodes;
                    self.category = 0;
                    self.sum = 0;
                    self.phase = .restore;
                    return;
                }
                const found = incidences(selection, edges[self.cursor]);
                for (0..found.count) |i| {
                    const index = self.rows.tables[found.categories[i]] + found.nodes[i];
                    self.rows.entries[self.rows.offsets[index]] = self.cursor;
                    self.rows.offsets[index] += 1;
                }
                self.cursor += 1;
            },
            .restore => {
                if (self.category == 4) {
                    self.phase = .done;
                    return;
                }
                const table = self.rows.tables[self.category];
                if (table == none) {
                    self.category += 1;
                    return;
                }
                if (self.cursor == 0) {
                    self.rows.offsets[table] = self.sum;
                    self.sum += self.counts[self.category];
                    self.category += 1;
                    self.cursor = nodes;
                } else {
                    self.rows.offsets[table + self.cursor] = self.rows.offsets[table + self.cursor - 1];
                    self.cursor -= 1;
                }
            },
            .done => unreachable,
        }
    }
    pub fn take(self: *Builder) Rows {
        std.debug.assert(self.phase == .done);
        const result = self.rows;
        self.rows = .{};
        return result;
    }
};
