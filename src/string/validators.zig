//! Built-in and custom validators share State(Context) and step(state, value,
//! settings, context). An optional check() supplies an unmetered fast path.
//! Optional batch(state, value, settings, context, allowance) consumes only
//! equivalent pending steps, without callbacks; zero leaves state unchanged.
pub const Outcome = enum { passed, failed, stopped };
pub const Step = enum { pending, passed, failed, stopped };
pub fn resumable(comptime Validator: type) bool {
    return @hasDecl(Validator, "State") and @hasDecl(Validator, "step");
}
pub const None = struct {
    pub const Settings = void;
    pub const defaults: Settings = {};
    pub const uses_comparison = false;
    pub fn State(comptime _: type) type {
        return struct {};
    }
    pub fn step(_: anytype, _: anytype, _: Settings, _: anytype) Step {
        return .passed;
    }
    pub fn check(_: anytype, _: Settings, _: anytype) Outcome {
        return .passed;
    }
};
pub const Equals = struct {
    pub const Settings = []const u8;
    pub const defaults: Settings = "";
    pub const uses_comparison = true;
    pub fn State(comptime Context: type) type {
        return struct { comparison: Context.ComparisonState = .{} };
    }
    pub fn step(state: anytype, value: anytype, expected: Settings, context: anytype) Step {
        return context.equalsStep(&state.comparison, value, expected);
    }
    pub fn batch(state: anytype, value: anytype, expected: Settings, context: anytype, allowance: u32) u32 {
        return context.equalsBatch(&state.comparison, value, expected, allowance);
    }
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
    pub fn State(comptime Context: type) type {
        return struct { candidate: usize = 0, comparison: Context.ComparisonState = .{} };
    }
    pub fn step(state: anytype, value: anytype, values: Settings, context: anytype) Step {
        if (state.candidate == values.len) return .failed;
        return switch (context.equalsStep(&state.comparison, value, values[state.candidate])) {
            .failed => blk: {
                state.candidate += 1;
                state.comparison = .{};
                break :blk if (state.candidate == values.len) .failed else .pending;
            },
            else => |outcome| outcome,
        };
    }
    pub fn batch(state: anytype, value: anytype, values: Settings, context: anytype, allowance: u32) u32 {
        if (state.candidate == values.len) return 0;
        return context.equalsBatch(&state.comparison, value, values[state.candidate], allowance);
    }
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
