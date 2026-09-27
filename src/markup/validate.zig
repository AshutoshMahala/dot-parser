//! Independent policy checks over completed syntax, never rewriting it.
//! Scratch is reused per element. Heap sorting has deterministic O(A log A)
//! comparisons, with bytewise name comparisons; no hash-collision worst case.
//! This pass is run-to-completion, not a metered parsing session.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
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
        fn rules(settings: Settings) policy.ValidationSettings {
            return if (fixed) |value| value else settings;
        }
        fn initial(settings: Settings) Result {
            const s = rules(settings);
            return .{ .checks = .{
                .duplicate_attribute = if (s.duplicate_attribute == .off) .not_run else .incomplete,
                .invalid_utf8 = if (s.invalid_utf8 == .off) .not_run else .incomplete,
            } };
        }
        fn enabled(settings: Settings) bool {
            const s = rules(settings);
            return s.duplicate_attribute != .off or s.invalid_utf8 != .off;
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
            if (scratch.attribute_keys.len < required.count) return unavailable(.{ .storage_exhausted = required.count }, sink, @intCast(scratch.attribute_keys.len), required.span, settings);
            var offset: Offset = if (has_encoding) 0 else {};
            var start: u32 = 0;
            while (rules(settings).duplicate_attribute != .off and start < document.attributes.len) {
                if (requested(hook)) {
                    result.completion = .cancelled;
                    return result;
                }
                var end = start + 1;
                while (end < document.attributes.len and document.attributes[end].owner == document.attributes[start].owner) : (end += 1) {}
                const count = end - start;
                if (count >= 2) {
                    const keys = scratch.attribute_keys[0..count];
                    for (keys, start..) |*key, index| key.* = .{ .index = @intCast(index), .first = 0 };
                    std.sort.heap(AttributeKeyScratch, keys, document, nameLessThan);
                    var first = keys[0].index;
                    keys[first - start].first = first;
                    for (keys[1..]) |key| {
                        if (!std.mem.eql(u8, document.attributes[first].name.slice(document.source), document.attributes[key.index].name.slice(document.source))) first = key.index;
                        keys[key.index - start].first = first;
                    }
                    // Linear source-order emission through the scattered column;
                    // the name-sorted index column is no longer consulted.
                    for (keys, start..) |key, index| {
                        if (requested(hook)) {
                            result.completion = .cancelled;
                            return result;
                        }
                        if (key.first == index) continue;
                        // Visit encoding before this finding, including ties.
                        // No finding queue/sort or source-sized temporary pool.
                        if (!encodingThrough(document.source, document.attributes[index].name.start, &offset, &result, sink, settings, hook)) return result;
                        const code: diagnostic.Code = if (rules(settings).duplicate_attribute == .err) .duplicate_attribute else .duplicate_attribute_tolerated;
                        if (!emit(&result, sink, .{ .code = code, .span = document.attributes[index].name, .related = document.attributes[key.first].name })) return result;
                    }
                }
                start = end;
            }
            if (rules(settings).duplicate_attribute != .off) result.checks.duplicate_attribute = .complete;
            if (!encodingThrough(document.source, @intCast(document.source.len), &offset, &result, sink, settings, hook)) return result;
            if (result.errors == 0) result.validity = .valid;
            return result;
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
        fn encodingThrough(source: []const u8, through: u32, offset: *Offset, result: *Result, sink: diagnostic.Sink, settings: Settings, hook: Hook) bool {
            if (comptime !has_encoding) return true;
            if (rules(settings).invalid_utf8 == .off) return true;
            while (offset.* < source.len and offset.* <= through) {
                if (cancelled(result, hook)) return false;
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
            if (offset.* == source.len) result.checks.invalid_utf8 = .complete;
            return true;
        }
        fn nameLessThan(document: *const syntax.Document, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
            const order = std.mem.order(u8, document.attributes[a.index].name.slice(document.source), document.attributes[b.index].name.slice(document.source));
            return if (order == .eq) a.index < b.index else order == .lt;
        }
    };
}
