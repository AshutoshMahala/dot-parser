//! Allocation-free scanning timing; source construction is outside the timer.
//! Run with: zig build bench-lexer -Doptimize=ReleaseFast
const std = @import("std");
const dot = @import("dot_parser");

const rounds = 9;
const warmups = 2;
const repetitions = 65536;

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &file.interface;
    const cases = .{
        .{ "short IDs/punctuation", "a;b;c;d;x=y;[k=v]" },
        .{ "short IDs/trivia", "a b\tc\r\nd -- e;\n" },
        .{ "keywords/numerals", "graph digraph strict subgraph node edge 1 -2 .3 -.4 5.6 " },
        .{ "quotes/comments", "\"a\"+\"b\" /*comment*/ \"c\\\"d\" //line\n" },
        .{ "long identifier", "abcdefghijklmnopqrstuvwxyz_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ;" },
    };
    inline for (cases) |entry| {
        const source = try init.arena.allocator().alloc(u8, entry[1].len * repetitions);
        for (0..repetitions) |i| @memcpy(source[i * entry[1].len ..][0..entry[1].len], entry[1]);
        var times: [rounds]u64 = undefined;
        const expected = try scan(source);
        for (0..warmups + rounds) |round| {
            const start = std.Io.Clock.Timestamp.now(init.io, .awake);
            const checksum = try scan(source);
            const end = std.Io.Clock.Timestamp.now(init.io, .awake);
            if (checksum != expected) return error.UnstableChecksum;
            if (round >= warmups) times[round - warmups] = @intCast(start.durationTo(end).raw.nanoseconds);
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        try out.print("{s}: {d} bytes, median {d:.2} ms ({d:.2}–{d:.2}), checksum {d}\n", .{
            entry[0],                                source.len,                                       @as(f64, @floatFromInt(times[rounds / 2])) / 1e6,
            @as(f64, @floatFromInt(times[0])) / 1e6, @as(f64, @floatFromInt(times[rounds - 1])) / 1e6, expected,
        });
    }
    try out.flush();
}

noinline fn scan(source: []const u8) !u64 {
    var lexer = dot.lexer.Lexer.init(source);
    var checksum: u64 = 0;
    while (true) switch (lexer.next()) {
        .failure => return error.InvalidFixture,
        .token => |token| {
            checksum +%= @intFromEnum(token.tag);
            checksum +%= token.span.start.byte_offset;
            checksum +%= token.span.start.line;
            checksum +%= token.span.start.byte_column;
            checksum +%= token.span.byte_len;
            if (token.tag == .eof) return checksum;
        },
    };
}
