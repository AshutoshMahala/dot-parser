//! Explicit conservative sizing. Metadata is constant time; the optional scan
//! charges each connection/body visit, including repeated reopened endpoints.
const std = @import("std");
const r = @import("resources.zig");
const t = @import("topology.zig");
const s = @import("materialization_storage.zig");
const q = @import("query_storage.zig");

fn mul(a: u64, b: u64, cap: u64) u64 {
    if (a == 0 or b == 0) return 0;
    return if (a > cap / b) cap else @min(a * b, cap);
}
fn add(a: u64, b: u64, cap: u64) u64 {
    return if (a >= cap or b >= cap - a) cap else a + b;
}
fn count(value: u64) r.Error!u32 {
    if (value >= std.math.maxInt(u32)) return error.IndexLimit;
    return @intCast(value);
}
fn members(graph: anytype, handle: t.Membership, work: *r.Work) r.Error!u64 {
    const id = @backingInt(handle);
    if (id & t.node_bit != 0) return 1;
    var total: u64 = 0;
    for (graph.bodies[graph.bodies[id].first .. id + 1]) |body| {
        try work.spend(1);
        total = add(total, body.end - body.start, graph.nodes.len);
    }
    return total;
}
pub fn bounds(comptime selection: @import("materialization_options.zig").Selection, input: anytype, options: r.Options, comptime scan: bool) r.Error!s.Bounds {
    const attributes = selection.attributes;
    const graph = q.data(input);
    if (attributes) comptime @import("representation.zig").requireAttributes(@TypeOf(graph.*).capabilities.attributes);
    const limits = options.limits orelse graph.limits;
    const n: u64 = graph.nodes.len;
    const c: u64 = graph.connections.len;
    const keys: u64 = if (attributes) graph.attribute_data.keys.items.len + @as(u64, if (graph.has_ports) 2 else 0) else 0;
    const universe = if (graph.kind == .undigraph) mul(n, n + 1, std.math.maxInt(u64)) / 2 else mul(n, n, std.math.maxInt(u64));
    var pairs: u64 = if (scan) 0 else mul(c, mul(n, n, limits.max_pairs), limits.max_pairs);
    var cells: u64 = if (scan) 0 else limits.max_attribute_states;
    var scratch_members: u64 = if (scan or c == 0) 0 else n * 2;
    if (scan) {
        var work = try r.Work.init(limits, options.cancellation);
        for (graph.connections) |connection| {
            try work.spend(1);
            const left = try members(graph, connection.left.members, &work);
            const right = try members(graph, connection.right.members, &work);
            const product = mul(left, right, limits.max_pairs);
            pairs = add(pairs, product, limits.max_pairs);
            if (attributes) {
                const suffixes: u64 = @as(u64, @intFromBool(connection.left.port != .none)) + @intFromBool(connection.right.port != .none);
                cells = add(cells, mul(product, connection.attributes.len + suffixes, limits.max_attribute_states), limits.max_attribute_states);
            }
            const l = if (@backingInt(connection.left.members) & t.node_bit != 0) 0 else left;
            const rr = if (@backingInt(connection.right.members) & t.node_bit != 0) 0 else right;
            scratch_members = @max(scratch_members, l + rr);
        }
        try work.spend(0); // Poll after empty input and before publishing bounds.
    }
    const edges = @min(pairs, limits.max_edges, if (graph.strict) universe else std.math.maxInt(u64));
    return .{
        .output = .{
            .edges = try count(edges),
            .attribute_states = if (attributes) try count(@min(cells, mul(edges, keys, limits.max_attribute_states))) else 0,
            .attribute_keys = if (attributes and edges != 0) try count(keys) else 0,
            .adjacency_offsets = if (selection.adjacency == .none or edges == 0) 0 else try count((n + 1) * @as(u64, if (selection.adjacency == .all) 4 else 3)),
            .adjacency_entries = if (selection.adjacency == .none) 0 else try count(edges * 2),
        },
        .scratch = .{ .members = try count(scratch_members) },
    };
}
