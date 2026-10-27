//! Bounded attribute-query primitives. No allocation or independent work budget.
const std = @import("std");
const t = @import("topology.zig");
const a = @import("attributes.zig");
const ports = @import("ports.zig");
const r = @import("resources.zig");
const encoding = @import("parser_support").encoding;
const Member = @import("query_session.zig").MembershipCursor;

/// Query hashing is incremental; collision equality reads one trusted source
/// name unit/output byte at a time, including concatenation/comment glue.
pub fn Key(comptime caps: encoding.Capabilities) type {
    return struct {
        const Self = @This();
        bytes: []const u8,
        kind: a.Kind,
        offset: usize = 0,
        hasher: std.hash.Wyhash = std.hash.Wyhash.init(0),
        hash: u64 = 0,
        slot: usize = 0,
        found: ?u32 = null,
        name: @import("lowering_primitives.zig").Name(caps) = .{},
        phase: enum { hash, probe, compare } = .hash,

        pub fn step(self: *Self, graph: anytype) r.Error!bool {
            const store = &graph.attribute_data;
            switch (self.phase) {
                .hash => {
                    if (store.table.slots.len == 0) return true;
                    if (self.offset < self.bytes.len) {
                        const end = self.offset + @min(64, self.bytes.len - self.offset);
                        self.hasher.update(self.bytes[self.offset..end]);
                        self.offset = end;
                    } else {
                        self.hash = self.hasher.final() ^ @as(u64, @backingInt(self.kind));
                        self.slot = @intCast(self.hash & (store.table.slots.len - 1));
                        self.phase = .probe;
                    }
                },
                .probe => {
                    const id = store.table.slots[self.slot];
                    if (id == a.none) return true;
                    const key = store.keys.items[id];
                    if (key.hash == self.hash and key.kind == self.kind) {
                        self.name = .{ .raw = graph.text(key.name), .actual = @import("names.zig").reader(caps, graph.source_info.encoding) };
                        self.offset = 0;
                        self.phase = .compare;
                    } else self.slot = (self.slot + 1) & (store.table.slots.len - 1);
                },
                .compare => switch (try self.name.step()) {
                    .pending => {},
                    .end => {
                        if (self.offset == self.bytes.len) {
                            self.found = store.table.slots[self.slot];
                            return true;
                        }
                        self.mismatch(store.table.slots.len);
                    },
                    .byte => |byte| {
                        if (self.offset == self.bytes.len or self.bytes[self.offset] != byte) self.mismatch(store.table.slots.len) else self.offset += 1;
                    },
                },
            }
            return false;
        }
        fn mismatch(self: *Self, length: usize) void {
            self.slot = (self.slot + 1) & (length - 1);
            self.phase = .probe;
        }
    };
}

/// Both orientations are needed only for synthetic port introduction. Ordinary
/// contribution checks can finish at the first forward witness.
pub const Covers = struct {
    edge: t.Edge,
    both: bool = false,
    forward: bool = false,
    member: Member = undefined,
    phase: enum { start, left, right, reverse, reverse_left, reverse_right } = .start,
    pub const Result = struct { forward: bool = false, backward: bool = false };

    pub fn step(self: *Covers, graph: anytype, connection: t.Connection) ?Result {
        switch (self.phase) {
            .start => {
                if (connection.effective_operator != self.edge.operator) return .{};
                self.member = .{ .members = @backingInt(connection.left.members), .node = @backingInt(self.edge.from) };
                self.phase = .left;
            },
            .left, .right, .reverse_left, .reverse_right => {
                const found = self.member.step(graph) orelse return null;
                switch (self.phase) {
                    .left => {
                        if (found) {
                            self.member = .{ .members = @backingInt(connection.right.members), .node = @backingInt(self.edge.to) };
                            self.phase = .right;
                        } else self.phase = .reverse;
                    },
                    .right => {
                        self.forward = found;
                        if (found and !self.both) return .{ .forward = true };
                        self.phase = .reverse;
                    },
                    .reverse_left => if (found) {
                        self.member = .{ .members = @backingInt(connection.right.members), .node = @backingInt(self.edge.from) };
                        self.phase = .reverse_right;
                    } else return .{ .forward = self.forward },
                    .reverse_right => return .{ .forward = self.forward, .backward = found },
                    else => unreachable,
                }
            },
            .reverse => {
                if (self.edge.operator != .undirected) return .{ .forward = self.forward };
                self.member = .{ .members = @backingInt(connection.left.members), .node = @backingInt(self.edge.to) };
                self.phase = .reverse_left;
            },
        }
        return null;
    }
};

