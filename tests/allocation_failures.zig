//! Deterministic allocation-failure sweeps across Zig allocator versions.
const std = @import("std");

pub fn check(allocator: std.mem.Allocator, comptime probe: anytype, args: anytype) !void {
    // SafeAllocator may remap depending on address placement. Refuse remapping
    // and resizing so every growth/handoff exercises its allocating fallback,
    // and a failure index always identifies the same allocation. The backing
    // testing allocator still checks leaks; dedicated tests cover remapping.
    var backing = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), probe, args);
}
