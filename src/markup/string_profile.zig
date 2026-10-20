//! One-shot and workspace string composition over retained markup attributes.
const std = @import("std");
const support = @import("parser_support");
const routing = support.string_routing;
const policy = @import("policy.zig");
const logical = @import("logical.zig");

fn Result(comptime Base: type) type {
    return struct {
        host: Base,
        string: routing.Report,
        has_errors: bool,
        pub fn scopeComplete(self: *const @This()) bool {
            return self.host.scopeComplete();
        }
        pub fn subtreeComplete(self: *const @This()) bool {
            return self.host.subtreeComplete() and self.string.complete and self.string.unavailable == 0;
        }
        pub fn documentValid(self: *const @This()) bool {
            return self.host.documentValid() and self.string.valid();
        }
        pub fn stopped(self: *const @This()) bool {
            return self.host.stopped() or self.string.stopped();
        }
        pub fn deinit(self: *@This()) void {
            self.host.deinit();
            self.* = undefined;
        }
    };
}

pub fn Profile(comptime api: type, comptime config: anytype, comptime base_config: policy.Config) type {
    const Child = routing.child(config);
    const caps = support.encoding.Capabilities.bound(support.encoding.Capabilities.from(base_config.source_encodings), if (Child != void) Child.declared_source_encodings else null);
    const adjusted = blk: {
        var c = base_config;
        c.source_encodings = caps.list();
        break :blk c;
    };
    return Wrapper(api, config, adjusted, @import("profile.zig").Profile(api, adjusted));
}

