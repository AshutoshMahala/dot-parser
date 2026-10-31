//! Parse/check/lower once, releasing the temporary syntax document. Module and
//! profile-bound conveniences share admission, acceptance and ownership rules.
const std = @import("std");
const dot = @import("../root.zig");
const ir_api = @import("../ir.zig");
const execution = @import("execution_policy.zig");
const IR = ir_api.Lowering(.{});
const Default = Bound(IR, .{}, true);
pub const Options = Default.Options;
pub const Result = Default.Result;
pub const PartialResult = Default.PartialResult;
pub const parse = Default.parse;
pub const parsePartial = Default.parsePartial;

pub const CheckSummary = struct {
    outcome: dot.ParseOutcome,
    completion: dot.Completion,
    syntax_errors: u32,
    validation: ?dot.ValidationResult,
    diagnostic_delivery: dot.diagnostic.Delivery,
    diagnostic_stop: ?dot.diagnostic.StopReason,
    accepted_deviations: u32,
    warnings: u64,

    fn from(result: *const dot.CheckResult) CheckSummary {
        return .{
            .outcome = result.outcome,
            .completion = result.completion,
            .syntax_errors = result.syntax_errors,
            .validation = result.validation,
            .diagnostic_delivery = result.diagnostic_delivery,
            .diagnostic_stop = result.diagnostic_stop,
            .accepted_deviations = result.accepted_deviations,
            .warnings = result.warnings,
        };
    }
};

fn ResultFor(comptime Graph: type) type {
    return struct {
        checking: CheckSummary,
        _graph: ?Graph = null,
        /// Borrows this result; keep it alive and unmoved. Checking distinguishes
        /// rejected input from unfinished work when no graph is available.
        pub fn ir(self: *const @This()) ?*const Graph {
            return if (self._graph) |*graph| graph else null;
        }
        pub fn deinit(self: *@This()) void {
            if (self._graph) |*graph| graph.deinit();
            self.* = undefined;
        }
    };
}

pub fn Bound(comptime Profile: type, comptime config: ir_api.Config, comptime module_convenience: bool) type {
    const Dot = dot.Profile(.{ .source_encodings = config.source_encodings });
    const PartialDot = dot.Profile(.{ .source_encodings = config.source_encodings, .policy = .{ .retention = .{ .partial = true } } });
    const Checked = @typeInfo(@typeInfo(@TypeOf(Dot.parseAndValidate)).@"fn".return_type.?);
    const ParseErrors = if (Checked == .error_union) Checked.error_union.error_set else error{};
    const Errors = ir_api.Error || ParseErrors || if (config.runtime_policy) execution.ValidationError else error{};
    return struct {
        const Self = @This();
        pub const Options = struct {
            diagnostics: dot.DiagnosticSink = dot.diagnostic.discard,
            dot: Dot.CheckOptions = .{},
            /// Independent lowering policy/resources, never a shared DOT budget.
            lowering: if (module_convenience) ir_api.Options else execution.OptionsFor(config) = .{},
        };
        pub const Result = ResultFor(Profile.Graph);
        pub const PartialResult = ResultFor(Profile.PartialGraph);
        pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: Self.Options) Errors!Self.Result {
            return run(false, allocator, source, options);
        }
        pub fn parsePartial(allocator: std.mem.Allocator, source: []const u8, options: Self.Options) Errors!Self.PartialResult {
            return run(true, allocator, source, options);
        }
        fn run(comptime partial: bool, allocator: std.mem.Allocator, source: []const u8, options: Self.Options) Errors!ResultFor(if (partial) Profile.PartialGraph else Profile.Graph) {
            const Parser = if (partial) PartialDot else Dot;
            const parsed = Parser.parseAndValidate(allocator, source, options.diagnostics, options.dot);
            var checked = if (@typeInfo(@TypeOf(parsed)) == .error_union) try parsed else parsed;
            defer checked.deinit(allocator);
            var result: ResultFor(if (partial) Profile.PartialGraph else Profile.Graph) = .{ .checking = .from(&checked) };
            if (checked.document == null or checked.diagnostic_stop != null or checked.diagnostic_delivery != .complete) return result;
            if (!partial) {
                if (!checked.documentValid()) return result;
            } else {
                switch (checked.outcome) {
                    .success, .invalid_syntax, .unsupported_feature => {},
                    else => return result,
                }
                if (checked.validation) |validation| switch (validation.outcome) {
                    .completed => {},
                    else => return result,
                };
                if (checked.document.?.strict) if (checked.validation) |validation| {
                    if (validation.outcome.completed.violations != 0) return result;
                };
            }
            const document = &checked.document.?;
            result._graph = lower(partial, allocator, document, Parser.interpretation(document, .{}), options.lowering) catch |err| {
                if (partial and err == error.UnsupportedSemantics) return result;
                return err;
            };
            return result;
        }
        fn lower(comptime partial: bool, allocator: std.mem.Allocator, document: *const dot.Document, interpretation: anytype, options: @FieldType(Self.Options, "lowering")) Errors!(if (partial) Profile.PartialGraph else Profile.Graph) {
            if (module_convenience) return lowerChecked(partial, allocator, document, interpretation, options);
            if (config.runtime_policy) {
                const opts = .{ .interpretation = interpretation, .limits = options.limits, .cancellation = options.cancellation, .policy = options.policy };
                return if (partial) Profile.lowerPartial(allocator, document, opts) else Profile.lowerComplete(allocator, document, opts);
            }
            const opts = .{ .interpretation = interpretation, .limits = options.limits, .cancellation = options.cancellation };
            return if (partial) Profile.lowerPartial(allocator, document, opts) else Profile.lowerComplete(allocator, document, opts);
        }
    };
}

fn lowerChecked(comptime partial: bool, allocator: std.mem.Allocator, document: *const dot.Document, interpretation: anytype, options: ir_api.Options) ir_api.Error!(if (partial) IR.PartialGraph else IR.Graph) {
    // This convenience API has no IR profile argument. Its explicit hook opts
    // into a cancellable profile; ordinary calls retain the default fast path.
    if (options.cancellation) |hook| {
        const Cancellable = ir_api.Lowering(.{ .policy = .{ .execution = .{ .cancellation = true } } });
        const opts = .{ .interpretation = interpretation, .limits = options.limits, .cancellation = hook };
        return if (partial) Cancellable.lowerPartial(allocator, document, opts) else Cancellable.lowerComplete(allocator, document, opts);
    }
    const opts = .{ .interpretation = interpretation, .limits = options.limits };
    return if (partial) IR.lowerPartial(allocator, document, opts) else IR.lowerComplete(allocator, document, opts);
}
