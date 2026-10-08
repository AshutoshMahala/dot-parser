//! Local representation state, independent of validity or work completion.
//! Whether an inner processor was requested is a separate scheduling fact.
pub const Completeness = enum {
    /// Reserved for scopes whose processing has not begun. Current parsers do
    /// not publish this state; an unstarted parse has no Document.
    not_processed,
    partial,
    complete,
};
