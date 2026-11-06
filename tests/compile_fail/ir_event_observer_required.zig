const std = @import("std");
const dot = @import("dot_parser");
const Observer = struct {
    pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
        return .proceed;
    }
    pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
};
pub fn main() !void {
    const IR = dot.ir.Lowering(.{}).FromEvents(dot.Profile(.{})).Observe(Observer);
    var result = try IR.parse(std.heap.page_allocator, "digraph{}", .{});
    defer result.deinit();
}
