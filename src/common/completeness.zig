//! Local representation state, independent of validity or work completion.
//! Whether an inner processor was requested is a separate scheduling fact.
pub const Completeness = enum {
    /// Scope representation has not been produced. Composition uses this for
    /// pending children; whether work was requested remains a separate fact.
    /// Standalone parsers publish no Document before their work begins.
    not_processed,
    partial,
    complete,
    /// No scope tree was returned. This is not a complete zero-node document,
    /// pending child work, or a retained partial tree; inspect the parse outcome
    /// separately for the reason representation is unavailable.
    empty,
};
