//! Processor-owned WDP 0.1.0-draft Level 2 registry. Shared transport, not
//! DOT diagnostics or a universal payload. No rendering or allocation here.
const std = @import("std");
const support = @import("parser_support");
const wdp = support.wdp;
const Span = support.location.Span;
pub const reporting = support.reporting;
pub const namespace = "markup_parser";
pub const namespace_hash = support.wdp.computeNamespaceHash(namespace);
pub const Severity = reporting.Severity;
pub const SequenceDefinition = wdp.SequenceDefinition;
pub const Sequence = struct {
    pub const mismatch = wdp.Sequence.mismatch;
    pub const invalid = wdp.Sequence.invalid;
    pub const duplicate = wdp.Sequence.duplicate;
    pub const unsupported = wdp.Sequence.unsupported;
    pub const exhausted = wdp.Sequence.exhausted;
    pub const unexpected_end: SequenceDefinition = .{ .number = 31, .alias = "UNEXPECTED_END" };
    pub const unterminated: SequenceDefinition = .{ .number = 32, .alias = "UNTERMINATED" };
};
pub const Component = enum {
    syntax,
    validation,
    resource,
    profile,
    pub fn name(self: Component) []const u8 {
        return switch (self) {
            .syntax => "Syntax",
            .validation => "Validation",
            .resource => "Resource",
            .profile => "Profile",
        };
    }
};
pub const Primary = enum {
    byte,
    grammar,
    tag,
    feature,
    capacity,
    memory,
    attribute,
    reference,
    encoding,
    identifier,
    pub fn name(self: Primary) []const u8 {
        return switch (self) {
            .byte => "Byte",
            .grammar => "Grammar",
            .tag => "Tag",
            .feature => "Feature",
            .capacity => "Capacity",
            .memory => "Memory",
            .attribute => "Attribute",
            .reference => "Reference",
            .encoding => "Encoding",
            .identifier => "Name",
        };
    }
};

