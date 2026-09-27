//! Markup-owned behavioral settings. Resources are passed separately.
const std = @import("std");

pub const Policy = struct {
    limits: struct {
        max_source_bytes: ?u32 = null,
        max_nesting: ?u32 = null,
        /// Elements plus nonempty text runs, independent of retained storage.
        max_nodes: ?u32 = null,
    } = .{},
    execution: struct {
        metering: ?bool = null,
        cancellation: ?bool = null,
    } = .{},
};
pub const Limits = struct {
    max_source_bytes: u32 = std.math.maxInt(u32),
    max_nesting: u32 = std.math.maxInt(u32),
    max_nodes: u32 = std.math.maxInt(u32),
};
pub const Effective = struct {
    limits: Limits = .{},
    execution: struct { metering: bool = false, cancellation: bool = false } = .{},
};
pub const Config = struct { policy: Policy = .{}, runtime_policy: bool = false };
pub const defaults: Effective = .{};
pub const Check = enum { valid };

/// Every typed combination in this slice is meaningful, including zero limits.
/// Do not invent invalid combinations merely to add a configuration error set.
pub fn check(_: Effective) Check {
    return .valid;
}

pub fn resolve(base: Effective, patch: Policy) Effective {
    var result = base;
    inline for (std.meta.fields(@TypeOf(patch.limits))) |field| {
        if (@field(patch.limits, field.name)) |value| @field(result.limits, field.name) = value;
    }
    inline for (std.meta.fields(@TypeOf(patch.execution))) |field| {
        if (@field(patch.execution, field.name)) |value| @field(result.execution, field.name) = value;
    }
    return result;
}

pub const presets = struct {
    pub const standard: Policy = .{
        .limits = .{
            .max_source_bytes = defaults.limits.max_source_bytes,
            .max_nesting = defaults.limits.max_nesting,
            .max_nodes = defaults.limits.max_nodes,
        },
        .execution = .{ .metering = false, .cancellation = false },
    };
};
