//! Fixed event-construction boundary. Retained IR and temporary transaction
//! storage are caller-owned; query_allocator is never used to construct them.
const std = @import("std");
const r = @import("resources.zig");
const execution = @import("execution_policy.zig");
const enc = @import("parser_support").encoding;
const dot = @import("../root.zig");
const policy = @import("../dot/policy.zig");
const storage = @import("event_fixed_storage.zig");

pub fn Bound(comptime API: type, comptime IR: type, comptime config: @import("../ir.zig").Config, comptime Dot: type, comptime Observer: ?type) type {
    const rep = @import("representation.zig").Identity.from(config);
    const Family = storage.For(rep, Observer);
    const runtime = config.runtime_policy or Dot.runtime_policy;
    const PlainLowering = execution.OptionsFor(config);
    const LoweringOptions = struct {
        limits: ?r.Limits = null,
        policy: @FieldType(PlainLowering, "policy") = (PlainLowering{}).policy,
        cancellation: @FieldType(PlainLowering, "cancellation") = (PlainLowering{}).cancellation,
        query_allocator: ?std.mem.Allocator = null,
    };
    return struct {
        pub const Context = Family.Context;
        pub const ParseScratchCapacities = storage.Capacities;
        pub const ParseBounds = storage.Bounds;
        pub const ParseScratch = Family.Scratch;
        pub const ParseMemory = Family.Memory;
        pub const ParseLayout = Family.Layout;
        pub const FixedParseScratch = Family.FixedScratch;
        pub const parseLayout = Family.layout;
        pub const Options = if (Observer) |O| struct {
            observer: *O,
            diagnostics: dot.DiagnosticSink = dot.diagnostic.discard,
            dot: @FieldType(API.Options, "dot") = .{},
            lowering: LoweringOptions = .{},
        } else struct {
            diagnostics: dot.DiagnosticSink = dot.diagnostic.discard,
            dot: @FieldType(API.Options, "dot") = .{},
            lowering: LoweringOptions = .{},
        };
        pub const ConfigurationError = (if (Dot.runtime_policy) policy.Error else error{}) || (if (config.runtime_policy) execution.ValidationError else error{});
        pub const Result = ResultFor(false);
        pub const PartialResult = ResultFor(true);
        fn ResultFor(comptime partial: bool) type {
            return struct {
                outcome: union(enum) { success, rejected, failure: API.Error } = .rejected,
                checking: ?API.Checking = null,
                graph: ?(if (partial) IR.PartialGraph else IR.Graph) = null,
                shortfall: ?@import("fixed_storage.zig").StorageShortfall = null,
                scratch_peak: ParseScratchCapacities = .{},
            };
        }
        pub const Session = @import("event_session.zig").SessionWith(API, config, Dot, Observer, false, Context);
        pub const PartialSession = @import("event_session.zig").SessionWith(API, config, Dot, Observer, true, Context);
        pub const parseIn = Constructor(false).parse;
        pub const parsePartialIn = Constructor(true).parse;
        pub fn parseBounds(counts: dot.DocumentCapacities, options: Options) (r.Error || ConfigurationError)!ParseBounds {
            const settings = if (Dot.runtime_policy) try Dot.Policies.prepare(.{ .policy = options.dot.policy }) else Dot.baseline;
            _ = if (config.runtime_policy) try execution.effectiveFor(config, options.lowering) else execution.effectiveFor(config, options.lowering);
            return Family.bounds(counts, options.lowering.limits orelse config.limits, settings.validation.repeated_attribute != .off);
        }
        fn Constructor(comptime partial: bool) type {
            return struct {
                pub fn parse(source: []const u8, memory: ParseMemory, options: Options) (if (runtime) ConfigurationError!ResultFor(partial) else ResultFor(partial)) {
                    // Only configuration errors escape. Operational failures keep
                    // their report and any final DOT summary already available.
                    const settings = if (Dot.runtime_policy) try Dot.Policies.prepare(.{ .policy = options.dot.policy }) else Dot.baseline;
                    const effective = if (config.runtime_policy) try execution.effectiveFor(config, options.lowering) else execution.effectiveFor(config, options.lowering);
                    var report: ResultFor(partial) = .{ .scratch_peak = .{ .partial_bookkeeping = memory.scratch.capacities.partial_bookkeeping } };
                    const limits = options.lowering.limits orelse config.limits;
                    var context = Context.init(memory, source, limits, options.lowering.query_allocator, partial) catch |err| {
                        report.outcome = .{ .failure = err };
                        return report;
                    };
                    // Store the report after work, rather than relying on defer
                    // to modify a value already copied into the return slot.
                    construct(partial, &context, source, settings, effective, options, &report) catch |err| {
                        report.outcome = .{ .failure = err };
                    };
                    report.shortfall = context.shortfall();
                    report.scratch_peak = context.scratchPeak();
                    return report;
                }
            };
        }
        fn construct(comptime partial: bool, memory: *Context, source: []const u8, settings: policy.Effective, effective: execution.Effective, options: Options, report: *ResultFor(partial)) API.Error!void {
            const Hooks = struct {
                outer: ?r.Cancellation,
                inner: ?r.Cancellation,
                fn requested(raw: ?*anyopaque) bool {
                    const self: *const @This() = @ptrCast(@alignCast(raw.?));
                    return (if (self.outer) |h| h.requested() else false) or (if (self.inner) |h| h.requested() else false);
                }
            };
            var hooks: Hooks = .{
                .outer = if (@FieldType(@FieldType(API.Options, "dot"), "cancellation") == void) null else if (settings.execution.cancellation) options.dot.cancellation else null,
                .inner = execution.cancellationFor(config, options.lowering, effective),
            };
            const hook: ?r.Cancellation = if (hooks.outer == null and hooks.inner == null) null else .{ .context = &hooks, .is_requested = Hooks.requested };
            const info = if (@hasField(@TypeOf(options.dot), "encoding")) try enc.select(Dot.source_capabilities, source, options.dot.encoding) else enc.Reader(if (Dot.source_capabilities.utf8) .utf8 else .ascii).sourceInfo(source);
            const reader = @import("names.zig").reader(rep.encodings, info.encoding);
            if (!rep.encodings.allows(reader)) return error.UnsupportedEncoding;
            var plain: API.Options = if (Observer != null) .{ .observer = options.observer } else .{};
            plain.dot = options.dot;
            plain.diagnostics = options.diagnostics;
            plain.lowering = .{ .limits = options.lowering.limits, .policy = options.lowering.policy, .cancellation = options.lowering.cancellation };
            const built = if (info.encoding == .ascii and comptime rep.encodings.utf8)
                try API.runFixed(.ascii, partial, memory, source, info, settings, plain, hook, &report.checking)
            else blk: {
                switch (reader) {
                    inline else => |actual| if (comptime rep.encodings.allows(actual)) break :blk try API.runFixed(actual, partial, memory, source, info, settings, plain, hook, &report.checking) else return error.UnsupportedEncoding,
                }
            };
            report.checking = built.checking;
            report.graph = built._graph;
            report.outcome = if (report.graph != null) .success else .rejected;
        }
    };
}

