const support = @import("parser_support");
const Value = @import("value.zig").Value;
const Comparison = @import("policy.zig").Comparison;
const Step = @import("validators.zig").Step;
const batches = @import("batch.zig");
const Pending = struct { values: [3]u21 = undefined, at: u2 = 0, len: u2 = 0 };
// Valid scalars stop at U+10FFFF. Two out-of-range tags keep the internal read
// result in one word instead of a padded error-union/optional return per side.
const Scalar = enum(u21) { end = 0x110000, invalid = 0x110001, _ };

/// No pointers into a session: states can move safely between advance calls.
pub fn State(comptime unicode: bool, comptime ascii: bool) type {
    return struct {
        expected: ?[]const u8 = null,
        checked: u32 = 0,
        left: u32 = 0,
        right: u32 = 0,
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
                    // Keep the two reads local in Small, but leave the larger
                    // step/driver boundaries and speed builds to the optimizer.
                    const read_call: @import("std").builtin.CallModifier = if (@import("builtin").mode == .small) .always_inline else .auto;
                    const a = @call(read_call, next, .{ unicode, @TypeOf(value).encoding, value.bytes, &self.left, if (unicode) &self.left_fold else {}, comparison });
                    if (a == .invalid) {
                        context.invalidValidator();
                        return .stopped;
                    }
                    const b = @call(read_call, next, .{ unicode, .utf8, expected, &self.right, if (unicode) &self.right_fold else {}, comparison });
                    if (b == .invalid) {
                        context.invalidValidator();
                        return .stopped;
                    }
                    // Equal scalars need no ASCII folding. In runtime-policy
                    // profiles, dispatch only on a mismatch rather than once
                    // per operand on every pending step. Unicode expansion
                    // remains in next(), since it can change cursor progress.
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

        /// Consume only consecutive pending steps. Final comparisons, invalid
        /// arguments and non-ASCII use step(), retaining exact failure credits.
        pub fn batch(self: *@This(), value: anytype, expected: []const u8, comparison: Comparison, allowance: u32) u32 {
            if (allowance < batches.width or expected.len > support.location.max_source_len) return 0;
            if (self.expected) |bound| {
                if (bound.ptr != expected.ptr or bound.len != expected.len) return 0;
            }
            switch (self.phase) {
                .encoding => {
                    if (!batches.ascii(expected, self.checked)) return 0;
                    self.checked += batches.width;
                },
                .compare => {
                    if (comptime @TypeOf(value).encoding != .utf8 and @TypeOf(value).encoding != .ascii) return 0;
                    // Unicode expansion owns its pending scalars. Otherwise
                    // equal ASCII runs need no mode dispatch; only mismatching
                    // runs may need ASCII folding, just like scalar step().
                    const matches = if (unicode and comparison == .case_insensitive)
                        false
                    else
                        batches.equalAscii(value.bytes, self.left, expected, self.right) or
                            (ascii and comparison == .ascii_case_insensitive and
                                @call(.never_inline, batches.equalAsciiIgnoreCase, .{ value.bytes, self.left, expected, self.right }));
                    if (!matches) return 0;
                    self.left += batches.width;
                    self.right += batches.width;
                },
                .done => return 0,
            }
            self.expected = expected;
            return batches.width;
        }
    };
}

// ASCII folding does not change cursor progress. Share decoding between
// exact-only and ASCII-capable states instead of cloning it per capability.
fn next(comptime unicode: bool, comptime actual: support.encoding.Actual, bytes: []const u8, offset: *u32, pending: if (unicode) *Pending else void, comparison: Comparison) Scalar {
    if (unicode and comparison == .case_insensitive) {
        if (pending.at == pending.len) {
            var cursor: Value(actual).Cursor = .{ .bytes = bytes, .offset = offset.* };
            const scalar = (cursor.next() catch return .invalid) orelse return .end;
            offset.* = cursor.offset;
            pending.len = @import("casefold.zig").fold(scalar, &pending.values);
            pending.at = 0;
        }
        const scalar = pending.values[pending.at];
        pending.at += 1;
        return @fromBackingInt(@intCast(scalar));
    }
    var cursor: Value(actual).Cursor = .{ .bytes = bytes, .offset = offset.* };
    const scalar = (cursor.next() catch return .invalid) orelse return .end;
    offset.* = cursor.offset;
    return @fromBackingInt(@intCast(scalar));
}

