//! Markup-owned compile-time baseline and default-off runtime patches. No
//! processor registry/composition. Resolve once, specialize execution variants.
const std = @import("std");
const policy = @import("policy.zig");
const engine = @import("engine.zig");

pub fn Profile(comptime api: type, comptime config: policy.Config) type {
    return struct {
        const Self = @This();
        pub const baseline = policy.resolve(policy.defaults, config.policy);
        pub const runtime_policy = config.runtime_policy;
        comptime {
            _ = policy.check(baseline);
        }
        const State = if (runtime_policy) policy.Effective else void;
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
        pub const validatePolicy = if (runtime_policy) checkRuntime else checkFixed;
        fn checkFixed(comptime input: policy.Policy) policy.Check {
            return comptime policy.check(policy.resolve(baseline, input));
        }
        fn checkRuntime(input: policy.Policy) policy.Check {
            return policy.check(policy.resolve(baseline, input));
        }
        fn resolve(options: Options) State {
            if (!runtime_policy) return {};
            const effective = policy.resolve(baseline, options.policy);
            _ = policy.check(effective);
            return effective;
        }

        const Variant = enum { plain, metered, cancellable, both };
        fn variantOf(effective: policy.Effective) Variant {
            return if (effective.execution.metering) (if (effective.execution.cancellation) .both else .metered) else (if (effective.execution.cancellation) .cancellable else .plain);
        }
        fn Core(comptime variant: Variant) type {
            return engine.Engine(api, if (runtime_policy) null else baseline.limits, variant == .metered or variant == .both, variant == .cancellable or variant == .both);
        }
        fn settings(comptime variant: Variant, effective: State) Core(variant).Settings {
            return if (runtime_policy) effective.limits else {};
        }
        fn hook(comptime variant: Variant, value: Hook) Core(variant).Hook {
            return if (variant == .cancellable or variant == .both) value else {};
        }
        fn call(comptime method: []const u8, comptime T: type, args: anytype, options: Options) T {
            const effective = resolve(options);
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
        /// No allocations. The source and both storage regions outlive the view.
        pub fn parseBorrowedIn(source: []const u8, memory: api.ParseMemory, diagnostics: api.DiagnosticSink, options: Options) api.FixedParseResult {
            return call("parseBorrowedIn", api.FixedParseResult, .{ source, memory, diagnostics }, options);
        }
        /// Count-only execution; output records are not materialized. On success,
        /// counts.nodes sizes fixed output, max_depth is safe scratch capacity.
        pub fn measureIn(source: []const u8, scratch: api.ParseScratch, diagnostics: api.DiagnosticSink, options: Options) api.Report {
            return call("measureIn", api.Report, .{ source, scratch, diagnostics }, options);
        }
        pub fn measure(allocator: std.mem.Allocator, source: []const u8, diagnostics: api.DiagnosticSink, options: Options) api.Report {
            return call("measure", api.Report, .{ allocator, source, diagnostics }, options);
        }

        const Inner = if (runtime_policy) union(Variant) {
            plain: Core(.plain).Session,
            metered: Core(.metered).Session,
            cancellable: Core(.cancellable).Session,
            both: Core(.both).Session,
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
                    .plain, .cancellable => error.MeteringDisabled,
                    inline .metered, .both => |*s| s.advance(budget),
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
                    inline else => |s| s.memory,
                } else self.inner.memory;
                self.deinit();
                self.* = init(source, memory, diagnostics, options);
            }
        };
    };
}
