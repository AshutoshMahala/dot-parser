//! Opt-in native source selection, outside DOT/markup execution loops.
const std = @import("std");
const support = @import("parser_support");
const enc = support.encoding;
const dispatch = support.source_dispatch;
const profile = @import("profile.zig");
const policy = @import("policy.zig");

pub fn Profile(comptime api: type, comptime config: policy.Config, comptime caps: enc.Capabilities) type {
    @setEvalBranchQuota(10000);
    const Base = profile.ProfileForEncoding(.utf8, api, config);
    if (config.processors.markup != null) return Composition(api, config, caps, Base);
    return struct {
        pub const declared_source_encodings = config.source_encodings;
        pub const source_capabilities = caps;
        pub const inspectSource = enc.Inspector(caps).inspect;
        pub const Policies = Base.Policies;
        pub const baseline = Base.baseline;
        pub const runtime_policy = config.runtime_policy;
        pub fn Events(comptime Sink: type) type {
            return @import("event_profile.zig").Source(api, config, caps, Sink);
        }
        pub const validatePolicy = Base.validatePolicy;
        pub const Options = Base.Options;
        pub const ParseOptions = dispatch.Options(Base.ParseOptions);
        pub const FixedParseOptions = dispatch.Options(Base.FixedParseOptions);
        pub const CheckOptions = dispatch.Options(Base.CheckOptions);
        pub const ValidationOptions = Base.ValidationOptions;
        pub const Interpretation = Base.Interpretation;
        pub const Error = enc.InputError || (if (config.runtime_policy) policy.Error else error{});

        fn ready(options: anytype) Error!Policies.State {
            return if (config.runtime_policy) try Policies.prepare(.{ .policy = options.policy }) else {};
        }
        fn call(comptime method: []const u8, comptime Result: type, source: []const u8, arguments: anytype, options: anytype) Error!Result {
            // Configuration errors precede source reading and callbacks.
            const effective = try ready(options);
            const cancellation = if (config.runtime_policy) (if (effective.execution.cancellation) options.cancellation else null) else options.cancellation;
            const info = try enc.select(caps, source, options.encoding);
            switch (info.encoding) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    if (actual != .utf8) try dispatch.checkCancellation(cancellation);
                    const W = profile.ProfileForEncoding(actual, api, config);
                    const Opt = comptime if (std.mem.eql(u8, method, "parseAndValidate")) W.CheckOptions else if (std.mem.eql(u8, method, "parseBorrowedIn") or std.mem.eql(u8, method, "measureIn")) W.FixedParseOptions else W.ParseOptions;
                    const called = @call(.auto, @field(W, method), arguments ++ .{dispatch.options(Opt, options)});
                    var result: Result = if (@typeInfo(@TypeOf(called)) == .error_union) try called else called;
                    if (@hasField(Result, "document")) dispatch.stamp(&result, info);
                    return result;
                } else return error.UnsupportedEncoding,
            }
        }
        pub fn parseBorrowed(allocator: std.mem.Allocator, source: []const u8, sink: api.DiagnosticSink, options: ParseOptions) Error!api.ParseResult {
            return call("parseBorrowed", api.ParseResult, source, .{ allocator, source, sink }, options);
        }
        pub fn parseBorrowedIn(source: []const u8, memory: api.ParseMemory, sink: api.DiagnosticSink, options: FixedParseOptions) Error!api.FixedParseResult {
            return call("parseBorrowedIn", api.FixedParseResult, source, .{ source, memory, sink }, options);
        }
        pub fn measure(allocator: std.mem.Allocator, source: []const u8, sink: api.DiagnosticSink, options: ParseOptions) Error!api.MeasureResult {
            return call("measure", api.MeasureResult, source, .{ allocator, source, sink }, options);
        }
        pub fn measureIn(source: []const u8, scratch: api.ParseScratch, sink: api.DiagnosticSink, options: FixedParseOptions) Error!api.MeasureResult {
            return call("measureIn", api.MeasureResult, source, .{ source, scratch, sink }, options);
        }
        pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8, sink: api.DiagnosticSink, options: CheckOptions) Error!api.CheckResult {
            return call("parseAndValidate", api.CheckResult, source, .{ allocator, source, sink }, options);
        }
        pub fn validate(document: *const api.Document, sink: api.DiagnosticSink, options: ValidationOptions) Error!api.ValidationResult {
            _ = try ready(options);
            switch (document.source_info.encoding) {
                inline else => |selected| if (comptime caps.allows(selected)) {
                    const W = profile.ProfileForEncoding(selected, api, config);
                    const value = W.validate(document, sink, options);
                    return if (config.runtime_policy) try value else value;
                } else return error.UnsupportedEncoding,
            }
        }
        pub fn interpretation(document: *const api.Document, options: Options) (if (config.runtime_policy) policy.Error!Interpretation else Interpretation) {
            return Base.interpretation(document, options);
        }
    };
}

fn Composition(comptime api: type, comptime config: policy.Config, comptime caps: enc.Capabilities, comptime Base: type) type {
    return struct {
        pub const declared_source_encodings = config.source_encodings;
        pub const source_capabilities = caps;
        pub const inspectSource = enc.Inspector(caps).inspect;
        pub const Policies = Base.Policies;
        pub const baseline = Base.baseline;
        pub const runtime_policy = config.runtime_policy;
        pub const Diagnostic = Base.Diagnostic;
        pub const DiagnosticSink = Base.DiagnosticSink;
        pub const GrowableDiagnosticBag = Base.GrowableDiagnosticBag;
        pub const FixedDiagnosticBag = Base.FixedDiagnosticBag;
        pub const PrefixDiagnosticBag = Base.PrefixDiagnosticBag;
        pub const CheckResult = Base.CheckResult;
        pub const MarkupResult = Base.MarkupResult;
        pub const MarkupReport = Base.MarkupReport;
        pub const console = Base.console;
        pub const CheckOptions = dispatch.Options(Base.CheckOptions);
        pub const MarkupOptions = Base.MarkupOptions;
        pub const SelectionError = Base.SelectionError;
        pub const Error = Base.Error || enc.InputError;

        pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8, sink: DiagnosticSink, options: CheckOptions) Error!CheckResult {
            const preparing = Policies.prepare(dispatch.options(Policies.Options, options));
            const prepared = if (@typeInfo(@TypeOf(preparing)) == .error_union) try preparing else preparing;
            const cancellation = if (config.runtime_policy) (if (prepared.dot.execution.cancellation) options.dot.cancellation else null) else options.dot.cancellation;
            const info = try enc.select(caps, source, options.encoding);
            switch (info.encoding) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    if (actual != .utf8) try dispatch.checkCancellation(cancellation);
                    const W = profile.ProfileForEncoding(actual, api, config);
                    var result = try W.parseAndValidate(allocator, source, sink, dispatch.options(W.CheckOptions, options));
                    dispatch.stamp(&result, info);
                    return result;
                } else return error.UnsupportedEncoding,
            }
        }
        pub fn processPendingMarkup(allocator: std.mem.Allocator, result: *CheckResult, sink: DiagnosticSink, options: MarkupOptions) (Base.SelectionError || Error)!void {
            const document = result.dot.document orelse return error.DocumentUnavailable;
            switch (document.source_info.encoding) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    const W = profile.ProfileForEncoding(actual, api, config);
                    return W.processPendingMarkup(allocator, result, sink, dispatch.options(W.MarkupOptions, options));
                } else return error.UnsupportedEncoding,
            }
        }
    };
}
