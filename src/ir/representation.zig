//! IR storage identity is independent of execution policy and resource limits.
//! Encoding readers keep their existing, encoding-only specialization.
const encoding = @import("parser_support").encoding;

pub const Capabilities = struct {
    attributes: bool = true,
};

/// Optional acceleration only: disabling an index removes no semantic facts.
pub const Indexes = struct {
    connections: bool = false,
    scope_memberships: bool = false,

    pub fn any(self: Indexes) bool {
        return self.connections or self.scope_memberships;
    }
};

pub const Identity = struct {
    encodings: encoding.Capabilities,
    attributes: bool,
    indexes: Indexes = .{},

    pub fn from(comptime config: anytype) Identity {
        return .{
            .encodings = encoding.Capabilities.from(config.source_encodings),
            .attributes = config.capabilities.attributes,
            .indexes = if (@hasField(@TypeOf(config), "indexes")) config.indexes else .{},
        };
    }
};

pub fn requireAttributes(comptime enabled: bool) void {
    if (!enabled) @compileError("IR attributes are disabled; enable .capabilities.attributes for attribute access and effective ports");
}
