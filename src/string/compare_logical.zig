//! Bounded equality over the same logical reader used by custom validators.
//! No source-sized buffers, host imports, or raw-spelling comparisons.
const support = @import("parser_support");
const Comparison = @import("policy.zig").Comparison;
const Step = @import("validators.zig").Step;
const batches = @import("batch.zig");
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

        /// Only successful, nonterminal ASCII steps may be grouped. Pattern
        /// admission, input provenance and reader boundaries remain identical.
        /// A rejected probe leaves all state untouched.
        pub fn batch(self: *@This(), value: anytype, expected: []const u8, comparison: Comparison, allowance: u32) u32 {
            const Reader = @typeInfo(@TypeOf(value.reader)).pointer.child;
            if (comptime !@hasDecl(Reader, "asciiRun") or !@hasDecl(Reader, "skipAscii")) return 0;
            if (allowance < batches.width or expected.len > support.location.max_source_len) return 0;
            if (self.expected) |bound| if (bound.ptr != expected.ptr or bound.len != expected.len) return 0;
            switch (self.phase) {
                .encoding => {
                    if (!batches.ascii(expected, self.checked)) return 0;
                    self.expected = expected;
                    self.checked += batches.width;
                    return batches.width;
                },
                .compare => {
                    if (unicode and (self.left_fold.at < self.left_fold.len or self.right_fold.at < self.right_fold.len)) return 0;
                    const reader = if (self.cursor.reader) |*r| r else value.reader;
                    const input = reader.fragment();
                    const original = value.reader.fragment();
                    if (input.bytes.ptr != original.bytes.ptr or input.bytes.len != original.bytes.len or input.origin != original.origin) return 0;
                    const bytes = reader.asciiRun();
                    const same = switch (comparison) {
                        .case_sensitive => batches.equalAscii(bytes, 0, expected, self.right),
                        .ascii_case_insensitive => ascii and batches.equalAsciiIgnoreCase(bytes, 0, expected, self.right),
                        .case_insensitive => unicode and batches.equalAsciiIgnoreCase(bytes, 0, expected, self.right),
                    };
                    if (!same) return 0;
                    if (self.cursor.reader == null) {
                        var next = value.reader.*;
                        if (!next.skipAscii(batches.width)) return 0;
                        self.cursor.reader = next;
                    } else if (!self.cursor.reader.?.skipAscii(batches.width)) return 0;
                    self.expected = expected;
                    self.right += batches.width;
                    return batches.width;
                },
                .done => return 0,
            }
        }

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
                        break :left @fromBackingInt(@intCast(item.codepoint));
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
                        break :right @fromBackingInt(@intCast(decoded.scalar));
                    };
                    const same = a == b or (ascii and comparison == .ascii_case_insensitive and
                        a != .end and b != .end and foldAscii(@backingInt(a)) == foldAscii(@backingInt(b)));
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
    return @fromBackingInt(@intCast(cp));
}
fn foldAscii(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
}
