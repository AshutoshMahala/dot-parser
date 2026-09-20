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
//! - `BoundedSession` / `Profile.Session` — fixed-storage resumable execution.
//! - `location`, `diagnostic`, `console` — underlying modules, exported whole.
//! - `lexer` — public lexical vocabulary and ordinary cursor, selected here.
//!
//! The syntax-event sink, low-level parser machine, and document builder remain private and
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
const scratch_impl = @import("scratch.zig");
const policy_impl = @import("policy.zig");

pub const Policy = policy_impl.Policy;
pub const PolicyValidation = policy_impl.Check;
pub const PolicyIssue = policy_impl.Issue;
pub const PolicyError = policy_impl.Error;
pub const PolicyConfig = policy_impl.Config;
pub const GraphKind = policy_impl.GraphKind;
pub const GraphTreatment = policy_impl.GraphTreatment;
pub const RuleSeverity = policy_impl.RuleSeverity;
pub const OperatorReading = policy_impl.OperatorReading;
pub const ScannerBackend = policy_impl.ScannerBackend;
pub const Recovery = policy_impl.Recovery;
const DefaultProfile = Profile(.{});

/// Policy-bound parsing, execution, validation and interpretation. Runtime
/// overrides are off by default; every supported setting has full parity.
pub fn Profile(comptime config: PolicyConfig) type {
    return @import("profile.zig").Profile(@This(), config);
}

/// Library-default policy verification is compile-time-only.
pub const validatePolicy = Profile(.{}).validatePolicy;

pub const location = @import("location.zig");
pub const diagnostic = @import("diagnostic.zig");
const lexer_impl = @import("lexer/lexer.zig");
pub const lexer = struct {
    pub const Token = lexer_impl.Token;
    pub const Result = lexer_impl.Result;
    /// Ordinary lexing with the library-default scalar backend.
    pub const Lexer = lexer_impl.Lexer;
    /// Low-level fixed-backend lexer. Parsing selects through Policy.scanner.
    pub const For = lexer_impl.For;
};
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
/// The original header, never reclassified by a policy.
pub const DeclaredGraphKind = syntax_impl.GraphKind;
pub const EdgeOperator = syntax_impl.EdgeOperator;
pub const ParseScratch = scratch_impl.Storage;
pub const FixedParseScratch = scratch_impl.Fixed;
pub const ScopeId = syntax_impl.ScopeId;
pub const ScopeView = syntax_impl.ScopeView;
pub const Subgraph = syntax_impl.Subgraph;
pub const Traversal = syntax_impl.Traversal;
pub const Document = syntax_impl.Document;
pub const Statement = syntax_impl.Statement;
pub const StatementId = syntax_impl.StatementId;
pub const ScopedStatement = syntax_impl.ScopedStatement;
pub const StatementRange = syntax_impl.StatementRange;
pub const NodeStatement = syntax_impl.NodeStatement;
pub const NodeReference = syntax_impl.NodeReference;
pub const NodeReferenceView = syntax_impl.NodeReferenceView;
pub const PortSyntax = syntax_impl.PortSyntax;
pub const PortedReference = syntax_impl.PortedReference;
pub const Endpoint = syntax_impl.Endpoint;
pub const EdgeView = syntax_impl.EdgeView;
pub const EdgeChainView = syntax_impl.EdgeChainView;
pub const EdgeLinkSource = syntax_impl.EdgeLinkSource;
pub const ScopedEdgeStatement = syntax_impl.ScopedEdgeStatement;
pub const ScopedEdgeLink = syntax_impl.ScopedEdgeLink;
pub const EdgeStatement = syntax_impl.EdgeStatement;
pub const EdgeChainStatement = syntax_impl.EdgeChainStatement;
pub const EdgeLink = syntax_impl.EdgeLink;
pub const EdgeLinkRange = syntax_impl.EdgeLinkRange;
pub const Attribute = syntax_impl.Attribute;
pub const AttributeRange = syntax_impl.AttributeRange;
pub const AttributeTarget = syntax_impl.AttributeTarget;
pub const AttributeStatement = syntax_impl.AttributeStatement;
pub const Assignment = syntax_impl.Assignment;

// Façade option/result types.
pub const ValidateOptions = DefaultProfile.Options;
pub const ValidationResult = validate_impl.Result;

pub const DocumentCapacities = syntax_impl.Capacities;
pub const DocumentStorage = syntax_impl.DocumentStorage;
pub const FixedDocumentStorage = syntax_impl.FixedDocumentStorage;

/// Independent retained-output and temporary-nesting storage.
pub const ParseMemory = struct { document: DocumentStorage, scratch: ParseScratch = .{} };

