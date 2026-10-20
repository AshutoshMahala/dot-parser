//! Logical contents of a single markup text/attribute scope, not a tree walk.
//! Callers remove framing and select the host's reference/whitespace rules.
const support = @import("parser_support");
const logical = support.logical;
const lexical = @import("lexer.zig");
const policy = @import("policy.zig");

pub const Options = struct {
    references: policy.ReferenceCatalog = .xml_predefined,
    malformed_reference: policy.Acceptance = .reject,
    /// Matches existing Graphviz attribute checks; literal CR/LF/tab become
    /// spaces, while character references retain their decoded values.
    normalize_attribute_whitespace: bool = false,
};

pub fn Reader(comptime actual: support.encoding.Actual) type {
    const E = support.encoding.Reader(actual);
    return struct {
        const Self = @This();
        pub const encoding_kind = actual;
        contents: logical.Reader(actual),
        options: Options,
        state: enum { content, start, name, number_start, hex_start, decimal, hex } = .content,
        reference_start: u32 = 0,
        number: u32 = 0,
        failure: ?logical.Failure = null,

        pub fn init(input: support.processor.Fragment, options: Options) support.processor.Fragment.Error!Self {
            return .{ .contents = try logical.Reader(actual).init(input), .options = options };
        }
        pub fn fragment(self: *const Self) support.processor.Fragment {
            return self.contents.input;
        }
        pub fn restarted(self: *const Self) support.processor.Fragment.Error!Self {
            return init(self.fragment(), self.options);
        }
        pub fn location(self: *const Self) logical.SourceLocation {
            var loc = self.contents.location();
            loc.mapping = .enclosing;
            return loc;
        }
        /// Conservative: discovering references/normalization would require a
        /// scan. Empty contents are known unchanged without inspecting anything.
        pub fn contiguous(self: *const Self) ?logical.BorrowedContents {
            return if (self.contents.input.bytes.len == 0) self.contents.contiguous() else null;
        }
        pub fn position(self: *const Self) u32 {
            return self.contents.position();
        }
        pub inline fn asciiRun(self: *const Self) []const u8 {
            if (self.failure != null or self.state != .content) return &.{};
            const bytes = self.contents.asciiRun();
            if (bytes.len == 0) return bytes;
            const V = @Vector(logical.ascii_width, u8);
            const block: V = bytes[0..logical.ascii_width].*;
            if (@reduce(.Or, block == @as(V, @splat('&')))) return &.{};
            if (self.options.normalize_attribute_whitespace and
                @reduce(.Or, (block == @as(V, @splat('\r'))) |
                    (block == @as(V, @splat('\n'))) | (block == @as(V, @splat('\t'))))) return &.{};
            return bytes;
        }
        pub inline fn skipAscii(self: *Self, count: u32) bool {
            if (count == 0 or count > self.asciiRun().len) return false;
            self.contents.offset += count;
            return true;
        }
        pub fn step(self: *Self) logical.Step {
            if (self.failure) |f| return .{ .failure = f };
            // Avoid an intermediate decoded-location return across this leaf
            // boundary without forcing the whole host state machine inline.
            const read = @call(.always_inline, logical.Reader(actual).step, .{&self.contents});
            const item = switch (read) {
                .pending => return .pending,
                .failure => |f| {
                    self.failure = f;
                    return read;
                },
                .end => return if (self.state == .content) .end else self.malformed(),
                .scalar => |item| item,
            };
            const c = item.codepoint;
            switch (self.state) {
                .content => {
                    if (c == '&') {
                        self.reference_start = item.location.span.start - self.contents.input.origin;
                        self.state = .start;
                        return .pending;
                    }
                    var out = item;
                    if (self.options.normalize_attribute_whitespace and (c == '\r' or c == '\n' or c == '\t')) out.codepoint = ' ';
                    return .{ .scalar = out };
                },
                .start => {
                    if (c == '#') {
                        self.state = .number_start;
                        self.number = 0;
                    } else if (lexical.isNameStart(project(c))) {
                        self.state = .name;
                    } else return self.malformed();
                },
                .name => {
                    if (c == ';') {
                        const name = self.contents.input.bytes[self.reference_start + E.width .. self.position() - E.width];
                        const value = switch (self.options.references) {
                            .graphviz => @import("graphviz_entities.zig").lookup(actual, name),
                            .xml_predefined => xmlReference(name),
                        } orelse return self.fail(.unresolved_reference);
                        return self.resolved(value);
                    }
                    if (!lexical.isNameContinue(project(c))) return self.malformed();
                },
                .number_start, .hex_start => {
                    if (self.state == .number_start and c == 'x') {
                        self.state = .hex_start;
                    } else if (lexical.digit(project(c), if (self.state == .hex_start) 16 else 10)) |digit| {
                        self.number = digit;
                        self.state = if (self.state == .hex_start) .hex else .decimal;
                    } else return self.malformed();
                },
                .decimal, .hex => {
                    if (c == ';') {
                        if (!lexical.referenceCharacter(self.number)) return self.malformed();
                        return self.resolved(@intCast(self.number));
                    }
                    const radix: u8 = if (self.state == .hex) 16 else 10;
                    const digit = lexical.digit(project(c), radix) orelse return self.malformed();
                    self.number = self.number *| radix +| digit;
                },
            }
            return .pending;
        }
        fn project(c: u21) u8 {
            return if (c < 128) @intCast(c) else 128;
        }
        fn xmlReference(name: []const u8) ?u21 {
            // Fixed five-name vocabulary, no unbounded lookup/hash or scan.
            inline for (.{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' } }) |entry| {
                if (E.asciiEqual(name, entry[0], false)) return entry[1];
            }
            return null;
        }
        fn referenceLocation(self: *const Self) logical.SourceLocation {
            return .{ .span = .{ .start = self.contents.input.origin + self.reference_start, .len = self.position() - self.reference_start }, .segment_start = self.contents.input.origin };
        }
        fn resolved(self: *Self, cp: u21) logical.Step {
            self.state = .content;
            return .{ .scalar = .{ .codepoint = cp, .location = self.referenceLocation() } };
        }
        fn fail(self: *Self, reason: @FieldType(logical.Failure, "reason")) logical.Step {
            self.failure = .{ .reason = reason, .location = self.referenceLocation() };
            return .{ .failure = self.failure.? };
        }
        fn malformed(self: *Self) logical.Step {
            if (self.options.malformed_reference == .reject) return self.fail(.invalid_syntax);
            // The host owns warning/rejection reporting. Accepted malformed
            // references are literal, as in its scanner: replay after '&'.
            // Each spelling is inspected at most twice; no guessed expansion.
            self.contents.offset = self.reference_start + E.width;
            self.contents.buffered = 0;
            self.contents.needed = 0;
            self.state = .content;
            return .{ .scalar = .{ .codepoint = '&', .location = self.referenceLocation() } };
        }
    };
}