pub const Feature = enum { processing_instructions, declarations, encoding };
pub const Resource = enum { source_bytes, nesting_depth, nodes, attributes, nesting_frames, node_pool, attribute_pool, attribute_keys };
pub const Expected = enum { name, tag_end, closing_angle, equal_sign, quote, attribute_separator, attribute_value, declaration_start, comment_start, comment_end, cdata_start, cdata_end };
pub const ReferenceProblem = enum { missing_name, missing_digits, missing_semicolon, invalid_character };
pub const NameContext = enum { element, attribute, reference };
pub const NameProblem = enum { invalid_start, invalid_character, invalid_utf8 };
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
    invalid_utf8,
    invalid_utf8_tolerated,
    invalid_name,
    invalid_name_tolerated,
    unknown_reference,
    unknown_reference_tolerated,

    const Metadata = wdp.Catalog(Component, Primary);
    pub const Info = Metadata.Info;
    pub fn info(self: Code) Info {
        const definition: Metadata.Definition = switch (self) {
            .invalid_byte => .{
                .severity = .err,
                .component = .syntax,
                .primary = .byte,
                .sequence = Sequence.invalid,
                .summary = "invalid byte in markup",
                .hint = "remove the forbidden byte; parsing does not replace or transcode input bytes",
            },
            .unexpected_byte => .{
                .severity = .err,
                .component = .syntax,
                .primary = .grammar,
                .sequence = Sequence.invalid,
                .summary = "unexpected byte in markup syntax",
                .hint = "check the expected construct at this location; attributes require quoted values and elements require matching closing tags or '/>'",
            },
            .unexpected_end => .{
                .severity = .err,
                .component = .syntax,
                .primary = .grammar,
                .sequence = Sequence.unexpected_end,
                .summary = "input ended inside a markup construct",
                .hint = "complete the unfinished tag, quoted value, comment or CDATA section",
            },
            .mismatched_tag => .{
                .severity = .err,
                .component = .syntax,
                .primary = .tag,
                .sequence = Sequence.mismatch,
                .summary = "closing tag does not match the open element",
                .hint = "close the most recently opened element using exactly the same name; name matching is byte-exact and case-sensitive",
            },
            .unexpected_close => .{
                .severity = .err,
                .component = .syntax,
                .primary = .tag,
                .sequence = Sequence.invalid,
                .summary = "closing tag has no open element",
                .hint = "add the intended opening tag or remove this closing tag; the parser does not infer missing elements",
            },
            .unclosed_element => .{
                .severity = .err,
                .component = .syntax,
                .primary = .tag,
                .sequence = Sequence.unterminated,
                .summary = "input ended before an element was closed",
                .hint = "add matching closing tags in reverse opening order, or use '/>' for an intentionally empty element",
            },
            .unsupported_feature => .{
                .severity = .err,
                .component = .profile,
                .primary = .feature,
                .sequence = Sequence.unsupported,
                .summary = "unsupported markup feature",
                .hint = "this structural parser does not process declarations, processing instructions or UTF-16/32 input; supply a supported fragment",
            },
            .capacity_exhausted => .{
                .severity = .err,
                .component = .resource,
                .primary = .capacity,
                .sequence = Sequence.exhausted,
                .summary = "markup resource capacity exhausted",
                .hint = "raise the relevant policy limit or provide larger caller-owned storage; the input may still be valid",
            },
            .out_of_memory => .{
                .severity = .err,
                .component = .resource,
                .primary = .memory,
                .sequence = Sequence.exhausted,
                .summary = "allocator could not provide markup storage",
                .hint = "provide sufficient allocator capacity or use fixed pools sized for the fragment",
            },
            .duplicate_attribute, .duplicate_attribute_tolerated => .{
                .severity = if (self == .duplicate_attribute) .err else .warning,
                .component = .validation,
                .primary = .attribute,
                .sequence = Sequence.duplicate,
                .summary = "repeated attribute name on one element",
                .hint = "choose the intended attribute value or change the validation policy; every occurrence remains retained",
            },
            .malformed_reference, .malformed_reference_tolerated => .{
                .severity = if (self == .malformed_reference) .err else .warning,
                .component = .syntax,
                .primary = .reference,
                .sequence = Sequence.invalid,
                .summary = "malformed markup reference",
                .hint = "use '&name;', '&#123;' or '&#x7B;'; tolerated candidates remain literal source bytes and are not expanded",
            },
            .invalid_utf8, .invalid_utf8_tolerated => .{
                .severity = if (self == .invalid_utf8) .err else .warning,
                .component = .validation,
                .primary = .encoding,
                .sequence = Sequence.invalid,
                .summary = "invalid UTF-8 byte sequence",
                .hint = "supply UTF-8 input or disable the optional encoding check for raw-byte processing; no bytes were replaced",
            },
            .invalid_name, .invalid_name_tolerated => .{
                .severity = if (self == .invalid_name) .err else .warning,
                .component = .validation,
                .primary = .identifier,
                .sequence = Sequence.invalid,
                .summary = "name violates the selected name rule",
                .hint = "use a name accepted by the selected rule or disable that optional check; source spelling is preserved",
            },
            .unknown_reference, .unknown_reference_tolerated => .{
                .severity = if (self == .unknown_reference) .err else .warning,
                .component = .validation,
                .primary = .reference,
                .sequence = Sequence.invalid,
                .summary = "reference name is absent from the selected catalog",
                .hint = "use a known reference or change the catalog policy; catalog validation does not expand references",
            },
        };
        return definition.info();
    }
    const Identity = wdp.Registry(Code, namespace);
    pub const severity = Identity.severity;
    pub const structured = Identity.structured;
    pub const compactId = Identity.compactId;
    pub const qualifiedCompactId = Identity.qualifiedCompactId;
};
comptime {
    wdp.Registry(Code, namespace).validate();
}
pub const Details = union(enum) {
    none,
    byte: u8,
    expected: Expected,
    feature: Feature,
    capacity: struct { resource: Resource, limit: u32 },
    reference: ReferenceProblem,
    name: struct { context: NameContext, problem: NameProblem },
};
pub const Diagnostic = struct {
    code: Code,
    span: Span,
    /// Matching opener/name, when relevant. No copied strings or source pointer.
    related: ?Span = null,
    details: Details = .none,
    /// A compact offer, not a retained copy of a full edit. Materialize through
    /// suggestedFix() only when consumed. This fits existing payload padding.
    fix: ?Repair = null,

    pub fn suggestedFix(self: Diagnostic) ?Fix {
        const repair = self.fix orelse return null;
        switch (repair) {
            .terminate_reference => {
                // Be defensive for caller-created diagnostics too.
                if ((self.code != .malformed_reference and self.code != .malformed_reference_tolerated) or
                    self.details != .reference or self.details.reference != .missing_semicolon or
                    self.span.len == 0 or self.span.len > std.math.maxInt(u32) - self.span.start) return null;
                return .{ .span = .{ .start = self.span.start + self.span.len, .len = 0 }, .edit = .{ .insert_before = .semicolon }, .applicability = .maybe };
            },
        }
    }

    pub inline fn withFixes(self: Diagnostic, mode: reporting.Fixes) Diagnostic {
        var result = self;
        // Every currently supported markup repair is only a possible repair:
        // a malformed reference may have been intended as literal text.
        if (!mode.allows(.maybe)) result.fix = null;
        return result;
    }
};
pub const Repair = enum(u1) { terminate_reference };
pub const Fix = reporting.Fix(Replacement);
pub const Edit = Fix.Edit;
pub const Applicability = reporting.Applicability;
pub const Replacement = enum(u1) {
    semicolon,
    pub fn text(_: Replacement) []const u8 {
        return ";";
    }
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
