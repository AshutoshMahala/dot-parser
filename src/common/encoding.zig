//! Compile-time input capabilities and allocation-free native code-unit readers.
//! A capability set is not a runtime validation policy or mixed-encoding framing.
const std = @import("std");

pub const Encoding = enum { ascii, utf8, utf16, utf32 };
pub const Actual = enum(u3) { ascii, utf8, utf16le, utf16be, utf32le, utf32be };
pub const Provenance = enum(u2) { default, explicit, bom, inherited };

/// One byte per input context, never per token, node or attribute.
pub const Info = packed struct(u8) {
    encoding: Actual = .utf8,
    provenance: Provenance = .default,
    has_bom: bool = false,
    _reserved: u2 = 0,

    pub fn bomBytes(self: Info) u3 {
        return if (!self.has_bom) 0 else switch (self.encoding) {
            .ascii => 0,
            .utf8 => 3,
            .utf16le, .utf16be => 2,
            .utf32le, .utf32be => 4,
        };
    }

    pub fn unitBytes(self: Info) u3 {
        return switch (self.encoding) {
            .ascii, .utf8 => 1,
            .utf16le, .utf16be => 2,
            .utf32le, .utf32be => 4,
        };
    }
};

pub const Capabilities = packed struct(u4) {
    ascii: bool = false,
    utf8: bool = false,
    utf16: bool = false,
    utf32: bool = false,

    /// Omission means UTF-8; an explicitly empty list means ASCII-only.
    pub fn from(comptime input: ?[]const Encoding) Capabilities {
        const requested = input orelse return .{ .utf8 = true };
        if (requested.len == 0) return .{ .ascii = true };
        var result: Capabilities = .{};
        for (requested) |value| switch (value) {
            .ascii => result.ascii = true,
            .utf8 => result.utf8 = true,
            .utf16 => result.utf16 = true,
            .utf32 => result.utf32 = true,
        };
        return result;
    }

    pub fn merge(a: Capabilities, b: Capabilities) Capabilities {
        return @bitCast(@as(u4, @bitCast(a)) | @as(u4, @bitCast(b)));
    }

    /// Bound omission inherits, rather than contributing standalone UTF-8.
    pub fn bound(comptime outer: Capabilities, comptime inner: ?[]const Encoding) Capabilities {
        return if (inner == null) outer else outer.merge(from(inner));
    }

    pub fn list(comptime self: Capabilities) []const Encoding {
        return switch (@as(u4, @bitCast(self))) {
            0, 1 => &.{.ascii},
            2 => &.{.utf8},
            3 => &.{ .ascii, .utf8 },
            4 => &.{.utf16},
            5 => &.{ .ascii, .utf16 },
            6 => &.{ .utf8, .utf16 },
            7 => &.{ .ascii, .utf8, .utf16 },
            8 => &.{.utf32},
            9 => &.{ .ascii, .utf32 },
            10 => &.{ .utf8, .utf32 },
            11 => &.{ .ascii, .utf8, .utf32 },
            12 => &.{ .utf16, .utf32 },
            13 => &.{ .ascii, .utf16, .utf32 },
            14 => &.{ .utf8, .utf16, .utf32 },
            15 => &.{ .ascii, .utf8, .utf16, .utf32 },
        };
    }

    pub fn allows(self: Capabilities, actual: Actual) bool {
        return switch (actual) {
            .ascii => self.ascii,
            .utf8 => self.utf8,
            .utf16le, .utf16be => self.utf16,
            .utf32le, .utf32be => self.utf32,
        };
    }

    pub fn byteOnly(self: Capabilities) bool {
        return !self.utf16 and !self.utf32;
    }
};

pub const InputError = error{
    UnsupportedEncoding,
    EncodingRequired,
    ConflictingBom,
    SourceTooLarge,
    TruncatedCodeUnit,
    InvalidEncoding,
    Cancelled,
};

pub fn bom(source: []const u8) ?Info {
    // UTF-32LE starts with the UTF-16LE signature. Longest matches win.
    const entries = .{
        .{ Actual.utf32le, "\xff\xfe\x00\x00" },
        .{ Actual.utf32be, "\x00\x00\xfe\xff" },
        .{ Actual.utf8, "\xef\xbb\xbf" },
        .{ Actual.utf16le, "\xff\xfe" },
        .{ Actual.utf16be, "\xfe\xff" },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, source, entry[1]))
            return .{ .encoding = entry[0], .provenance = .bom, .has_bom = true };
    }
    return null;
}

