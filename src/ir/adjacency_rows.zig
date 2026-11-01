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
    pub const Consumed = struct { used: u32 = 0, failure: ?r.Error = null };

    /// Fuse only already-admitted row work, up to the caller's grant/lifetime
    /// limit. Callers use this only without a cancellation callback. Each
    /// record/u32 keeps its original credit and exactly the one-step cursor;
    /// allocations and phase transitions remain in step().
    pub fn consume(self: *Builder, comptime selection: options.Adjacency, edges: []const t.Edge, nodes: u32, grant: u32) Consumed {
        std.debug.assert(grant != 0);
        switch (self.phase) {
            inline .count, .degrees, .fill => |phase| {
                const start = self.cursor;
                const n: u32 = @intCast(@min(grant, edges.len - self.cursor));
                for (edges[self.cursor..][0..n]) |edge| {
                    self.edgeStep(selection, phase, edge) catch |err| return .{ .used = self.cursor - start + 1, .failure = err };
                    self.cursor += 1;
                }
                return .{ .used = n };
            },
            .clear => {
                const n: u32 = @intCast(@min(grant, self.rows.offsets.len - self.cursor));
                @memset(self.rows.offsets[self.cursor..][0..n], 0);
                self.cursor += n;
                return .{ .used = n };
            },
            .prefix => {
                if (self.category == 4) return .{};
                const table = self.rows.tables[self.category];
                if (table == none) return .{};
                const n = @min(grant, nodes - self.cursor + 1);
                var sum = self.sum;
                for (self.rows.offsets[table + self.cursor ..][0..n]) |*value| {
                    const degree = value.*;
                    value.* = sum;
                    sum += degree; // Bounded by the admitted entry count.
                }
                self.sum = sum;
                self.cursor += n;
                if (self.cursor == nodes + 1) {
                    self.category += 1;
                    self.cursor = 0;
                }
                return .{ .used = n };
            },
            .restore => {
                if (self.category == 4 or self.cursor == 0) return .{};
                const table = self.rows.tables[self.category];
                if (table == none) return .{};
                const n = @min(grant, self.cursor);
                const end = table + self.cursor;
                std.mem.copyBackwards(u32, self.rows.offsets[end - n + 1 .. end + 1], self.rows.offsets[end - n .. end]);
                self.cursor -= n;
                return .{ .used = n };
            },
            else => return .{},
        }
    }
    inline fn edgeStep(self: *Builder, comptime selection: options.Adjacency, comptime phase: Phase, edge: t.Edge) r.Error!void {
        const found = incidences(selection, edge);
        for (0..found.count) |i| {
            const category = found.categories[i];
            if (phase == .count) {
                self.counts[category] = try count(@as(u64, self.counts[category]) + 1);
            } else {
                const index = self.rows.tables[category] + found.nodes[i];
                if (phase == .degrees) self.rows.offsets[index] += 1 else {
                    self.rows.entries[self.rows.offsets[index]] = self.cursor;
                    self.rows.offsets[index] += 1;
                }
            }
        }
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
                try self.edgeStep(selection, .count, edges[self.cursor]);
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
                try self.edgeStep(selection, .degrees, edges[self.cursor]);
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
                try self.edgeStep(selection, .fill, edges[self.cursor]);
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

test "batched adjacency rows retain every scalar cursor and write boundary" {
    const eq = std.testing.expectEqualDeep;
    const edges = [_]t.Edge{
        .{ .from = @fromBackingInt(0), .to = @fromBackingInt(1), .operator = .directed, .first_connection = @fromBackingInt(0) },
        .{ .from = @fromBackingInt(1), .to = @fromBackingInt(0), .operator = .undirected, .first_connection = @fromBackingInt(1) },
        .{ .from = @fromBackingInt(2), .to = @fromBackingInt(2), .operator = .directed, .first_connection = @fromBackingInt(2) },
        .{ .from = @fromBackingInt(2), .to = @fromBackingInt(2), .operator = .undirected, .first_connection = @fromBackingInt(3) },
        .{ .from = @fromBackingInt(0), .to = @fromBackingInt(1), .operator = .directed, .first_connection = @fromBackingInt(4) },
    };
    inline for (.{ .forward, .backward, .all }) |selection| for (0..edges.len + 1) |length| for (1..24) |grant| {
        var scalar: Builder = .{};
        var batched: Builder = .{};
        var left_offsets: [32]u32 = @splat(0xabcd);
        var right_offsets = left_offsets;
        var left_entries: [16]u32 = @splat(0xdcba);
        var right_entries = left_entries;
        const left: Pools = .{ .offsets = &left_offsets, .entries = &left_entries };
        const right: Pools = .{ .offsets = &right_offsets, .entries = &right_entries };
        while (batched.phase != .done) {
            var step = batched.consume(selection, edges[0..length], 4, @intCast(grant));
            try eq(@as(?r.Error, null), step.failure);
            if (step.used == 0) {
                try batched.step(selection, edges[0..length], 4, undefined, right);
                step.used = 1;
            }
            for (0..step.used) |_| try scalar.step(selection, edges[0..length], 4, undefined, left);
            try eq(scalar, batched);
            try eq(left_offsets, right_offsets);
            try eq(left_entries, right_entries);
        }
    };
    var scalar: Builder = .{ .counts = .{ 0, none - 2, 0, 0 } };
    var batched = scalar;
    const repeated: [3]t.Edge = @splat(edges[0]);
    const stopped = batched.consume(.all, &repeated, 4, 3);
    try eq(@as(u32, 2), stopped.used);
    try eq(@as(?r.Error, error.IndexLimit), stopped.failure);
    try scalar.step(.all, &repeated, 4, undefined, null);
    try std.testing.expectError(error.IndexLimit, scalar.step(.all, &repeated, 4, undefined, null));
    try eq(scalar, batched);
}
