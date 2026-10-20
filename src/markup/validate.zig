//! Independent policy checks over retained syntax or checked local scopes.
//! Never rewrites input; document and local traversal share the same kernels.
//! Scratch is reused per element. Heap sorting has deterministic O(A log A)
//! comparisons, with raw or ASCII-case-folded names; no hash-collision worst case.
//! This pass is run-to-completion, not a metered parsing session.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
const definitions = @import("validation_rules.zig");
const lexical = @import("lexer.zig");
const Span = support.location.Span;
const scopes = @import("scope.zig");
const graphviz = @import("graphviz.zig");
const safety_checks = switch (@import("builtin").mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

/// During sorting these are records. After sorting, the two columns have
/// independent indexing: index stays name-sorted; first is indexed by source
/// position within the owner's list. Scattering only first cannot disturb index.
pub const AttributeKeyScratch = struct { index: u32, first: u32 };
pub const Scratch = struct {
    /// Must not alias the document, source or diagnostics. Contents unspecified
    /// after use. Only the largest element with >=2 attributes needs storage.
    attribute_keys: []AttributeKeyScratch = &.{},
};
pub fn FixedScratch(comptime capacity: u32) type {
    return struct {
        keys: [capacity]AttributeKeyScratch = undefined,
        pub const byte_size = @sizeOf(@This());
        pub fn storage(self: *@This()) Scratch {
            return .{ .attribute_keys = &self.keys };
        }
    };
}
pub const CheckStatus = enum(u2) { not_run, incomplete, complete };
pub const Result = struct {
    completion: union(enum) {
        complete,
        /// This operation's first error; the destination remains usable by a parent.
        error_stopped,
        /// Earliest loss of local coverage, in original-source bytes. Later
        /// regions may have been checked; this is not a resume cursor.
        incomplete: u32,
        /// Invalid caller-supplied scope metadata, not invalid document content.
        invalid_scope,
        unsupported_encoding: support.encoding.Actual,
        source_limit: u32,
        /// Required entries; a lower bound if a source walk stopped at capacity.
        storage_exhausted: u32,
        out_of_memory,
        cancelled,
        diagnostic_stopped: support.reporting.StopReason,
    } = .complete,
    validity: enum { valid, invalid, unknown } = .unknown,
    checks: packed struct {
        duplicate_attribute: CheckStatus = .not_run,
        invalid_encoding: CheckStatus = .not_run,
        names: CheckStatus = .not_run,
        references: CheckStatus = .not_run,
        graphviz_elements: CheckStatus = .not_run,
        graphviz_attributes: CheckStatus = .not_run,
        graphviz_content: CheckStatus = .not_run,
        graphviz_values: CheckStatus = .not_run,
    } = .{},
    /// Aggregate findings from independent checks, which may overlap source
    /// spans. Offsets/capacities remain u32; totals use u64, as in DOT validation.
    errors: u64 = 0,
    warnings: u64 = 0,
    diagnostic_delivery: support.reporting.Delivery = .complete,
};

/// Shared routing predicate. Structural specializations never activate a
/// vocabulary pass, regardless of the stored (possibly runtime) severities.
pub inline fn vocabularyActive(comptime mode: policy.Mode, settings: policy.ValidationSettings) bool {
    return mode == .graphviz and (settings.graphviz.unknown_element != .off or settings.graphviz.invalid_attribute != .off or settings.graphviz.invalid_content != .off or settings.graphviz.invalid_value != .off or settings.graphviz.unknown_reference != .off);
}

/// Explicit reference settings take precedence; otherwise Graphviz selects its
/// HTML4 catalog. Structural profiles retain their independent opt-in check.
pub inline fn referenceSettings(comptime mode: policy.Mode, settings: policy.ValidationSettings) policy.ReferenceSettings {
    return if (settings.references.severity != .off or mode == .structural) settings.references else .{ .catalog = .graphviz, .severity = settings.graphviz.unknown_reference };
}

/// Internal traversal helper. Missing coverage is not a finding or a stop;
/// retain its earliest source offset while independent checks continue.
pub fn recordGap(result: *Result, at: u32) void {
    const first = if (result.completion == .incomplete) @min(result.completion.incomplete, at) else at;
    result.completion = .{ .incomplete = first };
}

/// Upper bound for an enabled duplicate check, independent of the policy.
/// O(number of attributes), no allocation or source-byte reads.
/// Requires Document's source-order/owner invariants, like validation and views.
pub fn requiredScratch(document: *const syntax.Document) u32 {
    return requirement(document).count;
}

const Requirement = struct {
    count: u32 = 0,
    /// Name of the first element with the largest attribute list. Context for
    /// resource diagnostics, not a claim that this element is invalid syntax.
    span: support.location.Span = .{ .start = 0, .len = 0 },
};

fn requirement(document: *const syntax.Document) Requirement {
    std.debug.assert(document.source.len <= support.location.max_source_len);
    std.debug.assert(document.records.len <= std.math.maxInt(u32));
    std.debug.assert(document.attributes.len <= std.math.maxInt(u32));
    var maximum: u32 = 0;
    var count: u32 = 0;
    var owner: ?syntax.NodeId = null;
    var largest_owner: syntax.NodeId = undefined;
    for (document.attributes, 0..) |attribute, index| {
        // Fold safety-build checks into the sizing pass. No extra release pass
        // or per-node lookup scan; arbitrary hand-built pools are not repaired.
        if (safety_checks) std.debug.assert(syntax.attributeInvariant(document, @intCast(index)));
        if (owner != attribute.owner) {
            owner = attribute.owner;
            count = 0;
        }
        count += 1;
        if (count > maximum) {
            maximum = count;
            largest_owner = attribute.owner;
        }
    }
    return if (maximum < 2) .{} else .{ .count = maximum, .span = document.records[@backingInt(largest_owner)].name };
}

pub fn Validator(comptime fixed: ?policy.ValidationSettings, comptime cancellable: bool, comptime mode: policy.Mode) type {
    return ValidatorForEncoding(.utf8, fixed, cancellable, mode);
}

pub fn ValidatorForEncoding(comptime actual: support.encoding.Actual, comptime fixed: ?policy.ValidationSettings, comptime cancellable: bool, comptime mode: policy.Mode) type {
    const enc = support.encoding.Reader(actual);
    return struct {
        fn canRead(document: *const syntax.Document) bool {
            return support.encoding.readerAccepts(actual, document.source_info.encoding);
        }
        pub const Settings = if (fixed == null) policy.ValidationSettings else void;
        pub const Hook = if (cancellable) ?support.execution.Cancellation else void;
        const has_encoding = if (fixed) |s| s.invalid_encoding != .off else true;
        const distinguish_ascii = actual == .utf8 and (if (fixed) |s| s.invalid_encoding != .off or s.names.severity != .off else true);
        const Offset = if (has_encoding) u32 else void;
        /// One countdown shared by the traversal and all content scans. Charge
        /// bytes examined (including revisits by another check) and record steps,
        /// not absolute source progress. A scalar can cross the threshold by 3.
        /// Fixed-disabled profiles have neither state nor callback branches.
        pub const Poller = @import("validation_poller.zig").For(cancellable, Result);
        // Expose fixed selections during semantic analysis, not just as an
        // optimizer inlining opportunity. Disabled passes must not instantiate.
        inline fn rules(settings: Settings) policy.ValidationSettings {
            return if (fixed) |value| value else settings;
        }
        fn initial(settings: Settings) Result {
            const s = rules(settings);
            return .{ .checks = .{
                .duplicate_attribute = if (s.duplicate_attribute == .off) .not_run else .incomplete,
                .invalid_encoding = if (!has_encoding or s.invalid_encoding == .off) .not_run else .incomplete,
                .names = if (s.names.severity == .off) .not_run else .incomplete,
                .references = if (referenceSettings(mode, s).severity == .off) .not_run else .incomplete,
                .graphviz_elements = if (mode == .structural or s.graphviz.unknown_element == .off) .not_run else .incomplete,
                .graphviz_attributes = if (mode == .structural or s.graphviz.invalid_attribute == .off) .not_run else .incomplete,
                .graphviz_content = if (mode == .structural or s.graphviz.invalid_content == .off) .not_run else .incomplete,
                .graphviz_values = if (mode == .structural or s.graphviz.invalid_value == .off) .not_run else .incomplete,
            } };
        }
        fn enabled(settings: Settings) bool {
            const s = rules(settings);
            return s.duplicate_attribute != .off or (has_encoding and s.invalid_encoding != .off) or s.names.severity != .off or s.references.severity != .off or vocabularyActive(mode, s);
        }
        fn requested(hook: Hook) bool {
            return if (cancellable) (if (hook) |h| h.requested() else false) else false;
        }
        fn unavailable(completion: @FieldType(Result, "completion"), sink: diagnostic.Sink, capacity: u32, span: support.location.Span, settings: Settings) Result {
            const finding: diagnostic.Diagnostic = switch (completion) {
                .storage_exhausted => .{ .code = .capacity_exhausted, .span = span, .details = .{ .capacity = .{ .resource = .attribute_keys, .limit = capacity } } },
                .out_of_memory => .{ .code = .out_of_memory, .span = span },
                else => unreachable,
            };
            var result = initial(settings);
            result.completion = completion;
            _ = sink.emit(finding) catch {
                result.diagnostic_delivery = .failed;
            };
            return result;
        }
        pub fn run(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (!canRead(document)) return .{ .completion = .{ .unsupported_encoding = document.source_info.encoding } };
            // Keep the ASCII fallback out of the UTF-8 hot path. Inlining both
            // traversals changes register allocation in combined validation.
            if (distinguish_ascii and document.source_info.encoding == .ascii)
                return @call(.never_inline, ValidatorForEncoding(.ascii, fixed, cancellable, mode).run, .{ document, scratch, sink, settings, hook });
            if (!enabled(settings)) return retainedCoverage(document, .{ .validity = .valid });
            var result = initial(settings);
            if (cancelled(&result, hook)) return result;
            const required = if (rules(settings).duplicate_attribute != .off) requirement(document) else Requirement{};
            return runSized(document, scratch, sink, settings, hook, required);
        }

        fn scopeInitial(scope: scopes.Scope, settings: Settings) Result {
            var result = initial(settings);
            // A local scope has no parent/child relationships to certify.
            result.checks.graphviz_content = .not_run;
            if (scope != .opening_header) result.checks.duplicate_attribute = .not_run;
            if (scope != .opening_header) result.checks.graphviz_attributes = .not_run;
            if (scope != .opening_header) result.checks.graphviz_values = .not_run;
            if (scope != .opening_header and scope != .opening_name and scope != .closing_name)
                result.checks.graphviz_elements = .not_run;
            switch (scope) {
                .bytes => {
                    result.checks.names = .not_run;
                    result.checks.references = .not_run;
                },
                .opening_name, .closing_name, .attribute_name => result.checks.references = .not_run,
                else => {},
            }
            return result;
        }
        fn scopeRequested(result: Result) bool {
            inline for (comptime std.meta.fieldNames(@TypeOf(result.checks))) |field| {
                if (@field(result.checks, field) != .not_run) return true;
            }
            return false;
        }
        /// Always check caller-built metadata, even with content checks off.
        /// Invalid descriptors produce no source diagnostic or allocator calls.
        const MetadataProgress = struct {
            result: *Result,
            poller: *Poller,
            hook: Hook,
            pub fn proceed(self: @This()) bool {
                return self.poller.step(self.result, self.hook);
            }
        };
        pub fn scopeInputFailure(source: []const u8, scope: scopes.Scope, settings: Settings, hook: Hook) ?Result {
            const invalid: Result = .{ .completion = .invalid_scope };
            const range = scope.span();
            if (source.len > support.location.max_source_len or range.endOffset() > source.len) return invalid;
            var result = scopeInitial(scope, settings);
            if (cancelled(&result, hook)) return result;
            var poller: Poller = .{};
            if (!scopes.metadataValidForEncoding(actual, source, scope, MetadataProgress{ .result = &result, .poller = &poller, .hook = hook }))
                return if (result.completion == .cancelled) result else invalid;
            return null;
        }
        pub fn runScope(source: []const u8, scope: scopes.Scope, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (scopeInputFailure(source, scope, settings, hook)) |failure| return failure;
            return runScopeTrusted(source, scope, scratch, sink, settings, hook);
        }
        /// Internal scanner-produced path: no release-mode metadata audit.
        /// Local checks share the exact document-validation kernels. Source and
        /// scopes must satisfy the borrowed-range contract; no enclosing tree is
        /// needed. Encoding is clipped to this scope, including scalar lookahead.
        pub fn runScopeTrusted(source: []const u8, scope: scopes.Scope, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            var poller: Poller = .{};
            return runScopePolled(source, scope, scratch, sink, settings, hook, &poller, true);
        }
        /// Internal composition reuses one countdown across scanner and scopes.
        /// The source walk supplies its own precise lexical gap; suppress only
        /// the header-metadata fallback there, never missing vocabulary coverage.
        pub fn runScopePolled(source: []const u8, scope: scopes.Scope, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook, poller: *Poller, comptime report_header_gap: bool) Result {
            var result = scopeInitial(scope, settings);
            if (!scopeRequested(result)) return .{ .validity = .valid };
            if (!poller.check(&result, hook)) return result;
            const range = scope.span();
            if (safety_checks) std.debug.assert(scopes.metadataValidForEncoding(actual, source, scope, {}));
            const end: u32 = @intCast(range.endOffset());
            var incomplete_offset = end;
            var gaps: ContractGaps = .{};
            const bounded_source = source[0..end];
            var offset: Offset = if (has_encoding) range.start else {};
            switch (scope) {
                .opening_header => |h| {
                    const required: u32 = if (rules(settings).duplicate_attribute != .off and h.attributes.len >= 2) @intCast(h.attributes.len) else 0;
                    if (scratch.attribute_keys.len < required) {
                        var stopped = unavailable(.{ .storage_exhausted = required }, sink, @intCast(scratch.attribute_keys.len), h.name, settings);
                        stopped.checks = result.checks;
                        return stopped;
                    }
                    const keys = scratch.attribute_keys[0..required];
                    const context = .{ .source = source, .attributes = h.attributes };
                    if (required != 0) prepareKeys(&context, keys, 0);
                    const owner = elementKind(bounded_source, h.name, settings);
                    if (!checkElement(bounded_source, h.name, owner, &offset, poller, &result, sink, settings, hook)) return result;
                    if (!checkName(bounded_source, h.name, .element, &offset, poller, &result, sink, settings, hook)) return result;
                    var header: HeaderFacts = .{};
                    for (h.attributes, 0..) |a, index| {
                        if (!poller.step(&result, hook)) return result;
                        if (a.value.len == 0) incomplete_offset = @min(incomplete_offset, @as(u32, @intCast(a.name.endOffset())));
                        if (required != 0 and keys[index].first != index) {
                            if (!emitDuplicate(bounded_source, a.name, h.attributes[keys[index].first].name, &offset, poller, &result, sink, settings, hook)) return result;
                        }
                        if (!checkAttribute(bounded_source, h.name, owner, a.name, &gaps, &offset, poller, &result, sink, settings, hook)) return result;
                        if (!checkValue(bounded_source, h.name, owner, a.name, a.value, &header, &gaps, poller, &result, sink, settings, hook)) return result;
                        if (!checkName(bounded_source, a.name, .attribute, &offset, poller, &result, sink, settings, hook)) return result;
                        if (a.value.len != 0 and
                            !checkReferences(bounded_source, .{ .start = a.value.start + enc.width, .len = a.value.len - 2 * enc.width }, true, &offset, poller, &result, sink, settings, hook)) return result;
                    }
                    if (h.complete and !checkHeader(h.name, owner, header, &gaps, &result, sink, settings)) return result;
                },
                .opening_name, .closing_name, .attribute_name => |name| {
                    if (scope != .attribute_name and !checkElement(bounded_source, name, elementKind(bounded_source, name, settings), &offset, poller, &result, sink, settings, hook)) return result;
                    if (!checkName(bounded_source, name, if (scope == .attribute_name) .attribute else .element, &offset, poller, &result, sink, settings, hook)) return result;
                },
                .text, .attribute_value => |value| {
                    if (!checkReferences(bounded_source, value, scope == .attribute_value, &offset, poller, &result, sink, settings, hook)) return result;
                },
                .bytes => {},
            }
            if (!encodingThrough(bounded_source, end, &offset, poller, &result, sink, settings, hook)) return result;
            const complete = scope != .opening_header or scope.opening_header.complete;
            inline for (comptime std.meta.fieldNames(@TypeOf(result.checks))) |field| {
                const missing = if (comptime std.mem.eql(u8, field, "graphviz_attributes")) gaps.attributes else if (comptime std.mem.eql(u8, field, "graphviz_values")) gaps.values else false;
                if (@field(result.checks, field) != .not_run)
                    @field(result.checks, field) = if (!complete or missing) .incomplete else .complete;
            }
            if (report_header_gap and !complete) recordGap(&result, incomplete_offset);
            if (result.errors == 0 and complete and (mode == .structural or result.completion == .complete)) result.validity = .valid;
            return result;
        }
        pub fn allocatedScope(allocator: std.mem.Allocator, source: []const u8, scope: scopes.Scope, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (scopeInputFailure(source, scope, settings, hook)) |failure| return failure;
            var result = scopeInitial(scope, settings);
            if (!scopeRequested(result)) return .{ .validity = .valid };
            if (cancelled(&result, hook)) return result;
            const count = if (scope == .opening_header and rules(settings).duplicate_attribute != .off and scope.opening_header.attributes.len >= 2) scope.opening_header.attributes.len else 0;
            if (count == 0) return runScopeTrusted(source, scope, .{}, sink, settings, hook);
            const keys = allocator.alloc(AttributeKeyScratch, count) catch {
                var stopped = unavailable(.out_of_memory, sink, 0, scope.opening_header.name, settings);
                stopped.checks = result.checks;
                return stopped;
            };
            defer allocator.free(keys);
            return runScopeTrusted(source, scope, .{ .attribute_keys = keys }, sink, settings, hook);
        }
        inline fn runSized(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook, required: Requirement) Result {
            // Validate retained local facts only; encoding must not inspect
            // an unrepresented suffix and claim tree-wide coverage.
            var prefix = document.*;
            if (document.state != .complete) prefix.source = document.source[0..document.retained_end];
            return retainedCoverage(document, runRetained(&prefix, scratch, sink, settings, hook, required));
        }
        fn retainedCoverage(document: *const syntax.Document, checked: Result) Result {
            if (document.state == .complete) return checked;
            var result = checked;
            // Do not replace an operational stop or fail-fast outcome with a gap.
            switch (result.completion) {
                .complete, .incomplete => recordGap(&result, document.retained_end),
                else => {},
            }
            inline for (comptime std.meta.fieldNames(@TypeOf(result.checks))) |field| {
                // Encoding is independent of syntax if every source byte was read.
                const all_bytes = comptime std.mem.eql(u8, field, "invalid_encoding");
                if (@field(result.checks, field) == .complete and !(all_bytes and document.retained_end == document.source.len))
                    @field(result.checks, field) = .incomplete;
            }
            if (result.validity == .valid) result.validity = .unknown;
            return result;
        }
        // Keep the sink and encoding-only policy visible through the partial
        // routing wrapper; an extra call boundary inhibits their specialization.
        inline fn runRetained(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook, required: Requirement) Result {
            var result = initial(settings);
            std.debug.assert(document.source.len <= support.location.max_source_len);
            if (scratch.attribute_keys.len < required.count) return unavailable(.{ .storage_exhausted = required.count }, sink, @intCast(scratch.attribute_keys.len), required.span, settings);
            // Only content/vocabulary checks need the forest. The default and
            // encoding-only paths retain their attribute-only/no-pool traversal.
            if (rules(settings).names.severity != .off or rules(settings).references.severity != .off or vocabularyActive(mode, rules(settings)))
                return runContent(document, scratch, sink, settings, hook);
            var offset: Offset = if (has_encoding) 0 else {};
            var poller: Poller = .{};
            var start: u32 = 0;
            while (rules(settings).duplicate_attribute != .off and start < document.attributes.len) {
                if (!poller.step(&result, hook)) return result;
                var end = start + 1;
                while (end < document.attributes.len and document.attributes[end].owner == document.attributes[start].owner) : (end += 1) {}
                const count = end - start;
                if (count >= 2) {
                    const keys = scratch.attribute_keys[0..count];
                    prepareKeys(document, keys, start);
                    // Linear source-order emission through the scattered column;
                    // the name-sorted index column is no longer consulted.
                    for (keys, start..) |key, index| {
                        if (!poller.step(&result, hook)) return result;
                        if (key.first == index) continue;
                        if (!emitDuplicate(document.source, document.attributes[index].name, document.attributes[key.first].name, &offset, &poller, &result, sink, settings, hook)) return result;
                    }
                }
                start = end;
            }
            if (rules(settings).duplicate_attribute != .off) result.checks.duplicate_attribute = .complete;
            if (!encodingThrough(document.source, @intCast(document.source.len), &offset, &poller, &result, sink, settings, hook)) return result;
            if (result.errors == 0) result.validity = .valid;
            return result;
        }

        /// Monotonic forest/attribute walks; no per-reference index, node state,
        /// diagnostic queue, or closing-tag rescan. Matched closing names are
        /// identical modulo Graphviz's ASCII case folding; name validity and
        /// vocabulary membership are therefore checked once per element.
        fn runContent(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            std.debug.assert(document.records.len <= std.math.maxInt(u32));
            std.debug.assert(document.attributes.len <= std.math.maxInt(u32));
            var result = initial(settings);
            var offset: Offset = if (has_encoding) 0 else {};
            var poller: Poller = .{};
            var attribute: u32 = 0;
            var gaps: ContractGaps = .{};
            const source = document.source;
            for (document.records, 0..) |node, id| {
                if (!poller.step(&result, hook)) return result;
                if (safety_checks) std.debug.assert(syntax.nodeInvariant(document, @intCast(id)));
                switch (node.kind()) {
                    .element => {
                        const owner = elementKind(source, node.name, settings);
                        if (!checkElement(source, node.name, owner, &offset, &poller, &result, sink, settings, hook)) return result;
                        if (!checkName(source, node.name, .element, &offset, &poller, &result, sink, settings, hook)) return result;
                        const start = attribute;
                        while (attribute < document.attributes.len and @backingInt(document.attributes[attribute].owner) == id) : (attribute += 1) {
                            // Duplicate-enabled validation already checked these
                            // during sizing, before any sorting/span access.
                            if (safety_checks and rules(settings).duplicate_attribute == .off)
                                std.debug.assert(syntax.attributeInvariant(document, attribute));
                        }
                        const count = attribute - start;
                        const duplicates = rules(settings).duplicate_attribute != .off and count >= 2;
                        const keys = if (duplicates) scratch.attribute_keys[0..count] else scratch.attribute_keys[0..0];
                        if (duplicates) prepareKeys(document, keys, start);
                        var header: HeaderFacts = .{};
                        for (document.attributes[start..attribute], start..) |attr, index| {
                            if (!poller.step(&result, hook)) return result;
                            if (duplicates and keys[index - start].first != index) {
                                const first = keys[index - start].first;
                                if (!emitDuplicate(source, attr.name, document.attributes[first].name, &offset, &poller, &result, sink, settings, hook)) return result;
                            }
                            if (!checkAttribute(source, node.name, owner, attr.name, &gaps, &offset, &poller, &result, sink, settings, hook)) return result;
                            if (!checkValue(source, node.name, owner, attr.name, attr.value, &header, &gaps, &poller, &result, sink, settings, hook)) return result;
                            if (!checkName(source, attr.name, .attribute, &offset, &poller, &result, sink, settings, hook)) return result;
                            // The retained value includes its original quotes.
                            if (!checkReferences(source, .{ .start = attr.value.start + enc.width, .len = attr.value.len - 2 * enc.width }, true, &offset, &poller, &result, sink, settings, hook)) return result;
                        }
                        if (document.node(@fromBackingInt(@intCast(id))).?.headerComplete().? and !checkHeader(node.name, owner, header, &gaps, &result, sink, settings)) return result;
                    },
                    .text => if (!checkReferences(source, node.span, false, &offset, &poller, &result, sink, settings, hook)) return result,
                    .comment, .cdata => {},
                }
            }
            // A malformed owner order must not silently skip retained values
            // and still claim the name/reference checks are complete.
            std.debug.assert(attribute == document.attributes.len);
            if (rules(settings).duplicate_attribute != .off) result.checks.duplicate_attribute = .complete;
            if (rules(settings).names.severity != .off) result.checks.names = .complete;
            if (referenceSettings(mode, rules(settings)).severity != .off) result.checks.references = .complete;
            if (mode == .graphviz and rules(settings).graphviz.unknown_element != .off) result.checks.graphviz_elements = .complete;
            if (mode == .graphviz and rules(settings).graphviz.invalid_attribute != .off and !gaps.attributes) result.checks.graphviz_attributes = .complete;
            if (mode == .graphviz and rules(settings).graphviz.invalid_value != .off and !gaps.values) result.checks.graphviz_values = .complete;
            if (!encodingThrough(source, @intCast(source.len), &offset, &poller, &result, sink, settings, hook)) return result;
            if (mode == .graphviz and rules(settings).graphviz.invalid_content != .off) {
                var context: ContentContext = .{ .result = &result, .poller = &poller, .sink = sink, .settings = settings, .hook = hook };
                const Checker = @import("graphviz_content.zig").Checker(actual);
                if (!Checker.check(document, null, &context)) return result;
                for (document.records, 0..) |node, id| {
                    if (!context.step()) return result;
                    if (node.kind() == .element and !Checker.check(document, @fromBackingInt(@intCast(id)), &context)) return result;
                }
                if (!context.missing) result.checks.graphviz_content = .complete;
            }
            if (result.errors == 0 and (mode == .structural or result.completion == .complete)) result.validity = .valid;
            return result;
        }

        const ContractGaps = struct { attributes: bool = false, values: bool = false };
        const Dimension = enum { missing, positive, zero, invalid };
        pub const HeaderFacts = struct { src: bool = false, fixed: bool = false, width: Dimension = .missing, height: Dimension = .missing };
        pub fn runValueTrusted(source: []const u8, owner: Span, name: Span, value: Span, facts: *HeaderFacts, sink: diagnostic.Sink, settings: Settings, hook: Hook, poller: *Poller) Result {
            var result: Result = .{};
            var gaps: ContractGaps = .{};
            if (mode == .graphviz and rules(settings).graphviz.invalid_value != .off) result.checks.graphviz_values = .incomplete;
            if (!checkValue(source, owner, elementKind(source, owner, settings), name, value, facts, &gaps, poller, &result, sink, settings, hook)) return result;
            if (result.checks.graphviz_values != .not_run and !gaps.values) result.checks.graphviz_values = .complete;
            if (result.errors == 0 and result.completion == .complete) result.validity = .valid;
            return result;
        }
        pub fn runHeaderTrusted(source: []const u8, name: Span, facts: HeaderFacts, sink: diagnostic.Sink, settings: Settings) Result {
            var result: Result = .{};
            var gaps: ContractGaps = .{};
            if (mode == .graphviz and rules(settings).graphviz.invalid_value != .off) result.checks.graphviz_values = .incomplete;
            if (!checkHeader(name, elementKind(source, name, settings), facts, &gaps, &result, sink, settings)) return result;
            if (result.checks.graphviz_values != .not_run and !gaps.values) result.checks.graphviz_values = .complete;
            if (result.errors == 0 and result.completion == .complete) result.validity = .valid;
            return result;
        }
        inline fn checkValue(source: []const u8, owner_name: Span, owner: ?graphviz.Element, name: Span, quoted: Span, header: *HeaderFacts, gaps: *ContractGaps, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (mode == .structural or rules(settings).graphviz.invalid_value == .off) return true;
            const tag = owner orelse {
                gaps.values = true;
                recordGap(result, name.start);
                return true;
            };
            if (!graphviz.allowsAttributeEncoded(actual, tag, name.slice(source))) {
                gaps.values = true;
                recordGap(result, name.start);
                return true;
            }
            if (quoted.len == 0) {
                gaps.values = true;
                recordGap(result, @intCast(name.endOffset()));
                return true;
            }
            const value = source[quoted.start + enc.width .. @as(usize, quoted.start) + quoted.len - enc.width];
            const Values = @import("graphviz_value.zig").Checks(actual);
            var context: ContentContext = .{ .result = result, .poller = poller, .sink = sink, .settings = settings, .hook = hook };
            const problem = Values.check(tag, name.slice(source), value, &context);
            if (result.completion == .cancelled) return false;
            if (Values.named(name.slice(source), "SRC")) header.src = true;
            if (Values.named(name.slice(source), "FIXEDSIZE")) header.fixed = Values.equals(value, "TRUE", &context);
            if (Values.named(name.slice(source), "WIDTH")) header.width = if (problem != null) .invalid else if (Values.positiveDimension(value, &context)) .positive else .zero;
            if (Values.named(name.slice(source), "HEIGHT")) header.height = if (problem != null) .invalid else if (Values.positiveDimension(value, &context)) .positive else .zero;
            if (result.completion == .cancelled) return false;
            if (problem) |p| return emitValue(result, sink, quoted, owner_name, p, settings);
            return true;
        }
        inline fn checkHeader(name: Span, owner: ?graphviz.Element, header: HeaderFacts, gaps: *ContractGaps, result: *Result, sink: diagnostic.Sink, settings: Settings) bool {
            if (mode == .structural or rules(settings).graphviz.invalid_value == .off) return true;
            if (owner == null) {
                gaps.values = true;
                recordGap(result, name.start);
                return true;
            }
            if (owner == .IMG and !header.src) return emitValue(result, sink, name, null, .image_source, settings);
            if (header.fixed and (header.width == .missing or header.width == .zero or header.height == .missing or header.height == .zero)) return emitValue(result, sink, name, null, .fixed_dimensions, settings);
            return true;
        }
        fn emitValue(result: *Result, sink: diagnostic.Sink, span: Span, related: ?Span, problem: @import("graphviz_value.zig").Problem, settings: Settings) bool {
            return emit(result, sink, .{ .code = if (rules(settings).graphviz.invalid_value == .err) .invalid_value else .invalid_value_tolerated, .span = span, .related = related, .details = .{ .graphviz_value = problem } }, settings);
        }

        const ContentContext = struct {
            result: *Result,
            poller: *Poller,
            sink: diagnostic.Sink,
            settings: Settings,
            hook: Hook,
            missing: bool = false,
            pub fn step(self: *@This()) bool {
                if (cancellable and self.result.completion == .cancelled) return false;
                return self.poller.step(self.result, self.hook);
            }
            pub fn unit(self: *@This()) bool {
                if (cancellable and self.result.completion == .cancelled) return false;
                if (!self.poller.check(self.result, self.hook)) return false;
                self.poller.consume(enc.width);
                return true;
            }
            pub fn gap(self: *@This(), at: u32) void {
                self.missing = true;
                recordGap(self.result, at);
            }
            pub fn finding(self: *@This(), span: Span, related: ?Span, problem: @import("graphviz_content.zig").Problem) bool {
                return emit(self.result, self.sink, .{
                    .code = if (rules(self.settings).graphviz.invalid_content == .err) .invalid_content else .invalid_content_tolerated,
                    .span = span,
                    .related = related,
                    .details = .{ .graphviz_content = problem },
                }, self.settings);
            }
        };

        /// One finding per retained name/reference name, at its first bad code
        /// point (one byte for malformed UTF-8); related identifies the full name.
        /// Inline short name/value checks so shared polling stays local to the
        /// traversal, rather than passing its state through per-attribute calls.
        inline fn checkName(source: []const u8, name: Span, context: diagnostic.NameContext, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            const selected = rules(settings).names;
            if (selected.severity == .off) return true;
            const bytes = name.slice(source);
            var index: u32 = 0;
            var scan = Poller.Scan.init(index, poller.*);
            while (index < bytes.len) {
                if (!scan.check(index, result, hook)) return false;
                const byte = enc.byteAt(bytes, index);
                var width: u3 = enc.width;
                var point: u21 = byte;
                var problem: ?diagnostic.NameProblem = null;
                if (byte >= 0x80) {
                    if (enc.decode(bytes, index)) |decoded| {
                        width = decoded.len;
                        point = decoded.scalar;
                    } else |_| {
                        problem = .invalid_encoding;
                    }
                }
                if (problem == null and !definitions.nameCharacter(selected.rule, point, index == 0))
                    problem = if (index == 0) .invalid_start else .invalid_character;
                index += width;
                if (problem) |reason| {
                    const at = name.start + index - width;
                    scan.flush(index, poller);
                    if (!encodingThrough(source, at, offset, poller, result, sink, settings, hook)) return false;
                    const code: diagnostic.Code = if (selected.severity == .err) .invalid_name else .invalid_name_tolerated;
                    return emit(result, sink, .{
                        .code = code,
                        .span = .{ .start = at, .len = if (reason == .invalid_encoding) enc.width else width },
                        .related = name,
                        .details = .{ .name = .{ .context = context, .problem = reason } },
                    }, settings);
                }
            }
            scan.flush(index, poller);
            return true;
        }

        /// Named references only. Reuse the scanner's byte-name predicates so
        /// malformed candidates accepted as literal text cannot become findings.
        /// Numeric candidates contain no '&'; scanning past them needs no decoding.
        inline fn checkReferences(source: []const u8, span: Span, attribute: bool, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (rules(settings).names.severity == .off and referenceSettings(mode, rules(settings)).severity == .off) return true;
            const bytes = span.slice(source);
            var index: u32 = 0;
            var scan = Poller.Scan.init(index, poller.*);
            while (index < bytes.len) {
                if (!scan.check(index, result, hook)) return false;
                const limit = scan.end(@intCast(bytes.len));
                // A polling window may end inside a native code unit. Include
                // the whole unit; the source scope is already aligned.
                const end = @min(bytes.len, ((@as(usize, limit) + enc.width - 1) / enc.width) * enc.width);
                const relative = enc.indexAscii(bytes[index..end], '&') orelse {
                    index = @intCast(end);
                    continue;
                };
                index += @intCast(relative);
                const amp = index;
                index += enc.width;
                if (index == bytes.len or !lexical.isNameStart(enc.byteAt(bytes, index))) continue;
                const begin = index;
                index += enc.width;
                while (index < bytes.len and lexical.isNameContinue(enc.byteAt(bytes, index))) : (index += enc.width) {
                    if (!scan.check(index, result, hook)) return false;
                }
                if (index == bytes.len or enc.byteAt(bytes, index) != ';') continue;
                const name: Span = .{ .start = span.start + begin, .len = index - begin };
                index += enc.width; // ';'
                // Nested name/encoding scans share and may exhaust the budget.
                // Flush before calling them, then reload their remainder below.
                scan.flush(index, poller);
                var selected = referenceSettings(mode, rules(settings));
                // Graphviz expands HTML4 names in text only. Attribute values
                // reach its XML parser unchanged; explicit catalogs still win.
                if (mode == .graphviz and attribute and rules(settings).references.severity == .off) selected.catalog = .xml_predefined;
                if (selected.severity != .off and !definitions.knownReferenceEncoded(actual, selected.catalog, name.slice(source))) {
                    // Catalog finding starts at '&', before any name finding.
                    const at = span.start + amp;
                    if (!encodingThrough(source, at, offset, poller, result, sink, settings, hook)) return false;
                    const code: diagnostic.Code = if (selected.severity == .err) .unknown_reference else .unknown_reference_tolerated;
                    if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = index - amp } }, settings)) return false;
                }
                if (!checkName(source, name, .reference, offset, poller, result, sink, settings, hook)) return false;
                scan = Poller.Scan.init(index, poller.*);
            }
            scan.flush(index, poller);
            return true;
        }

        // Both traversal paths share severity, related span and encoding-first
        // tie ordering, without adding a forest walk to the default path.
        inline fn emitDuplicate(source: []const u8, name: Span, first: Span, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (!encodingThrough(source, name.start, offset, poller, result, sink, settings, hook)) return false;
            const code: diagnostic.Code = if (rules(settings).duplicate_attribute == .err) .duplicate_attribute else .duplicate_attribute_tolerated;
            return emit(result, sink, .{ .code = code, .span = name, .related = first }, settings);
        }

        inline fn prepareKeys(context: anytype, keys: []AttributeKeyScratch, start: u32) void {
            const ignore_case = mode == .graphviz;
            // Pass a view pointer, not copied slices, through the comparator.
            // The retained path keeps its existing Document pointer directly.
            const Order = struct {
                fn less(self: @TypeOf(context), a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
                    const left = self.attributes[a.index].name.slice(self.source);
                    const right = self.attributes[b.index].name.slice(self.source);
                    const order = if (enc.width == 1) (if (ignore_case) std.ascii.orderIgnoreCase(left, right) else std.mem.order(u8, left, right)) else enc.orderUnits(left, right, ignore_case);
                    return if (order == .eq) a.index < b.index else order == .lt;
                }
            };
            for (keys, start..) |*key, index| key.* = .{ .index = @intCast(index), .first = 0 };
            std.sort.heap(AttributeKeyScratch, keys, context, Order.less);
            var first = keys[0].index;
            keys[first - start].first = first;
            for (keys[1..]) |key| {
                const left = context.attributes[first].name.slice(context.source);
                const right = context.attributes[key.index].name.slice(context.source);
                if (!(if (enc.width == 1) (if (ignore_case) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right)) else enc.orderUnits(left, right, ignore_case) == .eq)) first = key.index;
                keys[key.index - start].first = first;
            }
        }

        inline fn elementKind(source: []const u8, name: Span, settings: Settings) ?graphviz.Element {
            if (!vocabularyActive(mode, rules(settings))) return null;
            return graphviz.elementEncoded(actual, name.slice(source));
        }
        inline fn checkElement(source: []const u8, name: Span, owner: ?graphviz.Element, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (mode == .structural) return true;
            const severity = rules(settings).graphviz.unknown_element;
            if (severity == .off or owner != null) return true;
            if (!encodingThrough(source, name.start, offset, poller, result, sink, settings, hook)) return false;
            return emit(result, sink, .{ .code = if (severity == .err) .unknown_element else .unknown_element_tolerated, .span = name }, settings);
        }
        inline fn checkAttribute(source: []const u8, owner_name: Span, owner: ?graphviz.Element, name: Span, gaps: *ContractGaps, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (mode == .structural) return true;
            const severity = rules(settings).graphviz.invalid_attribute;
            if (severity == .off) return true;
            // An unknown owner's attribute contract is unavailable. Do not
            // manufacture one error per attribute as a consequence of its name.
            const tag = owner orelse {
                gaps.attributes = true;
                recordGap(result, name.start);
                return true;
            };
            if (graphviz.allowsAttributeEncoded(actual, tag, name.slice(source))) return true;
            if (!encodingThrough(source, name.start, offset, poller, result, sink, settings, hook)) return false;
            return emit(result, sink, .{ .code = if (severity == .err) .invalid_attribute else .invalid_attribute_tolerated, .span = name, .related = owner_name }, settings);
        }
        /// Scanner-produced attribute with its owner; no buffering is necessary
        /// when duplicate checking is off. Not an unchecked public scope API.
        pub fn runAttributeVocabularyTrusted(source: []const u8, owner: Span, name: Span, sink: diagnostic.Sink, settings: Settings, hook: Hook, poller: *Poller) Result {
            if (mode == .structural) return .{ .validity = .valid };
            if (rules(settings).graphviz.invalid_attribute == .off) return .{ .validity = .valid };
            var result: Result = .{ .checks = .{ .graphviz_attributes = .incomplete } };
            if (!poller.step(&result, hook)) return result;
            var offset: Offset = if (has_encoding) name.start else {};
            var gaps: ContractGaps = .{};
            if (!checkAttribute(source, owner, elementKind(source, owner, settings), name, &gaps, &offset, poller, &result, sink, settings, hook)) return result;
            if (result.completion == .complete) {
                result.checks.graphviz_attributes = .complete;
                if (result.errors == 0) result.validity = .valid;
            }
            return result;
        }
        pub fn allocated(allocator: std.mem.Allocator, document: *const syntax.Document, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (!canRead(document)) return .{ .completion = .{ .unsupported_encoding = document.source_info.encoding } };
            if (distinguish_ascii and document.source_info.encoding == .ascii)
                return @call(.never_inline, ValidatorForEncoding(.ascii, fixed, cancellable, mode).allocated, .{ allocator, document, sink, settings, hook });
            if (!enabled(settings)) return retainedCoverage(document, .{ .validity = .valid });
            var result = initial(settings);
            if (cancelled(&result, hook)) return result;
            if (rules(settings).duplicate_attribute == .off) return runSized(document, .{}, sink, settings, hook, .{});
            const required = requirement(document);
            const keys = allocator.alloc(AttributeKeyScratch, required.count) catch return unavailable(.out_of_memory, sink, 0, required.span, settings);
            defer allocator.free(keys);
            if (cancelled(&result, hook)) return result;
            return runSized(document, .{ .attribute_keys = keys }, sink, settings, hook, required);
        }
        pub fn reusing(allocator: std.mem.Allocator, document: *const syntax.Document, keys: *std.ArrayList(AttributeKeyScratch), sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (!canRead(document)) return .{ .completion = .{ .unsupported_encoding = document.source_info.encoding } };
            if (distinguish_ascii and document.source_info.encoding == .ascii)
                return @call(.never_inline, ValidatorForEncoding(.ascii, fixed, cancellable, mode).reusing, .{ allocator, document, keys, sink, settings, hook });
            if (!enabled(settings)) return retainedCoverage(document, .{ .validity = .valid });
            var result = initial(settings);
            if (cancelled(&result, hook)) return result;
            if (rules(settings).duplicate_attribute == .off) return runSized(document, .{}, sink, settings, hook, .{});
            const required = requirement(document);
            keys.resize(allocator, required.count) catch return unavailable(.out_of_memory, sink, 0, required.span, settings);
            if (cancelled(&result, hook)) return result;
            return runSized(document, .{ .attribute_keys = keys.items }, sink, settings, hook, required);
        }
        fn cancelled(result: *Result, hook: Hook) bool {
            if (!requested(hook)) return false;
            result.completion = .cancelled;
            return true;
        }
        fn emit(result: *Result, sink: diagnostic.Sink, finding: diagnostic.Diagnostic, settings: Settings) bool {
            if (finding.code.severity() == .err) {
                result.errors += 1;
                result.validity = .invalid;
            } else result.warnings += 1;
            const action = sink.emit(finding) catch |err| {
                result.completion = .{ .diagnostic_stopped = .fromError(err) };
                result.diagnostic_delivery = .failed;
                return false;
            };
            if (action == .stop) {
                result.completion = .{ .diagnostic_stopped = .requested };
                return false;
            }
            if (rules(settings).on_error == .fail_fast and finding.code.severity() == .err) {
                result.completion = .error_stopped;
                return false;
            }
            return true;
        }
        /// One monotonically advancing scope cursor using the selected reader.
        /// Each invalid code unit is one finding; valid scalars consume whole
        /// sequences. Encoding validity is not XML character/name validity.
        fn encodingThrough(source: []const u8, through: u32, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (comptime !has_encoding) return true;
            if (rules(settings).invalid_encoding == .off) return true;
            if (!cancellable) {
                // Keep the direct, unchunked loop when polling is compiled out.
                while (offset.* < source.len and offset.* <= through) {
                    const at = offset.*;
                    // Keep the length in a register for UTF-8. Returning the
                    // general reader's length/error aggregate on every scalar
                    // causes a stack round trip even for valid input.
                    if (actual == .utf8) {
                        if (source[at] < 0x80) {
                            offset.* += 1;
                            continue;
                        }
                        if (support.utf8.sequenceLength(source[at..])) |len| {
                            offset.* += len;
                        } else {
                            offset.* += 1;
                            const code: diagnostic.Code = if (rules(settings).invalid_encoding == .err) .invalid_encoding else .invalid_encoding_tolerated;
                            if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = 1 }, .details = .{ .invalid_encoding = .{ .unit = source[at], .encoding = actual } } }, settings)) return false;
                        }
                        continue;
                    }
                    const step = support.encoding.validationStep(actual, source, at);
                    offset.* += step.len;
                    if (step.invalid) |bad| {
                        const code: diagnostic.Code = if (rules(settings).invalid_encoding == .err) .invalid_encoding else .invalid_encoding_tolerated;
                        if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = step.len }, .details = .{ .invalid_encoding = bad } }, settings)) return false;
                    }
                }
            } else {
                // Publish the local cursor on every exit, including sink stops.
                var cursor = offset.*;
                defer offset.* = cursor;
                var scan = Poller.Scan.init(cursor, poller.*);
                const limit = @min(@as(u32, @intCast(source.len)), through +| 1);
                while (cursor < limit) {
                    if (!scan.check(cursor, result, hook)) return false;
                    const end = scan.end(limit);
                    // Finish whole scalars; sink stops inside chunks stay immediate.
                    while (cursor < end) {
                        const at = cursor;
                        if (actual == .utf8) {
                            if (source[at] < 0x80) {
                                cursor += 1;
                                continue;
                            }
                            if (support.utf8.sequenceLength(source[at..])) |len| {
                                cursor += len;
                            } else {
                                cursor += 1;
                                const code: diagnostic.Code = if (rules(settings).invalid_encoding == .err) .invalid_encoding else .invalid_encoding_tolerated;
                                if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = 1 }, .details = .{ .invalid_encoding = .{ .unit = source[at], .encoding = actual } } }, settings)) return false;
                            }
                            continue;
                        }
                        const step = support.encoding.validationStep(actual, source, at);
                        cursor += step.len;
                        if (step.invalid) |bad| {
                            const code: diagnostic.Code = if (rules(settings).invalid_encoding == .err) .invalid_encoding else .invalid_encoding_tolerated;
                            if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = step.len }, .details = .{ .invalid_encoding = bad } }, settings)) return false;
                        }
                    }
                }
                scan.flush(cursor, poller);
            }
            if (offset.* == source.len) result.checks.invalid_encoding = .complete;
            return true;
        }
    };
}
