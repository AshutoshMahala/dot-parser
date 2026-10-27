//! IR session execution policies use the same vocabulary as parser profiles.
//! Limits retain their existing IR configuration/options; DOT policies do not
//! implicitly control an independently constructed IR operation.
pub const Policy = struct {
    execution: struct {
        metering: ?bool = null,
        cancellation: ?bool = null,
        cancellation_interval: ?u32 = null,
    } = .{},
};
pub const Effective = struct {
    metering: bool = false,
    cancellation: bool = false,
    cancellation_interval: u32 = 1,
};
pub const Error = error{ InvalidCancellationInterval, MeteringDisabled };

/// Shared typed options for policy-bound queries and streams. Void capability
/// fields carry neither an override nor a hook, including when options are reused.
pub fn OptionsFor(comptime config: anytype) type {
    const r = @import("resources.zig");
    const baseline = comptime resolve(.{}, config.policy);
    const Hook = if (config.runtime_policy or baseline.cancellation) ?r.Cancellation else void;
    return struct {
        limits: ?r.Limits = null,
        cancellation: Hook = if (Hook == void) {} else null,
        policy: if (config.runtime_policy) Policy else void = if (config.runtime_policy) .{} else {},
    };
}
pub fn resolve(base: Effective, policy: Policy) Effective {
    return .{
        .metering = policy.execution.metering orelse base.metering,
        .cancellation = policy.execution.cancellation orelse base.cancellation,
        .cancellation_interval = policy.execution.cancellation_interval orelse base.cancellation_interval,
    };
}
pub fn validate(value: Effective) Error!void {
    if (value.cancellation_interval == 0) return error.InvalidCancellationInterval;
}

/// Direct lowering takes explicit options independently of session policy.
/// Share normalization across allocator-backed and caller-storage entry points.
pub fn directLimits(options: anytype, fallback: @import("resources.zig").Limits) @import("resources.zig").Limits {
    const Limits = @import("resources.zig").Limits;
    return (if (@hasField(@TypeOf(options), "limits")) option(?Limits, options.limits) else null) orelse fallback;
}
pub fn directCancellation(options: anytype) ?@import("resources.zig").Cancellation {
    if (!@hasField(@TypeOf(options), "cancellation")) return null;
    if (@FieldType(@TypeOf(options), "cancellation") == void) return null;
    return option(?@import("resources.zig").Cancellation, options.cancellation);
}

/// Anonymous options retain field checking through nested policy/limit structs.
pub fn option(comptime T: type, value: anytype) T {
    if (@TypeOf(value) == T) return value;
    if (@typeInfo(T) == .optional) {
        if (@typeInfo(@TypeOf(value)) == .null) return null;
        if (@typeInfo(@TypeOf(value)) == .optional) return if (value) |v| option(@typeInfo(T).optional.child, v) else null;
        return option(@typeInfo(T).optional.child, value);
    }
    if (@typeInfo(T) != .@"struct") return value;
    comptime for (@typeInfo(@TypeOf(value)).@"struct".field_names) |field| {
        if (!@hasField(T, field)) @compileError("unknown IR option field: " ++ field);
    };
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types, fields.field_attrs) |field, Field, attribute| {
        @field(result, field) = if (@hasField(@TypeOf(value), field))
            option(Field, @field(value, field))
        else if (attribute.default_value_ptr) |ptr|
            @as(*const Field, @ptrCast(@alignCast(ptr))).*
        else
            @compileError("missing IR option field: " ++ field);
    }
    return result;
}

pub fn Bound(comptime caps: @import("parser_support").encoding.Capabilities, comptime partial: bool, comptime config: anytype) type {
    return BoundWith(caps, partial, config, false);
}
pub fn BoundWith(comptime caps: @import("parser_support").encoding.Capabilities, comptime partial: bool, comptime config: anytype, comptime fixed_storage: bool) type {
    const baseline = comptime resolve(.{}, config.policy);
    comptime {
        validate(baseline) catch @compileError("IR cancellation_interval must be positive");
    }
    const Core = @import("lowering_session.zig").SessionWith(caps, partial, if (config.runtime_policy) null else baseline, fixed_storage);
    const Hook = if (config.runtime_policy or baseline.cancellation) ?@import("resources.zig").Cancellation else void;
    return struct {
        const Self = @This();
        pub const Result = Core.Result;
        pub const Options = struct {
            interpretation: @import("lower.zig").InterpretationFor(partial),
            limits: ?@import("resources.zig").Limits = null,
            cancellation: Hook = if (Hook == void) {} else null,
            policy: if (config.runtime_policy) Policy else void = if (config.runtime_policy) .{} else {},
        };
        core: Core,
        effective: if (config.runtime_policy) Effective else void,
        pub fn init(a: if (fixed_storage) @import("fixed_storage.zig").Context else @import("std").mem.Allocator, doc: *const @import("../dot/syntax.zig").Document, options: Options) (@import("resources.zig").Error || Error)!Self {
            const effective = if (config.runtime_policy) resolve(baseline, options.policy) else baseline;
            if (config.runtime_policy) try validate(effective);
            const hook = if (comptime Hook == void) {} else if (effective.cancellation) options.cancellation else null;
            return .{ .core = try Core.init(a, doc, options.interpretation, options.limits orelse config.limits, hook, effective.cancellation_interval), .effective = if (config.runtime_policy) effective else {} };
        }
        pub inline fn advance(self: *Self, budget: u32) (if (config.runtime_policy) Error!@import("lowering_session.zig").Progress else @import("lowering_session.zig").Progress) {
            if (config.runtime_policy) {
                if (!self.effective.metering) return error.MeteringDisabled;
            } else if (!baseline.metering) @compileError("metering is disabled; use run()");
            return self.core.advance(budget);
        }
        pub fn run(self: *Self) @import("lowering_session.zig").Progress {
            return self.core.run();
        }
        pub fn cancel(self: *Self) void {
            self.core.cancel();
        }
        pub fn peakBytes(self: *const Self) usize {
            return self.core.peakBytes();
        }
        pub fn scratchPeak(self: *const Self) @import("fixed_storage.zig").LoweringScratchCapacities {
            if (!fixed_storage) @compileError("scratchPeak requires fixed lowering");
            return self.core.memory.peak;
        }
        pub fn shortfall(self: *const Self) ?@import("fixed_storage.zig").StorageShortfall {
            if (!fixed_storage) @compileError("shortfall requires fixed lowering");
            return self.core.memory.shortfall;
        }
        pub fn takeResult(self: *Self) @import("lowering_session.zig").TakeError!Result {
            return self.core.takeResult();
        }
        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.* = undefined;
        }
    };
}
