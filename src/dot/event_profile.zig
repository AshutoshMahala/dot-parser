//! Event-only drivers over the same policy-specialized grammar as documents.
const std = @import("std");
const support = @import("parser_support");
const policy = @import("policy.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer/lexer.zig");
const scratch = @import("scratch.zig");
const events = @import("events.zig");

const Variant = @import("execution_variant.zig").Variant;

fn Core(comptime actual: support.encoding.Actual, comptime Sink: type, comptime fixed: ?policy.ParseSettings, comptime variant: Variant) type {
    const Scratch = scratch.For(events.Context(Sink));
    const Machine = parser.MachineWithProcessor(*Sink, variant.metered(), false, variant.cancellable(), lexer.scannerForEncoding(actual, variant.backend(), if (fixed) |s| s.retention.comments else null), fixed, void, variant.singlePoll());
    return struct {
        const Self = @This();
        pub const Options = struct {
            parsing: if (fixed == null) policy.ParseSettings else void,
            cancellation: if (variant.cancellable()) ?support.execution.Cancellation else void,
        };
        stack: Scratch.Stack,
        machine: Machine,
        terminal: ?events.Result = null,

        fn init(source: []const u8, frames: Scratch.Storage, sink: *Sink, diagnostics: @import("diagnostic.zig").Sink, options: Options) Self {
            return .{
                .stack = .{ .frames = frames.frames },
                .machine = .{ .tokens = @FieldType(Machine, "tokens").init(source), .events = sink, .diagnostics = diagnostics, .settings = options.parsing, .cancellation = options.cancellation },
            };
        }
        fn bind(self: *Self) void {
            self.machine.scratch = &self.stack;
        }
        fn settle(self: *Self) void {
            if (self.terminal != null) return;
            const result = self.machine.terminal orelse return;
            self.terminal = .{
                .source_info = support.encoding.Reader(actual).sourceInfo(self.machine.tokens.source),
                .outcome = switch (result.outcome) {
                    .success => .success,
                    .invalid_syntax => .invalid_syntax,
                    .unsupported_feature => .unsupported_feature,
                    .resource_exhausted => .resource_exhausted,
                    .cancelled => .cancelled,
                    .diagnostic_stopped => |reason| .{ .diagnostic_stopped = reason },
                    .sink_stopped => .event_stopped,
                    .sink_failure => |err| .{ .event_failure = err },
                    .scratch_failure => |err| .{ .storage_failure = if (err == error.OutOfMemory) .out_of_memory else .pool_exhausted },
                    .processor_stopped => unreachable,
                },
                .completion = result.completion,
                .syntax_errors = result.syntax_errors,
                .accepted_deviations = result.accepted_deviations,
                .warnings = result.warnings,
                .diagnostic_delivery = result.diagnostic_delivery,
                .diagnostic_stop = result.diagnostic_stop,
            };
        }
        fn run(self: *Self) events.Result {
            self.bind();
            _ = self.machine.runToCompletion();
            self.settle();
            return self.terminal.?;
        }
        fn cancel(self: *Self) events.Result {
            self.bind();
            _ = self.machine.cancel();
            self.settle();
            return self.terminal.?;
        }
        fn advance(self: *Self, budget: usize) events.Progress {
            self.bind();
            const progress = self.machine.advance(budget);
            self.settle();
            return .{ .phase = progress.phase, .work_used = progress.work_used, .source_frontier = progress.source_frontier, .completed_statements = progress.completed_statements, .completed_pairs = progress.completed_pairs, .result = self.terminal };
        }
    };
}

