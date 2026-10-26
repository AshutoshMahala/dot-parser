//! IR resource accounting. Total operation/iterator-lifetime limits, not
//! replenishable credits or deadlines. No global allocator or OS dependencies.
const std = @import("std");
pub const Cancellation = @import("parser_support").execution.Cancellation;

pub const Error = error{
    OutOfMemory,
    MemoryLimit,
    WorkLimit,
    NodeLimit,
    ScopeLimit,
    MentionLimit,
    ConnectionLimit,
    AttributeLimit,
    AttributeStateLimit,
    EdgeLimit,
    PairLimit,
    IndexLimit,
    Cancelled,
    IncompleteDocument,
    InvalidDocument,
    InvalidIdentifier,
    InvalidHandle,
    UnsupportedEncoding,
    UnsupportedSemantics,
    PoolExhausted,
    BufferTooSmall,
    InvalidStorage,
    StorageRequired,
};

/// Finite convenience defaults, not promises about acceptable graph size.
/// Counts/indices are u32; candidate pair visits and total work are u64.
pub const Limits = struct {
    max_nodes: u32 = 1_000_000,
    max_scopes: u32 = 100_000,
    max_mentions: u32 = 4_000_000,
    max_connections: u32 = 2_000_000,
    max_attributes: u32 = 2_000_000,
    /// Persistent attribute-map cells during lowering (including history), or
    /// winning explicit/derived (edge, key) cells during attribute materialization.
    max_attribute_states: u32 = 8_000_000,
    max_edges: u32 = 1_000_000,
    max_pairs: u64 = 4_000_000,
    max_work: u64 = 100_000_000,
    /// Peak live requested bytes allocated by this operation, including
    /// temporary old/new growth buffers. Fixed lowering instead counts the full
    /// bound retained + scratch reservation. Excludes borrowed inputs/allocator RSS.
    max_bytes: usize = 256 * 1024 * 1024,
};

pub const Options = struct {
    limits: ?Limits = null,
    cancellation: ?Cancellation = null,
};

pub const Work = struct {
    remaining: u64,
    cancellation: ?Cancellation,
    pub fn init(limits: Limits, cancellation: ?Cancellation) Error!Work {
        if (cancellation) |c| if (c.requested()) return error.Cancelled;
        return .{ .remaining = limits.max_work, .cancellation = cancellation };
    }
    /// Poll before accounted work. Name primitives are charged by the complete
    /// byte length before invocation and polled afterward; not hard deadlines.
    pub fn spend(w: *Work, count: u64) Error!void {
        if (w.cancellation) |c| if (c.requested()) return error.Cancelled;
        if (count > w.remaining) return error.WorkLimit;
        w.remaining -= count;
    }
};

/// Scoped allocator wrapper. Returned objects retain only the original allocator,
/// never this stack-local wrapper. The same backing allocator frees their slices.
pub const Memory = struct {
    backing: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    exceeded: bool = false,

    pub fn allocator(m: *Memory) std.mem.Allocator {
        return .{ .ptr = m, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn admit(m: *Memory, old: usize, new: usize) bool {
        if (new > old and new - old > m.limit - m.live) {
            m.exceeded = true;
            return false;
        }
        return true;
    }
    fn account(m: *Memory, old: usize, new: usize) void {
        m.live = m.live - old + new;
        m.peak = @max(m.peak, m.live);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const m: *Memory = @ptrCast(@alignCast(ctx));
        m.exceeded = false;
        if (!m.admit(0, len)) return null;
        const ptr = m.backing.rawAlloc(len, alignment, ra) orelse return null;
        m.account(0, len);
        return ptr;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const m: *Memory = @ptrCast(@alignCast(ctx));
        m.exceeded = false;
        if (!m.admit(buf.len, len)) return false;
        if (!m.backing.rawResize(buf, alignment, len, ra)) return false;
        m.account(buf.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const m: *Memory = @ptrCast(@alignCast(ctx));
        // Do not hide a moving realloc's old+new overlap from the peak limit.
        // Growth uses resize-in-place or an accounted allocate/copy/free pair.
        if (len > buf.len) {
            if (!resize(ctx, buf, alignment, len, ra)) return null;
            return buf.ptr;
        }
        if (!m.backing.rawResize(buf, alignment, len, ra)) return null;
        m.account(buf.len, len);
        return buf.ptr;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const m: *Memory = @ptrCast(@alignCast(ctx));
        m.backing.rawFree(buf, alignment, ra);
        m.live -= buf.len;
    }
    pub fn failure(m: *const Memory, err: Error) Error {
        if (err == error.OutOfMemory) {
            if (m.exceeded) return error.MemoryLimit;
            if (m.backing.vtable == unavailableAllocator().vtable) return error.StorageRequired;
        }
        return err;
    }
};

/// Missing later-query storage is not OOM. Never used to construct fixed pools.
pub fn unavailableAllocator() std.mem.Allocator {
    const Missing = struct {
        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
            unreachable;
        }
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
        const marker: u8 = 0;
    };
    // The context is never dereferenced; keep it defined when passed through
    // generic allocator wrappers, including in safety-enabled builds.
    return .{ .ptr = @constCast(&Missing.marker), .vtable = &Missing.vtable };
}

pub fn index(n: usize) Error!u32 {
    return if (n >= std.math.maxInt(u32)) error.IndexLimit else @intCast(n);
}
