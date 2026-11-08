//! Private transaction records shared by growable and fixed event construction.
const std = @import("std");
const syntax = @import("../dot/syntax.zig");
const e = @import("../dot/events.zig");
const Span = @import("parser_support").location.Span;
const none = std.math.maxInt(u32);
pub const Endpoint = union(enum) { node: syntax.NodeReferenceView, scope: u32 };
pub const Link = struct { right: Endpoint, operator: syntax.EdgeOperator, span: Span, next: u32 = none };
pub const Statement = struct {
    occurrence: u32,
    next: u32 = none,
    attributes: syntax.AttributeRange = .{},
    first_link: u32 = none,
    last_link: u32 = none,
    value: union(enum) { pending, node: e.Node, edge: e.Edge, scoped_edge: e.Edge, scope: u32, assignment: syntax.Attribute, defaults: syntax.AttributeTarget } = .pending,
};
pub const Scope = struct { occurrence: u32, first: u32 = none, last: u32 = none, active: u32 = none, parent: u32 = 0 };
pub const Replay = union(enum) {
    scope: struct { scope: u32, statement: u32 },
    statement: u32,
    edge: struct { statement: u32, phase: u32 = 0, link: u32, pending: u32 },
};
pub const PartialStatement = struct {
    first_child: u32 = none,
    last_child: u32 = none,
    gap: ?Span = null,
    // Certified prefixes of rejected edges are checked, never made connections.
    prefix: bool = false,
    committed: bool = false,
    certified_end: u32 = 0,
};
pub const PartialScope = struct { next: u32 = none, closed: bool = false };
