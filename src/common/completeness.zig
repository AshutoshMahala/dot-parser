//! Local representation state, independent of validity or work completion.
//! Whether an inner processor was requested is a separate scheduling fact.
pub const Completeness = enum { not_processed, partial, complete };
