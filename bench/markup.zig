//! Standalone baseline: sources/storage are constructed outside timed regions.
//! Decimal MB/s. Fixed-storage retained parsing and count-only execution are
//! measured separately; reserved bytes are not process RSS or allocator overhead.
const std = @import("std");
const markup = @import("markup_parser");
fn RuntimeFor(comptime backend: markup.ScannerBackend) type {
    return markup.Profile(.{ .runtime_policy = true, .policy = .{ .scanner = backend } });
}
const Runtime = RuntimeFor(.scalar);
const batch = 16;
const warmups = 5;

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(50_000);
    const allocator = init.arena.allocator();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--rules-only") and !std.mem.eql(u8, args[1], "--validation-only") and !std.mem.eql(u8, args[1], "--scopes-only"))) return error.InvalidArguments;
    try writer.print("Node={d} Attribute={d} KeyScratch={d} Frame={d} Diagnostic={d} fixed_session={d} bounded_session={d} runtime_session={d} ValidationResult={d}\n", .{
        @sizeOf(markup.Node),                  @sizeOf(markup.Attribute),  @sizeOf(markup.AttributeKeyScratch),
        markup.FixedParseScratch(1).byte_size, @sizeOf(markup.Diagnostic), @sizeOf(markup.Profile(.{}).Session),
        @sizeOf(markup.BoundedSession),        @sizeOf(Runtime.Session),   @sizeOf(markup.ValidationResult),
    });
    if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "--scopes-only")) {
            try benchScopes(init, writer);
            try writer.flush();
            return;
        }
        try benchRules(init, writer);
        if (std.mem.eql(u8, args[1], "--validation-only")) {
            try benchEncoding(init, writer);
            try benchCancellation(init, writer);
        }
        try writer.flush();
        return;
    }
    inline for (.{ "flat", "mixed", "text", "deep", "attributes", "duplicates", "references", "attribute_references", "comments", "cdata", "prose", "long_names", "long_values" }) |name| {
        var source: std.ArrayList(u8) = .empty;
        if (comptime std.mem.eql(u8, name, "deep")) {
            for (0..10_000) |_| try source.appendSlice(allocator, "<a>");
            for (0..10_000) |_| try source.appendSlice(allocator, "</a>");
        } else if (comptime std.mem.eql(u8, name, "text")) {
            try source.resize(allocator, 1_000_000);
            @memset(source.items, 'x');
        } else {
            const item = comptime blk: {
                if (std.mem.eql(u8, name, "prose")) break :blk "<p>" ++ "The quick brown fox jumps over the lazy dog. " ** 8 ++ "</p>";
                if (std.mem.eql(u8, name, "long_names")) break :blk "<" ++ "name" ** 32 ++ "/>";
                if (std.mem.eql(u8, name, "long_values")) break :blk "<a x='" ++ "value " ** 64 ++ "'/>";
                if (std.mem.eql(u8, name, "flat")) break :blk "<a/>";
                if (std.mem.eql(u8, name, "attributes")) break :blk "<a x='1' y=\"2\" z='3'/>";
                if (std.mem.eql(u8, name, "duplicates")) break :blk "<a x='1' y=\"2\" x='3'/>";
                if (std.mem.eql(u8, name, "references")) break :blk "<a>&amp;&#65;&#x1F600;&custom;</a>";
                if (std.mem.eql(u8, name, "attribute_references")) break :blk "<a x='&amp;&#65;&#x1F600;&custom;'/>";
                if (std.mem.eql(u8, name, "comments")) break :blk "<!-- <a>&literal; - text -->";
                if (std.mem.eql(u8, name, "cdata")) break :blk "<![CDATA[<a>&literal; ] text]]>";
                break :blk "<a><b/>text</a>";
            };
            const repetitions = if (comptime std.mem.eql(u8, name, "prose") or std.mem.startsWith(u8, name, "long_")) 5_000 else 50_000;
            for (0..repetitions) |_| try source.appendSlice(allocator, item);
        }
        const measured = markup.measure(allocator, source.items, markup.diagnostic.discard, .{});
        if (measured.outcome != .success) return error.MeasureFailed;
        const memory: markup.ParseMemory = .{
            .document = .{ .nodes = try allocator.alloc(markup.Node, measured.counts.nodes), .attributes = try allocator.alloc(markup.Attribute, measured.counts.attributes) },
            .scratch = .{ .frames = try allocator.alloc(std.meta.Elem(@FieldType(markup.ParseScratch, "frames")), measured.counts.max_depth) },
        };
        try writer.print("{s}: source={d} nodes={d} attributes={d} retained={d} scratch_reserved={d}\n", .{
            name, source.items.len, measured.counts.nodes, measured.counts.attributes, memory.document.nodes.len * @sizeOf(markup.Node) + memory.document.attributes.len * @sizeOf(markup.Attribute), memory.scratch.frames.len * markup.FixedParseScratch(1).byte_size,
        });
        inline for (.{ .scalar, .block }) |backend| {
            inline for (.{ "fixed", "runtime_baseline", "runtime_override", "count_only", "cancellable" }) |mode| {
                var times: [9]u64 = undefined;
                var patch: markup.Policy = if (comptime std.mem.eql(u8, mode, "runtime_override")) markup.presets.standard else .{};
                if (comptime std.mem.eql(u8, mode, "runtime_override")) patch.scanner = backend;
                const opaque_patch: *volatile markup.Policy = &patch;
                var stop: u8 = 0;
                for (0..warmups + times.len) |round| {
                    const input = opaque_patch.*;
                    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                    var node_sum: u64 = 0;
                    for (0..batch) |_| {
                        const counts = if (comptime std.mem.eql(u8, mode, "count_only")) countOnly(backend, source.items, memory.scratch) else if (comptime std.mem.eql(u8, mode, "fixed")) parseFixed(backend, source.items, memory) else if (comptime std.mem.eql(u8, mode, "cancellable")) parseCancellable(backend, source.items, memory, &stop) else parseRuntime(backend, source.items, memory, input);
                        node_sum += counts.nodes;
                    }
                    const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                    if (node_sum != @as(u64, measured.counts.nodes) * batch) return error.ParseFailed;
                    if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
                }
                std.mem.sort(u64, &times, {}, std.sort.asc(u64));
                const ns: f64 = @floatFromInt(times[4]);
                try writer.print("  {s}/{s}: {d:.3} ms, {d:.1} MB/s\n", .{ @tagName(backend), mode, ns / 1e6, @as(f64, @floatFromInt(source.items.len)) * 1000 / ns });
            }
        }
        if (comptime std.mem.eql(u8, name, "attributes") or std.mem.eql(u8, name, "duplicates")) {
            const parsed = markup.parseBorrowedIn(source.items, memory, markup.diagnostic.discard, .{});
            const document = parsed.document orelse return error.ParseFailed;
            const capacity = markup.requiredValidationScratch(&document);
            const scratch: markup.ValidationScratch = .{ .attribute_keys = try allocator.alloc(markup.AttributeKeyScratch, capacity) };
            var times: [9]u64 = undefined;
            for (0..warmups + times.len) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var errors: u64 = 0;
                for (0..batch) |_| errors += validateFixed(&document, scratch);
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (errors != (if (comptime std.mem.eql(u8, name, "duplicates")) @as(u64, 50_000 * batch) else 0)) return error.ValidationFailed;
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("  validation_only: {d:.3} ms, {d:.1} MB/s, scratch={d}\n", .{ ns / 1e6, @as(f64, @floatFromInt(source.items.len)) * 1000 / ns, capacity * @sizeOf(markup.AttributeKeyScratch) });
        }
    }
    try benchEncoding(init, writer);
    try benchRules(init, writer);
    try benchCancellation(init, writer);
    try writer.flush();
}

