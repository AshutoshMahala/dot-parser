//! Context-specific runs, not a second grammar or a token buffer.
//! Vectors never read outside source. A block call examines a <=64-byte window;
//! boundary bytes remain for the common scalar transition machine.
const std = @import("std");
const Backend = @import("policy.zig").ScannerBackend;
pub const Mode = enum { text, name, single_value, double_value, space, comment, cdata };
pub const Run = struct {
    consumed: u32,
    /// Exclusive lookahead distance, not a count of physical reads/rereads.
    examined: u32,
};
const width = @min(std.simd.suggestVectorLength(u8) orelse 16, 64);
const Bytes = @Vector(width, u8);
const Bits = std.meta.Int(.unsigned, width);

fn splat(value: u8) Bytes {
    return @splat(value);
}
fn mask(value: @Vector(width, bool)) Bits {
    return @bitCast(value);
}
fn goodMask(comptime mode: Mode, bytes: Bytes) Bits {
    const space = mask(bytes == splat(' ')) | mask(bytes == splat('\t')) |
        mask(bytes == splat('\r')) | mask(bytes == splat('\n'));
    if (mode == .space) return space;
    if (mode == .name) return (mask(bytes >= splat('a')) & mask(bytes <= splat('z'))) |
        (mask(bytes >= splat('A')) & mask(bytes <= splat('Z'))) |
        (mask(bytes >= splat('0')) & mask(bytes <= splat('9'))) |
        mask(bytes >= splat(0x80)) | mask(bytes == splat('_')) |
        mask(bytes == splat(':')) | mask(bytes == splat('-')) | mask(bytes == splat('.'));
    var good = mask(bytes >= splat(0x20)) | space;
    switch (mode) {
        .text, .single_value, .double_value => {
            good &= ~(mask(bytes == splat('<')) | mask(bytes == splat('&')));
            if (mode == .single_value) good &= ~mask(bytes == splat('\''));
            if (mode == .double_value) good &= ~mask(bytes == splat('"'));
        },
        .comment => good &= ~mask(bytes == splat('-')),
        .cdata => good &= ~mask(bytes == splat(']')),
        .space, .name => unreachable,
    }
    return good;
}
fn goodByte(comptime mode: Mode, byte: u8) bool {
    const space = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
    if (mode == .space) return space;
    if (mode == .name) return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte >= 0x80 or
        byte == '_' or byte == ':' or byte == '-' or byte == '.';
    if (byte < 0x20 and !space) return false;
    return switch (mode) {
        .text => byte != '<' and byte != '&',
        .single_value => byte != '<' and byte != '&' and byte != '\'',
        .double_value => byte != '<' and byte != '&' and byte != '"',
        .comment => byte != '-',
        .cdata => byte != ']',
        .space, .name => unreachable,
    };
}

pub fn prefix(comptime backend: Backend, comptime mode: Mode, source: []const u8, start: u32) Run {
    // Source length has already been checked against the u32 domain.
    const remaining: u32 = @intCast(source.len - start);
    const limit = if (backend == .block) @min(remaining, 64) else remaining;
    var consumed: u32 = 0;
    if (backend == .block) {
        // Short names/values dominate dense markup. Probe at most four bytes
        // before paying for vector masks. Long runs reexamine this fixed prefix
        // so the vector window still consists of whole native-width chunks.
        for (0..@min(limit, 4)) |i| {
            if (!goodByte(mode, source[start + i])) return .{ .consumed = @intCast(i), .examined = @intCast(i + 1) };
        }
        while (limit - consumed >= width) {
            const bytes: Bytes = source[start + consumed ..][0..width].*;
            const bad = ~goodMask(mode, bytes);
            if (bad != 0) return .{ .consumed = consumed + @as(u32, @intCast(@ctz(bad))), .examined = consumed + width };
            consumed += width;
        }
    }
    while (consumed < limit) : (consumed += 1) {
        if (!goodByte(mode, source[start + consumed])) return .{ .consumed = consumed, .examined = consumed + 1 };
    }
    return .{ .consumed = consumed, .examined = consumed };
}

test "every byte and vector lane agrees with scalar predicates" {
    inline for (comptime std.meta.tags(Mode)) |mode| {
        for (0..256) |byte| {
            var bytes: [width]u8 = undefined;
            @memset(&bytes, @intCast(byte));
            try std.testing.expectEqual(@as(Bits, if (goodByte(mode, @intCast(byte))) std.math.maxInt(Bits) else 0), goodMask(mode, bytes));
            for (0..width) |lane| {
                @memset(&bytes, 'a');
                bytes[lane] = @intCast(byte);
                var expected: Bits = 0;
                for (bytes, 0..) |b, i| if (goodByte(mode, b)) {
                    expected |= @as(Bits, 1) << @intCast(i);
                };
                try std.testing.expectEqual(expected, goodMask(mode, bytes));
            }
        }
    }
}
