//! One dispatch per source, outside the scanner and grammar hot loops.
const std = @import("std");
const encoding = @import("encoding.zig");

pub fn Options(comptime Base: type) type {
    const fields = @typeInfo(Base).@"struct";
    const count = fields.field_names.len;
    var names: [count + 1][:0]const u8 = undefined;
    var types: [count + 1]type = undefined;
    var attrs: [count + 1]std.lang.Type.Struct.FieldAttributes = undefined;
    for (fields.field_names, fields.field_types, fields.field_attrs, 0..) |name, T, attr, i| {
        names[i] = name;
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = attr.default_value_ptr };
    }
    names[count] = "encoding";
    types[count] = ?encoding.Actual;
    attrs[count] = .{ .default_value_ptr = &@as(?encoding.Actual, null) };
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Copy typed option fields, not layouts. All target option fields have defaults.
pub fn options(comptime T: type, value: anytype) T {
    if (T == @TypeOf(value)) return value;
    var result: T = .{};
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types) |name, Field| {
        if (@hasField(@TypeOf(value), name)) {
            const v = @field(value, name);
            @field(result, name) = if (Field == @TypeOf(v)) v else options(Field, v);
        }
    }
    return result;
}

/// Framing is checked by encoding.select. Content validity belongs to each
/// processor's invalid_encoding policy, not an unconditional admission pass.
pub fn checkCancellation(cancellation: anytype) encoding.InputError!void {
    if (@TypeOf(cancellation) != void) {
        if (cancellation) |hook| if (hook.requested()) return error.Cancelled;
    }
}

pub fn stamp(value: anytype, info: encoding.Info) void {
    const T = @TypeOf(value.*);
    if (@hasField(T, "document")) {
        if (value.document) |*document| document.source_info = info;
    } else if (@hasField(T, "parse")) {
        stamp(&value.parse, info);
    } else if (@hasField(T, "dot")) {
        stamp(&value.dot, info);
    }
}
