//! Standalone, byte-oriented markup fragments, structural slices 1–2.
//! Text, elements and quoted attributes. This is not a browser
//! HTML parser, a complete XML processor, or Graphviz label validation.
//! No dependency on DOT grammar, retained documents, or processor composition.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("markup/syntax.zig");
const scratch = @import("markup/scratch.zig");
const policy = @import("markup/policy.zig");
const results = @import("markup/result.zig");
const validation = @import("markup/validate.zig");
pub const location = support.location;
pub const reporting = support.reporting;
pub const diagnostic = @import("markup/diagnostic.zig");
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticSink = diagnostic.Sink;
pub const FixedDiagnosticBag = diagnostic.FixedBag;
pub const GrowableDiagnosticBag = diagnostic.GrowableBag;
pub const Cancellation = support.execution.Cancellation;
pub const Policy = policy.Policy;
pub const PolicyConfig = policy.Config;
pub const RuleSeverity = policy.RuleSeverity;
pub const presets = policy.presets;
pub const PolicyValidation = policy.Check;
pub const Document = syntax.Document;
pub const Node = syntax.Node;
pub const NodeId = syntax.NodeId;
pub const NodeView = syntax.NodeView;
pub const NodeKind = syntax.Kind;
pub const Attribute = syntax.Attribute;
pub const AttributeView = syntax.AttributeView;
pub const DocumentStorage = syntax.Storage;
pub const FixedDocumentStorage = syntax.Fixed;
pub const ParseScratch = scratch.Storage;
pub const FixedParseScratch = scratch.Fixed;
pub const Outcome = results.Outcome;
pub const Counts = results.Counts;
pub const Report = results.Report;
pub const Progress = results.Progress;
pub const ValidationResult = validation.Result;
pub const ValidationScratch = validation.Scratch;
pub const AttributeKeyScratch = validation.AttributeKeyScratch;
pub const FixedValidationScratch = validation.FixedScratch;
pub const requiredValidationScratch = validation.requiredScratch;
pub const lexer = struct {
    pub const Lexer = @import("markup/lexer.zig").Lexer;
    pub const Token = @import("markup/lexer.zig").Token;
    pub const Result = @import("markup/lexer.zig").Result;
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
    _attributes: std.ArrayList(Attribute),
    /// Reserved output capacity in bytes, including any untrimmed growth slack.
    /// Excludes source, scratch, diagnostics and allocator-internal overhead/RSS.
    pub fn retainedBytes(self: *const @This()) usize {
        return self._nodes.capacity * @sizeOf(Node) + self._attributes.capacity * @sizeOf(Attribute);
    }
    /// Frees retained records, never the source or caller diagnostic destination.
    /// Owning results must not be independently disposed through copied values.
    pub fn deinit(self: *@This()) void {
        self._nodes.deinit(self._allocator);
        self._nodes = .empty;
        self._attributes.deinit(self._allocator);
        self._attributes = .empty;
        self.document = null;
    }
};
pub fn Profile(comptime config: PolicyConfig) type {
    return @import("markup/profile.zig").Profile(@This(), config);
}
const Default = Profile(.{});
pub const parseBorrowed = Default.parseBorrowed;
pub const parseBorrowedIn = Default.parseBorrowedIn;
pub const measure = Default.measure;
pub const measureIn = Default.measureIn;
pub const validatePolicy = Default.validatePolicy;
pub const validate = Default.validate;
pub const validateIn = Default.validateIn;
pub const ParseOptions = Default.ParseOptions;
pub const Options = Default.Options;
pub const BoundedSession = Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Session;

test {
    std.testing.refAllDecls(@This());
}
