//! Policy-bound facade. One resolution/check per operation or session init/reset.
const std = @import("std");
const policy = @import("policy.zig");
const validation = @import("validate.zig");
const engine = @import("parse_engine.zig");

pub fn Profile(comptime api: type, comptime config: policy.Config) type {
    const compiled = policy.resolve(policy.defaults, config.policy);
    switch (comptime policy.check(compiled, config.policy)) {
        .valid => {},
        .invalid => |issue| @compileError("invalid policy: " ++ @tagName(issue)),
    }
    return struct {
        pub const baseline = compiled;
        pub const runtime_policy = config.runtime_policy;
        const State = if (runtime_policy) policy.Effective else void;
        const ValidationState = if (runtime_policy) policy.ValidationSettings else void;
        const Hook = if (runtime_policy or baseline.execution.cancellation) ?api.Cancellation else void;
        const no_hook: Hook = if (Hook == void) {} else null;

        pub const Options = if (runtime_policy) struct { policy: policy.Policy = .{} } else struct {};
        pub const FixedParseOptions = if (runtime_policy) struct {
            policy: policy.Policy = .{},
            cancellation: Hook = no_hook,
        } else struct { cancellation: Hook = no_hook };
        pub const ParseOptions = if (runtime_policy) struct {
            policy: policy.Policy = .{},
            scratch_allocator: ?std.mem.Allocator = null,
            document_capacities: api.DocumentCapacities = .{},
            cancellation: Hook = no_hook,
        } else struct {
            scratch_allocator: ?std.mem.Allocator = null,
            document_capacities: api.DocumentCapacities = .{},
            cancellation: Hook = no_hook,
        };
        pub const CheckOptions = if (runtime_policy) struct {
            policy: policy.Policy = .{},
            parse: api.ParseResources = .{},
            cancellation: Hook = no_hook,
        } else struct {
            parse: api.ParseResources = .{},
            cancellation: Hook = no_hook,
        };

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
        fn validationSettings(effective: State) ValidationState {
            return if (runtime_policy) effective.validation else {};
        }

        const Variant = enum(u3) {
            scalar_immediate,
            scalar_cancellable,
            scalar_metered,
            scalar_metered_cancellable,
            block_immediate,
            block_cancellable,
            block_metered,
            block_metered_cancellable,

            fn metered(self: Variant) bool {
                return @intFromEnum(self) & 2 != 0;
            }
            fn cancellable(self: Variant) bool {
                return @intFromEnum(self) & 1 != 0;
            }
            fn backend(self: Variant) policy.ScannerBackend {
                return if (@intFromEnum(self) & 4 != 0) .block else .scalar;
            }
        };
        fn variantOf(effective: policy.Effective) Variant {
            return @enumFromInt(@as(u3, if (effective.scanner == .block) 4 else 0) |
                @as(u3, if (effective.execution.metering) 2 else 0) |
                @as(u3, if (effective.execution.cancellation) 1 else 0));
        }
        fn EngineFor(comptime variant: Variant) type {
            return engine.Engine(api, if (runtime_policy) null else baseline.parsing, variant.metered(), variant.cancellable(), variant.backend());
        }
        const FixedEngine = EngineFor(variantOf(baseline));

        fn engineOptions(comptime Core: type, effective: State, hook: Hook) Core.Options {
            return .{
                .parsing = if (runtime_policy) effective.parsing else {},
                .cancellation = if (Core.cancellation_enabled) hook else {},
            };
        }
        const Operation = enum { parseBorrowed, parseBorrowedIn, measure, measureIn };
        fn parseResolved(comptime operation: Operation, comptime Result: type, arguments: anytype, effective: State, hook: Hook) Result {
            if (runtime_policy) {
                // Select once per operation, outside the scanner/grammar loop.
                switch (variantOf(effective)) {
                    inline else => |variant| {
                        const Core = EngineFor(variant);
                        return @call(.auto, @field(Core, @tagName(operation)), arguments ++ .{engineOptions(Core, effective, hook)});
                    },
                }
            }
            return @call(.auto, @field(FixedEngine, @tagName(operation)), arguments ++ .{engineOptions(FixedEngine, effective, hook)});
        }

        /// Retain syntax in allocator-owned pools, borrowing immutable source.
        /// Source must outlive the document; release pools with result.deinit().
        /// Runtime configuration errors precede allocation and input consumption.
        pub fn parseBorrowed(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: ParseOptions) Checked(api.ParseResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            const resources: api.ParseResources = .{ .scratch_allocator = options.scratch_allocator, .document_capacities = options.document_capacities };
            return parseResolved(.parseBorrowed, api.ParseResult, .{ allocator, source, diagnostics, resources }, effective, options.cancellation);
        }
        /// Allocation-free parsing into caller pools and nesting scratch. Nothing
        /// grows; storage exhaustion fails without publishing a partial document.
        pub fn parseBorrowedIn(source: []const u8, memory: api.ParseMemory, diagnostics: api.DiagnosticSink, options: FixedParseOptions) Checked(api.FixedParseResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            return parseResolved(.parseBorrowedIn, api.FixedParseResult, .{ source, memory, diagnostics }, effective, options.cancellation);
        }
        /// Count-only dry run under the same parsing policy. Allocator backs only
        /// nesting scratch; document-capacity hints are ignored. No counts escape
        /// on failure/cancellation. Retained parsing is a separate full pass.
        pub fn measure(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: ParseOptions) Checked(api.MeasureResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            const resources: api.ParseResources = .{ .scratch_allocator = options.scratch_allocator, .document_capacities = options.document_capacities };
            return parseResolved(.measure, api.MeasureResult, .{ allocator, source, diagnostics, resources }, effective, options.cancellation);
        }
        /// Allocation-free measurement using caller-owned nesting scratch.
        pub fn measureIn(source: []const u8, scratch: api.ParseScratch, diagnostics: api.DiagnosticSink, options: FixedParseOptions) Checked(api.MeasureResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            return parseResolved(.measureIn, api.MeasureResult, .{ source, scratch, diagnostics }, effective, options.cancellation);
        }
        pub fn validate(document: *const api.Document, diagnostics: api.DiagnosticSink, options: Options) Checked(api.ValidationResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            return validateResolved(document, diagnostics, validationSettings(effective));
        }
        fn validateResolved(document: *const api.Document, diagnostics: api.DiagnosticSink, effective: ValidationState) api.ValidationResult {
            return validation.validate(if (runtime_policy) null else baseline.validation, document, diagnostics, effective);
        }
        pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: CheckOptions) Checked(api.CheckResult) {
            const effective = if (runtime_policy) try settings(options) else settings(options);
            var parsed = parseResolved(.parseBorrowed, api.ParseResult, .{ allocator, source, diagnostics, options.parse }, effective, options.cancellation);
            if (parsed.document == null) return .{ .outcome = parsed.outcome, .diagnostic_delivery = parsed.diagnostic_delivery };
            const checked = validateResolved(&parsed.document.?, diagnostics, validationSettings(effective));
            return .{
                .document = parsed.document,
                .outcome = parsed.outcome,
                .validation = checked,
                .diagnostic_delivery = if (parsed.diagnostic_delivery == .failed or checked.diagnostic_delivery == .failed) .failed else .complete,
            };
        }

        /// Fixed-storage session. Policy is latched until reset. Runtime variants
        /// use one tagged union (largest driver, not eight driver instances).
        pub const Session = struct {
            const Self = @This();
            const Drivers = union(Variant) {
                scalar_immediate: EngineFor(.scalar_immediate).Session,
                scalar_cancellable: EngineFor(.scalar_cancellable).Session,
                scalar_metered: EngineFor(.scalar_metered).Session,
                scalar_metered_cancellable: EngineFor(.scalar_metered_cancellable).Session,
                block_immediate: EngineFor(.block_immediate).Session,
                block_cancellable: EngineFor(.block_cancellable).Session,
                block_metered: EngineFor(.block_metered).Session,
                block_metered_cancellable: EngineFor(.block_metered_cancellable).Session,
            };
            driver: if (runtime_policy) Drivers else FixedEngine.Session,
            interpretation_policy: ValidationState,

            pub const Options = FixedParseOptions;
            pub const AdvanceError = error{MeteringDisabled};

            pub fn init(source: []const u8, memory: api.ParseMemory, diagnostics: api.DiagnosticSink, options: FixedParseOptions) Checked(Self) {
                const effective = if (runtime_policy) try settings(options) else settings(options);
                return initResolved(source, memory, diagnostics, effective, options.cancellation);
            }
            fn initResolved(source: []const u8, memory: api.ParseMemory, diagnostics: api.DiagnosticSink, effective: State, hook: Hook) Self {
                return .{
                    .driver = if (runtime_policy) switch (variantOf(effective)) {
                        inline else => |variant| @unionInit(Drivers, @tagName(variant), EngineFor(variant).Session.init(source, memory, diagnostics, engineOptions(EngineFor(variant), effective, hook))),
                    } else FixedEngine.Session.init(source, memory, diagnostics, engineOptions(FixedEngine, effective, hook)),
                    .interpretation_policy = validationSettings(effective),
                };
            }
            pub fn advance(self: *Self, budget: usize) (if (runtime_policy) AdvanceError!api.SessionProgress else api.SessionProgress) {
                if (runtime_policy) {
                    return switch (self.driver) {
                        inline else => |*driver, variant| if (comptime variant.metered()) driver.advance(budget) else error.MeteringDisabled,
                    };
                }
                if (!baseline.execution.metering) @compileError("metering is disabled; use run()");
                return self.driver.advance(budget);
            }
            pub fn run(self: *Self) api.FixedParseResult {
                if (runtime_policy) return switch (self.driver) {
                    inline else => |*driver| driver.run(),
                };
                return self.driver.run();
            }
            pub fn result(self: *const Self) ?api.FixedParseResult {
                if (runtime_policy) return switch (self.driver) {
                    inline else => |*driver| driver.result(),
                };
                return self.driver.result();
            }
            pub fn cancel(self: *Self) api.FixedParseResult {
                if (runtime_policy) return switch (self.driver) {
                    inline else => |*driver| driver.cancel(),
                };
                return self.driver.cancel();
            }
            pub fn deinit(self: *Self) void {
                _ = self.cancel();
            }

            /// Invalid runtime policy leaves the existing session and views intact.
            /// Successful reset cancels old work and retires all previous pool views.
            pub fn reset(self: *Self, source: []const u8, diagnostics: api.DiagnosticSink, options: FixedParseOptions) Checked(void) {
                const effective = if (runtime_policy) try settings(options) else settings(options);
                const memory: api.ParseMemory = if (runtime_policy) switch (self.driver) {
                    inline else => |*driver| .{ .document = driver.builder.storage, .scratch = .{ .frames = driver.scratch.frames } },
                } else .{ .document = self.driver.builder.storage, .scratch = .{ .frames = self.driver.scratch.frames } };
                _ = self.cancel();
                self.* = initResolved(source, memory, diagnostics, effective, options.cancellation);
            }

            /// Separate, unbudgeted analysis using the latched validation policy.
            /// No result until a document has been committed successfully.
            pub fn validate(self: *const Self, diagnostics: api.DiagnosticSink) ?api.ValidationResult {
                const parsed = self.result() orelse return null;
                const doc = &(parsed.document orelse return null);
                return validateResolved(doc, diagnostics, self.interpretation_policy);
            }
            /// Separate, unbudgeted preparation; never scans during advance().
            pub fn interpretation(self: *const Self) ?Interpretation {
                const parsed = self.result() orelse return null;
                const doc = &(parsed.document orelse return null);
                return interpretationResolved(doc, self.interpretation_policy);
            }
        };

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
            auto_kind: if (!runtime_policy and baseline.validation.graph.treated_as == .auto) policy.GraphKind else void,

            pub fn effectiveKind(self: @This(), declared: api.DeclaredGraphKind) policy.GraphKind {
                if (runtime_policy) return self.reading.kind;
                if (declared == .digraph) return .digraph;
                return switch (baseline.validation.graph.treated_as) {
                    .undigraph => .undigraph,
                    .digraph => .digraph,
                    .generic => .generic,
                    .auto => self.auto_kind,
                };
            }

            pub fn effectiveOperator(self: @This(), declared: api.DeclaredGraphKind, written: api.EdgeOperator) api.EdgeOperator {
                const reading = if (runtime_policy) self.reading.operator_reading else if (declared == .digraph)
                    baseline.validation.digraph.operator_reading
                else if (baseline.validation.graph.treated_as == .auto or baseline.validation.graph.treated_as == .generic)
                    .as_written
                else
                    baseline.validation.graph.operators.operator_reading;
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
            return interpretationResolved(document, validationSettings(effective));
        }

        fn interpretationResolved(document: *const api.Document, effective: ValidationState) Interpretation {
            if (runtime_policy) {
                const treatment = if (document.kind == .digraph) .digraph else effective.graph.treated_as;
                return .{ .reading = .{
                    .kind = kindFor(document, treatment),
                    .operator_reading = if (document.kind == .digraph) effective.digraph.operator_reading else if (treatment == .auto or treatment == .generic) .as_written else effective.graph.operators.operator_reading,
                }, .auto_kind = {} };
            }
            return .{
                .reading = {},
                .auto_kind = if (baseline.validation.graph.treated_as == .auto) kindFor(document, .auto) else {},
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
