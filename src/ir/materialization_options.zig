//! Compile-time output identity; execution remains runtime data.
const std = @import("std");
const r = @import("resources.zig");

pub const Adjacency = enum { none, forward, backward, all };
pub const Selection = struct { attributes: bool, adjacency: Adjacency = .none };
pub const Direction = enum { all, incoming, outgoing, undirected, forward, backward };
pub const EdgeOptions = struct { direction: Direction = .all };

pub inline fn selection(comptime attributes: bool, value: anytype) Selection {
    const selected: Selection = comptime .{
        .attributes = if (@hasField(@TypeOf(value), "attributes")) value.attributes else attributes,
        .adjacency = if (@hasField(@TypeOf(value), "adjacency")) value.adjacency else .none,
    };
    if (selected.attributes) comptime @import("representation.zig").requireAttributes(attributes);
    return selected;
}
pub fn checkSelection(comptime value: anytype) void {
    comptime for (@typeInfo(@TypeOf(value)).@"struct".field_names) |field| {
        if (!std.mem.eql(u8, field, "attributes") and !std.mem.eql(u8, field, "adjacency"))
            @compileError("unknown IR materialization selection: " ++ field);
    };
}
pub inline fn options(comptime selected: Selection, value: anytype) r.Options {
    @setEvalBranchQuota(3000);
    comptime for (@typeInfo(@TypeOf(value)).@"struct".field_names) |field| {
        if (!std.mem.eql(u8, field, "attributes") and !std.mem.eql(u8, field, "adjacency") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation"))
            @compileError("unknown IR materialization option: " ++ field);
    };
    if (@hasField(@TypeOf(value), "attributes")) if (comptime value.attributes != selected.attributes)
        @compileError("materialization attributes must match output storage");
    if (@hasField(@TypeOf(value), "adjacency")) if (comptime value.adjacency != selected.adjacency)
        @compileError("materialization adjacency must match output storage");
    return .{
        .limits = if (@hasField(@TypeOf(value), "limits")) optionalOption(r.Limits, value.limits) else null,
        .cancellation = if (@hasField(@TypeOf(value), "cancellation")) optionalOption(r.Cancellation, value.cancellation) else null,
    };
}

fn optionalOption(comptime T: type, value: anytype) ?T {
    if (@TypeOf(value) == T) return value;
    switch (@typeInfo(@TypeOf(value))) {
        .null => return null,
        .optional => return if (value) |payload| optionalOption(T, payload) else null,
        else => {},
    }
    comptime for (@typeInfo(@TypeOf(value)).@"struct".field_names) |field| {
        if (!@hasField(T, field)) @compileError("unknown IR materialization option field: " ++ field);
    };
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, Field, attr| {
        @field(result, name) = if (@hasField(@TypeOf(value), name)) @field(value, name) else if (attr.default_value_ptr) |ptr| @as(*const Field, @ptrCast(@alignCast(ptr))).* else @compileError("missing IR materialization option field: " ++ name);
    }
    return result;
}

/// Internal categories: outgoing non-loops, incoming non-loops, undirected,
/// directed loops. A query selects each category at most once.
pub fn mask(comptime selected: Adjacency, comptime query: EdgeOptions) u4 {
    const result: u4 = switch (query.direction) {
        .all => 0b1111,
        .outgoing => 0b1001,
        .incoming => 0b1010,
        .undirected => 0b0100,
        .forward => 0b1101,
        .backward => 0b1110,
    };
    const available: u4 = switch (selected) {
        .none => 0,
        .forward => 0b1101,
        .backward => 0b1110,
        .all => 0b1111,
    };
    if (result & ~available != 0) @compileError("edge direction requires an adjacency selection that supports it");
    return result;
}
