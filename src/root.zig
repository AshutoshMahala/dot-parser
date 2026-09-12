//! Public surface of the dot-parser package (milestone 1, step 8).
//!
//! Everything exported here is experimental `0.x` API: usable, tested, and
//! subject to change (R-ARCH-009). The API is layered — the façade functions
//! below are conveniences over public building blocks, never a gate in front
//! of them (R-ARCH-006):
//!
//! - `parseBorrowed` / `parseAndValidate` / `validate` — the front door.
//! - `Document` and friends — what linters and analyzers actually program
//!   against: statements in source order, compact borrowed ranges.
//! - `location`, `diagnostic`, `console`, `lexer` — the underlying modules,
//!   exported whole for consumers that need them.
//!
//! The syntax-event sink, parser driver, and document builder remain private and
//! provisional; they are reachable only through the façade until the
//! contract stabilizes (PROJECT_STRUCTURE.md).
//!
//! ## Ownership at a glance
//!
//! - `source` is caller-owned and borrowed: every range and span indexes it,
//!   and it must outlive any returned document (R-MEM-004).
//! - Trees use the explicit caller allocator; release with `deinit` (bulk,
//!   no per-node walk) or by resetting the caller's arena (R-MEM-005).
//! - Diagnostics flow into the caller's sink — one uniform reporting surface
//!   for every phase; results carry only small outcome values (R-DIAG-003).

const std = @import("std");

const parser_impl = @import("parser.zig");
const syntax_impl = @import("syntax.zig");
const validate_impl = @import("validate.zig");

pub const location = @import("location.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const lexer = @import("lexer.zig");
/// Explicit raw-identifier decoding into caller storage or a writer.
pub const identifier = @import("identifier.zig");

/// Default console presentation for diagnostics — one way to render, shipped
/// out of the box. Consumers bring their own reporting by implementing
/// `DiagnosticSink`; the core never renders anything itself.
pub const console = @import("console.zig");

// Source positions.
pub const Location = location.Location;
pub const Span = location.Span;
pub const Range = location.Range;

// WDP diagnostics.
pub const wdp_namespace = diagnostic.namespace;
pub const Severity = diagnostic.Severity;
pub const Code = diagnostic.Code;
pub const Details = diagnostic.Details;
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticSink = diagnostic.Sink;
pub const DiagnosticSinkError = diagnostic.SinkError;
pub const FixedDiagnosticBag = diagnostic.FixedBag;

// The borrowed syntax document and its vocabulary.
pub const GraphKind = syntax_impl.GraphKind;
pub const EdgeOperator = syntax_impl.EdgeOperator;
pub const Document = syntax_impl.Document;
pub const Statement = syntax_impl.Statement;
pub const StatementId = syntax_impl.StatementId;
pub const NodeStatement = syntax_impl.NodeStatement;
pub const EdgeStatement = syntax_impl.EdgeStatement;
pub const Attribute = syntax_impl.Attribute;
pub const AttributeRange = syntax_impl.AttributeRange;
pub const AttributeTarget = syntax_impl.AttributeTarget;
pub const AttributeStatement = syntax_impl.AttributeStatement;
pub const Assignment = syntax_impl.Assignment;

// Façade option/result types.
pub const ValidateOptions = validate_impl.Options;
pub const ValidationResult = validate_impl.Result;

pub const DocumentCapacities = syntax_impl.Capacities;
pub const DocumentStorage = syntax_impl.DocumentStorage;
pub const FixedDocumentStorage = syntax_impl.FixedDocumentStorage;

pub const ParseOptions = struct {
    /// Maximum number of statements before the parse stops with a
    /// `resource_exhausted` outcome. A statement/output capacity bound, not
    /// a total-work budget (work is one linear scan of the input).
    max_statements: usize = std.math.maxInt(usize),
    /// Total key/value pairs, including standalone assignments; not a scan budget.
    max_attributes: usize = std.math.maxInt(usize),
    /// Preallocate the document's pools. With capacities that cover the
    /// document, the build performs no allocation after the pools are
    /// reserved — the intended mode for fixed-buffer allocators. Fixed-
    /// buffer callers typically derive the numbers from `max_statements`.
    document_capacities: DocumentCapacities = .{},
};

/// Why document storage could not hold the document. A façade-level taxonomy:
/// the private event-sink machinery never leaks into the public API.
pub const StorageFailure = enum {
    /// The document allocator ran out of memory.
    out_of_memory,
    /// A caller-provided fixed pool filled up (`parseBorrowedIn`).
    pool_exhausted,
    /// More statements of one kind than the document's index width addresses.
    statement_index_overflow,
    /// A source position beyond the retained-range limit (4 GiB).
    source_offset_overflow,
    /// An unexpected internal failure — please report a bug. Never produced
    /// by the documented builder error sets; exists so an unmapped future
    /// error is visible instead of being mislabeled.
    internal,
    /// Attribute-pool indices exceed the compact representation.
    attribute_index_overflow,
};

/// The public parse outcome. Diagnostics explaining failures travel through
/// the caller's diagnostic sink, never through this value.
pub const ParseOutcome = union(enum) {
    success,
    /// The input is malformed in any DOT dialect.
    invalid_syntax,
    /// Parsing stopped at a recognized-but-deferred DOT construct; validity
    /// beyond that boundary is unknown.
    unsupported_feature,
    /// A caller-configured limit was reached; the input may still be valid.
    resource_exhausted,
    /// Document storage could not hold the document.
    storage_failure: StorageFailure,
};

/// Result of `parseBorrowed`. The document is present exactly when
/// `outcome == .success` and is owned by the caller.
pub const ParseResult = struct {
    document: ?Document = null,
    outcome: ParseOutcome,
    diagnostic_delivery: diagnostic.Delivery,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        if (self.document) |*document| syntax_impl.deinitOwnedDocument(document, allocator);
        self.* = undefined;
    }
};

