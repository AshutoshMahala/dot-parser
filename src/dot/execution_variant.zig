//! Runtime execution choices are latched before entering the grammar loop.
//! Keep one-credit and batched cancellation in separate machine types: sharing
//! their hot grammar helpers changes LLVM's inlining decisions for interval 1.
const policy = @import("policy.zig");

pub const Variant = enum(u4) {
    scalar_immediate,
    scalar_cancellable,
    scalar_metered,
    scalar_metered_cancellable,
    block_immediate,
    block_cancellable,
    block_metered,
    block_metered_cancellable,
    scalar_batched = 9,
    scalar_metered_batched = 11,
    block_batched = 13,
    block_metered_batched = 15,

    pub fn metered(self: Variant) bool {
        return @intFromEnum(self) & 2 != 0;
    }
    pub fn cancellable(self: Variant) bool {
        return @intFromEnum(self) & 1 != 0;
    }
    pub fn backend(self: Variant) policy.ScannerBackend {
        return if (@intFromEnum(self) & 4 != 0) .block else .scalar;
    }
    pub fn singlePoll(self: Variant) bool {
        return @intFromEnum(self) & 8 == 0;
    }
    pub fn from(effective: policy.Effective) Variant {
        return @enumFromInt(@as(u4, if (effective.scanner == .block) 4 else 0) |
            @as(u4, if (effective.execution.metering) 2 else 0) |
            @as(u4, if (effective.execution.cancellation) 1 else 0) |
            @as(u4, if (effective.execution.cancellation and effective.execution.cancellation_interval != 1) 8 else 0));
    }
};
