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
const fixed_storage = @import("ir/fixed_storage.zig");
pub const GraphCapacities = fixed_storage.GraphCapacities;
pub const LoweringScratchCapacities = fixed_storage.LoweringScratchCapacities;
const query_storage = @import("ir/query_storage.zig");
pub const EdgeScratchCapacities = query_storage.EdgeScratchCapacities;
pub const AttributeScratchCapacities = query_storage.AttributeScratchCapacities;
pub const StorageShortfall = fixed_storage.StorageShortfall;
pub const Resource = fixed_storage.Resource;
pub const MaterializationProgress = @import("ir/materialization_session.zig").Progress;
pub const MaterializationOutcome = @import("ir/materialization_session.zig").Outcome;
pub const LoweringProgress = @import("ir/lowering_session.zig").Progress;
pub const LoweringOutcome = @import("ir/lowering_session.zig").Outcome;
pub const EdgeStreamingOutcome = @import("ir/materialization_session.zig").Outcome;
pub const QueryOutcome = @import("ir/query_session.zig").OutcomeFor(false);
pub const PartialQueryOutcome = @import("ir/query_session.zig").OutcomeFor(true);
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
pub const PortId = topology.PortId;
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
        const Fixed = @import("ir/fixed_lowering.zig").API(config);
        pub const GraphStorage = fixed_storage.GraphStorage;
        pub const LoweringScratch = fixed_storage.LoweringScratch;
        pub const LoweringMemory = fixed_storage.LoweringMemory;
        pub const FixedGraphStorage = fixed_storage.FixedGraphStorage;
        pub const FixedLoweringScratch = fixed_storage.FixedLoweringScratch;
        pub const loweringLayout = fixed_storage.loweringLayout;
        pub const EdgeScratch = query_storage.EdgeScratch;
        pub const AttributeScratch = query_storage.AttributeScratch;
        pub const FixedEdgeScratch = query_storage.FixedEdgeScratch;
        pub const FixedAttributeScratch = query_storage.FixedAttributeScratch;
        pub const edgeScratchLayout = query_storage.edgeScratchLayout;
        pub const attributeScratchLayout = query_storage.attributeScratchLayout;
        pub const edgeScratchBounds = query_storage.edgeScratchBounds;
        pub const attributeScratchBounds = query_storage.attributeScratchBounds;
        pub const FixedLoweringResult = Fixed.Result(false);
        pub const FixedPartialLoweringResult = Fixed.Result(true);
        pub const FixedLoweringSession = Fixed.FixedLoweringSession;
        pub const FixedPartialLoweringSession = Fixed.FixedPartialLoweringSession;
        /// Explicit arithmetic-only sizing. Lowering never reserves these bounds
        /// automatically; pass the same options to sizing and construction.
        pub fn loweringBounds(counts: syntax.Capacities, options: anytype) Error!fixed_storage.Bounds {
            return Fixed.bounds(false, counts, options);
        }
        /// Like loweringBounds, including retained partial-source coverage.
        pub fn partialLoweringBounds(counts: syntax.Capacities, options: anytype) Error!fixed_storage.Bounds {
            return Fixed.bounds(true, counts, options);
        }
        /// Allocation-free construction. Success borrows source and retained
        /// storage, never Document pools or scratch. Failure publishes no graph.
        pub fn lowerCompleteIn(document: *const syntax.Document, memory: LoweringMemory, options: anytype) Fixed.DirectResult(false) {
            return Fixed.direct(false, document, memory, options);
        }
        /// Lower retained partial-source facts; a storage/work stop is still a
        /// failure, not a partially constructed graph.
        pub fn lowerPartialIn(document: *const syntax.Document, memory: LoweringMemory, options: anytype) Fixed.DirectResult(true) {
            return Fixed.direct(true, document, memory, options);
        }
        /// Same bounded session contract as loweringSession, using caller pools.
        pub fn loweringSessionIn(document: *const syntax.Document, memory: LoweringMemory, options: anytype) (Error || execution.Error)!FixedLoweringSession {
            return Fixed.start(false, document, memory, options);
        }
        pub fn partialLoweringSessionIn(document: *const syntax.Document, memory: LoweringMemory, options: anytype) (Error || execution.Error)!FixedPartialLoweringSession {
            return Fixed.start(true, document, memory, options);
        }
        pub const Graph = topology.Graph(caps);
        pub const PartialGraph = @import("ir/partial.zig").Graph(caps);
        pub const LoweringSession = execution.Bound(caps, false, config);
        pub const PartialLoweringSession = execution.Bound(caps, true, config);
        pub const EdgeSession = @import("ir/edge_session.zig").Bound(Graph, caps, config);
        pub const PartialEdgeSession = @import("ir/edge_session.zig").Bound(PartialGraph, caps, config);
        pub const FixedEdgeSession = @import("ir/edge_session.zig").FixedBound(Graph, caps, config);
        pub const FixedPartialEdgeSession = @import("ir/edge_session.zig").FixedBound(PartialGraph, caps, config);
        pub const HasEdgeSession = @import("ir/query_session.zig").Bound(Graph, .has_edge, config);
        pub const PartialHasEdgeSession = @import("ir/query_session.zig").Bound(PartialGraph, .has_edge, config);
        pub const ContainsSession = @import("ir/query_session.zig").Bound(Graph, .contains, config);
        pub const PartialContainsSession = @import("ir/query_session.zig").Bound(PartialGraph, .contains, config);
        pub const AttributeSession = @import("ir/attribute_session.zig").Bound(Graph, caps, false, config);
        pub const PartialAttributeSession = @import("ir/attribute_session.zig").Bound(PartialGraph, caps, false, config);
        pub const AttributesSession = @import("ir/attribute_session.zig").Bound(Graph, caps, true, config);
        pub const PartialAttributesSession = @import("ir/attribute_session.zig").Bound(PartialGraph, caps, true, config);
        pub const FixedAttributesSession = @import("ir/attribute_session.zig").FixedBound(Graph, caps, config);
        pub const FixedPartialAttributesSession = @import("ir/attribute_session.zig").FixedBound(PartialGraph, caps, config);
        fn FixedAttributesOperation(comptime View: type) type {
            if (FixedAttributesSession.accepts(View)) return FixedAttributesSession;
            if (FixedPartialAttributesSession.accepts(View)) return FixedPartialAttributesSession;
            @compileError("attribute sessions require a compatible IR component view");
        }
        /// Borrows explicit winner scratch. No graph allocator fallback.
        pub fn attributesSessionIn(view: anytype, memory: AttributeScratch, options: anytype) !FixedAttributesOperation(@TypeOf(view)) {
            return FixedAttributesOperation(@TypeOf(view)).initIn(view, memory, options);
        }
        /// Fixed scratch, same policy and delivery contract as edgeSession.
        pub fn edgeSessionIn(graph: anytype, memory: EdgeScratch, options: anytype) !(if (@TypeOf(graph.*) == PartialGraph) FixedPartialEdgeSession else FixedEdgeSession) {
            const G = @TypeOf(graph.*);
            if (G != Graph and G != PartialGraph) @compileError("edgeSessionIn requires this profile's complete or partial IR type");
            return (if (G == PartialGraph) FixedPartialEdgeSession else FixedEdgeSession).initIn(graph, memory, options);
        }
        fn AttributeOperation(comptime View: type, comptime all: bool) type {
            if (AttributeSession.accepts(View)) return if (all) AttributesSession else AttributeSession;
            if (PartialAttributeSession.accepts(View)) return if (all) PartialAttributesSession else PartialAttributeSession;
            @compileError("attribute sessions require a compatible IR component view");
        }
        /// Borrows the view's owner and logical UTF-8 key until deinit. No
        /// traversal, hashing or allocation is hidden in construction.
        pub fn attributeSession(view: anytype, key: []const u8, options: anytype) !AttributeOperation(@TypeOf(view), false) {
            return AttributeOperation(@TypeOf(view), false).init(view, key, options);
        }
        /// One final effective attribute per delivery, using folded maps when
        /// supplied a materialized edge. No implicit edge expansion.
        pub fn attributesSession(view: anytype, options: anytype) !AttributeOperation(@TypeOf(view), true) {
            return AttributeOperation(@TypeOf(view), true).init(view, {}, options);
        }
        /// Bounded symbolic edge existence; never expands endpoint products.
        pub fn hasEdgeSession(graph: anytype, from: NodeId, to: NodeId, options: anytype) !(if (@TypeOf(graph.*) == PartialGraph) PartialHasEdgeSession else HasEdgeSession) {
            const G = @TypeOf(graph.*);
            if (G != Graph and G != PartialGraph) @compileError("hasEdgeSession requires this profile's complete or partial IR type");
            return (if (G == PartialGraph) PartialHasEdgeSession else HasEdgeSession).init(graph, from, to, options);
        }
        /// Bounded membership lookup, including reopened named subgraphs.
        pub fn containsSession(graph: anytype, members: Membership, node: NodeId, options: anytype) !(if (@TypeOf(graph.*) == PartialGraph) PartialContainsSession else ContainsSession) {
            const G = @TypeOf(graph.*);
            if (G != Graph and G != PartialGraph) @compileError("containsSession requires this profile's complete or partial IR type");
            return (if (G == PartialGraph) PartialContainsSession else ContainsSession).init(graph, members, node, options);
        }
        /// Explicitly use this IR profile's execution policy, not settings from
        /// a past parser/lowering operation. Limits default to the input IR.
        pub fn edgeSession(graph: anytype, options: anytype) !(if (@TypeOf(graph.*) == PartialGraph) PartialEdgeSession else EdgeSession) {
            const G = @TypeOf(graph.*);
            if (G != Graph and G != PartialGraph) @compileError("edgeSession requires this profile's complete or partial IR type");
            return (if (G == PartialGraph) PartialEdgeSession else EdgeSession).init(graph, options);
        }
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
            const effective = if (config.runtime_policy) try execution.effectiveFor(config, options) else baseline;
            return sessionInitResolved(partial, allocator, document, options, effective);
        }
        fn sessionInitResolved(comptime partial: bool, allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype, effective: execution.Effective) Error!(if (partial) PartialLoweringSession else LoweringSession) {
            comptime {
                if (!@hasField(@TypeOf(options), "interpretation")) @compileError("lowering session requires .interpretation from the accepting DOT profile");
                for (@typeInfo(@TypeOf(options)).@"struct".field_names) |field| {
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
                if (@hasField(@TypeOf(options), field)) {
                    if (comptime std.mem.eql(u8, field, "cancellation")) {
                        if (@FieldType(@TypeOf(options), field) != void) {
                            if (@FieldType(S.Options, field) == void) @compileError("IR cancellation is disabled by this profile");
                            normalized.cancellation = execution.directCancellation(options);
                        }
                    } else @field(normalized, field) = execution.option(@FieldType(S.Options, field), @field(options, field));
                }
            }
            normalized.limits = normalized.limits orelse config.limits;
            return execution.initLoweringResolved(S, allocator, document, normalized, effective);
        }
        /// Explicitly lower retained facts, including a stopped parser's safely
        /// retained Document. This is a new bounded operation, not parse resume.
        pub fn lowerPartial(allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) (if (config.runtime_policy) Error || execution.ValidationError else Error)!PartialGraph {
            comptime checkDirectOptions(@TypeOf(options));
            const effective = if (config.runtime_policy) try execution.effectiveFor(config, options) else baseline;
            _ = execution.cancellationFor(config, options, effective);
            if (effective.metering or effective.cancellation) return runBounded(true, allocator, document, options, effective);
            const limits = execution.directLimits(options, config.limits);
            const interpretation = options.interpretation;
            const resolved: @import("ir/lower.zig").InterpretationFor(true) = .{
                .kind = interpretation.effectiveKind(document.kind),
                .directed = interpretation.effectiveOperator(document.kind, .directed),
                .undirected = interpretation.effectiveOperator(document.kind, .undirected),
            };
            var memory: resources.Memory = .{ .backing = allocator, .limit = limits.max_bytes };
            return @import("ir/lower.zig").runWith(caps, true, memory.allocator(), document, resolved, limits, null) catch |err| return memory.failure(err);
        }
        /// Lower a complete, accepted parser-produced Document. Interpretation
        /// must come from the same profile/options used to accept that Document.
        /// Borrow only source bytes; Document pools may be released afterward.
        pub fn lowerComplete(allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype) (if (config.runtime_policy) Error || execution.ValidationError else Error)!Graph {
            comptime checkDirectOptions(@TypeOf(options));
            const effective = if (config.runtime_policy) try execution.effectiveFor(config, options) else baseline;
            _ = execution.cancellationFor(config, options, effective);
            if (effective.metering or effective.cancellation) return runBounded(false, allocator, document, options, effective);
            const limits = execution.directLimits(options, config.limits);
            if (!document.scopeComplete()) return error.IncompleteDocument;
            const interpretation = options.interpretation;
            const resolved: @import("ir/lower.zig").Interpretation = .{
                .kind = interpretation.effectiveKind(document.kind) orelse return error.UnsupportedSemantics,
                .directed = interpretation.effectiveOperator(document.kind, .directed),
                .undirected = interpretation.effectiveOperator(document.kind, .undirected),
            };
            var memory: resources.Memory = .{ .backing = allocator, .limit = limits.max_bytes };
            // Keep the complete fast driver's existing call boundary. Inlining
            // its encoding dispatch here changes optimizer decisions in callers.
            return @import("ir/lower.zig").run(caps, memory.allocator(), document, resolved, limits, null) catch |err| return memory.failure(err);
        }
        fn checkDirectOptions(comptime OptionsType: type) void {
            if (!@hasField(OptionsType, "interpretation")) @compileError("IR lowering requires .interpretation from the accepting DOT profile");
            for (@typeInfo(OptionsType).@"struct".field_names) |field| {
                if (!std.mem.eql(u8, field, "interpretation") and !std.mem.eql(u8, field, "limits") and !std.mem.eql(u8, field, "cancellation") and !(config.runtime_policy and std.mem.eql(u8, field, "policy"))) @compileError("unknown IR lowering option: " ++ field);
            }
        }
        fn runBounded(comptime partial: bool, allocator: std.mem.Allocator, document: *const syntax.Document, options: anytype, effective: execution.Effective) Error!@import("ir/lower.zig").Output(caps, partial) {
            var operation = try sessionInitResolved(partial, allocator, document, options, effective);
            defer operation.deinit();
            return execution.finish(&operation);
        }
    };
}
