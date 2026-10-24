//! Endpoint suffix contributions. Written attributes and syntax stay untouched.
//! Two reserved internal IDs keep folded cells at 24 bytes; these are never
//! exposed as written attribute indices. Lowering checks that domain boundary.
const std = @import("std");
const attrs = @import("attributes.zig");
const t = @import("topology.zig");
const r = @import("resources.zig");
const encoding = @import("parser_support").encoding;
const PortSyntax = @import("../dot/syntax.zig").PortSyntax;

pub fn syntax(graph: anytype, reference: attrs.PortReference) PortSyntax {
    const connection = graph.connections[@backingInt(reference.connection)];
    return (if (reference.side == .left) connection.left.port else connection.right.port).?;
}

pub fn span(port: PortSyntax) t.Range {
    const end = port.second orelse port.first;
    return .{ .start = port.first.start, .len = end.start + end.len - port.first.start };
}

pub const Key = enum { tailport, headport };
pub const left = attrs.none - 1;
pub const right = attrs.none - 2;
pub const Selection = struct { attribute: u32, connection: t.ConnectionId };
pub const Keys = struct {
    ids: [2]u32 = .{ left, right },
    pub fn init(comptime caps: encoding.Capabilities, graph: anytype, work: anytype) r.Error!Keys {
        var result: Keys = .{};
        inline for (.{ Key.tailport, Key.headport }, 0..) |port_key, i|
            if (try attrs.findKey(caps, graph, .edge, @tagName(port_key), work)) |id| {
                result.ids[i] = id;
            };
        return result;
    }
    pub fn key(self: Keys, id: u32) ?Key {
        if (id == self.ids[0]) return .tailport;
        if (id == self.ids[1]) return .headport;
        return null;
    }
};

/// The supplied edge uses its first-creation orientation. Port-bearing ends
/// are always singletons, even when the other endpoint is a symbolic set.
pub fn suffixes(connection: t.Connection, id: t.ConnectionId, edge: t.Edge) [2]?Selection {
    var result: [2]?Selection = .{ null, null };
    const loop = edge.from == edge.to;
    if (connection.left.port != null) {
        const reversed = !loop and @backingInt(connection.left.members) & ~t.node_bit == @backingInt(edge.to);
        result[@intFromBool(reversed)] = .{ .attribute = left, .connection = id };
    }
    if (connection.right.port != null) {
        const reversed = !loop and @backingInt(connection.right.members) & ~t.node_bit == @backingInt(edge.from);
        result[@intFromBool(!reversed)] = .{ .attribute = right, .connection = id };
    }
    return result;
}

pub fn resolve(graph: anytype, selection: Selection, key: Key, empty: bool) attrs.Resolved {
    if (selection.attribute < right) return attrs.resolvedConnection(graph, selection.attribute, selection.connection);
    const connection = graph.connections[@backingInt(selection.connection)];
    const is_left = selection.attribute == left;
    return .{
        .value = if (empty) .empty else .{ .port = .{ .connection = selection.connection, .side = if (is_left) .left else .right } },
        .kind = if (empty) .empty else .derived,
        .attribute = null,
        .port_key = key,
        .origin = if (is_left) .{ .written_left_port = selection.connection } else .{ .written_right_port = selection.connection },
        .scope = graph.occurrences[@backingInt(connection.occurrence)].scope,
    };
}

/// Find a synthetic key's first actual introduction, not an overapproximation
/// from written sides. A reversed strict undirected suffix can introduce the
/// opposite key; an empty product introduces neither. This bounded query visits
/// only partners of port-bearing singletons, never allocates/expands a product.
/// Materialization discovers these introductions in its existing forward pass.
pub fn introduction(graph: anytype, wanted: Key, work: *r.Work) r.Error!?Selection {
    if (!graph.has_ports) return null;
    for (graph.connections, 0..) |connection, index| {
        try work.spend(1);
        const port_on_left = connection.left.port != null;
        if (!port_on_left and connection.right.port == null) continue;
        if (!graph.strict or connection.effective_operator == .directed) {
            if (wanted == .tailport and connection.left.port == null) continue;
            if (wanted == .headport and connection.right.port == null) continue;
        }
        const fixed = if (port_on_left) connection.left else connection.right;
        const other = if (port_on_left) connection.right else connection.left;
        const node: t.NodeId = @fromBackingInt(@backingInt(fixed.members) & ~t.node_bit);
        const id: t.ConnectionId = @fromBackingInt(@as(u32, @intCast(index)));
        const handle = @backingInt(other.members);
        if (handle & t.node_bit != 0) {
            if (try probe(graph, connection, id, node, @fromBackingInt(handle & ~t.node_bit), port_on_left, wanted, work)) |found| return found;
        } else {
            for (graph.bodies[graph.bodies[handle].first .. handle + 1]) |body| {
                try work.spend(1);
                for (graph.mentions[body.start..body.end]) |mention| {
                    try work.spend(1);
                    if (try probe(graph, connection, id, node, mention.node, port_on_left, wanted, work)) |found| return found;
                }
            }
        }
    }
    return null;
}

fn probe(graph: anytype, connection: t.Connection, id: t.ConnectionId, fixed: t.NodeId, other: t.NodeId, port_on_left: bool, wanted: Key, work: *r.Work) r.Error!?Selection {
    var edge: t.Edge = .{ .from = if (port_on_left) fixed else other, .to = if (port_on_left) other else fixed, .operator = connection.effective_operator, .first_connection = id };
    if (graph.strict and edge.operator == .undirected and fixed != other) {
        for (graph.connections[0 .. @backingInt(id) + 1]) |previous| {
            try work.spend(1);
            if (previous.effective_operator != edge.operator) continue;
            const forward = try graph.containsWork(previous.left.members, edge.from, work) and try graph.containsWork(previous.right.members, edge.to, work);
            const backward = try graph.containsWork(previous.left.members, edge.to, work) and try graph.containsWork(previous.right.members, edge.from, work);
            if (!forward and !backward) continue;
            // If both orientations occur in one product, its left endpoint's
            // first semantic member determines which pair was created first.
            if (backward and (!forward or try firstMember(graph, previous.left.members, edge.to, edge.from, work))) std.mem.swap(t.NodeId, &edge.from, &edge.to);
            break;
        }
    }
    return suffixes(connection, id, edge)[@backingInt(wanted)];
}

fn firstMember(graph: anytype, members: t.Membership, a: t.NodeId, b: t.NodeId, work: *r.Work) r.Error!bool {
    const handle = @backingInt(members);
    if (handle & t.node_bit != 0) return handle & ~t.node_bit == @backingInt(a);
    for (graph.bodies[graph.bodies[handle].first .. handle + 1]) |body| {
        try work.spend(1);
        for (graph.mentions[body.start..body.end]) |mention| {
            try work.spend(1);
            if (mention.node == a) return true;
            if (mention.node == b) return false;
        }
    }
    unreachable;
}
