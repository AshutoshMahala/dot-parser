//! Private event-level grammar, shared by fixed/growing/count-only consumers.
//! No AST dependency. No source-sized loop inside a step, including tag-name
//! comparison. Consumer pointers are supplied when driving, never self-stored.
const support = @import("parser_support");
const lexer = @import("lexer.zig");
const diagnostic = @import("diagnostic.zig");
const policy = @import("policy.zig");
const scratch = @import("scratch.zig");
const result = @import("result.zig");

pub fn Machine(comptime fixed_limits: ?policy.Limits, comptime metered: bool, comptime cancellable: bool) type {
    return struct {
        const Self = @This();
        pub const Settings = if (fixed_limits == null) policy.Limits else void;
        pub const Hook = if (cancellable) ?support.execution.Cancellation else void;
        scanner: lexer.ScannerFor(metered),
        diagnostics: diagnostic.Sink,
        settings: Settings,
        hook: Hook,
        phase: enum { preflight, begin, scan, grammar, compare_open, compare_close, open, text, close, open_head, attribute, empty_close, commit } = .preflight,
        token: lexer.Token = undefined,
        /// Only live while reading an attribute-bearing opening header. Not a
        /// nesting frame: self-closing tags still need no persistent scratch.
        head: scratch.Frame = undefined,
        compare_index: u32 = 0,
        compare_byte: u8 = 0,
        began: bool = false,
        counts: result.Counts = .{},
        terminal: ?result.Report = null,

        pub fn init(source: []const u8, diagnostics: diagnostic.Sink, settings: Settings, hook: Hook) Self {
            return .{ .scanner = .init(source), .diagnostics = diagnostics, .settings = settings, .hook = hook };
        }
        fn limits(self: *const Self) policy.Limits {
            return if (fixed_limits) |v| v else self.settings;
        }
        fn finish(self: *Self, stack: *scratch.Stack, sink: anytype, outcome: result.Outcome, finding: ?diagnostic.Diagnostic) void {
            var delivery: diagnostic.reporting.Delivery = .complete;
            // These findings report an already-terminal cause. Accepted-stop or
            // rejection cannot replace it; broken sinks are never reported into.
            if (finding) |d| {
                _ = self.diagnostics.emit(d) catch {
                    delivery = .failed;
                };
            }
            if (self.began and outcome != .success) sink.abort();
            stack.len = 0;
            self.terminal = .{ .outcome = outcome, .diagnostic_delivery = delivery, .counts = self.counts };
        }
        fn capacity(self: *Self, stack: *scratch.Stack, sink: anytype, resource: diagnostic.Resource, limit: u32, storage: bool) void {
            self.finish(stack, sink, if (storage) .{ .storage_exhausted = resource } else .{ .resource_limit = .{ .resource = resource, .limit = limit } }, .{
                .code = .capacity_exhausted,
                .span = .{ .start = self.scanner.offset, .len = 0 },
                .details = .{ .capacity = .{ .resource = resource, .limit = limit } },
            });
        }
        fn failure(self: *Self, stack: *scratch.Stack, sink: anytype, err: anyerror) void {
            switch (err) {
                error.NodeStorageExhausted => self.capacity(stack, sink, .node_pool, self.counts.nodes, true),
                error.AttributeStorageExhausted => self.capacity(stack, sink, .attribute_pool, self.counts.attributes, true),
                error.NestingStorageExhausted => self.capacity(stack, sink, .nesting_frames, stack.len, true),
                error.OutOfMemory => self.finish(stack, sink, .out_of_memory, .{ .code = .out_of_memory, .span = .{ .start = self.scanner.offset, .len = 0 } }),
                else => self.finish(stack, sink, .sink_failure, null),
            }
        }
        fn invalid(self: *Self, stack: *scratch.Stack, sink: anytype, code: diagnostic.Code, span: support.location.Span, related: ?support.location.Span) void {
            self.finish(stack, sink, .invalid_syntax, .{ .code = code, .span = span, .related = related });
        }
        fn step(self: *Self, stack: *scratch.Stack, sink: anytype) void {
            switch (self.phase) {
                .preflight => {
                    if (self.scanner.source.len > self.limits().max_source_bytes) return self.capacity(stack, sink, .source_bytes, self.limits().max_source_bytes, false);
                    self.phase = .begin;
                },
                .begin => {
                    self.began = true;
                    sink.begin() catch |err| return self.failure(stack, sink, err);
                    self.phase = .scan;
                },
                .scan => if (self.scanner.step()) |item| {
                    switch (item) {
                        .problem => |p| self.finish(stack, sink, p.outcome, p.diagnostic),
                        .token => |t| {
                            self.token = t;
                            self.phase = .grammar;
                        },
                    }
                },
                .grammar => switch (self.token.kind) {
                    .eof => {
                        if (stack.len != 0) return self.invalid(stack, sink, .unclosed_element, self.token.span, stack.top().name);
                        self.phase = .commit;
                    },
                    .close => {
                        if (stack.len == 0) return self.invalid(stack, sink, .unexpected_close, self.token.span, null);
                        if (stack.top().name.len != self.token.name.len) return self.invalid(stack, sink, .mismatched_tag, self.token.name, stack.top().name);
                        self.compare_index = 0;
                        self.phase = .compare_open;
                    },
                    .open, .empty, .text => {
                        if (self.counts.nodes == self.limits().max_nodes) return self.capacity(stack, sink, .nodes, self.limits().max_nodes, false);
                        if (self.token.kind != .text) {
                            if (stack.len == self.limits().max_nesting) return self.capacity(stack, sink, .nesting_depth, self.limits().max_nesting, false);
                            if (self.token.kind == .open) stack.push(.{ .name = self.token.name }) catch |err| return self.failure(stack, sink, err);
                            self.phase = .open;
                        } else self.phase = .text;
                    },
                    .open_head => {
                        if (self.counts.nodes == self.limits().max_nodes) return self.capacity(stack, sink, .nodes, self.limits().max_nodes, false);
                        if (stack.len == self.limits().max_nesting) return self.capacity(stack, sink, .nesting_depth, self.limits().max_nesting, false);
                        self.phase = .open_head;
                    },
                    .attribute => {
                        if (self.counts.attributes == self.limits().max_attributes) return self.capacity(stack, sink, .attributes, self.limits().max_attributes, false);
                        self.phase = .attribute;
                    },
                    .head_end => {
                        stack.push(self.head) catch |err| return self.failure(stack, sink, err);
                        self.phase = .scan;
                    },
                    .empty_end => self.phase = .empty_close,
                },
                .compare_open => {
                    self.compare_byte = self.scanner.source[stack.top().name.start + self.compare_index];
                    self.phase = .compare_close;
                },
                .compare_close => {
                    if (self.compare_byte != self.scanner.source[self.token.name.start + self.compare_index])
                        return self.invalid(stack, sink, .mismatched_tag, self.token.name, stack.top().name);
                    self.compare_index += 1;
                    self.phase = if (self.compare_index == self.token.name.len) .close else .compare_open;
                },
                .open => {
                    const handle = sink.open(self.token.span, self.token.name) catch |err| return self.failure(stack, sink, err);
                    if (self.token.kind == .open) stack.top().handle = handle;
                    self.counts.nodes += 1;
                    self.counts.elements += 1;
                    self.counts.max_depth = @max(self.counts.max_depth, if (self.token.kind == .open) stack.len else stack.len + 1);
                    self.phase = .scan;
                },
                .text => {
                    sink.text(self.token.span) catch |err| return self.failure(stack, sink, err);
                    self.counts.nodes += 1;
                    self.phase = .scan;
                },
                .attribute => {
                    sink.attribute(self.head.handle, self.token.name, self.token.span) catch |err| return self.failure(stack, sink, err);
                    self.counts.attributes += 1;
                    self.phase = .scan;
                },
                .open_head => {
                    const handle = sink.open(self.token.span, self.token.name) catch |err| return self.failure(stack, sink, err);
                    self.head = .{ .name = self.token.name, .handle = handle };
                    self.counts.nodes += 1;
                    self.counts.elements += 1;
                    self.counts.max_depth = @max(self.counts.max_depth, stack.len + 1);
                    self.phase = .scan;
                },
                .empty_close => {
                    sink.close(self.head.handle, @as(u32, @intCast(self.token.span.endOffset()))) catch |err| return self.failure(stack, sink, err);
                    self.phase = .scan;
                },
                .close => {
                    sink.close(stack.top().handle, @as(u32, @intCast(self.token.span.endOffset()))) catch |err| return self.failure(stack, sink, err);
                    stack.len -= 1;
                    self.phase = .scan;
                },
                .commit => {
                    sink.commit() catch |err| return self.failure(stack, sink, err);
                    self.finish(stack, sink, .success, null);
                },
            }
        }
        fn requested(self: *const Self) bool {
            return if (cancellable) (if (self.hook) |h| h.requested() else false) else false;
        }
        pub fn cancel(self: *Self, stack: *scratch.Stack, sink: anytype) result.Report {
            if (self.terminal == null) self.finish(stack, sink, .cancelled, null);
            return self.terminal.?;
        }
        pub fn run(self: *Self, stack: *scratch.Stack, sink: anytype) result.Report {
            while (self.terminal == null) {
                if (self.requested()) return self.cancel(stack, sink);
                self.step(stack, sink);
            }
            return self.terminal.?;
        }
        pub fn advance(self: *Self, stack: *scratch.Stack, sink: anytype, budget: u32) result.Progress {
            if (!metered) @compileError("metering is disabled; use run()");
            var used: u32 = 0;
            while (self.terminal == null) {
                if (self.requested()) {
                    _ = self.cancel(stack, sink);
                    break;
                }
                if (used == budget) break;
                used += 1;
                self.step(stack, sink);
            }
            return .{ .outcome = if (self.terminal) |r| r.outcome else null, .work_used = used, .source_frontier = self.scanner.frontier, .counts = self.counts };
        }
    };
}

