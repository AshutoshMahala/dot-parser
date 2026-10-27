const dot = @import("dot_parser");
export fn check() void {
    const span: dot.Span = .{ .start = 0, .len = 1 };
    _ = dot.identifier.fromName("a", span);
}