/// Allocator/storage choices are explicit resources, not behavioral policies.
pub const ParseResources = struct {
    /// Temporary nesting frames; null uses the explicit document allocator.
    scratch_allocator: ?std.mem.Allocator = null,
    /// Preallocate output pools, not temporary nesting frames. A hint, not an
    /// acceptance limit. `measure` reports exact capacities; fixed pools and
    /// ParseMemory provide the allocation-free path.
    document_capacities: DocumentCapacities = .{},
};
pub const ParseOptions = DefaultProfile.ParseOptions;

/// Why document or temporary storage could not hold the parse. A façade-level taxonomy:
/// the private event-sink machinery never leaks into the public API.
pub const StorageFailure = enum {
    /// The document or temporary-scratch allocator ran out of memory.
    out_of_memory,
    /// A caller-provided document pool or nesting scratch filled up.
    pool_exhausted,
    /// A statement pool or global order exceeds the compact index/count domain.
    statement_index_overflow,
    /// An unexpected internal failure — please report a bug. Never produced
    /// by the documented builder error sets; exists so an unmapped future
    /// error is visible instead of being mislabeled.
    internal,
    /// Attribute-pool indices exceed the compact representation.
    attribute_index_overflow,
    /// Continuation-link indices exceed the compact representation.
    edge_link_index_overflow,
    ported_reference_index_overflow,
};

/// The public parse outcome. Diagnostics explaining failures travel through
/// the caller's diagnostic sink, never through this value.
pub const ParseOutcome = union(enum) {
    success,
    /// A cancellation-enabled operation or a session was cancelled.
    cancelled,
    /// The input is malformed in any DOT dialect.
    invalid_syntax,
    /// Parsing stopped at a recognized-but-deferred DOT construct; validity
    /// beyond that boundary is unknown.
    unsupported_feature,
    /// A caller-configured limit was reached; the input may still be valid.
    resource_exhausted,
    /// Document or temporary storage could not hold the parse.
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

/// Default fixed policy; select a Profile to change behavioral settings.
pub const parseBorrowed = DefaultProfile.parseBorrowed;

/// Validate a parsed document against the milestone rules. Positions come from
/// the source the document itself borrows — there is no separate source
/// parameter to mismatch. Validation is a complete analysis pass: it
/// continues past every violation and reports all of them into
/// `diagnostics` in source order; the result separates pass completion from
/// document validity (R-FUNC-008).
pub const validate = DefaultProfile.validate;

pub const FixedParseOptions = DefaultProfile.FixedParseOptions;

/// Result of `parseBorrowedIn` and fixed sessions. Unlike `ParseResult` there is deliberately
/// no `deinit`: the document is backed entirely by the caller's storage —
/// release it by reusing or discarding that storage.
pub const FixedParseResult = struct {
    document: ?Document = null,
    outcome: ParseOutcome,
    diagnostic_delivery: diagnostic.Delivery,
};

pub const Cancellation = @import("execution.zig").Cancellation;
pub const ExecutionPhase = parser_impl.Phase;

/// By-value progress, never a partial document. Accepted counts can describe
/// staged output that is later discarded; frontier includes lexical lookahead.
pub const SessionProgress = struct {
    phase: ExecutionPhase,
    /// One past the highest examined byte offset; zero before any byte read.
    /// EOF examination costs work but does not move this frontier.
    source_frontier: usize,
    completed_statements: usize,
    completed_pairs: usize,
    work_used: usize,
    outcome: ?ParseOutcome,
    diagnostic_delivery: diagnostic.Delivery,
};

/// A named policy preset, not a separate execution configuration mechanism.
pub const BoundedSession = Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Session;

/// Allocation-free one-shot parsing under the library-default fixed policy.
pub const parseBorrowedIn = DefaultProfile.parseBorrowedIn;

/// Result of `measure` / `measureIn`. `capacities` is present exactly when
/// the outcome is `.success`: the exact pool sizes a retained parse of the
/// same source needs, nothing more.
pub const MeasureResult = struct {
    capacities: ?DocumentCapacities = null,
    outcome: ParseOutcome,
    diagnostic_delivery: diagnostic.Delivery,
};

/// Count-only parsing with the same policy as retained parsing. Capacities are
/// published only on success; allocator backs nesting scratch, never output.
pub const measure = DefaultProfile.measure;
pub const measureIn = DefaultProfile.measureIn;
pub const CheckOptions = DefaultProfile.CheckOptions;

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

/// One-shot parse and validation under the library-default fixed policy.
pub const parseAndValidate = DefaultProfile.parseAndValidate;

test {
    std.testing.refAllDecls(@This());
    // Private, provisional modules are not exported but their unit tests
    // still run (the syntax-event sink, parser driver, and document builder stay
    // private per PROJECT_STRUCTURE until the contract stabilizes).
    _ = @import("syntax_event.zig");
    _ = @import("parser.zig");
    _ = @import("syntax.zig");
    _ = @import("validate.zig");
    _ = @import("lexer/lexer.zig");
    _ = @import("policy.zig");
}
