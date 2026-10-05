//! Compile-time policy preparation for configured processors. No registry,
//! scheduler, DOT grammar dependency or processor instance is introduced here.
const std = @import("std");
const location = @import("location.zig");

/// Schema owns Policy, Effective, defaults, Error, resolve and check. A failed
/// check carries an issue with asError(); an infallible schema uses Error =
/// error{} and a valid-only Check. Layouts need not match. The original
/// partial input is passed to check so explicit fields remain distinguishable.
pub fn PolicyBinding(comptime Schema: type, comptime config: struct {
    policy: Schema.Policy = .{},
    runtime_policy: bool = false,
}) type {
    const compiled = Schema.resolve(Schema.defaults, config.policy);
    comptime {
        const checked = Schema.check(compiled, config.policy);
        // Reject the contract, not merely this particular baseline value. Even
        // a currently-valid baseline cannot make an invalid-capable Check infallible.
        if (Schema.Error == error{}) {
            const Check = @TypeOf(checked);
            if (std.meta.fields(Check).len != 1 or !@hasField(Check, "valid"))
                @compileError("infallible policy schema must declare a valid-only Check");
        }
        if (Schema.Error == error{}) switch (checked) {
            .valid => {},
        } else switch (checked) {
            .valid => {},
            .invalid => |issue| @compileError("invalid policy: " ++ @tagName(issue)),
        }
    }
    return struct {
        pub const baseline = compiled;
        pub const runtime_policy = config.runtime_policy;
        pub const State = if (runtime_policy) Schema.Effective else void;
        pub const Options = if (runtime_policy) struct { policy: Schema.Policy = .{} } else struct {};
        pub const Error = if (runtime_policy) Schema.Error else error{};
        pub const validatePolicy = if (runtime_policy) checkRuntime else checkFixed;

        fn checkFixed(comptime input: Schema.Policy) @TypeOf(Schema.check(baseline, input)) {
            return comptime Schema.check(Schema.resolve(baseline, input), input);
        }
        fn checkRuntime(input: Schema.Policy) @TypeOf(Schema.check(baseline, input)) {
            return Schema.check(Schema.resolve(baseline, input), input);
        }

        pub fn prepare(options: Options) (if (runtime_policy) Error!State else State) {
            if (!runtime_policy) return {};
            const effective = Schema.resolve(baseline, options.policy);
            if (Schema.Error == error{}) return switch (Schema.check(effective, options.policy)) {
                .valid => effective,
            };
            return switch (Schema.check(effective, options.policy)) {
                .valid => effective,
                .invalid => |issue| issue.asError(),
            };
        }
    };
}

/// Named configured profiles/groups expose `Policies`, a policy binding. This prepares
/// only policies, not sessions. Call once before initializing any stage. No
/// profile's prepare method may scan input, allocate or invoke consumer callbacks.
/// Stage/resource compatibility will be checked by the future stage composition.
pub fn PolicySet(comptime profiles: anytype) type {
    const fields = std.meta.fields(@TypeOf(profiles));
    inline for (fields) |field| {
        const Profile = @field(profiles, field.name);
        if (@TypeOf(Profile) != type or !@hasDecl(Profile, "Policies"))
            @compileError("configured processor profile must expose Policies");
    }
    return struct {
        const Self = @This();
        pub const Options = namedFields(profiles, "Options", true);
        pub const State = namedFields(profiles, "State", false);
        pub const Error = blk: {
            var errors: type = error{};
            for (fields) |field| errors = errors || @field(profiles, field.name).Policies.Error;
            break :blk errors;
        };

        /// A set is itself a configured group. Nesting preserves field paths;
        /// preparing the root visits each leaf once, without runtime discovery.
        pub const Policies = struct {
            pub const Options = Self.Options;
            pub const State = Self.State;
            pub const Error = Self.Error;
            pub const runtime_policy = blk: {
                for (fields) |field| if (@field(profiles, field.name).Policies.runtime_policy) break :blk true;
                break :blk false;
            };
            pub fn prepare(options: Self.Options) (if (runtime_policy) Self.Error!Self.State else Self.State) {
                if (runtime_policy) return Self.prepare(options);
                return Self.prepare(options) catch unreachable; // all fixed leaves are verified at compile time
            }
        };

        pub fn prepare(options: Options) Error!State {
            var result: State = undefined;
            inline for (fields) |field| {
                const Binding = @field(profiles, field.name).Policies;
                @field(result, field.name) = if (Binding.runtime_policy)
                    try Binding.prepare(@field(options, field.name))
                else
                    Binding.prepare(@field(options, field.name));
            }
            return result;
        }
    };
}

fn namedFields(comptime profiles: anytype, comptime member: []const u8, comptime defaults: bool) type {
    const fields = std.meta.fields(@TypeOf(profiles));
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        const T = @field(@field(profiles, field.name).Policies, member);
        types[i] = T;
        attrs[i] = .{
            .default_value_ptr = if (defaults) @as(*const T, &@as(T, .{})) else null,
        };
    }
    return @Struct(.auto, null, std.meta.fieldNames(@TypeOf(profiles)), &types, &attrs);
}

/// Raw contiguous input, not decoded/concatenated input. The caller establishes
/// provenance; origin+length is checked without slicing or scanning the source.
pub const Fragment = struct {
    bytes: []const u8,
    origin: u32,
    pub const Error = error{ InvalidFragment, InvalidSpan };

    pub fn init(bytes: []const u8, origin: u32) Error!Fragment {
        if (bytes.len > location.max_source_len or @as(u64, origin) + bytes.len > location.max_source_len)
            return error.InvalidFragment;
        return .{ .bytes = bytes, .origin = origin };
    }

    /// Call for EACH primary, related and fix span. Never rebase an already
    /// mapped span. A processor-specific adapter knows its own payload fields.
    pub fn rebase(self: Fragment, local: location.Span) Error!location.Span {
        _ = try init(self.bytes, self.origin);
        if (local.endOffset() > self.bytes.len) return error.InvalidSpan;
        return .{ .start = self.origin + local.start, .len = local.len };
    }

    /// Select a raw child using parent-local coordinates. The child stores its
    /// final original-source origin, so leaf diagnostics are rebased only once.
    pub fn child(self: Fragment, local: location.Span) Error!Fragment {
        const original = try self.rebase(local);
        return .{ .bytes = self.bytes[local.start..@intCast(local.endOffset())], .origin = original.start };
    }

    pub fn fromSource(source: []const u8, span: location.Span) Error!Fragment {
        return (try init(source, 0)).child(span);
    }
};
