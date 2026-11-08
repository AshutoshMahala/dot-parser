//! Bounded growing/shrinking slices for event construction and nesting scratch.
const std = @import("std");
const r = @import("resources.zig");
const storage = @import("session_storage.zig");
const p = @import("lowering_primitives.zig");

pub fn Slice(comptime T: type) type {
    return struct {
        growth: p.Reserve(T) = .{},
        compacting: []T = &.{},
        copied: usize = 0,
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.growth.deinit(a);
            storage.release(T, a, self.compacting);
        }
        pub fn step(self: *@This(), list: *std.ArrayList(T), count: usize, a: std.mem.Allocator) r.Error!bool {
            return self.growth.step(list, count, a);
        }
        pub fn stepCapped(self: *@This(), list: *std.ArrayList(T), count: usize, a: std.mem.Allocator, maximum: usize) r.Error!bool {
            return self.growth.stepCapped(list, count, a, maximum);
        }
        pub fn reserve(self: *@This(), a: std.mem.Allocator, slice: *[]T, written: usize, need: usize, maximum: usize) r.Error!bool {
            std.debug.assert(written <= slice.len and written <= need);
            var list: std.ArrayList(T) = .empty;
            list.items = slice.*[0..written];
            list.capacity = slice.len;
            const ready = try self.growth.stepCapped(&list, need - written, a, maximum);
            slice.* = list.allocatedSlice();
            return ready;
        }
        pub fn compact(self: *@This(), a: std.mem.Allocator, slice: *[]T, written: usize) r.Error!bool {
            if (self.compacting.len != 0) {
                const bytes = written * @sizeOf(T);
                if (self.copied < bytes) {
                    const end = self.copied + @min(64, bytes - self.copied);
                    @memcpy(std.mem.sliceAsBytes(self.compacting)[self.copied..end], std.mem.sliceAsBytes(slice.*)[self.copied..end]);
                    self.copied = end;
                    return false;
                }
                storage.release(T, a, slice.*);
                slice.* = self.compacting;
                self.compacting = &.{};
                self.copied = 0;
                return false;
            }
            if (slice.len == written) return true;
            if (written == 0) {
                storage.release(T, a, slice.*);
                slice.* = &.{};
                return false;
            }
            if (a.rawResize(std.mem.sliceAsBytes(slice.*), .of(T), written * @sizeOf(T), @returnAddress())) slice.len = written else self.compacting = try storage.allocate(T, a, written);
            return false;
        }
        pub fn compactList(self: *@This(), a: std.mem.Allocator, list: *std.ArrayList(T)) r.Error!bool {
            var slice = list.allocatedSlice();
            const ready = try self.compact(a, &slice, list.items.len);
            list.items = slice[0..list.items.len];
            list.capacity = slice.len;
            return ready;
        }
    };
}

/// The fixed specialization borrows named pools and never allocates or copies.
/// The caller still charges each state transition before invoking these helpers.
pub fn SliceFor(comptime T: type, comptime fixed: bool, comptime field: []const u8) type {
    if (!fixed) return Slice(T);
    return struct {
        pub fn deinit(_: *@This(), _: anytype) void {}
        pub fn step(_: *@This(), list: *std.ArrayList(T), count: usize, memory: anytype) r.Error!bool {
            const need = std.math.add(usize, list.items.len, count) catch return error.IndexLimit;
            try memory.ensure(field, need);
            memory.observe(field, need);
            return true;
        }
        pub fn stepCapped(self: *@This(), list: *std.ArrayList(T), count: usize, memory: anytype, _: usize) r.Error!bool {
            return self.step(list, count, memory);
        }
        pub fn reserve(_: *@This(), memory: anytype, slice: *[]T, written: usize, need: usize, _: usize) r.Error!bool {
            std.debug.assert(written <= slice.len and written <= need);
            try memory.ensure(field, need);
            slice.* = memory.slice(field)[0..need];
            memory.observe(field, need);
            return true;
        }
        pub fn compact(_: *@This(), _: anytype, slice: *[]T, written: usize) r.Error!bool {
            slice.len = written;
            return true;
        }
        pub fn compactList(_: *@This(), _: anytype, _: *std.ArrayList(T)) r.Error!bool {
            return true;
        }
    };
}
