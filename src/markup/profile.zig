//! Markup-owned compile-time baseline and default-off runtime patches. No
//! runtime registry. Resolve once, specialize execution variants.
const std = @import("std");
const policy = @import("policy.zig");
const engine = @import("engine.zig");
const validation = @import("validate.zig");
const source_validation = @import("validate_source.zig");
const syntax = @import("syntax.zig");
const scratch_impl = @import("scratch.zig");

pub fn Profile(comptime api: type, comptime config: policy.Config) type {
    const Binding = @import("parser_support").processor.PolicyBinding(policy, .{ .policy = config.policy, .runtime_policy = config.runtime_policy });
    return struct {
        const Self = @This();
        pub const Policies = Binding;
        pub const Diagnostic = api.Diagnostic;
        pub const DiagnosticSink = api.DiagnosticSink;
        pub const CheckResult = api.FragmentResult;
        pub const InputError = api.Fragment.Error;
        pub const ParseResources = api.ParseResources;
        pub const console = api.console;
        pub const baseline = Binding.baseline;
        pub const runtime_policy = config.runtime_policy;
        const State = Binding.State;
        const Hook = if (runtime_policy or baseline.execution.cancellation) ?api.Cancellation else void;
        pub const Options = if (runtime_policy) struct {
            policy: policy.Policy = .{},
            cancellation: Hook = null,
        } else struct { cancellation: Hook = if (Hook == void) {} else null };
        pub const ParseOptions = if (runtime_policy) struct {
            policy: policy.Policy = .{},
            cancellation: Hook = null,
            scratch_allocator: ?std.mem.Allocator = null,
        } else struct {
            cancellation: Hook = if (Hook == void) {} else null,
            scratch_allocator: ?std.mem.Allocator = null,
        };
        pub const validatePolicy = Binding.validatePolicy;
        /// Prepared once for any number of explicitly selected raw fragments.
        /// For a PolicySet, use .{ .policies = state.path_to_markup } instead.
        /// Policies must be produced by Policies.prepare/PolicySet.prepare;
        /// cancellation is an explicit borrowed callback, not a policy leaf.
        pub const Prepared = struct {
            policies: State,
            cancellation: Hook = if (Hook == void) {} else null,

            inline fn effective(self: @This()) policy.Effective {
                return if (runtime_policy) self.policies else baseline;
            }

            /// No allocation until processing needs capacity. The workspace owns
            /// its buffers and must be deinitialized once, never through copies.
            pub fn initWorkspace(self: @This(), allocator: std.mem.Allocator, resources: api.ParseResources) Workspace {
                return .{
                    .prepared = self,
                    .allocator = allocator,
                    .builder = .growing(&.{}, allocator),
                    .stack = .{ .allocator = resources.scratch_allocator orelse allocator },
                    .buffers = .init(.{}, allocator),
                };
            }

            /// Parse, then validate the document or recognizable source scopes.
            /// Validation is skipped after an operational parsing stop or a
            /// fail-fast syntax error. Neither
            /// this operation nor identifier operand enumeration is work-metered.
            pub fn parseAndValidate(self: @This(), allocator: std.mem.Allocator, input: api.Fragment, diagnostics: api.DiagnosticSink, resources: api.ParseResources) api.Fragment.Error!api.FragmentResult {
                var mapped = try api.diagnostic.OriginSink.init(input, diagnostics);
                const parsed = callPrepared("parseBorrowed", api.ParseResult, .{ allocator, input.bytes, mapped.sink(), resources }, self);
                return finishFragment(.allocated, input, &parsed, mapped.sink(), allocator, self);
            }

            /// Allocation-free variant. Source validation scratch is reused for
            /// document validation too; capacities/limits remain local counts.
            pub fn parseAndValidateIn(self: @This(), input: api.Fragment, memory: api.ParseMemory, scratch: api.SourceValidationScratch, diagnostics: api.DiagnosticSink) api.Fragment.Error!api.FixedFragmentResult {
                var mapped = try api.diagnostic.OriginSink.init(input, diagnostics);
                const parsed = callPrepared("parseBorrowedIn", api.FixedParseResult, .{ input.bytes, memory, mapped.sink() }, self);
                return finishFragment(.fixed, input, &parsed, mapped.sink(), scratch, self);
            }
        };
        /// Reusable per-operation storage. Results borrow its pools until the
        /// next call or deinit; source bytes remain caller-owned and unchanged.
        /// Resetting a fragment never trims buffers or prepares policy again.
        pub const Workspace = struct {
            prepared: Prepared,
            allocator: std.mem.Allocator,
            builder: syntax.Builder,
            stack: scratch_impl.Stack,
            buffers: source_validation.Buffers,

            pub fn parseAndValidate(self: *@This(), input: api.Fragment, diagnostics: api.DiagnosticSink) api.Fragment.Error!api.FixedFragmentResult {
                var mapped = try api.diagnostic.OriginSink.init(input, diagnostics);
                const parsed = callPrepared("parseReusing", api.FixedParseResult, .{ input.bytes, mapped.sink(), &self.builder, &self.stack }, self.prepared);
                return finishFragment(.reusing, input, &parsed, mapped.sink(), self, self.prepared);
            }
            /// Allocator-requested buffer capacity, excluding source, diagnostics,
            /// allocator overhead and the workspace's own constant-size value.
            pub fn reservedBytes(self: *const @This()) usize {
                return self.builder.list.capacity * @sizeOf(api.Node) + self.builder.attributes.capacity * @sizeOf(api.Attribute) +
                    self.stack.frames.len * @sizeOf(scratch_impl.Frame) + self.buffers.attributes.capacity * @sizeOf(api.ScopeAttribute) +
                    self.buffers.keys.capacity * @sizeOf(api.AttributeKeyScratch);
            }
            pub fn deinit(self: *@This()) void {
                self.builder.deinit();
                self.stack.deinit();
                self.buffers.deinit();
                self.* = undefined;
            }
        };
        const FragmentStorage = enum { allocated, fixed, reusing };

        /// One routing contract for owned, fixed and workspace-backed fragments.
        /// Storage dispatch is compile-time-only; ownership and allocation remain
        /// in the selected implementation. Never start another stage after a
        /// terminal sink acknowledgment, even if parsing retained its original
        /// syntax-failure outcome instead of replacing it with diagnostic_stopped.
        fn finishFragment(
            comptime storage: FragmentStorage,
            input: api.Fragment,
            parsed: *const (if (storage == .allocated) api.ParseResult else api.FixedParseResult),
            diagnostics: api.DiagnosticSink,
            resources: anytype,
            prepared: Prepared,
        ) if (storage == .allocated) api.FragmentResult else api.FixedFragmentResult {
            const checked: ?api.ValidationResult = if (parsed.diagnostic_stop != null or parsed.diagnostic_delivery == .failed) null else switch (parsed.outcome) {
                .success => switch (storage) {
                    .allocated => validatePrepared("allocated", .{ resources, &parsed.document.?, diagnostics }, prepared),
                    .fixed => validatePrepared("run", .{ &parsed.document.?, api.ValidationScratch{ .attribute_keys = resources.attribute_keys }, diagnostics }, prepared),
                    .reusing => validatePrepared("reusing", .{ resources.allocator, &parsed.document.?, &resources.buffers.keys, diagnostics }, prepared),
                },
                .invalid_syntax => if (prepared.effective().on_error == .collect) switch (storage) {
                    .allocated => sourceValidationPrepared("allocated", .{ resources, input.bytes, diagnostics }, prepared),
                    .fixed => sourceValidationPrepared("run", .{ input.bytes, resources, diagnostics }, prepared),
                    .reusing => sourceValidationPrepared("reusing", .{ input.bytes, &resources.buffers, diagnostics }, prepared),
                } else null,
                else => null,
            };
            return .{ .parse = parsed.*, .validation = rebaseValidation(input, checked), .has_errors = fragmentHasErrors(parsed.*, checked, prepared.effective()) };
        }

        fn fragmentHasErrors(parsed: anytype, checked: ?api.ValidationResult, effective: policy.Effective) bool {
            if (parsed.syntax_errors != 0) return true;
            switch (parsed.outcome) {
                .invalid_syntax, .resource_limit => return true,
                .unsupported_feature => return effective.diagnostics.unsupported == .err,
                else => {},
            }
            if (checked) |value| return value.errors != 0 or value.completion == .source_limit;
            return false;
        }
        pub fn prepare(options: Options) Prepared {
            return .{ .policies = resolve(options), .cancellation = options.cancellation };
        }
        fn rebaseValidation(input: api.Fragment, checked: ?api.ValidationResult) ?api.ValidationResult {
            var result = checked orelse return null;
            // Engine-produced, fragment-local coverage gap, not a resource count.
            if (result.completion == .incomplete) result.completion.incomplete += input.origin;
            return result;
        }
        pub fn parseAndValidate(allocator: std.mem.Allocator, input: api.Fragment, diagnostics: api.DiagnosticSink, options: ParseOptions) api.Fragment.Error!api.FragmentResult {
            const opts: Options = if (runtime_policy) .{ .policy = options.policy, .cancellation = options.cancellation } else .{ .cancellation = options.cancellation };
            return Self.prepare(opts).parseAndValidate(allocator, input, diagnostics, .{ .scratch_allocator = options.scratch_allocator });
        }
        pub fn parseAndValidateIn(input: api.Fragment, memory: api.ParseMemory, scratch: api.SourceValidationScratch, diagnostics: api.DiagnosticSink, options: Options) api.Fragment.Error!api.FixedFragmentResult {
            return Self.prepare(options).parseAndValidateIn(input, memory, scratch, diagnostics);
        }
        fn resolve(options: Options) State {
            if (!runtime_policy) return {};
            // Enforce today's infallible API at compile time. If the schema
            // gains invalid combinations, propagate its errors instead of
            // silently discarding them or treating them as unreachable.
            const prepared: error{}!State = Binding.prepare(.{ .policy = options.policy });
            return prepared catch unreachable;
        }

        // Same bit layout as DOT: cancellation=1, metering=2, block=4.
        const Variant = enum(u3) {
            plain,
            cancellable,
            metered,
            both,
            block_plain,
            block_cancellable,
            block_metered,
            block_both,
            fn metering(v: Variant) bool {
                return @intFromEnum(v) & 2 != 0;
            }
            fn cancellation(v: Variant) bool {
                return @intFromEnum(v) & 1 != 0;
            }
            fn backend(v: Variant) policy.ScannerBackend {
                return if (@intFromEnum(v) & 4 != 0) .block else .scalar;
            }
        };
        fn variantOf(effective: policy.Effective) Variant {
            return @enumFromInt(@as(u3, if (effective.scanner == .block) 4 else 0) |
                @as(u3, if (effective.execution.metering) 2 else 0) |
                @as(u3, if (effective.execution.cancellation) 1 else 0));
        }
        fn Core(comptime variant: Variant) type {
            return engine.Engine(api, variant.backend(), if (runtime_policy) null else baseline.parsing(), variant.metering(), variant.cancellation());
        }
        fn settings(comptime variant: Variant, effective: State) Core(variant).Settings {
            return if (runtime_policy) effective.parsing() else {};
        }
        fn hook(comptime variant: Variant, value: Hook) Core(variant).Hook {
            return if (comptime variant.cancellation()) value else {};
        }
        fn call(comptime method: []const u8, comptime T: type, args: anytype, options: Options) T {
            return callPrepared(method, T, args, prepare(options));
        }
        fn callPrepared(comptime method: []const u8, comptime T: type, args: anytype, options: Prepared) T {
            const effective = options.policies;
            if (runtime_policy) switch (variantOf(effective)) {
                inline else => |v| return @call(.auto, @field(Core(v), method), args ++ .{ settings(v, effective), hook(v, options.cancellation) }),
            };
            const v = comptime variantOf(baseline);
            return @call(.auto, @field(Core(v), method), args ++ .{ settings(v, effective), hook(v, options.cancellation) });
        }

        /// Retains source-shaped records with the caller allocator. Source stays
        /// borrowed; dispose the result explicitly. No partial document escapes.
        pub fn parseBorrowed(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: ParseOptions) api.ParseResult {
            const opts: Options = if (runtime_policy) .{ .policy = options.policy, .cancellation = options.cancellation } else .{ .cancellation = options.cancellation };
            return call("parseBorrowed", api.ParseResult, .{ allocator, source, diagnostics, api.ParseResources{ .scratch_allocator = options.scratch_allocator } }, opts);
        }
        /// No allocations. The source and output pools outlive the view.
        pub fn parseBorrowedIn(source: []const u8, memory: api.ParseMemory, diagnostics: api.DiagnosticSink, options: Options) api.FixedParseResult {
            return call("parseBorrowedIn", api.FixedParseResult, .{ source, memory, diagnostics }, options);
        }
        /// Count-only execution; output records are not materialized. On success,
        /// counts.nodes/attributes size output, max_depth is safe scratch capacity.
        pub fn measureIn(source: []const u8, scratch: api.ParseScratch, diagnostics: api.DiagnosticSink, options: Options) api.Report {
            return call("measureIn", api.Report, .{ source, scratch, diagnostics }, options);
        }
        pub fn measure(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: Options) api.Report {
            return call("measure", api.Report, .{ allocator, source, diagnostics }, options);
        }

        fn Validator(comptime v: Variant) type {
            return validation.Validator(if (runtime_policy) null else baseline.validation, v.cancellation());
        }
        fn validateCall(comptime method: []const u8, args: anytype, options: Options) api.ValidationResult {
            return validatePrepared(method, args, prepare(options));
        }
        fn validatePrepared(comptime method: []const u8, args: anytype, options: Prepared) api.ValidationResult {
            const effective = options.policies;
            if (runtime_policy) switch (variantOf(effective)) {
                inline else => |v| return @call(.auto, @field(Validator(v), method), args ++ .{ effective.validation, hook(v, options.cancellation) }),
            };
            const v = comptime variantOf(baseline);
            return @call(.auto, @field(Validator(v), method), args ++ .{ {}, hook(v, options.cancellation) });
        }
        /// Independent, run-to-completion validation; never changes syntax.
        /// Parse metering does not bound this pass or its sorting/callbacks.
        pub fn validateIn(document: *const api.Document, scratch: api.ValidationScratch, diagnostics: api.DiagnosticSink, options: Options) api.ValidationResult {
            return validateCall("run", .{ document, scratch, diagnostics }, options);
        }
        /// Allocates temporary duplicate-key scratch when needed, freed before
        /// returning. Encoding/name/reference-only validation needs no allocation.
        pub fn validate(allocator: std.mem.Allocator, document: *const api.Document, diagnostics: api.DiagnosticSink, options: Options) api.ValidationResult {
            return validateCall("allocated", .{ allocator, document, diagnostics }, options);
        }

        /// Check an independently recognizable region; no enclosing tree needed.
        /// Caller-built original-source spans are checked in every build mode;
        /// invalid metadata returns invalid_scope, without source diagnostics.
        pub fn validateScopeIn(source: []const u8, scope: api.ValidationScope, scratch: api.ValidationScratch, diagnostics: api.DiagnosticSink, options: Options) api.ValidationResult {
            return validateCall("runScope", .{ source, scope, scratch, diagnostics }, options);
        }
        pub fn validateScope(allocator: std.mem.Allocator, source: []const u8, scope: api.ValidationScope, diagnostics: api.DiagnosticSink, options: Options) api.ValidationResult {
            return validateCall("allocatedScope", .{ allocator, source, scope, diagnostics }, options);
        }
        fn SourceValidator(comptime v: Variant) type {
            return source_validation.Validator(v.backend(), if (runtime_policy) null else baseline, v.cancellation());
        }
        fn sourceValidationCall(comptime method: []const u8, args: anytype, options: Options) api.ValidationResult {
            return sourceValidationPrepared(method, args, prepare(options));
        }
        fn sourceValidationPrepared(comptime method: []const u8, args: anytype, options: Prepared) api.ValidationResult {
            const effective = options.policies;
            if (runtime_policy) switch (variantOf(effective)) {
                inline else => |v| return @call(.auto, @field(SourceValidator(v), method), args ++ .{ effective, hook(v, options.cancellation) }),
            };
            const v = comptime variantOf(baseline);
            return @call(.auto, @field(SourceValidator(v), method), args ++ .{ {}, hook(v, options.cancellation) });
        }
        /// Local validation without a Document. This does not check tag balance
        /// or replace parsing; incomplete lexical regions cannot be certified.
        /// Like document validation, this operation is not work-credit metered.
        pub fn validateSourceIn(source: []const u8, scratch: api.SourceValidationScratch, diagnostics: api.DiagnosticSink, options: Options) api.ValidationResult {
            return sourceValidationCall("run", .{ source, scratch, diagnostics }, options);
        }
        pub fn validateSource(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: Options) api.ValidationResult {
            return sourceValidationCall("allocated", .{ allocator, source, diagnostics }, options);
        }

        const Inner = if (runtime_policy) union(Variant) {
            plain: Core(.plain).Session,
            cancellable: Core(.cancellable).Session,
            metered: Core(.metered).Session,
            both: Core(.both).Session,
            block_plain: Core(.block_plain).Session,
            block_cancellable: Core(.block_cancellable).Session,
            block_metered: Core(.block_metered).Session,
            block_both: Core(.block_both).Session,
        } else Core(variantOf(baseline)).Session;
        pub const Session = struct {
            inner: Inner,
            pub fn init(source: []const u8, memory: api.ParseMemory, diagnostics: api.DiagnosticSink, options: Options) @This() {
                const effective = resolve(options);
                if (runtime_policy) switch (variantOf(effective)) {
                    inline else => |v| return .{ .inner = @unionInit(Inner, @tagName(v), Core(v).Session.init(source, memory, diagnostics, settings(v, effective), hook(v, options.cancellation))) },
                };
                const v = comptime variantOf(baseline);
                return .{ .inner = Core(v).Session.init(source, memory, diagnostics, settings(v, effective), hook(v, options.cancellation)) };
            }
            pub fn run(self: *@This()) api.FixedParseResult {
                if (runtime_policy) return switch (self.inner) {
                    inline else => |*s| s.run(),
                };
                return self.inner.run();
            }
            pub fn advance(self: *@This(), budget: u32) (if (runtime_policy) error{MeteringDisabled}!api.Progress else api.Progress) {
                if (runtime_policy) return switch (self.inner) {
                    .plain, .cancellable, .block_plain, .block_cancellable => error.MeteringDisabled,
                    inline .metered, .both, .block_metered, .block_both => |*s| s.advance(budget),
                };
                return self.inner.advance(budget);
            }
            pub fn result(self: *const @This()) ?api.FixedParseResult {
                if (runtime_policy) return switch (self.inner) {
                    inline else => |*s| s.result(),
                };
                return self.inner.result();
            }
            pub fn cancel(self: *@This()) api.FixedParseResult {
                if (runtime_policy) return switch (self.inner) {
                    inline else => |*s| s.cancel(),
                };
                return self.inner.cancel();
            }
            pub fn deinit(self: *@This()) void {
                _ = self.cancel();
            }
            /// Reuses caller memory. Previous document views must be retired.
            /// Each reset inherits the compiled baseline, not the last override.
            pub fn reset(self: *@This(), source: []const u8, diagnostics: api.DiagnosticSink, options: Options) void {
                const memory = if (runtime_policy) switch (self.inner) {
                    inline else => |*s| s.memory,
                } else self.inner.memory;
                self.deinit();
                self.* = init(source, memory, diagnostics, options);
            }
        };
    };
}
