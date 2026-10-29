const dot = @import("dot_parser");
export fn rejected() void {
    _ = dot.processor.PolicySet(false);
}
