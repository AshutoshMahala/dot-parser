//! Logical contents of one host-selected DOT identifier expression. No tree,
//! allocation, layout-escape expansion or markup-to-text conversion. The host
//! owns identifier grammar; this adapter checks the framing it traverses.
const support = @import("parser_support");
const logical = support.logical;

pub fn Reader(comptime actual: support.encoding.Actual) type {
    const E = support.encoding.Reader(actual);
    return struct {
        const Self = @This();
        pub const encoding_kind = actual;
        contents: logical.Reader(actual),
        state: enum { initial, unquoted, quoted, escape, preserved_tail, continuation_cr, gap, slash, line_comment, block_comment, block_star, done } = .initial,
        needs_operand: bool = false,
        escape_start: u32 = 0,
        preserved: u21 = 0,
        failure: ?logical.Failure = null,

        pub fn init(input: support.processor.Fragment) support.processor.Fragment.Error!Self {
            return .{ .contents = try logical.Reader(actual).init(input) };
        }
        pub fn fragment(self: *const Self) support.processor.Fragment {
            return self.contents.input;
        }
        pub fn restarted(self: *const Self) support.processor.Fragment.Error!Self {
            return init(self.fragment());
        }
        pub fn location(self: *const Self) logical.SourceLocation {
            var loc = self.contents.location();
            loc.mapping = .enclosing;
            return loc;
        }
        /// Unquoted contents are unchanged; quotes/concatenation conservatively
        /// have no fast path. This never scans or certifies identifier grammar.
        pub fn contiguous(self: *const Self) ?logical.BorrowedContents {
            const bytes = self.contents.input.bytes;
            if (bytes.len < E.width) return null;
            const first = E.unit(bytes, 0);
            return if (first == '"' or first == '<') null else self.contents.contiguous();
        }
        pub fn position(self: *const Self) u32 {
            return self.contents.position();
        }
        pub inline fn asciiRun(self: *const Self) []const u8 {
            if (self.failure != null or (self.state != .unquoted and self.state != .quoted)) return &.{};
            const bytes = self.contents.asciiRun();
            if (bytes.len == 0 or self.state == .unquoted) return bytes;
            const block: @Vector(logical.ascii_width, u8) = bytes[0..logical.ascii_width].*;
            // Quotes, escapes and NUL must retain their individual steps.
            if (@reduce(.Or, (block == @as(@Vector(logical.ascii_width, u8), @splat('"'))) |
                (block == @as(@Vector(logical.ascii_width, u8), @splat('\\'))) |
                (block == @as(@Vector(logical.ascii_width, u8), @splat(0))))) return &.{};
            return bytes;
        }
        pub inline fn skipAscii(self: *Self, count: u32) bool {
            if (count == 0 or count > self.asciiRun().len) return false;
            self.contents.offset += count;
            return true;
        }
        pub fn step(self: *Self) logical.Step {
            if (self.failure) |f| return .{ .failure = f };
            if (self.state == .done) return .end;
            if (self.state == .preserved_tail) {
                self.state = .quoted;
                return self.emit(self.preserved, self.escape_start + E.width, self.position() - self.escape_start - E.width);
            }
            const next = self.read();
            const item = switch (next) {
                .pending => return .pending,
                .failure => |f| {
                    self.failure = f;
                    return next;
                },
                .end => {
                    if (self.state == .unquoted or ((self.state == .gap or self.state == .line_comment) and !self.needs_operand)) {
                        self.state = .done;
                        return .end;
                    }
                    return self.fail(.invalid_syntax, self.position(), 0);
                },
                .scalar => |item| item,
            };
            const c = item.codepoint;
            const start = item.location.span.start - self.contents.input.origin;
            if (self.state == .continuation_cr) {
                self.state = .quoted;
                if (c == '\n') return .pending;
            }
            switch (self.state) {
                .initial => {
                    if (c == '<') return self.fail(.unsupported_form, start, item.location.span.len);
                    if (c == '"') {
                        self.contents.segment_start = item.location.span.start;
                        self.state = .quoted;
                        return .pending;
                    }
                    self.state = .unquoted;
                    return .{ .scalar = item };
                },
                .unquoted => return .{ .scalar = item },
                .quoted => {
                    if (c == '"') {
                        self.state = .gap;
                        self.needs_operand = false;
                        return .pending;
                    }
                    if (c == '\\') {
                        self.escape_start = start;
                        self.state = .escape;
                        return .pending;
                    }
                    if (c == 0) return self.fail(.invalid_syntax, start, item.location.span.len);
                    return .{ .scalar = item };
                },
                .escape => {
                    self.state = .quoted;
                    switch (c) {
                        '"' => return self.emit('"', self.escape_start, self.position() - self.escape_start),
                        '\n' => return .pending,
                        '\r' => {
                            self.state = .continuation_cr;
                            return .pending;
                        },
                        0 => return self.fail(.invalid_syntax, start, item.location.span.len),
                        else => {
                            // Unknown/layout escapes are preserved, including
                            // the two backslashes in \\. Do not reinterpret the
                            // tail as another escape or delimiter next step.
                            self.preserved = c;
                            self.state = .preserved_tail;
                            return self.emit('\\', self.escape_start, E.width);
                        },
                    }
                },
                .gap => switch (c) {
                    ' ', '\t', '\r', '\n' => {},
                    '#' => self.state = .line_comment,
                    '/' => self.state = .slash,
                    '+' => {
                        if (self.needs_operand) return self.fail(.invalid_syntax, start, item.location.span.len);
                        self.needs_operand = true;
                    },
                    '"' => {
                        if (!self.needs_operand) return self.fail(.invalid_syntax, start, item.location.span.len);
                        self.contents.segment_start = item.location.span.start;
                        self.state = .quoted;
                    },
                    '<' => return self.fail(if (self.needs_operand) .unsupported_form else .invalid_syntax, start, item.location.span.len),
                    else => return self.fail(.invalid_syntax, start, item.location.span.len),
                },
                .slash => switch (c) {
                    '/' => self.state = .line_comment,
                    '*' => self.state = .block_comment,
                    else => return self.fail(.invalid_syntax, start, item.location.span.len),
                },
                .line_comment => if (c == '\r' or c == '\n') {
                    self.state = .gap;
                },
                .block_comment => if (c == '*') {
                    self.state = .block_star;
                },
                .block_star => {
                    if (c == '/') self.state = .gap else if (c != '*') self.state = .block_comment;
                },
                .continuation_cr, .preserved_tail, .done => unreachable,
            }
            return .pending;
        }
        fn read(self: *Self) logical.Step {
            // Comments are glue, not logical contents. Skip one physical unit
            // without imposing the string child's encoding check on that scope.
            switch (self.state) {
                .line_comment, .block_comment, .block_star => {
                    const bytes = self.contents.input.bytes;
                    const at = self.position();
                    if (bytes.len - at >= E.width) {
                        const unit = E.unit(bytes, at);
                        self.contents.offset += E.width;
                        return self.emit(@intCast(@min(unit, 128)), at, E.width);
                    }
                },
                else => {},
            }
            // Fuse the leaf decode/location result into the host step. Keep
            // the larger host and validation state machines independently sized.
            return @call(.always_inline, logical.Reader(actual).step, .{&self.contents});
        }
        fn emit(self: *const Self, c: u21, start: u32, len: u32) logical.Step {
            return .{ .scalar = .{ .codepoint = c, .location = .{
                .span = .{ .start = self.contents.input.origin + start, .len = len },
                .segment_start = self.contents.segment_start,
            } } };
        }
        fn fail(self: *Self, reason: @FieldType(logical.Failure, "reason"), start: u32, len: u32) logical.Step {
            self.failure = .{ .reason = reason, .location = .{
                .span = .{ .start = self.contents.input.origin + start, .len = len },
                .segment_start = self.contents.segment_start,
            } };
            return .{ .failure = self.failure.? };
        }
    };
}
