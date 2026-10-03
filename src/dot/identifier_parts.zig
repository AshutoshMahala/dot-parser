//! Borrowed operands of a validated DOT identifier expression. No content parser.
const support = @import("parser_support");
const Span = support.location.Span;
const Fragment = support.processor.Fragment;

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
        self.skipGlue();
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
                while (bytes[self.offset] != '"') {
                    if (bytes[self.offset] == '\\') self.offset += 1;
                    self.offset += 1;
                }
                self.offset += 1;
            },
            .html => {
                var depth: u32 = 1;
                self.offset += 1;
                while (depth != 0) : (self.offset += 1) switch (bytes[self.offset]) {
                    '<' => depth += 1,
                    '>' => depth -= 1,
                    else => {},
                };
            },
        }
        const wrapped = kind == .quoted or kind == .html;
        return .{
            .form = kind,
            .raw = .{ .start = self.input.origin + start, .len = self.offset - start },
            .inner = .{ .start = self.input.origin + start + @intFromBool(wrapped), .len = self.offset - start - (if (wrapped) @as(u32, 2) else 0) },
        };
    }

    fn skipGlue(self: *Parts) void {
        if (!self.compound) return;
        const raw = self.input.bytes;
        while (self.offset < raw.len) switch (raw[self.offset]) {
            '"', '<' => return,
            '#' => self.skipLine(),
            '/' => {
                if (raw[self.offset + 1] == '/') {
                    self.skipLine();
                } else {
                    self.offset += 2;
                    while (!(raw[self.offset] == '*' and raw[self.offset + 1] == '/')) self.offset += 1;
                    self.offset += 2;
                }
            },
            else => self.offset += 1,
        };
    }

    fn skipLine(self: *Parts) void {
        const raw = self.input.bytes;
        while (self.offset < raw.len and raw[self.offset] != '\n' and raw[self.offset] != '\r') self.offset += 1;
    }
};
