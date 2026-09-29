//! Independent policy checks over completed syntax, never rewriting it.
//! Scratch is reused per element. Heap sorting has deterministic O(A log A)
//! comparisons, with bytewise name comparisons; no hash-collision worst case.
//! This pass is run-to-completion, not a metered parsing session.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
const definitions = @import("validation_rules.zig");
const lexical = @import("lexer.zig");
const Span = support.location.Span;
const safety_checks = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
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
pub const CheckStatus = enum { not_run, incomplete, complete };
pub const Result = struct {
    completion: union(enum) {
        complete,
        storage_exhausted: u32, // required entries for the largest attribute list
        out_of_memory,
        cancelled,
        diagnostic_stopped: support.reporting.StopReason,
    } = .complete,
    validity: enum { valid, invalid, unknown } = .unknown,
    checks: struct {
        duplicate_attribute: CheckStatus = .not_run,
        invalid_utf8: CheckStatus = .not_run,
        names: CheckStatus = .not_run,
        references: CheckStatus = .not_run,
    } = .{},
    /// Aggregate findings from independent checks, which may overlap source
    /// spans. Offsets/capacities remain u32; totals use u64, as in DOT validation.
    errors: u64 = 0,
    warnings: u64 = 0,
    diagnostic_delivery: support.reporting.Delivery = .complete,
};

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
    return if (maximum < 2) .{} else .{ .count = maximum, .span = document.records[@intFromEnum(largest_owner)].name };
}

