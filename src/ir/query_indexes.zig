//! Optional symbolic-query acceleration. Every posting is a connection ID;
//! endpoint memberships and Cartesian products are never expanded here.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");
const mem = @import("lowering_storage.zig");
const Indexes = @import("representation.zig").Indexes;
const none = std.math.maxInt(u32);

pub fn Data(comptime selection: Indexes) type {
    if (!selection.any()) return void;
    return struct {
        left_offsets: if (selection.connections) []u32 else void = if (selection.connections) &.{} else {},
        right_offsets: if (selection.connections) []u32 else void = if (selection.connections) &.{} else {},
        left_entries: if (selection.connections) []u32 else void = if (selection.connections) &.{} else {},
        right_entries: if (selection.connections) []u32 else void = if (selection.connections) &.{} else {},
        scope_memberships: if (selection.scope_memberships) []t.Membership else void = if (selection.scope_memberships) &.{} else {},
        left_singletons: if (selection.connections) u32 else void = if (selection.connections) 0 else {},
        right_singletons: if (selection.connections) u32 else void = if (selection.connections) 0 else {},
        undirected: if (selection.connections) bool else void = if (selection.connections) false else {},
    };
}

pub const slice_fields = .{ "left_offsets", "right_offsets", "left_entries", "right_entries", "scope_memberships" };
pub fn release(a: std.mem.Allocator, data: anytype) void {
    if (@TypeOf(data.*) == void) return;
    inline for (slice_fields) |field| if (@FieldType(@TypeOf(data.*), field) != void) a.free(@field(data, field));
}
pub fn bytes(data: anytype) usize {
    if (@TypeOf(data.*) == void) return 0;
    var n: usize = 0;
    inline for (slice_fields) |field| if (@FieldType(@TypeOf(data.*), field) != void) {
        const slice = @field(data, field);
        n += slice.len * @sizeOf(std.meta.Elem(@TypeOf(slice)));
    };
    return n;
}
fn singleton(member: t.Membership) ?u32 {
    const id = @backingInt(member);
    return if (id & t.node_bit != 0) id & ~t.node_bit else null;
}

// At most four sorted lists: singleton/fallback for each requested orientation.
// One next() merges their heads and deduplicates in constant bounded work.
pub const Cursor = struct {
    lists: [4][]const u32,
    positions: [4]u32 = @splat(0),

    pub inline fn next(self: *Cursor) ?u32 {
        var heads: [4]u32 = undefined;
        inline for (0..4) |i| heads[i] = if (self.positions[i] < self.lists[i].len) self.lists[i][self.positions[i]] else none;
        const id = @min(heads[0], heads[1], heads[2], heads[3]);
        if (id == none) return null;
        inline for (0..4) |i| self.positions[i] += @intFromBool(heads[i] == id);
        return id;
    }
};
const Choice = struct {
    posted: []const u32 = &.{},
    groups: []const u32 = &.{},
    count: usize,
};
fn side(data: anytype, comptime left: bool, node: t.NodeId, total: usize) Choice {
    const offsets = if (left) data.left_offsets else data.right_offsets;
    if (offsets.len == 0) return .{ .count = total };
    const entries = if (left) data.left_entries else data.right_entries;
    const singles = if (left) data.left_singletons else data.right_singletons;
    const id = @backingInt(node);
    const posted = entries[offsets[id]..offsets[id + 1]];
    const groups = entries[singles..];
    return .{ .posted = posted, .groups = groups, .count = posted.len + groups.len };
}
fn best(data: anytype, from: t.NodeId, to: t.NodeId, total: usize) Choice {
    const left = side(data, true, from, total);
    const right = side(data, false, to, total);
    return if (left.count <= right.count) left else right;
}
/// O(1), after handle admission. Null selects the ordinary bounded scan. A
/// wholly symbolic side denotes ALL connections; it cannot prove absence.
pub inline fn select(graph: anytype, from: t.NodeId, to: t.NodeId) ?Cursor {
    const total = graph.connections.len;
    if (total < 8) return null;
    const data = graph.queryIndexes();
    const forward = best(data, from, to, total);
    const reverse = if (data.undirected and from != to) best(data, to, from, total) else Choice{ .count = 0 };
    // Difference form avoids overflowing usize on 32-bit targets. Broad
    // histories stay on the contiguous scan; no budget is restarted.
    const threshold = (total + 1) / 2;
    if (forward.count >= threshold or reverse.count >= threshold - forward.count) return null;
    return .{ .lists = .{ forward.posted, forward.groups, reverse.posted, reverse.groups } };
}

/// Optional contribution traversal. Call sites retain their ordinary for-loop
/// when disabled, including its range proof and usize induction variable.
pub const Scan = struct {
    index: usize,
    end: usize,
    cursor: ?Cursor,
    pub inline fn init(graph: anytype, start: usize, end: usize, from: t.NodeId, to: t.NodeId, use_index: bool) @This() {
        return .{ .index = start, .end = end, .cursor = if (use_index) select(graph, from, to) else null };
    }
    pub inline fn next(self: *@This()) ?usize {
        if (self.cursor) |*cursor| {
            const id = cursor.next() orelse return null;
            return if (id < self.end) id else null;
        }
        if (self.index == self.end) return null;
        const id = self.index;
        self.index += 1;
        return id;
    }
};