pub fn Bound(comptime actual: support.encoding.Actual, comptime api: type, comptime config: policy.Config, comptime Sink: type) type {
    if (config.processors.markup != null) @compileError("event-only output does not schedule child processors; bind an outer-only DOT profile");
    comptime events.assertSink(Sink);
    const Scratch = scratch.For(events.Context(Sink));
    const Binding = support.processor.PolicyBinding(policy, .{ .policy = config.policy, .runtime_policy = config.runtime_policy });
    const runtime = config.runtime_policy;
    const baseline = Binding.baseline;
    const Hook = if (runtime or baseline.execution.cancellation) ?api.Cancellation else void;
    const default_hook: Hook = if (Hook == void) {} else null;
    return struct {
        pub const ParseScratch = Scratch.Storage;
        pub const FixedParseScratch = Scratch.Fixed;
        pub const Options = if (runtime) struct { policy: policy.Policy = .{}, cancellation: Hook = default_hook } else struct { cancellation: Hook = default_hook };
        pub const ParseOptions = Options;
        pub const FixedParseOptions = Options;
        pub const Policies = Binding;
        pub const validatePolicy = Binding.validatePolicy;
        fn Checked(comptime T: type) type {
            return if (runtime) policy.Error!T else T;
        }
        fn prepare(options: Options) Checked(Binding.State) {
            return if (runtime) Binding.prepare(.{ .policy = options.policy }) else {};
        }
        fn Driver(comptime variant: Variant) type {
            return Core(actual, Sink, if (runtime) null else baseline.parsing, variant);
        }
        const Fixed = Driver(Variant.from(baseline));
        fn coreOptions(comptime variant: Variant, prepared: Binding.State, options: Options) Driver(variant).Options {
            return .{ .parsing = if (runtime) prepared.parsing else {}, .cancellation = if (comptime variant.cancellable()) options.cancellation else {} };
        }
        fn run(source: []const u8, stack: *Scratch.Stack, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options, prepared: Binding.State) events.Result {
            if (runtime) switch (Variant.from(prepared)) {
                inline else => |variant| {
                    var driver = Driver(variant).init(source, .{}, sink, diagnostics, coreOptions(variant, prepared, options));
                    driver.stack = stack.*;
                    const result = driver.run();
                    stack.* = driver.stack;
                    return result;
                },
            };
            var driver = Fixed.init(source, .{}, sink, diagnostics, coreOptions(Variant.from(baseline), prepared, options));
            driver.stack = stack.*;
            const result = driver.run();
            stack.* = driver.stack;
            return result;
        }
        /// Allocator backs nesting scratch only. Output ownership belongs to
        /// the consumer; the parser has no hidden statement/event buffer.
        pub fn parse(allocator: std.mem.Allocator, source: []const u8, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options) Checked(events.Result) {
            const prepared = if (runtime) try prepare(options) else prepare(options);
            var stack: Scratch.Stack = .{ .allocator = allocator };
            defer stack.deinit();
            return run(source, &stack, sink, diagnostics, options, prepared);
        }
        /// No allocations by the parser. Scratch must cover active nesting.
        pub fn parseIn(source: []const u8, frames: ParseScratch, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options) Checked(events.Result) {
            const prepared = if (runtime) try prepare(options) else prepare(options);
            var stack: Scratch.Stack = .{ .frames = frames.frames };
            return run(source, &stack, sink, diagnostics, options, prepared);
        }
        pub const Session = struct {
            const Self = @This();
            const Drivers = union(Variant) {
                scalar_immediate: Driver(.scalar_immediate),
                scalar_cancellable: Driver(.scalar_cancellable),
                scalar_metered: Driver(.scalar_metered),
                scalar_metered_cancellable: Driver(.scalar_metered_cancellable),
                block_immediate: Driver(.block_immediate),
                block_cancellable: Driver(.block_cancellable),
                block_metered: Driver(.block_metered),
                block_metered_cancellable: Driver(.block_metered_cancellable),
                scalar_batched: Driver(.scalar_batched),
                scalar_metered_batched: Driver(.scalar_metered_batched),
                block_batched: Driver(.block_batched),
                block_metered_batched: Driver(.block_metered_batched),
            };
            driver: if (runtime) Drivers else Fixed,
            pub fn init(source: []const u8, frames: ParseScratch, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options) Checked(Self) {
                const prepared = if (runtime) try prepare(options) else prepare(options);
                return .{ .driver = if (runtime) switch (Variant.from(prepared)) {
                    inline else => |variant| @unionInit(Drivers, @tagName(variant), Driver(variant).init(source, frames, sink, diagnostics, coreOptions(variant, prepared, options))),
                } else Fixed.init(source, frames, sink, diagnostics, coreOptions(Variant.from(baseline), prepared, options)) };
            }
            pub fn advance(self: *Self, budget: usize) (if (runtime) error{MeteringDisabled}!events.Progress else events.Progress) {
                if (runtime) return switch (self.driver) {
                    inline else => |*driver, variant| if (comptime variant.metered()) driver.advance(budget) else error.MeteringDisabled,
                };
                if (!baseline.execution.metering) @compileError("metering is disabled; use run()");
                return self.driver.advance(budget);
            }
            pub fn run(self: *Self) events.Result {
                if (runtime) return switch (self.driver) {
                    inline else => |*driver| driver.run(),
                };
                return self.driver.run();
            }
            pub fn cancel(self: *Self) events.Result {
                if (runtime) return switch (self.driver) {
                    inline else => |*driver| driver.cancel(),
                };
                return self.driver.cancel();
            }
            pub fn result(self: *const Self) ?events.Result {
                if (runtime) return switch (self.driver) {
                    inline else => |*driver| driver.terminal,
                };
                return self.driver.terminal;
            }
            pub fn reset(self: *Self, source: []const u8, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options) Checked(void) {
                // Verify before cancelling the old operation or invalidating it.
                if (runtime) _ = try prepare(options);
                const frames: ParseScratch = if (runtime) switch (self.driver) {
                    inline else => |*driver| .{ .frames = driver.stack.frames },
                } else .{ .frames = self.driver.stack.frames };
                _ = self.cancel();
                self.* = if (runtime) try init(source, frames, sink, diagnostics, options) else init(source, frames, sink, diagnostics, options);
            }
            pub fn deinit(self: *Self) void {
                _ = self.cancel();
            }
        };
    };
}

