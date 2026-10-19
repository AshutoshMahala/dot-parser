const std = @import("std");
const support = @import("parser_support");
const policy = @import("policy.zig");
const diagnostics = @import("diagnostic.zig");
const validators = @import("validators.zig");
const Value = @import("value.zig").Value;
const results = @import("result.zig");
const batches = @import("batch.zig");

pub fn Profile(comptime config: anytype) type {
    const C = @TypeOf(config);
    const Custom = if (@hasField(C, "custom")) config.custom else validators.None;
    const unicode = if (@hasField(C, "unicode_case_folding")) config.unicode_case_folding else false;
    const runtime = if (@hasField(C, "runtime_policy")) config.runtime_policy else false;
    const capabilities = support.encoding.Capabilities.from(if (@hasField(C, "source_encodings")) config.source_encodings else null);
    const Schema = policy.Schema(Custom, unicode);
    comptime {
        for (std.meta.fields(C)) |field| {
            if (!std.mem.eql(u8, field.name, "custom") and !std.mem.eql(u8, field.name, "policy") and
                !std.mem.eql(u8, field.name, "unicode_case_folding") and !std.mem.eql(u8, field.name, "runtime_policy") and
                !std.mem.eql(u8, field.name, "source_encodings"))
                @compileError("unknown string profile configuration field: " ++ field.name);
        }
        if (!@hasDecl(Custom, "uses_comparison")) @compileError("validator must declare uses_comparison");
        if (@hasDecl(Custom, "State") != @hasDecl(Custom, "step")) @compileError("resumable validator must declare both State and step");
        if (@hasDecl(Custom, "batch") and !validators.resumable(Custom)) @compileError("batch requires a resumable validator");
    }
    return struct {
        pub const Policy = Schema.Policy;
        pub const Policies = support.processor.PolicyBinding(Schema, .{
            .policy = if (@hasField(C, "policy")) coerce(Schema.Policy, config.policy) else .{},
            .runtime_policy = runtime,
        });
        pub const validatePolicy = Policies.validatePolicy;
        const cancellable = runtime or Policies.baseline.execution.cancellation;
        const folding_used = unicode and (runtime or
            (Policies.baseline.equals.severity != .off and (Policies.baseline.equals.comparison orelse Policies.baseline.comparison) == .case_insensitive) or
            (Policies.baseline.one_of.severity != .off and (Policies.baseline.one_of.comparison orelse Policies.baseline.comparison) == .case_insensitive) or
            (Custom.uses_comparison and Policies.baseline.custom_severity != .off and Policies.baseline.comparison == .case_insensitive));
        const ascii_folding_used = runtime or
            (Policies.baseline.equals.severity != .off and (Policies.baseline.equals.comparison orelse Policies.baseline.comparison) == .ascii_case_insensitive) or
            (Policies.baseline.one_of.severity != .off and (Policies.baseline.one_of.comparison orelse Policies.baseline.comparison) == .ascii_case_insensitive) or
            (Custom.uses_comparison and Policies.baseline.custom_severity != .off and Policies.baseline.comparison == .ascii_case_insensitive);
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

        pub fn parseAndValidate(input: support.processor.Fragment, sink: Sink, options: Options) Error!results.Result {
            const fragment = try support.processor.Fragment.init(input.bytes, input.origin);
            const prepared = if (runtime) try Policies.prepare(.{ .policy = options.policy }) else Policies.prepare(.{});
            // This is string CONTENT, not a file: U+FEFF is never stripped and
            // there is no BOM sniffing, escaping, quote removal or transcoding.
            const actual = options.encoding orelse (if (capabilities.utf8) support.encoding.Actual.utf8 else if (capabilities.ascii) .ascii else return error.EncodingRequired);
            switch (actual) {
                inline else => |encoding| {
                    if (comptime !capabilities.allows(encoding)) return error.UnsupportedEncoding;
                    const p = if (runtime) prepared else Policies.baseline;
                    if (p.execution.metering or p.execution.cancellation) {
                        var session = Core(encoding).init(fragment, sink, options, prepared);
                        return session.run();
                    }
                    return run(encoding, fragment, sink, options, prepared);
                },
            }
        }

        fn Engine(comptime actual: support.encoding.Actual, comptime can_cancel: bool) type {
            return struct {
                const Self = @This();
                input: support.processor.Fragment,
                sink: Sink,
                state: Policies.State,
                cancellation: if (can_cancel) ?support.execution.Cancellation else void,
                result: results.Result = .{},

                inline fn effective(self: *const Self) Schema.Effective {
                    return if (runtime) self.state else Policies.baseline;
                }

                fn cancelled(self: *Self) bool {
                    if (self.result.completion != .complete) return true;
                    if (can_cancel) if (self.effective().execution.cancellation) if (self.cancellation) |token| if (token.requested()) {
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

                fn Context(comptime Validator: type, comptime stepped: bool) type {
                    return struct {
                        pub const cancellation_enabled = can_cancel;
                        pub const ComparisonState = @import("compare.zig").State(folding_used, ascii_folding_used);
                        engine: *Self,
                        code: diagnostics.Code,
                        comparison: if (Validator.uses_comparison) policy.Comparison else void,
                        findings: u64 = 0,
                        pub fn equalsStep(ctx: *@This(), comparison_state: *ComparisonState, value: Value(actual), expected: []const u8) validators.Step {
                            if (!Validator.uses_comparison) @compileError("validator must opt into uses_comparison");
                            if (ctx.engine.result.completion != .complete) return .stopped;
                            if (value.bytes.ptr != ctx.engine.input.bytes.ptr or value.bytes.len != ctx.engine.input.bytes.len or value.origin != ctx.engine.input.origin) {
                                ctx.invalidValidator();
                                return .stopped;
                            }
                            return comparison_state.step(value, expected, ctx.comparison, ctx);
                        }
                        pub fn cancelled(ctx: *@This()) bool {
                            return ctx.engine.cancelled();
                        }
                        pub fn invalidValidator(ctx: *@This()) void {
                            if (ctx.engine.result.completion == .complete) ctx.engine.result.completion = .invalid_validator;
                        }
                        pub fn equals(ctx: *@This(), value: Value(actual), expected: []const u8) ?bool {
                            if (stepped) @compileError("resumable validators must use equalsStep");
                            if (!Validator.uses_comparison) @compileError("validator must opt into uses_comparison");
                            if (ctx.cancelled()) return null;
                            if (value.bytes.ptr != ctx.engine.input.bytes.ptr or value.bytes.len != ctx.engine.input.bytes.len or value.origin != ctx.engine.input.origin) {
                                ctx.invalidValidator();
                                return null;
                            }
                            // The input has already passed encoding validation.
                            // Exact byte equality therefore proves the UTF-8
                            // pattern valid too. On a mismatch still validate
                            // the WHOLE pattern before returning false: a bad
                            // suffix must not hide behind an early mismatch.
                            // Cooperative paths retain their original steps
                            // and polls, including expected-pattern validation.
                            // Keep Unicode-capable plans on their existing
                            // comparison path; this shortcut is for exact/ASCII
                            // plans and does not add a branch to folding loops.
                            if (!folding_used and !can_cancel and (actual == .utf8 or actual == .ascii) and ctx.comparison == .case_sensitive) {
                                const same = std.mem.eql(u8, value.bytes, expected);
                                if (!same and !std.unicode.utf8ValidateSlice(expected)) {
                                    ctx.invalidValidator();
                                    return null;
                                }
                                return same;
                            }
                            // The shared service checks its UTF-8 argument for
                            // every validator. A malformed suffix must not hide
                            // behind an early mismatch. Fixed literals may fold
                            // away; other dynamic/custom patterns incur this scan.
                            if (!std.unicode.utf8ValidateSlice(expected)) {
                                ctx.invalidValidator();
                                return null;
                            }
                            return @import("compare.zig").equals(folding_used, ascii_folding_used, value, expected, ctx.comparison, ctx);
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

                /// Batches cannot report, poll or terminate a check. Keep this
                /// service out of step's context: one step still costs one credit.
                fn BatchContext(comptime Validator: type) type {
                    return struct {
                        pub const ComparisonState = @import("compare.zig").State(folding_used, ascii_folding_used);
                        input: support.processor.Fragment,
                        comparison: if (Validator.uses_comparison) policy.Comparison else void,

                        pub fn equalsBatch(ctx: *@This(), state: *ComparisonState, value: Value(actual), expected: []const u8, allowance: u32) u32 {
                            if (!Validator.uses_comparison) @compileError("validator must opt into uses_comparison");
                            if (value.bytes.ptr != ctx.input.bytes.ptr or value.bytes.len != ctx.input.bytes.len or value.origin != ctx.input.origin) return 0;
                            // Keep fixed operands visible through the Small
                            // batch boundary; folding itself stays shared.
                            return @call(if (@import("builtin").mode == .ReleaseSmall) .always_inline else .auto, @TypeOf(state.*).batch, .{ state, value, expected, ctx.comparison, allowance });
                        }
                    };
                }

                fn check(self: *Self, comptime Validator: type, settings: Validator.Settings, severity: policy.Severity, comparison: policy.Comparison, code: diagnostics.Code, state: *results.CheckState) void {
                    if (severity == .off or self.cancelled()) return;
                    state.* = .incomplete;
                    var context: Context(Validator, false) = .{ .engine = self, .code = code, .comparison = if (Validator.uses_comparison) comparison else {} };
                    const value = Value(actual){ .bytes = self.input.bytes, .origin = self.input.origin };
                    const outcome: validators.Outcome = if (@hasDecl(Validator, "check")) Validator.check(value, settings, &context) else blk: {
                        var state_value: Validator.State(Context(Validator, false)) = .{};
                        while (true) switch (Validator.step(&state_value, value, settings, &context)) {
                            .pending => if (context.cancelled()) break :blk .stopped,
                            .passed => break :blk .passed,
                            .failed => break :blk .failed,
                            .stopped => break :blk .stopped,
                        };
                    };
                    // Preserve a concrete callback outcome before polling for
                    // another work step; an error is not erased by a late stop.
                    if (self.result.completion != .complete) return;
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

        fn Core(comptime actual: support.encoding.Actual) type {
            const E = Engine(actual, cancellable);
            const equals_active = runtime or Policies.baseline.equals.severity != .off;
            const one_of_active = runtime or Policies.baseline.one_of.severity != .off;
            const custom_active = runtime or Policies.baseline.custom_severity != .off;
            return struct {
                const Self = @This();
                engine: E,
                stage: results.Stage = .encoding,
                finished: bool = false,
                at: u32 = 0,
                bad_start: ?u32 = null,
                findings: u64 = 0,
                equals_state: if (equals_active) validators.Equals.State(E.Context(validators.Equals, true)) else void = if (equals_active) .{} else {},
                one_of_state: if (one_of_active) validators.OneOf.State(E.Context(validators.OneOf, true)) else void = if (one_of_active) .{} else {},
                custom_state: if (custom_active and validators.resumable(Custom)) Custom.State(E.Context(Custom, true)) else void = if (custom_active and validators.resumable(Custom)) .{} else {},

                fn init(fragment: support.processor.Fragment, sink: Sink, options: Options, prepared: Policies.State) Self {
                    var self: Self = .{ .engine = .{ .input = fragment, .sink = sink, .state = prepared, .cancellation = options.cancellation } };
                    const p = self.engine.effective();
                    self.engine.result.checks.equals = if (p.equals.severity == .off) .disabled else .not_run;
                    self.engine.result.checks.one_of = if (p.one_of.severity == .off) .disabled else .not_run;
                    self.engine.result.checks.custom = if (p.custom_severity == .off) .disabled else .not_run;
                    return self;
                }

                fn progress(self: *const Self, used: u32) results.Progress {
                    return .{ .outcome = if (self.finished) self.engine.result.completion else null, .work_used = used, .source_frontier = self.at, .stage = self.stage };
                }

                inline fn drive(self: *Self, comptime bounded: bool, budget: u32) results.Progress {
                    if (bounded and budget == 1) return self.driveOne();
                    if (bounded and budget < batches.width) return self.driveScalar(bounded, budget);
                    const p = self.engine.effective();
                    // Choose once, not once per scalar. In particular budget 1
                    // and interval 1 never enter the batching machinery.
                    if (cancellable and p.execution.cancellation and p.execution.cancellation_interval < batches.width)
                        return self.driveScalar(bounded, budget);
                    return self.driveBatched(bounded, budget);
                }

                inline fn driveOne(self: *Self) results.Progress {
                    if (self.finished) return self.progress(0);
                    if (cancellable and self.engine.effective().execution.cancellation and self.engine.cancelled()) {
                        self.finished = true;
                        return self.progress(0);
                    }
                    // Exactly one original step, without a loop, countdown or
                    // batch probe. Keep tiny resumes independent of the larger
                    // batching driver and its inlining cost.
                    self.step();
                    if (self.engine.result.completion != .complete) self.finished = true;
                    return self.progress(1);
                }

                fn driveScalar(self: *Self, comptime bounded: bool, budget: u32) results.Progress {
                    if (self.finished) return self.progress(0);
                    const p = self.engine.effective();
                    var polling: support.execution.CancellationPolling(cancellable, if (runtime) null else Policies.baseline.execution.cancellation_interval) = .{};
                    var used: u32 = 0;
                    while (true) {
                        // Entry polls even with a zero budget; completion wins
                        // over later cancellation and never polls again.
                        if (cancellable and p.execution.cancellation and polling.due(p.execution.cancellation_interval)) {
                            if (self.engine.cancelled()) {
                                self.finished = true;
                                return self.progress(used);
                            }
                        }
                        if (bounded and used == budget) return self.progress(used);
                        self.step();
                        if (bounded) used += 1;
                        if (cancellable and p.execution.cancellation) polling.spend(1);
                        if (self.engine.result.completion != .complete) self.finished = true;
                        if (self.finished) return self.progress(used);
                        // Do not poll again solely to discover an exhausted
                        // budget; the next live entry will poll before work.
                        if (bounded and used == budget) return self.progress(used);
                    }
                }

                fn driveBatched(self: *Self, comptime bounded: bool, budget: u32) results.Progress {
                    if (self.finished) return self.progress(0);
                    const p = self.engine.effective();
                    var polling: support.execution.CancellationPolling(cancellable, if (runtime) null else Policies.baseline.execution.cancellation_interval) = .{};
                    var used: u32 = 0;
                    while (true) {
                        if (cancellable and p.execution.cancellation and polling.due(p.execution.cancellation_interval)) {
                            if (self.engine.cancelled()) {
                                self.finished = true;
                                return self.progress(used);
                            }
                        }
                        if (bounded and used == budget) return self.progress(used);
                        var allowance: u32 = if (bounded) budget - used else std.math.maxInt(u32);
                        if (cancellable and p.execution.cancellation) allowance = @min(allowance, polling.allowance());
                        var work = self.batch(allowance);
                        if (self.engine.result.completion != .complete) {
                            self.finished = true;
                            return self.progress(used);
                        }
                        // A failed probe falls back for an entire bounded run,
                        // not another overlapping ASCII probe at every scalar.
                        // Amortize a failed probe over up to 64 scalar steps.
                        // The caller's remaining budget and next poll still
                        // bound this run, including budgets/intervals of one.
                        if (work == 0) work = self.scalarRun(@min(allowance, 64));
                        if (bounded) used += work;
                        if (cancellable and p.execution.cancellation) polling.spend(work);
                        if (self.finished) return self.progress(used);
                        if (bounded and used == budget) return self.progress(used);
                    }
                }

                fn scalarRun(self: *Self, allowance: u32) u32 {
                    var work: u32 = 0;
                    while (work < allowance) {
                        self.step();
                        work += 1;
                        if (self.engine.result.completion != .complete) self.finished = true;
                        if (self.finished) break;
                    }
                    return work;
                }

                fn batch(self: *Self, allowance: u32) u32 {
                    if (allowance < batches.width) return 0;
                    const p = self.engine.effective();
                    switch (self.stage) {
                        .encoding => {
                            if (comptime actual != .utf8 and actual != .ascii) return 0;
                            if (self.bad_start != null or !batches.ascii(self.engine.input.bytes, self.at)) return 0;
                            self.at += batches.width;
                            self.engine.result.checks.encoding = .incomplete;
                            return batches.width;
                        },
                        .equals => if (equals_active) return self.ruleBatch(validators.Equals, &self.equals_state, p.equals.expected, p.equals.severity, p.equals.comparison orelse p.comparison, &self.engine.result.checks.equals, allowance),
                        .one_of => if (one_of_active) return self.ruleBatch(validators.OneOf, &self.one_of_state, p.one_of.values, p.one_of.severity, p.one_of.comparison orelse p.comparison, &self.engine.result.checks.one_of, allowance),
                        .custom => if (custom_active) return self.ruleBatch(Custom, &self.custom_state, p.custom, p.custom_severity, p.comparison, &self.engine.result.checks.custom, allowance),
                        .done => unreachable,
                    }
                    return 0;
                }

                fn ruleBatch(self: *Self, comptime Validator: type, state: anytype, settings: Validator.Settings, severity: policy.Severity, comparison: policy.Comparison, coverage: *results.CheckState, allowance: u32) u32 {
                    if (comptime !@hasDecl(Validator, "batch")) return 0;
                    if (severity == .off) return 0;
                    // Batch only pending steps. No reports, polls or terminal
                    // outcomes may be skipped; step remains the source of truth.
                    var context: E.BatchContext(Validator) = .{ .input = self.engine.input, .comparison = if (Validator.uses_comparison) comparison else {} };
                    const work = Validator.batch(state, Value(actual){ .bytes = self.engine.input.bytes, .origin = self.engine.input.origin }, settings, &context, allowance);
                    if (work > allowance) {
                        self.engine.result.completion = .invalid_validator;
                        return 0;
                    }
                    if (work != 0) coverage.* = .incomplete;
                    return work;
                }

                fn run(self: *Self) results.Result {
                    _ = self.drive(false, 0);
                    return self.engine.result;
                }

                fn cancel(self: *Self) results.Result {
                    if (!self.finished) {
                        self.engine.result.completion = .cancelled;
                        self.finished = true;
                    }
                    return self.engine.result;
                }

                fn next(self: *Self, stage: results.Stage) void {
                    self.findings = 0;
                    self.stage = stage;
                    if (stage == .done) self.finished = true;
                }

                fn step(self: *Self) void {
                    const p = self.engine.effective();
                    switch (self.stage) {
                        .encoding => {
                            self.engine.result.checks.encoding = .incomplete;
                            const bytes = self.engine.input.bytes;
                            if (self.at < bytes.len) {
                                const decoded = support.encoding.Reader(actual).decode(bytes, self.at) catch {
                                    if (self.bad_start == null) self.bad_start = self.at;
                                    self.at += @intCast(@min(support.encoding.unitBytes(actual), bytes.len - self.at));
                                    return;
                                };
                                if (self.bad_start == null) {
                                    self.at += decoded.len;
                                    return;
                                }
                            }
                            if (self.bad_start) |start| {
                                self.bad_start = null;
                                _ = self.engine.emit(.{ .code = .invalid_encoding, .span = .{ .start = self.engine.input.origin + start, .len = self.at - start } });
                                return;
                            }
                            self.engine.result.checks.encoding = .complete;
                            if (self.engine.result.errors != 0) {
                                inline for (.{ "equals", "one_of", "custom" }) |field| {
                                    if (@field(self.engine.result.checks, field) != .disabled) @field(self.engine.result.checks, field) = .unavailable;
                                }
                                self.next(.done);
                            } else self.next(.equals);
                        },
                        .equals => if (equals_active) self.rule(validators.Equals, &self.equals_state, p.equals.expected, p.equals.severity, p.equals.comparison orelse p.comparison, if (p.equals.severity == .warning) .unequal_warning else .unequal, &self.engine.result.checks.equals, .one_of) else self.next(.one_of),
                        .one_of => if (one_of_active) self.rule(validators.OneOf, &self.one_of_state, p.one_of.values, p.one_of.severity, p.one_of.comparison orelse p.comparison, if (p.one_of.severity == .warning) .not_one_of_warning else .not_one_of, &self.engine.result.checks.one_of, .custom) else self.next(.custom),
                        .custom => if (custom_active) self.rule(Custom, &self.custom_state, p.custom, p.custom_severity, p.comparison, if (p.custom_severity == .warning) .custom_check_warning else .custom_check_failed, &self.engine.result.checks.custom, .done) else self.next(.done),
                        .done => unreachable,
                    }
                }

                fn rule(self: *Self, comptime Validator: type, state: anytype, settings: Validator.Settings, severity: policy.Severity, comparison: policy.Comparison, code: diagnostics.Code, coverage: *results.CheckState, next_stage: results.Stage) void {
                    if (severity == .off) return self.next(next_stage);
                    coverage.* = .incomplete;
                    if (comptime !validators.resumable(Validator)) {
                        // Policy preparation rejects this case under metering.
                        // Synchronous custom code remains usable without budgets.
                        self.engine.check(Validator, settings, severity, comparison, code, coverage);
                        self.next(next_stage);
                        return;
                    }
                    var context: E.Context(Validator, true) = .{ .engine = &self.engine, .code = code, .comparison = if (Validator.uses_comparison) comparison else {}, .findings = self.findings };
                    const outcome = Validator.step(state, Value(actual){ .bytes = self.engine.input.bytes, .origin = self.engine.input.origin }, settings, &context);
                    self.findings = context.findings;
                    if (self.engine.result.completion != .complete) return;
                    switch (outcome) {
                        .pending => {},
                        .stopped => context.invalidValidator(),
                        .passed, .failed => {
                            coverage.* = .complete;
                            if (outcome == .failed and self.findings == 0) _ = context.report(.{});
                            self.next(next_stage);
                        },
                    }
                }
            };
        }

        const Inner = union(support.encoding.Actual) {
            ascii: if (capabilities.ascii) Core(.ascii) else void,
            utf8: if (capabilities.utf8) Core(.utf8) else void,
            utf16le: if (capabilities.utf16) Core(.utf16le) else void,
            utf16be: if (capabilities.utf16) Core(.utf16be) else void,
            utf32le: if (capabilities.utf32) Core(.utf32le) else void,
            utf32be: if (capabilities.utf32) Core(.utf32be) else void,
        };
        pub const Session = struct {
            inner: Inner,
            pub fn init(input: support.processor.Fragment, sink: Sink, options: Options) Error!@This() {
                const fragment = try support.processor.Fragment.init(input.bytes, input.origin);
                const prepared = if (runtime) try Policies.prepare(.{ .policy = options.policy }) else Policies.prepare(.{});
                const actual = options.encoding orelse (if (capabilities.utf8) support.encoding.Actual.utf8 else if (capabilities.ascii) .ascii else return error.EncodingRequired);
                switch (actual) {
                    inline else => |encoding| {
                        if (comptime !capabilities.allows(encoding)) return error.UnsupportedEncoding;
                        return .{ .inner = @unionInit(Inner, @tagName(encoding), Core(encoding).init(fragment, sink, options, prepared)) };
                    },
                }
            }
            // Keep constant budgets visible at the call site: the batch driver
            // must not change inlining of the budget-one resume path.
            pub inline fn advance(self: *@This(), budget: u32) (if (runtime) error{MeteringDisabled}!results.Progress else results.Progress) {
                if (!runtime and !Policies.baseline.execution.metering) @compileError("advance requires execution.metering");
                switch (self.inner) {
                    inline else => |*session, encoding| {
                        if (comptime !capabilities.allows(encoding)) unreachable;
                        if (runtime and !session.engine.effective().execution.metering) return error.MeteringDisabled;
                        return session.drive(true, budget);
                    },
                }
            }
            pub fn run(self: *@This()) results.Result {
                return switch (self.inner) {
                    inline else => |*session, encoding| if (comptime capabilities.allows(encoding)) session.run() else unreachable,
                };
            }
            pub fn result(self: *const @This()) ?@import("result.zig").Result {
                return switch (self.inner) {
                    inline else => |*session, encoding| if (comptime capabilities.allows(encoding)) (if (session.finished) session.engine.result else null) else unreachable,
                };
            }
            pub fn cancel(self: *@This()) @import("result.zig").Result {
                return switch (self.inner) {
                    inline else => |*session, encoding| if (comptime capabilities.allows(encoding)) session.cancel() else unreachable,
                };
            }
            pub fn deinit(self: *@This()) void {
                _ = self.cancel();
            }
            pub fn reset(self: *@This(), input: support.processor.Fragment, sink: Sink, options: Options) Error!void {
                const replacement = try init(input, sink, options);
                self.deinit();
                self.* = replacement;
            }
        };

        fn run(comptime actual: support.encoding.Actual, fragment: support.processor.Fragment, sink: Sink, options: Options, prepared: Policies.State) results.Result {
            const p = if (runtime) prepared else Policies.baseline;
            _ = options;
            var engine: Engine(actual, false) = .{ .input = fragment, .sink = sink, .state = prepared, .cancellation = {} };
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
            if (actual == .utf8 and std.unicode.utf8ValidateSlice(fragment.bytes)) at = @intCast(fragment.bytes.len);
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
