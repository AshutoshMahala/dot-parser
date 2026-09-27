//! Processor-owned WDP 0.1.0-draft Level 2 registry. Shared transport, not
//! DOT diagnostics or a universal payload. No rendering or allocation here.
const std = @import("std");
const support = @import("parser_support");
const Span = support.location.Span;
pub const reporting = support.reporting;
pub const namespace = "markup_parser";
pub const namespace_hash = support.wdp.computeNamespaceHash(namespace);

pub const Feature = enum { attributes, references, comments, cdata, processing_instructions, declarations, encoding };
pub const Resource = enum { source_bytes, nesting_depth, nodes, nesting_frames, node_pool };
pub const Expected = enum { name, tag_end, closing_angle };
pub const Code = enum {
    invalid_byte,
    unexpected_byte,
    unexpected_end,
    mismatched_tag,
    unexpected_close,
    unclosed_element,
    unsupported_feature,
    capacity_exhausted,
    out_of_memory,

    pub fn structured(self: Code) []const u8 {
        return switch (self) {
            .invalid_byte => "E.Syntax.Byte.003",
            .unexpected_byte => "E.Syntax.Grammar.003",
            .unexpected_end => "E.Syntax.Grammar.031",
            .mismatched_tag => "E.Syntax.Tag.002",
            .unexpected_close => "E.Syntax.Tag.003",
            .unclosed_element => "E.Syntax.Tag.032",
            .unsupported_feature => "E.Profile.Feature.009",
            .capacity_exhausted => "E.Resource.Capacity.026",
            .out_of_memory => "E.Resource.Memory.026",
        };
    }
    pub fn severity(_: Code) reporting.Severity {
        return .err;
    }
    pub fn compactId(self: Code) [5]u8 {
        return switch (self) {
            inline else => |code| comptime support.wdp.computeCompactId(code.structured()),
        };
    }
    pub fn qualifiedCompactId(self: Code) [11]u8 {
        return switch (self) {
            inline else => |code| comptime namespace_hash ++ "-".* ++ code.compactId(),
        };
    }
};
pub const Details = union(enum) {
    none,
    byte: u8,
    expected: Expected,
    feature: Feature,
    capacity: struct { resource: Resource, limit: u32 },
};
pub const Diagnostic = struct {
    code: Code,
    span: Span,
    /// Matching opener/name, when relevant. No copied strings or source pointer.
    related: ?Span = null,
    details: Details = .none,
};
pub const Sink = reporting.Sink(Diagnostic);
pub const discard = Sink.discard;
pub fn FixedBag(comptime capacity: usize) type {
    return reporting.FixedBag(Diagnostic, capacity, .stop);
}
pub const GrowableBag = reporting.GrowableBag(Diagnostic);

test "markup registry has unique structured and compact identities" {
    const codes = std.enums.values(Code);
    for (codes, 0..) |a, i| {
        try std.testing.expectEqual(reporting.Severity.err, a.severity());
        try std.testing.expectEqual(@as(usize, 11), a.qualifiedCompactId().len);
        for (codes[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.structured(), b.structured()));
            try std.testing.expect(!std.mem.eql(u8, &a.qualifiedCompactId(), &b.qualifiedCompactId()));
        }
    }
}
