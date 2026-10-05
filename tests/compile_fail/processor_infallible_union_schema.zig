const dot = @import("dot_parser");

const Schema = struct {
    pub const Policy = struct {};
    pub const Effective = struct {};
    pub const Error = error{};
    pub const Check = union(enum) { valid, invalid: u8 };
    pub const defaults: Effective = .{};
    pub fn resolve(_: Effective, _: Policy) Effective {
        return .{};
    }
    pub fn check(_: Effective, _: Policy) Check {
        return .valid;
    }
};

export fn entry() void {
    const Binding = dot.processor.PolicyBinding(Schema, .{ .runtime_policy = true });
    _ = Binding.prepare(.{});
}
