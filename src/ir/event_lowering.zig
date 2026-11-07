//! Opt-in source construction. The parser owns grammar and nesting;
//! the consumer stages only the active statement and shares IR semantics.
const std = @import("std");
const dot = @import("../root.zig");
const ir = @import("../ir.zig");
const enc = @import("parser_support").encoding;
const r = @import("resources.zig");
const execution = @import("execution_policy.zig");
const builders = @import("event_builder.zig");
const forwarding = @import("event_observer.zig");

pub fn Bound(comptime IR: type, comptime config: ir.Config, comptime Dot: type) type {
    return Observed(IR, config, Dot, null);
}

fn Observed(comptime IR: type, comptime config: ir.Config, comptime Dot: type, comptime Observer: ?type) type {
    const rep = @import("representation.zig").Identity.from(config);
    const fixed = if (Dot.runtime_policy) null else Dot.baseline.validation;
    const Probe = forwarding.Consumer(builders.Builder(.utf8, rep, fixed, false), Observer);
    const Events = Dot.Events(Probe); // Also enforces the child-processor boundary.
    const Return = @typeInfo(@TypeOf(Events.parse)).@"fn".return_type.?;
    const Admission = if (@typeInfo(Return) == .error_union) @typeInfo(Return).error_union.error_set else error{};
    return struct {
        const Self = @This();
        pub fn Observe(comptime Consumer: type) type {
            comptime dot.events.assertSink(Consumer);
            return Observed(IR, config, Dot, Consumer);
        }
        pub const Error = r.Error || Admission || (if (config.runtime_policy) execution.ValidationError else error{}) ||
            (if (Observer) |O| forwarding.Errors(O) || error{ObserverStopped} else error{});
        pub const Options = if (Observer) |O| struct {
            observer: *O,
            diagnostics: dot.DiagnosticSink = dot.diagnostic.discard,
            dot: Events.ParseOptions = .{},
            lowering: execution.OptionsFor(config) = .{},
        } else struct {
            diagnostics: dot.DiagnosticSink = dot.diagnostic.discard,
            dot: Events.ParseOptions = .{},
            lowering: execution.OptionsFor(config) = .{},
        };
        pub const Checking = struct {
            outcome: dot.ParseOutcome,
            completion: dot.Completion,
            syntax_errors: u32,
            validation: ?dot.ValidationResult,
            diagnostic_delivery: dot.diagnostic.Delivery,
            diagnostic_stop: ?dot.diagnostic.StopReason,
            accepted_deviations: u32,
            warnings: u64,
            coverage: dot.events.Coverage,
        };
        pub const Result = ResultFor(IR.Graph);
        pub const PartialResult = ResultFor(IR.PartialGraph);
        fn ResultFor(comptime Graph: type) type {
            return struct {
                checking: Checking,
                _graph: ?Graph = null,
                /// Borrows the owning result. Keep it alive and unmoved.
                pub fn ir(self: *const @This()) ?*const Graph {
                    return if (self._graph) |*graph| graph else null;
                }
                pub fn deinit(self: *@This()) void {
                    if (self._graph) |*graph| graph.deinit();
                    self.* = undefined;
                }
            };
        }
        pub const Phase = @import("event_session.zig").Phase;
        pub const Session = @import("event_session.zig").Session(Self, config, Dot, Observer, false);
        pub const PartialSession = @import("event_session.zig").Session(Self, config, Dot, Observer, true);
        pub const parse = Constructor(false).parse;
        pub const parsePartial = Constructor(true).parse;
        // Bind the retention choice without an extra runtime entry-point wrapper.
        fn Constructor(comptime partial: bool) type {
            return struct {
                pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: Options) Error!ResultFor(if (partial) IR.PartialGraph else IR.Graph) {
                    // Configuration errors precede source admission, callbacks or work.
                    const settings = if (Dot.runtime_policy) try Dot.Policies.prepare(.{ .policy = options.dot.policy }) else Dot.baseline;
                    const effective = if (config.runtime_policy) try execution.effectiveFor(config, options.lowering) else execution.effectiveFor(config, options.lowering);
                    const limits = options.lowering.limits orelse config.limits;
                    const ir_hook = execution.cancellationFor(config, options.lowering, effective);
                    const dot_hook = if (@FieldType(Events.Options, "cancellation") == void) null else if (settings.execution.cancellation) options.dot.cancellation else null;
                    const Hooks = struct {
                        outer: ?r.Cancellation,
                        inner: ?r.Cancellation,
                        fn requested(context: ?*anyopaque) bool {
                            const self: *const @This() = @ptrCast(@alignCast(context.?));
                            return (if (self.outer) |hook| hook.requested() else false) or (if (self.inner) |hook| hook.requested() else false);
                        }
                    };
                    var hooks: Hooks = .{ .outer = dot_hook, .inner = ir_hook };
                    const hook: ?r.Cancellation = if (ir_hook == null and dot_hook == null) null else .{ .context = &hooks, .is_requested = Hooks.requested };
                    const info = if (@hasField(Events.Options, "encoding")) try enc.select(Dot.source_capabilities, source, options.dot.encoding) else enc.Reader(.utf8).sourceInfo(source);
                    const reader = @import("names.zig").reader(rep.encodings, info.encoding);
                    if (!rep.encodings.allows(reader)) return error.UnsupportedEncoding;
                    // ASCII admission can reuse the byte-compatible IR representation,
                    // but its encoding check must still reject non-ASCII bytes.
                    if (info.encoding == .ascii and comptime rep.encodings.utf8)
                        return run(.ascii, partial, allocator, source, info, settings.validation, options, limits, hook);
                    switch (reader) {
                        inline else => |actual| if (comptime rep.encodings.allows(actual)) return run(actual, partial, allocator, source, info, settings.validation, options, limits, hook) else return error.UnsupportedEncoding,
                    }
                }
            };
        }
        fn run(comptime actual: enc.Actual, comptime partial: bool, allocator: std.mem.Allocator, source: []const u8, info: enc.Info, settings: @import("../dot/policy.zig").ValidationSettings, options: Options, limits: r.Limits, hook: ?r.Cancellation) Error!ResultFor(if (partial) IR.PartialGraph else IR.Graph) {
            var memory: r.Memory = .{ .backing = allocator, .limit = limits.max_bytes };
            var builder = try builders.Builder(actual, rep, fixed, partial).init(memory.allocator(), source, info, limits, hook, settings, options.diagnostics);
            defer builder.deinit();
            const Consumer = forwarding.Consumer(@TypeOf(builder), Observer);
            var consumer: if (Observer != null) Consumer else void = if (Observer != null)
                .{ .builder = &builder, .observer = options.observer }
            else {};
            const Driver = Dot.Events(Consumer);
            const call = Driver.parse(allocator, source, if (Observer != null) &consumer else &builder, options.diagnostics, options.dot);
            const parsed = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
            // Capture observer failures at their producer. An observer may use
            // names such as OutOfMemory or ValidationStopped for its own errors.
            if (Observer != null) {
                if (consumer.failure) |err| return err;
                if (consumer.stopped) return error.ObserverStopped;
            }
            if (builder.failure) |failure| switch (failure) {
                error.ValidationStopped => {},
                else => |err| return memory.failure(err),
            };
            var result: ResultFor(if (partial) IR.PartialGraph else IR.Graph) = .{ .checking = .{
                .outcome = switch (parsed.outcome) {
                    .success => .success,
                    .invalid_syntax => .invalid_syntax,
                    .unsupported_feature => .unsupported_feature,
                    .resource_exhausted => .resource_exhausted,
                    .storage_failure => |reason| .{ .storage_failure = if (reason == .out_of_memory) .out_of_memory else .pool_exhausted },
                    .cancelled => return error.Cancelled,
                    .diagnostic_stopped => |s| .{ .diagnostic_stopped = s },
                    .event_failure, .event_stopped => if (builder.checker.stop) |s| .{ .diagnostic_stopped = s } else if (builder.checker.error_stopped) .processor_stopped else return error.InvalidDocument,
                },
                .completion = parsed.completion,
                .syntax_errors = parsed.syntax_errors,
                .validation = null,
                .diagnostic_delivery = parsed.diagnostic_delivery,
                .diagnostic_stop = parsed.diagnostic_stop,
                .accepted_deviations = parsed.accepted_deviations,
                .warnings = parsed.warnings,
                .coverage = parsed.coverage,
            } };
            if (builder.failure != null) {
                result.checking.validation = builder.checker.result();
                result.checking.diagnostic_delivery = builder.checker.delivery;
                result.checking.diagnostic_stop = builder.checker.stop;
                result.checking.warnings += builder.checker.warnings;
                return result;
            }
            const admissible = if (partial) switch (parsed.outcome) {
                .success, .invalid_syntax, .unsupported_feature => builder.occurrence_count != 0,
                else => false,
            } else parsed.outcome == .success;
            if (!admissible or parsed.diagnostic_stop != null or parsed.diagnostic_delivery != .complete) {
                result.checking.warnings += builder.checker.warnings;
                return result;
            }
            if (partial) builder.finishPartial(parsed.coverage, parsed.outcome == .success) catch |err| switch (err) {
                error.ValidationStopped => {
                    result.checking.validation = builder.checker.result();
                    result.checking.warnings += builder.checker.warnings;
                    result.checking.diagnostic_delivery = builder.checker.delivery;
                    result.checking.diagnostic_stop = builder.checker.stop;
                    return result;
                },
                else => |failure| return memory.failure(failure),
            };
            builder.finishChecks() catch |failure| switch (failure) {
                error.ValidationStopped => {},
                else => |err| return memory.failure(err),
            };
            result.checking.validation = builder.validation(parsed.outcome == .success, parsed.coverage.retained_end);
            result.checking.warnings += builder.checker.warnings;
            result.checking.diagnostic_delivery = builder.checker.delivery;
            result.checking.diagnostic_stop = builder.checker.stop;
            if (partial) {
                const validation = result.checking.validation.?;
                if (validation.outcome != .completed or (builder.header.strict and validation.outcome.completed.violations != 0)) return result;
            } else if (!result.checking.validation.?.documentValid()) return result;
            result._graph = builder.finish() catch |err| {
                if (partial and err == error.UnsupportedSemantics) return result;
                return memory.failure(err);
            };
            return result;
        }
    };
}
