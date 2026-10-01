//! Storage/execution adapters. One grammar; consumers choose retention.
const std = @import("std");
const policy = @import("policy.zig");
const parser = @import("parser.zig");
const syntax = @import("syntax.zig");
const scratch = @import("scratch.zig");
const diagnostic = @import("diagnostic.zig");
const results = @import("result.zig");

pub fn Engine(comptime api: type, comptime backend: policy.ScannerBackend, comptime fixed_settings: ?policy.ParseSettings, comptime metered: bool, comptime cancellable: bool) type {
    const Machine = parser.Machine(backend, fixed_settings, metered, cancellable);
    return struct {
        pub const Settings = Machine.Settings;
        pub const Hook = Machine.Hook;
        pub const Session = struct {
            machine: Machine,
            stack: scratch.Stack,
            builder: syntax.Builder,
            memory: api.ParseMemory,
            pub fn init(source: []const u8, memory: api.ParseMemory, diagnostics: diagnostic.Sink, settings: Settings, hook: Hook) @This() {
                return .{
                    .machine = .init(source, diagnostics, settings, hook),
                    .stack = .{ .frames = memory.scratch.frames },
                    .builder = .fixed(source, memory.document),
                    .memory = memory,
                };
            }
            pub fn run(self: *@This()) api.FixedParseResult {
                _ = self.machine.run(&self.stack, &self.builder);
                return self.result().?;
            }
            pub fn advance(self: *@This(), budget: u32) results.Progress {
                return self.machine.advance(&self.stack, &self.builder, budget);
            }
            pub fn result(self: *const @This()) ?api.FixedParseResult {
                const report = self.machine.terminal orelse return null;
                return fixedResult(report, &self.builder);
            }
            pub fn cancel(self: *@This()) api.FixedParseResult {
                _ = self.machine.cancel(&self.stack, &self.builder);
                return self.result().?;
            }
            pub fn deinit(self: *@This()) void {
                _ = self.cancel();
            }
        };

        fn fixedResult(report: results.Report, builder: *const syntax.Builder) api.FixedParseResult {
            return .{ .outcome = report.outcome, .completion = report.completion, .syntax_errors = report.syntax_errors, .diagnostic_delivery = report.diagnostic_delivery, .counts = report.counts, .accepted_deviations = report.accepted_deviations, .warnings = report.warnings, .document = builder.document() };
        }
        pub fn parseBorrowedIn(source: []const u8, memory: api.ParseMemory, diagnostics: diagnostic.Sink, settings: Settings, hook: Hook) api.FixedParseResult {
            var session = Session.init(source, memory, diagnostics, settings, hook);
            return session.run();
        }
        pub fn parseBorrowed(allocator: std.mem.Allocator, source: []const u8, diagnostics: diagnostic.Sink, resources: api.ParseResources, settings: Settings, hook: Hook) api.ParseResult {
            var builder = syntax.Builder.growing(source, allocator);
            var stack: scratch.Stack = .{ .allocator = resources.scratch_allocator orelse allocator };
            defer stack.deinit();
            var machine = Machine.init(source, diagnostics, settings, hook);
            const report = machine.run(&stack, &builder);
            if (report.outcome == .success) builder.trimCapacity() else builder.deinit();
            return .{
                .outcome = report.outcome,
                .completion = report.completion,
                .syntax_errors = report.syntax_errors,
                .diagnostic_delivery = report.diagnostic_delivery,
                .counts = report.counts,
                .accepted_deviations = report.accepted_deviations,
                .warnings = report.warnings,
                .document = builder.document(),
                ._allocator = allocator,
                ._nodes = builder.list,
                ._attributes = builder.attributes,
            };
        }
        pub fn measureIn(source: []const u8, storage: scratch.Storage, diagnostics: diagnostic.Sink, settings: Settings, hook: Hook) results.Report {
            var stack: scratch.Stack = .{ .frames = storage.frames };
            var counter: syntax.Counter = .{};
            var machine = Machine.init(source, diagnostics, settings, hook);
            return machine.run(&stack, &counter);
        }
        pub fn measure(allocator: std.mem.Allocator, source: []const u8, diagnostics: diagnostic.Sink, settings: Settings, hook: Hook) results.Report {
            var stack: scratch.Stack = .{ .allocator = allocator };
            defer stack.deinit();
            var counter: syntax.Counter = .{};
            var machine = Machine.init(source, diagnostics, settings, hook);
            return machine.run(&stack, &counter);
        }
    };
}
