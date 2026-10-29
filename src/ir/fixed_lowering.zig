//! Public fixed-lowering boundary. All semantic work remains in the shared
//! direct builder/session, with compile-time storage specialization.
const std = @import("std");
const encoding = @import("parser_support").encoding;
const syntax = @import("../dot/syntax.zig");
const pools = @import("fixed_storage.zig");
const lower = @import("lower.zig");
const r = @import("resources.zig");
const execution = @import("execution_policy.zig");
const session = @import("lowering_session.zig");

pub fn API(comptime config: anytype) type {
    const caps = encoding.Capabilities.from(config.source_encodings);
    const baseline = comptime execution.resolve(.{}, config.policy);
    return struct {
        pub const FixedLoweringSession = execution.BoundWith(caps, false, config, true);
        pub const FixedPartialLoweringSession = execution.BoundWith(caps, true, config, true);
        pub fn Result(comptime partial: bool) type {
            return struct {
                graph: ?lower.Output(caps, partial) = null,
                outcome: session.Outcome,
                shortfall: ?pools.StorageShortfall = null,
                scratch_peak: pools.LoweringScratchCapacities = .{},
            };
        }
        pub fn DirectResult(comptime partial: bool) type {
            return if (config.runtime_policy) execution.ValidationError!Result(partial) else Result(partial);
        }
        fn checkOptions(comptime Options: type, comptime require_interpretation: bool) void {
            if (require_interpretation and !@hasField(Options, "interpretation")) @compileError("fixed IR lowering requires .interpretation from the accepting DOT profile");
            for (@typeInfo(Options).@"struct".field_names) |field| {
                if (!std.mem.eql(u8, field, "interpretation") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !std.mem.eql(u8, field, "query_allocator") and !(config.runtime_policy and std.mem.eql(u8, field, "policy"))) @compileError("unknown fixed IR lowering option: " ++ field);
            }
        }
        fn limitsOf(options: anytype) r.Limits {
            return execution.directLimits(options, config.limits);
        }
        fn context(doc: *const syntax.Document, memory: pools.LoweringMemory, options: anytype) r.Error!pools.Context {
            return pools.Context.init(memory, doc, limitsOf(options), if (@hasField(@TypeOf(options), "query_allocator")) options.query_allocator else null);
        }
        fn interpretation(comptime partial: bool, doc: *const syntax.Document, options: anytype) r.Error!lower.InterpretationFor(partial) {
            if (!partial and !doc.scopeComplete()) return error.IncompleteDocument;
            const input = options.interpretation;
            const kind = input.effectiveKind(doc.kind);
            if (doc.strict and (kind == .generic or kind == null)) return error.UnsupportedSemantics;
            return .{
                .kind = if (partial) kind else kind orelse return error.UnsupportedSemantics,
                .directed = input.effectiveOperator(doc.kind, .directed),
                .undirected = input.effectiveOperator(doc.kind, .undirected),
            };
        }
        pub fn bounds(comptime partial: bool, counts: syntax.Capacities, options: anytype) r.Error!pools.Bounds {
            // Sizing accepts either operation's options, but only reads limits.
            comptime checkOptions(@TypeOf(options), false);
            return pools.loweringBounds(partial, counts, limitsOf(options));
        }
        pub fn direct(comptime partial: bool, doc: *const syntax.Document, memory: pools.LoweringMemory, options: anytype) DirectResult(partial) {
            comptime checkOptions(@TypeOf(options), true);
            var report: Result(partial) = .{ .outcome = .success };
            const effective = if (config.runtime_policy) try execution.effectiveFor(config, options) else baseline;
            _ = execution.cancellationFor(config, options, effective);
            if (effective.metering or effective.cancellation) {
                var operation = startResolved(partial, doc, memory, options, effective) catch |err| {
                    report.outcome = .{ .failure = err };
                    return report;
                };
                defer operation.deinit();
                report.graph = execution.finish(&operation) catch |err| blk: {
                    report.outcome = .{ .failure = err };
                    break :blk null;
                };
                report.shortfall = operation.shortfall();
                report.scratch_peak = operation.scratchPeak();
                return report;
            }
            const resolved = interpretation(partial, doc, options) catch |err| {
                report.outcome = .{ .failure = err };
                return report;
            };
            var storage = context(doc, memory, options) catch |err| {
                report.outcome = .{ .failure = err };
                return report;
            };
            report.graph = run(partial, doc, &storage, resolved, limitsOf(options)) catch |err| blk: {
                report.outcome = .{ .failure = err };
                break :blk null;
            };
            report.shortfall = storage.shortfall;
            report.scratch_peak = storage.peak;
            return report;
        }
        fn run(comptime partial: bool, doc: *const syntax.Document, storage: *pools.Context, resolved: lower.InterpretationFor(partial), limits: r.Limits) r.Error!lower.Output(caps, partial) {
            _ = try r.index(doc.source.len);
            _ = try r.index(doc.order.len);
            const reader = @import("names.zig").reader(caps, doc.source_info.encoding);
            return switch (reader) {
                inline else => |actual| if (comptime caps.allows(actual)) blk: {
                    var builder: lower.BuilderWith(actual, caps, partial, true) = .{
                        .a = storage,
                        .doc = doc,
                        .interpretation = resolved,
                        .limits = limits,
                        .work = .{ .remaining = limits.max_work, .cancellation = null },
                    };
                    builder.bindFixed(storage);
                    break :blk try builder.build();
                } else error.UnsupportedEncoding,
            };
        }
        pub fn start(comptime partial: bool, doc: *const syntax.Document, memory: pools.LoweringMemory, options: anytype) (r.Error || execution.Error)!(if (partial) FixedPartialLoweringSession else FixedLoweringSession) {
            const effective = if (config.runtime_policy) try execution.effectiveFor(config, options) else baseline;
            return startResolved(partial, doc, memory, options, effective);
        }
        fn startResolved(comptime partial: bool, doc: *const syntax.Document, memory: pools.LoweringMemory, options: anytype, effective: execution.Effective) r.Error!(if (partial) FixedPartialLoweringSession else FixedLoweringSession) {
            comptime checkOptions(@TypeOf(options), true);
            const S = if (partial) FixedPartialLoweringSession else FixedLoweringSession;
            const hook = execution.cancellationFor(config, options, effective);
            if (hook) |cancel| if (cancel.requested()) return error.Cancelled;
            var normalized: S.Options = .{ .interpretation = try interpretation(partial, doc, options), .limits = limitsOf(options) };
            if (@FieldType(S.Options, "cancellation") != void) normalized.cancellation = hook;
            if (config.runtime_policy and @hasField(@TypeOf(options), "policy")) normalized.policy = execution.option(execution.Policy, options.policy);
            return execution.initLoweringResolved(S, try context(doc, memory, options), doc, normalized, effective);
        }
    };
}
