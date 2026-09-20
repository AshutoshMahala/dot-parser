//! Typed policy input, baseline inheritance and source-independent verification.
//! No parser, storage, diagnostics renderer or allocator dependency.

pub const GraphKind = enum { undigraph, digraph, generic };
pub const GraphTreatment = enum { undigraph, digraph, generic, auto };
pub const RuleSeverity = enum { err, warning, off };
pub const OperatorReading = enum { as_written, conform_to_kind };

/// One input schema for compiled baselines and per-operation runtime patches.
/// null inherits the baseline leaf; omitted sibling branches never reset.
pub const Policy = struct {
    validation: Validation = .{},

    pub const Validation = struct {
        /// Selected by the written graph keyword, even when treated as digraph.
        graph: Graph = .{},
        /// Selected by the written digraph keyword; its kind cannot change.
        digraph: Operators = .{},
    };
    pub const Graph = struct {
        treated_as: ?GraphTreatment = null,
        operator_mismatch: ?RuleSeverity = null,
        operator_reading: ?OperatorReading = null,
    };
    pub const Operators = struct {
        operator_mismatch: ?RuleSeverity = null,
        operator_reading: ?OperatorReading = null,
    };
};

/// Fully resolved settings, never attached to retained syntax.
pub const Effective = struct {
    graph: Graph = .{},
    digraph: Operators = .{},

    pub const Graph = struct {
        treated_as: GraphTreatment = .undigraph,
        operators: Operators = .{},
    };
    pub const Operators = struct {
        operator_mismatch: RuleSeverity = .err,
        operator_reading: OperatorReading = .as_written,
    };
};

pub const defaults: Effective = .{};

pub fn resolve(baseline: Effective, input: Policy) Effective {
    const graph = input.validation.graph;
    const digraph = input.validation.digraph;
    return .{
        .graph = .{
            .treated_as = graph.treated_as orelse baseline.graph.treated_as,
            .operators = .{
                .operator_mismatch = graph.operator_mismatch orelse baseline.graph.operators.operator_mismatch,
                .operator_reading = graph.operator_reading orelse baseline.graph.operators.operator_reading,
            },
        },
        .digraph = .{
            .operator_mismatch = digraph.operator_mismatch orelse baseline.digraph.operator_mismatch,
            .operator_reading = digraph.operator_reading orelse baseline.digraph.operator_reading,
        },
    };
}

/// Configuration errors are not DOT diagnostics and have no source location.
pub const Error = error{
    GraphOperatorMismatchNotApplicable,
    GraphOperatorReadingNotApplicable,
};

pub const Issue = enum {
    graph_operator_mismatch_not_applicable,
    graph_operator_reading_not_applicable,

    pub fn asError(self: Issue) Error {
        return switch (self) {
            .graph_operator_mismatch_not_applicable => error.GraphOperatorMismatchNotApplicable,
            .graph_operator_reading_not_applicable => error.GraphOperatorReadingNotApplicable,
        };
    }
};
pub const Check = union(enum) { valid, invalid: Issue };

/// Verify the resolved treatment and this input's explicitly supplied fields.
/// Inherited concrete settings stay dormant under generic/auto; explicitly
/// requesting an inapplicable control is rejected, even its default value.
/// If both fields are invalid, mismatch is reported first, deterministically.
pub fn check(effective: Effective, input: Policy) Check {
    if (effective.graph.treated_as == .generic or effective.graph.treated_as == .auto) {
        if (input.validation.graph.operator_mismatch != null)
            return .{ .invalid = .graph_operator_mismatch_not_applicable };
        if (input.validation.graph.operator_reading != null)
            return .{ .invalid = .graph_operator_reading_not_applicable };
    }
    return .valid;
}

pub const Config = struct {
    policy: Policy = .{},
    runtime_policy: bool = false,
};

test "omitted leaves inherit without changing the sibling header branch" {
    const std = @import("std");
    const baseline = resolve(defaults, .{ .validation = .{
        .graph = .{ .treated_as = .digraph, .operator_mismatch = .warning, .operator_reading = .conform_to_kind },
        .digraph = .{ .operator_mismatch = .off },
    } });
    try std.testing.expectEqualDeep(baseline, resolve(baseline, .{}));
    const effective = resolve(baseline, .{ .validation = .{ .graph = .{ .operator_mismatch = .err } } });
    try std.testing.expectEqual(GraphTreatment.digraph, effective.graph.treated_as);
    try std.testing.expectEqual(RuleSeverity.err, effective.graph.operators.operator_mismatch);
    try std.testing.expectEqual(OperatorReading.conform_to_kind, effective.graph.operators.operator_reading);
    try std.testing.expectEqualDeep(baseline.digraph, effective.digraph);
}

test "mode changes retain dormant concrete values and never reset the other branch" {
    const std = @import("std");
    const baseline = resolve(defaults, .{ .validation = .{
        .graph = .{ .operator_mismatch = .warning, .operator_reading = .conform_to_kind },
        .digraph = .{ .operator_mismatch = .off },
    } });
    inline for (.{ .generic, .auto }) |treatment| {
        const patch: Policy = .{ .validation = .{ .graph = .{ .treated_as = treatment } } };
        const dormant = resolve(baseline, patch);
        try std.testing.expect(check(dormant, patch) == .valid);
        const restored = resolve(dormant, .{ .validation = .{ .graph = .{ .treated_as = .undigraph } } });
        try std.testing.expectEqualDeep(baseline, restored);
    }
}

test "verification is identical at both binding times for every mode and optional control" {
    const std = @import("std");
    inline for ([_]GraphTreatment{ .undigraph, .digraph, .generic, .auto }) |treatment| {
        inline for ([_]?RuleSeverity{ null, .err, .warning, .off }) |severity| {
            inline for ([_]?OperatorReading{ null, .as_written, .conform_to_kind }) |reading| {
                const input: Policy = .{ .validation = .{ .graph = .{
                    .treated_as = treatment,
                    .operator_mismatch = severity,
                    .operator_reading = reading,
                } } };
                const effective = resolve(defaults, input);
                const checked = check(effective, input);
                const static = comptime check(resolve(defaults, input), input);
                try std.testing.expectEqualDeep(static, checked);
                const flexible = treatment == .generic or treatment == .auto;
                if (flexible and severity != null) {
                    try std.testing.expectEqual(Issue.graph_operator_mismatch_not_applicable, checked.invalid);
                } else if (flexible and reading != null) {
                    try std.testing.expectEqual(Issue.graph_operator_reading_not_applicable, checked.invalid);
                } else {
                    try std.testing.expect(checked == .valid);
                }
            }
        }
    }
}