/// Select one actual encoding for the entire buffer. Native input without a
/// signature needs explicit byte order; no host-endian or content guessing.
pub fn select(comptime capabilities: Capabilities, source: []const u8, explicit: ?Actual) InputError!Info {
    if (source.len > std.math.maxInt(u32)) return error.SourceTooLarge;
    const detected = bom(source);
    const actual = explicit orelse if (detected) |value| value.encoding else if (capabilities.utf8) Actual.utf8 else if (capabilities.ascii) Actual.ascii else return error.EncodingRequired;
    if (!capabilities.allows(actual)) return error.UnsupportedEncoding;
    if (detected) |value| if (value.encoding != actual) return error.ConflictingBom;
    const info: Info = .{
        .encoding = actual,
        .provenance = if (explicit != null) .explicit else if (detected != null) .bom else .default,
        .has_bom = detected != null,
    };
    const width: u3 = switch (actual) {
        .ascii, .utf8 => 1,
        .utf16le, .utf16be => 2,
        .utf32le, .utf32be => 4,
    };
    if (source.len % width != 0) return error.TruncatedCodeUnit;
    return info;
}

pub const DecodeError = error{ InvalidEncoding, TruncatedEncoding };
pub const Decoded = packed struct { scalar: u21, len: u3 };

pub fn Reader(comptime actual: Actual) type {
    return struct {
        pub const selected = actual;
        pub const width = switch (actual) {
            .ascii, .utf8 => 1,
            .utf16le, .utf16be => 2,
            .utf32le, .utf32be => 4,
        };
        pub const endian: std.builtin.Endian = switch (actual) {
            .utf16be, .utf32be => .big,
            else => .little,
        };

        pub fn sourceInfo(source: []const u8) Info {
            const present = bomLength(source) != 0;
            return .{ .encoding = actual, .has_bom = present, .provenance = if (present) .bom else if (actual == .utf8) .default else .inherited };
        }

        /// Internal reader: the caller has checked alignment and full-unit bounds.
        /// No pointer casts, overreads, allocation or disabled runtime safety.
        pub inline fn unit(source: []const u8, at: usize) u32 {
            return switch (width) {
                1 => source[at],
                2 => std.mem.readInt(u16, source[at..][0..2], endian),
                4 => std.mem.readInt(u32, source[at..][0..4], endian),
                else => unreachable,
            };
        }
        /// A classification projection, not decoded text. Original bytes stay
        /// untouched; non-ASCII code units enter the lexer's high-byte class.
        pub inline fn byteAt(source: []const u8, at: usize) u8 {
            if (width == 1) return source[at];
            const value = unit(source, at);
            return if (value < 128) @intCast(value) else 128;
        }
        pub inline fn scanByte(source: []const u8, index: usize) u8 {
            return byteAt(source, index * width);
        }
        pub inline fn units(source: []const u8) usize {
            return source.len / width;
        }
        pub fn bomLength(source: []const u8) u3 {
            const signature = switch (actual) {
                .ascii => return 0,
                .utf8 => "\xef\xbb\xbf",
                .utf16le => "\xff\xfe",
                .utf16be => "\xfe\xff",
                .utf32le => "\xff\xfe\x00\x00",
                .utf32be => "\x00\x00\xfe\xff",
            };
            return if (std.mem.startsWith(u8, source, signature)) @intCast(signature.len) else 0;
        }
        pub inline fn decode(source: []const u8, at: usize) DecodeError!Decoded {
            if (at > source.len or source.len - at < width) return error.TruncatedEncoding;
            if (actual == .utf8) {
                const len = std.unicode.utf8ByteSequenceLength(source[at]) catch return error.InvalidEncoding;
                if (source.len - at < len) return error.TruncatedEncoding;
                const scalar = std.unicode.utf8Decode(source[at..][0..len]) catch return error.InvalidEncoding;
                return .{ .scalar = scalar, .len = len };
            }
            const first = unit(source, at);
            if (actual == .ascii and first >= 128) return error.InvalidEncoding;
            if (width == 2 and first >= 0xd800 and first <= 0xdbff) {
                if (source.len - at < 4) return error.TruncatedEncoding;
                const second = unit(source, at + 2);
                if (second < 0xdc00 or second > 0xdfff) return error.InvalidEncoding;
                return .{ .scalar = @intCast(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00), .len = 4 };
            }
            if (first > 0x10ffff or (first >= 0xd800 and first <= 0xdfff)) return error.InvalidEncoding;
            return .{ .scalar = @intCast(first), .len = width };
        }
        pub fn asciiEqual(raw: []const u8, text: []const u8, ignore_case: bool) bool {
            if (raw.len % width != 0 or raw.len / width != text.len) return false;
            for (text, 0..) |value, i| {
                const code = unit(raw, i * width);
                if (code > 127) return false;
                const byte: u8 = @intCast(code);
                if ((if (ignore_case) std.ascii.toLower(byte) else byte) !=
                    (if (ignore_case) std.ascii.toLower(value) else value)) return false;
            }
            return true;
        }
        pub fn orderUnits(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
            var at: usize = 0;
            const len = @min(a.len, b.len);
            while (at < len) : (at += width) {
                var left = unit(a, at);
                var right = unit(b, at);
                if (ignore_case) {
                    if (left < 128) left = std.ascii.toLower(@intCast(left));
                    if (right < 128) right = std.ascii.toLower(@intCast(right));
                }
                if (left != right) return std.math.order(left, right);
            }
            return std.math.order(a.len, b.len);
        }
        pub fn indexAscii(raw: []const u8, value: u8) ?usize {
            if (width == 1) return std.mem.indexOfScalar(u8, raw, value);
            var at: usize = 0;
            while (at < raw.len) : (at += width) if (unit(raw, at) == value) return at;
            return null;
        }
        /// Scanner-internal positions count code units. Exported span/range
        /// coordinates always count original physical bytes. Call only on
        /// scanner-produced positions bounded by a checked u32 source length.
        pub fn scaled(comptime T: type, value: T) T {
            if (width == 1) return value;
            var result = value;
            if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "start") and @hasField(T, "len") and
                @FieldType(T, "start") == u32 and @FieldType(T, "len") == u32)
            {
                result.start *= width;
                result.len *= width;
                return result;
            }
            switch (@typeInfo(T)) {
                .@"struct" => |info| inline for (info.fields) |field| {
                    if (!field.is_comptime) @field(result, field.name) = scaled(field.type, @field(value, field.name));
                },
                .@"union" => |info| if (info.tag_type != null) {
                    inline for (info.fields) |field| if (std.meta.activeTag(value) == @field(info.tag_type.?, field.name)) {
                        return @unionInit(T, field.name, scaled(field.type, @field(value, field.name)));
                    };
                },
                .optional => |info| if (value) |v| {
                    result = scaled(info.child, v);
                },
                else => {},
            }
            return result;
        }
    };
}

