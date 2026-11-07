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
    const S = Scratch.For(e.Context(Sink));
    const Core = @import("../dot/event_profile.zig").Core(actual, Sink, if (Dot.runtime_policy) null else Dot.baseline.parsing, if (backend == .scalar) .scalar_metered else .block_metered);
    return struct {
        core: Core,
        growth: slices.Slice(S.Frame) = .{},
        maximum: u32,
        pub fn init(source: []const u8, sink: *Sink, diagnostics: dot.DiagnosticSink, settings: policy.ParseSettings, info: enc.Info) @This() {
            return .{ .core = Core.init(source, .{}, sink, diagnostics, .{ .parsing = if (Dot.runtime_policy) settings else {}, .cancellation = {}, .source_info = info }), .maximum = settings.limits.max_nesting };
        }
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.growth.deinit(a);
            store.release(S.Frame, a, self.core.stack.frames);
            self.* = undefined;
        }
        /// Return true if this credit drove grammar/scanning/dispatch, false
        /// for bounded nesting allocation/copy. Both consume one shared credit.
        pub fn step(self: *@This(), a: std.mem.Allocator) r.Error!bool {
            const stack = &self.core.stack;
            if (stack.len == stack.frames.len and stack.len < self.maximum) {
                if (!try self.growth.reserve(a, &stack.frames, stack.len, @as(usize, stack.len) + 1, self.maximum)) return false;
            }
            self.core.bind();
            _ = self.core.machine.advanceCore(1);
            self.core.settle();
            return true;
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
