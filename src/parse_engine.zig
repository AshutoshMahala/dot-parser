//! Storage adapters around the single grammar machine. Policy specialization
//! happens outside its scan loop; no source-sized copy or hidden allocator.
const std = @import("std");
const parser_impl = @import("parser.zig");
const syntax_impl = @import("syntax.zig");
const scratch_impl = @import("scratch.zig");
const lexer_impl = @import("lexer/lexer.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
const location = @import("location.zig");

pub fn Engine(comptime api: type, comptime fixed: ?policy.ParseSettings, comptime metering: bool, comptime cancellable: bool, comptime backend: policy.ScannerBackend) type {
    return struct {
        pub const cancellation_enabled = cancellable;
        const ParseResult = api.ParseResult;
        const FixedParseResult = api.FixedParseResult;
        const MeasureResult = api.MeasureResult;
        const ParseOutcome = api.ParseOutcome;
        const ParseMemory = api.ParseMemory;
        const ParseScratch = api.ParseScratch;
        const StorageFailure = api.StorageFailure;
        const DiagnosticSink = api.DiagnosticSink;
        const SessionProgress = api.SessionProgress;

        pub const Options = struct {
            parsing: if (fixed == null) policy.ParseSettings else void,
            cancellation: if (cancellable) ?api.Cancellation else void,
        };

        fn DriverFor(comptime Sink: type) type {
            return parser_impl.Machine(Sink, metering, false, cancellable, lexer_impl.scannerFor(backend), fixed);
        }

        fn drive(source: []const u8, events: anytype, diagnostics: DiagnosticSink, scratch: *scratch_impl.Stack, options: Options) parser_impl.Result {
            const Driver = DriverFor(@TypeOf(events));
            var machine: Driver = .{
                .tokens = @FieldType(Driver, "tokens").init(source),
                .events = events,
                .diagnostics = diagnostics,
                .settings = options.parsing,
                .scratch = scratch,
                .cancellation = options.cancellation,
            };
            return machine.runToCompletion();
        }

        pub fn parseBorrowed(
            allocator: std.mem.Allocator,
            source: []const u8,
            diagnostics: diagnostic.Sink,
            resources: api.ParseResources,
            options: Options,
        ) ParseResult {
            var builder = syntax_impl.Builder.initCapacity(allocator, source, resources.document_capacities) catch |err| {
                return .{
                    .outcome = .{ .storage_failure = storageFailure(err) },
                    .diagnostic_delivery = emitStorageDiagnostic(diagnostics, err, null, .complete),
                };
            };
            defer builder.deinit();
            var scratch: scratch_impl.Stack = .{ .allocator = resources.scratch_allocator orelse allocator };
            defer scratch.deinit();

            const result = drive(source, &builder, diagnostics, &scratch, options);
            switch (result.outcome) {
                .scratch_failure => |err| return .{ .outcome = .{ .storage_failure = storageFailure(err) }, .diagnostic_delivery = result.diagnostic_delivery },
                .success => {},
                .cancelled => return .{ .outcome = .cancelled, .diagnostic_delivery = result.diagnostic_delivery },
                .invalid_syntax => return .{
                    .outcome = .invalid_syntax,
                    .diagnostic_delivery = result.diagnostic_delivery,
                },
                .unsupported_feature => return .{
                    .outcome = .unsupported_feature,
                    .diagnostic_delivery = result.diagnostic_delivery,
                },
                .resource_exhausted => return .{
                    .outcome = .resource_exhausted,
                    .diagnostic_delivery = result.diagnostic_delivery,
                },
                // The façade's only event sink is the document builder, so a sink
                // failure here is by definition a storage failure.
                .sink_failure => |err| return .{
                    .outcome = .{ .storage_failure = storageFailure(err) },
                    .diagnostic_delivery = emitStorageDiagnostic(
                        diagnostics,
                        err,
                        builder.failure_info,
                        result.diagnostic_delivery,
                    ),
                },
            }
            const document = builder.toDocument() catch |err| {
                return .{
                    .outcome = .{ .storage_failure = storageFailure(err) },
                    .diagnostic_delivery = emitStorageDiagnostic(
                        diagnostics,
                        err,
                        builder.failure_info,
                        result.diagnostic_delivery,
                    ),
                };
            };
            return .{
                .document = document,
                .outcome = .success,
                .diagnostic_delivery = result.diagnostic_delivery,
            };
        }

        /// Map the document builders' error sets into the public storage taxonomy.
        /// Exhaustive over the documented sets; anything else surfaces as
        /// `.internal` rather than being mislabeled (honest telemetry).
        fn storageFailure(err: anyerror) StorageFailure {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.PoolExhausted, error.NestingStorageExhausted => .pool_exhausted,
                error.StatementIndexOverflow => .statement_index_overflow,
                error.AttributeIndexOverflow => .attribute_index_overflow,
                error.EdgeLinkIndexOverflow => .edge_link_index_overflow,
                error.PortedReferenceIndexOverflow => .ported_reference_index_overflow,
                else => .internal,
            };
        }

        /// Storage failures are failures like any other: they are explained through
        /// the diagnostic sink (uniform reporting surface), with the builder's
        /// recorded detail naming the exhausted pool/limit and where it happened.
        /// `.internal` failures emit nothing (there is no truthful diagnostic to
        /// give); the outcome still reports them.
        fn emitStorageDiagnostic(
            diagnostics: diagnostic.Sink,
            err: anyerror,
            info: ?syntax_impl.StorageFailureInfo,
            delivery: diagnostic.Delivery,
        ) diagnostic.Delivery {
            const span: location.Span = if (info) |i| i.span else .{ .start = 0, .len = 0 };
            const d: diagnostic.Diagnostic = switch (storageFailure(err)) {
                .out_of_memory => .{
                    .code = .resource_memory_exhausted,
                    .span = span,
                },
                .pool_exhausted, .statement_index_overflow, .attribute_index_overflow, .edge_link_index_overflow, .ported_reference_index_overflow => .{
                    .code = .resource_capacity_exhausted,
                    .span = span,
                    .details = if (info) |i|
                        (if (i.capacity) |capacity| .{ .capacity = capacity } else .none)
                    else
                        .none,
                },
                .internal => return delivery,
            };
            diagnostics.emit(d) catch return .failed;
            return delivery;
        }

        pub const Session = struct {
            const Self = @This();
            const Driver = DriverFor(*syntax_impl.FixedBuilder);

            builder: syntax_impl.FixedBuilder,
            scratch: scratch_impl.Stack,
            machine: Driver,
            terminal: ?FixedParseResult = null,

            pub fn init(source: []const u8, memory: ParseMemory, diagnostics: DiagnosticSink, options: Options) Self {
                return .{
                    .builder = syntax_impl.FixedBuilder.init(source, memory.document),
                    .scratch = .{ .frames = memory.scratch.frames },
                    .machine = .{
                        .tokens = @FieldType(Driver, "tokens").init(source),
                        // Never retain a pointer into the returned init temporary.
                        .events = undefined,
                        .diagnostics = diagnostics,
                        .settings = options.parsing,
                        .cancellation = options.cancellation,
                    },
                };
            }

            /// At most `budget` scan/grammar/dispatch steps. Zero may observe
            /// cancellation; otherwise it yields without work. Callouts and terminal
            /// diagnostic/abort housekeeping are excluded from work credits.
            pub fn advance(self: *Self, budget: usize) SessionProgress {
                if (!metering) @compileError("metering is disabled; use run()");
                self.machine.events = &self.builder;
                self.machine.scratch = &self.scratch;
                const progress = self.machine.advance(budget);
                self.settle();
                return .{
                    .phase = progress.phase,
                    .source_frontier = progress.source_frontier,
                    .completed_statements = progress.completed_statements,
                    .completed_pairs = progress.completed_pairs,
                    .work_used = progress.work_used,
                    .outcome = if (self.terminal) |r| r.outcome else null,
                    .diagnostic_delivery = if (self.terminal) |r| r.diagnostic_delivery else .complete,
                };
            }

            /// Run the remaining parse to completion. Cancellation stays active when
            /// configured, independently of whether work metering is enabled.
            pub fn run(self: *Self) FixedParseResult {
                self.machine.events = &self.builder;
                self.machine.scratch = &self.scratch;
                _ = self.machine.runToCompletion();
                self.settle();
                return self.terminal.?;
            }

            /// Null until terminal; a document exists exactly on successful commit.
            /// Repeated reads return the same borrowed view, without consuming it.
            pub fn result(self: *const Self) ?FixedParseResult {
                return self.terminal;
            }

            /// Terminal cleanup without a hook or positive work budget. Success or
            /// a concrete failure already latched cannot be replaced by cancellation.
            pub fn cancel(self: *Self) FixedParseResult {
                self.machine.events = &self.builder;
                self.machine.scratch = &self.scratch;
                _ = self.machine.cancel();
                self.settle();
                return self.terminal.?;
            }

            fn settle(self: *Self) void {
                if (self.terminal != null) return;
                const parsed = self.machine.terminal orelse return;
                const outcome: ParseOutcome = switch (parsed.outcome) {
                    .success => .success,
                    .cancelled => .cancelled,
                    .invalid_syntax => .invalid_syntax,
                    .unsupported_feature => .unsupported_feature,
                    .resource_exhausted => .resource_exhausted,
                    .sink_failure, .scratch_failure => |err| .{ .storage_failure = storageFailure(err) },
                };
                self.terminal = .{
                    .document = if (parsed.outcome == .success) self.builder.toDocument() else null,
                    .outcome = outcome,
                    .diagnostic_delivery = if (parsed.outcome == .sink_failure)
                        emitStorageDiagnostic(self.machine.diagnostics, parsed.outcome.sink_failure, self.builder.failure_info, parsed.diagnostic_delivery)
                    else
                        parsed.diagnostic_delivery,
                };
            }
        };

        pub fn parseBorrowedIn(
            source: []const u8,
            memory: ParseMemory,
            diagnostics: diagnostic.Sink,
            options: Options,
        ) FixedParseResult {
            var builder = syntax_impl.FixedBuilder.init(source, memory.document);
            var scratch: scratch_impl.Stack = .{ .frames = memory.scratch.frames };
            const result = drive(source, &builder, diagnostics, &scratch, options);
            switch (result.outcome) {
                .scratch_failure => |err| return .{ .outcome = .{ .storage_failure = storageFailure(err) }, .diagnostic_delivery = result.diagnostic_delivery },
                .success => {},
                .cancelled => return .{ .outcome = .cancelled, .diagnostic_delivery = result.diagnostic_delivery },
                .invalid_syntax => return .{
                    .outcome = .invalid_syntax,
                    .diagnostic_delivery = result.diagnostic_delivery,
                },
                .unsupported_feature => return .{
                    .outcome = .unsupported_feature,
                    .diagnostic_delivery = result.diagnostic_delivery,
                },
                .resource_exhausted => return .{
                    .outcome = .resource_exhausted,
                    .diagnostic_delivery = result.diagnostic_delivery,
                },
                .sink_failure => |err| return .{
                    .outcome = .{ .storage_failure = storageFailure(err) },
                    .diagnostic_delivery = emitStorageDiagnostic(
                        diagnostics,
                        err,
                        builder.failure_info,
                        result.diagnostic_delivery,
                    ),
                },
            }
            return .{
                .document = builder.toDocument(),
                .outcome = .success,
                .diagnostic_delivery = result.diagnostic_delivery,
            };
        }

        pub fn measure(
            allocator: std.mem.Allocator,
            source: []const u8,
            diagnostics: diagnostic.Sink,
            resources: api.ParseResources,
            options: Options,
        ) MeasureResult {
            var scratch: scratch_impl.Stack = .{ .allocator = resources.scratch_allocator orelse allocator };
            defer scratch.deinit();
            return measureWith(source, diagnostics, &scratch, options);
        }

        /// `measure` without an allocator: nesting frames come from `scratch`
        /// (`FixedParseScratch`), so it runs wherever `parseBorrowedIn` runs.
        pub fn measureIn(
            source: []const u8,
            scratch: ParseScratch,
            diagnostics: diagnostic.Sink,
            options: Options,
        ) MeasureResult {
            var stack: scratch_impl.Stack = .{ .frames = scratch.frames };
            return measureWith(source, diagnostics, &stack, options);
        }

        fn measureWith(
            source: []const u8,
            diagnostics: diagnostic.Sink,
            scratch: *scratch_impl.Stack,
            options: Options,
        ) MeasureResult {
            var counting: syntax_impl.CountingSink = .{};
            const result = drive(source, &counting, diagnostics, scratch, options);
            return .{
                .capacities = if (result.outcome == .success) counting.counts else null,
                .outcome = switch (result.outcome) {
                    .success => .success,
                    .invalid_syntax => .invalid_syntax,
                    .unsupported_feature => .unsupported_feature,
                    .resource_exhausted => .resource_exhausted,
                    .scratch_failure => |err| .{ .storage_failure = storageFailure(err) },
                    // The counting sink cannot fail.
                    .sink_failure => unreachable,
                    .cancelled => .cancelled,
                },
                .diagnostic_delivery = result.diagnostic_delivery,
            };
        }
    };
}
