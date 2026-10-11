//! Private, allocation-free and resumable tag-name comparisons. No repair or
//! ancestor selection: the grammar supplies two complete name spans. Each step
//! performs at most one comparison or a bounded two-edit row (at most 5 cells).
const std = @import("std");
const support = @import("parser_support");
const Span = support.location.Span;
pub const Status = enum { pending, matched, different };

fn equal(comptime fold: bool, a: u32, b: u32) bool {
    const left = if (fold and a < 128) @as(u32, std.ascii.toLower(@intCast(a))) else a;
    const right = if (fold and b < 128) @as(u32, std.ascii.toLower(@intCast(b))) else b;
    return left == right;
}

/// One insertion/deletion/substitution or adjacent transposition. No backtracking
/// and no source-sized call inside a step. Indices count original code units.
pub fn One(comptime actual: support.encoding.Actual, comptime fold: bool) type {
    const enc = support.encoding.Reader(actual);
    return extern struct {
        left: u32 = 0,
        right: u32 = 0,
        used: bool = false,
        phase: enum(u8) { compare, swap_first, swap_second } = .compare,

        fn remaining(self: @This(), a: Span, b: Span) Status {
            const a_len = a.len / enc.width;
            const b_len = b.len / enc.width;
            if (self.left == a_len and self.right == b_len) return .matched;
            if (self.left == a_len or self.right == b_len)
                return if (!self.used and (a_len - self.left) + (b_len - self.right) == 1) .matched else .different;
            return .pending;
        }

        pub fn step(self: *@This(), source: []const u8, a: Span, b: Span) Status {
            const a_len = a.len / enc.width;
            const b_len = b.len / enc.width;
            if (self.phase == .compare) {
                const end = self.remaining(a, b);
                if (end != .pending) return end;
                if (equal(fold, enc.unit(source, a.start + self.left * enc.width), enc.unit(source, b.start + self.right * enc.width))) {
                    self.left += 1;
                    self.right += 1;
                } else {
                    if (self.used) return .different;
                    self.used = true;
                    if (a_len > b_len) {
                        self.left += 1;
                    } else if (b_len > a_len) {
                        self.right += 1;
                    } else if (self.left + 1 < a_len) {
                        self.phase = .swap_first;
                        return .pending;
                    } else {
                        self.left += 1;
                        self.right += 1;
                    }
                }
            } else {
                const swapped = if (self.phase == .swap_first)
                    equal(fold, enc.unit(source, a.start + self.left * enc.width), enc.unit(source, b.start + (self.right + 1) * enc.width))
                else
                    equal(fold, enc.unit(source, a.start + (self.left + 1) * enc.width), enc.unit(source, b.start + self.right * enc.width));
                if (self.phase == .swap_first and swapped) {
                    self.phase = .swap_second;
                    return .pending;
                }
                // A failed swap probe still permits a substitution; subsequent
                // comparisons decide whether the untouched suffix matches.
                const advance: u32 = if (self.phase == .swap_second and swapped) 2 else 1;
                self.left += advance;
                self.right += advance;
                self.phase = .compare;
            }
            return self.remaining(a, b);
        }
    };
}

