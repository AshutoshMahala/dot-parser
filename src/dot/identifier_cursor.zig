//! Encoding-specialized identifier traversal; no allocation or source copy.
const encoding = @import("parser_support").encoding;
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
            while (offset.* < raw.len) switch (enc.byteAt(raw, offset.*)) {
                '"', '<' => return,
                '#' => skipLine(raw, offset),
                '/' => {
                    if (enc.byteAt(raw, offset.* + enc.width) == '/') {
                        skipLine(raw, offset);
                    } else {
                        offset.* += 2 * enc.width;
                        while (!(enc.byteAt(raw, offset.*) == '*' and enc.byteAt(raw, offset.* + enc.width) == '/')) offset.* += enc.width;
                        offset.* += 2 * enc.width;
                    }
                },
                else => offset.* += enc.width, // validated whitespace or '+'
            };
        }

        fn skipLine(raw: []const u8, offset: anytype) void {
            while (offset.* < raw.len and enc.byteAt(raw, offset.*) != '\n' and enc.byteAt(raw, offset.*) != '\r') offset.* += enc.width;
        }

        /// `start` points at the outer '<'; return just past its matching '>'.
        pub fn htmlEnd(raw: []const u8, start: anytype) @TypeOf(start) {
            var offset = start + enc.width;
            var depth: u32 = 1;
            while (depth != 0) : (offset += enc.width) switch (enc.byteAt(raw, offset)) {
                '<' => depth += 1,
                '>' => depth -= 1,
                else => {},
            };
            return offset;
        }

        /// Stop at the next quote or backslash; neither is consumed.
        pub fn quotedRunEnd(raw: []const u8, start: anytype) @TypeOf(start) {
            var offset = start;
            while (offset < raw.len and enc.byteAt(raw, offset) != '"' and enc.byteAt(raw, offset) != '\\') offset += enc.width;
            return offset;
        }

        /// `start` points at a backslash; quoted continuations include the optional LF.
        pub fn escapeEnd(raw: []const u8, start: anytype) @TypeOf(start) {
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
