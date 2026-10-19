const std = @import("std");
const support = @import("parser_support");
const policy = @import("policy.zig");
const diagnostics = @import("diagnostic.zig");
const validators = @import("validators.zig");
const Value = @import("value.zig").Value;
const result = @import("result.zig");

pub fn Profile(comptime config: anytype) type {
    const C = @TypeOf(config);
    const Custom = if (@hasField(C, "custom")) config.custom else validators.None;
    const unicode = if (@hasField(C, "unicode_case_folding")) config.unicode_case_folding else false;
    const runtime = if (@hasField(C, "runtime_policy")) config.runtime_policy else false;
    const cancellable = if (@hasField(C, "cancellation")) config.cancellation else false;
    const capabilities = support.encoding.Capabilities.from(if (@hasField(C, "source_encodings")) config.source_encodings else null);
    const Schema = policy.Schema(Custom, unicode);
    comptime {
        for (std.meta.fields(C)) |field| {
            if (!std.mem.eql(u8, field.name, "custom") and !std.mem.eql(u8, field.name, "policy") and
                !std.mem.eql(u8, field.name, "unicode_case_folding") and !std.mem.eql(u8, field.name, "runtime_policy") and
                !std.mem.eql(u8, field.name, "cancellation") and !std.mem.eql(u8, field.name, "source_encodings"))
                @compileError("unknown string profile configuration field: " ++ field.name);
        }
        if (!@hasDecl(Custom, "uses_comparison")) @compileError("validator must declare uses_comparison");
    }
    return struct {
        pub const Policy = Schema.Policy;
        pub const Policies = support.processor.PolicyBinding(Schema, .{
            .policy = if (@hasField(C, "policy")) coerce(Schema.Policy, config.policy) else .{},
            .runtime_policy = runtime,
        });
        pub const validatePolicy = Policies.validatePolicy;
        const folding_used = unicode and (runtime or
            (Policies.baseline.equals.severity != .off and (Policies.baseline.equals.comparison orelse Policies.baseline.comparison) == .case_insensitive) or
            (Policies.baseline.one_of.severity != .off and (Policies.baseline.one_of.comparison orelse Policies.baseline.comparison) == .case_insensitive) or
            (Custom.uses_comparison and Policies.baseline.custom_severity != .off and Policies.baseline.comparison == .case_insensitive));
        pub const diagnostic = diagnostics.For(Custom);
        pub const Diagnostic = diagnostic.Diagnostic;
        pub const Sink = diagnostic.Sink;
        pub const FixedDiagnosticBag = diagnostic.FixedBag;
        pub const GrowableDiagnosticBag = diagnostic.GrowableBag;
        pub const console = @import("console.zig").For(Custom);
        pub const Options = struct {
            encoding: ?support.encoding.Actual = null,
            policy: if (runtime) Policy else void = if (runtime) .{} else {},
            cancellation: if (cancellable) ?support.execution.Cancellation else void = if (cancellable) null else {},
        };
        pub const Error = Policies.Error || support.processor.Fragment.Error || error{ UnsupportedEncoding, EncodingRequired };

        pub fn parseAndValidate(input: support.processor.Fragment, sink: Sink, options: Options) Error!result.Result {
            const fragment = try support.processor.Fragment.init(input.bytes, input.origin);
            const prepared = if (runtime) try Policies.prepare(.{ .policy = options.policy }) else Policies.prepare(.{});
            // This is string CONTENT, not a file: U+FEFF is never stripped and
            // there is no BOM sniffing, escaping, quote removal or transcoding.
            const actual = options.encoding orelse (if (capabilities.utf8) support.encoding.Actual.utf8 else if (capabilities.ascii) .ascii else return error.EncodingRequired);
            switch (actual) {
                inline else => |encoding| {
                    if (comptime !capabilities.allows(encoding)) return error.UnsupportedEncoding;
                    return run(encoding, fragment, sink, options, prepared);
                },
            }
        }

        fn Engine(comptime actual: support.encoding.Actual) type {
            return struct {
                const Self = @This();
                input: support.processor.Fragment,
                sink: Sink,
                state: Policies.State,
                cancellation: if (cancellable) ?support.execution.Cancellation else void,
                result: result.Result = .{},

                inline fn effective(self: *const Self) Schema.Effective {
                    return if (runtime) self.state else Policies.baseline;
                }

                fn cancelled(self: *Self) bool {
                    if (self.result.completion != .complete) return true;
                    if (cancellable) if (self.cancellation) |token| if (token.requested()) {
                        self.result.completion = .cancelled;
                        return true;
                    };
                    return false;
                }
                fn emit(self: *Self, finding: Diagnostic) bool {
                    if (self.result.completion != .complete) return false;
                    const count = if (finding.code.severity() == .err) &self.result.errors else &self.result.warnings;
                    count.* = std.math.add(u64, count.*, 1) catch {
                        self.result.completion = .invalid_validator;
                        return false;
                    };
                    const action = self.sink.emit(finding) catch |err| {
                        self.result.delivery = .failed;
                        self.result.completion = .{ .diagnostic_stop = support.reporting.StopReason.fromError(err) };
                        return false;
                    };
                    if (action == .stop) {
                        self.result.completion = .{ .diagnostic_stop = .requested };
                        return false;
                    }
                    if (finding.code.severity() == .err and self.effective().on_error == .fail_fast) {
                        self.result.completion = .fail_fast;
                        return false;
                    }
                    return true;
                }

                fn Context(comptime Validator: type) type {
                    return struct {
                        pub const cancellation_enabled = cancellable;
                        engine: *Self,
                        code: diagnostics.Code,
                        comparison: if (Validator.uses_comparison) policy.Comparison else void,
                        findings: u64 = 0,
                        pub fn cancelled(ctx: *@This()) bool {
                            return ctx.engine.cancelled();
                        }
                        pub fn invalidValidator(ctx: *@This()) void {
                            if (ctx.engine.result.completion == .complete) ctx.engine.result.completion = .invalid_validator;
                        }
                        pub fn equals(ctx: *@This(), value: Value(actual), expected: []const u8) ?bool {
                            if (!Validator.uses_comparison) @compileError("validator must opt into uses_comparison");
                            if (ctx.cancelled()) return null;
                            if (value.bytes.ptr != ctx.engine.input.bytes.ptr or value.bytes.len != ctx.engine.input.bytes.len or value.origin != ctx.engine.input.origin) {
                                ctx.invalidValidator();
                                return null;
                            }
                            // The shared service checks its UTF-8 argument for
                            // every validator. A malformed suffix must not hide
                            // behind an early mismatch. Fixed literals may fold
                            // away; dynamic/custom patterns incur this scan.
                            if (!std.unicode.utf8ValidateSlice(expected)) {
                                ctx.invalidValidator();
                                return null;
                            }
                            return @import("compare.zig").equals(folding_used, value, expected, ctx.comparison, ctx);
                        }
                        pub fn report(ctx: *@This(), finding: diagnostic.Finding) bool {
                            if (ctx.engine.result.completion != .complete) return false;
                            const fragment = ctx.engine.input;
                            var d: Diagnostic = .{
                                .code = ctx.code,
                                .span = fragment.rebase(finding.span orelse .{ .start = 0, .len = @intCast(fragment.bytes.len) }) catch {
                                    ctx.invalidValidator();
                                    return false;
                                },
                                .detail = finding.detail,
                            };
                            if (finding.related) |span| d.related = fragment.rebase(span) catch {
                                ctx.invalidValidator();
                                return false;
                            };
                            if (finding.fix) |fix| {
                                var mapped = fix;
                                mapped.span = fragment.rebase(fix.span) catch {
                                    ctx.invalidValidator();
                                    return false;
                                };
                                if (ctx.engine.effective().fixes.allows(fix.applicability)) d.fix = mapped;
                            }
                            ctx.findings = std.math.add(u64, ctx.findings, 1) catch {
                                ctx.invalidValidator();
                                return false;
                            };
                            return ctx.engine.emit(d);
                        }
                    };
                }

                fn check(self: *Self, comptime Validator: type, settings: Validator.Settings, severity: policy.Severity, comparison: policy.Comparison, code: diagnostics.Code, state: *result.CheckState) void {
                    if (severity == .off or self.cancelled()) return;
                    state.* = .incomplete;
                    var context: Context(Validator) = .{ .engine = self, .code = code, .comparison = if (Validator.uses_comparison) comparison else {} };
                    const outcome = Validator.check(Value(actual){ .bytes = self.input.bytes, .origin = self.input.origin }, settings, &context);
                    if (self.cancelled()) return;
                    if (outcome == .stopped) {
                        // Returning stopped without signalling a cause is a
                        // validator contract failure, never a successful check.
                        self.result.completion = .invalid_validator;
                        return;
                    }
                    state.* = .complete;
                    if (outcome == .failed and context.findings == 0) _ = context.report(.{});
                    // Findings remain failures even if a validator returns passed.
                }
            };
        }

        fn run(comptime actual: support.encoding.Actual, fragment: support.processor.Fragment, sink: Sink, options: Options, prepared: Policies.State) result.Result {
            const p = if (runtime) prepared else Policies.baseline;
            var engine: Engine(actual) = .{ .input = fragment, .sink = sink, .state = prepared, .cancellation = options.cancellation };
            engine.result.checks.equals = if (p.equals.severity == .off) .disabled else .not_run;
            engine.result.checks.one_of = if (p.one_of.severity == .off) .disabled else .not_run;
            engine.result.checks.custom = if (p.custom_severity == .off) .disabled else .not_run;
            // Validate before dispatch: even a short-circuit/empty-set check
            // cannot accidentally accept malformed input. No replacement text.
            var at: u32 = 0;
            engine.result.checks.encoding = .incomplete;
            // The standard validator skips ASCII runs in SIMD-sized chunks.
            // Keep cooperative polling on the scalar path when enabled. On
            // malformed input, the ordinary walk below locates every bad run.
            if (!cancellable and actual == .utf8 and std.unicode.utf8ValidateSlice(fragment.bytes)) at = @intCast(fragment.bytes.len);
            while (at < fragment.bytes.len) {
                if (engine.cancelled()) return engine.result;
                const decoded = support.encoding.Reader(actual).decode(fragment.bytes, at) catch {
                    const start = at;
                    // One finding per adjacent malformed run, not per byte.
                    while (at < fragment.bytes.len) {
                        at += @intCast(@min(support.encoding.unitBytes(actual), fragment.bytes.len - at));
                        if (engine.cancelled()) return engine.result;
                        if (at == fragment.bytes.len) break;
                        _ = support.encoding.Reader(actual).decode(fragment.bytes, at) catch continue;
                        break;
                    }
                    if (!engine.emit(.{ .code = .invalid_encoding, .span = .{ .start = fragment.origin + start, .len = at - start } })) return engine.result;
                    continue;
                };
                at += decoded.len;
            }
            if (engine.cancelled()) return engine.result;
            engine.result.checks.encoding = .complete;
            if (engine.result.errors != 0) {
                inline for (.{ "equals", "one_of", "custom" }) |field| {
                    if (@field(engine.result.checks, field) != .disabled) @field(engine.result.checks, field) = .unavailable;
                }
                return engine.result;
            }
            if (runtime or Policies.baseline.equals.severity != .off)
                engine.check(validators.Equals, p.equals.expected, p.equals.severity, p.equals.comparison orelse p.comparison, if (p.equals.severity == .warning) .unequal_warning else .unequal, &engine.result.checks.equals);
            if (runtime or Policies.baseline.one_of.severity != .off)
                engine.check(validators.OneOf, p.one_of.values, p.one_of.severity, p.one_of.comparison orelse p.comparison, if (p.one_of.severity == .warning) .not_one_of_warning else .not_one_of, &engine.result.checks.one_of);
            if (runtime or Policies.baseline.custom_severity != .off)
                engine.check(Custom, p.custom, p.custom_severity, p.comparison, if (p.custom_severity == .warning) .custom_check_warning else .custom_check_failed, &engine.result.checks.custom);
            return engine.result;
        }
    };
}

