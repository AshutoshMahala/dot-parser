//! Compile-time host routing. No grammar, processor implementation or allocation.
const std = @import("std");
const reporting = @import("reporting.zig");
const location = @import("location.zig");

pub const Mode = enum { none, passthrough, process };

/// Keep the established host schema typed. Only routing and processor binding
/// are extracted from the richer compile-time configuration.
pub fn hostConfig(comptime T: type, comptime config: anytype) T {
    @setEvalBranchQuota(10000);
    var result: T = .{};
    inline for (comptime @typeInfo(@TypeOf(config)).@"struct".field_names) |field| {
        const value = @field(config, field);
        if (comptime std.mem.eql(u8, field, "policy")) {
            if (@TypeOf(value) == @FieldType(T, "policy")) {
                result.policy = value;
                continue;
            }
            inline for (comptime @typeInfo(@TypeOf(value)).@"struct".field_names) |leaf| {
                if (comptime std.mem.eql(u8, leaf, "string") or std.mem.eql(u8, leaf, "attributes")) continue;
                @field(result.policy, leaf) = coerce(@FieldType(@TypeOf(result.policy), leaf), @field(value, leaf));
            }
        } else if (comptime std.mem.eql(u8, field, "processors")) {
            inline for (comptime @typeInfo(@TypeOf(value)).@"struct".field_names) |leaf| {
                if (comptime std.mem.eql(u8, leaf, "string")) continue;
                @field(result.processors, leaf) = @field(value, leaf);
            }
        } else @field(result, field) = coerce(@FieldType(T, field), value);
    }
    return result;
}

pub fn coerce(comptime T: type, value: anytype) T {
    if (T == @TypeOf(value)) return value;
    if (@typeInfo(T) == .optional and @TypeOf(value) == @TypeOf(null)) return null;
    if (@typeInfo(T) == .optional) return coerce(@typeInfo(T).optional.child, value);
    if (@typeInfo(T) == .@"struct" and @typeInfo(@TypeOf(value)) == .@"struct") {
        var result: T = .{};
        inline for (comptime @typeInfo(@TypeOf(value)).@"struct".field_names) |field|
            @field(result, field) = coerce(@FieldType(T, field), @field(value, field));
        return result;
    }
    return value;
}

pub fn child(comptime config: anytype) type {
    if (@hasField(@TypeOf(config), "processors") and @hasField(@TypeOf(config.processors), "string"))
        return config.processors.string;
    return void;
}

pub fn Routes(comptime config: anytype) type {
    const p = if (@hasField(@TypeOf(config), "policy")) config.policy else .{};
    const fallback = if (@hasField(@TypeOf(p), "string")) p.string else .passthrough;
    const attributes = if (@hasField(@TypeOf(p), "attributes")) p.attributes else .{};
    const fields = @typeInfo(@TypeOf(attributes)).@"struct".field_names;
    return struct {
        pub const count = fields.len + 1;
        pub fn rule(comptime index: usize) @TypeOf(if (index == 0) fallback else selected(index - 1)) {
            return if (index == 0) fallback else selected(index - 1);
        }
        fn selected(comptime index: usize) @TypeOf(if (@hasField(@TypeOf(@field(attributes, fields[index])), "string")) @field(attributes, fields[index]).string else fallback) {
            const item = @field(attributes, fields[index]);
            // Other value-form routes must not be silently accepted as implemented.
            inline for (comptime @typeInfo(@TypeOf(item)).@"struct".field_names) |field|
                if (comptime !std.mem.eql(u8, field, "string")) @compileError("attribute routing currently supports only .string");
            return if (@hasField(@TypeOf(item), "string")) item.string else fallback;
        }
        pub fn mode(comptime index: usize) Mode {
            const r = rule(index);
            if (@TypeOf(r) == @TypeOf(.enum_literal) or @typeInfo(@TypeOf(r)) == .@"enum") return @fromBackingInt(@intCast(@backingInt(@as(Mode, r))));
            if (@hasField(@TypeOf(r), "process") and @typeInfo(@TypeOf(r)).@"struct".field_names.len == 1) return .process;
            @compileError("string route must be .none, .passthrough or .{ .process = child_policy }");
        }
        pub const active = blk: {
            for (0..count) |i| if (mode(i) != .passthrough) break :blk true;
            break :blk false;
        };
        pub const processing = blk: {
            for (0..count) |i| if (mode(i) == .process) break :blk true;
            break :blk false;
        };
        pub fn name(comptime index: usize) []const u8 {
            return fields[index - 1];
        }
        pub fn checkNames(comptime insensitive: bool) void {
            for (fields, 0..) |field, i| {
                if (!std.unicode.utf8ValidateSlice(field)) @compileError("attribute route names must be UTF-8");
                if (insensitive) for (fields[0..i]) |other| {
                    if (std.ascii.eqlIgnoreCase(field, other))
                        @compileError("ambiguous ASCII-insensitive attribute routes: " ++ field ++ " and " ++ other);
                };
            }
        }
        pub fn Processor(comptime Child: type, comptime index: usize) type {
            if (Child == void) @compileError(".process requires .processors.string");
            const r = rule(index);
            return Child.withPolicy(if (@typeInfo(@TypeOf(r)) == .@"struct") r.process else .{});
        }
    };
}