pub fn Validator(comptime fixed: ?policy.ValidationSettings, comptime cancellable: bool) type {
    return struct {
        pub const Settings = if (fixed == null) policy.ValidationSettings else void;
        pub const Hook = if (cancellable) ?support.execution.Cancellation else void;
        const has_encoding = if (fixed) |s| s.invalid_utf8 != .off else true;
        const Offset = if (has_encoding) u32 else void;
        /// One countdown shared by the traversal and all content scans. Charge
        /// bytes examined (including revisits by another check) and record steps,
        /// not absolute source progress. A scalar can cross the threshold by 3.
        /// Fixed-disabled profiles have neither state nor callback branches.
        const Poller = struct {
            remaining: if (cancellable) u32 else void = if (cancellable) 0 else {},
            inline fn check(self: *@This(), result: *Result, hook: Hook) bool {
                if (!cancellable) return true;
                if (self.remaining != 0) return true;
                if (cancelled(result, hook)) return false;
                self.remaining = 64;
                return true;
            }
            inline fn consume(self: *@This(), count: u32) void {
                if (cancellable) self.remaining -|= count;
            }
            inline fn step(self: *@This(), result: *Result, hook: Hook) bool {
                if (!self.check(result, hook)) return false;
                self.consume(1);
                return true;
            }
            /// Keep byte-loop thresholds local; flush shared work at scan exit
            /// and before nested checks, then reload after those checks. A false
            /// return ends validation, so no remaining budget is used afterward.
            const Scan = struct {
                next: if (cancellable) u32 else void,
                inline fn init(index: u32, poller: Poller) @This() {
                    return .{ .next = if (cancellable) index +| poller.remaining else {} };
                }
                inline fn check(self: *@This(), index: u32, result: *Result, hook: Hook) bool {
                    if (!cancellable) return true;
                    if (index < self.next) return true;
                    if (cancelled(result, hook)) return false;
                    self.next = index +| 64;
                    return true;
                }
                inline fn flush(self: @This(), index: u32, poller: *Poller) void {
                    if (!cancellable) return;
                    poller.remaining = self.next -| index;
                }
                inline fn end(self: @This(), len: u32) u32 {
                    return if (cancellable) @min(self.next, len) else len;
                }
            };
        };
        // Expose fixed selections during semantic analysis, not just as an
        // optimizer inlining opportunity. Disabled passes must not instantiate.
        inline fn rules(settings: Settings) policy.ValidationSettings {
            return if (fixed) |value| value else settings;
        }
        fn initial(settings: Settings) Result {
            const s = rules(settings);
            return .{ .checks = .{
                .duplicate_attribute = if (s.duplicate_attribute == .off) .not_run else .incomplete,
                .invalid_utf8 = if (s.invalid_utf8 == .off) .not_run else .incomplete,
                .names = if (s.names.severity == .off) .not_run else .incomplete,
                .references = if (s.references.severity == .off) .not_run else .incomplete,
            } };
        }
        fn enabled(settings: Settings) bool {
            const s = rules(settings);
            return s.duplicate_attribute != .off or s.invalid_utf8 != .off or s.names.severity != .off or s.references.severity != .off;
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
            if (!enabled(settings)) return .{ .validity = .valid };
            var result = initial(settings);
            if (cancelled(&result, hook)) return result;
            const required = if (rules(settings).duplicate_attribute != .off) requirement(document) else Requirement{};
            return runSized(document, scratch, sink, settings, hook, required);
        }
        fn runSized(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook, required: Requirement) Result {
            var result = initial(settings);
            std.debug.assert(document.source.len <= support.location.max_source_len);
            if (scratch.attribute_keys.len < required.count) return unavailable(.{ .storage_exhausted = required.count }, sink, @intCast(scratch.attribute_keys.len), required.span, settings);
            // Only name/reference checks need the forest. The default and
            // encoding-only paths retain their attribute-only/no-pool traversal.
            if (rules(settings).names.severity != .off or rules(settings).references.severity != .off)
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
                        if (!emitDuplicate(document, @intCast(index), key.first, &offset, &poller, &result, sink, settings, hook)) return result;
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
        /// byte-identical to their opening name and are checked once per element.
        fn runContent(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            std.debug.assert(document.records.len <= std.math.maxInt(u32));
            std.debug.assert(document.attributes.len <= std.math.maxInt(u32));
            var result = initial(settings);
            var offset: Offset = if (has_encoding) 0 else {};
            var poller: Poller = .{};
            var attribute: u32 = 0;
            const source = document.source;
            for (document.records, 0..) |node, id| {
                if (!poller.step(&result, hook)) return result;
                if (safety_checks) std.debug.assert(syntax.nodeInvariant(document, @intCast(id)));
                switch (node.kind()) {
                    .element => {
                        if (!checkName(source, node.name, .element, &offset, &poller, &result, sink, settings, hook)) return result;
                        const start = attribute;
                        while (attribute < document.attributes.len and @intFromEnum(document.attributes[attribute].owner) == id) : (attribute += 1) {
                            // Duplicate-enabled validation already checked these
                            // during sizing, before any sorting/span access.
                            if (safety_checks and rules(settings).duplicate_attribute == .off)
                                std.debug.assert(syntax.attributeInvariant(document, attribute));
                        }
                        const count = attribute - start;
                        const duplicates = rules(settings).duplicate_attribute != .off and count >= 2;
                        const keys = if (duplicates) scratch.attribute_keys[0..count] else scratch.attribute_keys[0..0];
                        if (duplicates) prepareKeys(document, keys, start);
                        for (document.attributes[start..attribute], start..) |attr, index| {
                            if (!poller.step(&result, hook)) return result;
                            if (duplicates and keys[index - start].first != index) {
                                const first = keys[index - start].first;
                                if (!emitDuplicate(document, @intCast(index), first, &offset, &poller, &result, sink, settings, hook)) return result;
                            }
                            if (!checkName(source, attr.name, .attribute, &offset, &poller, &result, sink, settings, hook)) return result;
                            // The retained value includes its original quotes.
                            if (!checkReferences(source, .{ .start = attr.value.start + 1, .len = attr.value.len - 2 }, &offset, &poller, &result, sink, settings, hook)) return result;
                        }
                    },
                    .text => if (!checkReferences(source, node.span, &offset, &poller, &result, sink, settings, hook)) return result,
                    .comment, .cdata => {},
                }
            }
            // A malformed owner order must not silently skip retained values
            // and still claim the name/reference checks are complete.
            std.debug.assert(attribute == document.attributes.len);
            if (rules(settings).duplicate_attribute != .off) result.checks.duplicate_attribute = .complete;
            if (rules(settings).names.severity != .off) result.checks.names = .complete;
            if (rules(settings).references.severity != .off) result.checks.references = .complete;
            if (!encodingThrough(source, @intCast(source.len), &offset, &poller, &result, sink, settings, hook)) return result;
            if (result.errors == 0) result.validity = .valid;
            return result;
        }

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
                const byte = bytes[index];
                var width: u3 = 1;
                var point: u21 = byte;
                var problem: ?diagnostic.NameProblem = null;
                if (byte >= 0x80) {
                    if (support.utf8.decode(bytes[index..])) |decoded| {
                        width = decoded.len;
                        point = decoded.scalar;
                    } else {
                        problem = .invalid_utf8;
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
                        .span = .{ .start = at, .len = if (reason == .invalid_utf8) 1 else width },
                        .related = name,
                        .details = .{ .name = .{ .context = context, .problem = reason } },
                    });
                }
            }
            scan.flush(index, poller);
            return true;
        }

        /// Named references only. Reuse the scanner's byte-name predicates so
        /// malformed candidates accepted as literal text cannot become findings.
        /// Numeric candidates contain no '&'; scanning past them needs no decoding.
        inline fn checkReferences(source: []const u8, span: Span, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            const bytes = span.slice(source);
            var index: u32 = 0;
            var scan = Poller.Scan.init(index, poller.*);
            while (index < bytes.len) {
                if (!scan.check(index, result, hook)) return false;
                const end = scan.end(@intCast(bytes.len));
                const relative = std.mem.indexOfScalar(u8, bytes[index..end], '&') orelse {
                    index = end;
                    continue;
                };
                index += @intCast(relative);
                const amp = index;
                index += 1;
                if (index == bytes.len or !lexical.isNameStart(bytes[index])) continue;
                const begin = index;
                index += 1;
                while (index < bytes.len and lexical.isNameContinue(bytes[index])) : (index += 1) {
                    if (!scan.check(index, result, hook)) return false;
                }
                if (index == bytes.len or bytes[index] != ';') continue;
                const name: Span = .{ .start = span.start + begin, .len = index - begin };
                index += 1; // ';'
                // Nested name/encoding scans share and may exhaust the budget.
                // Flush before calling them, then reload their remainder below.
                scan.flush(index, poller);
                const selected = rules(settings).references;
                if (selected.severity != .off and !definitions.knownReference(selected.catalog, name.slice(source))) {
                    // Catalog finding starts at '&', before any name finding.
                    const at = span.start + amp;
                    if (!encodingThrough(source, at, offset, poller, result, sink, settings, hook)) return false;
                    const code: diagnostic.Code = if (selected.severity == .err) .unknown_reference else .unknown_reference_tolerated;
                    if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = index - amp } })) return false;
                }
                if (!checkName(source, name, .reference, offset, poller, result, sink, settings, hook)) return false;
                scan = Poller.Scan.init(index, poller.*);
            }
            scan.flush(index, poller);
            return true;
        }

        // Both traversal paths share severity, related span and encoding-first
        // tie ordering, without adding a forest walk to the default path.
        inline fn emitDuplicate(document: *const syntax.Document, index: u32, first: u32, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            const name = document.attributes[index].name;
            if (!encodingThrough(document.source, name.start, offset, poller, result, sink, settings, hook)) return false;
            const code: diagnostic.Code = if (rules(settings).duplicate_attribute == .err) .duplicate_attribute else .duplicate_attribute_tolerated;
            return emit(result, sink, .{ .code = code, .span = name, .related = document.attributes[first].name });
        }

        inline fn prepareKeys(document: *const syntax.Document, keys: []AttributeKeyScratch, start: u32) void {
            for (keys, start..) |*key, index| key.* = .{ .index = @intCast(index), .first = 0 };
            std.sort.heap(AttributeKeyScratch, keys, document, nameLessThan);
            var first = keys[0].index;
            keys[first - start].first = first;
            for (keys[1..]) |key| {
                if (!std.mem.eql(u8, document.attributes[first].name.slice(document.source), document.attributes[key.index].name.slice(document.source))) first = key.index;
                keys[key.index - start].first = first;
            }
        }
        pub fn allocated(allocator: std.mem.Allocator, document: *const syntax.Document, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (!enabled(settings)) return .{ .validity = .valid };
            var result = initial(settings);
            if (cancelled(&result, hook)) return result;
            if (rules(settings).duplicate_attribute == .off) return runSized(document, .{}, sink, settings, hook, .{});
            const required = requirement(document);
            const keys = allocator.alloc(AttributeKeyScratch, required.count) catch return unavailable(.out_of_memory, sink, 0, required.span, settings);
            defer allocator.free(keys);
            if (cancelled(&result, hook)) return result;
            return runSized(document, .{ .attribute_keys = keys }, sink, settings, hook, required);
        }
        fn cancelled(result: *Result, hook: Hook) bool {
            if (!requested(hook)) return false;
            result.completion = .cancelled;
            return true;
        }
        fn emit(result: *Result, sink: diagnostic.Sink, finding: diagnostic.Diagnostic) bool {
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
            return true;
        }
        /// One monotonically advancing source cursor. Each invalid leading byte
        /// is reported separately; valid sequences consume 1..4 bytes. This is
        /// encoding validation, not XML character/name validation or decoding.
        fn encodingThrough(source: []const u8, through: u32, offset: *Offset, poller: *Poller, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (comptime !has_encoding) return true;
            if (rules(settings).invalid_utf8 == .off) return true;
            if (!cancellable) {
                // Keep the direct, unchunked loop when polling is compiled out.
                while (offset.* < source.len and offset.* <= through) {
                    const at = offset.*;
                    if (source[at] < 0x80) {
                        offset.* += 1;
                        continue;
                    }
                    if (support.utf8.sequenceLength(source[at..])) |len| {
                        offset.* += len;
                    } else {
                        offset.* += 1;
                        const code: diagnostic.Code = if (rules(settings).invalid_utf8 == .err) .invalid_utf8 else .invalid_utf8_tolerated;
                        if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = 1 }, .details = .{ .byte = source[at] } })) return false;
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
                        if (source[at] < 0x80) {
                            cursor += 1;
                            continue;
                        }
                        if (support.utf8.sequenceLength(source[at..])) |len| {
                            cursor += len;
                        } else {
                            cursor += 1;
                            const code: diagnostic.Code = if (rules(settings).invalid_utf8 == .err) .invalid_utf8 else .invalid_utf8_tolerated;
                            if (!emit(result, sink, .{ .code = code, .span = .{ .start = at, .len = 1 }, .details = .{ .byte = source[at] } })) return false;
                        }
                    }
                }
                scan.flush(cursor, poller);
            }
            if (offset.* == source.len) result.checks.invalid_utf8 = .complete;
            return true;
        }

        fn nameLessThan(document: *const syntax.Document, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
            const order = std.mem.order(u8, document.attributes[a.index].name.slice(document.source), document.attributes[b.index].name.slice(document.source));
            return if (order == .eq) a.index < b.index else order == .lt;
        }
    };
}
