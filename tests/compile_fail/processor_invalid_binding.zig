const dot = @import("dot_parser");
const Set = dot.processor.PolicySet(.{ .content = struct {} });
export fn entry() void {
    _ = Set.prepare(.{}) catch unreachable;
}
