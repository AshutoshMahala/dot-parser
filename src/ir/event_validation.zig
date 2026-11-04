//! DOT checks over committed event groups. No Document or retained finding log.
const std = @import("std");
const support = @import("parser_support");
const enc = support.encoding;
const syntax = @import("../dot/syntax.zig");
const policy = @import("../dot/policy.zig");
const diagnostic = @import("../dot/diagnostic.zig");
const checks = @import("../dot/validation_checks.zig");
const r = @import("resources.zig");
const Span = support.location.Span;
const D = diagnostic.Diagnostic;
const Entry = checks.AttributeKeyScratch;
const none = std.math.maxInt(u32);
pub const Stop = error{ValidationStopped};

pub fn Checker(comptime actual: enc.Actual, comptime fixed: ?policy.ValidationSettings) type {
    return struct {
        const Self = @This();
        source: []const u8,
        runtime_settings: if (fixed == null) policy.ValidationSettings else void,
        sink: diagnostic.Sink,
        errors: u64 = 0,
        warnings: u64 = 0,
        delivery: diagnostic.Delivery = .complete,
        stop: ?diagnostic.StopReason = null,
        error_stopped: bool = false,
        entries: std.ArrayList(Entry) = .empty,

        pub inline fn settings(self: *const Self) policy.ValidationSettings {
            return fixed orelse self.runtime_settings;
        }

        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            self.entries.deinit(a);
        }
        pub fn emit(self: *Self, d: D) Stop!void {
            if (d.code.severity() == .err) self.errors += 1 else self.warnings += 1;
            const action = self.sink.emit(d.withFixes(self.settings().fixes)) catch |err| {
                self.delivery = .failed;
                self.stop = .fromError(err);
                return error.ValidationStopped;
            };
            if (action == .stop) {
                self.stop = .requested;
                return error.ValidationStopped;
            }
            if (d.code.severity() == .err and self.settings().on_error == .fail_fast) {
                self.error_stopped = true;
                return error.ValidationStopped;
            }
        }
        pub fn result(self: *const Self) @import("../dot/validate.zig").Result {
            return .{
                .outcome = if (self.stop) |s| .{ .diagnostic_stopped = .{ .reason = s, .violations = self.errors, .warnings = self.warnings } } else if (self.error_stopped) .{ .error_stopped = .{ .violations = self.errors, .warnings = self.warnings } } else .{ .completed = .{ .document_valid = self.errors == 0, .violations = self.errors, .warnings = self.warnings } },
                .diagnostic_delivery = self.delivery,
                .diagnostic_stop = self.stop,
            };
        }
        pub inline fn operator(self: *Self, declared: syntax.GraphKind, keyword: Span, written: syntax.EdgeOperator, span: Span) Stop!void {
            if (checks.operatorFinding(declared, keyword, self.settings(), written, span)) |d| try self.emit(d);
        }
        pub inline fn restriction(self: *Self, severity: policy.RuleSeverity, span: Span, kind: @FieldType(diagnostic.Details, "restriction")) Stop!void {
            if (severity != .off) try self.emit(checks.restricted(severity, span, kind));
        }
        pub fn graphKind(self: *Self, kind: policy.GraphKind, span: Span) Stop!void {
            switch (kind) {
                .digraph => try self.restriction(self.settings().restrictions.graph_kinds.digraph, span, .digraph),
                .undigraph => try self.restriction(self.settings().restrictions.graph_kinds.undigraph, span, .undigraph),
                .generic => try self.restriction(self.settings().restrictions.graph_kinds.generic, span, .generic),
            }
        }
        pub fn attributes(self: *Self, a: std.mem.Allocator, group: []const syntax.Attribute, work: *r.Work) (r.Error || Stop)!void {
            if (self.settings().graphviz.unknown_attribute != .off) for (group) |attr| {
                try work.spend(attr.key.len);
                const d = checks.catalogFinding(actual, self.source, attr.key, self.settings().graphviz.unknown_attribute);
                try work.spend(0);
                if (d) |finding| try self.emit(finding);
            };
            if (self.settings().repeated_attribute == .off or group.len < 2) return;
            try work.spend(self.entries.items.len);
            try self.entries.resize(a, group.len);
            const values = @import("../dot/identifier_value.zig").ForEncoding(actual);
            for (group, self.entries.items, 0..) |attr, *entry, i| {
                try work.spend(attr.key.len);
                entry.* = .{ .hash = values.hashAssumeValid(attr.key.slice(self.source)), .index = @intCast(i), .first = none };
            }
            // In-place heapsort, with fallible comparisons. Hash collisions use
            // logical name order, so hostile keys cannot force a quadratic pass.
            try self.sort(group, work, false);
            var first = self.entries.items[0];
            for (self.entries.items[1..]) |*entry| {
                if (first.hash == entry.hash and try self.order(group, first.index, entry.index, work) == .eq) entry.first = first.index else first = entry.*;
            }
            try self.sort(group, work, true);
            for (self.entries.items) |entry| {
                try work.spend(1);
                if (entry.first != none) try self.emit(.{
                    .code = checks.severityCode(self.settings().repeated_attribute, .validation_repeated_attribute, .validation_repeated_attribute_tolerated),
                    .span = group[entry.index].key,
                    .details = .{ .repeated_attribute = group[entry.first].key },
                });
            }
        }
        fn order(self: *Self, group: []const syntax.Attribute, left: u32, right: u32, work: *r.Work) r.Error!std.math.Order {
            const l = group[left].key.slice(self.source);
            const rr = group[right].key.slice(self.source);
            try work.spend(@as(u64, l.len) + rr.len);
            const value = @import("../dot/identifier_value.zig").ForEncoding(actual).orderAssumeValid(l, rr);
            try work.spend(0);
            return value;
        }
        fn less(self: *Self, group: []const syntax.Attribute, l: Entry, rr: Entry, work: *r.Work, by_index: bool) r.Error!bool {
            try work.spend(1);
            if (by_index) return l.index < rr.index;
            if (l.hash != rr.hash) return l.hash < rr.hash;
            const cmp = try self.order(group, l.index, rr.index, work);
            return if (cmp == .eq) l.index < rr.index else cmp == .lt;
        }
        fn sift(self: *Self, group: []const syntax.Attribute, start: usize, end: usize, work: *r.Work, by_index: bool) r.Error!void {
            var root = start;
            while (root < end / 2) {
                var child = root * 2 + 1;
                if (child + 1 < end and try self.less(group, self.entries.items[child], self.entries.items[child + 1], work, by_index)) child += 1;
                if (!try self.less(group, self.entries.items[root], self.entries.items[child], work, by_index)) break;
                std.mem.swap(Entry, &self.entries.items[root], &self.entries.items[child]);
                root = child;
            }
        }
        fn sort(self: *Self, group: []const syntax.Attribute, work: *r.Work, by_index: bool) r.Error!void {
            var i = self.entries.items.len / 2;
            while (i > 0) {
                i -= 1;
                try self.sift(group, i, self.entries.items.len, work, by_index);
            }
            var end = self.entries.items.len;
            while (end > 1) {
                end -= 1;
                std.mem.swap(Entry, &self.entries.items[0], &self.entries.items[end]);
                try self.sift(group, 0, end, work, by_index);
            }
        }
        /// Whole-source encoding ownership matches DOT validation: markup
        /// bodies are excluded, wrappers and concatenation glue are checked.
        pub fn encoding(self: *Self, work: *r.Work) (r.Error || Stop)!void {
            if (self.settings().invalid_encoding == .off) return;
            const Scanner = @import("../dot/lexer/lexer.zig").scannerForEncoding(actual, .scalar, false)(false, false, false);
            var scanner = Scanner.init(self.source);
            var checked: u32 = 0;
            while (true) {
                try work.spend(1);
                const progress = scanner.drive(true, 1);
                const token = progress.result orelse continue;
                switch (token) {
                    .failure => switch (scanner.terminal) {
                        .oversize, .none, .eof => break,
                        else => scanner.resumeAfterFailure(),
                    },
                    .token => |value| {
                        if (value.tag == .eof) break;
                        if (!value.flags.has_html) continue;
                        var parts: @import("../dot/identifier_parts.zig").ForEncoding(actual).Parts = .{
                            .input = .{ .bytes = value.span.slice(self.source), .origin = value.span.start },
                            .compound = value.flags.concatenated,
                        };
                        while (try parts.nextWith(work)) |part| if (part.form == .html) {
                            try self.encodingRange(&checked, part.inner.start, work);
                            checked = part.inner.start + part.inner.len;
                        };
                    },
                }
            }
            try self.encodingRange(&checked, @intCast(self.source.len), work);
        }
        fn encodingRange(self: *Self, at: *u32, end: u32, work: *r.Work) (r.Error || Stop)!void {
            while (at.* < end) {
                try work.spend(1);
                const start = at.*;
                const step = enc.validationStep(actual, self.source[0..end], start);
                at.* += step.len;
                if (step.invalid) |bad| try self.emit(.{ .code = checks.severityCode(self.settings().invalid_encoding, .validation_invalid_encoding, .validation_invalid_encoding_tolerated), .span = .{ .start = start, .len = enc.Reader(actual).width }, .details = .{ .invalid_encoding = bad } });
            }
        }
    };
}
