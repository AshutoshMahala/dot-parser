//! Same logical-name contract as DOT identifiers. Hashes never replace equality.
const std = @import("std");
const encoding = @import("parser_support").encoding;
const identifier = @import("../dot/identifier.zig");
const resources = @import("resources.zig");
const Error = resources.Error;

pub fn hash(comptime actual: encoding.Actual, raw: []const u8, work: *resources.Work) Error!u64 {
    try work.spend(raw.len);
    const result = try identifier.ForEncoding(actual).assumeParsed(raw).hash();
    try work.spend(0);
    return result;
}
pub fn eql(comptime actual: encoding.Actual, a: []const u8, b: []const u8, work: *resources.Work) Error!bool {
    try work.spend(@as(u64, a.len) + b.len);
    const result = try identifier.ForEncoding(actual).assumeParsed(a).eql(identifier.ForEncoding(actual).assumeParsed(b));
    try work.spend(0);
    return result;
}

/// Query names are logical UTF-8 bytes, not DOT spellings. Byte-profile names
/// retain raw bytes even if encoding validation was disabled. No normalization.
pub fn matches(comptime actual: encoding.Actual, raw: []const u8, value: []const u8, work: *resources.Work) Error!bool {
    try work.spend(@as(u64, raw.len) + value.len);
    const E = encoding.Reader(actual);
    var chunks: @import("../dot/identifier_value.zig").ForEncoding(actual).Chunks = .{ .raw = raw };
    var offset: usize = 0;
    while (chunks.next()) |chunk| {
        if (comptime E.width == 1) {
            if (chunk.len > value.len - offset or !std.mem.eql(u8, chunk, value[offset..][0..chunk.len])) return false;
            offset += chunk.len;
        } else {
            var at: usize = 0;
            while (at < chunk.len) {
                const scalar = E.decode(chunk, at) catch return error.InvalidIdentifier;
                at += scalar.len;
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(scalar.scalar, &bytes) catch return error.InvalidIdentifier;
                if (len > value.len - offset or !std.mem.eql(u8, bytes[0..len], value[offset..][0..len])) return false;
                offset += len;
            }
        }
        try work.spend(0);
    }
    return offset == value.len;
}

/// Stream an already parsed name without re-lexing it or allocating a copy.
/// Like identity, byte profiles preserve raw bytes; native profiles emit UTF-8.
pub fn write(comptime actual: encoding.Actual, raw: []const u8, writer: anytype, work: *resources.Work) !void {
    return writeImpl(actual, false, raw, writer, work);
}

/// Borrowed logical-name formatter. Constructed only from names interned by
/// lowering, which already checked native decoding. Source must stay immutable.
pub fn Formatted(comptime caps: encoding.Capabilities) type {
    return struct {
        raw: []const u8,
        actual: encoding.Actual,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.actual) {
                inline else => |actual| if (comptime caps.allows(actual)) {
                    try writeImpl(actual, true, self.raw, writer, {});
                } else unreachable, // The owning IR admitted this encoding.
            }
        }
    };
}

fn writeImpl(comptime actual: encoding.Actual, comptime formatting: bool, raw: []const u8, writer: anytype, work: if (formatting) void else *resources.Work) !void {
    if (!formatting) try work.spend(raw.len);
    const E = encoding.Reader(actual);
    var chunks: @import("../dot/identifier_value.zig").ForEncoding(actual).Chunks = .{ .raw = raw };
    while (chunks.next()) |chunk| {
        if (comptime E.width == 1) {
            try writer.writeAll(chunk);
        } else {
            var at: usize = 0;
            while (at < chunk.len) {
                const scalar = E.decode(chunk, at) catch {
                    if (formatting) unreachable; // Lowering validated this immutable logical name.
                    return error.InvalidIdentifier;
                };
                at += scalar.len;
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(scalar.scalar, &bytes) catch {
                    if (formatting) unreachable; // A decoded native scalar is representable in UTF-8.
                    return error.InvalidIdentifier;
                };
                try writer.writeAll(bytes[0..len]);
            }
        }
        if (!formatting) try work.spend(0);
    }
}

pub const empty = std.math.maxInt(u32);

/// Open addressing with explicitly charged probes and rehashing. Owners provide
/// immutable hashes; callers perform fallible, collision-checked name equality.
pub const Table = struct {
    slots: []u32 = &.{},
    count: u32 = 0,

    pub fn deinit(t: *Table, a: std.mem.Allocator) void {
        a.free(t.slots);
    }
    pub fn prepare(t: *Table, a: std.mem.Allocator, work: *resources.Work, owner: anytype) Error!void {
        if (t.slots.len != 0 and t.count < t.slots.len / 2) return;
        const capacity = if (t.slots.len == 0) 16 else std.math.mul(usize, t.slots.len, 2) catch return error.IndexLimit;
        var next: Table = .{ .slots = try a.alloc(u32, capacity) };
        errdefer next.deinit(a);
        for (next.slots) |*slot| {
            try work.spend(1);
            slot.* = empty;
        }
        for (t.slots) |id| {
            try work.spend(1);
            if (id != empty) try next.insert(owner.hashFor(id), id, work);
        }
        t.deinit(a);
        t.* = next;
    }
    pub fn insert(t: *Table, h: u64, id: u32, work: *resources.Work) Error!void {
        var at: usize = @intCast(h & (t.slots.len - 1));
        while (true) : (at = (at + 1) & (t.slots.len - 1)) {
            try work.spend(1);
            if (t.slots[at] == empty) {
                t.slots[at] = id;
                t.count += 1;
                return;
            }
        }
    }
};
