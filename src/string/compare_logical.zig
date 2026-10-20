//! Bounded equality over the same logical reader used by custom validators.
//! No source-sized buffers, host imports, or raw-spelling comparisons.
const support = @import("parser_support");
const Comparison = @import("policy.zig").Comparison;
const Step = @import("validators.zig").Step;
const Pending = struct { values: [3]u21 = undefined, at: u2 = 0, len: u2 = 0 };
const Scalar = enum(u21) { end = 0x110000, _ };

pub fn State(comptime Cursor: type, comptime unicode: bool, comptime ascii: bool) type {
    return struct {
        expected: ?[]const u8 = null,
        checked: u32 = 0,
        right: u32 = 0,
        cursor: Cursor = .{},
        phase: enum { encoding, compare, done } = .encoding,
        answer: Step = .pending,
        left_fold: if (unicode) Pending else void = if (unicode) .{} else {},
        right_fold: if (unicode) Pending else void = if (unicode) .{} else {},

        pub fn step(self: *@This(), value: anytype, expected: []const u8, comparison: Comparison, context: anytype) Step {
            if (expected.len > support.location.max_source_len) {
                context.invalidValidator();
                return .stopped;
            }
            if (self.expected) |bound| {
                if (bound.ptr != expected.ptr or bound.len != expected.len) {
                    context.invalidValidator();
                    return .stopped;
                }
            } else self.expected = expected;
            switch (self.phase) {
                .encoding => {
                    // Even an early mismatch cannot hide an invalid pattern's
                    // suffix. At most one UTF-8 scalar (four bytes) per step.
                    if (self.checked < expected.len) {
                        const decoded = support.encoding.Reader(.utf8).decode(expected, self.checked) catch {
                            context.invalidValidator();
                            return .stopped;
                        };
                        self.checked += decoded.len;
                    } else self.phase = .compare;
                    return .pending;
                },
                .compare => {
                    const a: Scalar = left: {
                        if (unicode and self.left_fold.at < self.left_fold.len)
                            break :left take(&self.left_fold);
                        const item = switch (context.readStep(&self.cursor, value)) {
                            .pending => return .pending,
                            .stopped => return .stopped,
                            .end => break :left .end,
                            .scalar => |item| item,
                        };
                        if (unicode and comparison == .case_insensitive) {
                            self.left_fold.len = @import("casefold.zig").fold(item.codepoint, &self.left_fold.values);
                            self.left_fold.at = 0;
                            break :left take(&self.left_fold);
                        }
                        break :left @enumFromInt(item.codepoint);
                    };
                    const b: Scalar = right: {
                        if (unicode and self.right_fold.at < self.right_fold.len)
                            break :right take(&self.right_fold);
                        if (self.right == expected.len) break :right .end;
                        const decoded = support.encoding.Reader(.utf8).decode(expected, self.right) catch {
                            context.invalidValidator();
                            return .stopped;
                        };
                        self.right += decoded.len;
                        if (unicode and comparison == .case_insensitive) {
                            self.right_fold.len = @import("casefold.zig").fold(decoded.scalar, &self.right_fold.values);
                            self.right_fold.at = 0;
                            break :right take(&self.right_fold);
                        }
                        break :right @enumFromInt(decoded.scalar);
                    };
                    const same = a == b or (ascii and comparison == .ascii_case_insensitive and
                        a != .end and b != .end and foldAscii(@intFromEnum(a)) == foldAscii(@intFromEnum(b)));
                    if (same and a != .end) return .pending;
                    self.phase = .done;
                    self.answer = if (same) .passed else .failed;
                    return self.answer;
                },
                .done => return self.answer,
            }
        }
    };
}

fn take(pending: *Pending) Scalar {
    const cp = pending.values[pending.at];
    pending.at += 1;
    return @enumFromInt(cp);
}
fn foldAscii(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
}