test "encoding capability defaults, empty fallback and bound inheritance" {
    const expect = std.testing.expectEqual;
    try expect(Capabilities{ .utf8 = true }, comptime Capabilities.from(null));
    try expect(Capabilities{ .ascii = true }, comptime Capabilities.from(&.{}));
    const parent = comptime Capabilities.from(&.{.utf16});
    try expect(parent, comptime Capabilities.bound(parent, null));
    try expect(Capabilities{ .utf16 = true, .utf32 = true }, comptime Capabilities.bound(parent, &.{.utf32}));
    try expect(Capabilities{ .ascii = true, .utf16 = true }, comptime Capabilities.bound(parent, &.{}));
    try expect(Capabilities{ .utf8 = true }, comptime Capabilities.from(&.{ .utf8, .utf8 }));
    try std.testing.expect(!parent.allows(.utf8));
}

test "encoding selection uses longest BOM and preserves provenance" {
    const all = comptime Capabilities.from(&.{ .utf8, .utf16, .utf32 });
    try std.testing.expectEqual(Actual.utf32le, (try select(all, "\xff\xfe\x00\x00", null)).encoding);
    try std.testing.expectEqual(@as(u3, 4), (try select(all, "\xff\xfe\x00\x00", null)).bomBytes());
    try std.testing.expectEqual(Provenance.explicit, (try select(all, "a\x00", .utf16le)).provenance);
    try std.testing.expectError(error.ConflictingBom, select(all, "\xfe\xff", .utf16le));
    try std.testing.expectError(error.EncodingRequired, select(comptime Capabilities.from(&.{.utf32}), "", null));
    try std.testing.expectError(error.TruncatedCodeUnit, select(all, "a", .utf16le));
    try std.testing.expectError(error.UnsupportedEncoding, select(comptime Capabilities.from(&.{}), "\xef\xbb\xbf", null));
}

test "native readers decode boundaries without reading incomplete units" {
    inline for (.{ Actual.utf16le, .utf16be, .utf32le, .utf32be }) |actual| {
        const R = Reader(actual);
        var bytes: [8]u8 = undefined;
        if (R.width == 2) {
            std.mem.writeInt(u16, bytes[0..2], 0xd83d, R.endian);
            std.mem.writeInt(u16, bytes[2..4], 0xde00, R.endian);
        } else std.mem.writeInt(u32, bytes[0..4], 0x1f600, R.endian);
        const decoded = try R.decode(bytes[0..4], 0);
        try std.testing.expectEqual(@as(u21, 0x1f600), decoded.scalar);
        try std.testing.expectEqual(@as(u3, 4), decoded.len);
        for (0..4) |len| try std.testing.expectError(error.TruncatedEncoding, R.decode(bytes[0..len], 0));
        std.mem.writeInt(if (R.width == 2) u16 else u32, bytes[0..R.width], 0xdc00, R.endian);
        try std.testing.expectError(error.InvalidEncoding, R.decode(bytes[0..R.width], 0));
    }
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Info));
}