/// Restricted Damerau/optimal-string-alignment distance with cutoff two. A swap
/// counts as one edit, just as in One. Three 5-cell rows handle transpositions;
/// no full matrix, source-sized scratch, or allocations are needed.
pub fn Two(comptime actual: support.encoding.Actual, comptime fold: bool) type {
    const enc = support.encoding.Reader(actual);
    return extern struct {
        prefix: u32 = 0,
        a_len: u32 = 0,
        b_len: u32 = 0,
        row: u32 = 1,
        previous: [5]u8 = @splat(3),
        older: [5]u8 = @splat(3),
        phase: enum(u8) { prefix, suffix, rows } = .prefix,

        fn cell(values: *const [5]u8, row: u32, col: u32, width: u32) u8 {
            const lo = row -| 2;
            const hi = @min(width, row +| 2);
            return if (col < lo or col > hi) 3 else values[col - lo];
        }
        pub fn step(self: *@This(), source: []const u8, a: Span, b: Span) Status {
            switch (self.phase) {
                .prefix => {
                    const a_len = a.len / enc.width;
                    const b_len = b.len / enc.width;
                    if (self.prefix == @min(a_len, b_len))
                        return if (@max(a_len, b_len) - @min(a_len, b_len) <= 2) .matched else .different;
                    if (equal(fold, enc.unit(source, a.start + self.prefix * enc.width), enc.unit(source, b.start + self.prefix * enc.width))) {
                        self.prefix += 1;
                    } else {
                        self.a_len = a_len - self.prefix;
                        self.b_len = b_len - self.prefix;
                        self.phase = .suffix;
                    }
                    return .pending;
                },
                .suffix => {
                    if (self.a_len == 0 or self.b_len == 0)
                        return if (@max(self.a_len, self.b_len) <= 2) .matched else .different;
                    if (equal(fold, enc.unit(source, a.start + (self.prefix + self.a_len - 1) * enc.width), enc.unit(source, b.start + (self.prefix + self.b_len - 1) * enc.width))) {
                        self.a_len -= 1;
                        self.b_len -= 1;
                    } else {
                        if (@max(self.a_len, self.b_len) - @min(self.a_len, self.b_len) > 2) return .different;
                        for (0..@min(self.b_len, 2) + 1) |col| self.previous[col] = @intCast(col);
                        self.phase = .rows;
                    }
                    return .pending;
                },
                .rows => {
                    const i = self.row;
                    const lo = i -| 2;
                    const hi = @min(self.b_len, i +| 2);
                    var current: [5]u8 = @splat(3);
                    var minimum: u8 = 3;
                    // At most 5 cells: a fixed-size recovery microstep, not a
                    // name-sized loop. Each row consumes one recovery credit.
                    for (lo..hi + 1) |column| {
                        const j: u32 = @intCast(column);
                        var cost: u8 = @intCast(@min(i, 3));
                        if (j != 0) {
                            const left = enc.unit(source, a.start + (self.prefix + i - 1) * enc.width);
                            const right = enc.unit(source, b.start + (self.prefix + j - 1) * enc.width);
                            cost = @min(3, @min(cell(&self.previous, i - 1, j, self.b_len) + 1, @min(
                                if (j > lo) current[j - lo - 1] + 1 else 3,
                                cell(&self.previous, i - 1, j - 1, self.b_len) + @intFromBool(!equal(fold, left, right)),
                            )));
                            if (i > 1 and j > 1 and
                                equal(fold, left, enc.unit(source, b.start + (self.prefix + j - 2) * enc.width)) and
                                equal(fold, enc.unit(source, a.start + (self.prefix + i - 2) * enc.width), right))
                                cost = @min(cost, cell(&self.older, i - 2, j - 2, self.b_len) + 1);
                        }
                        current[j - lo] = cost;
                        minimum = @min(minimum, cost);
                    }
                    if (minimum > 2) return .different;
                    if (i == self.a_len) return if (cell(&current, i, self.b_len, self.b_len) <= 2) .matched else .different;
                    self.older = self.previous;
                    self.previous = current;
                    self.row += 1;
                    return .pending;
                },
            }
        }
    };
}

fn reference(comptime fold: bool, a: []const u8, b: []const u8) u8 {
    var matrix: [33][33]u8 = undefined;
    for (0..a.len + 1) |i| matrix[i][0] = @intCast(i);
    for (0..b.len + 1) |j| matrix[0][j] = @intCast(j);
    for (a, 1..) |left, i| for (b, 1..) |right, j| {
        var cost = @min(matrix[i - 1][j] + 1, @min(matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + @intFromBool(!equal(fold, left, right))));
        if (i > 1 and j > 1 and equal(fold, left, b[j - 2]) and equal(fold, a[i - 2], right))
            cost = @min(cost, matrix[i - 2][j - 2] + 1);
        matrix[i][j] = cost;
    };
    return matrix[a.len][b.len];
}

