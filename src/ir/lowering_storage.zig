//! Compile-time storage dispatch. Ordinary lowering retains ordinary ArrayList
//! growth; fixed lowering checks and writes its prebound pools, with no allocator.
const std = @import("std");
const r = @import("resources.zig");
pub inline fn append(a: anytype, list: anytype, value: std.meta.Elem(@TypeOf(list.items)), comptime field: []const u8) r.Error!void {
    if (@TypeOf(a) == std.mem.Allocator) return list.append(a, value);
    try a.ensure(field, list.items.len + 1);
    list.appendAssumeCapacity(value);
    a.observe(field, list.items.len);
}
pub inline fn allocate(comptime T: type, a: anytype, count: usize, comptime field: []const u8, comptime metered: bool) r.Error![]T {
    if (@TypeOf(a) == std.mem.Allocator) {
        return if (metered) @import("session_storage.zig").allocate(T, a, count) else a.alloc(T, count);
    }
    try a.ensure(field, count);
    return a.slice(field)[0..count];
}
pub inline fn prepareTable(table: *@import("names.zig").Table, a: anytype, work: *r.Work, owner: anytype, comptime field: []const u8) r.Error!void {
    if (@TypeOf(a) == std.mem.Allocator) return table.prepare(a, work, owner);
    try a.ensureTable(field, table.count + 1);
    if (table.slots.len != 0) return;
    table.slots = a.slice(field);
    for (table.slots) |*slot| {
        try work.spend(1);
        slot.* = @import("names.zig").empty;
    }
}
