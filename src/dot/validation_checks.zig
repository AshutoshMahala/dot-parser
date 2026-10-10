//! Independent, lazy finding streams. Each produces source-ordered diagnostics;
//! validate.zig merges only the streams reachable under the compiled policy.
const std = @import("std");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
const identifier = @import("identifier_value.zig");
const location = @import("parser_support").location;
const D = diagnostic.Diagnostic;
const Settings = policy.ValidationSettings;
const none = std.math.maxInt(u32);

/// Temporary only. Contents are unspecified after validation and may be reused.
/// Size with requiredScratch; a working group is reused across attribute owners.
pub const AttributeKeyScratch = struct {
    hash: u64,
    index: u32,
    first: u32,
};

pub const Scratch = struct {
    /// Size with requiredValidationScratch when repeated_attribute is enabled.
    /// Must not alias source, document pools, or diagnostic storage.
    attribute_keys: []AttributeKeyScratch = &.{},
};

fn attributeRange(document: *const syntax.Document, id: syntax.StatementId) syntax.AttributeRange {
    return switch (id) {
        .node => |i| document.nodes[i].attributes,
        .edge => |i| document.edges[i].attributes,
        .edge_chain => |i| document.edge_chains[i].first.attributes,
        .scoped_edge => |i| document.scoped_edges[i].first.attributes,
        .attribute_statement => |i| document.attribute_statements[i].attributes,
        .assignment, .subgraph => .{},
    };
}

pub const DuplicatePlan = struct {
    largest: u32 = 0,
    extra: u32 = 0,
    order: enum { statements, nodes, edges, edge_chains, attribute_statements, bitmap, ranges } = .statements,
    pub fn required(self: DuplicatePlan) u32 {
        return self.largest + self.extra;
    }
};

/// Pure metadata pass. No source scan, allocation, or document mutation.
pub fn duplicatePlan(document: *const syntax.Document) DuplicatePlan {
    var plan: DuplicatePlan = .{};
    if (document.attributes.len < 2) return plan;
    if (document.scoped_edges.len == 0) {
        // These pools commit in attribute-source order. Ignore assignments and
        // empty/singleton lists: they cannot contain a duplicate key. A single
        // relevant pool can also bypass statement dispatch during validation.
        var active_pools: u32 = 0;
        inline for (.{ "nodes", "edges", "edge_chains", "attribute_statements" }) |name| {
            var active = false;
            for (@field(document, name)) |record| {
                const range = if (comptime std.mem.eql(u8, name, "edge_chains")) record.first.attributes else record.attributes;
                if (range.len < 2) continue;
                plan.largest = @max(plan.largest, range.len);
                active = true;
            }
            if (active) {
                active_pools += 1;
                plan.order = if (active_pools == 1) @field(@FieldType(DuplicatePlan, "order"), name) else .statements;
            }
        }
        return plan;
    }
    var previous: u32 = 0;
    var groups: u32 = 0;
    var ordered = true;
    for (document.order) |id| {
        const range = attributeRange(document, id);
        if (range.len < 2) continue;
        plan.largest = @max(plan.largest, range.len);
        groups += 1;
        if (range.start < previous) ordered = false;
        previous = range.start;
    }
    if (!ordered) {
        // Scoped-edge owners precede their descendants in statement order,
        // while their trailing attributes follow those descendants. Mark both
        // endpoints of each nontrivial group to traverse in lexical order.
        const words: u32 = @intCast(document.attributes.len / 64 + @intFromBool(document.attributes.len % 64 != 0));
        plan.extra = @min(words, groups);
        plan.order = if (words <= groups) .bitmap else .ranges;
        // For a few very large groups, explicit ranges are smaller than a bitmap.
        // groups >= 2; each non-largest group has >= 2 entries, hence
        // largest + groups <= total attributes. Scratch never exceeds the old
        // full-document requirement, even on the adversarial single-big-owner case.
        std.debug.assert(plan.required() <= document.attributes.len);
    }
    return plan;
}

