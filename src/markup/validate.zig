//! Independent duplicate checking over completed syntax, never rewriting it.
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
    checks: struct { duplicate_attribute: CheckStatus = .not_run } = .{},
    errors: u32 = 0,
    warnings: u32 = 0,
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

pub fn Validator(comptime fixed: ?policy.RuleSeverity, comptime cancellable: bool) type {
    return struct {
        pub const Settings = if (fixed == null) policy.RuleSeverity else void;
        pub const Hook = if (cancellable) ?support.execution.Cancellation else void;
        fn rule(settings: Settings) policy.RuleSeverity {
            return if (fixed) |value| value else settings;
        }
        fn requested(hook: Hook) bool {
            return if (cancellable) (if (hook) |h| h.requested() else false) else false;
        }
        fn unavailable(completion: @FieldType(Result, "completion"), sink: diagnostic.Sink, capacity: u32, span: support.location.Span) Result {
            const finding: diagnostic.Diagnostic = switch (completion) {
                .storage_exhausted => .{ .code = .capacity_exhausted, .span = span, .details = .{ .capacity = .{ .resource = .attribute_keys, .limit = capacity } } },
                .out_of_memory => .{ .code = .out_of_memory, .span = span },
                else => unreachable,
            };
            var result: Result = .{ .completion = completion, .checks = .{ .duplicate_attribute = .incomplete } };
            _ = sink.emit(finding) catch {
                result.diagnostic_delivery = .failed;
            };
            return result;
        }
        pub fn run(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (rule(settings) == .off) return .{ .validity = .valid };
            if (requested(hook)) return .{ .completion = .cancelled, .checks = .{ .duplicate_attribute = .incomplete } };
            return runSized(document, scratch, sink, settings, hook, requirement(document));
        }
        fn runSized(document: *const syntax.Document, scratch: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook, required: Requirement) Result {
            var result: Result = .{ .checks = .{ .duplicate_attribute = .incomplete } };
            if (scratch.attribute_keys.len < required.count) return unavailable(.{ .storage_exhausted = required.count }, sink, @intCast(scratch.attribute_keys.len), required.span);
            var start: u32 = 0;
            while (start < document.attributes.len) {
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
                        const code: diagnostic.Code = if (rule(settings) == .err) .duplicate_attribute else .duplicate_attribute_tolerated;
                        if (rule(settings) == .err) {
                            result.errors += 1;
                            result.validity = .invalid;
                        } else result.warnings += 1;
                        const action = sink.emit(.{ .code = code, .span = document.attributes[index].name, .related = document.attributes[key.first].name }) catch |err| {
                            result.completion = .{ .diagnostic_stopped = .fromError(err) };
                            result.diagnostic_delivery = .failed;
                            return result;
                        };
                        if (action == .stop) {
                            result.completion = .{ .diagnostic_stopped = .requested };
                            return result;
                        }
                    }
                }
                start = end;
            }
            result.checks.duplicate_attribute = .complete;
            if (result.errors == 0) result.validity = .valid;
            return result;
        }
        pub fn allocated(allocator: std.mem.Allocator, document: *const syntax.Document, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            if (rule(settings) == .off) return .{ .validity = .valid };
            if (requested(hook)) return .{ .completion = .cancelled, .checks = .{ .duplicate_attribute = .incomplete } };
            const required = requirement(document);
            const keys = allocator.alloc(AttributeKeyScratch, required.count) catch return unavailable(.out_of_memory, sink, 0, required.span);
            defer allocator.free(keys);
            if (requested(hook)) return .{ .completion = .cancelled, .checks = .{ .duplicate_attribute = .incomplete } };
            return runSized(document, .{ .attribute_keys = keys }, sink, settings, hook, required);
        }
        fn nameLessThan(document: *const syntax.Document, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
            const order = std.mem.order(u8, document.attributes[a.index].name.slice(document.source), document.attributes[b.index].name.slice(document.source));
            return if (order == .eq) a.index < b.index else order == .lt;
        }
    };
}