/// Explicit tree-free source-validation cost, including lexical recognition,
/// header buffering and local rules. Fixed buffers/source are outside timing.
fn benchScopes(init: std.process.Init, writer: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    inline for (.{ "complete", "bad_closer", "bad_header" }) |fixture| {
        const item = if (comptime std.mem.eql(u8, fixture, "complete"))
            "<x a='1' a='2'>&bogus;</x>"
        else if (comptime std.mem.eql(u8, fixture, "bad_closer"))
            "<x a='1' a='2'>&bogus;</wrong>"
        else
            "<x a='1' a='2' bad=0/><y>&bogus;</y>";
        const repetitions = 10_000;
        const source = try allocator.alloc(u8, repetitions * item.len);
        for (0..repetitions) |i| @memcpy(source[i * item.len ..][0..item.len], item);
        inline for (.{ .scalar, .block }) |backend| inline for (.{ false, true }) |runtime| {
            var scratch: markup.FixedSourceValidationScratch(3) = .{};
            var times: [9]u64 = undefined;
            for (0..warmups + times.len) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var errors: u64 = 0;
                for (0..batch) |_| {
                    const r = sourceScopes(backend, runtime, source, scratch.storage());
                    if (std.meta.activeTag(r.completion) != (if (comptime std.mem.eql(u8, fixture, "bad_header")) .incomplete else .complete)) return error.ValidationFailed;
                    errors += r.errors;
                }
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (errors != repetitions * 2 * batch) return error.ValidationFailed;
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("scopes/{s}/{s}/{s}: source={d}, {d:.3} ms, {d:.1} MB/s, scratch={d}\n", .{
                fixture,  @tagName(backend),                               if (runtime) "runtime" else "fixed", source.len,
                ns / 1e6, @as(f64, @floatFromInt(source.len)) * 1000 / ns, @sizeOf(@TypeOf(scratch)),
            });
        };
    }
}
noinline fn sourceScopes(comptime backend: markup.ScannerBackend, comptime runtime: bool, source: []const u8, scratch: markup.SourceValidationScratch) markup.ValidationResult {
    const p: markup.Policy = .{ .scanner = backend, .validation = .{ .names = .{ .severity = .err }, .references = .{ .severity = .err } } };
    const P = markup.Profile(.{ .runtime_policy = runtime, .policy = p });
    var patch: markup.Policy = .{};
    const input: *volatile markup.Policy = &patch;
    return P.validateSourceIn(source, scratch, markup.diagnostic.discard, if (runtime) .{ .policy = input.* } else .{});
}

