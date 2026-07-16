//! Public surface of the dot-parser package (milestone 1, step 8).
//!
//! Everything exported here is experimental `0.x` API: usable, tested, and
//! subject to change (R-ARCH-009). The API is layered — the façade functions
//! below are conveniences over public building blocks, never a gate in front
//! of them (R-ARCH-006):
//!
//! - `parseBorrowed` / `parseAndValidate` / `validate` — the front door.
//! - `Tree` and friends — what linters and analyzers actually program
//!   against: statements in source order, compact borrowed ranges.
//! - `location`, `diagnostic`, `console`, `lexer` — the underlying modules,
//!   exported whole for consumers that need them.
//!
//! The syntax-event sink, parser driver, and tree builder remain private and
//! provisional; they are reachable only through the façade until the
//! contract stabilizes (PROJECT_STRUCTURE.md).
//!
//! ## Ownership at a glance
//!
//! - `source` is caller-owned and borrowed: every range and span indexes it,
//!   and it must outlive any returned tree (R-MEM-004).
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

// The borrowed syntax tree and its vocabulary.
pub const GraphKind = syntax_impl.GraphKind;
pub const EdgeOperator = syntax_impl.EdgeOperator;
pub const Tree = syntax_impl.Tree;
pub const Statement = syntax_impl.Statement;
pub const StatementId = syntax_impl.StatementId;
pub const NodeStatement = syntax_impl.NodeStatement;
pub const EdgeStatement = syntax_impl.EdgeStatement;

// Façade option/result types.
pub const ValidateOptions = validate_impl.Options;
pub const ValidationResult = validate_impl.Result;

pub const TreeCapacities = struct {
    statements: usize = 0,
    nodes: usize = 0,
    edges: usize = 0,
};

pub const ParseOptions = struct {
    /// Maximum number of statements before the parse stops with a
    /// `resource_exhausted` outcome. A statement/output capacity bound, not
    /// a total-work budget (work is one linear scan of the input).
    max_statements: usize = std.math.maxInt(usize),
    /// Preallocate the tree's pools. With capacities that cover the
    /// document, the build performs no allocation after the pools are
    /// reserved — the intended mode for fixed-buffer allocators. Fixed-
    /// buffer callers typically derive the numbers from `max_statements`.
    tree_capacities: TreeCapacities = .{},
};

/// Why tree storage could not hold the document. A façade-level taxonomy:
/// the private event-sink machinery never leaks into the public API.
pub const StorageFailure = enum {
    /// The tree allocator ran out of memory.
    out_of_memory,
    /// More statements of one kind than the tree's index width addresses.
    statement_index_overflow,
    /// A source position beyond the retained-range limit (4 GiB).
    source_offset_overflow,
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
    /// Tree storage could not hold the document.
    storage_failure: StorageFailure,
};

/// Result of `parseBorrowed`. The tree is present exactly when
/// `outcome == .success` and is owned by the caller.
pub const ParseResult = struct {
    tree: ?Tree = null,
    outcome: ParseOutcome,
    diagnostic_delivery: diagnostic.Delivery,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        if (self.tree) |*tree| tree.deinit(allocator);
        self.* = undefined;
    }
};

/// Parse one DOT document from caller-owned bytes into a borrowed syntax
/// tree.
///
/// - `source` must stay alive and unchanged for as long as the tree is used.
/// - `allocator` owns the tree's storage (arena, fixed buffer, or GPA).
/// - Failure diagnostics are emitted into `diagnostics`; the parser is
///   fail-fast, so a failure bag holds one entry today.
pub fn parseBorrowed(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: diagnostic.Sink,
    options: ParseOptions,
) ParseResult {
    var builder = makeBuilder(allocator, source, options.tree_capacities) catch |err| {
        return .{
            .outcome = .{ .storage_failure = storageFailure(err) },
            .diagnostic_delivery = .complete,
        };
    };
    defer builder.deinit();

    const result = parser_impl.parse(source, &builder, diagnostics, .{
        .max_statements = options.max_statements,
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
        // The façade's only event sink is the tree builder, so a sink
        // failure here is by definition a storage failure.
        .sink_failure => |err| return .{
            .outcome = .{ .storage_failure = storageFailure(err) },
            .diagnostic_delivery = result.diagnostic_delivery,
        },
    }
    const tree = builder.toTree() catch |err| {
        return .{
            .outcome = .{ .storage_failure = storageFailure(err) },
            .diagnostic_delivery = result.diagnostic_delivery,
        };
    };
    return .{
        .tree = tree,
        .outcome = .success,
        .diagnostic_delivery = result.diagnostic_delivery,
    };
}

fn makeBuilder(
    allocator: std.mem.Allocator,
    source: []const u8,
    capacities: TreeCapacities,
) syntax_impl.Builder.Error!syntax_impl.Builder {
    if (capacities.statements == 0 and capacities.nodes == 0 and capacities.edges == 0) {
        return syntax_impl.Builder.init(allocator, source);
    }
    return syntax_impl.Builder.initCapacity(allocator, source, .{
        .statements = capacities.statements,
        .nodes = capacities.nodes,
        .edges = capacities.edges,
    });
}

/// Map the tree builder's error set into the public storage taxonomy.
fn storageFailure(err: anyerror) StorageFailure {
    return switch (err) {
        error.StatementIndexOverflow => .statement_index_overflow,
        error.SourceOffsetOverflow => .source_offset_overflow,
        else => .out_of_memory,
    };
}

/// Validate a parsed tree against the milestone rules. Positions come from
/// the source the tree itself borrows — there is no separate source
/// parameter to mismatch. Validation is a complete analysis pass: it
/// continues past every violation and reports all of them into
/// `diagnostics` in source order; the result separates pass completion from
/// document validity (R-FUNC-008).
pub fn validate(
    tree: *const Tree,
    diagnostics: diagnostic.Sink,
    options: ValidateOptions,
) ValidationResult {
    return validate_impl.validate(tree, diagnostics, options);
}

pub const CheckOptions = struct {
    parse: ParseOptions = .{},
    validation: ValidateOptions = .{},
};

/// Result of `parseAndValidate`. `validation` is present exactly when
/// parsing succeeded (a tree exists to validate).
pub const CheckResult = struct {
    tree: ?Tree = null,
    outcome: ParseOutcome,
    validation: ?ValidationResult = null,
    diagnostic_delivery: diagnostic.Delivery,

    /// The document parsed completely AND validation found no violations.
    pub fn documentValid(self: *const CheckResult) bool {
        const validation = self.validation orelse return false;
        return validation.completed and validation.document_valid;
    }

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        if (self.tree) |*tree| tree.deinit(allocator);
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
    if (parsed.tree == null) {
        return .{
            .outcome = parsed.outcome,
            .diagnostic_delivery = parsed.diagnostic_delivery,
        };
    }

    const validation = validate_impl.validate(
        &parsed.tree.?,
        diagnostics,
        options.validation,
    );
    const delivery: diagnostic.Delivery = if (parsed.diagnostic_delivery == .failed or
        validation.diagnostic_delivery == .failed) .failed else .complete;

    return .{
        .tree = parsed.tree,
        .outcome = .success,
        .validation = validation,
        .diagnostic_delivery = delivery,
    };
}

test {
    std.testing.refAllDecls(@This());
    // Private, provisional modules are not exported but their unit tests
    // still run (the syntax-event sink, parser driver, and tree builder stay
    // private per PROJECT_STRUCTURE until the contract stabilizes).
    _ = @import("syntax_event.zig");
    _ = @import("parser.zig");
    _ = @import("syntax.zig");
    _ = @import("validate.zig");
}