test "each event attempt is charged and every rejecting sink aborts exactly once" {
    const std = @import("std");
    try std.testing.expect(Machine(.{}, false, false).Settings == void);
    try std.testing.expect(Machine(.{}, false, false).Hook == void);
    try std.testing.expect(@FieldType(lexer.ScannerFor(false), "frontier") == void);
    try std.testing.expect(@FieldType(lexer.ScannerFor(true), "frontier") == u32);
    const Probe = struct {
        calls: u32 = 0,
        aborts: u32 = 0,
        fail_at: ?u32 = null,
        pub fn attempt(self: *@This()) error{Rejected}!void {
            const call = self.calls;
            self.calls += 1;
            if (self.fail_at == call) return error.Rejected;
        }
        pub fn begin(self: *@This()) !void {
            try self.attempt();
        }
        pub fn open(self: *@This(), _: support.location.Span, _: support.location.Span) !u32 {
            try self.attempt();
            return 0;
        }
        pub fn text(self: *@This(), _: support.location.Span) !void {
            try self.attempt();
        }
        pub fn attribute(self: *@This(), _: u32, _: support.location.Span, _: support.location.Span) !void {
            try self.attempt();
        }
        pub fn close(self: *@This(), _: u32, _: u32) !void {
            try self.attempt();
        }
        pub fn commit(self: *@This()) !void {
            try self.attempt();
        }
        pub fn abort(self: *@This()) void {
            self.aborts += 1;
        }
    };
    for (0..10) |attempt| {
        var probe: Probe = .{ .fail_at = if (attempt == 9) null else @intCast(attempt) };
        var storage: scratch.Fixed(1) = .{};
        var stack: scratch.Stack = .{ .frames = storage.storage().frames };
        var m = Machine(.{}, true, false).init("<a x='1'>x<b y='2'/></a>", diagnostic.discard, {}, {});
        while (m.terminal == null) {
            const calls = probe.calls;
            const p = m.advance(&stack, &probe, 1);
            try std.testing.expectEqual(@as(u32, 1), p.work_used);
            try std.testing.expect(probe.calls - calls <= 1);
        }
        const expected: result.Outcome = if (probe.fail_at == null) .success else .sink_failure;
        try std.testing.expectEqual(expected, m.terminal.?.outcome);
        try std.testing.expectEqual(@as(u32, if (probe.fail_at == null) 0 else 1), probe.aborts);
        const calls = probe.calls;
        _ = m.advance(&stack, &probe, 100);
        _ = m.run(&stack, &probe);
        _ = m.cancel(&stack, &probe);
        try std.testing.expectEqual(calls, probe.calls);
        try std.testing.expectEqual(@as(u32, if (probe.fail_at == null) 0 else 1), probe.aborts);
    }
}
