//! Standalone, byte-oriented markup fragments, structural slice 1.
//! Text and arbitrary matching/self-closing elements only. This is not a browser
//! HTML parser, a complete XML processor, or Graphviz label validation.
//! No dependency on DOT grammar, retained documents, or processor composition.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("syntax.zig");
const scratch = @import("scratch.zig");
const policy = @import("policy.zig");
const results = @import("result.zig");
pub const location = support.location;
pub const reporting = support.reporting;
pub const diagnostic = @import("diagnostic.zig");
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticSink = diagnostic.Sink;
pub const FixedDiagnosticBag = diagnostic.FixedBag;
pub const GrowableDiagnosticBag = diagnostic.GrowableBag;
pub const Cancellation = support.execution.Cancellation;
pub const Policy = policy.Policy;
pub const PolicyConfig = policy.Config;
pub const presets = policy.presets;
pub const PolicyValidation = policy.Check;
pub const Document = syntax.Document;
pub const Node = syntax.Node;
pub const NodeId = syntax.NodeId;
pub const NodeView = syntax.NodeView;
pub const NodeKind = syntax.Kind;
pub const DocumentStorage = syntax.Storage;
pub const FixedDocumentStorage = syntax.Fixed;
pub const ParseScratch = scratch.Storage;
pub const FixedParseScratch = scratch.Fixed;
pub const Outcome = results.Outcome;
pub const Counts = results.Counts;
pub const Report = results.Report;
pub const Progress = results.Progress;
pub const lexer = struct {
    pub const Lexer = @import("lexer.zig").Lexer;
    pub const Token = @import("lexer.zig").Token;
    pub const Result = @import("lexer.zig").Result;
};
pub const ParseMemory = struct { document: DocumentStorage = .{}, scratch: ParseScratch = .{} };
pub const ParseResources = struct { scratch_allocator: ?std.mem.Allocator = null };
pub const FixedParseResult = struct {
    outcome: Outcome,
    diagnostic_delivery: reporting.Delivery,
    counts: Counts,
    document: ?Document,
};
pub const ParseResult = struct {
    outcome: Outcome,
    diagnostic_delivery: reporting.Delivery,
    counts: Counts,
    document: ?Document,
    _allocator: std.mem.Allocator,
    _nodes: std.ArrayList(Node),
    /// Frees retained records, never the source or caller diagnostic destination.
    /// Owning results must not be independently disposed through copied values.
    pub fn deinit(self: *@This()) void {
        self._nodes.deinit(self._allocator);
        self._nodes = .empty;
        self.document = null;
    }
};
pub fn Profile(comptime config: PolicyConfig) type {
    return @import("profile.zig").Profile(@This(), config);
}
const Default = Profile(.{});
pub const parseBorrowed = Default.parseBorrowed;
pub const parseBorrowedIn = Default.parseBorrowedIn;
pub const measure = Default.measure;
pub const measureIn = Default.measureIn;
pub const validatePolicy = Default.validatePolicy;
pub const ParseOptions = Default.ParseOptions;
pub const Options = Default.Options;
pub const BoundedSession = Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Session;

test {
    std.testing.refAllDecls(@This());
}
