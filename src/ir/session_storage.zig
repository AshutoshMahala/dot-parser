//! Opt-in session growth. Allocation is an external call; library copying is
//! split into <=64-byte chunks. No moving realloc or hidden ArrayList copy.
const std = @import("std");
const r = @import("resources.zig");

/// Allocator.alloc/free poison entire slices in safety builds. Use the raw
/// callback boundary here so that initialization remains our metered work,
/// rather than an implicit unbounded memset. Every exposed item is initialized
/// before reading; alignment/size arithmetic still remains checked.
pub fn allocate(comptime T: type, a: std.mem.Allocator, count: usize) r.Error![]T {
    if (count == 0) return &.{};
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.IndexLimit;
    const raw = a.rawAlloc(bytes, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    const pointer: [*]T = @ptrCast(@alignCast(raw));
    return pointer[0..count];
}
pub fn release(comptime T: type, a: std.mem.Allocator, items: []T) void {
    if (items.len != 0) a.rawFree(std.mem.sliceAsBytes(items), .of(T), @returnAddress());
}

pub fn Growth(comptime T: type) type {
    if (@sizeOf(T) == 0 or @sizeOf(T) > 64) @compileError("session growth requires records of 1..64 bytes");
    return struct {
        pending: []T = &.{},
        copied: u32 = 0,

        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            a.free(self.pending);
        }
        /// Call once per credit. False means progress, not failure. Keep list
        /// unchanged until true; old and new storage both count against limits.
        pub fn step(self: *@This(), list: *std.ArrayList(T), a: std.mem.Allocator) r.Error!bool {
            if (self.pending.len != 0) {
                if (self.copied < list.items.len) {
                    const end = self.copied + @min(list.items.len - self.copied, @max(1, 64 / @sizeOf(T)));
                    @memcpy(self.pending[self.copied..end], list.items[self.copied..end]);
                    self.copied = @intCast(end);
                } else {
                    release(T, a, list.allocatedSlice());
                    list.items = self.pending[0..list.items.len];
                    list.capacity = self.pending.len;
                    self.pending = &.{};
                    self.copied = 0;
                }
                return false;
            }
            if (list.items.len < list.capacity) return true;
            if (list.items.len >= std.math.maxInt(u32) - 1) return error.IndexLimit;
            // Match ordinary ArrayList append capacity, so bounded copying
            // does not accidentally change the retained-memory growth curve.
            const capacity = @min(std.math.maxInt(u32) - 1, std.ArrayList(T).growCapacity(list.items.len + 1));
            const old = list.allocatedSlice();
            if (old.len != 0 and a.resize(old, capacity)) {
                list.items = old.ptr[0..list.items.len];
                list.capacity = capacity;
            } else self.pending = try allocate(T, a, capacity);
            return false;
        }
    };
}
