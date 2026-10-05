//! Local validation over recognizable source scopes, independent of tree balance.
//! No tree, nesting stack, syntax diagnostics, repairs or processor registry.
const std = @import("std");
const support = @import("parser_support");
const lexer = @import("lexer.zig");
const scopes = @import("scope.zig");
const policy = @import("policy.zig");
const diagnostic = @import("diagnostic.zig");
const validation = @import("validate.zig");
const Span = support.location.Span;
const Result = validation.Result;

pub const Scratch = struct {
    /// Reused for the largest opening header, not every element in the input.
    /// Needed only when duplicate checking is enabled.
    attributes: []scopes.Attribute = &.{},
    attribute_keys: []validation.AttributeKeyScratch = &.{},
};
pub fn FixedScratch(comptime capacity: u32) type {
    return struct {
        attributes: [capacity]scopes.Attribute = undefined,
        keys: [capacity]validation.AttributeKeyScratch = undefined,
        pub const byte_size = @sizeOf(@This());
        pub fn storage(self: *@This()) Scratch {
            return .{ .attributes = &self.attributes, .attribute_keys = &self.keys };
        }
    };
}

fn localSettings(settings: policy.ValidationSettings) policy.ValidationSettings {
    var local = settings;
    local.invalid_utf8 = .off; // Independent whole-source pass, once, before scopes.
    return local;
}

/// Internal workspace buffers shared by all scanner/policy variants. They own
/// no source and retain capacity only; reset logical attributes for each pass.
pub const Buffers = struct {
    allocator: ?std.mem.Allocator,
    attributes: std.ArrayList(scopes.Attribute),
    keys: std.ArrayList(validation.AttributeKeyScratch),
    pub fn init(storage: Scratch, allocator: ?std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .attributes = .{ .items = storage.attributes[0..0], .capacity = storage.attributes.len },
            .keys = .{ .items = storage.attribute_keys, .capacity = storage.attribute_keys.len },
        };
    }
    pub fn deinit(self: *@This()) void {
        if (self.allocator) |a| {
            self.attributes.deinit(a);
            self.keys.deinit(a);
        }
    }
    fn append(self: *@This(), attribute: scopes.Attribute) !void {
        if (self.attributes.items.len == self.attributes.capacity) {
            const a = self.allocator orelse return error.StorageExhausted;
            try self.attributes.ensureUnusedCapacity(a, 1);
        }
        self.attributes.appendAssumeCapacity(attribute);
    }
    fn prepare(self: *@This()) ![]validation.AttributeKeyScratch {
        const count = if (self.attributes.items.len >= 2) self.attributes.items.len else 0;
        if (count > self.keys.items.len) {
            const a = self.allocator orelse return error.StorageExhausted;
            try self.keys.resize(a, count);
        }
        return self.keys.items[0..count];
    }
};

