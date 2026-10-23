//! Encoding-specialized identifier traversal; no allocation or source copy.
const encoding = @import("parser_support").encoding;
/// Compile-time no-op accounting for trusted, ordinary traversal.
pub const Unmetered = struct {
    pub fn spend(_: @This(), _: u64) error{}!void {}
};
pub const skipGlue = ForEncoding(.utf8).skipGlue;
pub const htmlEnd = ForEncoding(.utf8).htmlEnd;
pub const quotedRunEnd = ForEncoding(.utf8).quotedRunEnd;
pub const escapeEnd = ForEncoding(.utf8).escapeEnd;

pub fn ForEncoding(comptime actual: encoding.Actual) type {
    return struct {
        const enc = encoding.Reader(actual);
        // Shared byte-boundary primitives for already validated identifier expressions.
        // No validation, decoding, allocation or extra pass over a complete operand.
        // Offset arguments may be u32 source cursors or native decoder slice indices.

        pub fn skipGlue(raw: []const u8, offset: anytype) void {
            skipGlueWith(raw, offset, Unmetered{}) catch unreachable;
        }
        pub fn skipGlueWith(raw: []const u8, offset: anytype, work: anytype) !void {
            while (offset.* < raw.len) {
                try work.spend(enc.width);
                switch (enc.byteAt(raw, offset.*)) {
                    '"', '<' => return,
                    '#' => try skipLine(raw, offset, work),
                    '/' => {
                        try work.spend(enc.width);
                        if (enc.byteAt(raw, offset.* + enc.width) == '/') {
                            try skipLine(raw, offset, work);
                        } else {
                            offset.* += 2 * enc.width;
                            while (true) {
                                try work.spend(2 * enc.width);
                                if (enc.byteAt(raw, offset.*) == '*' and enc.byteAt(raw, offset.* + enc.width) == '/') break;
                                offset.* += enc.width;
                            }
                            offset.* += 2 * enc.width;
                        }
                    },
                    else => offset.* += enc.width, // validated whitespace or '+'
                }
            }
        }

        fn skipLine(raw: []const u8, offset: anytype, work: anytype) !void {
            while (offset.* < raw.len) {
                try work.spend(enc.width);
                if (enc.byteAt(raw, offset.*) == '\n' or enc.byteAt(raw, offset.*) == '\r') break;
                offset.* += enc.width;
            }
        }

        /// `start` points at the outer '<'; return just past its matching '>'.
        pub fn htmlEnd(raw: []const u8, start: anytype) @TypeOf(start) {
            return htmlEndWith(raw, start, Unmetered{}) catch unreachable;
        }
        pub fn htmlEndWith(raw: []const u8, start: anytype, work: anytype) !@TypeOf(start) {
            try work.spend(enc.width);
            var offset = start + enc.width;
            var depth: u32 = 1;
            while (depth != 0) : (offset += enc.width) {
                try work.spend(enc.width);
                switch (enc.byteAt(raw, offset)) {
                    '<' => depth += 1,
                    '>' => depth -= 1,
                    else => {},
                }
            }
            return offset;
        }

        /// Stop at the next quote or backslash; neither is consumed.
        pub fn quotedRunEnd(raw: []const u8, start: anytype) @TypeOf(start) {
            return quotedRunEndWith(raw, start, Unmetered{}) catch unreachable;
        }
        pub fn quotedRunEndWith(raw: []const u8, start: anytype, work: anytype) !@TypeOf(start) {
            var offset = start;
            while (offset < raw.len) {
                try work.spend(enc.width);
                if (enc.byteAt(raw, offset) == '"' or enc.byteAt(raw, offset) == '\\') break;
                offset += enc.width;
            }
            return offset;
        }

        /// `start` points at a backslash; quoted continuations include the optional LF.
        pub fn escapeEnd(raw: []const u8, start: anytype) @TypeOf(start) {
            return escapeEndWith(raw, start, Unmetered{}) catch unreachable;
        }
        pub fn escapeEndWith(raw: []const u8, start: anytype, work: anytype) !@TypeOf(start) {
            // At most four code units are inspected/skipped by one escape.
            try work.spend(4 * enc.width);
            var offset = start + 2 * enc.width;
            // A preserved unknown escape must not split a UTF-16 surrogate
            // pair into separate logical chunks. ASCII/UTF-8 stay byte-exact.
            if (enc.width == 2) {
                const first = enc.unit(raw, start + enc.width);
                if (first >= 0xd800 and first <= 0xdbff) offset += enc.width;
            }
            if (enc.byteAt(raw, start + enc.width) == '\r' and offset < raw.len and enc.byteAt(raw, offset) == '\n') offset += enc.width;
            return offset;
        }
    };
}