/// Observable callback counts and post-parse latency. Plain modes guard against
/// adding cancellation overhead to profiles that compiled it out.
fn benchCancellation(init: std.process.Init, writer: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    inline for (.{ "references", "encoding", "names", "dense" }) |fixture| {
        const names = comptime std.mem.eql(u8, fixture, "names");
        const dense = comptime std.mem.eql(u8, fixture, "dense");
        const item = "<a x='1' y='2'/>";
        const source = try allocator.alloc(u8, if (dense) item.len * 10_000 else 100_000);
        if (dense) {
            for (0..10_000) |index| @memcpy(source[index * item.len ..][0..item.len], item);
        } else @memset(source, 'x');
        if (names) {
            source[0] = '<';
            @memcpy(source[source.len - 2 ..], "/>");
        }
        var parsed = markup.parseBorrowed(allocator, source, markup.diagnostic.discard, .{});
        defer parsed.deinit();
        const document = parsed.document orelse return error.ParseFailed;
        inline for (.{ false, true }) |runtime| inline for (.{ false, true }) |cancellable| {
            const patch: markup.Policy = .{ .validation = .{
                .duplicate_attribute = .off,
                .invalid_utf8 = if (dense or comptime std.mem.eql(u8, fixture, "encoding")) .err else .off,
                .names = .{ .severity = if (names or dense) .err else .off },
                .references = .{ .severity = if (dense or comptime std.mem.eql(u8, fixture, "references")) .err else .off },
            }, .execution = .{ .cancellation = cancellable } };
            var times: [9]u64 = undefined;
            var calls: u64 = 0;
            for (0..warmups + times.len) |round| {
                calls = 0;
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                for (0..batch) |_| {
                    if (!validateWithHook(runtime, cancellable, patch, &document, &calls)) return error.ValidationFailed;
                }
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("poll/{s}/{s}/{s}: source={d}, {d:.3} ms, {d:.1} MB/s, calls={d}\n", .{
                fixture, if (runtime) "runtime" else "fixed", if (cancellable) "cancellable" else "plain", source.len, ns / 1e6, @as(f64, @floatFromInt(source.len)) * 1000 / ns, calls / batch,
            });
        };
    }
}

noinline fn countPoll(context: ?*anyopaque) bool {
    const calls: *volatile u64 = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return false;
}
noinline fn validateWithHook(comptime runtime: bool, comptime cancellable: bool, comptime patch: markup.Policy, document: *const markup.Document, calls: *u64) bool {
    const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else patch });
    var input = patch;
    const opaque_patch: *volatile markup.Policy = &input;
    const hook: markup.Cancellation = .{ .context = calls, .is_requested = countPoll };
    const result = P.validateIn(document, .{}, markup.diagnostic.discard, if (runtime) .{ .policy = opaque_patch.*, .cancellation = hook } else if (cancellable) .{ .cancellation = hook } else .{});
    return result.completion == .complete and result.validity == .valid;
}