inline fn foldAscii(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
}

fn AsciiFolded(comptime Cursor: type) type {
    return struct {
        cursor: Cursor,
        inline fn next(self: *@This()) support.encoding.DecodeError!?u21 {
            return foldAscii(try self.cursor.next() orelse return null);
        }
    };
}

fn Folded(comptime Cursor: type) type {
    return struct {
        cursor: Cursor,
        pending: [3]u21 = undefined,
        at: u2 = 0,
        len: u2 = 0,
        inline fn next(self: *@This()) support.encoding.DecodeError!?u21 {
            if (self.at == self.len) {
                const cp = try self.cursor.next() orelse return null;
                self.len = @import("casefold.zig").fold(cp, &self.pending);
                self.at = 0;
            }
            const cp = self.pending[self.at];
            self.at += 1;
            return cp;
        }
    };
}

/// No folding cursor or table reference is instantiated on the exact-only path.
pub fn equals(comptime unicode: bool, comptime ascii: bool, value: anytype, expected: []const u8, comparison: Comparison, context: anytype) ?bool {
    if (unicode and comparison == .case_insensitive) {
        var left: Folded(@TypeOf(value.cursor())) = .{ .cursor = value.cursor() };
        var right: Folded(Value(.utf8).Cursor) = .{ .cursor = .{ .bytes = expected } };
        return compare(&left, &right, context);
    }
    if (ascii and comparison == .ascii_case_insensitive) {
        // UTF-8 preserves ASCII bytes and never embeds them in multibyte
        // scalars. After validation, bytewise ASCII folding has the same
        // meaning as scalar folding, leaving every non-ASCII scalar unchanged.
        if (!@TypeOf(context.*).cancellation_enabled and (@TypeOf(value).encoding == .utf8 or @TypeOf(value).encoding == .ascii))
            return @import("std").ascii.eqlIgnoreCase(value.bytes, expected);
        var left: AsciiFolded(@TypeOf(value.cursor())) = .{ .cursor = value.cursor() };
        var right: AsciiFolded(Value(.utf8).Cursor) = .{ .cursor = .{ .bytes = expected } };
        return compare(&left, &right, context);
    }
    // For already-validated UTF-8/ASCII, byte equality is scalar equality.
    // An enabled cancellation hook retains the cooperatively polled path.
    if (!@TypeOf(context.*).cancellation_enabled and (@TypeOf(value).encoding == .utf8 or @TypeOf(value).encoding == .ascii))
        return @import("std").mem.eql(u8, value.bytes, expected);
    var left = value.cursor();
    var right: Value(.utf8).Cursor = .{ .bytes = expected };
    return compare(&left, &right, context);
}
fn compare(left: anytype, right: anytype, context: anytype) ?bool {
    // Keep a single scalar loop boundary in size-optimized builds. Flattening
    // it into every profile lets the machine outliner extract tiny sequences
    // from the hot loop (including native decoding), adding calls per scalar.
    // Speed-optimized builds retain their usual inlining choices.
    if (@import("builtin").mode == .small and !@TypeOf(context.*).cancellation_enabled) {
        const same = @call(.never_inline, compareUnpolled, .{ left.*, right.* });
        if (same == null) context.invalidValidator();
        return same;
    }
    while (true) {
        if (context.cancelled()) return null;
        const a = left.next() catch {
            context.invalidValidator();
            return null;
        };
        const b = right.next() catch {
            context.invalidValidator();
            return null;
        };
        if (a != b) return false;
        if (a == null) return true;
    }
}

// Only internal cursors run here: they cannot report, stop or invoke consumer
// callbacks. Keeping the diagnostic context outside this loop also avoids
// aliasing its completion state with the moving cursors in an outlined call.
// Cursor positions are local values: the caller only needs the answer, and
// unrelated cursor stores must not force reloads of the other cursor's fields.
fn compareUnpolled(left_input: anytype, right_input: anytype) ?bool {
    var left = left_input;
    var right = right_input;
    while (true) {
        const a = left.next() catch return null;
        const b = right.next() catch return null;
        if (a != b) return false;
        if (a == null) return true;
    }
}
