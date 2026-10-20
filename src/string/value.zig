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
        /// Location of an admitted validator view. Like reader state, manually
        /// fabricated views must obey Fragment's source/coordinate contract.
        /// For an unchecked consumer slice, validate Fragment.init first.
        pub fn location(self: @This()) support.logical.SourceLocation {
            return .{ .span = .{ .start = self.origin, .len = @intCast(self.bytes.len) }, .segment_start = self.origin };
        }
        pub fn contiguous(self: @This()) ?support.logical.BorrowedContents {
            return .{ .bytes = self.bytes, .encoding = actual, .location = self.location() };
        }
        /// Checked even for consumer-constructed values, like Cursor.next.
        pub fn span(self: @This()) error{SourceTooLarge}!support.location.Span {
            if (self.bytes.len > support.location.max_source_len) return error.SourceTooLarge;
            return .{ .start = 0, .len = @intCast(self.bytes.len) };
        }
    };
}

/// Ephemeral view supplied to a validator. Cursors own their traversal state;
/// never retain this view or a pointer into the calling session across yields.
pub fn LogicalValue(comptime Reader: type) type {
    return struct {
        pub const encoding = Reader.encoding_kind;
        reader: *const Reader,
        pub fn location(self: @This()) support.logical.SourceLocation {
            return self.reader.location();
        }
        pub fn contiguous(self: @This()) ?support.logical.BorrowedContents {
            return self.reader.contiguous();
        }
    };
}
