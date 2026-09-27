//! Processor-owned WDP 0.1.0-draft Level 2 registry. Shared transport, not
//! DOT diagnostics or a universal payload. No rendering or allocation here.
const std = @import("std");
const support = @import("parser_support");
const Span = support.location.Span;
pub const reporting = support.reporting;
pub const namespace = "markup_parser";
pub const namespace_hash = support.wdp.computeNamespaceHash(namespace);

pub const Feature = enum { processing_instructions, declarations, encoding };
pub const Resource = enum { source_bytes, nesting_depth, nodes, attributes, nesting_frames, node_pool, attribute_pool, attribute_keys };
pub const Expected = enum { name, tag_end, closing_angle, equal_sign, quote, attribute_separator, attribute_value, declaration_start, comment_start, comment_end, cdata_start, cdata_end };
pub const ReferenceProblem = enum { missing_name, missing_digits, missing_semicolon, invalid_character };
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
    duplicate_attribute,
    duplicate_attribute_tolerated,
    malformed_reference,
    malformed_reference_tolerated,

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
            .duplicate_attribute => "E.Validation.Attribute.006",
            .duplicate_attribute_tolerated => "W.Validation.Attribute.006",
            .malformed_reference => "E.Syntax.Reference.003",
            .malformed_reference_tolerated => "W.Syntax.Reference.003",
        };
    }
    pub fn severity(self: Code) reporting.Severity {
        return if (self == .duplicate_attribute_tolerated or self == .malformed_reference_tolerated) .warning else .err;
    }
    pub fn compactId(self: Code) [5]u8 {
        @setEvalBranchQuota(5000);
        return switch (self) {
            inline else => |code| comptime support.wdp.computeCompactId(code.structured()),
        };
    }
    pub fn qualifiedCompactId(self: Code) [11]u8 {
        @setEvalBranchQuota(5000);
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
    reference: ReferenceProblem,
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
        try std.testing.expectEqual(a.severity().letter(), a.structured()[0]);
        try std.testing.expectEqual(@as(usize, 11), a.qualifiedCompactId().len);
        for (codes[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.structured(), b.structured()));
            try std.testing.expect(!std.mem.eql(u8, &a.qualifiedCompactId(), &b.qualifiedCompactId()));
        }
    }
}