pub fn Options(comptime Child: type, comptime R: type) type {
    if (Child == void) return void;
    const cancellation = blk: {
        for (0..R.count) |i| if (R.mode(i) == .process) {
            if (@FieldType(R.Processor(Child, i).Options, "cancellation") != void) break :blk true;
        };
        break :blk false;
    };
    return struct {
        policy: if (Child.Policies.runtime_policy) Child.Policy else void = if (Child.Policies.runtime_policy) .{} else {},
        cancellation: if (cancellation) ?@import("execution.zig").Cancellation else void = if (cancellation) null else {},
    };
}

/// Constant-size aggregate; no result list, decoded copy or mapping table.
pub const Report = struct {
    complete: bool = false,
    processed: u32 = 0,
    passed: u32 = 0,
    passthrough: u32 = 0,
    unsupported: u32 = 0,
    unavailable: u32 = 0,
    errors: u64 = 0,
    warnings: u64 = 0,
    delivery: reporting.Delivery = .complete,
    diagnostic_stop: ?reporting.StopReason = null,
    stop: ?enum { parent_error, cancelled, invalid_validator, diagnostic_stop } = null,
    first_unavailable: ?@import("logical.zig").Failure = null,

    pub fn valid(self: Report) bool {
        return self.complete and self.stop == null and self.errors == 0 and
            self.unavailable == 0 and self.passed == self.processed and self.delivery == .complete;
    }
    pub fn stopped(self: Report) bool {
        return if (self.stop) |s| s != .parent_error else false;
    }
    pub fn record(self: *Report, result: anytype, on_error: @import("execution.zig").OnError) void {
        self.processed += 1;
        self.errors = std.math.add(u64, self.errors, result.errors) catch {
            self.stop = .invalid_validator;
            return;
        };
        self.warnings = std.math.add(u64, self.warnings, result.warnings) catch {
            self.stop = .invalid_validator;
            return;
        };
        if (result.valid()) self.passed += 1;
        if (result.delivery == .failed) self.delivery = .failed;
        switch (result.completion) {
            .complete, .fail_fast => {},
            .input_unavailable => {
                self.unavailable += 1;
                if (self.first_unavailable == null) self.first_unavailable = result.input_failure;
            },
            .cancelled => self.stop = .cancelled,
            .invalid_validator => self.stop = .invalid_validator,
            .diagnostic_stop => |reason| {
                self.stop = .diagnostic_stop;
                self.diagnostic_stop = reason;
            },
        }
        if (self.stop == null and on_error == .fail_fast and result.errors != 0) self.stop = .parent_error;
    }
};

/// A bag shared by a host and its child, retaining each native payload.
pub fn Transport(comptime HostDiagnostic: type, comptime StringDiagnostic: type) type {
    return struct {
        pub const Diagnostic = union(enum) {
            host: HostDiagnostic,
            string: StringDiagnostic,
            pub fn span(self: @This()) location.Span {
                return switch (self) {
                    inline else => |d| if (@hasDecl(@TypeOf(d), "span")) d.span() else d.span,
                };
            }
        };
        pub const Sink = reporting.Sink(Diagnostic);
        pub const GrowableDiagnosticBag = reporting.GrowableBag(Diagnostic);
        pub fn FixedDiagnosticBag(comptime n: usize) type {
            return reporting.FixedBag(Diagnostic, n, .stop);
        }
        sink: Sink,
        pub fn hostSink(self: *@This()) reporting.Sink(HostDiagnostic) {
            return .{ .context = self, .emit_fn = emitHost };
        }
        pub fn stringSink(self: *@This()) reporting.Sink(StringDiagnostic) {
            return .{ .context = self, .emit_fn = emitString };
        }
        fn emitHost(raw: ?*anyopaque, d: HostDiagnostic) reporting.SinkError!reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.sink.emit(.{ .host = d });
        }
        fn emitString(raw: ?*anyopaque, d: StringDiagnostic) reporting.SinkError!reporting.Action {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.sink.emit(.{ .string = d });
        }
    };
}

/// Attribute names are UTF-8 configuration. Readers preserve host spelling rules.
pub fn nameMatches(input: anytype, expected: []const u8, insensitive: bool) bool {
    var reader = input;
    var index: usize = 0;
    while (true) switch (reader.step()) {
        .pending => {},
        .end => return index == expected.len,
        .failure => return false,
        .scalar => |item| {
            if (index == expected.len) return false;
            const len = std.unicode.utf8ByteSequenceLength(expected[index]) catch return false;
            if (len > expected.len - index) return false;
            const scalar = std.unicode.utf8Decode(expected[index..][0..len]) catch return false;
            const a = item.codepoint;
            const b = scalar;
            if ((if (insensitive and a >= 'A' and a <= 'Z') a + 32 else a) !=
                (if (insensitive and b >= 'A' and b <= 'Z') b + 32 else b)) return false;
            index += len;
        },
    };
}
