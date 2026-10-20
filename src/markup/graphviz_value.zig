//! Bounded-memory value checks. Decode references only while inspecting values;
//! retained source and spans are never changed. No entity expansion/allocation.
const std = @import("std");
const support = @import("parser_support");
const graphviz = @import("graphviz.zig");

pub const Problem = enum { alignment, boolean, scale, integer, font_size, sides, style, separator, image_source, fixed_dimensions };
pub fn message(problem: Problem) []const u8 {
    return switch (problem) {
        .alignment => "use an alignment allowed for this attribute and element",
        .boolean => "use TRUE or FALSE",
        .scale => "use FALSE, TRUE, WIDTH, HEIGHT or BOTH",
        .integer => "use a whole number within this attribute's documented range",
        .font_size => "use a finite font size between 0 and 255 points",
        .sides => "use only L, T, R and B in SIDES",
        .style => "use RADIAL, or ROUNDED on TABLE; separate styles with spaces or commas",
        .separator => "the only supported ROWS or COLUMNS value is *",
        .image_source => "IMG requires a nonempty SRC attribute",
        .fixed_dimensions => "FIXEDSIZE=TRUE requires positive WIDTH and HEIGHT",
    };
}

pub fn Reader(comptime actual: support.encoding.Actual) type {
    const enc = support.encoding.Reader(actual);
    return struct {
        bytes: []const u8,
        index: usize = 0,
        failed: bool = false,
        // XML normalizes literal attribute whitespace, not character references.
        normalize_space: bool = false,
        /// A bounded cancellation step for every inspected code unit. Invalid
        /// or unknown references remain distinguishable from decoded content.
        pub fn next(self: *@This(), context: anytype) ?u32 {
            if (self.index == self.bytes.len) return null;
            if (!context.unit()) {
                self.failed = true;
                return null;
            }
            const c = enc.unit(self.bytes, self.index);
            self.index += enc.width;
            if (c != '&') return if (self.normalize_space and (c == '\t' or c == '\n' or c == '\r')) ' ' else c;
            const begin = self.index;
            while (self.index < self.bytes.len and enc.unit(self.bytes, self.index) != ';') : (self.index += enc.width) {
                if (!context.unit()) {
                    self.failed = true;
                    return null;
                }
                const lexical = @import("lexer.zig");
                const unit = enc.byteAt(self.bytes, self.index);
                const first = enc.byteAt(self.bytes, begin);
                const valid = if (self.index == begin)
                    unit == '#' or lexical.isNameStart(unit)
                else if (first == '#')
                    (self.index == begin + enc.width and unit == 'x') or lexical.digit(unit, if (enc.byteAt(self.bytes, begin + enc.width) == 'x') 16 else 10) != null
                else
                    lexical.isNameContinue(unit);
                if (!valid) {
                    self.index = begin;
                    return '&';
                }
            }
            if (self.index == self.bytes.len) {
                self.index = begin;
                return '&';
            }
            const name = self.bytes[begin..self.index];
            if (!context.unit()) {
                self.failed = true;
                return null;
            }
            self.index += enc.width;
            if (name.len == 0) {
                self.index = begin;
                return '&';
            }
            if (enc.unit(name, 0) != '#') return @import("graphviz_entities.zig").lookup(actual, name) orelse 0xffffffff;
            var i: usize = enc.width;
            var base: u32 = 10;
            if (i < name.len and enc.unit(name, i) == 'x') {
                base = 16;
                i += enc.width;
            }
            if (i == name.len) {
                self.index = begin;
                return '&';
            }
            var number: u32 = 0;
            while (i < name.len) : (i += enc.width) {
                if (!context.unit()) {
                    self.failed = true;
                    return null;
                }
                const unit = enc.unit(name, i);
                const digit: u32 = switch (unit) {
                    '0'...'9' => unit - '0',
                    'a'...'f' => unit - 'a' + 10,
                    'A'...'F' => unit - 'A' + 10,
                    else => return '&',
                };
                if (digit >= base) return '&';
                number = number *| base +| digit;
            }
            if (@import("lexer.zig").referenceCharacter(number)) return number;
            self.index = begin;
            return '&';
        }
    };
}