/// Parse one DOT document from caller-owned bytes into a borrowed syntax
/// document.
///
/// - `source` must stay alive and unchanged for as long as the document is used.
/// - `allocator` owns the document's storage (arena, fixed buffer, or GPA).
/// - Failure diagnostics are emitted into `diagnostics`; the parser is
///   fail-fast, so a failure bag holds one entry today.
pub fn parseBorrowed(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: diagnostic.Sink,
    options: ParseOptions,
) ParseResult {
    var builder = makeBuilder(allocator, source, options.document_capacities) catch |err| {
        return .{
            .outcome = .{ .storage_failure = storageFailure(err) },
            .diagnostic_delivery = emitStorageDiagnostic(diagnostics, err, null, .complete),
        };
    };
    defer builder.deinit();

    const result = parser_impl.parse(source, &builder, diagnostics, .{
        .max_statements = options.max_statements,
        .max_attributes = options.max_attributes,
    });
    switch (result.outcome) {
        .success => {},
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

fn makeBuilder(
    allocator: std.mem.Allocator,
    source: []const u8,
    capacities: DocumentCapacities,
) syntax_impl.Builder.Error!syntax_impl.Builder {
    return syntax_impl.Builder.initCapacity(allocator, source, capacities);
}

/// Map the document builders' error sets into the public storage taxonomy.
/// Exhaustive over the documented sets; anything else surfaces as
/// `.internal` rather than being mislabeled (honest telemetry).
fn storageFailure(err: anyerror) StorageFailure {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.PoolExhausted => .pool_exhausted,
        error.StatementIndexOverflow => .statement_index_overflow,
        error.AttributeIndexOverflow => .attribute_index_overflow,
        error.SourceOffsetOverflow => .source_offset_overflow,
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
    const span: location.Span = if (info) |i| i.span else .{ .start = .start, .byte_len = 0 };
    const d: diagnostic.Diagnostic = switch (storageFailure(err)) {
        .out_of_memory => .{
            .code = .resource_memory_exhausted,
            .span = span,
        },
        .pool_exhausted, .statement_index_overflow, .source_offset_overflow, .attribute_index_overflow => .{
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

/// Validate a parsed document against the milestone rules. Positions come from
/// the source the document itself borrows — there is no separate source
/// parameter to mismatch. Validation is a complete analysis pass: it
/// continues past every violation and reports all of them into
/// `diagnostics` in source order; the result separates pass completion from
/// document validity (R-FUNC-008).
pub fn validate(
    document: *const Document,
    diagnostics: diagnostic.Sink,
    options: ValidateOptions,
) ValidationResult {
    return validate_impl.validate(document, diagnostics, options);
}

pub const FixedParseOptions = struct {
    /// See `ParseOptions.max_statements`. Capacity needs no option here:
    /// the caller's pools are the capacity.
    max_statements: usize = std.math.maxInt(usize),
    /// Total key/value pairs, including standalone assignments; not a scan budget.
    max_attributes: usize = std.math.maxInt(usize),
};

/// Result of `parseBorrowedIn`. Unlike `ParseResult` there is deliberately
/// no `deinit`: the document is backed entirely by the caller's storage —
/// release it by reusing or discarding that storage.
pub const FixedParseResult = struct {
    document: ?Document = null,
    outcome: ParseOutcome,
    diagnostic_delivery: diagnostic.Delivery,
};

/// Parse one DOT document into caller-provided fixed pools: no allocator,
/// nothing grows, failure is deterministic (`storage_failure` with
/// `.pool_exhausted` when a pool fills). The embedded-first sibling of
/// `parseBorrowed` (R-MEM-003); same parser, same grammar, different
/// storage policy.
pub fn parseBorrowedIn(
    source: []const u8,
    storage: DocumentStorage,
    diagnostics: diagnostic.Sink,
    options: FixedParseOptions,
) FixedParseResult {
    var builder = syntax_impl.FixedBuilder.init(source, storage);
    const result = parser_impl.parse(source, &builder, diagnostics, .{
        .max_statements = options.max_statements,
        .max_attributes = options.max_attributes,
    });
    switch (result.outcome) {
        .success => {},
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

pub const CheckOptions = struct {
    parse: ParseOptions = .{},
    validation: ValidateOptions = .{},
};

/// Result of `parseAndValidate`. `validation` is present exactly when
/// parsing succeeded (a document exists to validate).
pub const CheckResult = struct {
    document: ?Document = null,
    outcome: ParseOutcome,
    validation: ?ValidationResult = null,
    diagnostic_delivery: diagnostic.Delivery,

    /// The document parsed completely AND validation found no violations.
    pub fn documentValid(self: *const CheckResult) bool {
        const validation = self.validation orelse return false;
        return validation.documentValid();
    }

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        if (self.document) |*document| syntax_impl.deinitOwnedDocument(document, allocator);
        self.* = undefined;
    }
};

/// One-shot convenience: parse, then (when parsing succeeds) validate, with
/// every diagnostic from both phases arriving in the same `diagnostics`
/// sink. `parseBorrowed` and `validate` remain available separately for
/// staged consumers.
pub fn parseAndValidate(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: diagnostic.Sink,
    options: CheckOptions,
) CheckResult {
    var parsed = parseBorrowed(allocator, source, diagnostics, options.parse);
    if (parsed.document == null) {
        return .{
            .outcome = parsed.outcome,
            .diagnostic_delivery = parsed.diagnostic_delivery,
        };
    }

    const validation = validate_impl.validate(
        &parsed.document.?,
        diagnostics,
        options.validation,
    );
    const delivery: diagnostic.Delivery = if (parsed.diagnostic_delivery == .failed or
        validation.diagnostic_delivery == .failed) .failed else .complete;

    return .{
        .document = parsed.document,
        .outcome = .success,
        .validation = validation,
        .diagnostic_delivery = delivery,
    };
}

test {
    std.testing.refAllDecls(@This());
    // Private, provisional modules are not exported but their unit tests
    // still run (the syntax-event sink, parser driver, and document builder stay
    // private per PROJECT_STRUCTURE until the contract stabilizes).
    _ = @import("syntax_event.zig");
    _ = @import("parser.zig");
    _ = @import("syntax.zig");
    _ = @import("validate.zig");
}