pub fn Validator(comptime backend: policy.ScannerBackend, comptime fixed: ?policy.Effective, comptime cancellable: bool) type {
    const V = validation.Validator(if (fixed) |f| f.validation else null, cancellable);
    const Local = validation.Validator(if (fixed) |f| localSettings(f.validation) else null, cancellable);
    return struct {
        const Self = @This();
        pub const Settings = if (fixed == null) policy.Effective else void;
        pub const Hook = V.Hook;
        inline fn effective(settings: Settings) policy.Effective {
            return if (fixed) |f| f else settings;
        }
        const Driver = struct {
            source: []const u8,
            sink: diagnostic.Sink,
            settings: Settings,
            hook: Hook,
            result: Result = .{},
            buffers: Buffers,
            header: ?struct { start: u32, name: Span } = null,
            poller: V.Poller = .{},

            fn poll(self: *@This()) bool {
                return self.poller.step(&self.result, self.hook);
            }
            fn merge(self: *@This(), checked: Result) bool {
                self.result.errors += checked.errors;
                self.result.warnings += checked.warnings;
                if (checked.validity == .invalid) self.result.validity = .invalid;
                if (checked.diagnostic_delivery == .failed) self.result.diagnostic_delivery = .failed;
                switch (checked.completion) {
                    .complete => return true,
                    // The source walk owns gap locations: an incomplete header
                    // can be followed by a separately checked value prefix.
                    .incomplete => {
                        std.debug.assert(self.result.completion == .incomplete);
                        return true;
                    },
                    else => {
                        self.result.completion = checked.completion;
                        return false;
                    },
                }
            }
            // Expose the known scope at this small adapter boundary; an opaque
            // wrapper around the shared poller regresses dense short scopes.
            // Keep the validation kernels themselves under optimizer control.
            inline fn checkScope(self: *@This(), scope: scopes.Scope, keys: []validation.AttributeKeyScratch) bool {
                return self.merge(Local.runScopePolled(self.source, scope, .{ .attribute_keys = keys }, self.sink, if (fixed == null) localSettings(self.settings.validation) else {}, self.hook, &self.poller));
            }
            fn recordGap(self: *@This(), at: u32) void {
                const first = if (self.result.completion == .incomplete) @min(self.result.completion.incomplete, at) else at;
                self.result.completion = .{ .incomplete = first };
            }
            fn storageFailure(self: *@This(), err: anyerror, resource: diagnostic.Resource, at: Span, required: u32, available: u32) bool {
                const finding: diagnostic.Diagnostic = if (err == error.OutOfMemory)
                    .{ .code = .out_of_memory, .span = at }
                else
                    .{ .code = .capacity_exhausted, .span = at, .details = .{ .capacity = .{ .resource = resource, .limit = available } } };
                self.result.completion = if (err == error.OutOfMemory) .out_of_memory else .{ .storage_exhausted = required };
                // This is an already-terminal resource failure, not a validation
                // finding. Delivery failure cannot replace its original cause.
                _ = self.sink.emit(finding) catch {
                    self.result.diagnostic_delivery = .failed;
                };
                return false;
            }
            fn flush(self: *@This(), end: u32, complete: bool) bool {
                const h = self.header orelse return true;
                defer {
                    self.header = null;
                    self.buffers.attributes.clearRetainingCapacity();
                }
                if (effective(self.settings).validation.duplicate_attribute == .off) return true;
                const keys = self.buffers.prepare() catch |err|
                    return self.storageFailure(err, .attribute_keys, h.name, @intCast(self.buffers.attributes.items.len), @intCast(self.buffers.keys.items.len));
                return self.checkScope(.{ .opening_header = .{
                    .span = .{ .start = h.start, .len = end - h.start },
                    .name = h.name,
                    .attributes = self.buffers.attributes.items,
                    .complete = complete,
                } }, keys);
            }
            fn token(self: *@This(), t: lexer.Token) bool {
                switch (t.kind) {
                    .open, .empty => return self.checkScope(.{ .opening_header = .{ .span = t.span, .name = t.name } }, &.{}),
                    .open_head => {
                        self.header = .{ .start = t.span.start, .name = t.name };
                        if (effective(self.settings).validation.duplicate_attribute == .off)
                            return self.checkScope(.{ .opening_name = t.name }, &.{});
                    },
                    .attribute => {
                        if (effective(self.settings).validation.duplicate_attribute != .off) {
                            self.buffers.append(.{ .name = t.name, .value = t.span }) catch |err|
                                return self.storageFailure(err, .header_attributes, t.name, @as(u32, @intCast(self.buffers.attributes.items.len)) + 1, @intCast(self.buffers.attributes.capacity));
                        } else {
                            if (!self.checkScope(.{ .attribute_name = t.name }, &.{})) return false;
                            return self.checkScope(.{ .attribute_value = .{ .start = t.span.start + 1, .len = t.span.len - 2 } }, &.{});
                        }
                    },
                    .head_end, .empty_end => return self.flush(@intCast(t.span.endOffset()), true),
                    // Like retained validation, check an element's opening name
                    // once. Matching/mismatched closers belong to syntax; callers
                    // can still request an explicit closing_name scope check.
                    .close => {},
                    .text => return self.checkScope(.{ .text = t.span }, &.{}),
                    .comment, .cdata, .eof => {},
                }
                return true;
            }
            fn finish(self: *@This()) Result {
                const gaps = self.result.completion == .incomplete;
                inline for (.{ "duplicate_attribute", "names", "references" }) |name| {
                    if (@field(self.result.checks, name) != .not_run)
                        @field(self.result.checks, name) = if (gaps) .incomplete else .complete;
                }
                if (!gaps and self.result.errors == 0) self.result.validity = .valid;
                return self.result;
            }
            fn run(self: *@This()) Result {
                const p = effective(self.settings);
                self.result.checks = .{
                    .duplicate_attribute = if (p.validation.duplicate_attribute == .off) .not_run else .incomplete,
                    .invalid_utf8 = if (p.validation.invalid_utf8 == .off) .not_run else .incomplete,
                    .names = if (p.validation.names.severity == .off) .not_run else .incomplete,
                    .references = if (p.validation.references.severity == .off) .not_run else .incomplete,
                };
                if (self.source.len > p.limits.max_source_bytes) {
                    self.result.completion = .{ .source_limit = p.limits.max_source_bytes };
                    _ = self.sink.emit(.{ .code = .capacity_exhausted, .span = .{ .start = 0, .len = 0 }, .details = .{ .capacity = .{ .resource = .source_bytes, .limit = p.limits.max_source_bytes } } }) catch {
                        self.result.diagnostic_delivery = .failed;
                    };
                    return self.result;
                }
                // Encoding has no lexical prerequisites, so even a terminal
                // malformed header cannot hide invalid bytes elsewhere.
                const encoded = V.runScopePolled(self.source, .{ .bytes = .{ .start = 0, .len = @intCast(self.source.len) } }, .{}, self.sink, if (fixed == null) self.settings.validation else {}, self.hook, &self.poller);
                self.result.checks.invalid_utf8 = encoded.checks.invalid_utf8;
                if (!self.merge(encoded)) return self.result;
                if (p.validation.duplicate_attribute == .off and p.validation.names.severity == .off and p.validation.references.severity == .off)
                    return self.finish();
                var scanner = lexer.Scanner(backend, false, cancellable).init(self.source);
                while (true) {
                    if (!self.poll()) return self.result;
                    if (!scanner.stepReady()) continue;
                    switch (scanner.ready) {
                        .token => |t| {
                            if (!self.token(t)) return self.result;
                            if (t.kind == .eof) return self.finish();
                        },
                        .malformed_reference => {}, // syntax belongs to parsing
                        .unsupported => |u| {
                            // Encoding/prefix boundaries occur outside any
                            // pending name/value/header; prior tokens are flushed.
                            self.recordGap(u.span.start);
                            return self.finish();
                        },
                        .problem => |problem| {
                            self.recordGap(problem.diagnostic.span.start);
                            const pending = scanner.pendingScopes();
                            if (if (pending.name_kind == .closing) null else pending.name) |name| {
                                if (pending.name_kind == .attribute and p.validation.duplicate_attribute != .off) {
                                    std.debug.assert(self.header != null);
                                    self.buffers.append(.{ .name = name }) catch |err| {
                                        _ = self.storageFailure(err, .header_attributes, name, @as(u32, @intCast(self.buffers.attributes.items.len)) + 1, @intCast(self.buffers.attributes.capacity));
                                        return self.result;
                                    };
                                } else {
                                    const scope: scopes.Scope = switch (pending.name_kind) {
                                        .opening => .{ .opening_name = name },
                                        .closing => .{ .closing_name = name },
                                        .attribute => .{ .attribute_name = name },
                                    };
                                    if (!self.checkScope(scope, &.{})) return self.result;
                                }
                            }
                            if (!self.flush(scanner.offset, false)) return self.result;
                            if (pending.content) |content| {
                                if (!self.checkScope(if (pending.content_kind == .text) .{ .text = content } else .{ .attribute_value = content }, &.{})) return self.result;
                            }
                            // This operation checks local content, not syntax.
                            // A lexical gap is not a second syntax finding. Seek
                            // later trustworthy scopes even in fail-fast validation.
                            if (!scanner.canRecoverHeader()) return self.finish();
                            var cursor: lexer.HeaderRecovery = .unquoted;
                            while (true) {
                                if (!self.poll()) return self.result;
                                switch (scanner.recoverHeaderStep(&cursor)) {
                                    .pending => {},
                                    .open, .empty => break,
                                    .blocked => return self.finish(),
                                }
                            }
                        },
                    }
                }
            }
        };
        pub fn run(source: []const u8, storage: Scratch, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            var driver: Driver = .{ .source = source, .sink = sink, .settings = settings, .hook = hook, .buffers = .init(storage, null) };
            return driver.run();
        }
        pub fn allocated(allocator: std.mem.Allocator, source: []const u8, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            var driver: Driver = .{ .source = source, .sink = sink, .settings = settings, .hook = hook, .buffers = .init(.{}, allocator) };
            defer driver.buffers.deinit();
            return driver.run();
        }
        pub fn reusing(source: []const u8, buffers: *Buffers, sink: diagnostic.Sink, settings: Settings, hook: Hook) Result {
            buffers.attributes.clearRetainingCapacity();
            var driver: Driver = .{ .source = source, .sink = sink, .settings = settings, .hook = hook, .buffers = buffers.* };
            defer buffers.* = driver.buffers;
            return driver.run();
        }
    };
}
