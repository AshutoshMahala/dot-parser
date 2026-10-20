//! Compile-time input capabilities and allocation-free native code-unit readers.
//! A capability set is not a runtime validation policy or mixed-encoding framing.
const std = @import("std");
const encoding = @This();

pub const Encoding = enum { ascii, utf8, utf16, utf32 };
pub const Actual = enum(u3) { ascii, utf8, utf16le, utf16be, utf32le, utf32be };
pub const Provenance = enum(u2) { default, explicit, bom, inherited };

pub fn unitBytes(actual: Actual) u3 {
    return switch (actual) {
        .ascii, .utf8 => 1,
        .utf16le, .utf16be => 2,
        .utf32le, .utf32be => 4,
    };
}

/// Validation is byte-compatible from ASCII-profile documents to UTF-8, not
/// the reverse. Native readers require the exact encoding and byte order.
pub fn readerAccepts(reader: Actual, document: Actual) bool {
    return reader == document or (reader == .utf8 and document == .ascii);
}

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
        return encoding.unitBytes(self.encoding);
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

pub const AdmissionError = error{
    UnsupportedEncoding,
    EncodingRequired,
    SourceTooLarge,
    TruncatedCodeUnit,
};
pub const InputError = AdmissionError || error{Cancelled};

/// Admission failures are not content-validation findings. A span identifies
/// original physical bytes when there are offending bytes: an unsupported BOM
/// or the incomplete final code unit. Configuration/size failures have no span.
pub const AdmissionFailure = struct {
    reason: AdmissionError,
    span: ?@import("location.zig").Span = null,
    encoding: ?Actual = null,

    pub fn message(self: AdmissionFailure) []const u8 {
        return switch (self.reason) {
            error.UnsupportedEncoding => "source encoding is not enabled; save as UTF-8 or enable the reader in .source_encodings",
            error.EncodingRequired => "BOM-less input requires an explicit .encoding and byte order",
            error.SourceTooLarge => "source exceeds the u32 byte-offset range",
            error.TruncatedCodeUnit => "input ends inside a code unit of the selected encoding",
        };
    }
};

pub const Admission = union(enum) {
    selected: Info,
    failure: AdmissionFailure,

    pub fn require(self: Admission) AdmissionError!Info {
        return switch (self) {
            .selected => |info| info,
            .failure => |failure| failure.reason,
        };
    }
};

/// Bind a no-allocation, constant-time source preflight to compiled readers.
/// It never validates content, allocates, or links a native grammar reader.
pub fn Inspector(comptime capabilities: Capabilities) type {
    return struct {
        pub fn inspect(source: []const u8, explicit: ?Actual) Admission {
            return encoding.inspect(capabilities, source, explicit);
        }
    };
}

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

/// Select one actual encoding for the entire buffer. Explicit selection is
/// authoritative: only that reader's matching BOM is framing. Otherwise detect
/// the longest BOM, then use an enabled byte reader. BOM-less native input needs
/// explicit byte order; no host-endian guessing, NUL heuristic or parse retries.
pub fn select(comptime capabilities: Capabilities, source: []const u8, explicit: ?Actual) InputError!Info {
    return inspect(capabilities, source, explicit).require();
}

/// Positioned counterpart to select, including for UTF-8-only profiles whose
/// ordinary parse API deliberately has no encoding error union. Explicit input
/// remains authoritative. Look at at most four leading bytes, never guess from
/// content or scan for malformed sequences; those belong to validation.
pub fn inspect(comptime capabilities: Capabilities, source: []const u8, explicit: ?Actual) Admission {
    if (source.len > std.math.maxInt(u32)) return .{ .failure = .{ .reason = error.SourceTooLarge } };
    const detected = if (explicit == null) bom(source) else null;
    const actual = explicit orelse if (detected) |value| value.encoding else if (capabilities.utf8) Actual.utf8 else if (capabilities.ascii) Actual.ascii else return .{ .failure = .{ .reason = error.EncodingRequired } };
    if (!capabilities.allows(actual)) return .{ .failure = .{
        .reason = error.UnsupportedEncoding,
        .encoding = actual,
        .span = if (detected) |value| .{ .start = 0, .len = value.bomBytes() } else null,
    } };
    const has_bom = if (explicit != null) switch (actual) {
        inline else => |selected| Reader(selected).bomLength(source) != 0,
    } else detected != null;
    const info: Info = .{
        .encoding = actual,
        .provenance = if (explicit != null) .explicit else if (detected != null) .bom else .default,
        .has_bom = has_bom,
    };
    const width = unitBytes(actual);
    const tail = source.len % width;
    if (tail != 0) return .{ .failure = .{
        .reason = error.TruncatedCodeUnit,
        .encoding = actual,
        .span = .{ .start = @intCast(source.len - tail), .len = @intCast(tail) },
    } };
    return .{ .selected = info };
}

pub const DecodeError = error{ InvalidEncoding, TruncatedEncoding };
pub const Decoded = packed struct { scalar: u21, len: u3 };

/// A processor-owned finding can retain the actual reader and offending code
/// unit without copying source text. Spans still count original physical bytes.
pub const Invalid = struct { unit: u32, encoding: Actual };

