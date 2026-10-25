//! Optional semantic lowering. No work or storage is added to ordinary parsing.
//! See docs/IR.md for coverage, ownership, limits and unsupported semantics.
const std = @import("std");
const encoding = @import("parser_support").encoding;
const syntax = @import("dot/syntax.zig");
const resources = @import("ir/resources.zig");
const topology = @import("ir/topology.zig");
pub const Error = resources.Error;
pub const Limits = resources.Limits;
pub const Options = resources.Options;
pub const Cancellation = resources.Cancellation;
pub const MaterializationProgress = @import("ir/materialization_session.zig").Progress;
pub const MaterializationOutcome = @import("ir/materialization_session.zig").Outcome;
pub const LoweringProgress = @import("ir/lowering_session.zig").Progress;
pub const LoweringOutcome = @import("ir/lowering_session.zig").Outcome;
pub const Policy = @import("ir/execution_policy.zig").Policy;
pub const NodeId = topology.NodeId;
pub const ScopeId = topology.ScopeId;
pub const OccurrenceId = topology.OccurrenceId;
pub const ConnectionId = topology.ConnectionId;
pub const Membership = topology.Membership;
pub const Node = topology.Node;
pub const Scope = topology.Scope;
pub const Occurrence = topology.Occurrence;
pub const Mention = topology.Mention;
pub const Connection = topology.Connection;
pub const Declaration = topology.Declaration;
pub const Edge = topology.Edge;
pub const MaterializedTopology = topology.MaterializedTopology;
pub const AttributeValue = @import("ir/attributes.zig").Value;
pub const ResolvedAttribute = @import("ir/attributes.zig").Resolved;
pub const AttributeOrigin = @import("ir/attributes.zig").Origin;
pub const PortAttributeKey = @import("ir/ports.zig").Key;
pub const PortReference = @import("ir/attributes.zig").PortReference;
pub const Compass = @import("ir/port_views.zig").Compass;
pub const ValueKind = @import("ir/values.zig").Kind;
pub const OperandKind = @import("ir/values.zig").OperandKind;
pub const EncodedFragment = @import("ir/values.zig").EncodedFragment;
pub const parse = @import("ir/parse.zig").parse;
pub const ParseOptions = @import("ir/parse.zig").Options;
pub const ParseResult = @import("ir/parse.zig").Result;
pub const parsePartial = @import("ir/parse.zig").parsePartial;
pub const PartialResult = @import("ir/parse.zig").PartialResult;
pub const Knowledge = @import("ir/coverage.zig").Knowledge;
pub const Uncertainty = @import("ir/coverage.zig").Uncertainty;
pub const CoverageGap = @import("ir/coverage.zig").Gap;
pub const Config = struct {
    source_encodings: ?[]const encoding.Encoding = null,
    limits: Limits = .{},
    policy: Policy = .{},
    runtime_policy: bool = false,
};

