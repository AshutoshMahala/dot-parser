//! Encoding-specialized identifier traversal; no allocation or source copy.
const encoding = @import("parser_support").encoding;
const Fragment = @import("parser_support").processor.Fragment;
const Span = @import("parser_support").location.Span;
pub const Part = struct {
    pub const Form = enum { bare, numeral, quoted, html };
    form: Form,
    /// Absolute original-source spans. Quoted/html inner spans exclude wrappers,
    /// but quoted escapes remain written: these bytes have NOT been decoded.
    raw: Span,
    inner: Span,

    pub fn fragment(self: Part, source: []const u8) Fragment.Error!Fragment {
        return Fragment.fromSource(source, self.inner);
    }
};

pub const Parts = ForEncoding(.utf8).Parts;

pub fn ForEncoding(comptime actual: encoding.Actual) type {
    return struct {
        const enc = encoding.Reader(actual);
        // Borrowed operands of a validated DOT identifier expression. No content parser.
        const support = @import("parser_support");
        const cursor = @import("identifier_cursor.zig").ForEncoding(actual);

        /// Construct through identifier.parts(). Borrowed source must stay unchanged.
        pub const Parts = struct {
            input: Fragment,
            compound: bool,
            offset: u32 = 0,

            pub fn next(self: *@This()) ?Part {
                const bytes = self.input.bytes;
                if (self.offset == bytes.len) return null;
                if (self.compound) cursor.skipGlue(bytes, &self.offset);
                if (self.offset == bytes.len) return null;
                const start = self.offset;
                const kind: Part.Form = switch (enc.byteAt(bytes, start)) {
                    '<' => .html,
                    '"' => .quoted,
                    '-', '.', '0'...'9' => .numeral,
                    else => .bare,
                };
                switch (kind) {
                    .bare, .numeral => self.offset = @intCast(bytes.len),
                    .quoted => {
                        self.offset += enc.width;
                        while (true) {
                            self.offset = cursor.quotedRunEnd(bytes, self.offset);
                            if (enc.byteAt(bytes, self.offset) == '"') break;
                            self.offset = cursor.escapeEnd(bytes, self.offset);
                        }
                        self.offset += enc.width;
                    },
                    .html => self.offset = cursor.htmlEnd(bytes, self.offset),
                }
                const wrapped = kind == .quoted or kind == .html;
                return .{
                    .form = kind,
                    .raw = .{ .start = self.input.origin + start, .len = self.offset - start },
                    .inner = .{ .start = self.input.origin + start + @as(u32, @intFromBool(wrapped)) * enc.width, .len = self.offset - start - (if (wrapped) @as(u32, 2) * enc.width else 0) },
                };
            }
        };
    };
}
