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
};
pub const Counts = struct { nodes: u32 = 0, elements: u32 = 0, max_depth: u32 = 0 };
pub const Report = struct {
    outcome: Outcome,
    diagnostic_delivery: diagnostic.reporting.Delivery = .complete,
    /// Accepted prefix events, not a promise of a completed document on failure.
    counts: Counts = .{},
};
pub const Problem = struct { outcome: Outcome, diagnostic: diagnostic.Diagnostic };
pub const Progress = struct {
    outcome: ?Outcome,
    work_used: u32,
    source_frontier: u32,
    counts: Counts,
};
