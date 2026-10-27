//! Partial-only coverage, ordered by semantic traversal, not statement spelling.
const std = @import("std");
const t = @import("topology.zig");
const r = @import("resources.zig");

pub const Reason = enum { skipped_input, unfinished_input, unresolved_kind };
pub const Uncertainty = struct { reason: Reason, span: ?t.Range };
pub fn Knowledge(comptime T: type) type {
    const Candidate = switch (@typeInfo(T)) {
        .optional => T,
        else => ?T,
    };
    return union(enum) {
        known: T,
        unknown: struct { uncertainty: Uncertainty, retained: Candidate = null },
    };
}
pub const Gap = struct {
    reason: Reason,
    range: t.Range,
    occurrence: ?t.OccurrenceId,
};
pub const Entry = struct {
    gap: Gap,
    /// Number of declarations executed before this missing contribution.
    boundary: u32,
    /// Connections have their own semantic order (edge chains share attributes).
    connection_boundary: u32,
    /// Earliest source explanation at or after this entry (computed once).
    suffix_first: u32 = 0,
};
pub const Data = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Partial-only dependency summary. Hidden scope members can affect a
    /// later set-endpoint connection even when the gap precedes its winner.
    last_set_connection: ?u32 = null,

    pub fn observeConnection(self: *Data, id: u32, connection: t.Connection) void {
        if (@backingInt(connection.left.members) & t.node_bit == 0 or
            @backingInt(connection.right.members) & t.node_bit == 0)
            self.last_set_connection = id;
    }

    pub fn add(self: *Data, a: anytype, gap: Gap, boundary: usize, connections: u32, work: *r.Work) r.Error!void {
        try work.spend(1);
        _ = try r.index(self.entries.items.len + 1);
        try @import("lowering_storage.zig").append(a, &self.entries, .{ .gap = gap, .boundary = try r.index(boundary), .connection_boundary = connections }, "gaps");
    }
    pub fn finish(self: *Data, work: *r.Work) r.Error!void {
        var i = self.entries.items.len;
        var first: u32 = 0;
        while (i != 0) {
            i -= 1;
            try work.spend(1);
            const current = &self.entries.items[i];
            if (i + 1 == self.entries.items.len or current.gap.range.start <= self.entries.items[first].gap.range.start) first = @intCast(i);
            current.suffix_first = first;
        }
    }
    pub fn deinit(self: *Data, a: std.mem.Allocator) void {
        self.entries.deinit(a);
    }
    pub fn retainedBytes(self: *const Data) usize {
        return self.entries.capacity * @sizeOf(Entry);
    }
    /// No scan on a query: binary search the precomputed semantic boundaries.
    pub fn uncertainty(self: *const Data, after: ?u32) ?Uncertainty {
        return self.uncertaintyWith(after, @import("../dot/identifier_cursor.zig").Unmetered{}) catch unreachable;
    }
    pub inline fn uncertaintyWith(self: *const Data, after: ?u32, work: anytype) r.Error!?Uncertainty {
        return self.afterWith("boundary", after, work);
    }
    pub inline fn afterConnectionWith(self: *const Data, connection: u32, work: anytype) r.Error!?Uncertainty {
        return self.afterWith("connection_boundary", connection, work);
    }
    fn afterWith(self: *const Data, comptime field: []const u8, after: ?u32, work: anytype) r.Error!?Uncertainty {
        const entries = self.entries.items;
        var lo: usize = 0;
        if (after) |declaration| {
            var hi = entries.len;
            while (lo < hi) {
                try work.spend(1);
                const mid = lo + (hi - lo) / 2;
                if (@field(entries[mid], field) <= declaration) lo = mid + 1 else hi = mid;
            }
        }
        if (lo == entries.len) return null;
        const gap = entries[entries[lo].suffix_first].gap;
        return .{ .reason = gap.reason, .span = gap.range };
    }
};
