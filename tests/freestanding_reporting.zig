//! Consume the shared retention policy on 32-bit targets using caller memory only.
const std = @import("std");
const reporting = @import("parser_support").reporting;

export fn retain_findings(buffer: [*]u8, len: usize, maximum: u16, unlimited: bool, attempts: u32) u32 {
    var allocator = std.heap.FixedBufferAllocator.init(buffer[0..len]);
    var bag = reporting.GrowableBag(u8).init(allocator.allocator(), .{
        .max_entries = if (unlimited) .unlimited else .{ .limited = maximum },
    });
    defer bag.deinit();
    var index: u32 = 0;
    while (index < attempts) : (index += 1) {
        const action = bag.push(@truncate(index)) catch break;
        if (action == .stop) break;
    }
    return @intCast(bag.items().len);
}
