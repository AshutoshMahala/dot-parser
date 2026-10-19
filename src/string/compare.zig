const support = @import("parser_support");
const Value = @import("value.zig").Value;
const Comparison = @import("policy.zig").Comparison;
const Step = @import("validators.zig").Step;
const batches = @import("batch.zig");

/// No pointers into a session: states can move safely between advance calls.
pub fn State(comptime unicode: bool) type {
    const Pending = struct { values: [3]u21 = undefined, at: u2 = 0, len: u2 = 0 };
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
                    const a = self.next(@TypeOf(value).encoding, value.bytes, &self.left, if (unicode) &self.left_fold else {}, comparison) catch {
                        context.invalidValidator();
                        return .stopped;
                    };
                    const b = self.next(.utf8, expected, &self.right, if (unicode) &self.right_fold else {}, comparison) catch {
                        context.invalidValidator();
                        return .stopped;
                    };
                    if (a == b and a != null) return .pending;
                    self.phase = .done;
                    self.answer = if (a == b) .passed else .failed;
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
                    if (comparison != .case_sensitive or !batches.equalAscii(value.bytes, self.left, expected, self.right)) return 0;
                    self.left += batches.width;
                    self.right += batches.width;
                },
                .done => return 0,
            }
            self.expected = expected;
            return batches.width;
        }

        fn next(_: *@This(), comptime actual: support.encoding.Actual, bytes: []const u8, offset: *u32, pending: if (unicode) *Pending else void, comparison: Comparison) support.encoding.DecodeError!?u21 {
            if (unicode and comparison == .case_insensitive) {
                if (pending.at == pending.len) {
                    var cursor: Value(actual).Cursor = .{ .bytes = bytes, .offset = offset.* };
                    const scalar = try cursor.next() orelse return null;
                    offset.* = cursor.offset;
                    pending.len = @import("casefold.zig").fold(scalar, &pending.values);
                    pending.at = 0;
                }
                const scalar = pending.values[pending.at];
                pending.at += 1;
                return scalar;
            }
            var cursor: Value(actual).Cursor = .{ .bytes = bytes, .offset = offset.* };
            const scalar = try cursor.next();
            offset.* = cursor.offset;
            return scalar;
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
pub fn equals(comptime unicode: bool, value: anytype, expected: []const u8, comparison: Comparison, context: anytype) ?bool {
    if (unicode and comparison == .case_insensitive) {
        var left: Folded(@TypeOf(value.cursor())) = .{ .cursor = value.cursor() };
        var right: Folded(Value(.utf8).Cursor) = .{ .cursor = .{ .bytes = expected } };
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