fn checkPair(comptime fold: bool, a: []const u8, b: []const u8) !void {
    var buffer: [64]u8 = undefined;
    @memcpy(buffer[0..a.len], a);
    @memcpy(buffer[a.len..][0..b.len], b);
    const source = buffer[0 .. a.len + b.len];
    const left: Span = .{ .start = 0, .len = @intCast(a.len) };
    const right: Span = .{ .start = @intCast(a.len), .len = @intCast(b.len) };
    const distance = reference(fold, a, b);
    inline for (.{ One(.utf8, fold), Two(.utf8, fold) }, .{ 1, 2 }) |Matcher, limit| {
        var matcher: Matcher = .{};
        var steps: usize = 0;
        var status: Status = .pending;
        while (status == .pending) {
            status = matcher.step(source, left, right);
            steps += 1;
            try std.testing.expect(steps <= source.len + 8);
        }
        errdefer std.debug.print("typo comparison failed: '{s}'/'{s}', cutoff={d}, fold={}\n", .{ a, b, limit, fold });
        try std.testing.expectEqual(distance <= limit, status == .matched);
    }
}

test "bounded matchers agree with full optimal-string-alignment on exhaustive and mutated names" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    for (0..6) |a_len| for (0..6) |b_len| {
        for (0..@as(usize, 1) << @intCast(a_len)) |a_bits| for (0..@as(usize, 1) << @intCast(b_len)) |b_bits| {
            for (a[0..a_len], 0..) |*byte, i| byte.* = "ab"[(a_bits >> @intCast(i)) & 1];
            for (b[0..b_len], 0..) |*byte, i| byte.* = "ab"[(b_bits >> @intCast(i)) & 1];
            try checkPair(false, a[0..a_len], b[0..b_len]);
        };
    };
    var prng = std.Random.DefaultPrng.init(0x71_902abc);
    const random = prng.random();
    for (0..10_000) |trial| {
        const a_len = random.uintLessThan(usize, 30);
        var b_len = a_len;
        for (a[0..a_len]) |*byte| byte.* = "abCD\x80\xff"[random.uintLessThan(usize, 6)];
        @memcpy(b[0..b_len], a[0..a_len]);
        if (trial % 4 == 0) {
            b_len = random.uintLessThan(usize, 33);
            for (b[0..b_len]) |*byte| byte.* = "abcd\x80\xff"[random.uintLessThan(usize, 6)];
        } else for (0..trial % 4) |_| {
            switch (random.uintLessThan(u8, 4)) {
                0 => if (b_len != 0) {
                    b[random.uintLessThan(usize, b_len)] = "abcd"[random.uintLessThan(usize, 4)];
                },
                1 => if (b_len < b.len) {
                    const at = random.uintLessThan(usize, b_len + 1);
                    std.mem.copyBackwards(u8, b[at + 1 .. b_len + 1], b[at..b_len]);
                    b[at] = "abcd"[random.uintLessThan(usize, 4)];
                    b_len += 1;
                },
                2 => if (b_len != 0) {
                    const at = random.uintLessThan(usize, b_len);
                    std.mem.copyForwards(u8, b[at .. b_len - 1], b[at + 1 .. b_len]);
                    b_len -= 1;
                },
                3 => if (b_len >= 2) {
                    const at = random.uintLessThan(usize, b_len - 1);
                    std.mem.swap(u8, &b[at], &b[at + 1]);
                },
                else => unreachable,
            }
        }
        try checkPair(false, a[0..a_len], b[0..b_len]);
        try checkPair(true, a[0..a_len], b[0..b_len]);
    }
}