fn Wrapper(comptime api: type, comptime config: anytype, comptime base_config: policy.Config, comptime Host: type) type {
    const Routes = routing.Routes(config);
    const RawChild = routing.child(config);
    if (Routes.processing and RawChild == void) @compileError(".process requires .processors.string");
    const caps = Host.source_capabilities;
    const Child = if (RawChild != void) RawChild.withSourceEncodings(caps) else void;
    const T = routing.Transport(api.Diagnostic, if (Child != void) Child.Diagnostic else api.Diagnostic);
    const StringOptions = routing.Options(Child, Routes);
    const ChildError = if (Child != void) Child.Error else error{};
    comptime Routes.checkNames(base_config.runtime_policy or Host.Policies.baseline.mode == .graphviz);
    return struct {
        const Self = @This();
        pub const Outer = Host;
        // Preserve omission for inheritance when this wrapper is bound to DOT.
        pub const declared_source_encodings = blk: {
            const own = if (@hasField(@TypeOf(config), "source_encodings")) config.source_encodings else null;
            const inner = if (RawChild != void) RawChild.declared_source_encodings else null;
            if (own == null) break :blk inner;
            break :blk support.encoding.Capabilities.bound(support.encoding.Capabilities.from(own), inner).list();
        };
        pub const source_capabilities = caps;
        /// Group preparation only; operation prepare additionally checks each
        /// delegated baseline against the enabled runtime child patch.
        pub const Policies = if (Child == void) Host.Policies else support.processor.PolicySet(.{ .markup = Host, .string = Child }).Policies;
        pub const Diagnostic = T.Diagnostic;
        pub const DiagnosticSink = T.Sink;
        pub const GrowableDiagnosticBag = T.GrowableDiagnosticBag;
        pub const FixedDiagnosticBag = T.FixedDiagnosticBag;
        pub const console = support.console.ComposedRenderer(Diagnostic, .{
            .host = api.console.Adapter,
            .string = (if (Child != void) Child.console else api.console).Adapter,
        });
        pub const CheckResult = Result(api.FragmentResult);
        pub const FixedCheckResult = Result(api.FixedFragmentResult);
        pub const InputError = Host.InputError || ChildError;
        pub const ParseResources = api.ParseResources;
        pub const Options = struct {
            markup: Host.Options = .{},
            string: StringOptions = if (Child != void) .{} else {},
        };
        pub const ParseOptions = struct {
            markup: Host.Options = .{},
            string: StringOptions = if (Child != void) .{} else {},
            scratch_allocator: ?std.mem.Allocator = null,
        };
        pub fn withSourceEncodings(comptime capabilities: support.encoding.Capabilities) type {
            var c = base_config;
            c.source_encodings = capabilities.list();
            return Profile(api, config, c);
        }
        pub fn forSourceEncoding(comptime actual: support.encoding.Actual) type {
            return Wrapper(api, config, base_config, Host.forSourceEncoding(actual));
        }
        pub fn prepare(options: Options) InputError!Prepared {
            inline for (0..Routes.count) |i| if (comptime Routes.mode(i) == .process) {
                const P = Routes.Processor(Child, i);
                if (P.Policies.runtime_policy) _ = try P.Policies.prepare(.{ .policy = options.string.policy });
            };
            const call = Host.prepare(options.markup);
            return .{ .host = if (@typeInfo(@TypeOf(call)) == .error_union) try call else call, .string = options.string };
        }
        pub const Prepared = struct {
            host: Host.Prepared,
            string: StringOptions,
            fn effective(self: @This()) policy.Effective {
                return if (base_config.runtime_policy) self.host.policies else Host.Policies.baseline;
            }
            pub fn initWorkspace(self: @This(), allocator: std.mem.Allocator, resources: ParseResources) Workspace {
                return .{ .host = self.host.initWorkspace(allocator, resources), .prepared = self };
            }
            pub fn parseAndValidate(self: @This(), allocator: std.mem.Allocator, input: api.Fragment, sink: DiagnosticSink, resources: ParseResources) InputError!CheckResult {
                var transport: T = .{ .sink = sink };
                var host = try self.host.parseAndValidate(allocator, input, transport.hostSink(), resources);
                errdefer host.deinit();
                return finish(api.FragmentResult, host, input.origin, &transport, self);
            }
            pub fn parseAndValidateIn(self: @This(), input: api.Fragment, memory: api.ParseMemory, scratch: api.SourceValidationScratch, sink: DiagnosticSink) InputError!FixedCheckResult {
                var transport: T = .{ .sink = sink };
                const host = try self.host.parseAndValidateIn(input, memory, scratch, transport.hostSink());
                return finish(api.FixedFragmentResult, host, input.origin, &transport, self);
            }
        };
        pub const Workspace = struct {
            host: Host.Workspace,
            prepared: Prepared,
            pub fn parseAndValidate(self: *@This(), input: api.Fragment, sink: DiagnosticSink) InputError!FixedCheckResult {
                var transport: T = .{ .sink = sink };
                const host = try self.host.parseAndValidate(input, transport.hostSink());
                return finish(api.FixedFragmentResult, host, input.origin, &transport, self.prepared);
            }
            pub fn reservedBytes(self: *const @This()) usize {
                return self.host.reservedBytes();
            }
            pub fn deinit(self: *@This()) void {
                self.host.deinit();
                self.* = undefined;
            }
        };
        fn finish(comptime Base: type, host: Base, origin: u32, transport: *T, ready: Prepared) InputError!Result(Base) {
            const settings = ready.effective();
            const can_run = !host.stopped() and (settings.on_error == .collect or !host.has_errors) and
                (host.parse.outcome == .success or host.parse.outcome == .invalid_syntax);
            const report = if (can_run and host.parse.document != null)
                try processDocument(&host.parse.document.?, origin, transport, ready)
            else
                routing.Report{};
            return .{ .host = host, .string = report, .has_errors = host.has_errors or report.errors != 0 };
        }
        pub fn parseAndValidate(allocator: std.mem.Allocator, input: api.Fragment, sink: DiagnosticSink, options: ParseOptions) InputError!CheckResult {
            const ready = try prepare(.{ .markup = options.markup, .string = options.string });
            return ready.parseAndValidate(allocator, input, sink, .{ .scratch_allocator = options.scratch_allocator });
        }
        pub fn parseAndValidateIn(input: api.Fragment, memory: api.ParseMemory, scratch: api.SourceValidationScratch, sink: DiagnosticSink, options: Options) InputError!FixedCheckResult {
            const ready = try prepare(options);
            return ready.parseAndValidateIn(input, memory, scratch, sink);
        }
        pub fn processStrings(document: *const api.Document, origin: u32, sink: DiagnosticSink, options: Options) InputError!routing.Report {
            const ready = try prepare(options);
            _ = try support.processor.Fragment.init(document.source, origin);
            var transport: T = .{ .sink = sink };
            return processDocument(document, origin, &transport, ready);
        }
        fn processDocument(document: *const api.Document, origin: u32, transport: *T, ready: Prepared) InputError!routing.Report {
            const settings = ready.effective();
            var report: routing.Report = .{};
            switch (document.source_info.encoding) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    for (document.attributes) |attribute| {
                        const key = try support.logical.Reader(actual).init(.{ .bytes = attribute.name.slice(document.source), .origin = origin + attribute.name.start });
                        var selected = false;
                        inline for (1..Routes.count) |i| {
                            if (!selected and routing.nameMatches(key, Routes.name(i), settings.mode == .graphviz)) {
                                selected = true;
                                try checkValue(actual, i, document.source, origin, attribute.value, transport, &report, ready);
                            }
                        }
                        if (!selected) try checkValue(actual, 0, document.source, origin, attribute.value, transport, &report, ready);
                        if (report.stop != null) break;
                    }
                } else return error.InvalidFragment,
            }
            report.complete = report.stop == null and document.scopeComplete();
            return report;
        }
        fn checkValue(comptime actual: support.encoding.Actual, comptime index: usize, source: []const u8, origin: u32, quoted: support.location.Span, transport: *T, report: *routing.Report, ready: Prepared) InputError!void {
            const settings = ready.effective();
            const width: u32 = support.encoding.unitBytes(actual);
            const span: support.location.Span = .{ .start = quoted.start + width, .len = quoted.len - 2 * width };
            switch (comptime Routes.mode(index)) {
                .passthrough => report.passthrough += 1,
                .none => {
                    report.unsupported += 1;
                    const severity = settings.diagnostics.unsupported;
                    if (severity == .silent) return;
                    if (severity == .err) report.errors += 1 else report.warnings += 1;
                    const action = transport.hostSink().emit(.{
                        .code = if (severity == .err) .unsupported_feature else .unsupported_feature_warning,
                        .span = .{ .start = origin + quoted.start, .len = quoted.len },
                        .details = .{ .feature = .string_value },
                    }) catch |err| {
                        report.delivery = .failed;
                        report.diagnostic_stop = .fromError(err);
                        report.stop = .diagnostic_stop;
                        return;
                    };
                    if (action == .stop) {
                        report.stop = .diagnostic_stop;
                        report.diagnostic_stop = .requested;
                    } else if (severity == .err and settings.on_error == .fail_fast) report.stop = .parent_error;
                },
                .process => {
                    const P = Routes.Processor(Child, index);
                    const reader = try logical.Reader(actual).init(.{ .bytes = span.slice(source), .origin = origin + span.start }, .{
                        // Graphviz expands HTML4 entities in text, not XML
                        // attribute values. Follow the host's explicit catalog
                        // when that validation rule is selected.
                        .references = if (settings.mode == .graphviz and settings.validation.references.severity == .off) .xml_predefined else settings.validation.references.catalog,
                        .malformed_reference = settings.syntax.malformed_reference,
                        .normalize_attribute_whitespace = settings.mode == .graphviz,
                    });
                    const result = try P.WithReader(logical.Reader(actual)).parseAndValidate(reader, transport.stringSink(), .{
                        .encoding = null,
                        .policy = ready.string.policy,
                        .cancellation = if (@FieldType(P.Options, "cancellation") == void) {} else ready.string.cancellation,
                    });
                    report.record(result, settings.on_error);
                },
            }
        }
    };
}
