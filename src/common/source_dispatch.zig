//! One dispatch per source, outside the scanner and grammar hot loops.
const std = @import("std");
const encoding = @import("encoding.zig");

pub fn Options(comptime Base: type) type {
    const fields = std.meta.fields(Base);
    var names: [fields.len + 1][:0]const u8 = undefined;
    var types: [fields.len + 1]type = undefined;
    var attrs: [fields.len + 1]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{ .default_value_ptr = field.default_value_ptr };
    }
    names[fields.len] = "encoding";
    types[fields.len] = ?encoding.Actual;
    attrs[fields.len] = .{ .default_value_ptr = &@as(?encoding.Actual, null) };
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Copy typed option fields, not layouts. All target option fields have defaults.
pub fn options(comptime T: type, value: anytype) T {
    if (T == @TypeOf(value)) return value;
    var result: T = .{};
    inline for (std.meta.fields(T)) |field| {
        if (@hasField(@TypeOf(value), field.name)) {
            const v = @field(value, field.name);
            @field(result, field.name) = if (field.type == @TypeOf(v)) v else options(field.type, v);
        }
    }
    return result;
}

/// Native code units are framing, not arbitrary UTF-8 payload bytes. Reject
/// unpaired surrogates/out-of-range scalars before exposing a native document.
/// No allocation, decoding buffer, normalization or source map is involved.
pub fn check(comptime actual: encoding.Actual, source: []const u8) encoding.InputError!void {
    return checkControlled(actual, source, {});
}

pub fn checkControlled(comptime actual: encoding.Actual, source: []const u8, cancellation: anytype) encoding.InputError!void {
    if (actual == .utf8) return; // Existing optional UTF-8 validation contract.
    const reader = encoding.Reader(actual);
    var at: usize = 0;
    var next_poll: usize = 0;
    while (at < source.len) {
        if (@TypeOf(cancellation) != void) if (at >= next_poll) {
            if (cancellation) |hook| if (hook.requested()) return error.Cancelled;
            next_poll = at +| 256;
        };
        const decoded = reader.decode(source, at) catch return error.InvalidEncoding;
        at += decoded.len;
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
