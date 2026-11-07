//! One grant drives DOT, a single-event mailbox, validation and IR construction.
//! No Document, measuring pass or unbounded event/statement replay in callbacks.
const std = @import("std");
const dot = @import("../root.zig");
const e = dot.events;
const enc = @import("parser_support").encoding;
const policy = @import("../dot/policy.zig");
const r = @import("resources.zig");
const execution = @import("execution_policy.zig");
const forwarding = @import("event_observer.zig");
pub const Phase = enum { parse, stage, validate, replay, finalize, terminal };

pub fn Session(comptime API: type, comptime config: @import("../ir.zig").Config, comptime Dot: type, comptime Observer: ?type, comptime partial: bool) type {
    const rep = @import("representation.zig").Identity.from(config);
    const baseline = comptime execution.resolve(.{}, config.policy);
    const B = @import("event_session_builder.zig").Builder(rep, if (Dot.runtime_policy) null else Dot.baseline.validation, partial);
    const Queue = struct {
        pub const retains_partial = partial;
        pub const wants_begin_statement = true;
        pub const recover_statements = true;
        pub const coverage = true;
        pub const Error = error{};
        builder: *B = undefined,
        cancelled: *bool = undefined,
        prior_coverage: e.Coverage = .{},
        pub fn onEvent(self: *@This(), event: e.Event) Error!e.Action {
            if (self.cancelled.*) return .proceed;
            // The parser is not stepped again until this record is consumed.
            self.builder.accept(event);
            return .proceed;
        }
        pub fn onAbort(self: *@This(), reason: e.Abort) void {
            self.builder.abort(reason);
        }
    };
    const Sink = forwarding.ConsumerWith(Queue, Observer, true);
    const actual: enc.Actual = if (Dot.source_capabilities.utf8) .utf8 else .ascii;
    const Cursor = @import("event_cursor.zig");
    const Scalar = Cursor.Cursor(actual, Dot, Sink, .scalar);
    const Block = Cursor.Cursor(actual, Dot, Sink, .block);
    const Cursors = union(policy.ScannerBackend) { scalar: Scalar, block: Block };
    const runtime = config.runtime_policy or Dot.runtime_policy;
    const dot_cancel = Dot.runtime_policy or Dot.baseline.execution.cancellation;
    const ir_cancel = config.runtime_policy or baseline.cancellation;
    const Poll = @import("parser_support").execution.CancellationPolling;
    const DotPolling = Poll(dot_cancel, if (Dot.runtime_policy) null else Dot.baseline.execution.cancellation_interval);
    const IrPolling = Poll(ir_cancel, if (config.runtime_policy) null else baseline.cancellation_interval);
    return struct {
        const Self = @This();
        pub const Result = if (partial) API.PartialResult else API.Result;
        pub const Options = API.Options;
        pub const Outcome = union(enum) { success, rejected, failure: API.Error };
        pub const Progress = struct { work_used: u32, total_work: u64, phase: Phase, source_frontier: u32, outcome: ?Outcome };
        pub const TakeError = API.Error || error{ NotReady, AlreadyTaken };
        memory: r.Memory,
        builder: B,
        queue: Queue = .{},
        sink: if (Observer != null) Sink else void,
        cursor: if (Dot.runtime_policy) Cursors else if (Dot.baseline.scanner == .scalar) Scalar else Block,
        dot_execution: @FieldType(policy.Effective, "execution"),
        effective: execution.Effective,
        dot_hook: if (dot_cancel) ?r.Cancellation else void,
        ir_hook: if (ir_cancel) ?r.Cancellation else void,
        total_work: u64 = 0,
        frontier: u32 = 0,
        outcome: ?Outcome = null,
        result: ?Result = null,
        taken: bool = false,
        cancelled: bool = false,
        driving: bool = false,

        pub fn init(allocator: std.mem.Allocator, source: []const u8, options: Options) API.Error!Self {
            const settings = if (Dot.runtime_policy) try Dot.Policies.prepare(.{ .policy = options.dot.policy }) else Dot.baseline;
            const effective = if (config.runtime_policy) try execution.effectiveFor(config, options.lowering) else baseline;
            const limits = options.lowering.limits orelse config.limits;
            const info = if (@hasField(@TypeOf(options.dot), "encoding")) try enc.select(Dot.source_capabilities, source, options.dot.encoding) else enc.Reader(actual).sourceInfo(source);
            if (info.encoding != .utf8 and info.encoding != .ascii) return error.UnsupportedEncoding;
            if (!rep.encodings.allows(if (info.encoding == .ascii and !rep.encodings.utf8) .ascii else .utf8)) return error.UnsupportedEncoding;
            var value: Self = .{
                .memory = .{ .backing = allocator, .limit = limits.max_bytes },
                .builder = try B.init(allocator, source, info, limits, settings.validation, options.diagnostics),
                .sink = if (Observer != null) .{ .builder = undefined, .observer = options.observer } else {},
                .cursor = undefined,
                .dot_execution = settings.execution,
                .effective = effective,
                .dot_hook = if (dot_cancel) (if (settings.execution.cancellation) options.dot.cancellation else null) else {},
                .ir_hook = if (ir_cancel) execution.cancellationFor(config, options.lowering, effective) else {},
            };
            value.builder.actual = if (info.encoding == .ascii and !rep.encodings.utf8) .ascii else .utf8;
            if (Dot.runtime_policy) value.cursor = switch (settings.scanner) {
                .scalar => .{ .scalar = Scalar.init(source, undefined, options.diagnostics, settings.parsing, info) },
                .block => .{ .block = Block.init(source, undefined, options.diagnostics, settings.parsing, info) },
            } else value.cursor = @TypeOf(value.cursor).init(source, undefined, options.diagnostics, settings.parsing, info);
            // No allocation, source walk or callback has happened here.
            return value;
        }
        fn bind(self: *Self) void {
            self.builder.bind(self.memory.allocator());
            self.queue.builder = &self.builder;
            self.queue.cancelled = &self.cancelled;
            const sink = if (Observer != null) blk: {
                self.sink.builder = &self.queue;
                break :blk &self.sink;
            } else &self.queue;
            if (Dot.runtime_policy) switch (self.cursor) {
                inline else => |*cursor| cursor.core.machine.events = sink,
            } else self.cursor.core.machine.events = sink;
        }
        fn parsed(self: *const Self) ?e.ResultFor(true) {
            return if (Dot.runtime_policy) switch (self.cursor) {
                inline else => |*cursor| cursor.core.terminal,
            } else self.cursor.core.terminal;
        }
        fn stopParser(self: *Self) void {
            if (Dot.runtime_policy) switch (self.cursor) {
                inline else => |*cursor| cursor.cancel(),
            } else self.cursor.cancel();
        }
        fn stopParserFailure(self: *Self, err: anyerror) void {
            if (Dot.runtime_policy) switch (self.cursor) {
                inline else => |*cursor| cursor.fail(err),
            } else self.cursor.fail(err);
        }
        pub fn cancel(self: *Self) void {
            if (self.outcome != null) return;
            self.cancelled = true;
            self.outcome = .{ .failure = error.Cancelled };
            if (!self.driving) {
                self.bind();
                self.stopParser();
            }
        }
        fn fail(self: *Self, err: API.Error) void {
            if (self.outcome != null) return;
            self.outcome = .{ .failure = err };
            self.stopParserFailure(err);
        }
        fn poll(self: *Self, comptime is_dot: bool) bool {
            if (comptime if (is_dot) dot_cancel else ir_cancel) {
                if (if (is_dot) self.dot_hook else self.ir_hook) |hook| if (hook.requested()) self.cancel();
            }
            return self.outcome == null;
        }
        fn snapshot(self: *const Self, used: u32) Progress {
            return .{ .work_used = used, .total_work = self.total_work, .phase = if (self.outcome != null) .terminal else if (!self.builder.idle()) switch (self.builder.phaseKind()) {
                .stage => .stage,
                .validate => .validate,
                .replay => .replay,
                .finalize => .finalize,
            } else .parse, .source_frontier = self.frontier, .outcome = self.outcome };
        }
        pub fn advance(self: *Self, budget: u32) (if (runtime) error{MeteringDisabled}!Progress else Progress) {
            if (runtime) {
                if (!self.dot_execution.metering or !self.effective.metering) return error.MeteringDisabled;
            } else if (!Dot.baseline.execution.metering or !baseline.metering) @compileError("composed advance requires metering in both DOT and IR profiles; use run()");
            return self.drive(budget, true);
        }
        pub fn run(self: *Self) Progress {
            const start = self.total_work;
            while (self.outcome == null) _ = self.drive(std.math.maxInt(u32), false);
            return self.snapshot(@intCast(@min(self.total_work - start, std.math.maxInt(u32))));
        }
        fn drive(self: *Self, budget: u32, pause: bool) Progress {
            if (self.outcome != null) return self.snapshot(0);
            self.bind();
            self.driving = true;
            defer {
                self.driving = false;
                if (self.cancelled) self.stopParser();
            }
            var dot_polling: DotPolling = .{};
            var ir_polling: IrPolling = .{};
            // Resume checkpoints are independent of the size of the grant.
            if (!self.poll(true) or !self.poll(false)) return self.snapshot(0);
            _ = dot_polling.due(self.dot_execution.cancellation_interval);
            _ = ir_polling.due(self.effective.cancellation_interval);
            var used: u32 = 0;
            while (used < budget and self.outcome == null) {
                const ir_work = !self.builder.idle();
                if (ir_work) {
                    if (ir_polling.due(self.effective.cancellation_interval) and !self.poll(false)) break;
                    if (self.builder.d.b.work.remaining == 0) {
                        self.fail(error.WorkLimit);
                        break;
                    }
                    self.builder.d.b.work.remaining -= 1;
                    (if (comptime @import("builtin").mode == .small) self.builder.step() else @call(.always_inline, B.step, .{&self.builder})) catch |err| switch (err) {
                        error.ValidationStopped => {
                            self.builder.d.failure = err;
                            self.stopParserFailure(err);
                            self.rejectValidation();
                        },
                        error.UnsupportedSemantics => if (partial and self.result != null) {
                            self.outcome = .rejected;
                        } else self.fail(error.UnsupportedSemantics),
                        else => |failure| self.fail(self.memory.failure(failure)),
                    };
                    ir_polling.spend(1);
                } else if (self.parsed() != null) {
                    // Constant-sized admission/ownership decisions are charged.
                    self.finishParsed();
                } else {
                    if (dot_polling.due(self.dot_execution.cancellation_interval) and !self.poll(true)) break;
                    self.stepParser() catch |err| self.fail(self.memory.failure(err));
                    dot_polling.spend(1);
                    if (Observer != null) {
                        if (self.sink.failure) |err| self.fail(err) else if (self.sink.stopped) self.fail(error.ObserverStopped);
                    }
                }
                used += 1;
                self.total_work += 1;
                if (self.outcome != null) break;
                if (self.builder.checked()) self.admit();
                if (self.builder.done()) {
                    self.result.?._graph = self.builder.publish();
                    self.outcome = .success;
                }
            }
            if (pause and budget != 0 and self.outcome == null) {
                if (Dot.runtime_policy) switch (self.cursor) {
                    inline else => |*cursor| cursor.notePause(),
                } else self.cursor.notePause();
            }
            return self.snapshot(used);
        }
        fn stepParser(self: *Self) r.Error!void {
            if (Dot.runtime_policy) switch (self.cursor) {
                inline else => |*cursor| {
                    self.queue.prior_coverage = cursor.core.machine.control.coverage;
                    _ = try cursor.step(self.memory.allocator());
                    self.frontier = @intCast(cursor.core.machine.tokens.source_frontier);
                },
            } else {
                self.queue.prior_coverage = self.cursor.core.machine.control.coverage;
                _ = try self.cursor.step(self.memory.allocator());
                self.frontier = @intCast(self.cursor.core.machine.tokens.source_frontier);
            }
        }
        fn checking(self: *Self, parsed_result: e.ResultFor(true)) API.Checking {
            return .{
                .outcome = switch (parsed_result.outcome) {
                    .success => .success,
                    .invalid_syntax => .invalid_syntax,
                    .unsupported_feature => .unsupported_feature,
                    .resource_exhausted => .resource_exhausted,
                    .diagnostic_stopped => |reason| .{ .diagnostic_stopped = reason },
                    .storage_failure => |reason| .{ .storage_failure = if (reason == .out_of_memory) .out_of_memory else .pool_exhausted },
                    .event_stopped, .event_failure, .cancelled => if (self.builder.d.checker.stop) |s| .{ .diagnostic_stopped = s } else .processor_stopped,
                },
                .completion = parsed_result.completion,
                .syntax_errors = parsed_result.syntax_errors,
                .validation = null,
                .diagnostic_delivery = parsed_result.diagnostic_delivery,
                .diagnostic_stop = parsed_result.diagnostic_stop,
                .accepted_deviations = parsed_result.accepted_deviations,
                .warnings = parsed_result.warnings,
                .coverage = parsed_result.coverage,
            };
        }
        fn finishParsed(self: *Self) void {
            const parsed_result = self.parsed().?;
            self.result = .{ .checking = self.checking(parsed_result) };
            if (parsed_result.outcome == .cancelled) {
                self.fail(error.Cancelled);
                return;
            }
            const admissible = if (partial) switch (parsed_result.outcome) {
                .success, .invalid_syntax, .unsupported_feature => self.builder.d.occurrence_count != 0,
                else => false,
            } else parsed_result.outcome == .success;
            if (!admissible or parsed_result.diagnostic_stop != null or parsed_result.diagnostic_delivery != .complete) {
                self.result.?.checking.warnings += self.builder.d.checker.warnings;
                self.outcome = .rejected;
                return;
            }
            self.builder.finishInput(parsed_result.coverage, parsed_result.outcome == .success);
        }
        fn rejectValidation(self: *Self) void {
            if (self.outcome != null) return;
            if (self.result == null) {
                self.result = .{ .checking = self.checking(self.parsed().?) };
                // Semantic consumption can reject after the parser handed off
                // a commit. Keep the same accepted frontier as direct events.
                self.result.?.checking.coverage = self.queue.prior_coverage;
            }
            self.recordValidation(false);
            self.outcome = .rejected;
        }
        fn recordValidation(self: *Self, coverage: bool) void {
            const checker = &self.builder.d.checker;
            self.result.?.checking.validation = if (coverage) self.builder.d.validation(self.parsed().?.outcome == .success, self.parsed().?.coverage.retained_end) else checker.result();
            self.result.?.checking.warnings += checker.warnings;
            self.result.?.checking.diagnostic_delivery = checker.delivery;
            self.result.?.checking.diagnostic_stop = checker.stop;
        }
        fn admit(self: *Self) void {
            self.recordValidation(true);
            const validation = self.result.?.checking.validation.?;
            const allowed = if (partial) validation.outcome == .completed and (!self.builder.d.header.strict or validation.outcome.completed.violations == 0) else validation.documentValid();
            if (!allowed) {
                self.outcome = .rejected;
                return;
            }
            if (self.builder.d.semantic_failure) |err| {
                if (partial and err == error.UnsupportedSemantics) self.outcome = .rejected else self.fail(err);
                return;
            }
            self.builder.finalize();
        }
        pub fn takeResult(self: *Self) TakeError!Result {
            const outcome = self.outcome orelse return error.NotReady;
            if (outcome == .failure) return outcome.failure;
            if (self.taken) return error.AlreadyTaken;
            self.taken = true;
            const result = self.result.?;
            self.result = null;
            return result;
        }
        pub fn peakBytes(self: *const Self) usize {
            return self.memory.peak;
        }
        pub fn deinit(self: *Self) void {
            self.bind();
            if (self.outcome == null) self.cancel();
            if (self.result) |*result| result.deinit();
            if (Dot.runtime_policy) switch (self.cursor) {
                inline else => |*cursor| cursor.deinit(self.memory.allocator()),
            } else self.cursor.deinit(self.memory.allocator());
            self.builder.deinit();
            self.* = undefined;
        }
    };
}
