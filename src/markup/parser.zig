//! Private event-level grammar, shared by fixed/growing/count-only consumers.
//! No AST dependency. Bounded variants have no source-sized step, including tag-name
//! comparison. Consumer pointers are supplied when driving, never self-stored.
const std = @import("std");
const support = @import("parser_support");
const lexer = @import("lexer.zig");
const diagnostic = @import("diagnostic.zig");
const policy = @import("policy.zig");
const scratch = @import("scratch.zig");
const result = @import("result.zig");
const Kind = @import("kind.zig").Kind;

pub fn Machine(comptime backend: policy.ScannerBackend, comptime fixed: ?policy.ParseSettings, comptime metered: bool, comptime cancellable: bool, comptime mode: policy.Mode) type {
    const recovery_enabled = fixed == null or fixed.?.on_error == .collect;
    const deviations_enabled = fixed == null or fixed.?.syntax.malformed_reference != .reject;
    const warnings_enabled = fixed == null or fixed.?.syntax.malformed_reference == .warn or fixed.?.unsupported == .warning;
    return struct {
        const Self = @This();
        pub const Settings = if (fixed == null) policy.ParseSettings else void;
        pub const Hook = if (cancellable) ?support.execution.Cancellation else void;
        scanner: lexer.Scanner(backend, metered, metered or cancellable),
        diagnostics: diagnostic.Sink,
        settings: Settings,
        hook: Hook,
        phase: enum { preflight, begin, scan, grammar, compare_open, compare_close, open, leaf, close, open_head, attribute, empty_close, commit, recover_find, recover_compare, recover_header, recover_open } = .preflight,
        token: lexer.Token = undefined,
        /// Only live while reading an attribute-bearing opening header. Not a
        /// nesting frame: self-closing tags still need no persistent scratch.
        head: scratch.Frame = undefined,
        compare_index: u32 = 0,
        compare_byte: u8 = 0,
        began: bool = false,
        counts: result.Counts = .{},
        deviations: if (deviations_enabled) u32 else void = if (deviations_enabled) 0 else {},
        warnings: if (warnings_enabled) u32 else void = if (warnings_enabled) 0 else {},
        recovery_state: if (recovery_enabled) struct {
            errors: u32 = 0,
            // phase is the discriminator: ancestor search and header sync never
            // overlap. Explicit layout avoids a second safety tag in Debug/Safe.
            cursor: extern union { candidate: u32, header: lexer.HeaderRecovery } = .{ .candidate = 0 },
            remaining: u32 = 0,
        } else void = if (recovery_enabled) .{} else {},
        terminal: ?result.Report = null,

        pub fn init(source: []const u8, diagnostics: diagnostic.Sink, settings: Settings, hook: Hook) Self {
            var self: Self = .{ .scanner = .init(source), .diagnostics = diagnostics, .settings = settings, .hook = hook };
            // One source-sized allowance across ALL ancestor searches, including
            // length probes and byte comparisons. Even unmetered recovery is O(n).
            if (recovery_enabled) self.recovery_state.remaining = @intCast(@min(source.len, support.location.max_source_len));
            return self;
        }
        fn limits(self: *const Self) policy.Limits {
            return if (fixed) |v| v.limits else self.settings.limits;
        }
        fn acceptance(self: *const Self) policy.Acceptance {
            return if (fixed) |v| v.syntax.malformed_reference else self.settings.syntax.malformed_reference;
        }
        fn fixes(self: *const Self) policy.Fixes {
            return if (fixed) |v| v.fixes else self.settings.fixes;
        }
        inline fn nameByteEqual(a: u8, b: u8) bool {
            return if (mode == .graphviz) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
        }
        fn unsupported(self: *const Self) policy.Unsupported {
            return if (fixed) |v| v.unsupported else self.settings.unsupported;
        }
        fn writing(self: *const Self) bool {
            return !recovery_enabled or self.recovery_state.errors == 0;
        }
        fn syntaxErrors(self: *const Self) u32 {
            if (self.terminal) |report| return report.syntax_errors;
            return if (recovery_enabled) self.recovery_state.errors else 0;
        }
        /// Abort retained output once; keep only grammar/scratch for diagnostics.
        /// Ordinary findings continue, but sink stop/failure terminates immediately.
        fn recoverSyntax(self: *Self, stack: *scratch.Stack, sink: anytype, finding: diagnostic.Diagnostic) bool {
            if (!recovery_enabled or (if (fixed) |v| v.on_error else self.settings.on_error) == .fail_fast) {
                self.finish(stack, sink, .invalid_syntax, finding);
                return false;
            }
            self.recovery_state.errors += 1;
            if (self.began) {
                sink.abort();
                self.began = false;
            }
            const action = self.diagnostics.emit(finding.withFixes(self.fixes())) catch |err| {
                self.finish(stack, sink, .{ .diagnostic_stopped = .fromError(err) }, null);
                self.terminal.?.diagnostic_delivery = .failed;
                return false;
            };
            if (action == .stop) {
                self.finish(stack, sink, .{ .diagnostic_stopped = .requested }, null);
                return false;
            }
            return true;
        }
        fn searchCredit(self: *Self, stack: *scratch.Stack, sink: anytype) bool {
            if (!recovery_enabled) unreachable;
            if (self.recovery_state.remaining == 0) {
                self.capacity(stack, sink, .recovery_work, @intCast(self.scanner.source.len), false);
                return false;
            }
            self.recovery_state.remaining -= 1;
            return true;
        }
        fn malformedReference(self: *Self, stack: *scratch.Stack, sink: anytype, finding: diagnostic.Diagnostic) void {
            if (!deviations_enabled or self.acceptance() == .reject) {
                _ = self.recoverSyntax(stack, sink, finding);
                return;
            }
            // Each event owns one distinct ampersand: bounded by source length.
            self.deviations += 1;
            if (warnings_enabled and self.acceptance() == .warn) {
                self.warnings += 1;
                var warning = finding;
                warning.code = .malformed_reference_tolerated;
                const action = self.diagnostics.emit(warning.withFixes(self.fixes())) catch |err| {
                    self.finish(stack, sink, .{ .diagnostic_stopped = .fromError(err) }, null);
                    self.terminal.?.diagnostic_delivery = .failed;
                    return;
                };
                if (action == .stop) self.finish(stack, sink, .{ .diagnostic_stopped = .requested }, null);
            }
        }
        fn finish(self: *Self, stack: *scratch.Stack, sink: anytype, outcome: result.Outcome, finding: ?diagnostic.Diagnostic) void {
            var delivery: diagnostic.reporting.Delivery = .complete;
            var diagnostic_stop: ?diagnostic.reporting.StopReason = if (outcome == .diagnostic_stopped) outcome.diagnostic_stopped else null;
            var syntax_errors = self.syntaxErrors();
            if (outcome == .invalid_syntax and finding != null) syntax_errors += 1;
            // Preserve the original terminal cause AND the acknowledgment. A
            // parent operation must not emit again after accepted-stop/failure.
            if (finding) |item| {
                var d = item;
                if (warnings_enabled and outcome == .unsupported_feature and self.unsupported() == .warning) {
                    d.code = .unsupported_feature_warning;
                    self.warnings += 1;
                }
                const action = self.diagnostics.emit(d.withFixes(self.fixes())) catch |err| action: {
                    delivery = .failed;
                    diagnostic_stop = .fromError(err);
                    break :action .proceed;
                };
                if (action == .stop) diagnostic_stop = .requested;
            }
            if (self.began and outcome != .success) sink.abort();
            stack.len = 0;
            self.terminal = .{
                .outcome = outcome,
                .completion = if (outcome == .success or (outcome == .invalid_syntax and self.phase == .commit)) .complete else .incomplete,
                .syntax_errors = syntax_errors,
                .diagnostic_delivery = delivery,
                .diagnostic_stop = diagnostic_stop,
                .counts = self.counts,
                .accepted_deviations = if (deviations_enabled) self.deviations else 0,
                .warnings = if (warnings_enabled) self.warnings else 0,
            };
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
            if (!self.recoverSyntax(stack, sink, .{ .code = code, .span = span, .related = related })) return;
            if (!recovery_enabled) unreachable;
            switch (code) {
                .unexpected_close => self.phase = .scan,
                .unclosed_element => stack.len -= 1, // EOF: one finding/step, innermost first.
                .mismatched_tag => {
                    self.recovery_state.cursor = .{ .candidate = stack.len - 1 }; // top already compared
                    self.phase = .recover_find;
                },
                else => unreachable,
            }
        }
        // Keep optional header recovery out of the ordinary scan/grammar loop.
        noinline fn beginHeaderRecovery(self: *Self, stack: *scratch.Stack, sink: anytype, finding: diagnostic.Diagnostic) void {
            if (!recovery_enabled) unreachable;
            if (!self.recoverSyntax(stack, sink, finding)) return;
            self.recovery_state.cursor = .{ .header = .unquoted };
            self.phase = .recover_header;
        }
        noinline fn recoverHeader(self: *Self, stack: *scratch.Stack, sink: anytype) void {
            if (!recovery_enabled) unreachable;
            switch (self.scanner.recoverHeaderStep(&self.recovery_state.cursor.header)) {
                .pending => {},
                .open => self.phase = .recover_open,
                .empty => self.phase = .scan,
                // The initial header diagnostic already rejected this region.
                // Do not fabricate EOF findings for its parents.
                .blocked => self.finish(stack, sink, .invalid_syntax, null),
            }
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
                .scan => if (self.scanner.stepReady()) {
                    switch (self.scanner.ready) {
                        .problem => |p| {
                            if (recovery_enabled and self.scanner.canRecoverHeader()) {
                                self.beginHeaderRecovery(stack, sink, p.diagnostic);
                            } else self.finish(stack, sink, p.outcome, p.diagnostic);
                        },
                        .unsupported => |u| self.finish(stack, sink, .{ .unsupported_feature = u.feature }, if (self.unsupported() == .silent) null else u.finding()),
                        .malformed_reference => |d| self.malformedReference(stack, sink, d),
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
                    .open, .empty, .text, .comment, .cdata => {
                        if (self.counts.nodes == self.limits().max_nodes) return self.capacity(stack, sink, .nodes, self.limits().max_nodes, false);
                        if (self.token.kind == .open or self.token.kind == .empty) {
                            if (stack.len == self.limits().max_nesting) return self.capacity(stack, sink, .nesting_depth, self.limits().max_nesting, false);
                            if (self.token.kind == .open) stack.push(.{ .name = self.token.name }) catch |err| return self.failure(stack, sink, err);
                            self.phase = .open;
                        } else self.phase = .leaf;
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
                    if (!nameByteEqual(self.compare_byte, self.scanner.source[self.token.name.start + self.compare_index]))
                        return self.invalid(stack, sink, .mismatched_tag, self.token.name, stack.top().name);
                    self.compare_index += 1;
                    self.phase = if (self.compare_index == self.token.name.len) .close else .compare_open;
                },
                .recover_find => {
                    if (!recovery_enabled) unreachable;
                    if (self.recovery_state.cursor.candidate == 0) {
                        self.phase = .scan; // unmatched closer: preserve open ancestors
                        return;
                    }
                    if (!self.searchCredit(stack, sink)) return;
                    self.recovery_state.cursor.candidate -= 1;
                    if (stack.frames[self.recovery_state.cursor.candidate].name.len == self.token.name.len) {
                        self.compare_index = 0;
                        self.phase = .recover_compare;
                    }
                },
                .recover_compare => {
                    if (!recovery_enabled) unreachable;
                    if (!self.searchCredit(stack, sink)) return;
                    const candidate = self.recovery_state.cursor.candidate;
                    const opener = stack.frames[candidate].name;
                    if (!nameByteEqual(self.scanner.source[opener.start + self.compare_index], self.scanner.source[self.token.name.start + self.compare_index])) {
                        self.phase = .recover_find;
                    } else {
                        self.compare_index += 1;
                        if (self.compare_index == self.token.name.len) {
                            // Traversal only: no synthetic close events or records.
                            // The mismatch already explains the abandoned frames.
                            stack.len = candidate;
                            self.phase = .scan;
                        }
                    }
                },
                .recover_header => self.recoverHeader(stack, sink),
                .recover_open => {
                    if (!recovery_enabled) unreachable;
                    // open_head already enforced element/depth limits and counted
                    // this element. Only its explicit '>' adds a nesting frame.
                    stack.push(self.head) catch |err| return self.failure(stack, sink, err);
                    self.phase = .scan;
                },
                .open => {
                    const handle = if (self.writing()) sink.open(self.token.span, self.token.name) catch |err| return self.failure(stack, sink, err) else 0;
                    if (self.token.kind == .open) stack.top().handle = handle;
                    self.counts.nodes += 1;
                    self.counts.elements += 1;
                    self.counts.max_depth = @max(self.counts.max_depth, if (self.token.kind == .open) stack.len else stack.len + 1);
                    self.phase = .scan;
                },
                .leaf => {
                    const kind: Kind = switch (self.token.kind) {
                        .text => .text,
                        .comment => .comment,
                        .cdata => .cdata,
                        else => unreachable,
                    };
                    if (self.writing()) sink.leaf(kind, self.token.span) catch |err| return self.failure(stack, sink, err);
                    self.counts.nodes += 1;
                    self.phase = .scan;
                },
                .attribute => {
                    if (self.writing()) sink.attribute(self.head.handle, self.token.name, self.token.span) catch |err| return self.failure(stack, sink, err);
                    self.counts.attributes += 1;
                    self.phase = .scan;
                },
                .open_head => {
                    const handle = if (self.writing()) sink.open(self.token.span, self.token.name) catch |err| return self.failure(stack, sink, err) else 0;
                    self.head = .{ .name = self.token.name, .handle = handle };
                    self.counts.nodes += 1;
                    self.counts.elements += 1;
                    self.counts.max_depth = @max(self.counts.max_depth, stack.len + 1);
                    self.phase = .scan;
                },
                .empty_close => {
                    if (self.writing()) sink.close(self.head.handle, @as(u32, @intCast(self.token.span.endOffset()))) catch |err| return self.failure(stack, sink, err);
                    self.phase = .scan;
                },
                .close => {
                    if (self.writing()) sink.close(stack.top().handle, @as(u32, @intCast(self.token.span.endOffset()))) catch |err| return self.failure(stack, sink, err);
                    stack.len -= 1;
                    self.phase = .scan;
                },
                .commit => {
                    if (!self.writing()) return self.finish(stack, sink, .invalid_syntax, null);
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
            return .{ .outcome = if (self.terminal) |r| r.outcome else null, .work_used = used, .source_frontier = self.scanner.frontier, .counts = self.counts, .accepted_deviations = if (deviations_enabled) self.deviations else 0, .warnings = if (warnings_enabled) self.warnings else 0, .syntax_errors = self.syntaxErrors() };
        }
    };
}

test "each event attempt is charged and every rejecting sink aborts exactly once" {
    try std.testing.expect(Machine(.scalar, .{}, false, false, .structural).Settings == void);
    try std.testing.expect(Machine(.scalar, .{}, false, false, .structural).Hook == void);
    try std.testing.expect(@FieldType(Machine(.scalar, .{ .on_error = .fail_fast }, false, false, .structural), "recovery_state") == void);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(u32)), @sizeOf(@FieldType(Machine(.scalar, .{}, true, false, .structural), "recovery_state")));
    try std.testing.expect(@FieldType(lexer.Scanner(.scalar, false, false), "frontier") == void);
    try std.testing.expect(@FieldType(lexer.Scanner(.scalar, true, true), "frontier") == u32);
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
        pub fn leaf(self: *@This(), _: Kind, _: support.location.Span) !void {
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
        var m = Machine(.scalar, .{}, true, false, .structural).init("<a x='1'>x<b y='2'/></a>", diagnostic.discard, {}, {});
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
    // Output is aborted at the first rejection; grammar alone continues.
    var probe: Probe = .{};
    var storage: scratch.Fixed(4) = .{};
    var stack: scratch.Stack = .{ .frames = storage.storage().frames };
    var m = Machine(.scalar, .{}, true, false, .structural).init("<a><b></a><c x='1'>text</c></extra>", diagnostic.discard, {}, {});
    var calls_at_abort: ?u32 = null;
    while (m.terminal == null) {
        _ = m.advance(&stack, &probe, 1);
        if (calls_at_abort) |count| try std.testing.expectEqual(count, probe.calls);
        if (probe.aborts != 0) calls_at_abort = probe.calls;
    }
    try std.testing.expectEqual(@as(u32, 1), probe.aborts);
    try std.testing.expectEqual(@as(u32, 3), probe.calls); // begin, open a, open b
    try std.testing.expectEqual(@as(u32, 2), m.terminal.?.syntax_errors);
    try std.testing.expectEqual(result.Completion.complete, m.terminal.?.completion);

    probe = .{};
    m = Machine(.scalar, .{}, true, false, .structural).init("<a good='1' bad=0><b broken=0/></a>", diagnostic.discard, {}, {});
    calls_at_abort = null;
    while (m.terminal == null) {
        const calls = probe.calls;
        _ = m.advance(&stack, &probe, 1);
        try std.testing.expect(probe.calls - calls <= 1);
        if (calls_at_abort) |count| try std.testing.expectEqual(count, probe.calls);
        if (probe.aborts != 0) calls_at_abort = probe.calls;
    }
    try std.testing.expectEqual(@as(u32, 1), probe.aborts);
    try std.testing.expectEqual(@as(u32, 3), probe.calls); // begin, open a, good attribute
    try std.testing.expectEqual(@as(u32, 2), m.terminal.?.syntax_errors);
    try std.testing.expectEqual(result.Completion.complete, m.terminal.?.completion);
}
