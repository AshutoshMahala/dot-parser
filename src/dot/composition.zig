//! Opt-in, one-shot composition. Children run on recognized raw HTML operands
//! before DOT parsing completes. No registry, retained child array or shared
//! work-budget claim. Ordinary profiles do not instantiate this module's types.
const std = @import("std");
const support = @import("parser_support");
const reporting = support.reporting;
const policy = @import("policy.zig");
const engine = @import("parse_engine.zig");
const validation = @import("validate.zig");
const lex = @import("lexer/lexer.zig");
const Parts = @import("identifier_parts.zig").Parts;

pub fn Profile(comptime api: type, comptime config: policy.Config, comptime Child: type) type {
    comptime {
        for (.{ "Policies", "Prepared", "Options", "Diagnostic", "DiagnosticSink", "Workspace", "ParseResources", "InputError", "prepare" }) |member| {
            if (!@hasDecl(Child, member)) @compileError("bound markup processor is missing " ++ member);
        }
        if (!@hasDecl(Child.Prepared, "initWorkspace")) @compileError("bound markup processor must expose Prepared.initWorkspace");
        if (!@hasDecl(Child.Workspace, "parseAndValidate") or !@hasDecl(Child.Workspace, "deinit")) @compileError("bound markup workspace must expose parseAndValidate and deinit");
    }
    const Outer = @import("profile.zig").Profile(api, .{ .policy = config.policy, .runtime_policy = config.runtime_policy });
    return struct {
        const Self = @This();
        pub const baseline = Outer.baseline;
        pub const runtime_policy = config.runtime_policy;
        pub const Policies = support.processor.PolicySet(.{ .dot = Outer, .markup = Child }).Policies;
        pub const Error = Outer.Policies.Error || Child.Policies.Error || Child.InputError;

        /// Only this compiled composition pays for the tagged union. No payload
        /// is erased or truncated; a flat bag slot fits the largest bound type.
        pub const Diagnostic = union(enum) {
            dot: api.Diagnostic,
            markup: Child.Diagnostic,

            pub fn span(self: @This()) support.location.Span {
                return switch (self) {
                    inline else => |d| d.span,
                };
            }
        };
        pub const DiagnosticSink = reporting.Sink(Diagnostic);
        pub const GrowableDiagnosticBag = reporting.GrowableBag(Diagnostic);
        pub fn FixedDiagnosticBag(comptime capacity: usize) type {
            return reporting.FixedBag(Diagnostic, capacity, .stop);
        }
        pub fn PrefixDiagnosticBag(comptime capacity: usize) type {
            return reporting.FixedBag(Diagnostic, capacity, .omit);
        }
        pub const console = support.console.ComposedRenderer(Diagnostic, .{ .dot = api.console.Adapter, .markup = Child.console.Adapter });

        pub const CheckOptions = struct {
            dot: Outer.CheckOptions = .{},
            markup: Child.Options = .{},
            markup_resources: Child.ParseResources = .{},
        };
        pub const MarkupReport = struct {
            /// Scheduling coverage, not validity or a count of all source IDs.
            complete: bool = false,
            visited: u32 = 0,
            valid: u32 = 0,
            rejected: u32 = 0,
            unprocessed: u32 = 0,
            has_errors: bool = false,
            stop: ?enum { parent_error, child_stop, diagnostic_stop, input_error } = null,

            pub fn allValid(self: @This()) bool {
                return self.complete and self.stop == null and self.valid == self.visited;
            }
        };
        pub const CheckResult = struct {
            dot: api.CheckResult,
            markup: MarkupReport,

            pub fn documentValid(self: *const @This()) bool {
                return self.dot.documentValid() and self.markup.allValid();
            }
            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.dot.deinit(allocator);
                self.* = undefined;
            }
        };

        const Stop = struct {
            delivery: reporting.Delivery,
            diagnostic_stop: ?reporting.StopReason,
        };
        const Context = struct {
            workspace: Child.Workspace,
            sink: DiagnosticSink,
            report: MarkupReport = .{},
            failure: ?Child.InputError = null,
            diagnostic_stop: ?reporting.StopReason = null,
            delivery: reporting.Delivery = .complete,

            fn emit(self: *@This(), item: Diagnostic) reporting.SinkError!reporting.Action {
                // Producers must honor the first terminal acknowledgment. This
                // guard also prevents a faulty child from calling the user twice.
                if (self.diagnostic_stop != null) return error.DiagnosticSinkFailure;
                const action = self.sink.emit(item) catch |err| {
                    self.delivery = .failed;
                    self.diagnostic_stop = .fromError(err);
                    return err;
                };
                if (action == .stop) self.diagnostic_stop = .requested;
                return action;
            }
            fn emitDot(raw: ?*anyopaque, item: api.Diagnostic) reporting.SinkError!reporting.Action {
                // Each adapter is installed with a live, correctly aligned Context.
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                return self.emit(.{ .dot = item });
            }
            fn emitMarkup(raw: ?*anyopaque, item: Child.Diagnostic) reporting.SinkError!reporting.Action {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                return self.emit(.{ .markup = item });
            }
            fn dotSink(self: *@This()) api.DiagnosticSink {
                return .{ .context = self, .emit_fn = emitDot };
            }
            fn childSink(self: *@This()) Child.DiagnosticSink {
                return .{ .context = self, .emit_fn = emitMarkup };
            }
            fn stopped(self: *const @This()) Stop {
                return .{ .delivery = self.delivery, .diagnostic_stop = self.diagnostic_stop };
            }

            /// Called exactly once per scanner-produced expression, never on a
            /// grammar replay. The DOT scanner already established all bounds.
            pub fn processIdentifier(self: *@This(), source: []const u8, token: lex.Token, on_error: api.OnError) ?Stop {
                var parts: Parts = .{
                    .input = .{ .bytes = token.span.slice(source), .origin = token.span.start },
                    .compound = token.flags.concatenated,
                };
                while (parts.next()) |part| {
                    if (part.form != .html) continue;
                    const input: support.processor.Fragment = .{ .bytes = part.inner.slice(source), .origin = part.inner.start };
                    const checked = self.workspace.parseAndValidate(input, self.childSink()) catch |err| {
                        self.failure = err;
                        self.report.stop = .input_error;
                        return self.stopped();
                    };
                    self.report.visited += 1;
                    self.report.has_errors = self.report.has_errors or checked.has_errors;
                    if (checked.documentValid()) {
                        self.report.valid += 1;
                    } else if (checked.has_errors) {
                        self.report.rejected += 1;
                    } else self.report.unprocessed += 1;
                    if (self.diagnostic_stop != null) {
                        self.report.stop = .diagnostic_stop;
                        return self.stopped();
                    }
                    if (checked.stopped()) {
                        self.report.stop = .child_stop;
                        return self.stopped();
                    }
                    if (on_error == .fail_fast and checked.has_errors) {
                        self.report.stop = .parent_error;
                        return self.stopped();
                    }
                }
                return null;
            }
        };

        fn parse(comptime backend: api.ScannerBackend, comptime cancellable: bool, allocator: std.mem.Allocator, source: []const u8, context: *Context, effective: Outer.Policies.State, options: Outer.CheckOptions) api.ParseResult {
            const Core = engine.EngineWithProcessor(api, if (runtime_policy) null else baseline.parsing, false, cancellable, backend, *Context);
            return Core.parseBorrowed(allocator, source, context.dotSink(), options.parse, .{
                .processor = context,
                .parsing = if (runtime_policy) effective.parsing else {},
                .cancellation = if (cancellable) options.cancellation else {},
            });
        }

        /// One synchronous operation; no Session/advance or combined budget is
        /// exposed. Child-owned working buffers are reused across all operands.
        /// Runtime policies are prepared before scanning, allocations or callbacks.
        pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8, diagnostics: DiagnosticSink, options: CheckOptions) Error!CheckResult {
            const effective = if (runtime_policy) try Outer.Policies.prepare(.{ .policy = options.dot.policy }) else Outer.Policies.prepare(.{});
            const preparing = Child.prepare(options.markup);
            const ready = if (@typeInfo(@TypeOf(preparing)) == .error_union) try preparing else preparing;
            var context: Context = .{ .workspace = ready.initWorkspace(allocator, options.markup_resources), .sink = diagnostics };
            defer context.workspace.deinit();
            var parsed = if (runtime_policy) blk: {
                switch (effective.scanner) {
                    inline else => |backend| break :blk if (effective.execution.cancellation)
                        parse(backend, true, allocator, source, &context, effective, options.dot)
                    else
                        parse(backend, false, allocator, source, &context, effective, options.dot),
                }
            } else parse(baseline.scanner, baseline.execution.cancellation, allocator, source, &context, effective, options.dot);
            errdefer parsed.deinit(allocator);
            if (context.failure) |err| return err;
            context.report.complete = parsed.completion == .complete and context.report.stop == null;
            const checked: ?api.ValidationResult = if (parsed.document != null and parsed.diagnostic_stop == null and parsed.diagnostic_delivery == .complete)
                validation.validate(if (runtime_policy) null else baseline.validation, &parsed.document.?, context.dotSink(), if (runtime_policy) effective.validation else {}, options.dot.validation)
            else
                null;
            return .{
                .dot = .{
                    .document = parsed.document,
                    .outcome = parsed.outcome,
                    .completion = parsed.completion,
                    .syntax_errors = parsed.syntax_errors,
                    .validation = checked,
                    .diagnostic_delivery = context.delivery,
                    .diagnostic_stop = context.diagnostic_stop orelse parsed.diagnostic_stop,
                    .accepted_deviations = parsed.accepted_deviations,
                    .warnings = @as(u64, parsed.warnings) + if (checked) |v| v.warningCount() else 0,
                },
                .markup = context.report,
            };
        }
    };
}
