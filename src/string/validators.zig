//! Built-in and custom validators share check(value, settings, context) -> Outcome.
pub const Outcome = enum { passed, failed, stopped };
pub const None = struct {
    pub const Settings = void;
    pub const defaults: Settings = {};
    pub const uses_comparison = false;
    pub fn check(_: anytype, _: Settings, _: anytype) Outcome {
        return .passed;
    }
};
pub const Equals = struct {
    pub const Settings = []const u8;
    pub const defaults: Settings = "";
    pub const uses_comparison = true;
    pub fn validateSettings(expected: Settings) bool {
        return @import("std").unicode.utf8ValidateSlice(expected);
    }
    pub fn check(value: anytype, expected: Settings, context: anytype) Outcome {
        return if (context.equals(value, expected) orelse return .stopped) .passed else .failed;
    }
};
pub const OneOf = struct {
    pub const Settings = []const []const u8;
    pub const defaults: Settings = &.{};
    pub const uses_comparison = true;
    pub fn validateSettings(values: Settings) bool {
        for (values) |expected| if (!@import("std").unicode.utf8ValidateSlice(expected)) return false;
        return true;
    }
    pub fn check(value: anytype, values: Settings, context: anytype) Outcome {
        for (values) |expected| {
            if (context.cancelled()) return .stopped;
            if (context.equals(value, expected) orelse return .stopped) return .passed;
        }
        return .failed;
    }
};
/// Adapter for a consumer predicate fn(value, settings) bool. Opaque calls are
/// run-to-completion; use the structured contract for cooperative cancellation.
pub fn Predicate(comptime SettingsType: type, comptime initial: SettingsType, comptime predicate: anytype) type {
    return struct {
        pub const Settings = SettingsType;
        pub const defaults = initial;
        pub const uses_comparison = false;
        pub fn check(value: anytype, settings: Settings, _: anytype) Outcome {
            return if (predicate(value, settings)) .passed else .failed;
        }
    };
}
