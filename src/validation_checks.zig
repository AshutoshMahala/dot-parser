//! Independent, lazy finding streams. Each produces source-ordered diagnostics;
//! validate.zig merges only the streams reachable under the compiled policy.
const std = @import("std");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
const identifier = @import("identifier_value.zig");
const location = @import("location.zig");
const D = diagnostic.Diagnostic;
const Settings = policy.ValidationSettings;
const none = std.math.maxInt(u32);

/// Temporary only. Contents are unspecified after validation and may be reused.
/// One element per Document.attributes entry when repeated_attribute is enabled.
pub const AttributeKeyScratch = struct {
    hash: u64,
    index: u32,
    first: u32,
};

pub const Scratch = struct {
    /// Must not alias source, document pools, or diagnostic storage.
    attribute_keys: []AttributeKeyScratch = &.{},
};

pub const Operators = struct {
    edges: syntax.EdgeIterator,
    document: *const syntax.Document,
    operators: Settings.Operators,
    treatment: policy.GraphTreatment,
    enabled: bool,

    pub fn init(document: *const syntax.Document, settings: Settings, _: Scratch) Operators {
        const operators = if (document.kind == .digraph) settings.digraph else settings.graph.operators;
        return .{
            .edges = document.edgeIterator(),
            .document = document,
            .operators = operators,
            .treatment = settings.graph.treated_as,
            .enabled = operators.operator_mismatch != .off and (document.kind == .digraph or
                (settings.graph.treated_as != .auto and settings.graph.treated_as != .generic)),
        };
    }

    pub fn next(self: *Operators) ?D {
        if (!self.enabled) return null;
        const expected: syntax.EdgeOperator = if (self.document.kind == .digraph or self.treatment == .digraph) .directed else .undirected;
        while (self.edges.next()) |edge| {
            if (edge.operator == expected) continue;
            return .{
                .code = severityCode(self.operators.operator_mismatch, .validation_operator_mismatch, .validation_operator_tolerated),
                .span = edge.operator_range,
                .details = .{ .operator_mismatch = .{
                    .expected = operatorDetail(expected),
                    .found = operatorDetail(edge.operator),
                    .declaration = self.document.keyword,
                    .reading = if (self.operators.operator_reading == .as_written) .as_written else .conform_to_kind,
                    .kind_overridden = self.document.kind == .undigraph and self.treatment == .digraph,
                    .suggest_header_change = self.treatment != .digraph,
                } },
                .fix = .{
                    .span = edge.operator_range,
                    .edit = .{ .replace = if (expected == .directed) .directed_operator else .undirected_operator },
                    .applicability = if (self.operators.operator_reading == .conform_to_kind) .machine_applicable else .maybe,
                },
            };
        }
        return null;
    }
};

