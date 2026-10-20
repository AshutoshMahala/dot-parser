//! String-owned settings; implementations and capabilities are bound at comptime.
const std = @import("std");
const support = @import("parser_support");
pub const Comparison = enum {
    case_sensitive,
    /// Full Unicode default case folding; requires unicode_case_folding.
    case_insensitive,
    /// Fold only A-Z, independently of source encoding; no Unicode tables.
    ascii_case_insensitive,
};
pub const Severity = enum { off, warning, err };
pub const Execution = struct { metering: bool = false, cancellation: bool = false, cancellation_interval: u32 = 1 };
pub const Equals = struct {
    expected: []const u8 = "",
    severity: Severity = .off,
    comparison: ?Comparison = null,
};
pub const OneOf = struct {
    values: []const []const u8 = &.{},
    severity: Severity = .off,
    comparison: ?Comparison = null,
};

pub fn Schema(comptime Custom: type, comptime unicode: bool) type {
    return struct {
        pub const Policy = struct {
            comparison: ?Comparison = null,
            on_error: ?support.execution.OnError = null,
            diagnostics: struct { fixes: ?support.reporting.Fixes = null } = .{},
            execution: struct { metering: ?bool = null, cancellation: ?bool = null, cancellation_interval: ?u32 = null } = .{},
            validation: struct {
                equals: ?Equals = null,
                one_of: ?OneOf = null,
                custom: ?Severity = null,
            } = .{},
            custom: ?Custom.Settings = null,
        };
        pub const Effective = struct {
            comparison: Comparison = .case_sensitive,
            on_error: support.execution.OnError = .collect,
            fixes: support.reporting.Fixes = .all,
            execution: Execution = .{},
            equals: Equals = .{},
            one_of: OneOf = .{},
            custom_severity: Severity = .off,
            custom: Custom.Settings = Custom.defaults,
        };
        pub const defaults: Effective = .{};
        pub const Error = error{ UnicodeFoldingDisabled, InvalidPatternEncoding, CustomValidatorRequired, InvalidCustomSettings, InvalidCancellationInterval, NonResumableValidator };
        pub const Issue = enum {
            unicode_folding_disabled,
            invalid_pattern_encoding,
            custom_validator_required,
            invalid_custom_settings,
            invalid_cancellation_interval,
            non_resumable_validator,
            pub fn asError(self: @This()) Error {
                return switch (self) {
                    .unicode_folding_disabled => error.UnicodeFoldingDisabled,
                    .invalid_pattern_encoding => error.InvalidPatternEncoding,
                    .custom_validator_required => error.CustomValidatorRequired,
                    .invalid_custom_settings => error.InvalidCustomSettings,
                    .invalid_cancellation_interval => error.InvalidCancellationInterval,
                    .non_resumable_validator => error.NonResumableValidator,
                };
            }
        };
        pub const Check = union(enum) { valid, invalid: Issue };
        pub fn resolve(base: Effective, patch: Policy) Effective {
            return .{
                .comparison = patch.comparison orelse base.comparison,
                .on_error = patch.on_error orelse base.on_error,
                .fixes = patch.diagnostics.fixes orelse base.fixes,
                .execution = .{
                    .metering = patch.execution.metering orelse base.execution.metering,
                    .cancellation = patch.execution.cancellation orelse base.execution.cancellation,
                    .cancellation_interval = patch.execution.cancellation_interval orelse base.execution.cancellation_interval,
                },
                .equals = patch.validation.equals orelse base.equals,
                .one_of = patch.validation.one_of orelse base.one_of,
                .custom_severity = patch.validation.custom orelse base.custom_severity,
                .custom = patch.custom orelse base.custom,
            };
        }
        pub fn check(p: Effective, _: Policy) Check {
            if (p.execution.cancellation_interval == 0) return .{ .invalid = .invalid_cancellation_interval };
            if (p.execution.metering and p.custom_severity != .off and !@import("validators.zig").resumable(Custom))
                return .{ .invalid = .non_resumable_validator };
            if (!unicode and (p.comparison == .case_insensitive or
                p.equals.comparison == .case_insensitive or p.one_of.comparison == .case_insensitive))
                return .{ .invalid = .unicode_folding_disabled };
            // Patterns are UTF-8 configuration, independently of source encoding.
            if (p.equals.severity != .off and !@import("validators.zig").Equals.validateSettings(p.equals.expected))
                return .{ .invalid = .invalid_pattern_encoding };
            if (p.one_of.severity != .off) for (p.one_of.values) |value| {
                if (!@import("validators.zig").Equals.validateSettings(value)) return .{ .invalid = .invalid_pattern_encoding };
            };
            if (Custom == @import("validators.zig").None and p.custom_severity != .off)
                return .{ .invalid = .custom_validator_required };
            if (@hasDecl(Custom, "validateSettings") and !Custom.validateSettings(p.custom))
                return .{ .invalid = .invalid_custom_settings };
            return .valid;
        }
    };
}