/// Encoding validity only, independent of grammar/name/character rules. On
/// failure consume one physical code unit, never the following valid scalar.
/// Callers bound the slice to their scope; no lookahead escapes that boundary.
pub inline fn validationStep(comptime actual: Actual, source: []const u8, at: u32) struct { len: u3, invalid: ?Invalid = null } {
    const R = Reader(actual);
    if (at <= source.len and source.len - at >= R.width and R.unit(source, at) < 128)
        return .{ .len = R.width };
    if (R.decode(source, at)) |decoded| return .{ .len = decoded.len } else |_| {
        // Whole-source selection and public scope metadata enforce full units.
        // Keep this helper total for caller-built/truncated slices as well.
        const remaining = source.len - @min(@as(usize, at), source.len);
        const len: u3 = @intCast(@min(R.width, remaining));
        return .{ .len = len, .invalid = .{
            .unit = if (len == R.width) R.unit(source, at) else if (len != 0) source[at] else 0,
            .encoding = actual,
        } };
    }
}

pub fn Reader(comptime actual: Actual) type {
    return struct {
        pub const selected = actual;
        pub const width: comptime_int = unitBytes(actual);
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
        /// Decode a short ASCII spelling into caller storage. Reject incomplete
        /// code units/non-ASCII input rather than interpreting constituent bytes.
        pub fn asciiInto(raw: []const u8, output: []u8) ?[]const u8 {
            if (raw.len % width != 0 or raw.len / width > output.len) return null;
            const len = raw.len / width;
            for (output[0..len], 0..) |*out, i| {
                const code = unit(raw, i * width);
                if (code > 127) return null;
                out.* = @intCast(code);
            }
            return output[0..len];
        }
        /// Complete native units compare by value. Malformed partial-unit
        /// buffers use raw-byte order so this public helper remains total/safe.
        pub fn orderUnits(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
            if (a.len % width != 0 or b.len % width != 0) return std.mem.order(u8, a, b);
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
            if (raw.len % width != 0) return null;
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
                .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                    if (!attrs.@"comptime") @field(result, name) = scaled(Field, @field(value, name));
                },
                .@"union" => |info| if (info.tag_type != null) {
                    inline for (info.field_names, info.field_types) |name, Field| if (std.meta.activeTag(value) == @field(info.tag_type.?, name)) {
                        return @unionInit(T, name, scaled(Field, @field(value, name)));
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

test "encoding widths and reader compatibility have one source of truth" {
    inline for (comptime std.meta.tags(Actual)) |actual| {
        try std.testing.expectEqual(unitBytes(actual), (Info{ .encoding = actual }).unitBytes());
        try std.testing.expectEqual(unitBytes(actual), Reader(actual).width);
        try std.testing.expect(@TypeOf(Reader(actual).width) == comptime_int);
        inline for (comptime std.meta.tags(Actual)) |document| {
            try std.testing.expectEqual(actual == document or (actual == .utf8 and document == .ascii), readerAccepts(actual, document));
        }
    }
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
    const explicit = try select(all, "\xfe\xff", .utf16le);
    try std.testing.expectEqual(Actual.utf16le, explicit.encoding);
    try std.testing.expectEqual(Provenance.explicit, explicit.provenance);
    try std.testing.expect(!explicit.has_bom);
    try std.testing.expectError(error.EncodingRequired, select(comptime Capabilities.from(&.{.utf32}), "", null));
    try std.testing.expectError(error.TruncatedCodeUnit, select(all, "a", .utf16le));
    try std.testing.expectError(error.UnsupportedEncoding, select(comptime Capabilities.from(&.{}), "\xef\xbb\xbf", null));
}

test "explicit encoding recognizes only its own BOM without reader fallback" {
    const all = comptime Capabilities.from(&.{ .ascii, .utf8, .utf16, .utf32 });
    const overlap = "\xff\xfe\x00\x00";
    const narrow = try select(all, overlap, .utf16le);
    try std.testing.expectEqual(Actual.utf16le, narrow.encoding);
    try std.testing.expectEqual(@as(u3, 2), narrow.bomBytes());
    const wide = try select(all, overlap, null);
    try std.testing.expectEqual(Actual.utf32le, wide.encoding);
    try std.testing.expectEqual(@as(u3, 4), wide.bomBytes());
    const narrow_only = comptime Capabilities.from(&.{.utf16});
    try std.testing.expectError(error.UnsupportedEncoding, select(narrow_only, overlap, null));
    try std.testing.expectEqual(narrow, try select(narrow_only, overlap, .utf16le));

    // These prefixes are text in the explicitly selected reader, even though
    // generic detection would interpret them as another reader's signature.
    inline for (.{
        .{ Actual.utf16le, "\xef\xbb\xbf\x4e" },
        .{ Actual.utf32le, "\xff\xfe\x0f\x00" },
        .{ Actual.utf8, "\xff\xfe" },
        .{ Actual.ascii, "\xef\xbb\xbf" },
    }) |case| {
        const info = try select(all, case[1], case[0]);
        try std.testing.expectEqual(case[0], info.encoding);
        try std.testing.expectEqual(Provenance.explicit, info.provenance);
        try std.testing.expectEqual(@as(u3, 0), info.bomBytes());
    }
    try std.testing.expectEqual(Actual.utf8, (try select(all, "abc", null)).encoding);
    try std.testing.expectEqual(Actual.ascii, (try select(comptime Capabilities.from(&.{}), "abc", null)).encoding);
    try std.testing.expectError(error.EncodingRequired, select(narrow_only, "g\x00", null));
    try std.testing.expectError(error.UnsupportedEncoding, select(narrow_only, "abc", .utf8));
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
