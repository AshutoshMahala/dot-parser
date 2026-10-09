//! Opt-in, one-shot composition. With markup = process, children run on recognized
//! raw HTML operands before DOT parsing completes. No registry or shared
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
    const child_owns = @hasDecl(Child, "CheckResult") and @hasDecl(Child.Prepared, "parseAndValidate");
    const Binding = support.processor.PolicyBinding(policy.Schema(true, child_owns), .{ .policy = config.policy, .runtime_policy = config.runtime_policy });
    const Outer = struct {
        pub const Policies = Binding;
    };
    const DotOptions = @import("profile.zig").CheckOptionsFor(api, Binding);
    const can_process = config.runtime_policy or Binding.baseline.parsing.markup == .process;
    const can_retain = child_owns and (config.runtime_policy or Binding.baseline.parsing.retention.markup);
    const can_delay = can_retain and (config.runtime_policy or Binding.baseline.parsing.markup == .passthrough);
    return struct {
        const Self = @This();
        pub const baseline = Binding.baseline;
        pub const runtime_policy = config.runtime_policy;
        pub const Policies = support.processor.PolicySet(.{ .dot = Outer, .markup = Child }).Policies;
        pub const Error = Binding.Error || Child.Policies.Error || Child.InputError;

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
            dot: DotOptions = .{},
            markup: Child.Options = .{},
            markup_resources: Child.ParseResources = .{},
        };
        pub const MarkupOptions = struct {
            markup: Child.Options = .{},
            markup_resources: Child.ParseResources = .{},
        };
        pub const SelectionError = error{
            MarkupRetentionDisabled,
            MarkupNotPassthrough,
            DocumentUnavailable,
            CompositionStopped,
            SelectionClosed,
            SelectionOutOfOrder,
            InvalidSpan,
            InvalidIdentifier,
            OutOfMemory,
        };
        pub const MarkupReport = struct {
            /// False until proactive processing or explicit delayed selection.
            /// No child checking was requested;
            /// zero findings must not be mistaken for validated markup.
            requested: bool = false,
            /// Explicit selections do not certify unselected HTML operands.
            selection: enum { all_operands, selected_operands } = .all_operands,
            /// Scheduling coverage, not validity or a count of all source IDs.
            complete: bool = false,
            visited: u32 = 0,
            valid: u32 = 0,
            rejected: u32 = 0,
            unprocessed: u32 = 0,
            has_errors: bool = false,
            /// Child-stage delivery, including child-retention storage findings.
            /// Delayed work never rewrites the finished DOT stage's delivery.
            diagnostic_delivery: reporting.Delivery = .complete,
            diagnostic_stop: ?reporting.StopReason = null,
            /// Local child representation, independent of validation findings.
            /// Consult requested first: not requested is not missing work.
            representation: support.Completeness = .not_processed,
            stop: ?enum { parent_error, child_stop, diagnostic_stop, input_error, retention_storage } = null,

            pub fn allValid(self: @This()) bool {
                return self.requested and self.complete and self.stop == null and self.valid == self.visited;
            }
        };
        pub const MarkupResult = if (can_retain) struct {
            /// Whole raw DOT operand (including its outer angle brackets).
            envelope: support.location.Span,
            /// Original-source origin; child records index input.bytes locally.
            input: support.processor.Fragment,
            result: Child.CheckResult,
        } else void;
        const Delayed = struct {
            mode: policy.MarkupMode,
            enabled: bool,
            on_error: api.OnError,
            pending: std.ArrayList(support.location.Span) = .empty,
            next: u32 = 0,
            selection_end: u32 = 0,
            closed: bool = false,
        };
        pub const CheckResult = struct {
            dot: api.CheckResult,
            markup: MarkupReport,
            _markup_results: if (can_retain) std.ArrayList(MarkupResult) else void = if (can_retain) .empty else {},
            _markup_retained: bool = false,
            _delayed: if (can_delay) Delayed else void,

            /// Null when retention was not requested. A present empty slice means
            /// it was requested, but no child was processed. Borrowed from self.
            pub fn markupResults(self: *const @This()) ?[]const MarkupResult {
                if (!can_retain) return null;
                return if (self._markup_retained) self._markup_results.items else null;
            }
            /// Register HTML operands from one raw identifier expression. Calls
            /// must be non-overlapping and in source order; quoted operands are
            /// ignored. Admission is checked and failure-atomic. No child runs.
            /// Selection does not prove that a caller-built span is a DOT ID.
            pub fn requestMarkup(self: *@This(), allocator: std.mem.Allocator, range: support.location.Span) SelectionError!void {
                if (!can_retain) return error.MarkupRetentionDisabled;
                if (!can_delay) return error.MarkupNotPassthrough;
                try self.checkDelayed();
                const document = self.dot.document orelse return error.DocumentUnavailable;
                const limit = if (document.scopeComplete()) document.source.len else document.retained_end;
                if (range.start > limit or range.len > limit - range.start) return error.InvalidSpan;
                var parts = try @import("identifier.zig").parts(document.source, range);
                if (range.start < self._delayed.selection_end) return error.SelectionOutOfOrder;
                const first = parts;
                var count: u32 = 0;
                while (parts.next()) |part| if (part.form == .html) {
                    count += 1;
                };
                if (count == 0) return;
                try self._delayed.pending.ensureUnusedCapacity(allocator, count);
                parts = first;
                while (parts.next()) |part| if (part.form == .html) {
                    self._delayed.pending.appendAssumeCapacity(part.raw);
                };
                self._delayed.selection_end = range.start + range.len;
                self._markup_retained = true;
                self.markup.requested = true;
                self.markup.selection = .selected_operands;
                self.markup.representation = .not_processed;
            }
            /// Source-ordered envelopes still awaiting an attempt. Borrowed;
            /// invalidated by selection, processing or deinit. No hidden traversal.
            pub fn pendingMarkup(self: *const @This()) []const support.location.Span {
                if (!can_delay) return &.{};
                return self._delayed.pending.items[self._delayed.next..];
            }
            fn checkDelayed(self: *const @This()) SelectionError!void {
                if (!can_retain) return error.MarkupRetentionDisabled;
                if (!can_delay) return error.MarkupNotPassthrough;
                if (!self._delayed.enabled) return error.MarkupRetentionDisabled;
                if (self._delayed.mode != .passthrough) return error.MarkupNotPassthrough;
                if (self._delayed.closed) return error.SelectionClosed;
                // A later stage is not a way to bypass an earlier terminal
                // stop. Independent standalone checking remains available.
                if (self.dot.diagnostic_stop != null or self.dot.diagnostic_delivery != .complete) return error.CompositionStopped;
                switch (self.dot.outcome) {
                    .success => {},
                    .invalid_syntax => if (self._delayed.on_error == .fail_fast) return error.CompositionStopped,
                    else => return error.CompositionStopped,
                }
                if (self.dot.validation) |v| switch (v.outcome) {
                    .completed => {},
                    else => return error.CompositionStopped,
                };
            }
            pub fn scopeComplete(self: *const @This()) bool {
                return if (self.dot.document) |doc| doc.scopeComplete() else false;
            }
            pub fn subtreeComplete(self: *const @This()) bool {
                return self.scopeComplete() and (!self.markup.requested or self.markup.representation == .complete);
            }
            pub fn state(self: *const @This()) support.Completeness {
                if (!self.scopeComplete()) return .partial;
                return if (self.markup.requested) self.markup.representation else .complete;
            }

            /// Valid under the selected policy; passthrough does not certify
            /// inner contents. Inspect markup.requested/allValid for that fact.
            pub fn documentValid(self: *const @This()) bool {
                return self.dot.documentValid() and (!self.markup.requested or self.markup.allValid());
            }
            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                if (can_retain) {
                    for (self._markup_results.items) |*child| child.result.deinit();
                    self._markup_results.deinit(allocator);
                }
                if (can_delay) self._delayed.pending.deinit(allocator);
                self.dot.deinit(allocator);
                self.* = undefined;
            }
        };

        const Stop = struct {
            delivery: reporting.Delivery,
            diagnostic_stop: ?reporting.StopReason,
        };
        const Context = struct {
            workspace: if (can_process) Child.Workspace else void = if (can_process) undefined else {},
            sink: DiagnosticSink,
            report: MarkupReport = .{},
            failure: ?Child.InputError = null,
            diagnostic_stop: ?reporting.StopReason = null,
            delivery: reporting.Delivery = .complete,
            retaining: bool = false,
            children: if (can_retain) std.ArrayList(MarkupResult) else void = if (can_retain) .empty else {},
            ready: if (can_retain) Child.Prepared else void = if (can_retain) undefined else {},
            allocator: if (can_retain) std.mem.Allocator else void = if (can_retain) undefined else {},
            resources: if (can_retain) Child.ParseResources else void = if (can_retain) undefined else {},

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
                const action = self.emit(.{ .markup = item }) catch |err| {
                    self.report.diagnostic_delivery = self.delivery;
                    self.report.diagnostic_stop = self.diagnostic_stop;
                    return err;
                };
                if (action == .stop) self.report.diagnostic_stop = .requested;
                return action;
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
                if (!can_process) return null;
                var parts: Parts = .{
                    .input = .{ .bytes = token.span.slice(source), .origin = token.span.start },
                    .compound = token.flags.concatenated,
                };
                while (parts.next()) |part| {
                    if (part.form != .html) continue;
                    const input: support.processor.Fragment = .{ .bytes = part.inner.slice(source), .origin = part.inner.start };
                    if (can_retain and self.retaining) {
                        if (self.processRetained(part.raw, input, on_error)) |stop| return stop;
                    } else {
                        const checked = self.workspace.parseAndValidate(input, self.childSink()) catch |err| {
                            self.failure = err;
                            self.report.stop = .input_error;
                            return self.stopped();
                        };
                        if (self.record(checked, on_error)) |stop| return stop;
                    }
                }
                return null;
            }
            fn processRetained(self: *@This(), envelope: support.location.Span, input: support.processor.Fragment, on_error: api.OnError) ?Stop {
                // Reserve before starting a child. Ownership transfer at its
                // terminal failure then cannot need an allocation.
                self.children.ensureUnusedCapacity(self.allocator, 1) catch {
                    _ = self.emit(.{ .dot = .{ .code = .resource_memory_exhausted, .span = .{ .start = input.origin, .len = @intCast(input.bytes.len) } } }) catch {};
                    self.report.has_errors = true;
                    self.report.diagnostic_delivery = self.delivery;
                    self.report.diagnostic_stop = self.diagnostic_stop;
                    self.report.stop = .retention_storage;
                    return self.stopped();
                };
                const checked = self.ready.parseAndValidate(self.allocator, input, self.childSink(), self.resources) catch |err| {
                    self.failure = err;
                    self.report.stop = .input_error;
                    return self.stopped();
                };
                self.children.appendAssumeCapacity(.{ .envelope = envelope, .input = input, .result = checked });
                return self.record(checked, on_error);
            }
            fn record(self: *@This(), checked: anytype, on_error: api.OnError) ?Stop {
                self.report.visited += 1;
                const complete = if (@hasDecl(@TypeOf(checked), "subtreeComplete"))
                    checked.subtreeComplete()
                else
                    checked.documentValid();
                if (!complete) self.report.representation = .partial else if (self.report.representation == .not_processed) {
                    self.report.representation = .complete;
                }
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
                return null;
            }
        };

        /// One delayed batch on the same owned result. Prepare child options
        /// before closing selection or allocating. Parent on_error is the value
        /// latched by the DOT parse; child runtime options belong to this call.
        /// Sink/child/parent stops leave remaining envelopes visibly pending.
        /// No resume/retry is implied: after starting the batch, selection closes.
        pub fn processPendingMarkup(allocator: std.mem.Allocator, result: *CheckResult, diagnostics: DiagnosticSink, options: MarkupOptions) (SelectionError || Child.Policies.Error || Child.InputError)!void {
            if (!can_retain) return error.MarkupRetentionDisabled;
            if (!can_delay) return error.MarkupNotPassthrough;
            try result.checkDelayed();
            const document = result.dot.document orelse return error.DocumentUnavailable;
            const preparing = Child.prepare(options.markup);
            const ready = if (@typeInfo(@TypeOf(preparing)) == .error_union) try preparing else preparing;
            if (!result.markup.requested) return;
            result._delayed.closed = true;
            var context: Context = .{
                .sink = diagnostics,
                .retaining = true,
                .ready = ready,
                .allocator = allocator,
                .resources = options.markup_resources,
                .report = result.markup,
                .children = result._markup_results,
            };
            result._markup_results = .empty;
            defer {
                context.report.complete = context.report.stop == null and result.pendingMarkup().len == 0;
                if (context.report.representation != .partial and result.pendingMarkup().len != 0)
                    context.report.representation = .not_processed;
                if (result.pendingMarkup().len == 0) {
                    result._delayed.pending.deinit(allocator);
                    result._delayed.pending = .empty;
                    result._delayed.next = 0;
                }
                result.markup = context.report;
                result._markup_results = context.children;
            }
            while (result._delayed.next < result._delayed.pending.items.len) {
                const envelope = result._delayed.pending.items[result._delayed.next];
                // Admission validated the envelope; the borrowed source must
                // remain unchanged for the whole result lifetime.
                const input: support.processor.Fragment = .{
                    .bytes = document.source[envelope.start + 1 ..][0 .. envelope.len - 2],
                    .origin = envelope.start + 1,
                };
                const visited = context.report.visited;
                const stop = context.processRetained(envelope, input, result._delayed.on_error);
                if (context.report.visited != visited) result._delayed.next += 1;
                if (context.failure) |err| return err;
                if (stop != null) break;
            }
        }

        fn parse(comptime backend: api.ScannerBackend, comptime cancellable: bool, allocator: std.mem.Allocator, source: []const u8, context: *Context, effective: Binding.State, options: DotOptions) api.ParseResult {
            const Core = engine.EngineWithProcessor(api, if (runtime_policy) null else baseline.parsing, false, cancellable, backend, *Context);
            return Core.parseBorrowed(allocator, source, context.dotSink(), options.parse, .{
                .processor = context,
                .parsing = if (runtime_policy) effective.parsing else {},
                .cancellation = if (cancellable) options.cancellation else {},
            });
        }

        /// One synchronous operation; no Session/advance or combined budget is
        /// exposed. Child buffers are reused unless retention.markup is enabled.
        /// Runtime policies are prepared before scanning, allocations or callbacks.
        pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8, diagnostics: DiagnosticSink, options: CheckOptions) Error!CheckResult {
            const effective = if (runtime_policy) try Binding.prepare(.{ .policy = options.dot.policy }) else Binding.prepare(.{});
            const requested = if (runtime_policy) effective.parsing.markup == .process else baseline.parsing.markup == .process;
            const retaining = requested and (if (runtime_policy) effective.parsing.retention.markup else baseline.parsing.retention.markup);
            const preparing = Child.prepare(options.markup);
            const ready = if (@typeInfo(@TypeOf(preparing)) == .error_union) try preparing else preparing;
            var context: Context = .{ .sink = diagnostics, .retaining = retaining, .report = .{ .requested = requested } };
            if (can_retain) {
                context.ready = ready;
                context.allocator = allocator;
                context.resources = options.markup_resources;
            }
            errdefer if (can_retain) {
                for (context.children.items) |*child| child.result.deinit();
                context.children.deinit(allocator);
            };
            if (can_process and requested and !retaining) context.workspace = ready.initWorkspace(allocator, options.markup_resources);
            defer if (can_process and requested and !retaining) context.workspace.deinit();
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
            context.report.complete = requested and parsed.completion == .complete and context.report.stop == null;
            if (context.report.complete and context.report.visited == 0) context.report.representation = .complete;
            if (requested and !context.report.complete and context.report.representation == .complete) context.report.representation = .partial;
            const collect = (if (runtime_policy) effective.parsing.on_error else baseline.parsing.on_error) == .collect;
            const checked: ?api.ValidationResult = if (parsed.document != null and parsed.diagnostic_stop == null and parsed.diagnostic_delivery == .complete and
                (parsed.outcome == .success or (parsed.outcome == .invalid_syntax and collect)))
                validation.validate(if (runtime_policy) null else baseline.validation, &parsed.document.?, context.dotSink(), if (runtime_policy) effective.validation else {}, options.dot.validation)
            else
                null;
            return .{
                .dot = .{
                    .document = parsed.document,
                    ._allocation_lengths = parsed._allocation_lengths,
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
                ._markup_results = context.children,
                ._markup_retained = retaining,
                ._delayed = if (can_delay) .{
                    .mode = if (runtime_policy) effective.parsing.markup else baseline.parsing.markup,
                    .enabled = if (runtime_policy) effective.parsing.retention.markup else baseline.parsing.retention.markup,
                    .on_error = if (runtime_policy) effective.parsing.on_error else baseline.parsing.on_error,
                } else {},
            };
        }
    };
}
