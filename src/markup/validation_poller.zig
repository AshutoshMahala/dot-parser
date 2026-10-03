//! One work countdown shared by a validation operation, including local scopes.
const execution = @import("parser_support").execution;

pub fn For(comptime cancellable: bool, comptime Result: type) type {
    return struct {
        const Self = @This();
        pub const Hook = if (cancellable) ?execution.Cancellation else void;
        remaining: if (cancellable) u32 else void = if (cancellable) 0 else {},

        pub inline fn check(self: *Self, result: *Result, hook: Hook) bool {
            if (!cancellable) return true;
            if (self.remaining != 0) return true;
            if (!checkHook(result, hook)) return false;
            self.remaining = 64;
            return true;
        }
        pub inline fn consume(self: *Self, count: u32) void {
            if (cancellable) self.remaining -|= count;
        }
        pub inline fn step(self: *Self, result: *Result, hook: Hook) bool {
            if (!self.check(result, hook)) return false;
            self.consume(1);
            return true;
        }
        inline fn checkHook(result: *Result, hook: Hook) bool {
            if (cancellable) if (hook) |h| if (h.requested()) {
                result.completion = .cancelled;
                return false;
            };
            return true;
        }
        /// Byte loops keep local thresholds; flush on exit and before nested
        /// checks so scopes never reset the operation's remaining countdown.
        pub const Scan = struct {
            next: if (cancellable) u32 else void,
            pub inline fn init(index: u32, poller: Self) @This() {
                return .{ .next = if (cancellable) index +| poller.remaining else {} };
            }
            pub inline fn check(self: *@This(), index: u32, result: *Result, hook: Hook) bool {
                if (!cancellable) return true;
                if (index < self.next) return true;
                if (!checkHook(result, hook)) return false;
                self.next = index +| 64;
                return true;
            }
            pub inline fn flush(self: @This(), index: u32, poller: *Self) void {
                if (cancellable) poller.remaining = self.next -| index;
            }
            pub inline fn end(self: @This(), len: u32) u32 {
                return if (cancellable) @min(self.next, len) else len;
            }
        };
    };
}
