//! Borrowed execution resources. Behavior is configured by Policy.execution.
//! No clock, thread or synchronization dependency.

/// Borrowed, non-failing request predicate, polled before each microstep.
/// Hooks must not reenter the session. Cross-thread and signal adapters own
/// synchronization and signal safety; the parser does not make plain flags safe.
pub const Cancellation = struct {
    context: ?*anyopaque,
    is_requested: *const fn (?*anyopaque) bool,

    pub fn requested(self: Cancellation) bool {
        return self.is_requested(self.context);
    }
};
