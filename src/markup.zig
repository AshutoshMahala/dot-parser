//! Standalone, byte-oriented markup fragments with optional Graphviz vocabulary.
//! Elements, attributes, references, comments, CDATA and optional validation. Not a browser
//! HTML parser, a complete XML processor, or complete Graphviz label validation.
//! Raw fragment operations support explicit delayed use without depending on DOT.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("markup/syntax.zig");
const scratch = @import("markup/scratch.zig");
const policy = @import("markup/policy.zig");
const results = @import("markup/result.zig");
const validation = @import("markup/validate.zig");
pub const location = support.location;
pub const reporting = support.reporting;
pub const wdp = support.wdp;
pub const presentation = support.console;
pub const diagnostic = @import("markup/diagnostic.zig");
/// Optional console presentation shared with DOT; no DOT dependency.
pub const console = @import("markup/console.zig");
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticSink = diagnostic.Sink;
pub const FixedDiagnosticBag = diagnostic.FixedBag;
pub const GrowableDiagnosticBag = diagnostic.GrowableBag;
pub const Cancellation = support.execution.Cancellation;
pub const Fragment = support.processor.Fragment;
pub const FragmentResult = @import("markup/fragment_result.zig").Result(@This(), false);
pub const FixedFragmentResult = @import("markup/fragment_result.zig").Result(@This(), true);
pub const Policy = policy.Policy;
pub const PolicyConfig = policy.Config;
pub const Mode = policy.Mode;
pub const RuleSeverity = policy.RuleSeverity;
pub const NameRule = policy.NameRule;
pub const ReferenceCatalog = policy.ReferenceCatalog;
pub const Acceptance = policy.Acceptance;
pub const OnError = policy.OnError;
pub const Unsupported = policy.Unsupported;
pub const ScannerBackend = policy.ScannerBackend;
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
pub const Completion = results.Completion;
pub const Counts = results.Counts;
pub const Report = results.Report;
pub const Progress = results.Progress;
pub const ValidationResult = validation.Result;
pub const ValidationScratch = validation.Scratch;
pub const AttributeKeyScratch = validation.AttributeKeyScratch;
pub const FixedValidationScratch = validation.FixedScratch;
pub const requiredValidationScratch = validation.requiredScratch;
pub const ValidationScope = @import("markup/scope.zig").Scope;
pub const HeaderScope = @import("markup/scope.zig").Header;
pub const ScopeAttribute = @import("markup/scope.zig").Attribute;
pub const SourceValidationScratch = @import("markup/validate_source.zig").Scratch;
pub const FixedSourceValidationScratch = @import("markup/validate_source.zig").FixedScratch;
pub const lexer = struct {
    pub const For = @import("markup/lexer.zig").For;
    pub const Lexer = @import("markup/lexer.zig").Lexer;
    pub const Token = @import("markup/lexer.zig").Token;
    pub const Result = @import("markup/lexer.zig").Result;
};
pub const ParseMemory = struct { document: DocumentStorage = .{}, scratch: ParseScratch = .{} };
pub const ParseResources = struct { scratch_allocator: ?std.mem.Allocator = null };
pub const FixedParseResult = struct {
    outcome: Outcome,
    completion: Completion = .incomplete,
    syntax_errors: u32 = 0,
    diagnostic_delivery: reporting.Delivery,
    diagnostic_stop: ?reporting.StopReason = null,
    counts: Counts,
    accepted_deviations: u32 = 0,
    warnings: u32 = 0,
    document: ?Document,
};
pub const ParseResult = struct {
    outcome: Outcome,
    completion: Completion = .incomplete,
    syntax_errors: u32 = 0,
    diagnostic_delivery: reporting.Delivery,
    diagnostic_stop: ?reporting.StopReason = null,
    counts: Counts,
    accepted_deviations: u32 = 0,
    warnings: u32 = 0,
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
pub const prepare = Default.prepare;
pub const parseAndValidate = Default.parseAndValidate;
pub const parseAndValidateIn = Default.parseAndValidateIn;
pub const parseBorrowed = Default.parseBorrowed;
pub const parseBorrowedIn = Default.parseBorrowedIn;
pub const measure = Default.measure;
pub const measureIn = Default.measureIn;
pub const validatePolicy = Default.validatePolicy;
pub const validate = Default.validate;
pub const validateIn = Default.validateIn;
pub const validateScope = Default.validateScope;
pub const validateScopeIn = Default.validateScopeIn;
pub const validateSource = Default.validateSource;
pub const validateSourceIn = Default.validateSourceIn;
pub const ParseOptions = Default.ParseOptions;
pub const Options = Default.Options;
pub const BoundedSession = Profile(.{ .policy = .{ .execution = .{ .metering = true } } }).Session;

test {
    std.testing.refAllDecls(@This());
    // Default-off validation should not instantiate these definitions in normal
    // builds, but their boundary tests must still be discovered by the root suite.
    _ = @import("markup/validation_rules.zig");
}
