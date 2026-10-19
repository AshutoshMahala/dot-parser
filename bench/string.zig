//! Run-to-completion throughput; inputs allocated once outside measurement.
//! Decimal MB/s of physical source bytes, no diagnostic retention allocation.
const std = @import("std");
const s = @import("string_processor");

fn Checker(comptime text: []const u8, comptime folding: bool, comptime custom: bool) type {
    @setEvalBranchQuota(200_000);
    return s.Profile(.{
        .source_encodings = &.{ .utf8, .utf16, .utf32 },
        .unicode_case_folding = folding,
        .custom = if (custom) s.validators.Equals else s.validators.None,
        .policy = .{
            .comparison = if (folding) .case_insensitive else .case_sensitive,
            .custom = if (custom) text else {},
            .validation = .{
                .equals = .{ .expected = text, .severity = if (custom) .off else .err },
                .custom = if (custom) .err else .off,
            },
        },
    });
}

noinline fn run(comptime P: type, bytes: []const u8, actual: s.ActualEncoding) bool {
    return (P.parseAndValidate(.{ .bytes = bytes, .origin = 0 }, P.Sink.discard, .{ .encoding = actual }) catch unreachable).valid();
}

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(1_000_000);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print("Result={d} Diagnostic={d}; processor heap allocations=0 (discard sink)\n", .{ @sizeOf(s.Result), @sizeOf(s.Diagnostic) });
    inline for (.{ "Seattle", "Straße 中文 😀", "The quick brown fox. " ** 200 }) |text| {
        inline for (.{ s.ActualEncoding.utf8, .utf16le, .utf32le }) |actual| {
            const buffer = try init.gpa.alloc(u8, text.len * 4);
            defer init.gpa.free(buffer);
            const bytes = encode(actual, text, buffer);
            inline for (.{ false, true }) |folding| {
                inline for (.{ false, true }) |custom| {
                    const P = Checker(text, folding, custom);
                    const iterations = @max(1000, 4_000_000 / bytes.len);
                    var times: [7]u64 = undefined;
                    var accepted: usize = 0;
                    for (0..9) |sample| {
                        const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
                        for (0..iterations) |_| {
                            std.mem.doNotOptimizeAway(bytes.ptr);
                            accepted += @intFromBool(run(P, bytes, actual));
                        }
                        const end = std.Io.Clock.Timestamp.now(init.io, .awake);
                        if (sample >= 2) times[sample - 2] = @intCast(begin.durationTo(end).raw.nanoseconds);
                    }
                    if (accepted != iterations * 9) return error.RejectedValidInput;
                    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
                    const ns = @as(f64, @floatFromInt(times[times.len / 2])) / @as(f64, @floatFromInt(iterations));
                    try writer.print("{s} {s} {s} bytes={d} ns/value={d:.1} MB/s={d:.1}\n", .{
                        @tagName(actual), if (folding) "fold" else "exact",                 if (custom) "custom" else "builtin", bytes.len,
                        ns,               @as(f64, @floatFromInt(bytes.len)) * 1000.0 / ns,
                    });
                }
            }
        }
    }
    try writer.flush();
}

fn encode(comptime actual: s.ActualEncoding, text: []const u8, buffer: []u8) []const u8 {
    var input = s.Value(.utf8){ .bytes = text, .origin = 0 };
    var cursor = input.cursor();
    var at: usize = 0;
    while (cursor.next() catch unreachable) |cp| switch (actual) {
        .utf8 => {
            at += std.unicode.utf8Encode(cp, buffer[at..][0..4]) catch unreachable;
        },
        .utf16le => {
            if (cp < 0x10000) {
                std.mem.writeInt(u16, buffer[at..][0..2], @intCast(cp), .little);
                at += 2;
            } else {
                std.mem.writeInt(u16, buffer[at..][0..2], @intCast(0xd800 + ((cp - 0x10000) >> 10)), .little);
                std.mem.writeInt(u16, buffer[at + 2 ..][0..2], @intCast(0xdc00 + ((cp - 0x10000) & 1023)), .little);
                at += 4;
            }
        },
        .utf32le => {
            std.mem.writeInt(u32, buffer[at..][0..4], cp, .little);
            at += 4;
        },
        else => unreachable,
    };
    return buffer[0..at];
}
