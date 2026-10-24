//! Default-policy convenience path: parse once, validate, lower, release syntax
//! storage. The source and diagnostic destination remain caller-owned.
const std = @import("std");
const dot = @import("../root.zig");
const ir_api = @import("../ir.zig");
const IR = ir_api.Lowering(.{});

pub const Options = struct {
    diagnostics: dot.DiagnosticSink = dot.diagnostic.discard,
    /// Resources for ordinary default-policy DOT parsing and validation.
    dot: dot.CheckOptions = .{},
    /// Limits/cancellation for lowering only, not a shared parsing budget.
    lowering: ir_api.Options = .{},
};

/// The DOT result's facts without its temporary Document or allocation handles.
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

pub const Result = struct {
    checking: CheckSummary,
    _graph: ?IR.Graph = null,

    /// A complete accepted IR, or null if DOT checking rejected/stopped.
    /// Inspect checking to distinguish invalid input from unfinished work.
    /// The pointer is borrowed from this result; keep it alive and unmoved.
    pub fn ir(self: *const Result) ?*const IR.Graph {
        return if (self._graph) |*graph| graph else null;
    }

    pub fn deinit(self: *Result) void {
        if (self._graph) |*graph| graph.deinit();
        self.* = undefined;
    }
};

/// UTF-8/default DOT policy, with the same diagnostics and acceptance rules as
/// dot.parseAndValidate. Custom profiles use Lowering.lowerComplete explicitly.
/// Lowering failures are errors; DOT rejections/stops retain their report.
/// No source copy, reparsing, edge expansion, or retained Document pools.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: Options) ir_api.Error!Result {
    var checked = dot.parseAndValidate(allocator, source, options.diagnostics, options.dot);
    defer checked.deinit(allocator);
    var result: Result = .{ .checking = .from(&checked) };
    if (!checked.documentValid() or checked.diagnostic_stop != null or checked.diagnostic_delivery != .complete) return result;
    const document = &checked.document.?;
    result._graph = try IR.lowerComplete(allocator, document, .{
        .interpretation = dot.Profile(.{}).interpretation(document, .{}),
        .limits = options.lowering.limits orelse ir_api.Limits{},
        .cancellation = options.lowering.cancellation,
    });
    return result;
}

pub const PartialResult = struct {
    checking: CheckSummary,
    _graph: ?IR.PartialGraph = null,
    pub fn ir(self: *const PartialResult) ?*const IR.PartialGraph {
        return if (self._graph) |*graph| graph else null;
    }
    pub fn deinit(self: *PartialResult) void {
        if (self._graph) |*graph| graph.deinit();
        self.* = undefined;
    }
};

/// Default-policy editor route: partial retention and collection are opt-in
/// through this entry point. Checking rejection never becomes acceptance.
/// Deliberate stops never automatically launch a second computation.
pub fn parsePartial(allocator: std.mem.Allocator, source: []const u8, options: Options) ir_api.Error!PartialResult {
    const Dot = dot.Profile(.{ .policy = .{ .retention = .{ .partial = true } } });
    var checked = Dot.parseAndValidate(allocator, source, options.diagnostics, options.dot);
    defer checked.deinit(allocator);
    var result: PartialResult = .{ .checking = .from(&checked) };
    if (checked.document == null or checked.diagnostic_stop != null or checked.diagnostic_delivery != .complete) return result;
    switch (checked.outcome) {
        .success, .invalid_syntax, .unsupported_feature => {},
        else => return result,
    }
    if (checked.validation) |validation| switch (validation.outcome) {
        .completed => {},
        else => return result,
    };
    const document = &checked.document.?;
    result._graph = try IR.lowerPartial(allocator, document, .{
        .interpretation = Dot.interpretation(document, .{}),
        .limits = options.lowering.limits orelse ir_api.Limits{},
        .cancellation = options.lowering.cancellation,
    });
    return result;
}
