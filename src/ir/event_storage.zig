//! Private construction pages. Large event pools grow without repeatedly
//! copying their entire prefix; publication still exposes one ordinary slice.
const std = @import("std");
const r = @import("resources.zig");

pub fn Pages(comptime T: type) type {
    return WithPageCapacity(T, 16 * 1024);
}

pub fn PagesFor(comptime T: type, comptime fixed: bool, comptime field: []const u8) type {
    if (!fixed) return Pages(T);
    return struct {
        base: u32 = 0,
        pub fn deinit(_: *@This(), _: anytype) void {}
        pub inline fn ensure(_: *@This(), a: anytype, _: *r.Work, current: *[]T, written: u32, _: u32) r.Error!void {
            // A fixed pool never moves. Bind it once, then check the retained
            // slice before reconstructing the same view for every record.
            if (written < current.len) return;
            try a.ensure(field, @as(usize, written) + 1);
            current.* = a.slice(field);
        }
        pub fn finish(_: *@This(), _: anytype, _: *r.Work, current: *[]T, written: u32) r.Error!void {
            current.* = current.*[0..written];
        }
    };
}

fn WithPageCapacity(comptime T: type, comptime page_capacity: u32) type {
    return struct {
        const Self = @This();
        completed: std.ArrayList([]T) = .empty,
        base: u32 = 0,

        // The builder owns the current page; this helper owns completed pages.
        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            for (self.completed.items) |page| a.free(page);
            self.completed.deinit(a);
            self.* = .{};
        }

        pub inline fn ensure(self: *Self, a: std.mem.Allocator, work: *r.Work, current: *[]T, written: u32, maximum: u32) r.Error!void {
            if (written - self.base < current.len) return;
            try self.grow(a, work, current, written, maximum);
        }

        noinline fn grow(self: *Self, a: std.mem.Allocator, work: *r.Work, current: *[]T, written: u32, maximum: u32) r.Error!void {
            if (written >= maximum) return error.IndexLimit;
            if (current.len == page_capacity) {
                try work.spend(1);
                if (self.completed.items.len == self.completed.capacity) try work.spend(self.completed.items.len);
                try self.completed.append(a, current.*);
                self.base = written;
                current.* = &.{};
            }
            const ceiling = @min(page_capacity, maximum - self.base);
            // Only the first page grows gradually. Later full pages allocate
            // once; a short source tail caps the last page conservatively.
            const capacity = if (self.base == 0) @min(ceiling, std.ArrayList(T).growCapacity(current.len + 1)) else ceiling;
            try work.spend(current.len);
            current.* = try a.realloc(current.*, capacity);
        }

        pub fn finish(self: *Self, a: std.mem.Allocator, work: *r.Work, current: *[]T, written: u32) r.Error!void {
            if (self.completed.items.len == 0) {
                if (current.len == written) return;
                try work.spend(written);
                current.* = try a.realloc(current.*, written);
                return;
            }
            const output = try a.alloc(T, written);
            errdefer a.free(output);
            var at: usize = 0;
            for (self.completed.items) |page| {
                for (page, output[at..][0..page.len]) |value, *slot| {
                    try work.spend(1);
                    slot.* = value;
                }
                at += page.len;
            }
            for (current.*[0 .. written - self.base], output[at..]) |value, *slot| {
                try work.spend(1);
                slot.* = value;
            }
            self.deinit(a);
            a.free(current.*);
            current.* = output;
        }
    };
}

test "event pages clean up every allocation failure and preserve output order" {
    const Run = struct {
        fn run(a: std.mem.Allocator) !void {
            var pages: WithPageCapacity(u32, 4) = .{};
            defer pages.deinit(a);
            var current: []u32 = &.{};
            defer a.free(current);
            var work = try r.Work.init(.{}, null);
            for (0..13) |i| {
                try pages.ensure(a, &work, &current, @intCast(i), 13);
                current[i - pages.base] = @intCast(i);
            }
            try pages.finish(a, &work, &current, 13);
            for (current, 0..) |value, i| try std.testing.expectEqual(i, value);
            try std.testing.expectEqual(@as(usize, 13), current.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}

test "event page publication checks every copied record and releases failed output" {
    const a = std.testing.allocator;
    var pages: WithPageCapacity(u32, 4) = .{};
    defer pages.deinit(a);
    var current: []u32 = &.{};
    defer a.free(current);
    var work = try r.Work.init(.{}, null);
    for (0..13) |i| {
        try pages.ensure(a, &work, &current, @intCast(i), 13);
        current[i - pages.base] = @intCast(i);
    }
    work = try r.Work.init(.{ .max_work = 12 }, null);
    try std.testing.expectError(error.WorkLimit, pages.finish(a, &work, &current, 13));
    try std.testing.expectEqual(@as(u64, 0), work.remaining);
    const Cancel = struct {
        calls: usize = 0,
        fn check(raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.calls == 3;
        }
    };
    var cancel: Cancel = .{};
    work = try r.Work.init(.{}, .{ .context = &cancel, .is_requested = Cancel.check });
    try std.testing.expectError(error.Cancelled, pages.finish(a, &work, &current, 13));
    try std.testing.expectEqual(@as(usize, 3), cancel.calls);
    work = try r.Work.init(.{ .max_work = 13 }, null);
    try pages.finish(a, &work, &current, 13);
    try std.testing.expectEqual(@as(u64, 0), work.remaining);
    for (current, 0..) |value, i| try std.testing.expectEqual(i, value);
}
