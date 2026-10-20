const support = @import("parser_support");
pub fn Value(comptime actual: support.encoding.Actual) type {
    return struct {
        pub const encoding = actual;
        bytes: []const u8,
        origin: u32,
        pub const Cursor = struct {
            bytes: []const u8,
            offset: u32 = 0,
            pub inline fn next(self: *@This()) support.encoding.DecodeError!?u21 {
                if (self.offset >= self.bytes.len) return null;
                // Cursor offsets follow the fragment's u32 span contract even
                // for a consumer-constructed cursor, not merely parser views.
                if (self.bytes.len > support.location.max_source_len) return error.InvalidEncoding;
                if ((actual == .utf8 or actual == .ascii) and self.bytes[self.offset] < 128) {
                    const cp = self.bytes[self.offset];
                    self.offset += 1;
                    return cp;
                }
                const decoded = try support.encoding.Reader(actual).decode(self.bytes, self.offset);
                self.offset += decoded.len;
                return decoded.scalar;
            }
        };
        pub fn cursor(self: @This()) Cursor {
            return .{ .bytes = self.bytes };
        }
        /// Checked even for consumer-constructed values, like Cursor.next.
        pub fn span(self: @This()) error{SourceTooLarge}!support.location.Span {
            if (self.bytes.len > support.location.max_source_len) return error.SourceTooLarge;
            return .{ .start = 0, .len = @intCast(self.bytes.len) };
        }
    };
}
