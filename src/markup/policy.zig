//! Markup-owned behavioral settings. Resources are passed separately.
const std = @import("std");
pub const RuleSeverity = enum { err, warning, off };
pub const ScannerBackend = enum { scalar, block };
/// Graphviz currently adds vocabulary checks only, not complete label grammar.
/// Extended remains unimplemented. Neither mode changes the structural parser.
pub const Mode = enum { structural, graphviz };
pub const Acceptance = enum { reject, warn, accept };
pub const OnError = @import("parser_support").execution.OnError;
pub const Unsupported = @import("parser_support").reporting.Unsupported;
pub const Fixes = @import("parser_support").reporting.Fixes;
pub const SyntaxSettings = struct { malformed_reference: Acceptance = .reject };
/// Optional validation rules, not parser dialects or namespace processing.
pub const NameRule = enum { xml_1_0 };
pub const ReferenceCatalog = enum { xml_predefined };
pub const NameSettings = struct { rule: NameRule = .xml_1_0, severity: RuleSeverity = .off };
pub const ReferenceSettings = struct { catalog: ReferenceCatalog = .xml_predefined, severity: RuleSeverity = .off };
pub const GraphvizSettings = struct {
    unknown_element: RuleSeverity = .err,
    invalid_attribute: RuleSeverity = .err,
};
pub const ValidationSettings = struct {
    on_error: OnError = .collect,
    duplicate_attribute: RuleSeverity = .err,
    invalid_utf8: RuleSeverity = .off,
    names: NameSettings = .{},
    references: ReferenceSettings = .{},
    graphviz: GraphvizSettings = .{},
};

pub const Policy = struct {
    mode: ?Mode = null,
    scanner: ?ScannerBackend = null,
    on_error: ?OnError = null,
    diagnostics: struct { fixes: ?Fixes = null, unsupported: ?Unsupported = null } = .{},
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
        graphviz: struct { unknown_element: ?RuleSeverity = null, invalid_attribute: ?RuleSeverity = null } = .{},
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
    mode: Mode = .structural,
    scanner: ScannerBackend = .scalar,
    on_error: OnError = .collect,
    diagnostics: struct { fixes: Fixes = .all, unsupported: Unsupported = .err } = .{},
    limits: Limits = .{},
    syntax: SyntaxSettings = .{},
    validation: ValidationSettings = .{},
    execution: struct { metering: bool = false, cancellation: bool = false } = .{},

    pub fn parsing(self: Effective) ParseSettings {
        return .{ .limits = self.limits, .syntax = self.syntax, .fixes = self.diagnostics.fixes, .unsupported = self.diagnostics.unsupported, .on_error = self.on_error };
    }
    pub fn validating(self: Effective) ValidationSettings {
        var selected = self.validation;
        if (self.mode == .structural) selected.graphviz = .{ .unknown_element = .off, .invalid_attribute = .off };
        return selected;
    }
};
pub const ParseSettings = struct { limits: Limits = .{}, syntax: SyntaxSettings = .{}, fixes: Fixes = .all, unsupported: Unsupported = .err, on_error: OnError = .collect };
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
    if (patch.mode) |value| result.mode = value;
    if (patch.scanner) |value| result.scanner = value;
    if (patch.on_error) |value| {
        result.on_error = value;
        result.validation.on_error = value;
    }
    if (patch.diagnostics.fixes) |value| result.diagnostics.fixes = value;
    if (patch.diagnostics.unsupported) |value| result.diagnostics.unsupported = value;
    if (patch.syntax.malformed_reference) |value| result.syntax.malformed_reference = value;
    inline for (std.meta.fields(@TypeOf(patch.limits))) |field| {
        if (@field(patch.limits, field.name)) |value| @field(result.limits, field.name) = value;
    }
    inline for (std.meta.fields(@TypeOf(patch.execution))) |field| {
        if (@field(patch.execution, field.name)) |value| @field(result.execution, field.name) = value;
    }
    if (patch.validation.duplicate_attribute) |v| result.validation.duplicate_attribute = v;
    if (patch.validation.invalid_utf8) |v| result.validation.invalid_utf8 = v;
    inline for (.{ "names", "references", "graphviz" }) |group| {
        inline for (std.meta.fields(@TypeOf(@field(patch.validation, group)))) |field| {
            if (@field(@field(patch.validation, group), field.name)) |value|
                @field(@field(result.validation, group), field.name) = value;
        }
    }
    return result;
}

pub const presets = struct {
    pub const standard: Policy = .{
        .mode = .structural,
        .scanner = .scalar,
        .on_error = .collect,
        .diagnostics = .{ .fixes = .all, .unsupported = .err },
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
            .graphviz = .{ .unknown_element = .err, .invalid_attribute = .err },
        },
        .execution = .{ .metering = false, .cancellation = false },
    };

    /// Starting budgets for untrusted fragments, not a total heap/time bound or
    /// a new dialect. Pair with bounded diagnostics and caller resource budgets.
    /// Like standard, this is a complete policy (including disabled UTF-8).
    pub const untrusted: Policy = blk: {
        var input = standard;
        // An anonymous literal has no inherited/defaulted fields. Extending
        // Policy.limits must require an explicit finite budget here as well.
        const budgets = .{
            .max_source_bytes = 8 * 1024 * 1024,
            .max_nodes = 100_000,
            .max_attributes = 200_000,
            .max_nesting = 256,
        };
        for (std.meta.fields(@TypeOf(input.limits))) |field| {
            if (!@hasField(@TypeOf(budgets), field.name))
                @compileError("untrusted preset needs an explicit budget for " ++ field.name);
            const value: u32 = @field(budgets, field.name);
            if (value == std.math.maxInt(u32))
                @compileError("untrusted preset needs a finite budget for " ++ field.name);
            @field(input.limits, field.name) = value;
        }
        break :blk input;
    };
};