pub fn requiredScratch(document: *const syntax.Document) u32 {
    return duplicatePlan(document).required();
}

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
            const len = @import("parser_support").utf8.sequenceLength(self.source[start..]) orelse return self.invalid();
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
    metadata: []AttributeKeyScratch = &.{},
    plan: DuplicatePlan = .{},
    severity: policy.RuleSeverity,
    index: u32 = 0,
    count: u32 = 0,
    statement_index: u32 = 0,
    metadata_index: u32 = 0,

    pub fn init(document: *const syntax.Document, settings: Settings, scratch: Scratch, plan: DuplicatePlan) RepeatedAttributes {
        if (settings.repeated_attribute == .off) return .{ .document = document, .entries = &.{}, .severity = .off };
        const entries = scratch.attribute_keys[0..plan.largest];
        const metadata = scratch.attribute_keys[plan.largest..plan.required()];
        if (plan.order == .bitmap or plan.order == .ranges) {
            if (plan.order == .bitmap) for (metadata) |*entry| {
                entry.hash = 0;
            };
            var written: u32 = 0;
            for (document.order) |id| {
                const range = attributeRange(document, id);
                if (range.len < 2) continue;
                if (plan.order == .bitmap) {
                    const end = range.start + range.len - 1;
                    metadata[range.start / 64].hash |= @as(u64, 1) << @as(u6, @intCast(range.start % 64));
                    metadata[end / 64].hash |= @as(u64, 1) << @as(u6, @intCast(end % 64));
                } else {
                    metadata[written] = .{ .hash = 0, .index = range.start, .first = range.len };
                    written += 1;
                }
            }
            if (plan.order == .ranges) std.sort.heap(AttributeKeyScratch, metadata, {}, indexLessThan);
        }
        return .{ .document = document, .entries = entries, .metadata = metadata, .plan = plan, .severity = settings.repeated_attribute };
    }

    pub fn next(self: *RepeatedAttributes) ?D {
        if (self.entries.len == 0) return null;
        while (true) {
            while (self.index < self.count) {
                const entry = self.entries[self.index];
                self.index += 1;
                if (entry.first == none) continue;
                return .{
                    .code = severityCode(self.severity, .validation_repeated_attribute, .validation_repeated_attribute_tolerated),
                    .span = self.document.attributes[entry.index].key,
                    .details = .{ .repeated_attribute = self.document.attributes[entry.first].key },
                };
            }
            const range = self.nextRange() orelse return null;
            self.prepare(range);
        }
    }

    fn nextMark(self: *RepeatedAttributes) ?u32 {
        while (self.metadata_index < self.metadata.len) {
            const bits = &self.metadata[self.metadata_index].hash;
            if (bits.* == 0) {
                self.metadata_index += 1;
                continue;
            }
            const at = self.metadata_index * 64 + @as(u32, @intCast(@ctz(bits.*)));
            bits.* &= bits.* - 1;
            return at;
        }
        return null;
    }

    fn nextRange(self: *RepeatedAttributes) ?syntax.AttributeRange {
        switch (self.plan.order) {
            .statements => while (self.statement_index < self.document.order.len) {
                const range = attributeRange(self.document, self.document.order[self.statement_index]);
                self.statement_index += 1;
                if (range.len >= 2) return range;
            },
            inline .nodes, .edges, .edge_chains, .attribute_statements => |pool| {
                const records = @field(self.document, @tagName(pool));
                while (self.statement_index < records.len) {
                    const record = records[self.statement_index];
                    self.statement_index += 1;
                    const range = if (comptime pool == .edge_chains) record.first.attributes else record.attributes;
                    if (range.len >= 2) return range;
                }
            },
            .bitmap => {
                const start = self.nextMark() orelse return null;
                const end = self.nextMark().?;
                return .{ .start = start, .len = end - start + 1 };
            },
            .ranges => {
                if (self.metadata_index == self.metadata.len) return null;
                const range = self.metadata[self.metadata_index];
                self.metadata_index += 1;
                return .{ .start = range.index, .len = range.first };
            },
        }
        return null;
    }

    fn prepare(self: *RepeatedAttributes, range: syntax.AttributeRange) void {
        const group = self.entries[0..range.len];
        const attributes = self.document.attributes[range.start..][0..range.len];
        for (group, attributes, range.start..) |*entry, attribute, index| {
            entry.* = .{ .hash = identifier.hashAssumeValid(attribute.key.slice(self.document.source)), .index = @intCast(index), .first = none };
        }
        // Bound quadratic comparisons to eight keys. Source order is already
        // correct; first matching predecessor is the original occurrence.
        if (group.len <= 8) {
            for (group, 0..) |*entry, i| {
                for (group[0..i]) |previous| {
                    if (entry.hash == previous.hash and equalKeys(self.document, previous.index, entry.index)) {
                        entry.first = previous.index;
                        break;
                    }
                }
            }
            self.index = 0;
            self.count = range.len;
            return;
        }
        std.sort.heap(AttributeKeyScratch, group, self.document, keyLessThan);
        var first = group[0].index;
        for (group[1..], group[0 .. group.len - 1]) |*entry, previous| {
            if (entry.hash == previous.hash and equalKeys(self.document, first, entry.index)) entry.first = first else first = entry.index;
        }
        std.sort.heap(AttributeKeyScratch, group, {}, indexLessThan);
        self.index = 0;
        self.count = range.len;
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