/// Shared bounded builder. Each step allocates one pool or visits one record /
/// offset; direct lowering drains it, sessions charge and pause around it.
pub fn Builder(comptime selection: Indexes) type {
    return struct {
        const Self = @This();
        const Phase = enum { scopes_allocate, scopes_fill, count, allocate_offsets, allocate_entries, clear, count_side, prefix, fill, restore, done };
        phase: Phase = if (selection.scope_memberships) .scopes_allocate else .count,
        index: u32 = 0,
        group: u32 = 0,
        right: bool = false,

        pub fn step(self: *Self, b: anytype, comptime metered: bool) r.Error!bool {
            const data = b.queryIndexes();
            if (self.phase == .scopes_allocate or self.phase == .scopes_fill) {
                if (comptime selection.scope_memberships) {
                    if (self.phase == .scopes_allocate) {
                        data.scope_memberships = try mem.allocate(t.Membership, b.a, b.scopes.items.len, "scope_memberships", metered);
                        self.phase = .scopes_fill;
                    } else if (self.index < b.occurrences.len) {
                        const occurrence = b.occurrences[self.index];
                        data.scope_memberships[@backingInt(occurrence.scope)] = occurrence.membership;
                        self.index += 1;
                    } else {
                        self.index = 0;
                        self.phase = .count;
                    }
                    return false;
                } else unreachable;
            }
            if (comptime !selection.connections) return true;
            if (self.phase == .count) {
                if (b.connections.len < 8) return true;
                if (self.index < b.connections.len) {
                    const c = b.connections[self.index];
                    data.left_singletons += @intFromBool(singleton(c.left.members) != null);
                    data.right_singletons += @intFromBool(singleton(c.right.members) != null);
                    data.undirected = data.undirected or c.effective_operator == .undirected;
                    self.index += 1;
                } else {
                    self.index = 0;
                    self.phase = .allocate_offsets;
                }
                return false;
            }
            return if (self.right) self.sideStep(b, metered, false) else self.sideStep(b, metered, true);
        }
        fn sideStep(self: *Self, b: anytype, comptime metered: bool, comptime left: bool) r.Error!bool {
            const data = b.queryIndexes();
            const offsets = if (left) &data.left_offsets else &data.right_offsets;
            const entries = if (left) &data.left_entries else &data.right_entries;
            const singles = if (left) data.left_singletons else data.right_singletons;
            if (self.phase == .allocate_offsets and singles == 0) return self.nextSide();
            switch (self.phase) {
                .allocate_offsets => {
                    offsets.* = try mem.allocate(u32, b.a, b.nodes.items.len + 1, if (left) "left_offsets" else "right_offsets", metered);
                    self.phase = .allocate_entries;
                },
                .allocate_entries => {
                    entries.* = try mem.allocate(u32, b.a, b.connections.len, if (left) "left_entries" else "right_entries", metered);
                    self.phase = .clear;
                },
                .clear => {
                    if (self.index == offsets.len) {
                        self.index = 0;
                        self.phase = .count_side;
                        return false;
                    }
                    offsets.*[self.index] = 0;
                    self.index += 1;
                },
                .count_side => {
                    if (self.index == b.connections.len) {
                        self.index = 1;
                        self.phase = .prefix;
                        return false;
                    }
                    const c = b.connections[self.index];
                    if (singleton(if (left) c.left.members else c.right.members)) |node| offsets.*[node + 1] += 1;
                    self.index += 1;
                },
                .prefix => {
                    if (self.index == offsets.len) {
                        self.index = 0;
                        self.group = singles;
                        self.phase = .fill;
                        return false;
                    }
                    offsets.*[self.index] += offsets.*[self.index - 1];
                    self.index += 1;
                },
                .fill => {
                    if (self.index == b.connections.len) {
                        self.index = @intCast(offsets.len - 1);
                        self.phase = .restore;
                        return false;
                    }
                    const c = b.connections[self.index];
                    if (singleton(if (left) c.left.members else c.right.members)) |node| {
                        const cursor = &offsets.*[node];
                        entries.*[cursor.*] = self.index;
                        cursor.* += 1;
                    } else {
                        entries.*[self.group] = self.index;
                        self.group += 1;
                    }
                    self.index += 1;
                },
                .restore => {
                    if (self.index == 0) {
                        offsets.*[0] = 0;
                        return self.nextSide();
                    }
                    offsets.*[self.index] = offsets.*[self.index - 1];
                    self.index -= 1;
                },
                .done => return true,
                else => unreachable,
            }
            return false;
        }
        fn nextSide(self: *Self) bool {
            if (self.right) {
                self.phase = .done;
                return true;
            }
            self.right = true;
            self.index = 0;
            self.phase = .allocate_offsets;
            return false;
        }
    };
}
