//! Connections and their sparse ports share one allocation. Sizes are known
//! together; grouping avoids an extra allocation and reduces arena chunk waste.
const std = @import("std");
const t = @import("topology.zig");
const syntax = @import("../dot/syntax.zig");
const r = @import("resources.zig");
const storage = @import("session_storage.zig");

pub const Pools = struct {
    connections: []t.Connection,
    endpoint_ports: []syntax.PortSyntax,
};

// Both schemas contain only u32-aligned fields. No inter-pool padding or
// separate allocation descriptor is needed; retained byte accounting is exact.
comptime {
    for (.{ t.Connection, syntax.PortSyntax }) |T| {
        if (@alignOf(T) != @alignOf(u32) or @sizeOf(T) % @sizeOf(u32) != 0)
            @compileError("topology pool layout needs explicit padding/alignment");
    }
}

pub fn allocate(a: std.mem.Allocator, connections: usize, ports: usize, comptime metered: bool) r.Error!Pools {
    const c = std.math.mul(usize, connections, @sizeOf(t.Connection) / 4) catch return error.IndexLimit;
    const p = std.math.mul(usize, ports, @sizeOf(syntax.PortSyntax) / 4) catch return error.IndexLimit;
    const count = std.math.add(usize, c, p) catch return error.IndexLimit;
    _ = std.math.mul(usize, count, @sizeOf(u32)) catch return error.IndexLimit;
    const words = if (metered) try storage.allocate(u32, a, count) else try a.alloc(u32, count);
    return .{
        .connections = region(t.Connection, words[0..c]),
        .endpoint_ports = region(syntax.PortSyntax, words[c..]),
    };
}

fn region(comptime T: type, words: []u32) []T {
    if (words.len == 0) return &.{};
    return @as([*]T, @ptrCast(words.ptr))[0 .. words.len / (@sizeOf(T) / 4)];
}

/// Accepts either builder slices or the immutable published slices. Fixed
/// graphs never call this: their regions belong to the caller's reservation.
pub fn release(a: std.mem.Allocator, owner: anytype) void {
    const count = (owner.connections.len * @sizeOf(t.Connection) + owner.endpoint_ports.len * @sizeOf(syntax.PortSyntax)) / 4;
    if (count == 0) return;
    const start: [*]const u32 = if (owner.connections.len != 0)
        @ptrCast(owner.connections.ptr)
    else
        @ptrCast(owner.endpoint_ports.ptr);
    // Allocation checked the combined size. Every descriptor is published
    // together and keeps its full length, including on interrupted builds.
    storage.release(u32, a, @constCast(start[0..count]));
}
