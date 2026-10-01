//! Control-flow vocabulary, independent of storage and retained syntax.
const diagnostic = @import("diagnostic.zig");
pub const Outcome = union(enum) {
    success,
    invalid_syntax,
    unsupported_feature: diagnostic.Feature,
    resource_limit: struct { resource: diagnostic.Resource, limit: u32 },
    storage_exhausted: diagnostic.Resource,
    out_of_memory,
    cancelled,
    sink_failure,
    diagnostic_stopped: diagnostic.reporting.StopReason,
};
pub const Counts = struct { nodes: u32 = 0, elements: u32 = 0, attributes: u32 = 0, max_depth: u32 = 0 };
pub const Completion = enum { incomplete, complete };
pub const Report = struct {
    outcome: Outcome,
    /// Complete only after EOF and all pending structural checks. Independent
    /// of validity: recovery can finish completely with invalid_syntax.
    completion: Completion = .incomplete,
    /// Factual rejected syntax findings, including the finding that stops a sink.
    /// Survives later operational failure; resource/unsupported findings excluded.
    syntax_errors: u32 = 0,
    diagnostic_delivery: diagnostic.reporting.Delivery = .complete,
    /// Recognized constructs (including after recovery), not retained records
    /// or a sizing promise on failure. Enforced limits still cover these counts.
    counts: Counts = .{},
    /// Each tolerated ampersand counts once, even if reporting or later work stops.
    accepted_deviations: u32 = 0,
    warnings: u32 = 0,
};
pub const Problem = struct { outcome: Outcome, diagnostic: diagnostic.Diagnostic };
pub const Progress = struct {
    outcome: ?Outcome,
    work_used: u32,
    source_frontier: u32,
    counts: Counts,
    accepted_deviations: u32 = 0,
    warnings: u32 = 0,
    syntax_errors: u32 = 0,
};
