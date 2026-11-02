//! Untimed requested-byte accounting. Never substitutes allocator behavior.
//! A moving backing remap is opaque: only its returned size is observable.
const std = @import("std");
pub const Phase = enum { parse, validate, lower, release_document, release_ir };
pub const count = std.meta.tags(Phase).len;
pub const Stats = struct {
    start: usize = 0,
    end: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,
    allocated_bytes: usize = 0,
    frees: usize = 0,
    resize_ok: usize = 0,
    resize_failed: usize = 0,
    remap_ok: usize = 0,
    remap_failed: usize = 0,
    moving_remaps: usize = 0,
    // Confirmed failed-grow -> allocate -> free-old sequences only. Explicit
    // rehash allocations may not have a preceding resize, so this is a subset.
    growth_moves: usize = 0,
    growth_old_bytes: usize = 0,
    largest_growth_pair: usize = 0,
};
pub const Tracker = struct {
    backing: std.mem.Allocator,
    phase: Phase = .parse,
    stats: [count]Stats = @splat(.{}),
    live: usize = 0,
    peak: usize = 0,
    peak_phase: Phase = .parse,
    // An allocator may copy inside remap. Record a separate conservative
    // requested-byte bound, never present it as an observed simultaneous peak.
    remap_peak_bound: usize = 0,
    remap_bound_phase: Phase = .parse,
    pending: ?struct { old: []u8, next_len: usize, allocated: bool = false } = null,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    pub fn begin(self: *@This(), phase: Phase) void {
        self.phase = phase;
        self.stats[@backingInt(phase)] = .{ .start = self.live, .end = self.live, .peak = self.live };
        self.pending = null;
    }
    pub fn peakBound(self: *const @This()) usize {
        return @max(self.peak, self.remap_peak_bound);
    }
    pub fn boundPhase(self: *const @This()) Phase {
        return if (self.remap_peak_bound > self.peak) self.remap_bound_phase else self.peak_phase;
    }
    fn current(self: *@This()) *Stats {
        return &self.stats[@backingInt(self.phase)];
    }
    fn account(self: *@This(), old: usize, new: usize) void {
        self.live = self.live - old + new;
        const s = self.current();
        s.end = self.live;
        s.peak = @max(s.peak, self.live);
        if (self.live > self.peak) {
            self.peak = self.live;
            self.peak_phase = self.phase;
        }
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const ptr = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.current().allocations += 1;
        self.current().allocated_bytes += len;
        if (self.pending) |*p| {
            if (!p.allocated and p.next_len == len) p.allocated = true else self.pending = null;
        }
        self.account(0, len);
        return ptr;
    }
    fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!self.backing.rawResize(bytes, alignment, len, ra)) {
            self.current().resize_failed += 1;
            self.pending = if (len > bytes.len) .{ .old = bytes, .next_len = len } else null;
            return false;
        }
        self.pending = null;
        self.current().resize_ok += 1;
        self.account(bytes.len, len);
        return true;
    }
    fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const ptr = self.backing.rawRemap(bytes, alignment, len, ra) orelse {
            self.current().remap_failed += 1;
            self.pending = if (len > bytes.len) .{ .old = bytes, .next_len = len } else null;
            return null;
        };
        self.pending = null;
        self.current().remap_ok += 1;
        if (ptr != bytes.ptr) {
            self.current().moving_remaps += 1;
            if (self.live + len > self.remap_peak_bound) {
                self.remap_peak_bound = self.live + len;
                self.remap_bound_phase = self.phase;
            }
        }
        self.account(bytes.len, len);
        return ptr;
    }
    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.pending) |p| {
            if (p.allocated and p.old.ptr == bytes.ptr and p.old.len == bytes.len) {
                self.current().growth_moves += 1;
                self.current().growth_old_bytes += bytes.len;
                self.current().largest_growth_pair = @max(self.current().largest_growth_pair, bytes.len + p.next_len);
            }
        }
        self.pending = null;
        self.backing.rawFree(bytes, alignment, ra);
        self.current().frees += 1;
        self.account(bytes.len, 0);
    }
};

test "phase peaks include retained overlap and do not add disjoint maxima" {
    var t: Tracker = .{ .backing = std.testing.allocator };
    const a = t.allocator();
    t.begin(.parse);
    const document = try a.alloc(u8, 100);
    const temporary = try a.alloc(u8, 200);
    a.free(temporary);
    t.begin(.validate);
    t.begin(.lower);
    const graph = try a.alloc(u8, 150);
    t.begin(.release_document);
    a.free(document);
    t.begin(.release_ir);
    a.free(graph);
    try std.testing.expectEqual(@as(usize, 300), t.peak);
    try std.testing.expectEqual(.parse, t.peak_phase);
    try std.testing.expectEqual(@as(usize, 250), t.stats[@backingInt(Phase.lower)].peak);
    try std.testing.expectEqual(@as(usize, 100), t.stats[@backingInt(Phase.validate)].start);
    try std.testing.expectEqual(@as(usize, 0), t.live);
}

test "arena backing survives logical release and failed allocation changes nothing" {
    var backing: Tracker = .{ .backing = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(backing.allocator());
    var logical: Tracker = .{ .backing = arena.allocator() };
    const bytes = try logical.allocator().alloc(u8, 200);
    logical.allocator().free(bytes);
    try std.testing.expectEqual(@as(usize, 0), logical.live);
    try std.testing.expect(backing.live >= arena.queryCapacity());
    try std.testing.expect(backing.live > 0);
    arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), backing.live);
    var buffer: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var t: Tracker = .{ .backing = fixed.allocator() };
    try std.testing.expectError(error.OutOfMemory, t.allocator().alloc(u8, 2));
    try std.testing.expectEqual(@as(usize, 0), t.peak);
}

test "failed growth records the simultaneous old and new buffers" {
    var buffer: [1000]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var t: Tracker = .{ .backing = fixed.allocator() };
    const a = t.allocator();
    const old = try a.alloc(u8, 100);
    const blocker = try a.alloc(u8, 1);
    try std.testing.expect(!a.resize(old, 200));
    const next = try a.alloc(u8, 200);
    a.free(old);
    try std.testing.expectEqual(@as(usize, 301), t.peak);
    try std.testing.expectEqual(@as(usize, 300), t.stats[0].largest_growth_pair);
    try std.testing.expectEqual(@as(usize, 100), t.stats[0].growth_old_bytes);
    a.free(blocker);
    a.free(next);
    try std.testing.expectEqual(@as(usize, 0), t.live);
}

test "moving backing remaps have a separate conservative overlap bound" {
    const Moving = struct {
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, old: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
            const ptr = std.testing.allocator.rawAlloc(len, alignment, ra) orelse return null;
            @memcpy(ptr[0..@min(len, old.len)], old[0..@min(len, old.len)]);
            std.testing.allocator.rawFree(old, alignment, ra);
            return ptr;
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var context: u8 = 0;
    var t: Tracker = .{ .backing = .{ .ptr = &context, .vtable = &.{ .alloc = Moving.alloc, .resize = Moving.resize, .remap = Moving.remap, .free = Moving.free } } };
    const a = t.allocator();
    const old = try a.alloc(u8, 100);
    @memset(old, 42);
    const next = a.remap(old, 200).?;
    try std.testing.expectEqual(@as(usize, 200), t.peak);
    try std.testing.expectEqual(@as(usize, 300), t.peakBound());
    try std.testing.expectEqual(@as(usize, 1), t.stats[0].moving_remaps);
    a.free(next);
    try std.testing.expectEqual(@as(usize, 0), t.live);
}