/// New optional validation costs. Includes reference rescanning, but excludes
/// parsing, diagnostic retention, source construction and scratch allocation.
fn benchRules(init: std.process.Init, writer: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    inline for (.{ "ascii_names", "unicode_names", "references", "combined", "prose", "literal_candidates" }) |fixture| {
        const item = comptime blk: {
            if (std.mem.eql(u8, fixture, "ascii_names")) break :blk "<element long_name='value'/>";
            if (std.mem.eql(u8, fixture, "unicode_names")) break :blk "<東京 café='text'/>";
            if (std.mem.eql(u8, fixture, "references")) break :blk "&amp;&nbsp;&#160;&custom;";
            if (std.mem.eql(u8, fixture, "combined")) break :blk "<\xff a='\xff' a='&unknown;'/>";
            if (std.mem.eql(u8, fixture, "prose")) break :blk "some plain text without references ";
            break :blk "&\xff &missing &#x0; ";
        };
        const repetitions = 50_000;
        const source = try allocator.alloc(u8, item.len * repetitions);
        for (0..repetitions) |index| @memcpy(source[index * item.len ..][0..item.len], item);
        const Reader = markup.Profile(.{ .policy = .{ .syntax = .{ .malformed_reference = .accept } } });
        var parsed = Reader.parseBorrowed(allocator, source, markup.diagnostic.discard, .{});
        defer parsed.deinit();
        const document = parsed.document orelse return error.ParseFailed;
        const combined = comptime std.mem.eql(u8, fixture, "combined");
        const references = comptime std.mem.eql(u8, fixture, "references");
        const keys = try allocator.alloc(markup.AttributeKeyScratch, if (combined) markup.requiredValidationScratch(&document) else 0);
        const scratch: markup.ValidationScratch = .{ .attribute_keys = keys };
        const patch: markup.Policy = .{ .validation = .{
            .names = .{ .severity = if (references) .off else .warning },
            .references = .{ .severity = if (combined or references) .warning else .off },
            .invalid_utf8 = if (combined) .warning else .off,
            .duplicate_attribute = if (combined) .warning else .off,
        } };
        inline for (.{ false, true }) |runtime| {
            var times: [9]u64 = undefined;
            const expected: u64 = repetitions * (if (combined) @as(u64, 5) else if (references) @as(u64, 2) else 0);
            for (0..warmups + times.len) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var findings: u64 = 0;
                for (0..batch) |_| findings += validateRules(runtime, patch, &document, scratch);
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (findings != expected * batch) return error.RuleValidationFailed;
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("rules/{s}/{s}: source={d}, {d:.3} ms, {d:.1} MB/s, scratch={d}, findings={d}\n", .{
                fixture, if (runtime) "runtime" else "fixed", source.len, ns / 1e6, @as(f64, @floatFromInt(source.len)) * 1000 / ns, keys.len * @sizeOf(markup.AttributeKeyScratch), expected,
            });
        }
    }
}

noinline fn validateRules(comptime runtime: bool, comptime patch: markup.Policy, document: *const markup.Document, scratch: markup.ValidationScratch) u64 {
    var input = patch;
    const opaque_patch: *volatile markup.Policy = &input;
    const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else patch });
    const result = P.validateIn(document, scratch, markup.diagnostic.discard, if (runtime) .{ .policy = opaque_patch.* } else .{});
    return if (result.completion == .complete) result.warnings else std.math.maxInt(u64);
}

