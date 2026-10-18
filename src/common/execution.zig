//! Borrowed execution resources. Behavior is configured by Policy.execution.
//! No clock, thread or synchronization dependency.

/// Per-operation error handling, independent of diagnostic retention. Collect
/// uses safe syntax recovery where possible; neither choice repairs input.
pub const OnError = enum { fail_fast, collect };

/// Borrowed, non-failing request predicate. Parsing polls at operation entry
/// and at most Policy.execution.cancellation_interval work steps apart.
/// Hooks must not reenter the session. Cross-thread and signal adapters own
/// synchronization and signal safety; the parser does not make plain flags safe.
pub const Cancellation = struct {
    context: ?*anyopaque,
    is_requested: *const fn (?*anyopaque) bool,

    pub fn requested(self: Cancellation) bool {
        return self.is_requested(self.context);
    }
};

/// Local to one drive call: every resume checks immediately, even at budget 0.
/// Fixed interval 1 and disabled cancellation have no countdown storage/work.
/// Callers charge existing work units, never bytes or elapsed time. Validation
/// uses its own safe points rather than this parse countdown.
pub fn CancellationPolling(comptime enabled: bool, comptime fixed: ?u32) type {
    const batched = enabled and (fixed == null or fixed.? != 1);
    return struct {
        remaining: if (batched) u32 else void = if (batched) 0 else {},

        pub inline fn due(self: *@This(), interval: u32) bool {
            if (!enabled) return false;
            if (batched) {
                if (self.remaining != 0) return false;
                self.remaining = fixed orelse interval;
            }
            return true;
        }

        pub inline fn allowance(self: *const @This()) u32 {
            return if (batched) self.remaining else 1;
        }

        pub inline fn spend(self: *@This(), work: usize) void {
            if (batched) self.remaining -= @intCast(work);
        }
    };
}
