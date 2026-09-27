//! Context-specific runs, not a second grammar or a token buffer.
//! Vectors never read outside source. Bounded block calls use <=64-byte windows;
//! plain calls scan the whole run. Boundaries stay with the scalar state machine.
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

pub fn prefix(comptime backend: Backend, comptime bounded: bool, comptime mode: Mode, source: []const u8, start: u32) Run {
    // Source length has already been checked against the u32 domain.
    const remaining: u32 = @intCast(source.len - start);
    const limit = if (backend == .block and bounded) @min(remaining, 64) else remaining;
    var consumed: u32 = 0;
    if (backend == .block) {
        // Short names/values dominate dense markup. Probe at most four bytes
        // before paying for vector masks. Long runs reexamine this fixed prefix
        // so the vector window still consists of whole native-width chunks.
        const probe_len = @min(limit, 4);
        for (0..probe_len) |i| {
            if (!goodByte(mode, source[start + i])) return .{ .consumed = @intCast(i), .examined = @intCast(i + 1) };
        }
        // In plain mode with no full vector available, resume after the probe.
        // Keep bounded probe/tail control flow intact: changing it regressed
        // cancellation-enabled long runs in native benchmarks.
        if (!bounded and limit < width) return scalarTail(mode, source, start, probe_len, limit);
        if (!bounded) {
            // Most markup runs end in the first vector. Keep that return ahead
            // of the unbounded loop's induction/bookkeeping.
            const bytes: Bytes = source[start..][0..width].*;
            const bad = ~goodMask(mode, bytes);
            if (bad != 0) return .{ .consumed = @intCast(@ctz(bad)), .examined = width };
            consumed = width;
        }
        while (limit - consumed >= width) {
            const bytes: Bytes = source[start + consumed ..][0..width].*;
            const bad = ~goodMask(mode, bytes);
            if (bad != 0) return .{ .consumed = consumed + @as(u32, @intCast(@ctz(bad))), .examined = consumed + width };
            consumed += width;
        }
        if (!bounded) return scalarTail(mode, source, start, consumed, limit);
    }
    // Keep the scalar backend's loop local; routing it through the block-only
    // short-tail helper adds induction bookkeeping in native optimized builds.
    while (consumed < limit) : (consumed += 1) {
        if (!goodByte(mode, source[start + consumed])) return .{ .consumed = consumed, .examined = consumed + 1 };
    }
    return .{ .consumed = consumed, .examined = consumed };
}

fn scalarTail(comptime mode: Mode, source: []const u8, start: u32, from: u32, limit: u32) Run {
    var consumed = from;
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

test "plain block runs have no window cap while bounded runs stop at 64 bytes" {
    var bytes: [4096]u8 = undefined;
    inline for (comptime std.meta.tags(Mode)) |mode| {
        @memset(&bytes, if (mode == .space) ' ' else 'a');
        // Nonzero source offsets exercise the source-relative frontier math.
        inline for (.{ 0, 1, 15, 63, 64 }) |start| {
            const plain = prefix(.block, false, mode, &bytes, start);
            const bounded = prefix(.block, true, mode, &bytes, start);
            try std.testing.expectEqual(Run{ .consumed = bytes.len - start, .examined = bytes.len - start }, plain);
            try std.testing.expectEqual(Run{ .consumed = 64, .examined = 64 }, bounded);
        }
    }
}

test "block probes and tails preserve the first boundary and exact source bounds" {
    var bytes: [256]u8 = undefined;
    inline for (comptime std.meta.tags(Mode)) |mode| {
        const good: u8 = if (mode == .space) ' ' else 'a';
        const stop: u8 = switch (mode) {
            .space, .name => '!',
            .text => '&',
            .single_value => '\'',
            .double_value => '"',
            .comment => '-',
            .cdata => ']',
        };
        for (0..130) |len| {
            @memset(&bytes, good);
            const source = bytes[3 .. 3 + len];
            inline for (.{ false, true }) |bounded| {
                const limit: u32 = @intCast(if (bounded) @min(len, 64) else len);
                try std.testing.expectEqual(Run{ .consumed = limit, .examined = limit }, prefix(.block, bounded, mode, source, 0));
                for (0..len) |at| {
                    source[at] = stop;
                    const got = prefix(.block, bounded, mode, source, 0);
                    try std.testing.expectEqual(@min(limit, @as(u32, @intCast(at))), got.consumed);
                    try std.testing.expect(got.examined >= got.consumed and got.examined <= limit);
                    if (at < limit) try std.testing.expect(got.examined > at);
                    source[at] = good;
                }
            }
        }
    }
}
