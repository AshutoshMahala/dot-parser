//! Opt-in retained-attribute routing. Ordinary parsers never instantiate this.
const std = @import("std");
const support = @import("parser_support");
const routing = support.string_routing;
const policy = @import("policy.zig");
const logical = @import("logical.zig");

pub fn Profile(comptime api: type, comptime config: anytype, comptime base_config: policy.Config) type {
    const Routes = routing.Routes(config);
    comptime Routes.checkNames(false);
    const RawChild = routing.child(config);
    if (Routes.processing and RawChild == void) @compileError(".process requires .processors.string");
    const caps = support.encoding.Capabilities.bound(support.encoding.Capabilities.from(base_config.source_encodings), if (RawChild != void) RawChild.declared_source_encodings else null);
    const host_config = blk: {
        var c = base_config;
        c.source_encodings = caps.list();
        break :blk c;
    };
    const Host = @import("profile.zig").Profile(api, host_config);
    const Child = if (RawChild != void) RawChild.withSourceEncodings(Host.source_capabilities) else void;
    const composed = base_config.processors.markup != null;
    const HostDiagnostic = if (composed) Host.Diagnostic else api.Diagnostic;
    const T = routing.Transport(HostDiagnostic, if (Child != void) Child.Diagnostic else api.Diagnostic);
    const HostResult = if (composed) Host.CheckResult else api.CheckResult;
    return struct {
        /// Existing host API. If markup is bound this is that composition;
        /// otherwise it retains the ordinary DOT parsing/session surface.
        pub const Outer = Host;
        pub const source_capabilities = Host.source_capabilities;
        pub const inspectSource = Host.inspectSource;
        pub const Diagnostic = T.Diagnostic;
        pub const DiagnosticSink = T.Sink;
        pub const GrowableDiagnosticBag = T.GrowableDiagnosticBag;
        pub const FixedDiagnosticBag = T.FixedDiagnosticBag;
        pub const console = support.console.ComposedRenderer(Diagnostic, .{
            .host = (if (composed) Host.console else api.console).Adapter,
            .string = (if (Child != void) Child.console else api.console).Adapter,
        });
        pub const Options = struct {
            dot: Host.CheckOptions = .{},
            string: routing.Options(Child, Routes) = if (Child != void) .{} else {},
        };
        pub const CheckOptions = Options;
        pub const CheckResult = struct {
            host: HostResult,
            string: routing.Report = .{},
            pub fn documentValid(self: *const @This()) bool {
                return self.host.documentValid() and self.string.valid();
            }
            pub fn scopeComplete(self: *const @This()) bool {
                const d = if (composed) self.host.dot.document else self.host.document;
                return if (d) |doc| doc.scopeComplete() else false;
            }
            pub fn subtreeComplete(self: *const @This()) bool {
                return self.scopeComplete() and self.string.complete and self.string.unavailable == 0 and
                    (!composed or self.host.subtreeComplete());
            }
            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.host.deinit(allocator);
                self.* = undefined;
            }
        };
        fn childOptions(comptime P: type, options: Options) P.Options {
            return .{
                .encoding = null,
                .policy = options.string.policy,
                .cancellation = if (@FieldType(P.Options, "cancellation") == void) {} else options.string.cancellation,
            };
        }
        fn preflight(options: Options) !void {
            inline for (0..Routes.count) |i| if (comptime Routes.mode(i) == .process) {
                const P = Routes.Processor(Child, i);
                if (P.Policies.runtime_policy) _ = try P.Policies.prepare(.{ .policy = options.string.policy });
            };
        }
        fn effective(options: Options) !policy.Effective {
            const B = if (composed) support.processor.PolicyBinding(policy.Schema(true, true), .{ .policy = base_config.policy, .runtime_policy = base_config.runtime_policy }) else Host.Policies;
            if (!base_config.runtime_policy) return B.baseline;
            const opts = if (composed) options.dot.dot else options.dot;
            return try B.prepare(.{ .policy = opts.policy });
        }
        pub fn parseAndValidate(allocator: std.mem.Allocator, source: []const u8, sink: DiagnosticSink, options: Options) !CheckResult {
            try preflight(options);
            const settings = try effective(options);
            var transport: T = .{ .sink = sink };
            const call = Host.parseAndValidate(allocator, source, transport.hostSink(), options.dot);
            var host = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call;
            errdefer host.deinit(allocator);
            const dot_result = if (composed) host.dot else host;
            const allowed = dot_result.diagnostic_stop == null and dot_result.diagnostic_delivery == .complete and
                (dot_result.outcome == .success or (dot_result.outcome == .invalid_syntax and settings.parsing.on_error == .collect)) and
                (settings.parsing.on_error == .collect or host.documentValid()) and
                (!composed or host.markup.stop == null);
            const report = if (allowed and dot_result.document != null)
                try processDocument(&dot_result.document.?, sink, options)
            else
                routing.Report{};
            return .{ .host = host, .string = report };
        }
        /// Explicit delayed checking. It never modifies or owns the document.
        /// Partial trees check retained attributes but cannot certify the tail.
        pub fn processStrings(document: *const api.Document, sink: DiagnosticSink, options: Options) !routing.Report {
            try preflight(options);
            return processDocument(document, sink, options);
        }
        fn processDocument(document: *const api.Document, sink: DiagnosticSink, options: Options) !routing.Report {
            const settings = try effective(options);
            var transport: T = .{ .sink = sink };
            var report: routing.Report = .{};
            switch (document.source_info.encoding) {
                inline else => |actual| if (comptime Host.source_capabilities.allows(actual)) {
                    // Both pools are source ordered. Merge without an index/copy.
                    var a: usize = 0;
                    var b: usize = 0;
                    while (a < document.attributes.len or b < document.assignments.len) {
                        const pair = if (b == document.assignments.len or (a < document.attributes.len and document.attributes[a].key.start < document.assignments[b].key.start)) blk: {
                            const p = document.attributes[a];
                            a += 1;
                            break :blk p;
                        } else blk: {
                            const p = document.assignments[b];
                            b += 1;
                            break :blk p;
                        };
                        const key = try logical.Reader(actual).init(try support.processor.Fragment.fromSource(document.source, pair.key));
                        var selected = false;
                        inline for (1..Routes.count) |i| {
                            if (!selected and routing.nameMatches(key, Routes.name(i), false)) {
                                selected = true;
                                try checkValue(actual, i, document.source, pair.value, &transport, &report, settings, options);
                            }
                        }
                        if (!selected) try checkValue(actual, 0, document.source, pair.value, &transport, &report, settings, options);
                        if (report.stop != null) break;
                    }
                } else return error.UnsupportedEncoding,
            }
            report.complete = report.stop == null and document.scopeComplete();
            return report;
        }
        fn checkValue(comptime actual: support.encoding.Actual, comptime index: usize, source: []const u8, span: api.Span, transport: *T, report: *routing.Report, settings: policy.Effective, options: Options) !void {
            // A value with HTML operands belongs to the markup path. Mixed
            // expressions cannot be flattened or certified as a logical string.
            var parts = try @import("identifier.zig").ForEncoding(actual).parts(source, span);
            var html = false;
            var text = false;
            while (parts.next()) |part| {
                if (part.form == .html) html = true else text = true;
            }
            if (html) {
                if (!text) return;
                if (Routes.mode(index) == .process) {
                    report.unavailable += 1;
                    if (report.first_unavailable == null) report.first_unavailable = .{ .reason = .unsupported_form, .location = .{ .span = span, .segment_start = span.start } };
                    return;
                }
            }
            switch (comptime Routes.mode(index)) {
                .passthrough => report.passthrough += 1,
                .none => {
                    report.unsupported += 1;
                    const severity = settings.parsing.unsupported;
                    if (severity == .silent) return;
                    if (severity == .err) report.errors += 1 else report.warnings += 1;
                    const d: api.Diagnostic = .{
                        .code = if (severity == .err) .profile_unsupported_feature else .profile_unsupported_feature_warning,
                        .span = span,
                        .details = .{ .unsupported_feature = .string_value },
                    };
                    const action = transport.hostSink().emit(if (composed) .{ .dot = d } else d) catch |err| {
                        report.delivery = .failed;
                        report.diagnostic_stop = .fromError(err);
                        report.stop = .diagnostic_stop;
                        return;
                    };
                    if (action == .stop) {
                        report.stop = .diagnostic_stop;
                        report.diagnostic_stop = .requested;
                    } else if (severity == .err and settings.parsing.on_error == .fail_fast) report.stop = .parent_error;
                },
                .process => {
                    const P = Routes.Processor(Child, index);
                    const reader = try logical.Reader(actual).init(try support.processor.Fragment.fromSource(source, span));
                    const result = try P.WithReader(logical.Reader(actual)).parseAndValidate(reader, transport.stringSink(), childOptions(P, options));
                    report.record(result, settings.parsing.on_error);
                },
            }
        }
    };
}
