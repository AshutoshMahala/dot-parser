//! Selected validation definitions, not restrictions on the structural scanner.
//! XML 1.0 Fifth Edition productions [4], [4a] and [5], and predefined entities.
const std = @import("std");
const policy = @import("policy.zig");

pub fn nameCharacter(rule: policy.NameRule, value: u21, first: bool) bool {
    return switch (rule) {
        .xml_1_0 => xmlStart(value) or (!first and switch (value) {
            '-', '.', '0'...'9', 0xb7, 0x300...0x36f, 0x203f...0x2040 => true,
            else => false,
        }),
    };
}

fn xmlStart(value: u21) bool {
    return switch (value) {
        ':',
        '_',
        'A'...'Z',
        'a'...'z',
        0xc0...0xd6,
        0xd8...0xf6,
        0xf8...0x2ff,
        0x370...0x37d,
        0x37f...0x1fff,
        0x200c...0x200d,
        0x2070...0x218f,
        0x2c00...0x2fef,
        0x3001...0xd7ff,
        0xf900...0xfdcf,
        0xfdf0...0xfffd,
        0x10000...0xeffff,
        => true,
        else => false,
    };
}

pub fn knownReference(catalog: policy.ReferenceCatalog, name: []const u8) bool {
    return switch (catalog) {
        .xml_predefined => switch (name.len) {
            2 => std.mem.eql(u8, name, "lt") or std.mem.eql(u8, name, "gt"),
            3 => std.mem.eql(u8, name, "amp"),
            4 => std.mem.eql(u8, name, "apos") or std.mem.eql(u8, name, "quot"),
            else => false,
        },
    };
}

test "XML name ranges use Fifth Edition boundaries, not Unicode letter categories" {
    const ranges = [_][2]u21{
        .{ 0xc0, 0xd6 },     .{ 0xd8, 0xf6 },     .{ 0xf8, 0x2ff },    .{ 0x370, 0x37d },
        .{ 0x37f, 0x1fff },  .{ 0x200c, 0x200d }, .{ 0x2070, 0x218f }, .{ 0x2c00, 0x2fef },
        .{ 0x3001, 0xd7ff }, .{ 0xf900, 0xfdcf }, .{ 0xfdf0, 0xfffd }, .{ 0x10000, 0xeffff },
    };
    for (ranges) |range| {
        try std.testing.expect(nameCharacter(.xml_1_0, range[0], true));
        try std.testing.expect(nameCharacter(.xml_1_0, range[1], true));
        try std.testing.expect(!nameCharacter(.xml_1_0, range[0] - 1, true));
        try std.testing.expect(!nameCharacter(.xml_1_0, range[1] + 1, true));
    }
    for ([_]u21{ '0', '-', '.', 0xb7, 0x300, 0x36f, 0x203f, 0x2040 }) |v| {
        try std.testing.expect(!nameCharacter(.xml_1_0, v, true));
        try std.testing.expect(nameCharacter(.xml_1_0, v, false));
    }
    for ([_]u21{ 0, 0xd800, 0xfffe, 0xffff, 0xf0000, 0x10ffff }) |v|
        try std.testing.expect(!nameCharacter(.xml_1_0, v, false));
    try std.testing.expect(knownReference(.xml_predefined, "amp"));
    try std.testing.expect(!knownReference(.xml_predefined, "AMP"));
    try std.testing.expect(!knownReference(.xml_predefined, "nbsp"));
}
