//! Policy-bound facade. Graph policy is the first vertical slice; existing
//! parser limits/recovery/execution/backend controls are not migrated here yet.
const std = @import("std");
const policy = @import("policy.zig");
const validation = @import("validate.zig");

pub fn Profile(comptime api: type, comptime config: policy.Config) type {
    const compiled = policy.resolve(policy.defaults, config.policy);
    // The same pure checker serves both binding times.
    switch (comptime policy.check(compiled, config.policy)) {
        .valid => {},
        .invalid => |issue| @compileError("invalid policy: " ++ @tagName(issue)),
    }
    return struct {
        pub const baseline = compiled;
        pub const runtime_policy = config.runtime_policy;
        const State = if (runtime_policy) policy.Effective else void;

        pub const Options = if (runtime_policy) struct {
            policy: policy.Policy = .{},
        } else struct {};

        pub const CheckOptions = if (runtime_policy) struct {
            parse: api.ParseOptions = .{},
            policy: policy.Policy = .{},
        } else struct {
            parse: api.ParseOptions = .{},
        };

        /// Same name and input schema at both binding times. A fixed profile
        /// accepts only comptime input; it has no runtime verification entry.
        pub const validatePolicy = if (runtime_policy) checkRuntime else checkFixed;

        fn checkFixed(comptime input: policy.Policy) policy.Check {
            return comptime policy.check(policy.resolve(baseline, input), input);
        }

        fn checkRuntime(input: policy.Policy) policy.Check {
            return policy.check(policy.resolve(baseline, input), input);
        }

        fn Checked(comptime T: type) type {
            return if (runtime_policy) policy.Error!T else T;
        }

        fn settings(options: anytype) Checked(State) {
            if (!runtime_policy) return {};
            const effective = policy.resolve(baseline, options.policy);
            return switch (policy.check(effective, options.policy)) {
                .valid => effective,
                .invalid => |issue| issue.asError(),
            };
        }

        /// Source parsing remains kind-agnostic; use validate for staged policy
        /// application. These aliases have the existing resource/limit options.
        pub const parseBorrowed = api.parseBorrowed;
        pub const parseBorrowedIn = api.parseBorrowedIn;

        pub fn validate(document: *const api.Document, diagnostics: api.DiagnosticSink, options: Options) Checked(api.ValidationResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            return validateResolved(document, diagnostics, effective);
        }

        fn validateResolved(document: *const api.Document, diagnostics: api.DiagnosticSink, effective: State) api.ValidationResult {
            return validation.validateWith(if (runtime_policy) null else baseline, document, diagnostics, effective);
        }

        /// Resolve/verify before allocating or reading input. No settings are
        /// attached to the returned syntax document, which remains source truth.
        pub fn parseAndValidate(
            allocator: std.mem.Allocator,
            source: []const u8,
            diagnostics: api.DiagnosticSink,
            options: CheckOptions,
        ) Checked(api.CheckResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            var parsed = api.parseBorrowed(allocator, source, diagnostics, options.parse);
            if (parsed.document == null) return .{
                .outcome = parsed.outcome,
                .diagnostic_delivery = parsed.diagnostic_delivery,
            };
            const checked = validateResolved(&parsed.document.?, diagnostics, effective);
            return .{
                .document = parsed.document,
                .outcome = parsed.outcome,
                .validation = checked,
                .diagnostic_delivery = if (parsed.diagnostic_delivery == .failed or checked.diagnostic_delivery == .failed) .failed else .complete,
            };
        }

        /// Prepared for one immutable document. Do not reuse it for another
        /// document, especially with auto treatment. No source mutation or
        /// per-edge policy state. Fixed concrete profiles need no instance state;
        /// fixed auto retains one input-derived kind, not runtime policy.
        pub const Interpretation = struct {
            const Reading = struct {
                kind: policy.GraphKind,
                operator_reading: policy.OperatorReading,
            };
            reading: if (runtime_policy) Reading else void,
            auto_kind: if (!runtime_policy and baseline.graph.treated_as == .auto) policy.GraphKind else void,

            pub fn effectiveKind(self: @This(), declared: api.DeclaredGraphKind) policy.GraphKind {
                if (runtime_policy) return self.reading.kind;
                if (declared == .digraph) return .digraph;
                return switch (baseline.graph.treated_as) {
                    .undigraph => .undigraph,
                    .digraph => .digraph,
                    .generic => .generic,
                    .auto => self.auto_kind,
                };
            }

            pub fn effectiveOperator(self: @This(), declared: api.DeclaredGraphKind, written: api.EdgeOperator) api.EdgeOperator {
                const reading = if (runtime_policy) self.reading.operator_reading else if (declared == .digraph)
                    baseline.digraph.operator_reading
                else if (baseline.graph.treated_as == .auto or baseline.graph.treated_as == .generic)
                    .as_written
                else
                    baseline.graph.operators.operator_reading;
                if (reading == .as_written) return written;
                return switch (self.effectiveKind(declared)) {
                    .generic => written,
                    .digraph => .directed,
                    .undigraph => .undirected,
                };
            }
        };

        /// Auto scans syntax edges once (stopping at the first directed edge).
        /// Subsequent kind/operator queries are O(1), with no allocation. Other
        /// treatments require no scan. Parsing itself stays kind-agnostic.
        pub fn interpretation(document: *const api.Document, options: Options) Checked(Interpretation) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            if (runtime_policy) {
                const treatment = if (document.kind == .digraph) .digraph else effective.graph.treated_as;
                return .{ .reading = .{
                    .kind = kindFor(document, treatment),
                    .operator_reading = if (document.kind == .digraph) effective.digraph.operator_reading else if (treatment == .auto or treatment == .generic) .as_written else effective.graph.operators.operator_reading,
                }, .auto_kind = {} };
            }
            return .{
                .reading = {},
                .auto_kind = if (baseline.graph.treated_as == .auto) kindFor(document, .auto) else {},
            };
        }

        fn kindFor(document: *const api.Document, treatment: policy.GraphTreatment) policy.GraphKind {
            if (document.kind == .digraph) return .digraph;
            return switch (treatment) {
                .undigraph => .undigraph,
                .digraph => .digraph,
                .generic => .generic,
                .auto => blk: {
                    var edges = document.edgeIterator();
                    while (edges.next()) |edge| {
                        if (edge.operator == .directed) break :blk .generic;
                    }
                    break :blk .undigraph;
                },
            };
        }
    };
}