/// Source-order member occurrences, without deduplication or pair expansion.
const Members = struct {
    handle: u32,
    body: u32 = 0,
    index: u32 = 0,
    end: u32 = 0,
    phase: enum { start, body, mention, done } = .start,
    const Step = union(enum) { pending, end, node: t.NodeId };
    fn step(self: *Members, graph: anytype) Step {
        switch (self.phase) {
            .start => {
                if (self.handle & t.node_bit != 0) {
                    self.phase = .done;
                    return .{ .node = @fromBackingInt(self.handle & ~t.node_bit) };
                }
                self.body = graph.bodies[self.handle].first;
                self.phase = .body;
            },
            .body => {
                const body = graph.bodies[self.body];
                self.index = body.start;
                self.end = body.end;
                self.phase = .mention;
            },
            .mention => {
                if (self.index < self.end) {
                    const node = graph.mentions[self.index].node;
                    self.index += 1;
                    return .{ .node = node };
                }
                if (self.body == self.handle) return .end;
                self.body += 1;
                self.phase = .body;
            },
            .done => return .end,
        }
        return .pending;
    }
};

/// Resumable counterpart of ports.introduction. Only port-bearing singleton
/// partners are inspected; even strict orientation checks stay symbolic.
pub const Introduction = struct {
    wanted: ports.Key,
    found: ?ports.Selection = null,
    connection: u32 = 0,
    previous: u32 = 0,
    left: bool = false,
    fixed: t.NodeId = undefined,
    edge: t.Edge = undefined,
    members: Members = undefined,
    order: Members = undefined,
    covers: Covers = undefined,
    phase: enum { connection, partner, previous, compare, order, suffix } = .connection,

    pub fn step(self: *Introduction, graph: anytype) bool {
        switch (self.phase) {
            .connection => {
                if (!graph.has_ports or self.connection == graph.connections.len) return true;
                const c = graph.connections[self.connection];
                self.left = c.left.port != null;
                if ((!self.left and c.right.port == null) or
                    ((!graph.strict or c.effective_operator == .directed) and
                        ((self.wanted == .tailport and !self.left) or (self.wanted == .headport and c.right.port == null))))
                {
                    self.connection += 1;
                    return false;
                }
                self.fixed = @fromBackingInt(@backingInt((if (self.left) c.left else c.right).members) & ~t.node_bit);
                self.members = .{ .handle = @backingInt((if (self.left) c.right else c.left).members) };
                self.phase = .partner;
            },
            .partner => switch (self.members.step(graph)) {
                .pending => {},
                .end => {
                    self.connection += 1;
                    self.phase = .connection;
                },
                .node => |other| {
                    self.edge = .{ .from = if (self.left) self.fixed else other, .to = if (self.left) other else self.fixed, .operator = graph.connections[self.connection].effective_operator, .first_connection = @fromBackingInt(self.connection) };
                    self.previous = 0;
                    self.phase = if (graph.strict and self.edge.operator == .undirected and self.edge.from != self.edge.to) .previous else .suffix;
                },
            },
            .previous => {
                if (self.previous > self.connection) unreachable;
                self.covers = .{ .edge = self.edge, .both = true };
                self.phase = .compare;
            },
            .compare => if (self.covers.step(graph, graph.connections[self.previous])) |result| {
                if (!result.forward and !result.backward) {
                    self.previous += 1;
                    self.phase = .previous;
                } else if (result.backward and result.forward) {
                    self.order = .{ .handle = @backingInt(graph.connections[self.previous].left.members) };
                    self.phase = .order;
                } else {
                    if (result.backward) std.mem.swap(t.NodeId, &self.edge.from, &self.edge.to);
                    self.phase = .suffix;
                }
            },
            .order => switch (self.order.step(graph)) {
                .pending => {},
                .end => unreachable,
                .node => |node| {
                    if (node == self.edge.to) {
                        std.mem.swap(t.NodeId, &self.edge.from, &self.edge.to);
                        self.phase = .suffix;
                    } else if (node == self.edge.from) self.phase = .suffix;
                },
            },
            .suffix => {
                self.found = ports.suffixes(graph.connections[self.connection], @fromBackingInt(self.connection), self.edge)[@backingInt(self.wanted)];
                if (self.found != null) return true;
                self.phase = .partner;
            },
        }
        return false;
    }
};
