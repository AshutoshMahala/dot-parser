//! Private bounded DOT driver for composition. A single parser credit can
//! deliver at most one normal event; abort notifications only latch state.
//! Nesting growth is charged separately, without measuring/rescanning source.
const std = @import("std");
const dot = @import("../root.zig");
const policy = @import("../dot/policy.zig");
const Scratch = @import("../dot/scratch.zig");
const e = @import("../dot/events.zig");
const r = @import("resources.zig");
const store = @import("session_storage.zig");
const slices = @import("event_session_storage.zig");
const enc = @import("parser_support").encoding;

pub fn Cursor(comptime actual: enc.Actual, comptime Dot: type, comptime Sink: type, comptime backend: policy.ScannerBackend) type {
    return CursorWith(actual, Dot, Sink, backend, void);
}
pub fn CursorWith(comptime actual: enc.Actual, comptime Dot: type, comptime Sink: type, comptime backend: policy.ScannerBackend, comptime Context: type) type {
    const fixed_storage = Context != void;
    const Memory = if (fixed_storage) *Context else std.mem.Allocator;
    const S = Scratch.For(e.Context(Sink));
    const Core = @import("../dot/event_profile.zig").Core(actual, Sink, if (Dot.runtime_policy) null else Dot.baseline.parsing, if (backend == .scalar) .scalar_metered else .block_metered);
    return struct {
        core: Core,
        growth: if (fixed_storage) void else slices.Slice(S.Frame) = if (fixed_storage) {} else .{},
        maximum: u32,
        pub fn init(source: []const u8, sink: *Sink, diagnostics: dot.DiagnosticSink, settings: policy.ParseSettings, info: enc.Info) @This() {
            return .{ .core = Core.init(source, .{}, sink, diagnostics, .{ .parsing = if (Dot.runtime_policy) settings else {}, .cancellation = {}, .source_info = info }), .maximum = settings.limits.max_nesting };
        }
        pub fn deinit(self: *@This(), a: Memory) void {
            if (fixed_storage) {
                self.* = undefined;
                return;
            }
            self.growth.deinit(a);
            if (!fixed_storage) store.release(S.Frame, a, self.core.stack.frames);
            self.* = undefined;
        }
        /// Scan a bounded run or perform one grammar/event/growth step. Never
        /// cross an event handoff before the composition drains its mailbox.
        pub inline fn advance(self: *@This(), a: Memory, allowance: u32) r.Error!u32 {
            const stack = &self.core.stack;
            const machine = &self.core.machine;
            while (true) {
                // Only a recognized opening brace can push a frame. In particular,
                // a full stack followed by a closer must not reserve another level.
                const may_push = switch (machine.work.phase) {
                    .grammar => machine.open_brace_span != null and machine.work.token.tag == .left_brace,
                    .dispatch => machine.work.action == .begin_statement and machine.work.token.tag == .left_brace,
                    else => false,
                };
                if (may_push and stack.len == stack.frames.len and stack.len < self.maximum) {
                    if (fixed_storage) return a.fail(.nesting_frames, stack.frames.len, @as(usize, stack.len) + 1);
                    // Match ordinary DOT's geometric stack growth. Reserve only
                    // at a possible push, not merely because the stack is full.
                    // Copying still advances in <=64-byte credits.
                    const capacity: usize = @intCast(@min(self.maximum, @max(@as(u64, 1), @as(u64, stack.frames.len) * 2)));
                    if (!try self.growth.reserve(a, &stack.frames, stack.len, capacity, capacity)) return 1;
                }
                self.core.bind();
                const used = machine.advanceWork(allowance);
                self.core.settle();
                if (fixed_storage) a.observe("nesting", stack.len);
                if (used != 0 or self.core.terminal != null) return @intCast(@max(1, used));
                // A cached token can cost zero scanner credits. Recheck nesting
                // before its grammar transition without charging an extra credit.
            }
        }
        pub fn releaseFrames(self: *@This(), a: Memory) void {
            std.debug.assert(self.core.terminal != null);
            if (!fixed_storage) store.release(S.Frame, a, self.core.stack.frames);
            self.core.stack.frames = &.{};
            self.core.stack.len = 0;
        }
        pub fn notePause(self: *@This()) void {
            self.core.machine.notePause();
        }
        pub fn fail(self: *@This(), err: anyerror) void {
            if (self.core.terminal != null) return;
            self.core.bind();
            _ = self.core.machine.sinkFailure(err);
            self.core.settle();
        }
        pub fn cancel(self: *@This()) void {
            _ = self.core.cancel();
        }
    };
}