pub const Encoding = struct {
    source: []const u8,
    severity: policy.RuleSeverity,
    offset: u32 = 0,

    pub fn init(document: *const syntax.Document, settings: Settings, _: Scratch) Encoding {
        return .{ .source = document.source, .severity = settings.invalid_utf8 };
    }

    pub fn next(self: *Encoding) ?D {
        if (self.severity == .off) return null;
        while (self.offset < self.source.len) {
            const start = self.offset;
            const byte = self.source[start];
            if (byte < 0x80) {
                self.offset += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(byte) catch return self.invalid();
            if (len > self.source.len - start) return self.invalid();
            _ = std.unicode.utf8Decode(self.source[start..][0..len]) catch return self.invalid();
            self.offset += len;
        }
        return null;
    }

    /// Bytewise recovery: every byte not consumed by a valid sequence is one
    /// finding. Never swallows a subsequent ASCII byte or valid sequence.
    fn invalid(self: *Encoding) D {
        const start = self.offset;
        self.offset += 1;
        return .{
            .code = severityCode(self.severity, .validation_invalid_utf8, .validation_invalid_utf8_tolerated),
            .span = .{ .start = start, .len = 1 },
            .details = .{ .invalid_utf8 = self.source[start] },
        };
    }
};

pub const RepeatedAttributes = struct {
    document: *const syntax.Document,
    entries: []AttributeKeyScratch,
    severity: policy.RuleSeverity,
    index: u32 = 0,

    pub fn init(document: *const syntax.Document, settings: Settings, scratch: Scratch) RepeatedAttributes {
        if (settings.repeated_attribute == .off) return .{ .document = document, .entries = &.{}, .severity = .off };
        const entries = scratch.attribute_keys[0..document.attributes.len]; // preflighted by validate
        for (document.attributes, entries, 0..) |attribute, *entry, index| {
            entry.* = .{ .hash = identifier.hashAssumeValid(attribute.key.slice(document.source)), .index = @intCast(index), .first = none };
        }
        // Each owner's adjacent [...] groups form one range. A chain owns its
        // attributes once; separate statements/defaults/scopes never merge.
        for (document.order) |id| {
            const range: syntax.AttributeRange = switch (document.statement(id).?) {
                .node => |node| node.attributes,
                .edge => |edge| edge.attributes,
                .edge_chain => |chain| chain.first.attributes,
                .attribute_statement => |statement| statement.attributes,
                .assignment, .subgraph => continue,
            };
            if (range.len < 2) continue;
            const group = entries[range.start..][0..range.len];
            std.sort.heap(AttributeKeyScratch, group, document, keyLessThan);
            var first: u32 = group[0].index;
            for (group[1..], group[0 .. group.len - 1]) |*entry, previous| {
                if (entry.hash == previous.hash and equalKeys(document, first, entry.index)) {
                    entry.first = first;
                } else first = entry.index;
            }
            // Restore source order without changing document pools. Fingerprints
            // accelerate comparisons but never establish equality on their own.
            std.sort.heap(AttributeKeyScratch, group, {}, indexLessThan);
        }
        return .{ .document = document, .entries = entries, .severity = settings.repeated_attribute };
    }

    pub fn next(self: *RepeatedAttributes) ?D {
        while (self.index < self.entries.len) {
            const entry = self.entries[self.index];
            self.index += 1;
            if (entry.first == none) continue;
            return .{
                .code = severityCode(self.severity, .validation_repeated_attribute, .validation_repeated_attribute_tolerated),
                .span = self.document.attributes[entry.index].key,
                .details = .{ .repeated_attribute = self.document.attributes[entry.first].key },
            };
        }
        return null;
    }

    fn keyLessThan(document: *const syntax.Document, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
        if (a.hash != b.hash) return a.hash < b.hash;
        const order = identifier.orderAssumeValid(document.attributes[a.index].key.slice(document.source), document.attributes[b.index].key.slice(document.source));
        return if (order == .eq) a.index < b.index else order == .lt;
    }
    fn equalKeys(document: *const syntax.Document, a: u32, b: u32) bool {
        return identifier.orderAssumeValid(document.attributes[a].key.slice(document.source), document.attributes[b].key.slice(document.source)) == .eq;
    }
    fn indexLessThan(_: void, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
        return a.index < b.index;
    }
};

pub const Ports = struct {
    values: []const syntax.PortedReference,
    severity: policy.RuleSeverity,
    index: u32 = 0,

    pub fn init(document: *const syntax.Document, settings: Settings, _: Scratch) Ports {
        return .{ .values = document.ported_references, .severity = settings.restrictions.ports };
    }
    pub fn next(self: *Ports) ?D {
        if (self.severity == .off or self.index == self.values.len) return null;
        const port = self.values[self.index].port;
        self.index += 1;
        const last = port.second orelse port.first;
        return restricted(self.severity, .{ .start = port.first.start, .len = last.start + last.len - port.first.start }, .port);
    }
};

pub const Subgraphs = struct {
    document: *const syntax.Document,
    severity: policy.RuleSeverity,
    index: u32 = 0,

    pub fn init(document: *const syntax.Document, settings: Settings, _: Scratch) Subgraphs {
        return .{ .document = document, .severity = settings.restrictions.subgraphs };
    }
    pub fn next(self: *Subgraphs) ?D {
        if (self.severity == .off or self.index == self.document.subgraph_records.len) return null;
        const source = self.document.subgraph_records[self.index].source;
        self.index += 1;
        return restricted(self.severity, .{ .start = source.start, .len = if (self.document.source[source.start] == '{') 1 else 8 }, .subgraph);
    }
};

pub const GraphKinds = struct {
    document: *const syntax.Document,
    settings: Settings,
    done: bool = false,

    pub fn init(document: *const syntax.Document, settings: Settings, _: Scratch) GraphKinds {
        return .{ .document = document, .settings = settings };
    }
    pub fn next(self: *GraphKinds) ?D {
        if (self.done) return null;
        self.done = true;
        const kinds = self.settings.restrictions.graph_kinds;
        if (kinds.undigraph == .off and kinds.digraph == .off and kinds.generic == .off) return null;
        const kind = kindFor(self.document, self.settings.graph.treated_as);
        const severity = switch (kind) {
            .undigraph => kinds.undigraph,
            .digraph => kinds.digraph,
            .generic => kinds.generic,
        };
        if (severity == .off) return null;
        return restricted(severity, self.document.keyword, switch (kind) {
            .undigraph => .undigraph,
            .digraph => .digraph,
            .generic => .generic,
        });
    }
};

/// Shared with interpretation so auto has exactly one definition.
pub fn kindFor(document: *const syntax.Document, treatment: policy.GraphTreatment) policy.GraphKind {
    if (document.kind == .digraph) return .digraph;
    return switch (treatment) {
        .undigraph => .undigraph,
        .digraph => .digraph,
        .generic => .generic,
        .auto => blk: {
            var edges = document.edgeIterator();
            while (edges.next()) |edge| if (edge.operator == .directed) break :blk .generic;
            break :blk .undigraph;
        },
    };
}

fn severityCode(severity: policy.RuleSeverity, err: diagnostic.Code, warning: diagnostic.Code) diagnostic.Code {
    return switch (severity) {
        .err => err,
        .warning => warning,
        .off => unreachable,
    };
}
fn restricted(severity: policy.RuleSeverity, span: location.Span, kind: @FieldType(diagnostic.Details, "restriction")) D {
    return .{ .code = severityCode(severity, .validation_restriction, .validation_restriction_tolerated), .span = span, .details = .{ .restriction = kind } };
}
fn operatorDetail(operator: syntax.EdgeOperator) diagnostic.OperatorMismatch.Operator {
    return if (operator == .directed) .directed else .undirected;
}