pub fn Lowering(comptime config: Config) type {
    const caps = encoding.Capabilities.from(config.source_encodings);
    const execution = @import("ir/execution_policy.zig");
    const baseline = comptime execution.resolve(.{}, config.policy);
    comptime {
        execution.validate(baseline) catch @compileError("IR cancellation_interval must be positive");
    }
    return struct {
        pub const Graph = topology.Graph(caps);
        pub const PartialGraph = @import("ir/partial.zig").Graph(caps);
        pub const LoweringSession = execution.Bound(caps, false, config);
        pub const PartialLoweringSession = execution.Bound(caps, true, config);
        /// Resolve/check an override without starting work. The fixed-policy
        /// profile verifies its baseline during compilation.
        pub fn validatePolicy(policy: Policy) execution.Error!void {
            if (!config.runtime_policy) @compileError("runtime policy is disabled; the baseline is verified at compile time");
            try execution.validate(execution.resolve(baseline, policy));
        }
        /// No scan or allocation at initialization. Borrows Document and source
        /// until successful transfer; output then borrows only the source.
        pub fn loweringSession(allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) !LoweringSession {
            return sessionInit(false, allocator, document, options);
        }
        pub fn partialLoweringSession(allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) !PartialLoweringSession {
            return sessionInit(true, allocator, document, options);
        }
        fn sessionInit(comptime partial: bool, allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) !(if (partial) PartialLoweringSession else LoweringSession) {
            comptime {
                if (!@hasField(@TypeOf(options), "interpretation")) @compileError("lowering session requires .interpretation from the accepting DOT profile");
                for (std.meta.fieldNames(@TypeOf(options))) |field| {
                    if (!std.mem.eql(u8, field, "interpretation") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !(config.runtime_policy and std.mem.eql(u8, field, "policy"))) @compileError("unknown IR lowering session option: " ++ field);
                }
            }
            const S = if (partial) PartialLoweringSession else LoweringSession;
            if (!partial and !document.scopeComplete()) return error.IncompleteDocument;
            const interpretation = options.interpretation;
            const kind = interpretation.effectiveKind(document.kind);
            const resolved: @import("ir/lower.zig").InterpretationFor(partial) = .{
                .kind = if (partial) kind else kind orelse return error.UnsupportedSemantics,
                .directed = interpretation.effectiveOperator(document.kind, .directed),
                .undirected = interpretation.effectiveOperator(document.kind, .undirected),
            };
            var normalized: S.Options = .{ .interpretation = resolved };
            inline for (.{ "limits", "cancellation", "policy" }) |field| {
                if (@hasField(@TypeOf(options), field)) @field(normalized, field) = execution.option(@FieldType(S.Options, field), @field(options, field));
            }
            return S.init(allocator, document, normalized);
        }
        /// Explicitly lower retained facts, including a stopped parser's safely
        /// retained Document. This is a new bounded operation, not parse resume.
        pub fn lowerPartial(allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) Error!PartialGraph {
            comptime {
                if (!@hasField(@TypeOf(options), "interpretation")) @compileError("lowerPartial requires .interpretation from the accepting DOT profile");
                for (std.meta.fieldNames(@TypeOf(options))) |field| {
                    if (!std.mem.eql(u8, field, "interpretation") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation")) @compileError("unknown IR lowering option: " ++ field);
                }
            }
            const limits: Limits = if (@hasField(@TypeOf(options), "limits")) options.limits else config.limits;
            const cancellation: ?Cancellation = if (@hasField(@TypeOf(options), "cancellation")) options.cancellation else null;
            const interpretation = options.interpretation;
            const resolved: @import("ir/lower.zig").InterpretationFor(true) = .{
                .kind = interpretation.effectiveKind(document.kind),
                .directed = interpretation.effectiveOperator(document.kind, .directed),
                .undirected = interpretation.effectiveOperator(document.kind, .undirected),
            };
            var memory: resources.Memory = .{ .backing = allocator, .limit = limits.max_bytes };
            return @import("ir/lower.zig").runWith(caps, true, memory.allocator(), document, resolved, limits, cancellation) catch |err| return memory.failure(err);
        }
        /// Lower a complete, accepted parser-produced Document. Interpretation
        /// must come from the same profile/options used to accept that Document.
        /// Borrow only source bytes; Document pools may be released afterward.
        pub fn lowerComplete(allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) Error!Graph {
            comptime {
                if (!@hasField(@TypeOf(options), "interpretation")) @compileError("lowerComplete requires .interpretation from the accepting DOT profile");
                for (std.meta.fieldNames(@TypeOf(options))) |field| {
                    if (!std.mem.eql(u8, field, "interpretation") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation")) @compileError("unknown IR lowering option: " ++ field);
                }
            }
            const limits: Limits = if (@hasField(@TypeOf(options), "limits")) options.limits else config.limits;
            const cancellation: ?Cancellation = if (@hasField(@TypeOf(options), "cancellation")) options.cancellation else null;
            if (!document.scopeComplete()) return error.IncompleteDocument;
            const interpretation = options.interpretation;
            const resolved: @import("ir/lower.zig").Interpretation = .{
                .kind = interpretation.effectiveKind(document.kind) orelse return error.UnsupportedSemantics,
                .directed = interpretation.effectiveOperator(document.kind, .directed),
                .undirected = interpretation.effectiveOperator(document.kind, .undirected),
            };
            var memory: resources.Memory = .{ .backing = allocator, .limit = limits.max_bytes };
            return @import("ir/lower.zig").run(caps, memory.allocator(), document, resolved, limits, cancellation) catch |err| return memory.failure(err);
        }
    };
}
