//! Generate full default case folding from pinned local Unicode data.
const std = @import("std");
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;
const Entry = struct { key: u21, values: [3]u21, len: u2 };
const Range = struct { first: u21, last: u21, delta: i32, stride: u2 };
const Tables = struct {
    ranges: std.ArrayList(Range) = .empty,
    expansions: std.ArrayList(Entry) = .empty,

    fn deinit(self: *Tables, gpa: Allocator) void {
        self.ranges.deinit(gpa);
        self.expansions.deinit(gpa);
    }
};

fn parse(gpa: Allocator, input: []const u8) !std.ArrayList(Entry) {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const content = unicode.trim(line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len]);
        if (content.len == 0) continue;
        var fields = std.mem.splitScalar(u8, content, ';');
        const key = try unicode.codePoint(fields.next().?);
        const status = unicode.trim(fields.next() orelse return error.InvalidUnicodeData);
        const mapping = unicode.trim(fields.next() orelse return error.InvalidUnicodeData);
        if (unicode.trim(fields.next() orelse return error.InvalidUnicodeData).len != 0 or fields.next() != null)
            return error.InvalidUnicodeData;
        // Full default folding uses C and F; S and Turkic T are deliberately omitted.
        if (std.mem.eql(u8, status, "S") or std.mem.eql(u8, status, "T")) continue;
        if (!std.mem.eql(u8, status, "C") and !std.mem.eql(u8, status, "F")) return error.InvalidUnicodeData;
        if (entries.items.len != 0 and key <= entries.items[entries.items.len - 1].key)
            return error.UnsortedOrDuplicateMapping;
        var entry: Entry = .{ .key = key, .values = .{ 0, 0, 0 }, .len = 0 };
        var values = std.mem.tokenizeAny(u8, mapping, " \t");
        while (values.next()) |value| {
            if (entry.len == entry.values.len) return error.MappingTooLong;
            entry.values[entry.len] = try unicode.codePoint(value);
            entry.len += 1;
        }
        if (entry.len == 0) return error.InvalidUnicodeData;
        try entries.append(gpa, entry);
    }
    return entries;
}

fn compress(gpa: Allocator, entries: []const Entry) !Tables {
    var tables: Tables = .{};
    errdefer tables.deinit(gpa);
    var singles: std.ArrayList(Entry) = .empty;
    defer singles.deinit(gpa);
    for (entries) |entry| {
        if (entry.len == 1) try singles.append(gpa, entry) else try tables.expansions.append(gpa, entry);
    }
    var i: usize = 0;
    while (i < singles.items.len) {
        const entry = singles.items[i];
        const delta = @as(i32, entry.values[0]) - @as(i32, entry.key);
        var last = entry.key;
        const stride = if (i + 1 < singles.items.len) singles.items[i + 1].key - entry.key else 0;
        var j = i + 1;
        if (stride == 1 or stride == 2) {
            while (j < singles.items.len) : (j += 1) {
                const next = singles.items[j];
                if (next.key - last != stride or @as(i32, next.values[0]) - @as(i32, next.key) != delta) break;
                last = next.key;
            }
        }
        try tables.ranges.append(gpa, .{ .first = entry.key, .last = last, .delta = delta, .stride = if (last == entry.key) 1 else @intCast(stride) });
        i = j;
    }
    return tables;
}

/// Compare compressed lookup with original C/F records, including unmapped holes.
fn verify(entries: []const Entry, tables: Tables) !void {
    var r: usize = 0;
    var e: usize = 0;
    var original: usize = 0;
    var cp: u21 = 0;
    while (cp <= 0x10ffff) : (cp += 1) {
        while (r < tables.ranges.items.len and cp > tables.ranges.items[r].last) : (r += 1) {}
        while (e < tables.expansions.items.len and cp > tables.expansions.items[e].key) : (e += 1) {}
        var actual = [3]u21{ cp, 0, 0 };
        var len: u2 = 1;
        if (r < tables.ranges.items.len and cp >= tables.ranges.items[r].first and
            (cp - tables.ranges.items[r].first) % tables.ranges.items[r].stride == 0)
        {
            actual[0] = std.math.cast(u21, @as(i32, cp) + tables.ranges.items[r].delta) orelse return error.CompressionMismatch;
        } else if (e < tables.expansions.items.len and cp == tables.expansions.items[e].key) {
            actual = tables.expansions.items[e].values;
            len = tables.expansions.items[e].len;
        }
        var expected = [3]u21{ cp, 0, 0 };
        var expected_len: u2 = 1;
        if (original < entries.len and cp == entries[original].key) {
            expected = entries[original].values;
            expected_len = entries[original].len;
            original += 1;
        }
        if (len != expected_len or !std.mem.eql(u21, actual[0..len], expected[0..expected_len]))
            return error.CompressionMismatch;
    }
}

