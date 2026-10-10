//! Opt-in native source facade. Default UTF-8 uses the original direct profile.
const std = @import("std");
const support = @import("parser_support");
const enc = support.encoding;
const dispatch = support.source_dispatch;
const profile = @import("profile.zig");
const policy = @import("policy.zig");

pub fn Profile(comptime api: type, comptime config: policy.Config, comptime caps: enc.Capabilities) type {
    @setEvalBranchQuota(10000);
    const Base = profile.ProfileForEncoding(.utf8, api, config);
    return struct {
        const Self = @This();
        pub const declared_source_encodings = config.source_encodings;
        pub const source_capabilities = caps;
        pub const Policies = Base.Policies;
        pub const baseline = Base.baseline;
        pub const runtime_policy = config.runtime_policy;
        pub const validatePolicy = Base.validatePolicy;
        pub const Diagnostic = api.Diagnostic;
        pub const DiagnosticSink = api.DiagnosticSink;
        pub const CheckResult = api.FragmentResult;
        pub const InputError = api.Fragment.Error || enc.InputError;
        pub const ParseResources = api.ParseResources;
        pub const console = api.console;
        pub const Options = dispatch.Options(Base.Options);
        pub const ParseOptions = dispatch.Options(Base.ParseOptions);
        pub fn withSourceEncodings(comptime capabilities: enc.Capabilities) type {
            var bound = config;
            bound.source_encodings = capabilities.list();
            return api.Profile(bound);
        }
        pub fn forSourceEncoding(comptime actual: enc.Actual) type {
            return Base.forSourceEncoding(actual);
        }
        fn worker(comptime actual: enc.Actual) type {
            return profile.ProfileForEncoding(actual, api, config);
        }

        pub const Prepared = struct {
            policies: Base.Policies.State,
            cancellation: @FieldType(Base.Prepared, "cancellation") = if (@FieldType(Base.Prepared, "cancellation") == void) {} else null,
            encoding: ?enc.Actual = null,
            fn admissionHook(self: @This()) @FieldType(Base.Prepared, "cancellation") {
                if (config.runtime_policy) return if (self.policies.execution.cancellation) self.cancellation else null;
                return self.cancellation;
            }
            pub fn initWorkspace(self: @This(), allocator: std.mem.Allocator, resources: api.ParseResources) Workspace {
                const ready: Base.Prepared = .{ .policies = self.policies, .cancellation = self.cancellation };
                return .{ .base = ready.initWorkspace(allocator, resources), .encoding = self.encoding };
            }
            pub fn parseAndValidate(self: @This(), allocator: std.mem.Allocator, input: api.Fragment, sink: api.DiagnosticSink, resources: api.ParseResources) InputError!api.FragmentResult {
                const info = try enc.select(caps, input.bytes, self.encoding);
                switch (info.encoding) {
                    inline else => |actual| if (comptime caps.allows(actual)) {
                        try dispatch.checkControlled(actual, input.bytes, self.admissionHook());
                        const W = worker(actual);
                        const ready: W.Prepared = .{ .policies = self.policies, .cancellation = self.cancellation };
                        var result = try ready.parseAndValidate(allocator, input, sink, resources);
                        dispatch.stamp(&result, info);
                        return result;
                    } else return error.UnsupportedEncoding,
                }
            }
            pub fn parseAndValidateIn(self: @This(), input: api.Fragment, memory: api.ParseMemory, scratch: api.SourceValidationScratch, sink: api.DiagnosticSink) InputError!api.FixedFragmentResult {
                const info = try enc.select(caps, input.bytes, self.encoding);
                switch (info.encoding) {
                    inline else => |actual| if (comptime caps.allows(actual)) {
                        try dispatch.checkControlled(actual, input.bytes, self.admissionHook());
                        const W = worker(actual);
                        const ready: W.Prepared = .{ .policies = self.policies, .cancellation = self.cancellation };
                        var result = try ready.parseAndValidateIn(input, memory, scratch, sink);
                        dispatch.stamp(&result, info);
                        return result;
                    } else return error.UnsupportedEncoding,
                }
            }
        };
        pub const Workspace = struct {
            base: Base.Workspace,
            encoding: ?enc.Actual,
            pub fn parseAndValidate(self: *@This(), input: api.Fragment, sink: api.DiagnosticSink) InputError!api.FixedFragmentResult {
                const info = try enc.select(caps, input.bytes, self.encoding);
                switch (info.encoding) {
                    inline else => |actual| if (comptime caps.allows(actual)) {
                        const cancellation = if (config.runtime_policy) (if (self.base.prepared.policies.execution.cancellation) self.base.prepared.cancellation else null) else self.base.prepared.cancellation;
                        try dispatch.checkControlled(actual, input.bytes, cancellation);
                        const W = worker(actual);
                        // Move the same buffers through the selected worker. No
                        // extra pool, duplicate ownership or per-encoding cache.
                        var workspace: W.Workspace = .{
                            .prepared = .{ .policies = self.base.prepared.policies, .cancellation = self.base.prepared.cancellation },
                            .allocator = self.base.allocator,
                            .builder = self.base.builder,
                            .stack = self.base.stack,
                            .buffers = self.base.buffers,
                        };
                        defer {
                            self.base.builder = workspace.builder;
                            self.base.stack = workspace.stack;
                            self.base.buffers = workspace.buffers;
                        }
                        var result = try workspace.parseAndValidate(input, sink);
                        dispatch.stamp(&result, info);
                        return result;
                    } else return error.UnsupportedEncoding,
                }
            }
            pub fn reservedBytes(self: *const @This()) usize {
                return self.base.reservedBytes();
            }
            pub fn deinit(self: *@This()) void {
                self.base.deinit();
                self.* = undefined;
            }
        };
        pub fn prepare(options: Options) Prepared {
            const ready = Base.prepare(dispatch.options(Base.Options, options));
            return .{ .policies = ready.policies, .cancellation = ready.cancellation, .encoding = options.encoding };
        }
        pub fn parseAndValidate(allocator: std.mem.Allocator, input: api.Fragment, sink: api.DiagnosticSink, options: ParseOptions) InputError!api.FragmentResult {
            return prepare(dispatch.options(Options, options)).parseAndValidate(allocator, input, sink, .{ .scratch_allocator = options.scratch_allocator });
        }
        pub fn parseAndValidateIn(input: api.Fragment, memory: api.ParseMemory, scratch: api.SourceValidationScratch, sink: api.DiagnosticSink, options: Options) InputError!api.FixedFragmentResult {
            return prepare(options).parseAndValidateIn(input, memory, scratch, sink);
        }

        fn call(comptime method: []const u8, comptime Result: type, source: []const u8, arguments: anytype, options: anytype) enc.InputError!Result {
            const prepared = prepare(dispatch.options(Options, options));
            const info = try enc.select(caps, source, options.encoding);
            switch (info.encoding) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    if (comptime std.mem.startsWith(u8, method, "validateScope")) {
                        const scope = if (comptime std.mem.eql(u8, method, "validateScope")) arguments[2] else arguments[1];
                        if (!@import("scope.zig").metadataValidForEncoding(actual, source, scope, {})) return .{ .completion = .invalid_scope };
                    }
                    try dispatch.checkControlled(actual, source, prepared.admissionHook());
                    const W = worker(actual);
                    const Opt = comptime if (std.mem.eql(u8, method, "parseBorrowed")) W.ParseOptions else W.Options;
                    var result: Result = @call(.auto, @field(W, method), arguments ++ .{dispatch.options(Opt, options)});
                    if (@hasField(Result, "document")) dispatch.stamp(&result, info);
                    return result;
                } else return error.UnsupportedEncoding,
            }
        }
        pub fn parseBorrowed(allocator: std.mem.Allocator, source: []const u8, sink: api.DiagnosticSink, options: ParseOptions) enc.InputError!api.ParseResult {
            return call("parseBorrowed", api.ParseResult, source, .{ allocator, source, sink }, options);
        }
        pub fn parseBorrowedIn(source: []const u8, memory: api.ParseMemory, sink: api.DiagnosticSink, options: Options) enc.InputError!api.FixedParseResult {
            return call("parseBorrowedIn", api.FixedParseResult, source, .{ source, memory, sink }, options);
        }
        pub fn measure(allocator: std.mem.Allocator, source: []const u8, sink: api.DiagnosticSink, options: Options) enc.InputError!api.Report {
            return call("measure", api.Report, source, .{ allocator, source, sink }, options);
        }
        pub fn measureIn(source: []const u8, scratch: api.ParseScratch, sink: api.DiagnosticSink, options: Options) enc.InputError!api.Report {
            return call("measureIn", api.Report, source, .{ source, scratch, sink }, options);
        }
        pub fn validate(allocator: std.mem.Allocator, document: *const api.Document, sink: api.DiagnosticSink, options: Options) enc.InputError!api.ValidationResult {
            var selected = options;
            selected.encoding = document.source_info.encoding;
            return call("validate", api.ValidationResult, document.source, .{ allocator, document, sink }, selected);
        }
        pub fn validateIn(document: *const api.Document, scratch: api.ValidationScratch, sink: api.DiagnosticSink, options: Options) enc.InputError!api.ValidationResult {
            var selected = options;
            selected.encoding = document.source_info.encoding;
            return call("validateIn", api.ValidationResult, document.source, .{ document, scratch, sink }, selected);
        }
        pub fn validateScope(allocator: std.mem.Allocator, source: []const u8, scope: api.ValidationScope, sink: api.DiagnosticSink, options: Options) enc.InputError!api.ValidationResult {
            return call("validateScope", api.ValidationResult, source, .{ allocator, source, scope, sink }, options);
        }
        pub fn validateScopeIn(source: []const u8, scope: api.ValidationScope, scratch: api.ValidationScratch, sink: api.DiagnosticSink, options: Options) enc.InputError!api.ValidationResult {
            return call("validateScopeIn", api.ValidationResult, source, .{ source, scope, scratch, sink }, options);
        }
        pub fn validateSource(allocator: std.mem.Allocator, source: []const u8, sink: api.DiagnosticSink, options: Options) enc.InputError!api.ValidationResult {
            return call("validateSource", api.ValidationResult, source, .{ allocator, source, sink }, options);
        }
        pub fn validateSourceIn(source: []const u8, scratch: api.SourceValidationScratch, sink: api.DiagnosticSink, options: Options) enc.InputError!api.ValidationResult {
            return call("validateSourceIn", api.ValidationResult, source, .{ source, scratch, sink }, options);
        }
    };
}