/// Native one-shot source selection. Like native document profiles, this does
/// not yet expose a native resumable session; UTF-8 profiles expose Session.
pub fn Source(comptime api: type, comptime config: policy.Config, comptime caps: support.encoding.Capabilities, comptime Sink: type) type {
    const Base = Bound(.utf8, api, config, Sink);
    const dispatch = support.source_dispatch;
    return struct {
        pub const ParseScratch = Base.ParseScratch;
        pub const FixedParseScratch = Base.FixedParseScratch;
        pub const Options = dispatch.Options(Base.Options);
        pub const ParseOptions = Options;
        pub const FixedParseOptions = Options;
        pub const Error = support.encoding.InputError || (if (config.runtime_policy) policy.Error else error{});
        fn call(comptime method: []const u8, source: []const u8, arguments: anytype, options: Options) Error!events.Result {
            if (config.runtime_policy) _ = try Base.Policies.prepare(.{ .policy = options.policy });
            const info = try support.encoding.select(caps, source, options.encoding);
            switch (info.encoding) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    const Worker = Bound(actual, api, config, Sink);
                    const value = @call(.auto, @field(Worker, method), arguments ++ .{dispatch.options(Worker.Options, options)});
                    return if (config.runtime_policy) try value else value;
                } else return error.UnsupportedEncoding,
            }
        }
        pub fn parse(allocator: std.mem.Allocator, source: []const u8, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options) Error!events.Result {
            return call("parse", source, .{ allocator, source, sink, diagnostics }, options);
        }
        pub fn parseIn(source: []const u8, frames: ParseScratch, sink: *Sink, diagnostics: api.DiagnosticSink, options: Options) Error!events.Result {
            return call("parseIn", source, .{ source, frames, sink, diagnostics }, options);
        }
    };
}
