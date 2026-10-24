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
};

pub fn Lowering(comptime config: Config) type {
    const caps = encoding.Capabilities.from(config.source_encodings);
    return struct {
        pub const Graph = topology.Graph(caps);
        pub const PartialGraph = @import("ir/partial.zig").Graph(caps);
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