/// Separate post-parse costs; parsing, source/pool construction and sink storage
/// are outside the timer. A discard sink still counts every factual finding.
fn benchEncoding(init: std.process.Init, writer: *std.Io.Writer) !void {
    const allocator = init.arena.allocator();
    inline for (.{ "ascii", "unicode", "invalid", "combined" }) |fixture| {
        const item = comptime blk: {
            if (std.mem.eql(u8, fixture, "ascii")) break :blk "plain text";
            if (std.mem.eql(u8, fixture, "unicode")) break :blk "é東京😀";
            if (std.mem.eql(u8, fixture, "invalid")) break :blk "x\xff\xc0\xaf\xed\xa0\x80";
            break :blk "<a x='東京' x='\xff'/>";
        };
        const repetitions = 50_000;
        const source = try allocator.alloc(u8, item.len * repetitions);
        for (0..repetitions) |index| @memcpy(source[index * item.len ..][0..item.len], item);
        var parsed = markup.parseBorrowed(allocator, source, markup.diagnostic.discard, .{});
        defer parsed.deinit();
        const document = parsed.document orelse return error.ParseFailed;
        const combined = comptime std.mem.eql(u8, fixture, "combined");
        const keys = try allocator.alloc(markup.AttributeKeyScratch, if (combined) markup.requiredValidationScratch(&document) else 0);
        const scratch: markup.ValidationScratch = .{ .attribute_keys = keys };
        inline for (.{ false, true }) |runtime| {
            var times: [9]u64 = undefined;
            const expected: u64 = repetitions * (if (comptime std.mem.eql(u8, fixture, "invalid")) @as(u64, 6) else if (combined) @as(u64, 2) else 0);
            for (0..warmups + times.len) |round| {
                const start = std.Io.Clock.Timestamp.now(init.io, .awake);
                var findings: u64 = 0;
                for (0..batch) |_| findings += validateEncoding(runtime, combined, &document, scratch);
                const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                if (findings != expected * batch) return error.EncodingValidationFailed;
                if (round >= warmups) times[round - warmups] = @intCast(@divTrunc(start.durationTo(end).raw.nanoseconds, batch));
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const ns: f64 = @floatFromInt(times[4]);
            try writer.print("utf8/{s}/{s}: source={d}, {d:.3} ms, {d:.1} MB/s, scratch={d}, findings={d}\n", .{
                fixture, if (runtime) "runtime" else "fixed", source.len, ns / 1e6, @as(f64, @floatFromInt(source.len)) * 1000 / ns, keys.len * @sizeOf(markup.AttributeKeyScratch), expected,
            });
        }
    }
}

noinline fn validateEncoding(comptime runtime: bool, comptime combined: bool, document: *const markup.Document, scratch: markup.ValidationScratch) u64 {
    const policy: markup.Policy = .{ .validation = .{ .invalid_utf8 = .warning, .duplicate_attribute = if (combined) .warning else .off } };
    var patch = policy;
    const opaque_patch: *volatile markup.Policy = &patch;
    const P = markup.Profile(.{ .runtime_policy = runtime, .policy = if (runtime) .{} else policy });
    const result = P.validateIn(document, scratch, markup.diagnostic.discard, if (runtime) .{ .policy = opaque_patch.* } else .{});
    return if (result.completion == .complete and result.checks.invalid_utf8 == .complete) result.warnings else std.math.maxInt(u64);
}

noinline fn validateFixed(document: *const markup.Document, scratch: markup.ValidationScratch) u64 {
    const r = markup.validateIn(document, scratch, markup.diagnostic.discard, .{});
    return if (r.completion == .complete) r.errors else std.math.maxInt(u64);
}
noinline fn parseFixed(comptime backend: markup.ScannerBackend, source: []const u8, memory: markup.ParseMemory) markup.Counts {
    const r = markup.Profile(.{ .policy = .{ .scanner = backend } }).parseBorrowedIn(source, memory, markup.diagnostic.discard, .{});
    return if (r.outcome == .success) r.counts else .{};
}
noinline fn countOnly(comptime backend: markup.ScannerBackend, source: []const u8, frames: markup.ParseScratch) markup.Counts {
    const r = markup.Profile(.{ .policy = .{ .scanner = backend } }).measureIn(source, frames, markup.diagnostic.discard, .{});
    return if (r.outcome == .success) r.counts else .{};
}
noinline fn parseRuntime(comptime backend: markup.ScannerBackend, source: []const u8, memory: markup.ParseMemory, patch: markup.Policy) markup.Counts {
    const r = RuntimeFor(backend).parseBorrowedIn(source, memory, markup.diagnostic.discard, .{ .policy = patch });
    return if (r.outcome == .success) r.counts else .{};
}

noinline fn requested(context: ?*anyopaque) bool {
    const flag: *volatile u8 = @ptrCast(context.?);
    return flag.* != 0;
}
noinline fn parseCancellable(comptime backend: markup.ScannerBackend, source: []const u8, memory: markup.ParseMemory, stop: *u8) markup.Counts {
    const P = markup.Profile(.{ .policy = .{ .scanner = backend, .execution = .{ .cancellation = true } } });
    const r = P.parseBorrowedIn(source, memory, markup.diagnostic.discard, .{ .cancellation = .{ .context = stop, .is_requested = requested } });
    return if (r.outcome == .success) r.counts else .{};
}