fn emit(writer: *std.Io.Writer, tables: Tables) !void {
    try writer.print(
        "//! Generated by tools/generate_string_casefold.zig. Do not edit by hand.\n" ++
            "//! Unicode 17.0.0 full default folding: C + F, excluding Turkic T and simple S.\n" ++
            "//! Input SHA-256: {s}\n" ++
            "//! Source: https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt\n" ++
            "//! Copyright Unicode, Inc. Distributed under UNICODE_LICENSE.txt alongside this file.\n" ++
            "pub const version = \"17.0.0\";\n" ++
            "const Range = struct {{ first: u21, last: u21, delta: i32, stride: u2 }};\n" ++
            "const ranges = [_]Range{{\n",
        .{unicode.case_folding.sha256},
    );
    for (tables.ranges.items) |range| try writer.print(
        "    .{{ .first = 0x{x}, .last = 0x{x}, .delta = {d}, .stride = {d} }},\n",
        .{ range.first, range.last, range.delta, range.stride },
    );
    try writer.writeAll("};\nconst Expansion = struct { key: u21, values: [3]u21, len: u2 };\nconst expansions = [_]Expansion{\n");
    for (tables.expansions.items) |entry| try writer.print(
        "    .{{ .key = 0x{x}, .values = .{{ 0x{x}, 0x{x}, 0x{x} }}, .len = {d} }},\n",
        .{ entry.key, entry.values[0], entry.values[1], entry.values[2], entry.len },
    );
    try writer.writeAll("};\n\n");
    try writer.writeAll(@embedFile("templates/string_casefold.zig.txt"));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const check = unicode.checkPath(args, 1) catch |err| {
        std.debug.print("usage: generate-string-casefold CaseFolding.txt [--check output.zig]\n", .{});
        return err;
    };
    const input = try unicode.readPinned(gpa, init.io, args[1], unicode.case_folding);
    const entries = try parse(gpa, input);
    const tables = try compress(gpa, entries.items);
    try verify(entries.items, tables);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    try emit(&buffer.writer, tables);
    try unicode.output(gpa, init.io, buffer.written(), check);
}

test "full default folding, compression holes, negative deltas and expansions" {
    const gpa = std.testing.allocator;
    var entries = try parse(gpa, "0041; C; 0061;\n0042; C; 0062;\n0049; T; 0131;\n00DF; F; 0073 0073;\n" ++
        "0100; C; 0101;\n0102; C; 0103;\n0130; F; 0069 0307;\n0130; T; 0069;\n" ++
        "1E9E; F; 0073 0073;\n1E9E; S; 00DF;\n212A; C; 006B;\nFB03; F; 0066 0066 0069;\n");
    defer entries.deinit(gpa);
    var tables = try compress(gpa, entries.items);
    defer tables.deinit(gpa);
    try verify(entries.items, tables);
    try std.testing.expectEqual(@as(usize, 3), tables.ranges.items.len);
    try std.testing.expectEqual(@as(u2, 2), tables.ranges.items[1].stride);
    try std.testing.expectEqual(@as(usize, 4), tables.expansions.items.len);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try emit(&buffer.writer, tables);
    const formatted = try unicode.format(gpa, buffer.written());
    defer gpa.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "pub fn fold") != null);
    tables.ranges.items[0].delta += 1;
    try std.testing.expectError(error.CompressionMismatch, verify(entries.items, tables));
}

test "bad mappings fail instead of silently corrupting generated data" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidUnicodeData, parse(gpa, "0041; C; ;"));
    try std.testing.expectError(error.InvalidUnicodeData, parse(gpa, "0041; X; 0061;"));
    try std.testing.expectError(error.InvalidUnicodeData, parse(gpa, "110000; C; 0061;"));
    try std.testing.expectError(error.MappingTooLong, parse(gpa, "0041; F; 0061 0062 0063 0064;"));
    try std.testing.expectError(error.UnsortedOrDuplicateMapping, parse(gpa, "0042; C; 0062;\n0041; C; 0061;"));
    try std.testing.expectError(error.UnsortedOrDuplicateMapping, parse(gpa, "0041; C; 0061;\n0041; F; 0061;"));
    var empty = try compress(gpa, &.{});
    defer empty.deinit(gpa);
    try verify(&.{}, empty);
}
