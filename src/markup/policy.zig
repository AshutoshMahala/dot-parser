//! Markup-owned behavioral settings. Resources are passed separately.
const std = @import("std");
pub const RuleSeverity = enum { err, warning, off };
pub const ScannerBackend = enum { scalar, block };
pub const Acceptance = enum { reject, warn, accept };
pub const SyntaxSettings = struct { malformed_reference: Acceptance = .reject };
/// Optional validation rules, not parser dialects or namespace processing.
pub const NameRule = enum { xml_1_0 };
pub const ReferenceCatalog = enum { xml_predefined };
pub const NameSettings = struct { rule: NameRule = .xml_1_0, severity: RuleSeverity = .off };
pub const ReferenceSettings = struct { catalog: ReferenceCatalog = .xml_predefined, severity: RuleSeverity = .off };
pub const ValidationSettings = struct {
    duplicate_attribute: RuleSeverity = .err,
    invalid_utf8: RuleSeverity = .off,
    names: NameSettings = .{},
    references: ReferenceSettings = .{},
};

pub const Policy = struct {
    scanner: ?ScannerBackend = null,
    syntax: struct { malformed_reference: ?Acceptance = null } = .{},
    limits: struct {
        max_source_bytes: ?u32 = null,
        max_nesting: ?u32 = null,
        /// Elements, nonempty text runs, comments and CDATA sections.
        max_nodes: ?u32 = null,
        max_attributes: ?u32 = null,
    } = .{},
    validation: struct {
        duplicate_attribute: ?RuleSeverity = null,
        invalid_utf8: ?RuleSeverity = null,
        names: struct { rule: ?NameRule = null, severity: ?RuleSeverity = null } = .{},
        references: struct { catalog: ?ReferenceCatalog = null, severity: ?RuleSeverity = null } = .{},
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
    max_attributes: u32 = std.math.maxInt(u32),
};
pub const Effective = struct {
    scanner: ScannerBackend = .scalar,
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
    if (patch.scanner) |value| result.scanner = value;
    if (patch.syntax.malformed_reference) |value| result.syntax.malformed_reference = value;
    inline for (std.meta.fields(@TypeOf(patch.limits))) |field| {
        if (@field(patch.limits, field.name)) |value| @field(result.limits, field.name) = value;
    }
    inline for (std.meta.fields(@TypeOf(patch.execution))) |field| {
        if (@field(patch.execution, field.name)) |value| @field(result.execution, field.name) = value;
    }
    if (patch.validation.duplicate_attribute) |v| result.validation.duplicate_attribute = v;
    if (patch.validation.invalid_utf8) |v| result.validation.invalid_utf8 = v;
    inline for (.{ "names", "references" }) |group| {
        inline for (std.meta.fields(@TypeOf(@field(patch.validation, group)))) |field| {
            if (@field(@field(patch.validation, group), field.name)) |value|
                @field(@field(result.validation, group), field.name) = value;
        }
    }
    return result;
}

pub const presets = struct {
    pub const standard: Policy = .{
        .scanner = .scalar,
        .syntax = .{ .malformed_reference = .reject },
        .limits = .{
            .max_source_bytes = defaults.limits.max_source_bytes,
            .max_nesting = defaults.limits.max_nesting,
            .max_nodes = defaults.limits.max_nodes,
            .max_attributes = defaults.limits.max_attributes,
        },
        .validation = .{
            .duplicate_attribute = defaults.validation.duplicate_attribute,
            .invalid_utf8 = defaults.validation.invalid_utf8,
            .names = .{ .rule = defaults.validation.names.rule, .severity = defaults.validation.names.severity },
            .references = .{ .catalog = defaults.validation.references.catalog, .severity = defaults.validation.references.severity },
        },
        .execution = .{ .metering = false, .cancellation = false },
    };

    /// Starting budgets for untrusted fragments, not a total heap/time bound or
    /// a new dialect. Pair with bounded diagnostics and caller resource budgets.
    /// Like standard, this is a complete policy (including disabled UTF-8).
    pub const untrusted: Policy = blk: {
        var input = standard;
        input.limits = .{
            .max_source_bytes = 8 * 1024 * 1024,
            .max_nodes = 100_000,
            .max_attributes = 200_000,
            .max_nesting = 256,
        };
        break :blk input;
    };
};
