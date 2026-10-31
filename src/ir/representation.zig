//! IR storage identity is independent of execution policy and resource limits.
//! Encoding readers keep their existing, encoding-only specialization.
const encoding = @import("parser_support").encoding;

pub const Capabilities = struct {
    attributes: bool = true,
};

pub const Identity = struct {
    encodings: encoding.Capabilities,
    attributes: bool,

    pub fn from(comptime config: anytype) Identity {
        return .{
            .encodings = encoding.Capabilities.from(config.source_encodings),
            .attributes = config.capabilities.attributes,
        };
    }
};

pub fn requireAttributes(comptime enabled: bool) void {
    if (!enabled) @compileError("IR attributes are disabled; enable .capabilities.attributes for attribute access and effective ports");
}
