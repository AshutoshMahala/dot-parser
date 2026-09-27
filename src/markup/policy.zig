//! Markup-owned behavioral settings. Resources are passed separately.
const std = @import("std");
pub const RuleSeverity = enum { err, warning, off };
pub const Acceptance = enum { reject, warn, accept };
pub const SyntaxSettings = struct { malformed_reference: Acceptance = .reject };
pub const ValidationSettings = struct { duplicate_attribute: RuleSeverity = .err };

pub const Policy = struct {
    syntax: struct { malformed_reference: ?Acceptance = null } = .{},
    limits: struct {
        max_source_bytes: ?u32 = null,
        max_nesting: ?u32 = null,
        /// Elements, nonempty text runs, comments and CDATA sections.
        max_nodes: ?u32 = null,
        max_attributes: ?u32 = null,
    } = .{},
    validation: struct { duplicate_attribute: ?RuleSeverity = null } = .{},
    execution: struct {
        metering: ?bool = null,
        cancellation: ?bool = null,
    } = .{},
};
pub const Limits = struct {
    max_source_bytes: u32 = std.math.maxInt(u32),
    max_nesting: u32 = std.math.maxInt(u32),
    max_nodes: u32 = std.math.maxInt(u32),
    max_attributes: u32 = std.math.maxInt(u32),
};
pub const Effective = struct {
    limits: Limits = .{},
    syntax: SyntaxSettings = .{},
    validation: ValidationSettings = .{},
    execution: struct { metering: bool = false, cancellation: bool = false } = .{},

    pub fn parsing(self: Effective) ParseSettings {
        return .{ .limits = self.limits, .syntax = self.syntax };
    }
};
pub const ParseSettings = struct { limits: Limits = .{}, syntax: SyntaxSettings = .{} };
pub const Config = struct { policy: Policy = .{}, runtime_policy: bool = false };
pub const defaults: Effective = .{};
pub const Check = enum { valid };
pub const Error = error{};

/// Every typed combination in this slice is meaningful, including zero limits.
/// Do not invent invalid combinations merely to add a configuration error set.
pub fn check(_: Effective, _: Policy) Check {
    return .valid;
}

pub fn resolve(base: Effective, patch: Policy) Effective {
    var result = base;
    if (patch.syntax.malformed_reference) |value| result.syntax.malformed_reference = value;
    inline for (std.meta.fields(@TypeOf(patch.limits))) |field| {
        if (@field(patch.limits, field.name)) |value| @field(result.limits, field.name) = value;
    }
    inline for (std.meta.fields(@TypeOf(patch.execution))) |field| {
        if (@field(patch.execution, field.name)) |value| @field(result.execution, field.name) = value;
    }
    if (patch.validation.duplicate_attribute) |value| result.validation.duplicate_attribute = value;
    return result;
}

pub const presets = struct {
    pub const standard: Policy = .{
        .syntax = .{ .malformed_reference = .reject },
        .limits = .{
            .max_source_bytes = defaults.limits.max_source_bytes,
            .max_nesting = defaults.limits.max_nesting,
            .max_nodes = defaults.limits.max_nodes,
            .max_attributes = defaults.limits.max_attributes,
        },
        .validation = .{ .duplicate_attribute = defaults.validation.duplicate_attribute },
        .execution = .{ .metering = false, .cancellation = false },
    };
};
