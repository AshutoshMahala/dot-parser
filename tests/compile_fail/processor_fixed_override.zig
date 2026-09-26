const dot = @import("dot_parser");
const Set = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}) });
export fn entry() void {
    _ = Set.prepare(.{ .dot = .{ .policy = .{} } }) catch unreachable;
}
