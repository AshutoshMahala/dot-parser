//! Internal logical reader for already recognized names. Public callers bind a
//! typed Name through identifier.fromName; raw unchecked construction stays here.
const std = @import("std");
const encoding = @import("parser_support").encoding;

pub fn ForEncoding(comptime actual: encoding.Actual) type {
    return struct {
        raw: []const u8,
        const Self = @This();
        const E = encoding.Reader(actual);
        const Values = @import("identifier_value.zig").ForEncoding(actual);

        /// Same logical-value hash as the checked helper, without lexing again.
        /// Native text is still decoded with encoding checks: accepted syntax
        /// alone does not certify Unicode validity. UTF-8 retains arbitrary bytes.
        pub fn hash(self: Self) error{InvalidIdentifier}!u64 {
            if (comptime actual == .utf8) return Values.hashAssumeValid(self.raw);
            var chunks: Values.Chunks = .{ .raw = self.raw };
            var state = std.hash.Wyhash.init(0);
            var out: [4]u8 = undefined;
            while (chunks.next()) |chunk| {
                var at: usize = 0;
                while (at < chunk.len) {
                    const scalar = E.decode(chunk, at) catch return error.InvalidIdentifier;
                    at += scalar.len;
                    const len = std.unicode.utf8Encode(scalar.scalar, &out) catch return error.InvalidIdentifier;
                    state.update(out[0..len]);
                }
            }
            return state.final();
        }

        /// Compare names using the same source encoding. No normalization,
        /// layout escapes or entity expansion. Hash equality is not sufficient.
        pub fn eql(self: Self, other: Self) error{InvalidIdentifier}!bool {
            if (comptime actual != .utf8) {
                // Preserve the checked API's rejection of malformed native
                // text on either side, even when the logical values differ.
                for ([_][]const u8{ self.raw, other.raw }) |raw| {
                    var chunks: Values.Chunks = .{ .raw = raw };
                    while (chunks.next()) |chunk| {
                        var at: usize = 0;
                        while (at < chunk.len) {
                            const scalar = E.decode(chunk, at) catch return error.InvalidIdentifier;
                            at += scalar.len;
                        }
                    }
                }
            }
            return Values.orderAssumeValid(self.raw, other.raw) == .eq;
        }
    };
}
