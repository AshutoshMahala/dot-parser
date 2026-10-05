//! Borrowed operands of a validated DOT identifier expression. No content parser.
const support = @import("parser_support");
const Span = support.location.Span;
const Fragment = support.processor.Fragment;
const cursor = @import("identifier_cursor.zig");

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

/// Construct through identifier.parts(). Borrowed source must stay unchanged.
pub const Parts = struct {
    input: Fragment,
    compound: bool,
    offset: u32 = 0,

    pub fn next(self: *Parts) ?Part {
        const bytes = self.input.bytes;
        if (self.offset == bytes.len) return null;
        if (self.compound) cursor.skipGlue(bytes, &self.offset);
        if (self.offset == bytes.len) return null;
        const start = self.offset;
        const kind: Part.Form = switch (bytes[start]) {
            '<' => .html,
            '"' => .quoted,
            '-', '.', '0'...'9' => .numeral,
            else => .bare,
        };
        switch (kind) {
            .bare, .numeral => self.offset = @intCast(bytes.len),
            .quoted => {
                self.offset += 1;
                while (true) {
                    self.offset = cursor.quotedRunEnd(bytes, self.offset);
                    if (bytes[self.offset] == '"') break;
                    self.offset = cursor.escapeEnd(bytes, self.offset);
                }
                self.offset += 1;
            },
            .html => self.offset = cursor.htmlEnd(bytes, self.offset),
        }
        const wrapped = kind == .quoted or kind == .html;
        return .{
            .form = kind,
            .raw = .{ .start = self.input.origin + start, .len = self.offset - start },
            .inner = .{ .start = self.input.origin + start + @intFromBool(wrapped), .len = self.offset - start - (if (wrapped) @as(u32, 2) else 0) },
        };
    }
};