/// Specialized DOT driver with a live nesting-depth pointer for high-water
/// accounting. Reading it during event delivery does not add a parser credit.
pub fn drive(comptime actual: enc.Actual, comptime Dot: type, source: []const u8, sink: anytype, memory: anytype, settings: policy.Effective, options: anytype, diagnostics: dot.DiagnosticSink, info: enc.Info) dot.events.ResultFor(true) {
    const V = @import("../dot/execution_variant.zig").Variant;
    if (Dot.runtime_policy) switch (V.from(settings)) {
        inline else => |variant| return driveVariant(actual, Dot, variant, source, sink, memory, settings, options, diagnostics, info),
    };
    return driveVariant(actual, Dot, V.from(Dot.baseline), source, sink, memory, settings, options, diagnostics, info);
}
fn driveVariant(comptime actual: enc.Actual, comptime Dot: type, comptime variant: @import("../dot/execution_variant.zig").Variant, source: []const u8, sink: anytype, memory: anytype, settings: policy.Effective, options: anytype, diagnostics: dot.DiagnosticSink, info: enc.Info) dot.events.ResultFor(true) {
    const Sink = @typeInfo(@TypeOf(sink)).pointer.child;
    const Core = @import("../dot/event_profile.zig").Core(actual, Sink, if (Dot.runtime_policy) null else Dot.baseline.parsing, variant);
    var driver = Core.init(source, .{ .frames = memory.frames(dot.events.Context(Sink)) }, sink, diagnostics, .{
        .parsing = if (Dot.runtime_policy) settings.parsing else {},
        .cancellation = if (comptime variant.cancellable()) options.cancellation else {},
        .source_info = info,
    });
    memory.nesting_depth = &driver.stack.len;
    defer memory.nesting_depth = null;
    driver.bind();
    _ = driver.machine.runToCompletion();
    driver.settle();
    memory.observe("nesting", driver.stack.len);
    return driver.terminal.?;
}
