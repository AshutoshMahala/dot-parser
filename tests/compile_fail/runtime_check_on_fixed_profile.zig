const dot = @import("dot_parser");
export fn check(value: u8) bool {
    return dot.validatePolicy(.{ .validation = .{ .graph = .{
        .operator_mismatch = if (value == 0) .err else .warning,
    } } }) == .valid;
}
