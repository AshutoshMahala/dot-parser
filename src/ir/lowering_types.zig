//! Shared continuation records; storage strategy does not change semantics.
const syntax = @import("../dot/syntax.zig");
const t = @import("topology.zig");
const names = @import("names.zig");
pub const ScopeCursor = struct { first: u32 = 0, next: u32 = 0, head: u32 = names.empty };
pub const ScopeFrame = struct { occurrence: u32, cursor: u32, end: u32 };
pub const EdgeFrame = struct {
    occurrence: u32,
    first: syntax.EdgeView,
    links: syntax.EdgeLinkIterator,
    phase: u2 = 0,
    pending_start: u32,
    statement_index: u32,
};
pub const Frame = union(enum) { scope: ScopeFrame, edge: u32 };
pub const Pending = union(enum) { node: t.Endpoint, scope: t.ScopeId };
