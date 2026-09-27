//! Independent duplicate checking over completed syntax, never rewriting it.
//! Scratch is reused per element. Heap sorting has deterministic O(A log A)
//! comparisons, with bytewise name comparisons; no hash-collision worst case.
//! This pass is run-to-completion, not a metered parsing session.
const std = @import("std");
const support = @import("parser_support");
const syntax = @import("syntax.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");

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
pub fn requiredScratch(document: *const syntax.Document) u32 {
    var maximum: u32 = 0;
    var count: u32 = 0;
    var owner: ?syntax.NodeId = null;
    for (document.attributes) |attribute| {
        if (owner != attribute.owner) {
            owner = attribute.owner;
            count = 0;
        }
        count += 1;
        maximum = @max(maximum, count);
    }
    return if (maximum < 2) 0 else maximum;
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
        fn unavailable(completion: @FieldType(Result, "completion"), sink: diagnostic.Sink, capacity: u32) Result {
            const finding: diagnostic.Diagnostic = switch (completion) {
                .storage_exhausted => .{ .code = .capacity_exhausted, .span = .{ .start = 0, .len = 0 }, .details = .{ .capacity = .{ .resource = .attribute_keys, .limit = capacity } } },
                .out_of_memory => .{ .code = .out_of_memory, .span = .{ .start = 0, .len = 0 } },
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
            var result: Result = .{ .checks = .{ .duplicate_attribute = .incomplete } };
            if (requested(hook)) {
                result.completion = .cancelled;
                return result;
            }
            const required = requiredScratch(document);
            if (scratch.attribute_keys.len < required) return unavailable(.{ .storage_exhausted = required }, sink, @intCast(scratch.attribute_keys.len));
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
                    for (keys, start..) |*key, index| key.* = .{ .index = @intCast(index), .first = @intCast(index) };
                    std.sort.heap(AttributeKeyScratch, keys, document, nameLessThan);
                    var first = keys[0].index;
                    for (keys[1..]) |*key| {
                        if (!std.mem.eql(u8, document.attributes[first].name.slice(document.source), document.attributes[key.index].name.slice(document.source))) first = key.index;
                        key.first = first;
                    }
                    // Report every occurrence after the first, in document order.
                    std.sort.heap(AttributeKeyScratch, keys, {}, indexLessThan);
                    for (keys) |key| {
                        if (requested(hook)) {
                            result.completion = .cancelled;
                            return result;
                        }
                        if (key.first == key.index) continue;
                        const code: diagnostic.Code = if (rule(settings) == .err) .duplicate_attribute else .duplicate_attribute_tolerated;
                        if (rule(settings) == .err) {
                            result.errors += 1;
                            result.validity = .invalid;
                        } else result.warnings += 1;
                        const action = sink.emit(.{ .code = code, .span = document.attributes[key.index].name, .related = document.attributes[key.first].name }) catch |err| {
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
            const keys = allocator.alloc(AttributeKeyScratch, requiredScratch(document)) catch return unavailable(.out_of_memory, sink, 0);
            defer allocator.free(keys);
            return run(document, .{ .attribute_keys = keys }, sink, settings, hook);
        }
        fn nameLessThan(document: *const syntax.Document, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
            const order = std.mem.order(u8, document.attributes[a.index].name.slice(document.source), document.attributes[b.index].name.slice(document.source));
            return if (order == .eq) a.index < b.index else order == .lt;
        }
        fn indexLessThan(_: void, a: AttributeKeyScratch, b: AttributeKeyScratch) bool {
            return a.index < b.index;
        }
    };
}
