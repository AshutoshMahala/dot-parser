const support = @import("parser_support");
const Value = @import("value.zig").Value;
const Comparison = @import("policy.zig").Comparison;

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