// A profile's custom settings type depends on its compile-time validator. Give
// anonymous configuration literals the same checked coercion as typed options;
// never silently accept unknown fields. No runtime reflection/preparation here.
fn coerce(comptime T: type, comptime input: anytype) T {
    if (@TypeOf(input) == T) return input;
    return switch (@typeInfo(T)) {
        .optional => |o| if (@TypeOf(input) == @TypeOf(null)) null else coerce(o.child, input),
        .@"struct" => |s| blk: {
            var value: T = undefined;
            for (std.meta.fields(@TypeOf(input))) |field| {
                if (!@hasField(T, field.name)) @compileError("unknown string policy field: " ++ field.name);
            }
            for (s.fields) |field| {
                @field(value, field.name) = if (@hasField(@TypeOf(input), field.name))
                    coerce(field.type, @field(input, field.name))
                else
                    field.defaultValue() orelse @compileError("missing string policy field: " ++ field.name);
            }
            break :blk value;
        },
        .pointer => |p| if (p.size == .slice and p.child != u8) blk: {
            const items = inner: {
                var array: [input.len]p.child = undefined;
                for (input, 0..) |item, i| array[i] = coerce(p.child, item);
                break :inner array;
            };
            break :blk &items;
        } else input,
        else => input,
    };
}