pub fn Checks(comptime actual: support.encoding.Actual) type {
    const enc = support.encoding.Reader(actual);
    const R = Reader(actual);
    return struct {
        pub fn named(name: []const u8, expected: []const u8) bool {
            return enc.asciiEqual(name, expected, true);
        }
        pub fn equals(value: []const u8, expected: []const u8, context: anytype) bool {
            var r: R = .{ .bytes = value, .normalize_space = true };
            for (expected) |byte| {
                const c = r.next(context) orelse return false;
                if (c > 127 or std.ascii.toUpper(@intCast(c)) != byte) return false;
            }
            return r.next(context) == null and !r.failed;
        }
        fn choices(value: []const u8, comptime list: anytype, context: anytype) bool {
            inline for (list) |word| if (equals(value, word, context)) return true;
            return false;
        }
        fn integer(value: []const u8, min: i32, max: i32, context: anytype) bool {
            var r: R = .{ .bytes = value };
            var current = r.next(context);
            while (space(current)) current = r.next(context);
            const negative = current == '-';
            const bound: u32 = @intCast(if (negative) @max(0, -min) else max);
            if (current == '+' or current == '-') current = r.next(context);
            var count: u32 = 0;
            var n: u32 = 0;
            while (current) |c| {
                if (c < '0' or c > '9') break;
                count +|= 1;
                n = n *| 10 +| (c - '0');
                if (n > bound) return false;
                current = r.next(context);
            }
            while (space(current)) current = r.next(context);
            const signed: i64 = if (negative) -@as(i64, n) else n;
            return !r.failed and current == null and count > 0 and signed >= min and signed <= max;
        }
        fn space(c: ?u32) bool {
            return c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }
        fn fontSize(value: []const u8, context: anytype) bool {
            // Streaming decimal grammar; no bounded string copy that would
            // reject a valid value merely for having many leading zeroes.
            var r: R = .{ .bytes = value };
            var c = r.next(context);
            while (space(c)) c = r.next(context);
            const negative = c == '-';
            if (c == '+' or c == '-') c = r.next(context);
            var digits: u32 = 0;
            var significant: u32 = 0;
            var leading: u32 = 0;
            var trailing_nonzero = false;
            var exponent: i64 = 0;
            var fractional = false;
            while (c) |ch| {
                if (ch == '.' and !fractional) {
                    fractional = true;
                    c = r.next(context);
                    continue;
                }
                if (ch < '0' or ch > '9') break;
                digits +|= 1;
                if (fractional) exponent -= 1;
                if (significant != 0 or ch != '0') {
                    if (significant < 3) leading = leading * 10 + (ch - '0') else trailing_nonzero = trailing_nonzero or ch != '0';
                    significant +|= 1;
                }
                c = r.next(context);
            }
            if (c == 'e' or c == 'E') {
                c = r.next(context);
                const negative_power = c == '-';
                if (c == '+' or c == '-') c = r.next(context);
                var power: i64 = 0;
                var count: u32 = 0;
                while (c) |ch| {
                    if (ch < '0' or ch > '9') break;
                    count +|= 1;
                    power = @min(10000000000, power * 10 + @as(i64, ch - '0'));
                    c = r.next(context);
                }
                if (count == 0) return false;
                exponent += if (negative_power) -power else power;
            }
            while (space(c)) c = r.next(context);
            if (r.failed or c != null or digits == 0) return false;
            if (significant == 0) return true;
            if (negative) return false;
            // Compare the decimal value with 255 exactly, without conversion,
            // rounding, underflow, libm, or a large temporary numeric string.
            const places = @as(i64, significant) + exponent;
            if (places != 3) return places < 3;
            var retained = significant;
            while (retained < 3) : (retained += 1) leading *= 10;
            return leading < 255 or (leading == 255 and !trailing_nonzero);
        }
        pub fn check(owner: graphviz.Element, name: []const u8, value: []const u8, context: anytype) ?Problem {
            if (named(name, "ALIGN") or named(name, "BALIGN")) {
                if (choices(value, .{ "LEFT", "CENTER", "RIGHT" }, context) or (owner == .TD and named(name, "ALIGN") and equals(value, "TEXT", context))) return null;
                return .alignment;
            }
            if (named(name, "VALIGN")) return if (choices(value, .{ "TOP", "MIDDLE", "BOTTOM" }, context)) null else .alignment;
            if (named(name, "FIXEDSIZE")) return if (choices(value, .{ "TRUE", "FALSE" }, context)) null else .boolean;
            if (named(name, "SCALE")) return if (choices(value, .{ "TRUE", "FALSE", "WIDTH", "HEIGHT", "BOTH" }, context)) null else .scale;
            if (named(name, "COLUMNS") or named(name, "ROWS")) return if (equals(value, "*", context)) null else .separator;
            if (named(name, "POINT-SIZE")) return if (fontSize(value, context)) null else .font_size;
            if (named(name, "BORDER") or named(name, "CELLPADDING")) return if (integer(value, 0, 255, context)) null else .integer;
            if (named(name, "CELLBORDER")) return if (integer(value, 0, 127, context)) null else .integer;
            if (named(name, "CELLSPACING")) return if (integer(value, -128, 127, context)) null else .integer;
            if (named(name, "WIDTH") or named(name, "HEIGHT")) return if (integer(value, 0, 65535, context)) null else .integer;
            if (named(name, "COLSPAN") or named(name, "ROWSPAN")) return if (integer(value, 1, 65535, context)) null else .integer;
            if (named(name, "GRADIENTANGLE")) return if (integer(value, 0, 360, context)) null else .integer;
            if (named(name, "SRC")) return if (value.len != 0) null else .image_source;
            if (named(name, "SIDES")) {
                var r: R = .{ .bytes = value };
                while (r.next(context)) |c| {
                    if (c > 127 or std.mem.indexOfScalar(u8, "LTRBltrb", @intCast(c)) == null) return .sides;
                }
                return null;
            }
            if (named(name, "STYLE")) {
                var r: R = .{ .bytes = value, .normalize_space = true };
                var word: [7]u8 = undefined;
                var len: usize = 0;
                while (true) {
                    const c = r.next(context);
                    if (c == null or c == ' ' or c == ',') {
                        if (len != 0 and !std.mem.eql(u8, word[0..len], "RADIAL") and !(owner == .TABLE and std.mem.eql(u8, word[0..len], "ROUNDED"))) return .style;
                        len = 0;
                        if (c == null) break;
                    } else {
                        if (len == word.len or c.? > 127) return .style;
                        word[len] = std.ascii.toUpper(@intCast(c.?));
                        len += 1;
                    }
                }
            }
            // Free-form strings and colors depend on renderer/scheme context.
            return null;
        }
        pub fn positiveDimension(value: []const u8, context: anytype) bool {
            return integer(value, 1, 65535, context);
        }
    };
}
